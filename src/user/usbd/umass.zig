//! The mass storage class driver: a disk behind two bulk pipes.
//!
//! Everything about the protocol itself, the wrappers and the commands
//! and what their answers mean, is in `lib.scsi` where it can be tested.
//! What is here is the conversation: write a wrapper, move the data, read
//! the status back, and recover an endpoint that stalled instead of
//! answering.
//!
//! Only the transparent-SCSI, bulk-only variant is driven, which is every
//! stick and card reader worth the name. A device claiming a different
//! transport is left listed and undriven rather than guessed at.

const class = @import("class.zig");
const std = @import("std");
const hc = @import("hc.zig");
const log = @import("ulib").log;
const out = @import("ulib").out;
const scsi = @import("lib").scsi;
const str = @import("ulib").str;
const sys = @import("sys");
const table = @import("ulib").table;
const usb = @import("lib").usb;

pub const name = "umass";

/// Every high speed device's control endpoint takes sixty-four byte
/// packets, and the requests sent here carry no data anyway.
const PACKET_ZERO: u16 = 64;

/// The class this driver is for, which is also what its manifest says.
pub const CLASS = usb.Class.mass_storage;
pub const SUBCLASS: u8 = 0x06;
pub const PROTOCOL: u8 = 0x50;

/// Class control requests, which the specification numbers rather than
/// naming.
const RESET: u8 = 0xFF;
const GET_MAX_UNIT: u8 = 0xFE;

/// How many disks one machine of this class plausibly carries: a card
/// reader with four slots, and something in a socket.
pub const MAX_DISKS = 4;

pub const Disk = struct {
    live: bool = false,
    address: u7 = 0,
    controller: u8 = 0,
    port: u8 = 0,
    interface: u8 = 0,
    unit: u8 = 0,
    reading: usb.Pipe = .{},
    writing: usb.Pipe = .{},
    ops: hc.HcOps = undefined,
    capacity: scsi.Capacity = .{},
    inquiry: scsi.Inquiry = .{},
    /// A number that walks, so a status wrapper can be matched to the
    /// command it answers.
    tag: u32 = 1,
    /// What the device last complained about, kept for the listing.
    sense: scsi.SenseData = .{},

    /// The device's control endpoint, which the class's own requests and
    /// every halt cleared here go to.
    pub fn zero(self: *const Disk) usb.Pipe {
        return .{
            .address = self.address,
            .speed = self.reading.speed,
            .max_packet = PACKET_ZERO,
            .route = self.reading.route,
        };
    }

    pub fn sectors(self: *const Disk) u64 {
        return self.capacity.blocks;
    }

    pub fn sectorBytes(self: *const Disk) u32 {
        return self.capacity.block_bytes;
    }
};

var disks: [MAX_DISKS]Disk = @splat(.{});

pub fn all() []const Disk {
    return &disks;
}

pub fn at(index: usize) ?*Disk {
    if (index >= disks.len or !disks[index].live) return null;
    return &disks[index];
}

/// The disk on a given device address, which is how the bus finds the one
/// that was unplugged.
pub fn forAddress(address: u7) ?*Disk {
    return table.by(&disks, "address", address);
}

pub const ops = class.ClassOps{ .attach = attach, .detach = detach };
pub const driver = class.ClassDriver{ .name = name, .ops = ops };

// ---------------------------------------------------------------------------
// Coming and going
// ---------------------------------------------------------------------------

fn attach(target: class.Target) bool {
    const view = usb.interfaceFor(target.configuration, CLASS, SUBCLASS, PROTOCOL) orelse {
        log.warn(name, "the device carries no bulk-only transparent interface");
        return false;
    };
    const reading = view.find(.bulk, .in) orelse return complain("no pipe to read from");
    const writing = view.find(.bulk, .out) orelse return complain("no pipe to write to");

    const slot = table.free(&disks) orelse return complain("no room for another disk");
    slot.* = .{
        .live = true,
        .address = target.address,
        .controller = target.controller,
        .port = target.port,
        .interface = view.interface.number,
        .reading = target.pipe(reading),
        .writing = target.pipe(writing),
        .ops = target.ops,
    };

    // How many units are behind this one interface. A device that will
    // not say has one, which is what a stick answers by stalling.
    var units: [1]u8 = .{0};
    if (target.control(usb.Setup.classRequest(.in, GET_MAX_UNIT, 0, slot.interface, 1), &units)) |moved| {
        if (moved == 1) slot.unit = units[0];
    } else |_| {
        slot.unit = 0;
    }

    if (!ready(slot)) {
        slot.* = .{};
        return false;
    }

    say(slot);
    return true;
}

fn detach(address: u7) void {
    const disk = forAddress(address) orelse return;
    disk.* = .{};
}

fn complain(what: []const u8) bool {
    log.warn(name, what);
    return false;
}

/// Wake the unit and learn how big it is. A stick answers at once; a
/// spinning disk or a card reader with nothing in it answers `not ready`
/// for a while first, so the question is asked again while it starts.
fn ready(disk: *Disk) bool {
    var attempts: u8 = 0;
    while (attempts < 10) : (attempts += 1) {
        if (command(disk, scsi.testUnitReady(), .out, &.{})) |verdict| {
            if (verdict == .passed) break;
            const why = sense(disk);
            if (why.mediumGone()) return complain("no medium in the unit");
            if (!why.starting() and attempts >= 2) return complain("the unit will not come ready");
        } else |_| {
            if (attempts >= 2) return complain("the unit does not answer");
        }
        sys.sleepMicros(100_000);
    } else return complain("the unit will not come ready");

    var told: [scsi.Inquiry.BYTES]u8 = @splat(0);
    if (command(disk, scsi.inquiry(told.len), .in, &told)) |verdict| {
        if (verdict == .passed) {
            if (scsi.Inquiry.parse(&told)) |answer| disk.inquiry = answer;
        }
    } else |_| {}

    var size: [scsi.Capacity.BYTES]u8 = @splat(0);
    const verdict = command(disk, scsi.readCapacity(), .in, &size) catch
        return complain("the unit will not say how big it is");
    if (verdict != .passed) {
        _ = sense(disk);
        return complain("the unit refused to say how big it is");
    }
    disk.capacity = scsi.Capacity.parse(&size) orelse
        return complain("the unit reported a size that cannot be");
    return true;
}

fn sense(disk: *Disk) scsi.SenseData {
    var told: [scsi.SenseData.BYTES]u8 = @splat(0);
    if (command(disk, scsi.requestSense(told.len), .in, &told)) |verdict| {
        if (verdict == .passed) {
            if (scsi.SenseData.parse(&told)) |answer| {
                disk.sense = answer;
                return answer;
            }
        }
    } else |_| {}
    return .{};
}

// ---------------------------------------------------------------------------
// Reading and writing
// ---------------------------------------------------------------------------

pub const Error = error{
    /// The transport lost its place: the device answered something that
    /// is not a status wrapper, or answers a different command.
    Confused,
    /// The command reached the device and the device refused it.
    Refused,
    /// The device did not answer at all.
    Gone,
    /// More was asked for than one transfer carries.
    TooLarge,
};

/// How many sectors one request carries, from what the controller will
/// take in a single bulk transfer.
pub fn sectorsPerRequest(disk: *const Disk) u32 {
    const size = @max(disk.sectorBytes(), 1);
    const limit: u32 = @intCast(disk.ops.bulkLimit());
    return @max(limit / size, 1);
}

pub fn read(disk: *Disk, lba: u64, into: []u8) Error!void {
    try move(disk, lba, into, false);
}

pub fn write(disk: *Disk, lba: u64, from: []u8) Error!void {
    try move(disk, lba, from, true);
}

/// Commit whatever the device is holding. A device that refuses is a
/// device that was holding nothing, which is the documented behaviour of
/// the cheap readers and not an error to report.
pub fn flush(disk: *Disk) void {
    _ = command(disk, scsi.synchronizeCache(), .out, &.{}) catch {};
}

fn move(disk: *Disk, lba: u64, buffer: []u8, writing: bool) Error!void {
    const size = @max(disk.sectorBytes(), 1);
    if (buffer.len % size != 0) return Error.Refused;
    const count = buffer.len / size;
    if (count == 0) return;
    if (count > sectorsPerRequest(disk)) return Error.TooLarge;
    if (lba + count > disk.sectors()) return Error.Refused;

    const at_lba: u32 = @intCast(lba);
    const blocks: u16 = @intCast(count);
    const block = if (writing) scsi.write10(at_lba, blocks) else scsi.read10(at_lba, blocks);

    const verdict = command(
        disk,
        block,
        if (writing) .out else .in,
        buffer,
    ) catch |err| return switch (err) {
        hc.Error.Timeout => Error.Gone,
        else => Error.Confused,
    };

    if (verdict != .passed) {
        const why = sense(disk);
        return if (why.mediumGone()) Error.Gone else Error.Refused;
    }
}

// ---------------------------------------------------------------------------
// The transport
// ---------------------------------------------------------------------------

/// One command, all the way through: the wrapper out, the data either
/// way, the status back. The only error returned is the transport's; what
/// the device made of the command is the verdict.
fn command(
    disk: *Disk,
    block: scsi.Block,
    direction: scsi.Direction,
    data: []u8,
) hc.Error!scsi.Verdict {
    disk.tag +%= 1;
    const tag = disk.tag;

    var wrapper = scsi.Command.wrap(tag, disk.unit, direction, @intCast(data.len), block.slice());
    var wire: [scsi.Command.BYTES]u8 = @splat(0);
    @memcpy(&wire, std.mem.asBytes(&wrapper)[0..scsi.Command.BYTES]);
    _ = try disk.ops.bulk(&disk.writing, &wire);

    if (data.len != 0) {
        const pipe = if (direction == .in) &disk.reading else &disk.writing;
        _ = disk.ops.bulk(pipe, data) catch |err| {
            // A stalled data pipe is the device saying no to this
            // command, not the end of the conversation: clear the halt
            // and the status wrapper still explains itself.
            if (err != hc.Error.Stalled) return err;
            clearHalt(disk, pipe);
        };
    }

    return status(disk, tag);
}

/// Read the status wrapper, clearing a halted pipe once if that is what
/// the device answered with. A device that will not produce a wrapper
/// even then has lost its place, and only a reset recovers it.
fn status(disk: *Disk, tag: u32) hc.Error!scsi.Verdict {
    var wire: [scsi.Status.BYTES]u8 = @splat(0);

    var attempt: u8 = 0;
    while (attempt < 2) : (attempt += 1) {
        if (disk.ops.bulk(&disk.reading, &wire)) |moved| {
            if (moved < scsi.Status.BYTES) continue;
            const answer = scsi.Status.parse(&wire) orelse break;
            if (!answer.answers(tag)) break;
            if (answer.verdict == .confused) break;
            return answer.verdict;
        } else |err| {
            if (err != hc.Error.Stalled) return err;
            clearHalt(disk, &disk.reading);
        }
    }

    // Whatever came back was not this command's answer. The device and
    // the host disagree about what should happen next, which is what a
    // reset is for.
    recover(disk);
    return hc.Error.Stalled;
}

/// Take a pipe out of its halt, and put the toggle back where the device
/// has just put its own.
fn clearHalt(disk: *Disk, pipe: *usb.Pipe) void {
    const address = @as(u8, pipe.number) | (@as(u8, @intFromEnum(pipe.direction)) << 7);
    hc.command(disk.ops, disk.zero(), usb.Setup.clearHalt(address)) catch {};
    pipe.resetToggle();
}

/// The class's own reset, which puts both pipes and the device back to
/// where a command can be sent again.
fn recover(disk: *Disk) void {
    hc.command(
        disk.ops,
        disk.zero(),
        usb.Setup.classRequest(.out, RESET, 0, disk.interface, 0),
    ) catch {};
    clearHalt(disk, &disk.reading);
    clearHalt(disk, &disk.writing);
}


fn say(disk: *const Disk) void {
    log.begin(name, .key);
    const megabytes = disk.capacity.bytes_() / (1024 * 1024);
    var buf: [24]u8 = @splat(0);
    var text = str.Builder{ .buf = &buf };
    text.quantity(@intCast(megabytes), "MiB");
    out.text(text.done());
    if (disk.inquiry.productSlice().len != 0) {
        out.text(", ");
        out.text(disk.inquiry.productSlice());
    }
    if (disk.inquiry.removable) out.text(" (removable)");
    log.end();
}

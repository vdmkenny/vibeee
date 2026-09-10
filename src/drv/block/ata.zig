//! ATA/PATA driver.
//!
//! Both legacy channels are probed, because the machines this targets disagree
//! about where the disk is: QEMU puts `-drive if=ide` on the primary channel,
//! while the Eee PC 701's soldered SSD sits on the **secondary** channel as
//! master (verified: 0x170/0x376, IRQ 15). Probing both costs four IDENTIFY
//! commands at boot and removes a per-machine assumption.
//!
//! A channel transfers by bus mastering where the controller has the registers
//! for it and the drive is already running a DMA mode, and by moving every
//! word through the CPU where it does not. Both go through the channel's own
//! staging area, because the buffers reaching this driver are a mixture of
//! kernel memory and a caller's own pages, and the controller can only be
//! given an address the driver chose. `design/03-storage-fs.md` §3.
//!
//! Constraints of the real device, from docs/research: ATA-4, **28-bit LBA
//! only** (no LBA48) and **no READ/WRITE MULTIPLE**. Nothing here uses either.

const std = @import("std");
const bcache = @import("../../kernel/bcache.zig");
const block = @import("../../kernel/block.zig");
const console = @import("../../kernel/console.zig");
const hal = @import("../../kernel/hal.zig");
const lib = @import("lib");
const pci = @import("../bus/pci.zig");
const pmm = @import("../../kernel/pmm.zig");

/// Register offsets from a channel's I/O base.
const REG_DATA = 0;
const REG_ERROR = 1;
const REG_SECTOR_COUNT = 2;
const REG_LBA_LOW = 3;
const REG_LBA_MID = 4;
const REG_LBA_HIGH = 5;
const REG_DRIVE = 6;
const REG_STATUS = 7;
const REG_COMMAND = 7;

fn readStatus(ch: *const Channel) Status {
    return @bitCast(hal.inb(ch.io + REG_STATUS));
}

fn issue(ch: *const Channel, cmd: Command) void {
    hal.outb(ch.io + REG_COMMAND, @intFromEnum(cmd));
}

/// The status register.
///
/// A packed struct rather than a mask per bit: `status.busy` says what it
/// tests, and a condition over three of them reads as a sentence instead of as
/// an expression that has to be decoded before it can be checked.
const Status = packed struct(u8) {
    err: bool = false,
    index: bool = false,
    corrected: bool = false,
    /// The drive has data to move.
    request: bool = false,
    seek_complete: bool = false,
    fault: bool = false,
    ready: bool = false,
    /// Nothing else in the register means anything while this is set.
    busy: bool = false,

    /// Whether the drive is reporting a problem rather than a state.
    fn failed(self: Status) bool {
        return self.err or self.fault;
    }
};

const Command = enum(u8) {
    read_sectors = 0x20,
    write_sectors = 0x30,
    read_dma = 0xC8,
    write_dma = 0xCA,
    flush_cache = 0xE7,
    identify = 0xEC,
};

/// Which way a transfer moves.
const Direction = enum { in, out };

/// How a channel moves bytes. A channel with no bus-master block takes the
/// second, and so does one whose drive is not running a DMA mode.
const Path = enum { dma, pio };

/// One command's worth of a caller's memory, and which way it moves.
///
/// A union over the direction rather than a slice beside a flag: which way it
/// goes is what decides whether the driver may write to it, and the two facts
/// cannot then disagree.
const Chunk = union(Direction) {
    in: []u8,
    out: []const u8,

    fn bytes(self: Chunk) usize {
        return switch (self) {
            inline else => |b| b.len,
        };
    }

    /// The same memory from `at`, and no more than `span` of it.
    fn part(self: Chunk, at: usize, span: usize) Chunk {
        return switch (self) {
            .in => |b| .{ .in = b[at..][0..span] },
            .out => |b| .{ .out = b[at..][0..span] },
        };
    }
};

/// The command that starts a transfer, which is the one thing the direction
/// and the path decide together.
fn commandFor(chunk: Chunk, path: Path) Command {
    return switch (path) {
        .dma => switch (chunk) {
            .in => .read_dma,
            .out => .write_dma,
        },
        .pio => switch (chunk) {
            .in => .read_sectors,
            .out => .write_sectors,
        },
    };
}

/// Generous: a spun-down or confused drive can take seconds, and failing early
/// on a slow device is worse than waiting.
/// How long a transfer is waited for. Generous, because a drive spinning
/// up or recovering a sector takes seconds, and it is there.
const TIMEOUT_US: u64 = 5_000_000;
/// How long a drive is given to answer an identify with data. A drive that
/// is there answers within a moment once it is not busy; a slave that is
/// not there leaves the channel showing its master's status forever, and a
/// boot that waited a transfer's worth for that would stall for nothing.
const IDENTIFY_PATIENCE_US: u64 = 100_000;

const Channel = struct {
    io: u16,
    control: u16,
    name: []const u8,
    /// The bus-master block, once a drive on this channel has been found that
    /// can use it. Null while the channel moves words through the CPU: no
    /// window in the controller's fourth BAR, no memory for the staging area,
    /// or nothing here running a DMA mode.
    bus: ?Bus = null,
};

/// A channel's bus-master registers and the memory they read.
///
/// The two drives on a channel share one set of task-file registers and one
/// of these, so they share the one command that may be in flight.
const Bus = struct {
    ports: u16,
    area: *Dma,
    phys: u32,
};

var channels = [_]Channel{
    .{ .io = 0x1F0, .control = 0x3F6, .name = "primary" },
    .{ .io = 0x170, .control = 0x376, .name = "secondary" },
};

/// Offsets from a channel's bus-master base.
const BM_COMMAND = 0;
const BM_STATUS = 2;
const BM_TABLE = 4;

const BusCommand = packed struct(u8) {
    start: bool = false,
    _1: u2 = 0,
    /// Set for device to memory, clear for memory to device.
    to_memory: bool = false,
    _4: u4 = 0,
};

/// The bus-master status register. `failed` and `interrupt` are
/// write-one-to-clear, so writing them back set is what clears them.
const BusStatus = packed struct(u8) {
    active: bool = false,
    failed: bool = false,
    interrupt: bool = false,
    _3: u2 = 0,
    drive0_capable: bool = false,
    drive1_capable: bool = false,
    simplex: bool = false,
};

/// One run of memory for the controller to move, as the controller reads it.
const Prd = packed struct(u64) {
    base: u32 = 0,
    /// Bytes, even, and zero would mean 65536. Never zero here: a run is at
    /// most the staging area, which is smaller than that.
    count: u16 = 0,
    _: u15 = 0,
    /// The last entry of the table.
    last: bool = false,
};

/// An entry may not reach across one of these.
const PRD_BOUNDARY: u32 = 64 * 1024;

/// How much one command carries. The layers above ask for at most one FAT
/// cluster at a time and the largest cluster FAT presents is this, so a
/// larger ask costs an extra command rather than being the common case. It is
/// also what the channel pins for as long as it has a DMA-capable drive.
const STAGING_BYTES: usize = 32 * 1024;

/// The staging area is one contiguous run, so only a boundary can split it.
const PRD_MAX = 2;

/// What a channel keeps in memory the controller reads and writes.
///
/// One allocation, so one physical base to derive every address from. The
/// staging area is first because the allocation is page aligned and that
/// keeps it so, and its length is a multiple of eight so the table that
/// follows needs no padding.
const Dma = extern struct {
    staging: [STAGING_BYTES]u8,
    table: [PRD_MAX]Prd,
};

comptime {
    if (STAGING_BYTES % @alignOf(Prd) != 0) @compileError("the descriptor table would be padded");
    if (@offsetOf(Dma, "table") != STAGING_BYTES) @compileError("the staging area is not first");
    if (STAGING_BYTES % block.SECTOR_SIZE != 0) @compileError("the staging area is not whole sectors");
}

/// What IDENTIFY says a drive can do.
///
/// Everything the driver knows about a device, so any decision taken from it
/// can be tested without one.
const Caps = struct {
    /// Whether it can transfer by DMA at all.
    dma: bool = false,
    /// Which ultra mode it is running, if one was agreed.
    ultra: ?u3 = null,
    /// The same for a multiword mode.
    multiword: ?u3 = null,
    write_cache: bool = false,
    flush: bool = false,

    /// Whether transfers may be handed to the controller.
    ///
    /// A mode both ends of the cable have already agreed needs neither a
    /// command nor host timing to use, and the firmware agrees one to boot
    /// from the drive. Negotiating a faster mode than that is a separate
    /// thing, and it is what would need the host timing registers.
    fn dmaReady(self: Caps) bool {
        return self.dma and (self.ultra != null or self.multiword != null);
    }
};

/// The mode a transfer-mode word reports as running. Low byte is what the
/// drive supports, high byte is what is selected, one bit each.
fn activeMode(word: u16) ?u3 {
    const selected: u8 = @truncate(word >> 8);
    if (selected == 0) return null;
    return @intCast(@ctz(selected));
}

fn capsOf(words: *const [256]u16) Caps {
    return .{
        .dma = words[49] & (1 << 8) != 0,
        .ultra = activeMode(words[88]),
        .multiword = activeMode(words[63]),
        .write_cache = words[82] & (1 << 5) != 0,
        .flush = words[83] & (1 << 12) != 0,
    };
}

pub const Drive = struct {
    channel: *Channel,
    caps: Caps = .{},
    /// False for master, true for slave.
    slave: bool,
    sectors: u64,
    model: [41]u8,
    model_len: usize,
    name: [8]u8,
    name_len: usize,

    fn modelSlice(self: *const Drive) []const u8 {
        return self.model[0..self.model_len];
    }

    fn nameSlice(self: *const Drive) []const u8 {
        return self.name[0..self.name_len];
    }
};

var drives: [4]Drive = undefined;
var drive_count: usize = 0;

// ---------------------------------------------------------------------------
// Low-level helpers
// ---------------------------------------------------------------------------

/// Reading the alternate status register takes ~100 ns and has no side effects;
/// four reads is the conventional way to wait the 400 ns the spec requires
/// after a drive select before the status byte is meaningful.
fn selectDelay(ch: *const Channel) void {
    for (0..4) |_| _ = hal.inb(ch.control);
}

fn waitWhileBusy(ch: *const Channel) block.Error!Status {
    const deadline = hal.monotonicMicros() + TIMEOUT_US;
    while (true) {
        const status = readStatus(ch);
        if (!status.busy) return status;
        if (hal.monotonicMicros() > deadline) return error.Timeout;
    }
}

/// Wait for the drive to be ready to transfer, distinguishing "not yet" from
/// "failed", a drive that sets ERR and never sets DRQ would otherwise look
/// like a timeout.
fn waitForData(ch: *const Channel) block.Error!void {
    return waitForDataWithin(ch, TIMEOUT_US);
}

fn waitForDataWithin(ch: *const Channel, patience_us: u64) block.Error!void {
    const deadline = hal.monotonicMicros() + patience_us;
    while (true) {
        const status = readStatus(ch);
        if (!status.busy) {
            if (status.failed()) return error.IoError;
            if (status.request) return;
        }
        if (hal.monotonicMicros() > deadline) return error.Timeout;
    }
}

fn selectDrive(ch: *const Channel, slave: bool, lba_high_nibble: u8) void {
    const value: u8 = 0xE0 | (@as(u8, @intFromBool(slave)) << 4) | (lba_high_nibble & 0x0F);
    hal.outb(ch.io + REG_DRIVE, value);
    selectDelay(ch);
}

// ---------------------------------------------------------------------------
// Identification
// ---------------------------------------------------------------------------

/// Model strings come back as 16-bit words with the bytes swapped, space
/// padded.
fn decodeModel(words: []const u16, out: *[41]u8) usize {
    var n: usize = 0;
    for (words[27..47]) |w| {
        out[n] = @truncate(w >> 8);
        out[n + 1] = @truncate(w);
        n += 2;
    }
    out[40] = 0;
    while (n > 0 and (out[n - 1] == ' ' or out[n - 1] == 0)) n -= 1;
    return n;
}

fn identify(ch: *Channel, slave: bool) ?Drive {
    selectDrive(ch, slave, 0);

    // Zero the addressing registers: a non-zero signature here after IDENTIFY
    // means an ATAPI device answered, which we do not handle.
    hal.outb(ch.io + REG_SECTOR_COUNT, 0);
    hal.outb(ch.io + REG_LBA_LOW, 0);
    hal.outb(ch.io + REG_LBA_MID, 0);
    hal.outb(ch.io + REG_LBA_HIGH, 0);

    issue(ch, .identify);
    selectDelay(ch);

    // Status 0 means nothing is attached; the bus floats high or low with no
    // drive to drive it.
    if (@as(u8, @bitCast(readStatus(ch))) == 0) return null;

    const status = waitWhileBusy(ch) catch return null;
    if (status.err) return null;

    // ATAPI and SATA devices answer IDENTIFY with a signature in the LBA mid
    // and high registers instead of data.
    if (hal.inb(ch.io + REG_LBA_MID) != 0 or hal.inb(ch.io + REG_LBA_HIGH) != 0) return null;

    waitForDataWithin(ch, IDENTIFY_PATIENCE_US) catch return null;

    var words: [256]u16 = undefined;
    hal.insw(ch.io + REG_DATA, std.mem.sliceAsBytes(&words));

    // Words 60-61 hold the 28-bit LBA capacity. This is the only capacity
    // field used: the target device is ATA-4 and has no LBA48 field to read.
    const sectors: u64 = @as(u32, words[60]) | (@as(u32, words[61]) << 16);
    if (sectors == 0) return null;

    var drive = Drive{
        .channel = ch,
        .caps = capsOf(&words),
        .slave = slave,
        .sectors = sectors,
        .model = undefined,
        .model_len = 0,
        .name = undefined,
        .name_len = 0,
    };
    drive.model_len = decodeModel(&words, &drive.model);
    return drive;
}

// ---------------------------------------------------------------------------
// Transfers
// ---------------------------------------------------------------------------

fn setupTransfer(drive: *const Drive, lba: u64, count: u8) block.Error!void {
    if (lba + count > drive.sectors) return error.OutOfRange;
    // 28-bit LBA is the whole address space here; anything larger cannot be
    // expressed and must not be silently truncated.
    if (lba + count > 0x0FFF_FFFF) return error.OutOfRange;

    const ch = drive.channel;
    _ = try waitWhileBusy(ch);

    selectDrive(ch, drive.slave, @truncate((lba >> 24) & 0x0F));
    hal.outb(ch.io + REG_SECTOR_COUNT, count);
    hal.outb(ch.io + REG_LBA_LOW, @truncate(lba));
    hal.outb(ch.io + REG_LBA_MID, @truncate(lba >> 8));
    hal.outb(ch.io + REG_LBA_HIGH, @truncate(lba >> 16));
}

fn readBusStatus(bus: *const Bus) BusStatus {
    return @bitCast(hal.inb(bus.ports + BM_STATUS));
}

fn writeBusStatus(bus: *const Bus, value: BusStatus) void {
    hal.outb(bus.ports + BM_STATUS, @bitCast(value));
}

fn writeBusCommand(bus: *const Bus, value: BusCommand) void {
    hal.outb(bus.ports + BM_COMMAND, @bitCast(value));
}

/// Describe the first `len` bytes of the staging area to the controller.
///
/// Split only where an entry may not reach across a boundary, which for an
/// area this size is at most once.
fn describe(bus: *Bus, len: u32) void {
    var at: u32 = 0;
    var i: usize = 0;
    while (at < len) : (i += 1) {
        const base = bus.phys + at;
        const to_boundary = PRD_BOUNDARY - (base & (PRD_BOUNDARY - 1));
        const span = @min(len - at, to_boundary);
        bus.area.table[i] = .{
            .base = base,
            .count = @intCast(span),
            .last = at + span >= len,
        };
        at += span;
    }
}

/// How much of what is left one command may carry.
///
/// Whole sectors, because a command is counted in them, and never more than
/// the path can hold: a staging area for the controller, and the sector count
/// register otherwise. That register is eight bits and zero would mean 256,
/// so the count stops at 255 rather than leaning on the encoding.
fn chunkOf(ch: *const Channel, remaining: usize) usize {
    const sectors = remaining / block.SECTOR_SIZE;
    const limit = if (ch.bus != null) STAGING_BYTES / block.SECTOR_SIZE else 255;
    return @min(sectors, limit) * block.SECTOR_SIZE;
}

/// One command's worth, by whichever path the channel has.
fn run(drive: *Drive, lba: u64, chunk: Chunk) block.Error!void {
    if (drive.channel.bus != null) return runDma(drive, lba, chunk);
    return runPio(drive, lba, chunk);
}

fn runDma(drive: *Drive, lba: u64, chunk: Chunk) block.Error!void {
    const ch = drive.channel;
    const bus = &ch.bus.?;
    const span = chunk.bytes();
    const sectors: u8 = @intCast(span / block.SECTOR_SIZE);
    const to_memory = chunk == .in;

    // The controller can only be given an address this driver chose, so what
    // is going out is copied in first and what comes in is copied out after.
    if (chunk == .out) @memcpy(bus.area.staging[0..span], chunk.out);

    describe(bus, @intCast(span));
    hal.outl(bus.ports + BM_TABLE, bus.phys + @offsetOf(Dma, "table"));
    // Cleared before the command that will set them, so what is read
    // afterwards belongs to this transfer.
    writeBusStatus(bus, .{ .failed = true, .interrupt = true });
    writeBusCommand(bus, .{ .to_memory = to_memory });

    try setupTransfer(drive, lba, sectors);
    issue(ch, commandFor(chunk, .dma));
    writeBusCommand(bus, .{ .to_memory = to_memory, .start = true });

    const moved = awaitDma(bus, TIMEOUT_US);

    // Stopped, and the drive's own interrupt taken off the line by reading its
    // status, whatever the outcome was. A controller left running would write
    // into the staging area behind the next command.
    writeBusCommand(bus, .{});
    const status = readStatus(ch);
    writeBusStatus(bus, .{ .failed = true, .interrupt = true });

    try moved;
    if (status.failed()) return error.IoError;
    if (chunk == .in) @memcpy(chunk.in, bus.area.staging[0..span]);
}

/// Wait for the controller to have moved everything the table described.
///
/// Two things have to have happened: the controller has exhausted the table,
/// which lowers `active`, and the drive has finished with the data, which is
/// what raises `interrupt`. Either alone is a transfer still in progress.
fn awaitDma(bus: *const Bus, patience_us: u64) block.Error!void {
    const deadline = hal.monotonicMicros() + patience_us;
    while (true) {
        const status = readBusStatus(bus);
        if (status.failed) return error.IoError;
        if (!status.active and status.interrupt) return;
        if (hal.monotonicMicros() > deadline) return error.Timeout;
    }
}

fn runPio(drive: *Drive, lba: u64, chunk: Chunk) block.Error!void {
    const ch = drive.channel;
    const sectors: u8 = @intCast(chunk.bytes() / block.SECTOR_SIZE);
    try setupTransfer(drive, lba, sectors);
    issue(ch, commandFor(chunk, .pio));

    // Straight to the caller's memory: nothing but the CPU touches it, so
    // there is nothing to stage it for.
    var at: usize = 0;
    for (0..sectors) |_| {
        try waitForData(ch);
        switch (chunk) {
            .in => |b| hal.insw(ch.io + REG_DATA, b[at..][0..block.SECTOR_SIZE]),
            .out => |b| hal.outsw(ch.io + REG_DATA, b[at..][0..block.SECTOR_SIZE]),
        }
        at += block.SECTOR_SIZE;
    }
}

/// Cut a request into commands and run them in order.
fn transfer(drive: *Drive, lba: u64, whole: Chunk) block.Error!void {
    var at: usize = 0;
    while (at < whole.bytes()) {
        const span = chunkOf(drive.channel, whole.bytes() - at);
        // Less than a whole sector left is a caller asking for something the
        // medium cannot answer, not a transfer to keep trying.
        if (span == 0) return error.IoError;
        try run(drive, lba + at / block.SECTOR_SIZE, whole.part(at, span));
        at += span;
    }
}

fn readSectors(ctx: *anyopaque, lba: u64, buf: []u8) block.Error!void {
    const drive: *Drive = @ptrCast(@alignCast(ctx));
    return transfer(drive, lba, .{ .in = buf });
}

fn writeSectors(ctx: *anyopaque, lba: u64, buf: []const u8) block.Error!void {
    const drive: *Drive = @ptrCast(@alignCast(ctx));
    try transfer(drive, lba, .{ .out = buf });
    return flushCache(ctx);
}

/// Without this the drive may still be holding the write in its own cache, and
/// a power cut loses data the caller was told had landed.
fn flushCache(ctx: *anyopaque) block.Error!void {
    const drive: *Drive = @ptrCast(@alignCast(ctx));
    const ch = drive.channel;
    _ = try waitWhileBusy(ch);
    selectDrive(ch, drive.slave, 0);
    issue(ch, .flush_cache);
    const status = try waitWhileBusy(ch);
    if (status.failed()) return error.IoError;
}

const ops = block.Ops{
    .read = readSectors,
    .write = writeSectors,
    .flush = flushCache,
};

// ---------------------------------------------------------------------------
// Bring-up
// ---------------------------------------------------------------------------

/// The PCI function the task-file registers belong to. What the driver needs
/// from it is the bus-master window in its fourth BAR, and the identity that
/// says how its host timing is programmed.
pub const Host = struct {
    at: lib.pci.Location,
    vendor: u16,
    device: u16,
};

/// The controller's bus-master window, or null where there is none to use.
///
/// Read rather than assumed: where the firmware puts it is a fact about one
/// machine. A window that is not an I/O one, or that the firmware never
/// placed, leaves every channel moving words through the CPU.
fn busWindow(host: Host) ?u16 {
    const raw = pci.configRead32(host.at, lib.pci.BAR0_OFFSET + 4 * @sizeOf(u32));
    const bar: lib.pci.IoBar = @bitCast(raw);
    if (!bar.io_space or bar.base() == 0) return null;
    // Only now, when there is something to address memory for.
    pci.enableIoAndMaster(host.at);
    return @truncate(bar.base());
}

/// Give a channel its bus-master block, once something on it can use one.
///
/// The two channels' blocks are eight bytes apart in the one window. Memory
/// is taken here rather than at probe time so a machine whose drives will
/// only move words through the CPU pins none of it.
fn attachBus(ch: *Channel, window: ?u16, index: usize) void {
    if (ch.bus != null) return;
    const base = window orelse return;

    const frames = (@sizeOf(Dma) + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
    const phys = pmm.allocContiguous(frames, 0x1_0000_0000, .device) catch {
        console.warn("ata: {s} has no memory for a transfer area, moving words instead", .{ch.name});
        return;
    };

    ch.bus = .{
        .ports = base + @as(u16, @intCast(index)) * 8,
        .area = @ptrFromInt(hal.physToVirt(phys)),
        .phys = @intCast(phys),
    };
}

/// Probe both channels and register whatever is found.
pub fn init(host: Host) void {
    drive_count = 0;
    const window = busWindow(host);

    for (&channels, 0..) |*ch, index| {
        for ([_]bool{ false, true }) |slave| {
            if (drive_count >= drives.len) return;
            const found = identify(ch, slave) orelse continue;
            if (found.caps.dmaReady()) attachBus(ch, window, index);

            drives[drive_count] = found;
            const d = &drives[drive_count];

            // hd0, hd1, ... in discovery order, so the name does not encode a
            // channel layout that differs between machines.
            d.name[0] = 'h';
            d.name[1] = 'd';
            d.name[2] = '0' + @as(u8, @intCast(drive_count));
            d.name_len = 3;
            drive_count += 1;

            console.info("ata", "{s}: {s} {s} {s}, {d} MiB, {s}", .{
                d.nameSlice(),
                ch.name,
                if (slave) "slave" else "master",
                d.modelSlice(),
                d.sectors * block.SECTOR_SIZE / (1024 * 1024),
                if (ch.bus != null) "bus mastering" else "moving words",
            });

            const raw = block.Device{
                .name = d.nameSlice(),
                .ctx = d,
                .ops = &ops,
                .sectors = d.sectors,
            };

            // Everything above this point sees the cached device. Partitions
            // inherit its context, so they share one cache per disk, which is
            // what lets a lookup on one partition warm the FAT for another.
            const dev = bcache.wrap(raw) orelse raw;
            block.register(dev);

            // A disk with no partition table is a filesystem in its own right,
            // which is how most SD cards and USB sticks arrive.
            const parts = block.scanPartitions(&dev);
            if (parts == 0) block.markWholeDiskUsable(&dev);
        }
    }
}

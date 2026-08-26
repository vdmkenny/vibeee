//! ATA/PATA driver, PIO mode.
//!
//! Both legacy channels are probed, because the machines this targets disagree
//! about where the disk is: QEMU puts `-drive if=ide` on the primary channel,
//! while the Eee PC 701's soldered SSD sits on the **secondary** channel as
//! master (verified: 0x170/0x376, IRQ 15). Probing both costs four IDENTIFY
//! commands at boot and removes a per-machine assumption.
//!
//! PIO rather than DMA to begin with. The design calls for UDMA/66 through the
//! bus-master interface, and that is worth doing: 30 MB/s versus roughly 3
//! but PIO needs no PRD tables, no bus-master registers and no interrupt
//! plumbing, so it is the right thing to be correct first. DMA replaces the
//! transfer path behind the same interface.
//!
//! Constraints of the real device, from docs/research: ATA-4, **28-bit LBA
//! only** (no LBA48) and **no READ/WRITE MULTIPLE**. Nothing here uses either.

const bcache = @import("../../kernel/bcache.zig");
const block = @import("../../kernel/block.zig");
const console = @import("../../kernel/console.zig");
const hal = @import("../../kernel/hal.zig");
const port = @import("../../arch/x86/port.zig");

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

fn readStatus(ch: Channel) Status {
    return @bitCast(port.inb(ch.io + REG_STATUS));
}

fn issue(ch: Channel, cmd: Command) void {
    port.outb(ch.io + REG_COMMAND, @intFromEnum(cmd));
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
    flush_cache = 0xE7,
    identify = 0xEC,
};

/// Generous: a spun-down or confused drive can take seconds, and failing early
/// on a slow device is worse than waiting.
const TIMEOUT_US: u64 = 5_000_000;

const Channel = struct {
    io: u16,
    control: u16,
    name: []const u8,
};

const CHANNELS = [_]Channel{
    .{ .io = 0x1F0, .control = 0x3F6, .name = "primary" },
    .{ .io = 0x170, .control = 0x376, .name = "secondary" },
};

pub const Drive = struct {
    channel: Channel,
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
fn selectDelay(ch: Channel) void {
    for (0..4) |_| _ = port.inb(ch.control);
}

fn waitWhileBusy(ch: Channel) block.Error!Status {
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
fn waitForData(ch: Channel) block.Error!void {
    const deadline = hal.monotonicMicros() + TIMEOUT_US;
    while (true) {
        const status = readStatus(ch);
        if (!status.busy) {
            if (status.failed()) return error.IoError;
            if (status.request) return;
        }
        if (hal.monotonicMicros() > deadline) return error.Timeout;
    }
}

fn selectDrive(ch: Channel, slave: bool, lba_high_nibble: u8) void {
    const value: u8 = 0xE0 | (@as(u8, @intFromBool(slave)) << 4) | (lba_high_nibble & 0x0F);
    port.outb(ch.io + REG_DRIVE, value);
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

fn identify(ch: Channel, slave: bool) ?Drive {
    selectDrive(ch, slave, 0);

    // Zero the addressing registers: a non-zero signature here after IDENTIFY
    // means an ATAPI device answered, which we do not handle.
    port.outb(ch.io + REG_SECTOR_COUNT, 0);
    port.outb(ch.io + REG_LBA_LOW, 0);
    port.outb(ch.io + REG_LBA_MID, 0);
    port.outb(ch.io + REG_LBA_HIGH, 0);

    issue(ch, .identify);
    selectDelay(ch);

    // Status 0 means nothing is attached; the bus floats high or low with no
    // drive to drive it.
    if (@as(u8, @bitCast(readStatus(ch))) == 0) return null;

    const status = waitWhileBusy(ch) catch return null;
    if (status.err) return null;

    // ATAPI and SATA devices answer IDENTIFY with a signature in the LBA mid
    // and high registers instead of data.
    if (port.inb(ch.io + REG_LBA_MID) != 0 or port.inb(ch.io + REG_LBA_HIGH) != 0) return null;

    waitForData(ch) catch return null;

    var words: [256]u16 = undefined;
    for (&words) |*w| w.* = port.inw(ch.io + REG_DATA);

    // Words 60-61 hold the 28-bit LBA capacity. This is the only capacity
    // field used: the target device is ATA-4 and has no LBA48 field to read.
    const sectors: u64 = @as(u32, words[60]) | (@as(u32, words[61]) << 16);
    if (sectors == 0) return null;

    var drive = Drive{
        .channel = ch,
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
    port.outb(ch.io + REG_SECTOR_COUNT, count);
    port.outb(ch.io + REG_LBA_LOW, @truncate(lba));
    port.outb(ch.io + REG_LBA_MID, @truncate(lba >> 8));
    port.outb(ch.io + REG_LBA_HIGH, @truncate(lba >> 16));
}

fn readSectors(ctx: *anyopaque, lba: u64, buf: []u8) block.Error!void {
    const drive: *Drive = @ptrCast(@alignCast(ctx));
    const ch = drive.channel;
    var remaining = buf.len / block.SECTOR_SIZE;
    var offset: usize = 0;
    var current = lba;

    // A sector count of 0 means 256 to the hardware, so batches cap at 255 to
    // keep the encoding unambiguous.
    while (remaining > 0) {
        const batch: u8 = @intCast(@min(remaining, 255));
        try setupTransfer(drive, current, batch);
        issue(ch, .read_sectors);

        for (0..batch) |_| {
            try waitForData(ch);
            var i: usize = 0;
            while (i < block.SECTOR_SIZE) : (i += 2) {
                const w = port.inw(ch.io + REG_DATA);
                buf[offset + i] = @truncate(w);
                buf[offset + i + 1] = @truncate(w >> 8);
            }
            offset += block.SECTOR_SIZE;
        }

        current += batch;
        remaining -= batch;
    }
}

fn writeSectors(ctx: *anyopaque, lba: u64, buf: []const u8) block.Error!void {
    const drive: *Drive = @ptrCast(@alignCast(ctx));
    const ch = drive.channel;
    var remaining = buf.len / block.SECTOR_SIZE;
    var offset: usize = 0;
    var current = lba;

    while (remaining > 0) {
        const batch: u8 = @intCast(@min(remaining, 255));
        try setupTransfer(drive, current, batch);
        issue(ch, .write_sectors);

        for (0..batch) |_| {
            try waitForData(ch);
            var i: usize = 0;
            while (i < block.SECTOR_SIZE) : (i += 2) {
                const w = @as(u16, buf[offset + i]) | (@as(u16, buf[offset + i + 1]) << 8);
                port.outw(ch.io + REG_DATA, w);
            }
            offset += block.SECTOR_SIZE;
        }

        current += batch;
        remaining -= batch;
    }

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

/// Probe both channels and register whatever is found.
pub fn init() void {
    drive_count = 0;

    for (CHANNELS) |ch| {
        for ([_]bool{ false, true }) |slave| {
            if (drive_count >= drives.len) return;
            const found = identify(ch, slave) orelse continue;

            drives[drive_count] = found;
            const d = &drives[drive_count];

            // hd0, hd1, ... in discovery order, so the name does not encode a
            // channel layout that differs between machines.
            d.name[0] = 'h';
            d.name[1] = 'd';
            d.name[2] = '0' + @as(u8, @intCast(drive_count));
            d.name_len = 3;
            drive_count += 1;

            console.debug("ata", "{s}: {s} {s} {s}, {d} MiB", .{
                d.nameSlice(),
                ch.name,
                if (slave) "slave" else "master",
                d.modelSlice(),
                d.sectors * block.SECTOR_SIZE / (1024 * 1024),
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

pub fn driveCount() usize {
    return drive_count;
}

//! The flag saying a volume was unmounted cleanly.
//!
//! Cleared before a mount's first write, set after its last write reaches the
//! medium. A volume found with it clear was interrupted, and `fat/check.zig`
//! runs before it is used.
//!
//! Two flags, in two places, because two families of system read different
//! ones: the top bits of the second table entry (the specification's), and a
//! byte in the boot sector (most Unix implementations'). Both are written.
//! Either one clear counts as dirty.
//!
//! FAT12 has neither, so it records nothing and `State` has a third case.

const std = @import("std");
const block = @import("../block.zig");
const table = @import("alloc.zig");

const Table = table.Table;
const Error = table.Error;
const Kind = table.Kind;

/// What the medium says about the last time this volume was used.
pub const State = enum {
    /// Unmounted in an orderly way, or never written since it was made.
    clean,
    /// Written to and not unmounted: a power cut, a yank or a crash.
    dirty,
    /// The volume has nowhere to record it. FAT12 only.
    unrecorded,
};

/// What entry one holds above the bits a chain value would use.
///
/// A union over the same enum the rest of the driver uses, so a width that
/// records nothing is expressed by the type rather than by a check repeated
/// at every call.
const Flags = union(Kind) {
    /// Twelve-bit entries have no room, and predate both flags.
    fat12: void,
    fat16: Narrow,
    fat32: Wide,

    /// Sixteen-bit entries. The two flags occupy the top, above the bits a
    /// chain value uses, which are carried through unchanged.
    const Narrow = packed struct(u16) {
        chain: u14,
        errors_clear: bool,
        clean: bool,
    };

    /// The same two flags over the twenty-eight meaningful bits of a
    /// thirty-two bit entry. The four above them are reserved and are not
    /// described here: `fat/alloc.zig` preserves them on every store.
    const Wide = packed struct(u28) {
        chain: u26,
        errors_clear: bool,
        clean: bool,
    };

    /// Whether the volume records a clean unmount, or null for a width that
    /// cannot record one.
    fn isClean(self: Flags) ?bool {
        return switch (self) {
            .fat12 => null,
            inline .fat16, .fat32 => |width| width.clean,
        };
    }

    /// The same flags with the clean bit set to `is_clean`.
    fn withClean(self: Flags, is_clean: bool) Flags {
        return switch (self) {
            .fat12 => .fat12,
            inline .fat16, .fat32 => |width, tag| blk: {
                var changed = width;
                changed.clean = is_clean;
                break :blk @unionInit(Flags, @tagName(tag), changed);
            },
        };
    }
};

/// The boot sector's byte for the same fact, laid out as the systems that
/// read it expect. Set means dirty, the opposite sense to the table's flag.
const BootFlags = packed struct(u8) {
    dirty: bool,
    had_errors: bool,
    unused: u6,
};

/// The front of a boot sector up to and including that byte.
///
/// The two layouts differ only in how much parameter block precedes the same
/// three fields, so the byte's position is derived from this struct rather
/// than written as an offset separate from what explains it.
fn BootTail(comptime header: usize) type {
    return extern struct {
        header: [header]u8,
        drive: u8,
        flags: BootFlags,
    };
}

/// How far into the boot sector the flags byte is, or null for a width that
/// has none.
fn bootFlagsAt(kind: Kind) ?usize {
    return switch (kind) {
        .fat12 => null,
        // The older layouts put the parameter block in thirty-six bytes.
        .fat16 => @offsetOf(BootTail(36), "flags"),
        // FAT32 grew it to sixty-four before the same three fields.
        .fat32 => @offsetOf(BootTail(64), "flags"),
    };
}

fn readFlags(t: *Table) Error!Flags {
    const entry = try table.reserved(t, .flags);
    return switch (t.kind) {
        .fat12 => .fat12,
        .fat16 => .{ .fat16 = @bitCast(@as(u16, @truncate(entry))) },
        .fat32 => .{ .fat32 = @bitCast(@as(u28, @truncate(entry))) },
    };
}

fn writeFlags(t: *Table, flags: Flags) Error!void {
    try table.setReserved(t, .flags, switch (flags) {
        .fat12 => return,
        .fat16 => |width| @as(u16, @bitCast(width)),
        .fat32 => |width| @as(u28, @bitCast(width)),
    });
}

/// What the volume records about its last use.
///
/// Either flag reading dirty means dirty. They are written together, so a
/// volume where they disagree was interrupted between the two writes, which
/// is the case they exist to catch.
pub fn state(t: *Table) Error!State {
    const by_table = (try readFlags(t)).isClean() orelse return .unrecorded;
    if (!by_table) return .dirty;

    var sector: [block.SECTOR_SIZE]u8 = undefined;
    t.dev.read(0, &sector) catch return error.Io;
    const boot: *const BootFlags = @ptrCast(&sector[bootFlagsAt(t.kind).?]);

    return if (boot.dirty) .dirty else .clean;
}

/// Record that the volume is clean, or that it is about to be written.
///
/// Does nothing on FAT12, which has nowhere to record it. Both places are
/// written; a volume interrupted between them has them disagreeing, and
/// `state` reads that as dirty.
pub fn mark(t: *Table, is_clean: bool) Error!void {
    const flags = try readFlags(t);
    if (flags == .fat12) return;
    try writeFlags(t, flags.withClean(is_clean));

    var sector: [block.SECTOR_SIZE]u8 = undefined;
    t.dev.read(0, &sector) catch return error.Io;
    const boot: *BootFlags = @ptrCast(&sector[bootFlagsAt(t.kind).?]);
    if (boot.dirty == !is_clean) return;

    boot.dirty = !is_clean;
    t.dev.write(0, &sector) catch return error.Io;
}

const testing = std.testing;

/// A volume in memory, with enough of one for the flags to be read and
/// written.
const Fake = struct {
    bytes: []u8,

    fn read(ctx: *anyopaque, lba: u64, buf: []u8) block.Error!void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const at = lba * block.SECTOR_SIZE;
        if (at + buf.len > self.bytes.len) return error.OutOfRange;
        @memcpy(buf, self.bytes[at..][0..buf.len]);
    }

    fn write(ctx: *anyopaque, lba: u64, buf: []const u8) block.Error!void {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        const at = lba * block.SECTOR_SIZE;
        if (at + buf.len > self.bytes.len) return error.OutOfRange;
        @memcpy(self.bytes[at..][0..buf.len], buf);
    }

    const ops = block.Ops{ .read = &read, .write = &write };
};

fn fakeTable(kind: Kind, fake: *Fake, dev: *block.Device) Table {
    dev.* = .{
        .name = "fake",
        .ctx = fake,
        .ops = &Fake.ops,
        .sectors = fake.bytes.len / block.SECTOR_SIZE,
    };
    return .{
        .dev = dev,
        .kind = kind,
        .bytes_per_sector = block.SECTOR_SIZE,
        .first_fat_sector = 1,
        .sectors_per_fat = 1,
        .fat_count = 2,
        .cluster_count = 16,
    };
}

test "a volume marked clean reads back clean, and dirty reads back dirty" {
    for ([_]Kind{ .fat16, .fat32 }) |kind| {
        var bytes: [4 * block.SECTOR_SIZE]u8 = @splat(0);
        var fake = Fake{ .bytes = &bytes };
        var dev: block.Device = undefined;
        var t = fakeTable(kind, &fake, &dev);

        // A table whose flag is clear reads as dirty, which is what an
        // unfinished write leaves.
        try testing.expectEqual(State.dirty, try state(&t));

        try mark(&t, true);
        try testing.expectEqual(State.clean, try state(&t));

        try mark(&t, false);
        try testing.expectEqual(State.dirty, try state(&t));
    }
}

test "either flag alone is enough to call a volume dirty" {
    // The case the two flags catch between them: one written, then power
    // lost before the other. Either way the volume is not clean.
    for ([_]Kind{ .fat16, .fat32 }) |kind| {
        var bytes: [4 * block.SECTOR_SIZE]u8 = @splat(0);
        var fake = Fake{ .bytes = &bytes };
        var dev: block.Device = undefined;
        var t = fakeTable(kind, &fake, &dev);

        try mark(&t, true);
        try testing.expectEqual(State.clean, try state(&t));

        // The boot sector says dirty while the table still says clean.
        const boot: *BootFlags = @ptrCast(&bytes[bootFlagsAt(kind).?]);
        boot.dirty = true;
        try testing.expectEqual(State.dirty, try state(&t));

        // And the other way round.
        boot.dirty = false;
        try testing.expectEqual(State.clean, try state(&t));
        try writeFlags(&t, (try readFlags(&t)).withClean(false));
        try testing.expectEqual(State.dirty, try state(&t));
    }
}

test "marking a volume leaves what a chain would use alone" {
    // The flags share their entry with bits that are not flags. Clearing
    // those would write a value the format reserves, which other
    // implementations read.
    var bytes: [4 * block.SECTOR_SIZE]u8 = @splat(0);
    var fake = Fake{ .bytes = &bytes };
    var dev: block.Device = undefined;
    var t = fakeTable(.fat32, &fake, &dev);

    const before = try readFlags(&t);
    try mark(&t, true);
    const after = try readFlags(&t);

    try testing.expectEqual(before.fat32.chain, after.fat32.chain);
    try testing.expectEqual(before.fat32.errors_clear, after.fat32.errors_clear);
    try testing.expect(after.fat32.clean);
}

test "marking a volume does not disturb the free count" {
    // Entry one is not a cluster. Counting a write of it as an allocation
    // would move the free count on every mount and unmount, and that count
    // is what tells a caller the volume is full.
    var bytes: [4 * block.SECTOR_SIZE]u8 = @splat(0);
    var fake = Fake{ .bytes = &bytes };
    var dev: block.Device = undefined;
    var t = fakeTable(.fat32, &fake, &dev);

    t.free_known = 9;
    try mark(&t, true);
    try mark(&t, false);
    try testing.expectEqual(@as(?u32, 9), t.free_known);
}

test "a FAT12 volume records nothing and is not written to" {
    var bytes: [4 * block.SECTOR_SIZE]u8 = @splat(0);
    var fake = Fake{ .bytes = &bytes };
    var dev: block.Device = undefined;
    var t = fakeTable(.fat12, &fake, &dev);

    try testing.expectEqual(State.unrecorded, try state(&t));

    // And marking leaves the medium exactly as it was.
    const before = bytes;
    try mark(&t, true);
    try testing.expectEqualSlices(u8, &before, &bytes);
}

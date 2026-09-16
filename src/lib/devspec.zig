//! Manifest lines that name devices.
//!
//! A driver says which devices it serves as a comma-separated list of
//! specs, and each spec is a prefix and the numbers that follow it:
//! `pci:8086:265c`, `usb-class:08:06:50`. A field may name several numbers
//! separated by `|`: `pci:8086:1229|1209` is two parts of one maker. Which
//! numbers those are is the bus's business. The shape of the line is not,
//! and it is the same wherever a bus writes one, so it is here rather than
//! in each of them.

const std = @import("std");

/// One spec, read field by field.
pub const Spec = struct {
    fields: std.mem.SplitIterator(u8, .scalar),

    /// A spec's fields, when it names `prefix`. Null when it names
    /// something else, which is how one bus passes over another's lines.
    pub fn under(text: []const u8, prefix: []const u8) ?Spec {
        var fields = std.mem.splitScalar(u8, text, ':');
        const named = trim(fields.next() orelse return null);
        if (!std.mem.eql(u8, named, prefix)) return null;
        return .{ .fields = fields };
    }

    /// Whether the next field is this number, or lists it. A spec that
    /// stops early names less than it was asked about, and names nothing
    /// here.
    pub fn is(self: *Spec, value: u32) bool {
        return lists(self.fields.next() orelse return false, value);
    }

    /// Whether the next field is this number, or is not there at all: the
    /// last field of a spec is often left off, and left off it fits every
    /// value of itself. That is how one driver serves a whole family
    /// without listing its members.
    pub fn isOrAbsent(self: *Spec, value: u32) bool {
        const field = trim(self.fields.next() orelse return true);
        if (field.len == 0) return true;
        return lists(field, value);
    }
};

/// Whether a field names `value` among the numbers it separates with `|`.
fn lists(field: []const u8, value: u32) bool {
    var numbers = std.mem.splitScalar(u8, field, '|');
    while (numbers.next()) |number| {
        const listed = std.fmt.parseInt(u32, trim(number), 16) catch continue;
        if (listed == value) return true;
    }
    return false;
}

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, &std.ascii.whitespace);
}

/// Whether any spec in `match` fits, as `fits` decides. Specs are
/// separated by commas: one driver and one program can serve several
/// devices, and saying so once beats a manifest each.
pub fn any(
    match: []const u8,
    context: anytype,
    comptime fits: fn (@TypeOf(context), []const u8) bool,
) bool {
    var specs = std.mem.splitScalar(u8, match, ',');
    while (specs.next()) |spec| {
        const trimmed = trim(spec);
        if (trimmed.len != 0 and fits(context, trimmed)) return true;
    }
    return false;
}

const testing = std.testing;

test "a spec is read under its own prefix and nobody else's" {
    try testing.expect(Spec.under("pci:8086:265c", "usb") == null);
    try testing.expect(Spec.under("pci:8086:265c", "pci-class") == null);

    var fields = Spec.under(" pci : 8086 : 265c ", "pci").?;
    try testing.expect(fields.is(0x8086));
    try testing.expect(fields.is(0x265C));
}

test "a field that is not there names nothing, unless it may be left off" {
    var short = Spec.under("pci:8086", "pci").?;
    try testing.expect(short.is(0x8086));
    try testing.expect(!short.is(0x265C));

    // The last field left off fits every value of itself.
    var open = Spec.under("pci-class:0c:03", "pci-class").?;
    try testing.expect(open.is(0x0C));
    try testing.expect(open.is(0x03));
    try testing.expect(open.isOrAbsent(0x20));
    var named = Spec.under("pci-class:0c:03:20", "pci-class").?;
    try testing.expect(named.is(0x0C));
    try testing.expect(named.is(0x03));
    try testing.expect(named.isOrAbsent(0x20));
    var other = Spec.under("pci-class:0c:03:00", "pci-class").?;
    try testing.expect(other.is(0x0C));
    try testing.expect(other.is(0x03));
    try testing.expect(!other.isOrAbsent(0x20));
}

test "a field lists several numbers, and fits any of them" {
    var parts = Spec.under("pci:8086:1229|1209 | 2449", "pci").?;
    try testing.expect(parts.is(0x8086));
    try testing.expect(parts.is(0x2449));

    var other = Spec.under("pci:8086:1229|1209", "pci").?;
    try testing.expect(other.is(0x8086));
    try testing.expect(!other.is(0x1029));

    var empty = Spec.under("pci:8086:|", "pci").?;
    try testing.expect(empty.is(0x8086));
    try testing.expect(!empty.is(0));

    var interfaces = Spec.under("pci-class:0c:03:10|00", "pci-class").?;
    try testing.expect(interfaces.is(0x0C));
    try testing.expect(interfaces.is(0x03));
    try testing.expect(interfaces.isOrAbsent(0x00));
}

test "one line names several devices, and an empty one names none" {
    const Wanted = struct {
        fn fits(want: u32, spec: []const u8) bool {
            var fields = Spec.under(spec, "pci") orelse return false;
            return fields.is(want);
        }
    };
    try testing.expect(any("pci:8086, pci:10ec", @as(u32, 0x10EC), Wanted.fits));
    try testing.expect(any("pci:8086", @as(u32, 0x8086), Wanted.fits));
    try testing.expect(!any("pci:8086, pci:10ec", @as(u32, 0x1234), Wanted.fits));
    try testing.expect(!any("", @as(u32, 0x8086), Wanted.fits));
    try testing.expect(!any(" , , ", @as(u32, 0x8086), Wanted.fits));
}

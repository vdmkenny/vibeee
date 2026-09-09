//! The ustar archive format: one header block per file, its bytes after it,
//! everything rounded up to five hundred and twelve.
//!
//! A machine that cannot hand a set of files to another machine is one you
//! cannot get work off, and ustar is the shape every other machine already
//! reads. Nothing is compressed: there is no compressor here, and on this
//! processor one would cost more time than it saves medium.
//!
//! Numbers in the format are octal written as text, which is the part worth
//! having tests for, so the reading and the writing of a header live here and
//! not in the commands that use them.

const std = @import("std");

/// Everything in the format is a multiple of this.
pub const BLOCK = 512;

/// The longest name a header holds on its own. A longer path is split across
/// the prefix field, which is what the format has it for.
pub const NAME = 100;
pub const PREFIX = 155;

/// What an entry is. The format has more kinds; a system with no links and no
/// devices to archive has no use for them, and one it does not recognise is
/// skipped rather than guessed at.
pub const Kind = enum(u8) {
    file = '0',
    /// Written by archivers that predate the kind field.
    old_file = 0,
    directory = '5',
    _,

    pub fn isFile(self: Kind) bool {
        return self == .file or self == .old_file;
    }
};

/// One header block, as it sits on the medium.
pub const Header = extern struct {
    name: [NAME]u8,
    mode: [8]u8,
    uid: [8]u8,
    gid: [8]u8,
    size: [12]u8,
    mtime: [12]u8,
    checksum: [8]u8,
    kind: u8,
    linked: [NAME]u8,
    magic: [6]u8,
    version: [2]u8,
    user: [32]u8,
    group: [32]u8,
    major: [8]u8,
    minor: [8]u8,
    prefix: [PREFIX]u8,
    _tail: [12]u8,

    pub const MAGIC = "ustar\x00";
    pub const VERSION = "00";

    /// What a directory and a file are given. Nothing here has an owner or
    /// permissions, so these are what another machine will read as sensible
    /// rather than a claim about this one.
    const FILE_MODE = 0o644;
    const DIRECTORY_MODE = 0o755;
};

comptime {
    if (@sizeOf(Header) != BLOCK) @compileError("a ustar header is one block");
}

/// What a header says, put the way a caller wants it.
pub const Entry = struct {
    /// Points into the caller's own name buffer.
    path: []const u8,
    size: u64,
    mtime: i64,
    kind: Kind,
};

pub const Error = error{
    /// The block is not a header: wrong magic, or a checksum that does not
    /// agree with the bytes around it.
    NotAHeader,
    /// The path is longer than a header can carry, even split.
    NameTooLong,
};

/// How many whole blocks `bytes` occupies, which is what follows a header.
pub fn blocksFor(bytes: u64) u64 {
    return (bytes + BLOCK - 1) / BLOCK;
}

/// Fill `into` with a header for one entry.
pub fn write(into: *Header, path: []const u8, size: u64, mtime: i64, kind: Kind) Error!void {
    into.* = std.mem.zeroes(Header);

    const split = splitName(path) orelse return Error.NameTooLong;
    @memcpy(into.name[0..split.name.len], split.name);
    @memcpy(into.prefix[0..split.prefix.len], split.prefix);

    writeOctal(&into.mode, if (kind == .directory) Header.DIRECTORY_MODE else Header.FILE_MODE);
    writeOctal(&into.uid, 0);
    writeOctal(&into.gid, 0);
    writeOctal(&into.size, if (kind == .directory) 0 else size);
    writeOctal(&into.mtime, @intCast(@max(mtime, 0)));
    into.kind = @intFromEnum(kind);
    @memcpy(&into.magic, Header.MAGIC);
    @memcpy(&into.version, Header.VERSION);

    // Last, because it is the sum of everything above it.
    seal(into);
}

/// What a block says, or nothing at all when it is one of the zero blocks
/// that end an archive.
pub fn read(block: *const Header, into: []u8) Error!?Entry {
    if (isEmpty(block)) return null;
    if (!std.mem.eql(u8, block.magic[0..5], Header.MAGIC[0..5])) return Error.NotAHeader;
    if (sumOf(block) != (readOctal(&block.checksum) orelse return Error.NotAHeader)) return Error.NotAHeader;

    const prefix = text(&block.prefix);
    const name = text(&block.name);
    if (prefix.len + name.len + 1 > into.len) return Error.NameTooLong;

    var len: usize = 0;
    if (prefix.len != 0) {
        @memcpy(into[0..prefix.len], prefix);
        into[prefix.len] = '/';
        len = prefix.len + 1;
    }
    @memcpy(into[len..][0..name.len], name);
    len += name.len;

    return .{
        .path = into[0..len],
        .size = readOctal(&block.size) orelse 0,
        .mtime = @intCast(readOctal(&block.mtime) orelse 0),
        .kind = @enumFromInt(block.kind),
    };
}

/// A block of nothing, which is how an archive says it has ended.
fn isEmpty(block: *const Header) bool {
    const bytes = std.mem.asBytes(block);
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

/// The checksum, written where it goes.
fn seal(block: *Header) void {
    const sum = sumOf(block);
    // This one field is written differently from every other number in the
    // format: six digits, a NUL, then a space. Every reader accepts that
    // spelling and not every reader accepts the others.
    _ = std.fmt.bufPrint(block.checksum[0..7], "{o:0>6}\x00", .{sum}) catch unreachable;
    block.checksum[7] = ' ';
}

/// The sum of every byte of the header, with the checksum field counted as
/// spaces, which is the field's own definition.
fn sumOf(block: *const Header) u64 {
    const bytes = std.mem.asBytes(block);
    const at = @offsetOf(Header, "checksum");

    var sum: u64 = 0;
    for (bytes, 0..) |byte, i| {
        sum += if (i >= at and i < at + 8) ' ' else byte;
    }
    return sum;
}

/// Where a path is cut so both halves fit. The cut falls on a separator,
/// because the two halves are joined with one when the archive is read.
fn splitName(path: []const u8) ?struct { prefix: []const u8, name: []const u8 } {
    if (path.len <= NAME) return .{ .prefix = "", .name = path };
    if (path.len > NAME + PREFIX + 1) return null;

    // The last separator that leaves a short enough tail, so the prefix takes
    // as much as it can and the name is what is left.
    var at = path.len - NAME - 1;
    while (at < path.len) : (at += 1) {
        if (path[at] == '/') break;
    } else return null;

    if (at > PREFIX) return null;
    return .{ .prefix = path[0..at], .name = path[at + 1 ..] };
}

/// A field's text, which ends at the first NUL or space the format wrote.
fn text(field: []const u8) []const u8 {
    for (field, 0..) |byte, i| {
        if (byte == 0) return field[0..i];
    }
    return field;
}

/// A number as the format writes them: octal digits, right-aligned in the
/// field with leading zeros, and a NUL after them.
fn writeOctal(field: []u8, value: u64) void {
    @memset(field, '0');
    field[field.len - 1] = 0;

    var left = value;
    var at = field.len - 1;
    while (at > 0) {
        at -= 1;
        field[at] = '0' + @as(u8, @intCast(left % 8));
        left /= 8;
        if (left == 0) break;
    }
}

/// A number back out of a field, or nothing when it holds something that is
/// not one.
fn readOctal(field: []const u8) ?u64 {
    var value: u64 = 0;
    var digits: usize = 0;
    for (field) |byte| {
        if (byte == 0 or byte == ' ') {
            // Trailing padding ends the number; leading padding is skipped.
            if (digits != 0) break;
            continue;
        }
        if (byte < '0' or byte > '7') return null;
        value = value * 8 + (byte - '0');
        digits += 1;
    }
    return if (digits == 0) null else value;
}

const testing = std.testing;

test "a header reads back what was written into it" {
    var block: Header = undefined;
    try write(&block, "notes/today.txt", 5263, 1_789_101_441, .file);

    var name: [256]u8 = undefined;
    const entry = (try read(&block, &name)).?;

    try testing.expectEqualStrings("notes/today.txt", entry.path);
    try testing.expectEqual(@as(u64, 5263), entry.size);
    try testing.expectEqual(@as(i64, 1_789_101_441), entry.mtime);
    try testing.expectEqual(Kind.file, entry.kind);
}

test "a directory carries no size, whatever it was given" {
    var block: Header = undefined;
    try write(&block, "pictures", 4096, 0, .directory);

    var name: [256]u8 = undefined;
    const entry = (try read(&block, &name)).?;
    try testing.expectEqual(@as(u64, 0), entry.size);
    try testing.expectEqual(Kind.directory, entry.kind);
}

test "a long path is split across the prefix and joined again" {
    const long = "home/pictures/holidays/nineteen-ninety-nine/scanned/from-the-box/" ++
        "the-one-with-everybody-in-it-including-the-dog-and-the-car.jpeg";
    try testing.expect(long.len > NAME);

    var block: Header = undefined;
    try write(&block, long, 1, 0, .file);
    try testing.expect(text(&block.prefix).len != 0);

    var name: [256]u8 = undefined;
    const entry = (try read(&block, &name)).?;
    try testing.expectEqualStrings(long, entry.path);
}

test "a block of nothing is the end rather than an entry" {
    const block = std.mem.zeroes(Header);
    var name: [256]u8 = undefined;
    try testing.expectEqual(@as(?Entry, null), try read(&block, &name));
}

test "a block that is not a header is refused rather than guessed at" {
    var block: Header = undefined;
    try write(&block, "a", 1, 0, .file);

    // A byte changed anywhere puts the checksum out.
    var damaged = block;
    damaged.name[0] = 'b';
    var name: [256]u8 = undefined;
    try testing.expectError(Error.NotAHeader, read(&damaged, &name));

    // So does something that was never a header.
    var noise = std.mem.zeroes(Header);
    noise.name[0] = 0xFF;
    try testing.expectError(Error.NotAHeader, read(&noise, &name));
}

test "the blocks a file occupies are whole and enough" {
    try testing.expectEqual(@as(u64, 0), blocksFor(0));
    try testing.expectEqual(@as(u64, 1), blocksFor(1));
    try testing.expectEqual(@as(u64, 1), blocksFor(BLOCK));
    try testing.expectEqual(@as(u64, 2), blocksFor(BLOCK + 1));
}

test "octal fields carry the numbers a header actually holds" {
    var field: [12]u8 = undefined;
    writeOctal(&field, 5263);
    try testing.expectEqual(@as(?u64, 5263), readOctal(&field));

    writeOctal(&field, 0);
    try testing.expectEqual(@as(?u64, 0), readOctal(&field));

    // Space padded, which is how other archivers write them.
    try testing.expectEqual(@as(?u64, 8), readOctal("10 "));
    try testing.expectEqual(@as(?u64, null), readOctal("        "));
    try testing.expectEqual(@as(?u64, null), readOctal("9"));
}

test "a header is the bytes another machine's archiver reads" {
    // Checked once against a real archive: what this writes here is what
    // `tar tvf` listed with the right mode, size and time, and what it
    // extracted correctly. The fields are pinned so a change that would stop
    // another machine reading our archives fails here instead of in the post.
    var block: Header = undefined;
    try write(&block, "notes/today.txt", 18, 1_789_101_441, .file);

    try testing.expectEqualStrings("notes/today.txt", text(&block.name));
    try testing.expectEqualStrings("ustar", text(&block.magic));
    try testing.expectEqualSlices(u8, "00", &block.version);
    try testing.expectEqualStrings("0000644", text(&block.mode));
    try testing.expectEqualStrings("00000000022", text(&block.size));
    try testing.expectEqualStrings("15250702601", text(&block.mtime));
    try testing.expectEqual(@as(u8, '0'), block.kind);

    // Six octal digits, a NUL, then a space: the one field the format spells
    // differently from the rest, and the spelling every reader accepts.
    try testing.expectEqual(@as(u8, 0), block.checksum[6]);
    try testing.expectEqual(@as(u8, ' '), block.checksum[7]);
    try testing.expectEqual(sumOf(&block), readOctal(&block.checksum).?);

    var directory: Header = undefined;
    try write(&directory, "pictures", 0, 0, .directory);
    try testing.expectEqualStrings("0000755", text(&directory.mode));
    try testing.expectEqual(@as(u8, '5'), directory.kind);
}

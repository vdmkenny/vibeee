//! Files read and written whole.
//!
//! What a program does with a file it is going to decode, show or parse:
//! open it, read as much as fits, close it. Written once so the loop that
//! keeps reading until the file or the room runs out lives in one place,
//! and the mistake it guards against, a short read taken for the end, can
//! be made only here. `readWhole` takes as much as fits, for a head or a
//! caller that sizes its room from the file; `readEntire` refuses a file
//! that does not fit, for a document that is read back and written again.
//! `copy` and `put` are the whole-file moves the other way round: the same
//! loop, writing.

const std = @import("std");
const dir = @import("dir.zig");
const sys = @import("sys");

/// Read the file at `path` into `into`, as much of it as fits, and say how
/// much. Null for a file that cannot be opened; a file that is there but
/// empty reads as nothing at all.
pub fn readWhole(path: []const u8, into: []u8) ?usize {
    const handle = sys.open(path, .{}) catch return null;
    defer sys.close(handle);
    const filled = fill(handle, into);
    return if (filled.failed) null else filled.read;
}

/// Read `into.len` bytes of the file at `path` starting `from` bytes in, and
/// say how much came back. Null for a file that cannot be opened or seeked.
///
/// What a caller with a head in hand and an offset out of it wants: a raw
/// photograph keeps the picture it carries megabytes past its own tables, and
/// reading that stretch is the difference between a preview and reading a
/// twelve megabyte file to take one megabyte out of the middle.
pub fn readAt(path: []const u8, from: usize, into: []u8) ?usize {
    const handle = sys.open(path, .{}) catch return null;
    defer sys.close(handle);

    _ = sys.seek(handle, @intCast(from), sys.SEEK_SET) catch return null;
    const filled = fill(handle, into);
    return if (filled.failed) null else filled.read;
}

/// What a file is, without reading any of it.
pub const Facts = struct { size: usize, mtime: i64 };

/// How large a file is and when it was written, or nothing for one that
/// cannot be asked about.
///
/// What a program does before deciding whether to read a file at all: a
/// picture too large to hold is refused for the room it would have taken
/// rather than after taking it. The record the kernel answers with is decoded
/// here, because the buffer it lands in is a frame nobody should be handing
/// back a pointer into.
pub fn factsOf(path: []const u8) ?Facts {
    var record: [512]u8 = undefined;
    const told = sys.stat(path, &record) catch return null;
    const entry = sys.Dirent.decode(&record, told) orelse return null;
    return .{ .size = entry.size, .mtime = entry.mtime };
}

pub const EntireError = error{ NoFile, TooBig, Unreadable };

/// Read the file at `path` into `into` entire, and say how long it is. A
/// file with more in it than the room is refused rather than cut short, so
/// what comes back is the file or nothing, and a document read this way is
/// never written back shorter than it was.
pub fn readEntire(path: []const u8, into: []u8) EntireError!usize {
    const handle = sys.open(path, .{}) catch return error.NoFile;
    defer sys.close(handle);
    const filled = fill(handle, into);
    if (filled.failed) return error.Unreadable;
    const read = filled.read;
    if (read < into.len) return read;
    // The room is full. One byte more tells a file that fits exactly from
    // one that goes on.
    var more: [1]u8 = undefined;
    if ((sys.read(handle, &more) catch 0) > 0) return error.TooBig;
    return read;
}

/// How much was read, and whether a read failed rather than ended.
const Filled = struct { read: usize, failed: bool };

/// Read from `handle` until the file or the room runs out.
///
/// A read that failed and a read that ended look alike to a loop that
/// stops on "nothing more", and taking the first for the second is the
/// mistake this module exists to make only once: a file half read would
/// come back as a whole file that happened to be short, and settings half
/// applied read as settings applied.
fn fill(handle: u32, into: []u8) Filled {
    var read: usize = 0;
    while (read < into.len) {
        const n = sys.read(handle, into[read..]) catch return .{ .read = read, .failed = true };
        if (n == 0) break;
        read += n;
    }
    return .{ .read = read, .failed = false };
}

/// Write `bytes` as the whole of the file at `path`, creating it or
/// replacing what was there.
///
/// The other end of `readEntire`: a program that read a small file, changed
/// what it says and is putting it back. A short write is not a failed one, so
/// the loop that finishes the job lives here rather than in whoever wanted it.
pub fn put(path: []const u8, bytes: []const u8) CopyError!void {
    const handle = sys.open(path, .{ .write = true, .create = true, .truncate = true }) catch
        return error.CannotCreate;
    defer sys.close(handle);

    return writeAll(handle, bytes);
}

/// Write the whole of `bytes`, going round again for a short write.
///
/// A short write is not a failed one, and taking the first for the second is
/// the writing half of the mistake this module exists to make only once: a
/// file written short comes back as a file that was always that length.
fn writeAll(handle: u32, bytes: []const u8) CopyError!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = sys.write(handle, bytes[written..]) catch return error.NoSpace;
        if (n == 0) return error.NoSpace;
        written += n;
    }
}

pub const CopyError = error{
    /// The source and the destination name the same file, which would empty
    /// it before a byte had been read.
    Itself,
    /// Directories are walked and created, which is a different job.
    Directory,
    NoFile,
    CannotCreate,
    Unreadable,
    NoSpace,
};

/// How much is moved at once. A page, which is what the filesystem reads and
/// writes in anyway, so a larger buffer would buy nothing but memory. Beside
/// the function rather than on its frame: the user stack is thirty-two
/// kilobytes for everything.
var block: [4096]u8 = undefined;

/// Copy the whole of one file onto another, creating it.
///
/// Written here rather than in whichever command wanted it first: a file
/// manager, a copy command and a program filing its own work all want the
/// same loop, and a short write taken for a failure is the mistake it exists
/// to make only once.
pub fn copy(from: []const u8, to: []const u8) CopyError!void {
    if (std.mem.eql(u8, from, to)) return error.Itself;
    if (dir.isDirectory(from)) return error.Directory;

    const source = sys.open(from, .{}) catch return error.NoFile;
    defer sys.close(source);

    const target = sys.open(to, .{ .write = true, .create = true, .truncate = true }) catch
        return error.CannotCreate;
    defer sys.close(target);

    while (true) {
        const got = sys.read(source, &block) catch return error.Unreadable;
        if (got == 0) return;
        try writeAll(target, block[0..got]);
    }
}

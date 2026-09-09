//! Files read whole.
//!
//! What a program does with a file it is going to decode, show or parse:
//! open it, read as much as fits, close it. Written once so the loop that
//! keeps reading until the file or the room runs out lives in one place,
//! and the mistake it guards against, a short read taken for the end, can
//! be made only here. `readWhole` takes as much as fits, for a head or a
//! caller that sizes its room from the file; `readEntire` refuses a file
//! that does not fit, for a document that is read back and written again.
//! `copy` is the other whole-file move: the same loop the other way round.

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

        var put: usize = 0;
        while (put < got) {
            // A short write is not a failed one: what is left goes round again.
            const wrote = sys.write(target, block[put..got]) catch return error.NoSpace;
            if (wrote == 0) return error.NoSpace;
            put += wrote;
        }
    }
}

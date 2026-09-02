//! Files read whole.
//!
//! What a program does with a file it is going to decode, show or parse:
//! open it, read as much as fits, close it. Written once so the loop that
//! keeps reading until the file or the room runs out lives in one place,
//! and the mistake it guards against, a short read taken for the end, can
//! be made only here.

const sys = @import("sys");

/// Read the file at `path` into `into`, as much of it as fits, and say how
/// much. Null for a file that cannot be opened; a file that is there but
/// empty reads as nothing at all.
pub fn readWhole(path: []const u8, into: []u8) ?usize {
    const handle = sys.open(path, .{});
    if (handle < 0) return null;
    defer _ = sys.close(@intCast(handle));

    var read: usize = 0;
    while (read < into.len) {
        const n = sys.read(@intCast(handle), into[read..]);
        if (n <= 0) break;
        read += @intCast(n);
    }
    return read;
}

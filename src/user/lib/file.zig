//! Files read whole.
//!
//! What a program does with a file it is going to decode, show or parse:
//! open it, read as much as fits, close it. Written once so the loop that
//! keeps reading until the file or the room runs out lives in one place,
//! and the mistake it guards against, a short read taken for the end, can
//! be made only here. `readWhole` takes as much as fits, for a head or a
//! caller that sizes its room from the file; `readEntire` refuses a file
//! that does not fit, for a document that is read back and written again.

const sys = @import("sys");

/// Read the file at `path` into `into`, as much of it as fits, and say how
/// much. Null for a file that cannot be opened; a file that is there but
/// empty reads as nothing at all.
pub fn readWhole(path: []const u8, into: []u8) ?usize {
    const handle = sys.open(path, .{});
    if (handle < 0) return null;
    defer _ = sys.close(@intCast(handle));
    return fill(@intCast(handle), into);
}

pub const EntireError = error{ NoFile, TooBig };

/// Read the file at `path` into `into` entire, and say how long it is. A
/// file with more in it than the room is refused rather than cut short, so
/// what comes back is the file or nothing, and a document read this way is
/// never written back shorter than it was.
pub fn readEntire(path: []const u8, into: []u8) EntireError!usize {
    const handle = sys.open(path, .{});
    if (handle < 0) return error.NoFile;
    defer _ = sys.close(@intCast(handle));
    const read = fill(@intCast(handle), into);
    if (read < into.len) return read;
    // The room is full. One byte more tells a file that fits exactly from
    // one that goes on.
    var more: [1]u8 = undefined;
    if (sys.read(@intCast(handle), &more) > 0) return error.TooBig;
    return read;
}

/// Read from `handle` until the file or the room runs out.
fn fill(handle: u32, into: []u8) usize {
    var read: usize = 0;
    while (read < into.len) {
        const n = sys.read(handle, into[read..]);
        if (n <= 0) break;
        read += @intCast(n);
    }
    return read;
}

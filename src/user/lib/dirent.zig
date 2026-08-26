//! Directory entry decoding.
//!
//! The wire format is defined by the kernel in `kernel/syscall.zig`; this is
//! the one place userspace decodes it, so a change there means changing one
//! reader rather than every tool that lists files.

const sys = @import("../syscall.zig");

pub const Entry = struct {
    name: []const u8,
    size: u32,
    /// Seconds since the Unix epoch, or 0 when the filesystem recorded none.
    mtime: i64,
    is_dir: bool,
};

fn readU32(buf: []const u8) u32 {
    return @as(u32, buf[0]) | (@as(u32, buf[1]) << 8) |
        (@as(u32, buf[2]) << 16) | (@as(u32, buf[3]) << 24);
}

/// Decode `n` bytes as written by readdir or stat. Returns null when the
/// buffer is too short to hold what it claims.
pub fn decode(buf: []const u8, n: usize) ?Entry {
    if (n < sys.DIRENT_HEADER) return null;

    const name_len = buf[9];
    if (sys.DIRENT_HEADER + name_len > n) return null;

    return .{
        .name = buf[sys.DIRENT_HEADER..][0..name_len],
        .size = readU32(buf[0..4]),
        .mtime = @as(i32, @bitCast(readU32(buf[4..8]))),
        .is_dir = buf[8] & sys.DIRENT_FLAG_DIR != 0,
    };
}

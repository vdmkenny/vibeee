//! Asking about files without opening them, and walking a directory.
//!
//! Two things ported code does before it does anything else: check that
//! what it is looking for is there, and look through a directory for what
//! it does not know the name of. Both are one syscall here; what is in
//! this file is the shape C expects around them.

const errno = @import("errno.zig");
const heap = @import("ulib").heap;
const stdio = @import("stdio.zig");
const str = @import("lib").str;
const string = @import("string.zig");
const sys = @import("sys");

// ---------------------------------------------------------------------------
// What a name is
// ---------------------------------------------------------------------------

/// The bits C puts in `st_mode`. Only the two that mean anything here: a
/// name is a directory or it is a file, and everything is readable and
/// writable by whoever can reach it.
const S_IFDIR: c_uint = 0o040000;
const S_IFREG: c_uint = 0o100000;
const RW: c_uint = 0o666;

pub const Stat = extern struct {
    st_mode: c_uint = 0,
    st_size: c_long = 0,
    st_mtime: c_long = 0,
    /// Room for the fields a caller may name but this system has no
    /// answer for. Zero rather than invented.
    st_dev: c_uint = 0,
    st_ino: c_uint = 0,
    st_nlink: c_uint = 1,
    st_uid: c_uint = 0,
    st_gid: c_uint = 0,
};

export fn stat(path: [*:0]const u8, into: ?*Stat) callconv(.c) c_int {
    const out = into orelse return @intCast(errno.fail(errno.EFAULT));

    var record: [512]u8 = undefined;
    const n = sys.stat(string.spanOf(path), &record);
    if (n <= 0) return @intCast(errno.fail(errno.ENOENT));

    const entry = sys.Dirent.decode(&record, @intCast(n)) orelse
        return @intCast(errno.fail(errno.ENOENT));

    out.* = .{
        .st_mode = (if (entry.is_dir) S_IFDIR else S_IFREG) | RW,
        .st_size = @intCast(entry.size),
        .st_mtime = @intCast(@divTrunc(entry.mtime, 1_000_000)),
    };
    return 0;
}

/// Whether a name can be reached. The modes are not distinguished:
/// everything readable here is writable, so answering otherwise would be
/// answering something that is not asked.
export fn access(path: [*:0]const u8, mode: c_int) callconv(.c) c_int {
    _ = mode;
    var record: [512]u8 = undefined;
    if (sys.stat(string.spanOf(path), &record) <= 0) return @intCast(errno.fail(errno.ENOENT));
    return 0;
}

// ---------------------------------------------------------------------------
// Walking a directory
// ---------------------------------------------------------------------------

/// The longest name one entry may have. Longer ones are cut, which is
/// what every system with a fixed field does.
pub const NAME_MAX = 255;

pub const Dirent = extern struct {
    d_ino: c_uint = 0,
    /// Four for a directory, eight for a file, which is where every
    /// other system puts them.
    d_type: u8 = 0,
    d_name: [NAME_MAX + 1]u8 = @splat(0),
};

const DT_DIR: u8 = 4;
const DT_REG: u8 = 8;

/// An open directory: the handle, and somewhere for the entry a caller is
/// looking at to live until it asks for the next.
pub const Dir = extern struct {
    handle: c_int = -1,
    entry: Dirent = .{},
};

export fn opendir(path: [*:0]const u8) callconv(.c) ?*Dir {
    const handle = sys.open(string.spanOf(path), .{ .directory = true });
    if (handle < 0) {
        _ = errno.fail(errno.ENOENT);
        return null;
    }

    const block = heap.alloc(@sizeOf(Dir)) orelse {
        _ = sys.close(@intCast(handle));
        _ = errno.fail(errno.ENOMEM);
        return null;
    };

    const dir: *Dir = @alignCast(@ptrCast(block));
    dir.* = .{ .handle = @intCast(handle) };
    return dir;
}

/// The next entry, or null at the end. The answer points into the open
/// directory and stands until the next call, which is what C promises and
/// what lets this need no allocation per entry.
export fn readdir(dir: ?*Dir) callconv(.c) ?*Dirent {
    const open = dir orelse return null;

    var record: [512]u8 = undefined;
    const n = sys.readdir(@intCast(open.handle), &record);
    if (n <= 0) return null;

    const entry = sys.Dirent.decode(&record, @intCast(n)) orelse return null;

    open.entry = .{ .d_type = if (entry.is_dir) DT_DIR else DT_REG };
    const kept = @min(entry.name.len, NAME_MAX);
    @memcpy(open.entry.d_name[0..kept], entry.name[0..kept]);
    return &open.entry;
}

export fn closedir(dir: ?*Dir) callconv(.c) c_int {
    const open = dir orelse return -1;
    _ = sys.close(@intCast(open.handle));
    heap.release(@ptrCast(open));
    return 0;
}

/// What `assert` calls when its claim turns out to be false.
///
/// Says where, and stops. A program whose own check failed has already
/// stopped being the program that was written, and carrying on from
/// there produces a second, stranger fault somewhere else.
export fn __assert_fail(claim: [*:0]const u8, file: [*:0]const u8, line: c_int) callconv(.c) noreturn {
    var digits: [16]u8 = @splat(0);
    var text = str.Builder{ .buf = digits[0..15] };
    text.number(@intCast(@max(line, 0)));

    say("assertion failed: ");
    say(claim);
    say(" at ");
    say(file);
    say(":");
    say(@ptrCast(&digits));
    say("\n");

    // The same status a shell reports for a program that aborted, which
    // is what this is.
    sys.exit(134);
}

fn say(text: [*:0]const u8) void {
    _ = stdio.fputs(text, stdio.stderr);
}

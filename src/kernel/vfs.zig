//! Mount table and path resolution.
//!
//! A path is resolved by finding the longest mounted prefix, so `/media/sd1/x`
//! goes to the volume mounted at `/media/sd1` even though `/` is also mounted.
//! That is the whole mechanism; there is no unified inode cache and no dentry
//! tree, because with a handful of FAT volumes neither would earn its
//! complexity.
//!
//! Everything here is transport-agnostic. The internal SSD, an SD card behind
//! the USB reader and a USB stick differ only in which `block.Device` they
//! present, so `usbd` will be able to mount removable media through exactly
//! this interface without changes.

const std = @import("std");
const block = @import("block.zig");
const console = @import("console.zig");
const fat = @import("fat.zig");

pub const Error = error{
    NotMounted,
    AlreadyMounted,
    TableFull,
    BadPath,
    Busy,
    ReadOnly,
} || fat.Error;

pub const MAX_MOUNTS = 8;
pub const MAX_PATH = 64;

pub const Mount = struct {
    path_buf: [MAX_PATH]u8 = undefined,
    path_len: usize = 0,
    volume: fat.Volume = undefined,
    device: *const block.Device = undefined,
    /// Removable media may vanish without warning; the flag drives whether an
    /// unmount is expected to be able to flush.
    removable: bool = false,
    in_use: bool = false,
    /// Open file count. Unmounting with files open would leave userspace
    /// holding handles to a volume that no longer exists.
    open_files: usize = 0,

    pub fn path(self: *const Mount) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

var mounts: [MAX_MOUNTS]Mount = @splat(.{});

fn isValidPath(path: []const u8) bool {
    if (path.len == 0 or path.len >= MAX_PATH) return false;
    if (path[0] != '/') return false;
    // A trailing slash on anything but "/" makes prefix matching ambiguous.
    if (path.len > 1 and path[path.len - 1] == '/') return false;
    return true;
}

/// Mount the filesystem on `dev` at `path`.
pub fn mount(path: []const u8, dev: *const block.Device, removable: bool) Error!*Mount {
    if (!isValidPath(path)) return error.BadPath;

    for (&mounts) |*m| {
        if (m.in_use and std.mem.eql(u8, m.path(), path)) return error.AlreadyMounted;
    }

    const volume = try fat.mount(dev);

    for (&mounts) |*m| {
        if (m.in_use) continue;
        @memcpy(m.path_buf[0..path.len], path);
        m.path_len = path.len;
        m.volume = volume;
        m.device = dev;
        m.removable = removable;
        m.open_files = 0;
        m.in_use = true;
        return m;
    }
    return error.TableFull;
}

/// Unmount whatever is at `path`.
///
/// Flushing before detaching is the point: FAT has no journal, so anything the
/// device is still holding is lost if the medium goes away first.
pub fn umount(path: []const u8) Error!void {
    for (&mounts) |*m| {
        if (!m.in_use or !std.mem.eql(u8, m.path(), path)) continue;
        if (m.open_files > 0) return error.Busy;

        m.device.flush() catch |err| {
            // Report, but still detach: refusing to unmount a device that is
            // already gone would leave a permanently stuck mount point.
            console.warn("vfs: flush failed unmounting {s}: {s}", .{ path, @errorName(err) });
        };

        m.in_use = false;
        m.path_len = 0;
        return;
    }
    return error.NotMounted;
}

pub const Resolved = struct {
    mount: *Mount,
    /// Path relative to the mount point, with no leading slash.
    rest: []const u8,
};

/// Find the volume responsible for `path`.
///
/// Longest prefix wins, so a deeper mount shadows a shallower one. The prefix
/// must end at a component boundary: `/media` must not match `/mediaplayer`.
pub fn resolve(path: []const u8) Error!Resolved {
    if (!isValidPath(path) and !std.mem.eql(u8, path, "/")) return error.BadPath;

    var best: ?*Mount = null;
    var best_len: usize = 0;

    for (&mounts) |*m| {
        if (!m.in_use) continue;
        const mp = m.path();

        const matches = if (mp.len == 1)
            true // "/" matches everything
        else
            path.len >= mp.len and
                std.mem.eql(u8, path[0..mp.len], mp) and
                (path.len == mp.len or path[mp.len] == '/');

        if (matches and mp.len >= best_len) {
            best = m;
            best_len = mp.len;
        }
    }

    const m = best orelse return error.NotMounted;
    var rest = path[if (best_len == 1) 1 else best_len..];
    while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    return .{ .mount = m, .rest = rest };
}

pub fn list() []const Mount {
    return &mounts;
}

pub fn mountCount() usize {
    var n: usize = 0;
    for (mounts) |m| {
        if (m.in_use) n += 1;
    }
    return n;
}

// ---------------------------------------------------------------------------
// File access
// ---------------------------------------------------------------------------

pub fn stat(path: []const u8) Error!fat.Entry {
    const r = try resolve(path);
    if (r.rest.len == 0) return error.BadPath; // the mount point itself
    return fat.lookupPath(&r.mount.volume, r.rest);
}

/// Read a whole file into `buf`, returning the byte count.
pub fn readFile(path: []const u8, buf: []u8) Error!usize {
    const r = try resolve(path);
    if (r.rest.len == 0) return error.BadPath;

    const entry = try fat.lookupPath(&r.mount.volume, r.rest);

    // Counted across the read so an unmount cannot pull the volume out from
    // under an in-flight transfer.
    r.mount.open_files += 1;
    defer r.mount.open_files -= 1;

    return fat.readFile(&r.mount.volume, entry, buf);
}

/// Open a file, returning the mount and entry a handle needs to keep.
pub fn open(path: []const u8) Error!struct { mount: *Mount, entry: fat.Entry } {
    const r = try resolve(path);
    if (r.rest.len == 0) return error.BadPath;
    const entry = try fat.lookupPath(&r.mount.volume, r.rest);
    r.mount.open_files += 1;
    return .{ .mount = r.mount, .entry = entry };
}

/// Read from an already-opened file.
pub fn readAt(m: *Mount, entry: fat.Entry, offset: u64, buf: []u8) Error!usize {
    return fat.readAt(&m.volume, entry, offset, buf);
}

/// Iterate the directory at `path`.
pub fn openDir(path: []const u8) Error!fat.Iterator {
    const r = try resolve(path);
    if (r.rest.len == 0) return fat.rootIterator(&r.mount.volume);

    const entry = try fat.lookupPath(&r.mount.volume, r.rest);
    if (!entry.is_dir) return error.NotDirectory;
    return fat.iterate(&r.mount.volume, entry);
}

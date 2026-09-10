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
//!
//! Two kinds of lock. The table's own serialises mounting and unmounting,
//! which sleep on the medium while they decide what the table holds. Each
//! slot's serialises the work on its volume, and is taken after the volume is
//! found: a path resolves to a slot and a turn of it, and the turn is checked
//! again once the lock is held, because whoever held it before may have
//! unmounted the volume, or mounted another into the same slot, while this
//! caller waited.

const std = @import("std");
const block = @import("block.zig");
const console = @import("console.zig");
const fat = @import("fat.zig");
const lock_mod = @import("lock.zig");

pub const Error = error{
    NotMounted,
    AlreadyMounted,
    TableFull,
    BadPath,
    Busy,
    ReadOnly,
    /// The two paths are on different volumes, which a rename cannot span.
    CrossDevice,
    /// The volume a handle was opened on is no longer the one in its slot:
    /// the medium went, or the slot has since been given to another.
    Gone,
    /// The caller was asked to end while waiting its turn on the volume.
    Ending,
} || fat.Error;

/// One operation at a time on a volume's own metadata: the allocation
/// table's one-sector cache, the free count, a directory sector being
/// edited. See `lock.zig` for why this is a lock at all rather than nothing.
pub const Lock = lock_mod.Lock;

pub const MAX_MOUNTS = 8;
/// The longest mount point, which is what a slot keeps. A path resolved
/// through the table is not kept, and has no bound here.
pub const MAX_PATH = 64;

pub const Mount = struct {
    path_buf: [MAX_PATH]u8 = undefined,
    path_len: usize = 0,
    volume: fat.Volume = undefined,
    device: *const block.Device = undefined,
    /// Refuse writes to this mount whatever the device would allow. For a
    /// volume being inspected rather than used.
    read_only: bool = false,
    in_use: bool = false,
    /// Open file count. Unmounting with files open would leave userspace
    /// holding handles to a volume that no longer exists.
    open_files: usize = 0,
    /// Which turn of this slot this is, bumped every time something is
    /// mounted into it. A file remembers the turn it opened on, so a slot
    /// that has since been given to another volume answers it "gone" rather
    /// than the other volume's blocks.
    generation: u32 = 0,
    /// Whoever is working on the volume holds this; see `Lock`. It belongs
    /// to the slot rather than to the volume in it: a thread waiting its
    /// turn is still queued on it when the volume changes, and finds that
    /// out when its turn comes.
    lock: Lock = .{},

    pub fn path(self: *const Mount) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    /// Whether this slot may be given to a new volume. A dead mount with files
    /// still open keeps its slot: freeing it would let the next mount take the
    /// place those files point at.
    fn free(self: *const Mount) bool {
        return !self.in_use and self.open_files == 0;
    }
};

/// A claim on the mount something was opened on: the slot, and which turn
/// of it.
///
/// Held instead of a bare pointer because the slot outlives the volume. A
/// medium pulled out takes its mount with it while the files on it stay open,
/// and whatever is mounted into the slot next must not inherit them.
pub const Lease = struct {
    slot: *Mount,
    generation: u32,

    /// The volume, held for one operation: the slot's lock taken, and the
    /// turn found to still be this one under it. Given back with `release`.
    pub fn hold(self: Lease) Error!*Mount {
        try self.slot.lock.hold();
        if (self.slot.in_use and self.slot.generation == self.generation) return self.slot;
        self.slot.lock.release();
        return error.Gone;
    }

    pub fn release(self: Lease) void {
        self.slot.lock.release();
    }
};

var mounts: [MAX_MOUNTS]Mount = @splat(.{});

/// Mounting and unmounting decide what the table holds, and sleep on the
/// medium while they do. One at a time, so that two media arriving together
/// do not settle on the same slot or the same place.
var table_lock: Lock = .{};

/// The shape every path here has: absolute, and ending in a name rather
/// than a slash, since a trailing slash on anything but "/" would make
/// prefix matching ambiguous.
fn wellFormed(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    return path.len == 1 or path[path.len - 1] != '/';
}

/// Take a lock for work that goes ahead whether or not it could wait, and
/// say whether it was taken, so that it can be given back.
fn tryHold(l: *Lock) bool {
    l.hold() catch return false;
    return true;
}

pub const Options = struct {
    /// Refuse writes whatever the device would allow.
    read_only: bool = false,
};

/// Mount the filesystem on `dev` at `path`.
pub fn mount(path: []const u8, dev: *const block.Device, options: Options) Error!*Mount {
    if (!wellFormed(path) or path.len >= MAX_PATH) return error.BadPath;

    try table_lock.hold();
    defer table_lock.release();

    if (slotAt(path) != null) return error.AlreadyMounted;

    const volume = try fat.mount(dev);

    for (&mounts) |*m| {
        if (!m.free()) continue;
        // Under the slot's own lock: a thread still queued on it from the
        // slot's last turn takes its turn after this, and finds the turn
        // has moved on.
        try m.lock.hold();
        defer m.lock.release();
        @memcpy(m.path_buf[0..path.len], path);
        m.path_len = path.len;
        m.volume = volume;
        m.device = dev;
        m.read_only = options.read_only;
        m.open_files = 0;
        m.generation +%= 1;
        // The one walk of the table, here rather than on the first ask: a
        // shell and a file manager ask how full a volume is all the time,
        // and from now on the answer is kept rather than counted. Before the
        // slot is in use, so nothing else can be on the volume yet.
        _ = fat.freeClusters(&m.volume) catch {};
        m.in_use = true;
        console.info("mount", "{s} on {s} ({s}, {d} MiB)", .{
            m.path(),
            dev.name,
            @tagName(m.volume.kind),
            m.volume.totalBytes() / (1024 * 1024),
        });
        return m;
    }
    return error.TableFull;
}

/// The slot whose volume is mounted at exactly `path`.
fn slotAt(path: []const u8) ?*Mount {
    for (&mounts) |*m| {
        if (m.in_use and std.mem.eql(u8, m.path(), path)) return m;
    }
    return null;
}

/// Take the volume out of its slot.
///
/// The slot is not freed. Files still open on it hold leases that name this
/// turn, and `mount` will not reuse the slot until the last of them closes;
/// until then every one of them is answered "gone".
fn detach(m: *Mount) void {
    m.in_use = false;
    m.path_len = 0;
}

/// Whether a volume found is a volume mounted.
///
/// On, because a medium plugged in is meant to be read. Off is for a
/// machine being worked on: a filesystem this kernel would mount and
/// write to is one it cannot be asked to leave alone otherwise, and
/// `mount` still attaches anything by hand.
var automount = true;

pub fn setAutomount(on: bool) void {
    automount = on;
}

pub fn automounts() bool {
    return automount;
}

/// Put a volume under /media, named after itself.
///
/// One place, because a medium found at boot and a medium plugged in
/// afterwards should arrive in the same spot: the only difference between
/// them is when they turned up.
/// The boot medium, and where its own volumes go after the first.
///
/// Held as a signature and a partition's number rather than as devices,
/// because a machine whose boot medium is behind a bus that starts later
/// has no such device to point at when the boot mounts are decided: the
/// volumes that carry what it remembers turn up long after, and have to
/// know their places when they do.
var spoken_signature: u32 = 0;
var spoken_places: []const []const u8 = &.{};

pub fn speakFor(signature: u32, places: []const []const u8) void {
    spoken_signature = signature;
    spoken_places = places;
}

/// Where a volume belongs, when it is one of the boot medium's own. The
/// first partition carries the loader and the system and has no place
/// reserved: what it holds is the root, and the root is mounted from
/// whichever copy of it the machine can reach.
pub fn placeOf(dev: *const block.Device) ?[]const u8 {
    if (spoken_signature == 0 or spoken_places.len == 0) return null;
    const place = block.partitionOf(dev) orelse return null;
    if (place.number < 2 or place.number - 2 >= spoken_places.len) return null;
    const signature = block.signatureOf(place.disk) orelse return null;
    if (signature != spoken_signature) return null;
    return spoken_places[place.number - 2];
}

pub fn mountMedia(dev: *const block.Device) void {
    if (!automount) return;

    // A volume the board has spoken for goes to its own place, whenever it
    // arrives. On a machine whose boot medium is behind a bus that starts
    // later this is the only pass that ever sees it.
    if (placeOf(dev)) |place| {
        if (mount(place, dev, .{})) |_| {
            return;
        } else |err| switch (err) {
            // Somebody is already in that place: a second copy of the
            // machine's own medium is still a medium worth reaching, so
            // it goes where any other one would.
            error.AlreadyMounted => {},
            error.NotFat, error.Unsupported => return,
            else => {
                console.warn("vfs: cannot mount {s} on {s}: {s}", .{ dev.name, place, @errorName(err) });
                return;
            },
        }
    }

    // Named for its device, e.g. "/media/hd1p1". The mount keeps the path
    // in its own slot, so the name lives as long as the mount and no longer,
    // and a medium plugged in for the hundredth time is named like the first.
    var path_buf: [MAX_PATH]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "/media/{s}", .{dev.name}) catch return;

    _ = mount(path, dev, .{}) catch |err| switch (err) {
        error.NotFat, error.Unsupported => {},
        else => console.warn("vfs: cannot mount {s}: {s}", .{ dev.name, @errorName(err) }),
    };
}

/// Detach every mount on a device whose medium has gone.
///
/// Not the same as unmounting: there is nothing left to flush to, and a
/// mount pointing at a device that answers nothing is worse than no mount
/// at all. Reported so the reason a path stopped working is in the log.
///
/// Serialised with mounting like an unmount, but not refused to a thread
/// asked to end: the medium is gone whether or not this could wait.
pub fn abandon(dev_ctx: *anyopaque) usize {
    const table_held = tryHold(&table_lock);
    defer if (table_held) table_lock.release();

    var dropped: usize = 0;
    for (&mounts) |*m| {
        if (!m.in_use or m.device.ctx != dev_ctx) continue;
        console.info("mount", "{s} is gone", .{m.path()});
        // Whoever is on the volume finishes first, failing on a device that
        // answers nothing, rather than having the slot emptied under them.
        const held = tryHold(&m.lock);
        detach(m);
        if (held) m.lock.release();
        dropped += 1;
    }
    return dropped;
}

/// Unmount whatever is at `path`.
///
/// Flushing before detaching is the point: FAT has no journal, so anything the
/// device is still holding is lost if the medium goes away first. Under the
/// slot's lock, so that a write in flight on the volume finishes before the
/// flush rather than landing after it.
pub fn unmount(path: []const u8) Error!void {
    try table_lock.hold();
    defer table_lock.release();

    const m = slotAt(path) orelse return error.NotMounted;
    try m.lock.hold();
    defer m.lock.release();
    if (m.open_files > 0) return error.Busy;

    m.device.flush() catch |err| {
        // Report, but still detach: refusing to unmount a device that is
        // already gone would leave a permanently stuck mount point.
        console.warn("vfs: flush failed unmounting {s}: {s}", .{ path, @errorName(err) });
    };
    detach(m);
}

pub const Resolved = struct {
    lease: Lease,
    /// Path relative to the mount point, with no leading slash.
    rest: []const u8,

    /// The volume, held for one operation. A path whose volume went while
    /// the caller waited its turn has no volume: that is "not mounted",
    /// where a handle's would be "gone".
    pub fn hold(self: Resolved) Error!*Mount {
        return self.lease.hold() catch |err| switch (err) {
            error.Gone => error.NotMounted,
            else => |e| e,
        };
    }

    pub fn release(self: Resolved) void {
        self.lease.release();
    }
};

/// Whether `mount_point` covers `path`. The root covers everything; any
/// other mount point must end at a component boundary, so that `/media`
/// does not cover `/mediaplayer`.
fn covers(mount_point: []const u8, path: []const u8) bool {
    if (mount_point.len == 1) return true;
    if (!std.mem.startsWith(u8, path, mount_point)) return false;
    return path.len == mount_point.len or path[mount_point.len] == '/';
}

/// Find the volume responsible for `path`.
///
/// Longest prefix wins, so a deeper mount shadows a shallower one.
pub fn resolve(path: []const u8) Error!Resolved {
    if (!wellFormed(path)) return error.BadPath;

    var best: ?*Mount = null;
    var best_len: usize = 0;
    for (&mounts) |*m| {
        if (!m.in_use or !covers(m.path(), path)) continue;
        if (m.path_len >= best_len) {
            best = m;
            best_len = m.path_len;
        }
    }

    const m = best orelse return error.NotMounted;
    var rest = path[best_len..];
    while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
    return .{ .lease = .{ .slot = m, .generation = m.generation }, .rest = rest };
}

pub fn list() []const Mount {
    return &mounts;
}

pub const Usage = struct { free: u64 = 0, total: u64 = 0 };

/// How full the nth mounted volume is.
///
/// Here rather than at the caller: reading the allocation table needs the
/// volume mutable, and the mount table is handed out read-only on purpose. A
/// volume that will not answer reads as empty rather than failing the whole
/// listing.
pub fn usageAt(index: usize) Usage {
    if (index >= mounts.len or !mounts[index].in_use) return .{};
    const lease = Lease{ .slot = &mounts[index], .generation = mounts[index].generation };
    const m = lease.hold() catch return .{};
    defer lease.release();
    const clusters = fat.freeClusters(&m.volume) catch return .{ .total = m.volume.totalBytes() };
    return .{
        .free = @as(u64, clusters) * m.volume.clusterSize(),
        .total = m.volume.totalBytes(),
    };
}

// ---------------------------------------------------------------------------
// File access
// ---------------------------------------------------------------------------

/// The entry `rest` names on a volume held. A mount point has no record in
/// the volume above it: what stands for it is the volume's own root.
fn entryOn(m: *Mount, rest: []const u8) Error!fat.Entry {
    if (rest.len == 0) return fat.rootEntry(&m.volume);
    return fat.lookupPath(&m.volume, rest);
}

pub fn stat(path: []const u8) Error!fat.Entry {
    const r = try resolve(path);
    const m = try r.hold();
    defer r.release();
    return entryOn(m, r.rest);
}

/// Read a whole file into `buf`, returning the byte count. The volume is
/// held for the whole read, so nothing can take it away part way.
pub fn readFile(path: []const u8, buf: []u8) Error!usize {
    const r = try resolve(path);
    const m = try r.hold();
    defer r.release();
    const entry = try entryOn(m, r.rest);
    return fat.readFile(&m.volume, entry, buf);
}

/// What a handle keeps about an open file: its claim on the mount, and the
/// entry. The claim is counted against the slot until `close`.
pub const Opened = struct { lease: Lease, entry: fat.Entry };

pub const OpenMode = struct {
    /// Make the file if there is none. Only a missing file is worth making:
    /// anything else in the way is a real failure, and making a file on top
    /// of it would hide that.
    create: bool = false,
    /// Start it empty.
    truncate: bool = false,
};

/// Open a file, all of it in one turn on the volume: found or made, and
/// emptied if asked, before anything else can get between.
pub fn open(path: []const u8, mode: OpenMode, mtime: i64) Error!Opened {
    const r = try resolve(path);
    const m = try r.hold();
    defer r.release();

    var entry = entryOn(m, r.rest) catch |err| switch (err) {
        error.NotFound => if (mode.create) try makeOn(m, path, mtime, .file) else return err,
        else => return err,
    };
    if (mode.truncate) {
        try requireWritable(m);
        try fat.resize(&m.volume, &entry, 0, mtime);
    }
    m.open_files += 1;
    return .{ .lease = r.lease, .entry = entry };
}

/// What a handle keeps about a directory being listed: its claim on the
/// mount, counted like a file's, and where the listing has got to.
pub const OpenedDir = struct {
    lease: Lease,
    iterator: fat.Iterator,
    /// A mount root, which has no parent to report.
    at_root: bool,
};

pub fn openDir(path: []const u8) Error!OpenedDir {
    const r = try resolve(path);
    const m = try r.hold();
    defer r.release();
    const iterator = try directoryOn(m, r.rest);
    m.open_files += 1;
    return .{ .lease = r.lease, .iterator = iterator, .at_root = r.rest.len == 0 };
}

/// One more handle names what `lease` opened.
///
/// The count is owed to the slot rather than to the volume: it is what keeps
/// the slot from being given away while a handle names it, whether or not
/// the volume is still there.
pub fn share(lease: Lease) void {
    lease.slot.open_files += 1;
}

/// One handle fewer names what `lease` opened. The last one closing frees a
/// slot whose volume has gone for the next mount.
pub fn close(lease: Lease) void {
    lease.slot.open_files -= 1;
}

/// Read from an already-opened file.
pub fn readAt(lease: Lease, entry: *fat.Entry, offset: u64, buf: []u8) Error!usize {
    const m = try lease.hold();
    defer lease.release();
    return fat.readAt(&m.volume, entry, offset, buf);
}

/// The next record of a directory being listed. The listing holds the
/// volume for the one record, not for the whole walk, so a slow reader does
/// not keep everything else off the volume.
pub fn readDir(lease: Lease, it: *fat.Iterator) Error!?fat.Entry {
    _ = try lease.hold();
    defer lease.release();
    return it.next();
}

/// A directory on a volume already held.
fn directoryOn(m: *Mount, rest: []const u8) Error!fat.Iterator {
    const entry = try entryOn(m, rest);
    if (!entry.is_dir) return error.NotDirectory;
    return fat.iterate(&m.volume, entry);
}

// ---------------------------------------------------------------------------
// Writing
//
// Everything below goes through `resolve` for the same reason the read paths
// do: only the mount table knows which volume a path belongs to, and only it
// knows whether that volume will accept a write at all. A syscall reaching
// into `fat` directly would bypass both.
// ---------------------------------------------------------------------------

/// Refuse a write before it starts.
///
/// Two separate reasons a volume may be unwritable: mounted read-only, or
/// backed by a device that cannot write. Checking here means every write path
/// gets the check rather than each remembering to.
fn requireWritable(m: *Mount) Error!void {
    if (m.read_only or m.device.read_only) return error.ReadOnly;
}

/// Split a path into the directory holding it and the final component.
fn splitParent(path: []const u8) struct { dir: []const u8, name: []const u8 } {
    var cut: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/') cut = i;
    }
    return .{
        .dir = if (cut == 0) "/" else path[0..cut],
        .name = path[cut + 1 ..],
    };
}

const Parent = struct { dir: fat.Iterator, name: []const u8 };

/// Where a record for `path` goes: the directory above it, on the volume
/// held, and the name it has there. A path inside a mount has its parent on
/// the same mount, or at its root.
fn parentOf(m: *Mount, path: []const u8) Error!Parent {
    const split = splitParent(path);
    const parent = try resolve(split.dir);
    if (parent.lease.slot != m) return error.CrossDevice;
    return .{ .dir = try directoryOn(m, parent.rest), .name = split.name };
}

const Made = enum { file, directory };

/// Put an empty file or directory at `path`, on its volume held. Whether the
/// name is already taken is the directory's own check, made while the
/// record is placed.
fn makeOn(m: *Mount, path: []const u8, mtime: i64, kind: Made) Error!fat.Entry {
    try requireWritable(m);
    const at = try parentOf(m, path);
    return switch (kind) {
        .file => fat.createFile(&m.volume, at.dir, at.name, mtime),
        .directory => fat.createDirectory(&m.volume, at.dir, at.name, mtime),
    };
}

/// Create an empty directory, failing if something is already there.
pub fn mkdir(path: []const u8, mtime: i64) Error!void {
    const r = try resolve(path);
    // A mount point is something already there.
    if (r.rest.len == 0) return error.Exists;
    const m = try r.hold();
    defer r.release();
    _ = try makeOn(m, path, mtime, .directory);
}

/// Write to an already-opened file. The entry is updated in place; the caller
/// commits it when it closes the file.
pub fn writeAt(lease: Lease, entry: *fat.Entry, offset: u64, data: []const u8) Error!usize {
    const m = try lease.hold();
    defer lease.release();
    try requireWritable(m);
    return fat.writeAt(&m.volume, entry, offset, data);
}

/// Persist an entry's size, first cluster and modification time.
pub fn commit(lease: Lease, entry: fat.Entry, mtime: i64) Error!void {
    const m = try lease.hold();
    defer lease.release();
    try requireWritable(m);
    return fat.commit(&m.volume, entry, mtime);
}

/// Push what the volume's drive still holds through to the medium.
///
/// What bounds how much a power cut can take: a file whose handle has been
/// closed has landed, whatever the drive was keeping in its own cache. The
/// drive is only asked when something has been written to it.
pub fn flush(lease: Lease) Error!void {
    const m = try lease.hold();
    defer lease.release();
    // A drive answers about itself; above here the only thing that matters
    // is that what was written is not known to have landed.
    m.device.flush() catch return error.Io;
}

/// Make an open file exactly `size` bytes, record and all.
pub fn resize(lease: Lease, entry: *fat.Entry, size: u32, mtime: i64) Error!void {
    const m = try lease.hold();
    defer lease.release();
    try requireWritable(m);
    return fat.resize(&m.volume, entry, size, mtime);
}

/// Move `from` to `to`, replacing whatever is at `to`.
///
/// Within one volume only. Across volumes a rename would be a copy and a
/// delete, which is a different operation with different failure modes and a
/// duration proportional to the file: a caller that wants it should ask for it
/// rather than have a rename quietly become it.
pub fn rename(from: []const u8, to: []const u8, mtime: i64) Error!void {
    const source = try resolve(from);
    const destination = try resolve(to);
    if (source.lease.slot != destination.lease.slot) return error.CrossDevice;
    // A mount point is in use as one: it is neither moved nor replaced.
    if (source.rest.len == 0 or destination.rest.len == 0) return error.Busy;
    const m = try source.hold();
    defer source.release();
    try requireWritable(m);

    const entry = try fat.lookupPath(&m.volume, source.rest);
    const at = try parentOf(m, to);
    _ = try fat.rename(&m.volume, entry, at.dir, at.name, mtime);
}

/// Remove a file.
pub fn unlink(path: []const u8) Error!void {
    const r = try resolve(path);
    // A mount point is in use as one.
    if (r.rest.len == 0) return error.Busy;
    const m = try r.hold();
    defer r.release();
    try requireWritable(m);

    const entry = try fat.lookupPath(&m.volume, r.rest);
    return fat.unlink(&m.volume, entry);
}

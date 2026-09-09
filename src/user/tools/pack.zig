//! pack and unpack: a set of files as one file, and back again.
//!
//! Named for what they do rather than after another system's word for a tape.
//! The format is ustar, which is what every other machine reads, so a set of
//! files packed here opens on whatever you carry it to. Nothing is
//! compressed; `ulib.ustar` says why.
//!
//! Walking a directory is `ulib.walk`, shared with `tree` and `find`, so what
//! is under a directory means the same thing to all three.

const dir = @import("ulib").dir;
const out = @import("ulib").out;
const paths = @import("ulib").paths;
const sys = @import("sys");
const ustar = @import("ulib").ustar;
const walk = @import("ulib").walk;

/// How much is moved at once. A page, which is what the filesystem reads and
/// writes in anyway. Beside the commands rather than on their frames.
var block: [4096]u8 = undefined;

/// One header, and the zeros an archive ends with.
var header: ustar.Header = undefined;
var padding: [ustar.BLOCK]u8 = @splat(0);

// ---------------------------------------------------------------------------
// pack
// ---------------------------------------------------------------------------

/// The archive being written, and whether anything has gone wrong with it.
/// Kept here because the walk's visitor cannot be handed a growing state and
/// return a failure through it.
var archive: u32 = 0;
var failed = false;
var packed_count: usize = 0;

var walker: walk.Walk = .{};

pub fn pack(args: []const []const u8) void {
    if (args.len < 2) {
        out.text("usage: pack <archive> <file>...\n");
        out.flush();
        return;
    }

    const name = args[0];
    archive = sys.open(name, .{ .write = true, .create = true, .truncate = true }) catch {
        out.fault("pack", name, "cannot create");
        out.flush();
        return;
    };
    defer sys.close(archive);

    failed = false;
    packed_count = 0;

    for (args[1..]) |path| {
        if (failed) break;
        const facts = factsOf(path) orelse {
            out.fault("pack", path, "cannot open");
            continue;
        };
        if (facts.is_dir) {
            // The directory itself first, so an empty one survives the trip,
            // then everything under it.
            store(path, .directory, 0, facts.mtime);
            _ = walker.each(path, {}, storeFound);
        } else {
            store(path, .file, facts.size, facts.mtime);
        }
    }

    // Two blocks of nothing, which is how an archive says it has ended.
    if (!failed) {
        put(&padding);
        put(&padding);
    }

    if (!failed) {
        out.decimal(packed_count);
        out.text(if (packed_count == 1) " thing packed into " else " things packed into ");
        out.text(name);
        out.byte('\n');
    }
    out.flush();
}

fn storeFound(_: void, _: usize, found: walk.Found) void {
    switch (found) {
        .name => |it| store(it.path, if (it.is_dir) .directory else .file, it.size, it.mtime),
        .unreadable => out.fault("pack", "", "a directory would not open"),
        .more => out.fault("pack", "", "a directory held more than was packed"),
    }
}

/// What the filesystem says about a name, in one call rather than by reading
/// it: a header carries a length before the bytes do, and measuring a file by
/// reading it would read every file twice.
fn factsOf(path: []const u8) ?sys.Dirent {
    var record: [512]u8 = undefined;
    const n = sys.stat(path, &record) catch return null;
    return sys.Dirent.decode(&record, n);
}

/// One entry: its header, then its bytes rounded up to a whole block.
fn store(path: []const u8, kind: ustar.Kind, size: u32, mtime: i64) void {
    if (failed) return;

    if (kind == .directory) {
        ustar.write(&header, path, 0, mtime, .directory) catch
            return out.fault("pack", path, "the name is too long for an archive");
        put(asBytes());
        packed_count += 1;
        return;
    }

    const source = sys.open(path, .{}) catch return out.fault("pack", path, "cannot open");
    defer sys.close(source);

    ustar.write(&header, path, size, mtime, .file) catch
        return out.fault("pack", path, "the name is too long for an archive");
    put(asBytes());

    var moved: usize = 0;
    while (moved < size) {
        const room = @min(block.len, size - moved);
        const got = sys.read(source, block[0..room]) catch
            return out.fault("pack", path, "cannot read");
        if (got == 0) break;
        put(block[0..got]);
        moved += got;
        if (failed) return;
    }

    // A file that grew or shrank while it was being packed still has to fill
    // the length its header claims, or every entry after it is misread.
    while (moved < size) : (moved += 1) put(padding[0..1]);
    pad(size);
    packed_count += 1;
}

fn asBytes() []const u8 {
    const bytes: [*]const u8 = @ptrCast(&header);
    return bytes[0..ustar.BLOCK];
}

/// Up to the next block boundary, which is where the next header starts.
fn pad(written: u64) void {
    const over: usize = @intCast(written % ustar.BLOCK);
    if (over != 0) put(padding[0 .. ustar.BLOCK - over]);
}

fn put(bytes: []const u8) void {
    var at: usize = 0;
    while (at < bytes.len) {
        const wrote = sys.write(archive, bytes[at..]) catch 0;
        if (wrote == 0) {
            failed = true;
            return out.fault("pack", "", "cannot write the archive");
        }
        at += wrote;
    }
}

// ---------------------------------------------------------------------------
// unpack
// ---------------------------------------------------------------------------

var name_buf: [walk.PATH_MAX]u8 = undefined;
var where_buf: [walk.PATH_MAX]u8 = undefined;

pub fn unpack(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: unpack <archive> [where]\n  unpack -l <archive>   say what is in it\n");
        out.flush();
        return;
    }

    const listing = args.len > 1 and args[0].len == 2 and args[0][0] == '-' and args[0][1] == 'l';
    const rest = if (listing) args[1..] else args;
    const name = rest[0];
    const where = if (!listing and rest.len > 1) rest[1] else ".";

    const source = sys.open(name, .{}) catch {
        out.fault("unpack", name, "cannot open");
        out.flush();
        return;
    };
    defer sys.close(source);

    var taken: usize = 0;
    while (true) {
        if (!fill(source, block[0..ustar.BLOCK])) break;
        const at: *const ustar.Header = @ptrCast(@alignCast(&block));

        const entry = ustar.read(at, &name_buf) catch {
            out.fault("unpack", name, "this is not an archive, or it is damaged");
            break;
        } orelse break;

        if (listing) {
            out.decimalRight(@intCast(entry.size), 9);
            out.byte(' ');
            out.text(entry.path);
            if (entry.kind == .directory) out.byte('/');
            out.byte('\n');
            skip(source, entry.size);
            taken += 1;
            continue;
        }

        const to = paths.joined(where, entry.path, &where_buf) orelse {
            out.fault("unpack", entry.path, "the path is too long");
            skip(source, entry.size);
            continue;
        };

        if (entry.kind == .directory) {
            makeWay(to);
            taken += 1;
            continue;
        }
        if (!entry.kind.isFile()) {
            // Something the format allows and this system has no use for.
            skip(source, entry.size);
            continue;
        }

        makeWay(paths.parent(to));
        if (take(source, to, entry.size)) taken += 1;
    }

    if (!listing) {
        out.decimal(taken);
        out.text(if (taken == 1) " thing taken out of " else " things taken out of ");
        out.text(name);
        out.byte('\n');
    }
    out.flush();
}

/// The directories on the way to something, made as far as they are missing.
/// An archive names a file under a directory it also carries, but not always
/// before it.
fn makeWay(path: []const u8) void {
    if (path.len == 0 or dir.isDirectory(path)) return;
    makeWay(paths.parent(path));
    sys.mkdir(path) catch {};
}

fn take(source: u32, to: []const u8, size: u64) bool {
    const target = sys.open(to, .{ .write = true, .create = true, .truncate = true }) catch {
        out.fault("unpack", to, "cannot create");
        skip(source, size);
        return false;
    };
    defer sys.close(target);

    var left = size;
    while (left > 0) {
        const room: usize = @intCast(@min(@as(u64, block.len), left));
        if (!fill(source, block[0..room])) return false;
        var at: usize = 0;
        while (at < room) {
            const wrote = sys.write(target, block[at..room]) catch 0;
            if (wrote == 0) {
                out.fault("unpack", to, "cannot write");
                return false;
            }
            at += wrote;
        }
        left -= room;
    }
    // Past the padding, to where the next header starts.
    const over: usize = @intCast(size % ustar.BLOCK);
    if (over != 0) _ = fill(source, block[0 .. ustar.BLOCK - over]);
    return true;
}

/// The rest of an entry's blocks, for one that is not being taken out.
fn skip(source: u32, size: u64) void {
    var left = ustar.blocksFor(size) * ustar.BLOCK;
    while (left > 0) {
        const room: usize = @intCast(@min(@as(u64, block.len), left));
        if (!fill(source, block[0..room])) return;
        left -= room;
    }
}

/// Exactly `into.len` bytes, or false at the end of the archive. A short read
/// is not the end: a filesystem may hand over less than was asked for.
fn fill(source: u32, into: []u8) bool {
    var at: usize = 0;
    while (at < into.len) {
        const got = sys.read(source, into[at..]) catch return false;
        if (got == 0) return false;
        at += got;
    }
    return true;
}

//! Reading a directory.
//!
//! `readdir` hands back one packed record per call and leaves the decoding to
//! whoever asked. Every caller was writing the same loop, and a file dialog
//! wants the whole listing at once rather than a callback, so it happens here.

const std = @import("std");
const sys = @import("sys");
const Bounded = @import("lib").Bounded;
const str = @import("lib").str;

/// One name, and enough about it to show a row.
pub const Entry = struct {
    /// Points into the caller's buffer, so that has to outlive the listing.
    name: []const u8 = "",
    size: u32 = 0,
    mtime: i64 = 0,
    is_dir: bool = false,
};

/// Enough for a directory anyone will look at in one window. A listing that
/// stopped early without saying so would be worse than one that is bounded.
pub const MAX = 96;

pub const Listing = struct {
    entries: Bounded(Entry, MAX) = .{},
    /// The directory held more than `MAX`, so what is here is not all of it.
    truncated: bool = false,

    pub fn items(self: *const Listing) []const Entry {
        return self.entries.slice();
    }
};

pub const Error = error{ NotFound, NoRoom };

/// List `path`, copying the names into `names`.
///
/// Directories come first and each group is sorted, because a listing in the
/// order the filesystem happens to hold it is a listing nobody can scan. The
/// parent sorts to the very top, where a person looking for the way out of a
/// directory will look for it.
pub fn read(path: []const u8, names: []u8, out: *Listing) Error!void {
    const handle = sys.open(path, .{ .directory = true });
    if (handle < 0) return error.NotFound;
    defer _ = sys.close(@intCast(handle));

    out.* = .{};
    var used: usize = 0;

    while (true) {
        var record: [512]u8 = undefined;
        const n = sys.readdir(@intCast(handle), &record);
        if (n <= 0) break;

        const entry = sys.Dirent.decode(&record, @intCast(n)) orelse continue;

        if (used + entry.name.len > names.len) return error.NoRoom;

        const stored = names[used..][0..entry.name.len];
        @memcpy(stored, entry.name);

        out.entries.append(.{
            .name = stored,
            .size = entry.size,
            .mtime = entry.mtime,
            .is_dir = entry.is_dir,
        }) catch {
            out.truncated = true;
            break;
        };
        used += entry.name.len;
    }

    sort(out.entries.mutable());
}

/// Insertion sort, named rather than left to `std.mem.sort`.
///
/// `std.mem.sort` is a block sort, and a block sort keeps a `[512]T` cache in
/// its own frame: for an entry of this size that is sixteen kilobytes of a
/// thirty-two kilobyte user stack, which overflows the moment a caller reads
/// one directory from inside another. Insertion sort needs no memory at all,
/// and at `MAX` entries the comparisons are not worth counting.
fn sort(entries: []Entry) void {
    std.sort.insertion(Entry, entries, {}, before);
}

pub const PARENT = "..";

fn before(_: void, a: Entry, b: Entry) bool {
    const a_parent = str.eql(a.name, PARENT);
    const b_parent = str.eql(b.name, PARENT);
    if (a_parent != b_parent) return a_parent;

    if (a.is_dir != b.is_dir) return a.is_dir;
    return lessCaseless(a.name, b.name);
}

/// Compare without regard to case, because FAT stores short names upper-cased
/// and a sort that took that literally would put every short name before every
/// long one.
fn lessCaseless(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        const lx = lower(x);
        const ly = lower(y);
        if (lx != ly) return lx < ly;
    }
    return a.len < b.len;
}

fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}

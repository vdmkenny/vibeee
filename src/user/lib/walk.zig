//! A directory and everything under it.
//!
//! `dir.read` answers what is in one place. This carries that down, keeping
//! each level's listing alive while its children are walked, which is the part
//! two tools were writing separately: `tree` to draw the shape and `find` to
//! look for a name in it.
//!
//! Bounded in depth and held beside the caller rather than on its frame. A
//! level's listing is a kilobyte of names, and the user stack is thirty-two
//! for everything: a walk that put them on it would run out somewhere down a
//! deep tree rather than say it had stopped.

const dir = @import("dir.zig");
const paths = @import("paths.zig");
const str = @import("lib").str;

/// How far down to go. A walk that stops says so in its summary.
pub const MAX_DEPTH = 8;

/// One name the walk reached.
pub const Name = struct {
    /// What it is called, without where it is.
    name: []const u8,
    /// Where it is, which is what a caller opens. Points into the walk and
    /// lasts until it moves on.
    path: []const u8,
    is_dir: bool,
    size: u32,
    mtime: i64,
    /// Nothing else follows at this level, which is what line art needs and
    /// what nothing else does.
    last: bool,
};

/// What the walk found at one place.
///
/// A directory it could not read and a listing it could not hold whole are
/// places in the tree rather than figures in a summary, so they are reported
/// where they happened.
pub const Found = union(enum) {
    name: Name,
    unreadable,
    more,
};

/// What a whole walk came to.
pub const Summary = struct {
    dirs: usize = 0,
    files: usize = 0,
    /// Something below `MAX_DEPTH` went unwalked.
    cut: bool = false,
};

/// One level's listing and the names it points into. One per level, because a
/// level's entries have to outlive the walk into its children.
const Level = struct {
    listing: dir.Listing = .{},
    names: [1024]u8 = @splat(0),
};

pub const Walk = struct {
    levels: [MAX_DEPTH]Level = @splat(.{}),
    path_buf: [paths.MAX]u8 = @splat(0),
    path: str.Builder = undefined,
    summary: Summary = .{},

    /// Walk `root`, handing every place to `visit` with the depth it sits at.
    ///
    /// Pre-order: a directory is reported before what is inside it, which is
    /// the order both a drawing and a search want.
    pub fn each(
        self: *Walk,
        root: []const u8,
        ctx: anytype,
        comptime visit: fn (@TypeOf(ctx), usize, Found) void,
    ) Summary {
        self.path = .{ .buf = &self.path_buf };
        self.path.text(root);
        self.summary = .{};
        self.list(0, ctx, visit);
        return self.summary;
    }

    fn list(
        self: *Walk,
        depth: usize,
        ctx: anytype,
        comptime visit: fn (@TypeOf(ctx), usize, Found) void,
    ) void {
        const level = &self.levels[depth];
        dir.read(self.path.done(), &level.names, &level.listing) catch
            return visit(ctx, depth, .unreadable);

        // Dotted names are the way out of a directory and the way to hide a
        // file. Neither is part of what is here, and both have to be
        // discounted before anything can be called the last one.
        var shown: usize = 0;
        for (level.listing.items()) |entry| {
            if (!hidden(entry.name)) shown += 1;
        }

        var seen: usize = 0;
        for (level.listing.items()) |entry| {
            if (hidden(entry.name)) continue;
            seen += 1;

            const was = self.path.len;
            var below: [paths.MAX]u8 = undefined;
            const full = paths.joined(self.path.done(), entry.name, &below) orelse {
                visit(ctx, depth, .unreadable);
                continue;
            };

            visit(ctx, depth, .{ .name = .{
                .name = entry.name,
                .path = full,
                .is_dir = entry.is_dir,
                .size = entry.size,
                .mtime = entry.mtime,
                .last = seen == shown and !level.listing.truncated,
            } });

            if (!entry.is_dir) {
                self.summary.files += 1;
                continue;
            }
            self.summary.dirs += 1;

            if (depth + 1 == MAX_DEPTH) {
                self.summary.cut = true;
                continue;
            }

            // Down into it and back out again, so the next name at this level
            // is joined onto the path this one was.
            self.path.len = 0;
            self.path.text(full);
            self.list(depth + 1, ctx, visit);
            self.path.len = was;
        }

        if (level.listing.truncated) visit(ctx, depth, .more);
    }
};

fn hidden(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

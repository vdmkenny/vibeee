//! tree, a directory and everything under it.
//!
//! `ls` answers what is in one directory, which is the wrong question when what
//! you are looking for is somewhere in a shape you do not know yet. This draws
//! the shape.
//!
//! Drawn in the box-drawing characters, which the console reads: it decodes
//! UTF-8 and, in text mode, maps them onto the ones the hardware font has had
//! since it was a hardware font.

const dir = @import("ulib").dir;
const Rung = @import("ulib").tree.Rung;
const out = @import("ulib").out;
const paths = @import("ulib").paths;
const str = @import("ulib").str;

/// How far down to go. Bounded because the walk recurses and the stack is
/// finite; a tree that stops says so rather than running out of room.
const MAX_DEPTH = 8;

/// Whether an entry had anything after it, which is the only thing the line art
/// depends on. Asking once and drawing from the answer keeps the two halves of
/// a rung from disagreeing about which one this is.
/// One level's listing and the names it points into. One per level, because a
/// level's entries have to outlive the walk into its children.
const Level = struct {
    listing: dir.Listing = .{},
    names: [1024]u8 = @splat(0),
};

const Walk = struct {
    levels: [MAX_DEPTH]Level = @splat(.{}),
    /// What each ancestor was, which is what decides whether its rail carries
    /// down past this line. Kept as the rungs themselves rather than as the
    /// characters they draw: the two forms are different byte lengths, and a
    /// buffer of them could not be indexed by depth.
    rails: [MAX_DEPTH]Rung = @splat(.last),
    path_buf: [256]u8 = @splat(0),
    path: str.Builder = undefined,

    dirs: usize = 0,
    files: usize = 0,
    /// Something below `MAX_DEPTH` went unlisted.
    cut: bool = false,

    fn start(self: *Walk, root: []const u8) void {
        self.path = .{ .buf = &self.path_buf };
        self.path.text(root);
        self.dirs = 0;
        self.files = 0;
        self.cut = false;
    }

    fn indent(self: *const Walk, depth: usize) void {
        for (self.rails[0..depth]) |rung| out.text(rung.under());
    }

    fn note(self: *Walk, depth: usize, rung: Rung, what: []const u8) void {
        self.indent(depth);
        out.text(rung.stem());
        out.text(what);
        out.byte('\n');
    }

    fn descend(self: *Walk, depth: usize, rung: Rung, name: []const u8) void {
        self.rails[depth] = rung;

        const was = self.path.len;
        defer self.path.len = was;

        var below: [self.path_buf.len]u8 = undefined;
        const joined = paths.join(self.path.done(), name, &below);
        self.path.len = 0;
        self.path.text(joined);

        self.list(depth + 1);
    }

    fn list(self: *Walk, depth: usize) void {
        const level = &self.levels[depth];
        dir.read(self.path.done(), &level.names, &level.listing) catch
            return self.note(depth, .last, "(unreadable)");

        // Dotted names are the way out of a directory and the way to hide a
        // file. Neither belongs in a picture of what is here, and both have to
        // be discounted before anything can be called the last one.
        var shown: usize = 0;
        for (level.listing.items()) |entry| {
            if (!hidden(entry.name)) shown += 1;
        }

        var seen: usize = 0;
        for (level.listing.items()) |entry| {
            if (hidden(entry.name)) continue;
            seen += 1;
            const rung: Rung = if (seen == shown and !level.listing.truncated) .last else .more;

            self.indent(depth);
            out.text(rung.stem());
            out.text(entry.name);
            if (entry.is_dir) out.byte('/');
            out.byte('\n');

            if (!entry.is_dir) {
                self.files += 1;
                continue;
            }
            self.dirs += 1;

            if (depth + 1 == MAX_DEPTH) {
                self.cut = true;
                continue;
            }
            self.descend(depth, rung, entry.name);
        }

        if (level.listing.truncated) self.note(depth, .last, "(more, not listed)");
    }

    fn summarise(self: *const Walk) void {
        out.decimal(self.dirs);
        out.text(if (self.dirs == 1) " directory, " else " directories, ");
        out.decimal(self.files);
        out.text(if (self.files == 1) " file" else " files");
        if (self.cut) {
            out.text(", stopped ");
            out.decimal(MAX_DEPTH);
            out.text(" deep");
        }
        out.byte('\n');
    }
};

/// Static because a level's listing is kilobytes and there are several of them:
/// this is far more than a user stack should be carrying down a recursion.
var walk: Walk = .{};

pub fn run(args: []const []const u8) void {
    const root = if (args.len > 0) args[0] else ".";

    walk.start(root);
    out.text(root);
    out.byte('\n');
    walk.list(0);
    walk.summarise();
    out.flush();
}

fn hidden(name: []const u8) bool {
    return name.len > 0 and name[0] == '.';
}

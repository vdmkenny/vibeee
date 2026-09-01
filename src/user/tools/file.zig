//! file, what something is rather than what it is called.
//!
//! FAT has no type beyond the name, and a name is a claim rather than a fact:
//! anything can be called `.TXT`. What a file holds is decided by looking at
//! it, which is also the only way to tell a program built for this machine
//! from one built for another.

const sys = @import("sys");
const dir = @import("ulib").dir;
const kind = @import("lib").kind;
const out = @import("ulib").out;

/// Enough to reach every signature the recogniser knows, and enough of a
/// text file for it to judge one by.
var head: [kind.ENOUGH]u8 = @splat(0);

pub fn run(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: file <path>...\n");
        out.flush();
        return;
    }

    for (args) |path| {
        out.pad(path, 14);
        // A path longer than the column still gets its gap: two things run
        // together read as one thing nobody can parse.
        out.byte(' ');
        describe(path);
        out.byte('\n');
    }
    out.flush();
}

fn describe(path: []const u8) void {
    if (dir.isDirectory(path)) return out.text(kind.Kind.directory.says());

    const handle = sys.open(path, .{});
    if (handle < 0) {
        out.text("cannot open");
        return;
    }
    defer _ = sys.close(@intCast(handle));

    const n = sys.read(@intCast(handle), &head);
    if (n <= 0) {
        out.text(kind.Kind.empty.says());
        return;
    }
    var room: [kind.SAYS_MAX]u8 = undefined;
    out.text(kind.fromBytes(head[0..@intCast(n)]).says(&room));
}

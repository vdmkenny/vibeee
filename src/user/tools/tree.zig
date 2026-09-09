//! tree, a directory and everything under it.
//!
//! `ls` answers what is in one directory, which is the wrong question when what
//! you are looking for is somewhere in a shape you do not know yet. This draws
//! the shape.
//!
//! Drawn in the box-drawing characters, which the console reads: it decodes
//! UTF-8 and, in text mode, maps them onto the ones the hardware font has had
//! since it was a hardware font.
//!
//! The walking is `ulib.walk`, shared with `find`. What is left here is the
//! drawing, which is all this command is.

const Rung = @import("ulib").tree.Rung;
const out = @import("ulib").out;
const walk = @import("ulib").walk;

/// What each ancestor was, which is what decides whether its rail carries down
/// past this line. Kept as the rungs themselves rather than as the characters
/// they draw: the two forms are different byte lengths, and a buffer of them
/// could not be indexed by depth.
var rails: [walk.MAX_DEPTH]Rung = @splat(.last);

/// Beside the drawing rather than on its frame: a walk carries a listing per
/// level, which is far more than a user stack should hold.
var walker: walk.Walk = .{};

pub fn run(args: []const []const u8) void {
    const root = if (args.len > 0) args[0] else ".";

    out.text(root);
    out.byte('\n');
    const seen = walker.each(root, {}, draw);

    out.decimal(seen.dirs);
    out.text(if (seen.dirs == 1) " directory, " else " directories, ");
    out.decimal(seen.files);
    out.text(if (seen.files == 1) " file" else " files");
    if (seen.cut) {
        out.text(", stopped ");
        out.decimal(walk.MAX_DEPTH);
        out.text(" deep");
    }
    out.byte('\n');
    out.flush();
}

fn draw(_: void, depth: usize, found: walk.Found) void {
    switch (found) {
        .name => |it| {
            rails[depth] = if (it.last) .last else .more;
            indent(depth);
            out.text(rails[depth].stem());
            out.text(it.name);
            if (it.is_dir) out.byte('/');
            out.byte('\n');
        },
        .unreadable => note(depth, "(unreadable)"),
        .more => note(depth, "(more, not listed)"),
    }
}

fn indent(depth: usize) void {
    for (rails[0..depth]) |rung| out.text(rung.under());
}

fn note(depth: usize, what: []const u8) void {
    indent(depth);
    out.text(Rung.last.stem());
    out.text(what);
    out.byte('\n');
}

//! mount and unmount: what is attached where.
//!
//! Listing is `disk`'s job and stays there, because a volume and the drive it
//! sits on are one picture and splitting it across two tools would mean
//! reading both to answer one question.

const std = @import("std");
const sys = @import("sys");
const dir = @import("ulib").dir;
const out = @import("ulib").out;

pub fn mount(args: []const []const u8) void {
    if (args.len < 2) return usage();

    var flags = sys.MountFlags{};
    var rest = args;
    while (rest.len > 0 and std.mem.startsWith(u8, rest[0], "-")) {
        if (std.mem.eql(u8, rest[0], "-r")) flags.read_only = true;
        rest = rest[1..];
    }

    if (rest.len < 2) return usage();

    const volume = rest[0];
    const where = rest[1];

    // Said before the attempt rather than guessed from the failure: a path
    // whose parent is not there is the ordinary mistake, and "no such file"
    // from a call naming two paths does not say which one.
    //
    // The last part of the path need not exist. A mount takes a name in its
    // parent, which is how the kernel's own automatic mounts arrive, and a
    // tool that insisted on a directory already being there would make a
    // volume unmountable back to where it came from.
    const parent = parentOf(where);
    if (!dir.isDirectory(parent)) {
        out.text("mount: ");
        out.text(parent);
        out.text(": not a directory\n");
        out.flush();
        return;
    }

    report("mount", volume, sys.mount(volume, where, flags));
}

pub fn unmount(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: unmount <path>\n");
        out.flush();
        return;
    }
    report("unmount", args[0], sys.unmount(args[0]));
}

/// Say what did not work and why. The kernel already knows the reason; a tool
/// that swallowed it and said "cannot mount" would be throwing away the only
/// part of the answer worth having.
fn report(tool: []const u8, subject: []const u8, outcome: sys.Refusal!void) void {
    outcome catch |why| {
        out.text(tool);
        out.text(": ");
        out.text(subject);
        out.text(": ");
        out.text(sys.reasonOf(why));
        out.byte('\n');
        out.flush();
    };
}

/// The directory a path names something in. The root's parent is itself,
/// and a path with no separator names something in the working directory.
fn parentOf(path: []const u8) []const u8 {
    const trimmed = if (path.len > 1 and path[path.len - 1] == '/') path[0 .. path.len - 1] else path;
    const cut = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return ".";
    return if (cut == 0) "/" else trimmed[0..cut];
}

fn usage() void {
    out.text("usage: mount [-r] <volume> <path>\n");
    out.text("       unmount <path>\n");
    out.text("`disk` lists what there is to mount.\n");
    out.flush();
}

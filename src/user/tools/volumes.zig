//! mount and unmount: what is attached where.
//!
//! Listing is `disk`'s job and stays there, because a volume and the drive it
//! sits on are one picture and splitting it across two tools would mean
//! reading both to answer one question.

const sys = @import("sys");
const dir = @import("ulib").dir;
const out = @import("ulib").out;
const str = @import("ulib").str;

pub fn mount(args: []const []const u8) void {
    if (args.len < 2) return usage();

    var flags = sys.MountFlags{};
    var rest = args;
    while (rest.len > 0 and str.startsWith(rest[0], "-")) {
        if (str.eql(rest[0], "-r")) flags.read_only = true;
        rest = rest[1..];
    }

    if (rest.len < 2) return usage();

    const volume = rest[0];
    const where = rest[1];

    // Said before the attempt rather than guessed from the failure: a mount
    // point that is not there yet is the ordinary mistake, and "no such file"
    // from a call naming two paths does not say which one.
    if (!dir.isDirectory(where)) {
        out.text("mount: ");
        out.text(where);
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
fn report(tool: []const u8, subject: []const u8, result: isize) void {
    if (result >= 0) return;

    out.text(tool);
    out.text(": ");
    out.text(subject);
    out.text(": ");
    out.text(sys.reasonFor(result));
    out.byte('\n');
    out.flush();
}

fn usage() void {
    out.text("usage: mount [-r] <volume> <path>\n");
    out.text("       unmount <path>\n");
    out.text("`disk` lists what there is to mount.\n");
    out.flush();
}

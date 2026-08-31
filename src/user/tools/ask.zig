//! sysinfo: any key the kernel answers, by name.
//!
//! The kernel's `sysinfo` interface is the one place it describes itself,
//! and every window and tool that shows a fact reads it from there. This is
//! the shell's direct line to the same place: whatever a pane can show, a
//! command can print, and a key added for a new pane is scriptable the same
//! day. Without an argument it lists nothing and says so; the keys live in
//! the manual, and guessing them is what the manual is for.

const info = @import("ulib").info;
const out = @import("ulib").out;

pub fn run(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: sysinfo <key>\n");
        out.text("keys are listed in `man sysinfo`\n");
        out.flush();
        return;
    }

    // Large enough for the biggest text answer (`log` aside, which has its
    // own command). A key the kernel does not know prints nothing and says
    // so, which beats printing an empty line that looks like an answer.
    var buf: [4096]u8 = @splat(0);
    const value = info.ask(args[0], &buf);
    if (value.len == 0) {
        out.text("sysinfo: the kernel does not answer '");
        out.text(args[0]);
        out.text("'\n");
        out.flush();
        return;
    }

    out.text(value);
    out.text("\n");
    out.flush();
}

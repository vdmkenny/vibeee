//! sysinfo: any key the kernel answers, by name.
//!
//! The kernel's `sysinfo` interface is the one place it describes itself,
//! and every window and tool that shows a fact reads it from there. This is
//! the shell's direct line to the same place: whatever a pane can show, a
//! command can print, and a key added for a new pane is scriptable the same
//! day. Without an argument it lists what there is, asked of the kernel: a
//! list written down anywhere else is a list that drifts from the answers.

const info = @import("ulib").info;
const out = @import("ulib").out;

pub fn run(args: []const []const u8) void {
    // Large enough for the biggest text answer (`log` aside, which has its
    // own command). A key the kernel does not know prints nothing and says
    // so, which beats printing an empty line that looks like an answer.
    var buf: [4096]u8 = @splat(0);

    if (args.len == 0) {
        out.text("usage: sysinfo <key>\n\n");
        out.text(info.ask("keys", &buf));
        out.byte('\n');
        out.flush();
        return;
    }

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

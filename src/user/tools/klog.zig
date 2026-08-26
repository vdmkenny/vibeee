//! What the kernel has said, from userspace.
//!
//! Named `log` rather than after any other system's word for it. The kernel
//! keeps every message whether or not it printed one, so this shows a quiet
//! boot in full: the alternative is rebooting with `verbose` and hoping the
//! fault happens again.

const sys = @import("sys");
const info = @import("ulib").info;
const out = @import("ulib").out;
const str = @import("ulib").str;

/// The kernel's ring is eight kilobytes, so this is never truncated by being
/// too small. A stack that size would be half of what a process has, so it is
/// static.
var buffer: [8 * 1024]u8 = @splat(0);

pub fn log(args: []const []const u8) void {
    const text = info.ask("log", &buffer);
    if (text.len == 0) {
        out.text("the kernel has said nothing\n");
        out.flush();
        return;
    }

    // With an argument, only lines containing it. What anyone wants after the
    // first look, and cheaper than piping into `grep` on a shell with no pipes.
    const filter = if (args.len > 0) args[0] else "";

    var lines = str.lines(text);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (filter.len > 0 and !str.contains(line, filter)) continue;

        out.text(line);
        out.byte('\n');
    }
    out.flush();
}

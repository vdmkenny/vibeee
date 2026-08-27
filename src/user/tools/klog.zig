//! What the kernel has said, from userspace.
//!
//! Named `log` rather than after any other system's word for it. The kernel
//! keeps every message whether or not it printed one, so this shows a quiet
//! boot in full: the alternative is rebooting with `verbose` and hoping the
//! fault happens again.

const info = @import("ulib").info;
const ink = @import("ulib").ink;
const style = @import("lib").style;
const out = @import("ulib").out;
const str = @import("ulib").str;

/// One recorded line, coloured the way the console coloured it when it was
/// written. The key is the first word and the rest is the message, which is
/// the shape `console.field` gave it.
fn writeLine(line: []const u8) void {
    const key = firstWord(line);

    ink.write(roleOf(key), key);
    out.text(line[key.len..]);
    out.byte('\n');
}

/// What a line is: a failure, a warning, or one component reporting.
fn roleOf(key: []const u8) style.Role {
    if (str.eql(key, "fail")) return .bad;
    if (str.eql(key, "warn")) return .warn;
    return .key;
}

fn firstWord(line: []const u8) []const u8 {
    for (line, 0..) |c, i| {
        if (c == ' ') return line[0..i];
    }
    return line;
}

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

        writeLine(line);
    }
    out.flush();
}

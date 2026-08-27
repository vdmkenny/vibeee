//! What the kernel has said, from userspace.
//!
//! Named `log` rather than after any other system's word for it. The kernel
//! keeps every message whether or not it printed one, and the services tee
//! their own lines into the same ring, so this shows a quiet boot in full:
//! the alternative is rebooting with `verbose` and hoping the fault happens
//! again.
//!
//! `log [needle]` prints the lines containing a word; `log -n N` the last N
//! lines; with neither argument, the whole ring.

const info = @import("ulib").info;
const ink = @import("ulib").ink;
const style = @import("lib").style;
const out = @import("ulib").out;
const str = @import("ulib").str;

/// The ring is sixteen kilobytes, so this is never truncated by being too
/// small. A stack that size would be half of what a process has, so it is
/// static.
var buffer: [16 * 1024]u8 = @splat(0);

/// One recorded line, as a span into the ring text. A packed pair: sixteen
/// bits is exactly the size of the ring.
const Line = packed struct(u32) {
    start: u16,
    end: u16,
};

/// A line is at least the eight-column key, a space and a newline, so a full
/// ring holds fewer than this many; what does not fit is not shown rather
/// than never picked: the newest lines are the ones being looked for.
const MAX_LINES = 2048;

/// The lines worth showing, oldest first. Filled in one pass and written in
/// another, because which ones a `-n` tail wants is only knowable once the
/// pass is over.
const Pick = struct {
    lines: [MAX_LINES]Line,
    count: usize = 0,

    fn remember(self: *Pick, text: []const u8, line: []const u8) void {
        if (self.count >= MAX_LINES) return;
        const start = @intFromPtr(line.ptr) - @intFromPtr(text.ptr);
        self.lines[self.count] = .{ .start = @intCast(start), .end = @intCast(start + line.len) };
        self.count += 1;
    }
};

pub fn log(args: []const []const u8) void {
    const text = info.ask("log", &buffer);
    if (text.len == 0) {
        out.text("the kernel has said nothing\n");
        out.flush();
        return;
    }

    var tail: usize = 0;
    var needle: []const u8 = "";
    if (args.len >= 2 and str.eql(args[0], "-n")) {
        tail = str.toUnsigned(args[1]);
        needle = if (args.len > 2) args[2] else "";
    } else if (args.len > 0) {
        needle = args[0];
    }

    var picked = Pick{ .lines = undefined, .count = 0 };
    var lines = str.lines(text);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        if (needle.len > 0 and !str.contains(line, needle)) continue;
        picked.remember(text, line);
    }

    const from = if (tail > 0) picked.count -| tail else 0;
    for (picked.lines[from..picked.count]) |span| {
        writeLine(text[span.start..span.end]);
    }
    out.flush();
}

/// One recorded line, coloured the way the console coloured it when it was
/// written. The key is the first word and the rest is the message, which is
/// the shape `console.info` gave it.
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
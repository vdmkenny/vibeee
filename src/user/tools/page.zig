//! page, a pager: show a file a screen at a time and move around in it.
//!
//! The console scrolls and does not remember, so anything longer than the
//! screen is gone as soon as it is printed. This exists so a long report can
//! be read at all, which on a machine whose diagnostics are all long reports
//! is most of them. The viewing itself is the shared viewer's; this loads
//! the bytes and knows where standard input is worth reading.

const sys = @import("sys");
const out = @import("ulib").out;
const pager = @import("ulib").pager;
const str = @import("ulib").str;

/// As much of a file as this will hold. Past it the tail is dropped, and said
/// so rather than silently shown as if it were the whole file.
var text: [32 * 1024]u8 = @splat(0);
var filled: usize = 0;
var truncated = false;

pub fn run(args: []const []const u8) void {
    // With no argument the text comes from whatever is feeding standard
    // input, which is what makes `log | page` work and is most of what a
    // pager is for on a console that does not scroll back.
    const from: []const u8 = if (args.len > 0) args[0] else STDIN;

    // A pipe's read end is waitable; the interactive console is not. That
    // difference is the whole answer to "is anything feeding this": a bare
    // `page` at the prompt would otherwise sit reading the console forever,
    // showing nothing, with no way out.
    if (args.len == 0) {
        if (sys.waitMany(&[_]u32{sys.STDIN}, sys.FOREVER) < 0) {
            say("page: nothing to read; name a file or pipe something in\n");
            return;
        }
    }

    if (!load(from)) return;
    if (filled == 0) {
        say("page: nothing to read\n");
        return;
    }

    pager.view(.{
        .title = from,
        .text = text[0..filled],
        .truncated = truncated,
    });
}

/// What the status bar calls the stream when there is no file behind it.
const STDIN = "standard input";

fn load(from: []const u8) bool {
    const handle = open(from) orelse {
        out.text("page: ");
        out.text(from);
        out.text(": cannot open\n");
        out.flush();
        return false;
    };
    defer if (handle != sys.STDIN) {
        _ = sys.close(handle);
    };

    // Everything at once, before the screen is taken. A pager that read as it
    // scrolled could not say how many lines there are, and a pipe cannot be
    // rewound to count them later.
    while (filled < text.len) {
        const n = sys.read(handle, text[filled..]);
        if (n <= 0) break;
        filled += @intCast(n);
    }

    // A read that filled the buffer may have left more behind it.
    truncated = filled == text.len;
    return true;
}

fn open(from: []const u8) ?u32 {
    if (str.eql(from, STDIN)) return sys.STDIN;

    const handle = sys.open(from, .{});
    return if (handle < 0) null else @intCast(handle);
}

fn say(what: []const u8) void {
    out.text(what);
    out.flush();
}

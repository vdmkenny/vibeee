//! grep — print lines matching a pattern.
//!
//! Literal substring matching only. Regular expressions are a real parser and a
//! real matcher, and a half-implemented regex is worse than an honest
//! substring search: it accepts patterns it then quietly mismatches.
//!
//! Reads a file when given one and standard input otherwise, so it already
//! works as the receiving end of a pipeline once pipes exist.

const sys = @import("../syscall.zig");
const out = @import("../lib/out.zig");
const str = @import("../lib/str.zig");

pub fn run(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: grep <pattern> [file...]\n");
        out.flush();
        return;
    }

    const pattern = args[0];

    if (args.len == 1) {
        grepHandle(sys.STDIN, pattern, "", false);
    } else {
        // Prefix each match with its filename only when there is more than one
        // file, which is what makes the output unambiguous without being noisy.
        const show_names = args.len > 2;
        for (args[1..]) |path| {
            const handle = sys.open(path, 0);
            if (handle < 0) {
                out.text("grep: ");
                out.text(path);
                out.text(": cannot open\n");
                continue;
            }
            grepHandle(@intCast(handle), pattern, path, show_names);
            _ = sys.close(@intCast(handle));
        }
    }
    out.flush();
}

fn grepHandle(handle: usize, pattern: []const u8, name: []const u8, show_name: bool) void {
    var chunk: [4096]u8 = [_]u8{0} ** 4096;
    var line: [1024]u8 = [_]u8{0} ** 1024;
    var line_len: usize = 0;

    while (true) {
        const n = sys.read(handle, &chunk);
        if (n <= 0) break;

        for (chunk[0..@intCast(n)]) |c| {
            if (c == '\n') {
                emitIfMatch(line[0..line_len], pattern, name, show_name);
                line_len = 0;
                continue;
            }
            // A line longer than the buffer is truncated rather than dropped:
            // losing the tail of a very long line beats losing the match.
            if (line_len < line.len) {
                line[line_len] = c;
                line_len += 1;
            }
        }
    }

    // A final line with no trailing newline still counts.
    if (line_len > 0) emitIfMatch(line[0..line_len], pattern, name, show_name);
}

fn emitIfMatch(line: []const u8, pattern: []const u8, name: []const u8, show_name: bool) void {
    if (!str.contains(line, pattern)) return;
    if (show_name) {
        out.text(name);
        out.text(":");
    }
    out.text(line);
    out.text("\n");
}


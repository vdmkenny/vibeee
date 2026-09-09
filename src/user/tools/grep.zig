//! grep, print lines matching a pattern.
//!
//! Literal substring matching only. Regular expressions are a real parser and a
//! real matcher, and a half-implemented regex is worse than an honest
//! substring search: it accepts patterns it then quietly mismatches.
//!
//! Reads a file when given one and standard input otherwise, so it sits at the
//! receiving end of a pipeline.

const std = @import("std");
const sys = @import("sys");
const lines = @import("ulib").lines;
const out = @import("ulib").out;

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
            const handle = sys.open(path, .{}) catch {
                out.fault("grep", path, "cannot open");
                continue;
            };
            grepHandle(handle, pattern, path, show_names);
            sys.close(handle);
        }
    }
    out.flush();
}

/// Beside the other state rather than on the frame: a reader is kilobytes and
/// the user stack is not many of them.
var reader: lines.Reader = .{};

fn grepHandle(handle: u32, pattern: []const u8, name: []const u8, show_name: bool) void {
    reader = lines.Reader.of(handle);
    while (reader.next()) |line| emitIfMatch(line, pattern, name, show_name);
}

fn emitIfMatch(line: []const u8, pattern: []const u8, name: []const u8, show_name: bool) void {
    if (!(std.mem.indexOf(u8, line, pattern) != null)) return;
    if (show_name) {
        out.text(name);
        out.text(":");
    }
    out.text(line);
    out.text("\n");
}

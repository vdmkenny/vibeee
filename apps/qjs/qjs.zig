//! qjs: run a script.
//!
//! QuickJS, vendored under `third_party/quickjs` and built into this program,
//! with a script read from a file. What a script gets is the language, `print`
//! and `console.log`, and the bounds every script here runs under. No files,
//! no network, no window: those are the system's to give, and are not given.
//!
//! Not part of the system. It is built into `home/bin/` and versioned on its
//! own.

const std = @import("std");
const sys = @import("sys");
const ulib = @import("ulib");
const js = @import("js");
const qjs = @import("quickjs");

const env = ulib.env;
const file = ulib.file;
const heap = ulib.heap;
const out = ulib.out;

// The routines quickjs's C calls by name.
comptime {
    _ = @import("clibc");
}

const gpa = heap.allocator;

/// The most a script may be. A program is a file of words; four megabytes of
/// them is a book, and a script is not one.
const SCRIPT_MAX = 4 * 1024 * 1024;

export fn _start(frame: [*]usize) callconv(.c) noreturn {
    const path = env.argument(frame) orelse usage();
    const script = file.readAlloc(gpa, path, SCRIPT_MAX) catch |err| fatal(path, err);
    defer gpa.free(script);

    const machine = js.start(&sys.clockMicros, &say) orelse {
        out.trouble("qjs: the engine would not start\n");
        sys.exit(1);
    };
    const held = machine.open() orelse {
        out.trouble("qjs: the engine would not start\n");
        sys.exit(1);
    };
    defer machine.close(held);

    // A script named as a module is read as one; any other is read as a
    // script, which is what the engine does with a file it is given.
    var name: [256]u8 = undefined;
    const called = std.fmt.bufPrintZ(&name, "{s}", .{path}) catch "script";
    const ended = machine.run(held, script, called, if (std.mem.endsWith(u8, path, ".mjs")) .module else .global);
    defer qjs.free(held, ended);
    if (qjs.isException(ended)) {
        machine.tellError(held);
    } else if (!qjs.isUndefined(ended)) {
        if (qjs.sliceOf(held, ended)) |text| {
            defer qjs.freeText(held, text.ptr);
            say(text);
        }
    }
    // What a script left waiting runs after it has been read, so a promise
    // made at the top of it is kept even where the answer was already given.
    _ = machine.runJobs();
    out.flush();
    sys.exit(0);
}

/// What a script says, a line each, on standard output.
fn say(text: []const u8) void {
    out.text(text);
    out.text("\n");
}

fn usage() noreturn {
    out.trouble("usage: qjs <script.js>\n");
    sys.exit(2);
}

fn fatal(path: []const u8, why: file.AllocError) noreturn {
    out.fault("qjs", path, @errorName(why));
    sys.exit(1);
}

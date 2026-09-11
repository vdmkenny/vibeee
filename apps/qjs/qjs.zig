//! qjs: run a script.
//!
//! QuickJS, vendored under `third_party/quickjs` and built into this program,
//! with a script read from a file. It is the first half of giving the reader a
//! script to run: the engine running here at all, on this machine, in a
//! program of this system's, before anything of a page is put in front of it.
//!
//! What a script gets is what the engine has and what `quickjsport` adds:
//! the language, `print`, `console.log` and the rest of the standard objects.
//! No files, no network, no window: those are the system's to give, and are
//! not given yet.
//!
//! Not part of the system. It is built into `home/bin/` and versioned on its
//! own.

const std = @import("std");
const sys = @import("sys");
const ulib = @import("ulib");

const env = ulib.env;
const file = ulib.file;
const heap = ulib.heap;
const out = ulib.out;
const engine = @import("js");

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

    const machine = engine.start() orelse {
        out.trouble("qjs: the engine would not start\n");
        sys.exit(1);
    };
    const held = engine.open(machine) orelse {
        out.trouble("qjs: the engine would not start\n");
        sys.exit(1);
    };
    defer engine.close(held);

    // A script named as a module is read as one; any other is read as a
    // script, which is what the engine does with a file it is given.
    const ended = engine.run(held, script, path, std.mem.endsWith(u8, path, ".mjs"));
    if (ended) |value| {
        defer engine.giveBack(held, value);
        out.text(std.mem.span(value));
        out.text("\n");
    } else {
        engine.tellError(held);
    }
    // What a script left waiting runs after it has been read, so a promise
    // made at the top of it is kept even where the answer was already given.
    engine.loop(held);
    out.flush();
    sys.exit(0);
}

fn usage() noreturn {
    out.trouble("usage: qjs <script.js>\n");
    sys.exit(2);
}

fn fatal(path: []const u8, why: file.AllocError) noreturn {
    out.fault("qjs", path, @errorName(why));
    sys.exit(1);
}

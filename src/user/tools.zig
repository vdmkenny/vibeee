//! vibeee system tools.
//!
//! A multicall binary: one image, dispatched on its first argument. That is how
//! the rest of the utilities will ship too, thirty separate static binaries
//! would repeat the same few kilobytes of support code thirty times, on a
//! machine where the root filesystem is read into RAM at every boot.
//!
//! The command table lives in `tools/registry.zig`, which the shell reads too:
//! dispatch and the help text are both generated from it, so a command cannot
//! exist without being listed.

const std = @import("std");
const sys = @import("sys");
const registry = @import("tools/registry.zig");
const out = @import("ulib").out;

const commands = registry.commands;

/// The kernel enters every program as one C call whose argument is the
/// argc/argv frame it built, so taking it is an ordinary parameter.
export fn _start(frame: [*]const u32) callconv(.c) noreturn {
    toolsMain(frame);
}

var argv_storage: [sys.MAX_ARGS][]const u8 = undefined;

fn toolsMain(frame: [*]const u32) noreturn {
    const argc: usize = frame[0];
    const count = @min(argc, sys.MAX_ARGS);

    for (0..count) |i| {
        const ptr: [*:0]const u8 = @ptrFromInt(frame[1 + i]);
        argv_storage[i] = std.mem.span(ptr);
    }
    const argv = argv_storage[0..count];

    // argv[0] is the image name; the command is the argument after it, so the
    // same binary can also be invoked by a symlink-style name later.
    const command = if (argv.len > 1) argv[1] else "help";

    for (commands) |c| {
        if (std.mem.eql(u8, c.name, command)) {
            c.run(argv[@min(2, argv.len)..]);
            sys.exit(0);
        }
    }

    out.text("unknown command: ");
    out.text(command);
    out.text("\n");
    listCommands();
    sys.exit(1);
}

fn listCommands() void {
    out.text("commands:\n");
    for (commands) |c| {
        out.text("  ");
        out.pad(c.name, 12);
        out.text(c.summary);
        out.text("\n");
    }
}

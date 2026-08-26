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

const sys = @import("sys");
const registry = @import("tools/registry.zig");
const out = @import("ulib").out;
const str = @import("ulib").str;

const commands = registry.commands;

export fn _start() callconv(.naked) noreturn {
    // argc and argv are already on the stack, placed there by the kernel. The
    // stack pointer is the argument frame, so pass it straight through.
    asm volatile (
        \\ xorl %ebp, %ebp
        \\ movl %esp, %eax
        \\ pushl %eax
        \\ call toolsMain
        \\ hlt
    );
}

var argv_storage: [sys.MAX_ARGS][]const u8 = undefined;

export fn toolsMain(frame: [*]const u32) callconv(.c) noreturn {
    const argc: usize = frame[0];
    const count = @min(argc, sys.MAX_ARGS);

    for (0..count) |i| {
        const ptr: [*:0]const u8 = @ptrFromInt(frame[1 + i]);
        argv_storage[i] = str.span(ptr);
    }
    const argv = argv_storage[0..count];

    // argv[0] is the image name; the command is the argument after it, so the
    // same binary can also be invoked by a symlink-style name later.
    const command = if (argv.len > 1) argv[1] else "help";

    for (commands) |c| {
        if (str.eql(c.name, command)) {
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



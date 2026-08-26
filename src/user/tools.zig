//! vibeee system tools.
//!
//! A multicall binary: one image, dispatched on its first argument. That is how
//! the rest of the utilities will ship too, thirty separate static binaries
//! would repeat the same few kilobytes of support code thirty times, on a
//! machine where the root filesystem is read into RAM at every boot.
//!
//! The command table is the single definition: dispatch and the help text are
//! both generated from it, so a command cannot exist without being listed.

const sys = @import("sys");
const eeefetch = @import("tools/eeefetch.zig");
const dmidecode = @import("tools/dmidecode.zig");
const date = @import("tools/date.zig");
const files = @import("tools/files.zig");
const grep = @import("tools/grep.zig");
const pointer = @import("tools/pointer.zig");
const ringtest = @import("tools/ringtest.zig");
const irq_tool = @import("tools/irq.zig");
const status = @import("tools/status.zig");
const out = @import("ulib").out;
const str = @import("ulib").str;

const Command = struct {
    name: []const u8,
    summary: []const u8,
    run: *const fn (args: []const []const u8) void,
};

const commands = [_]Command{
    .{ .name = "ls", .summary = "list a directory", .run = &files.ls },
    .{ .name = "cat", .summary = "print a file", .run = &files.cat },
    .{ .name = "rm", .summary = "remove a file", .run = &files.rm },
    .{ .name = "hexdump", .summary = "dump a file in hex", .run = &files.hexdump },
    .{ .name = "grep", .summary = "print lines matching a pattern", .run = &grep.run },
    .{ .name = "free", .summary = "show memory use", .run = &status.free },
    .{ .name = "top", .summary = "show threads and load", .run = &status.top },
    .{ .name = "kill", .summary = "end a process by id", .run = &status.kill },
    .{ .name = "irq", .summary = "interrupt lines held outside the kernel", .run = &irq_tool.irq },
    .{ .name = "pointer", .summary = "show pointer movement and clicks", .run = &pointer.run },
    .{ .name = "ringtest", .summary = "prove shared memory between two processes", .run = &ringtest.run },
    .{ .name = "svc", .summary = "list registered services", .run = &status.services },
    .{ .name = "disk", .summary = "list drives and volumes", .run = &status.disk },
    .{ .name = "date", .summary = "show the wall-clock time", .run = &date.run },
    .{ .name = "eeefetch", .summary = "show system information", .run = &eeefetch.run },
    .{ .name = "dmidecode", .summary = "decode the firmware DMI tables", .run = &dmidecode.run },
    .{ .name = "help", .summary = "list commands", .run = &help },
};

fn help(_: []const []const u8) void {
    listCommands();
    out.flush();
}

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



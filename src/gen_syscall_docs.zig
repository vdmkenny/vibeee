//! Generates docs/syscalls.md from the syscall table.
//!
//! The table is the source of truth; this is a projection of it. Running as
//! part of `zig build` means the documentation cannot describe an interface the
//! kernel does not implement, which is the usual way syscall docs go wrong.

const std = @import("std");
const abi = @import("lib/syscalls.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const out_path = if (args.len > 1) args[1] else "docs/syscalls.md";

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(init.gpa);
    const w = &buf;
    const gpa = init.gpa;

    try w.appendSlice(gpa,
        \\# vibeee system calls
        \\
        \\<!-- Generated from src/lib/syscalls.zig by `zig build syscall-docs`.
        \\     Do not edit: change the table instead. -->
        \\
        \\Calls enter the kernel through `SYSENTER` where the CPU provides it, and
        \\through `int 0x80` otherwise; the choice is made once at libc start-up and
        \\the register convention is identical either way.
        \\
        \\| register | meaning |
        \\|---|---|
        \\| `eax` | call number on entry, result on return |
        \\| `ebx`, `ecx`, `edx`, `esi`, `edi` | arguments 0-4 |
        \\
        \\A negative result is `-errno`. Pointer arguments are validated against the
        \\caller's address space before use, and a range crossing into kernel memory
        \\fails with `EFAULT` rather than faulting.
        \\
        \\
    );

    for (abi.table) |sc| {
        try w.print(gpa, "## `{s}`  <sub>#{d}</sub>\n\n{s}\n\n", .{ sc.name, sc.number, sc.summary });

        if (sc.args.len > 0) {
            try w.appendSlice(gpa, "| arg | type | meaning |\n|---|---|---|\n");
            for (sc.args) |arg| {
                try w.print(gpa, "| `{s}` | {s} | {s} |\n", .{ arg.name, arg.kind.label(), arg.desc });
            }
            try w.appendSlice(gpa, "\n");
        }

        try w.print(gpa, "**Returns:** {s}\n\n", .{sc.returns});

        if (sc.errors.len > 0) {
            try w.appendSlice(gpa, "**Errors:**\n\n");
            for (sc.errors) |e| {
                try w.print(gpa, "- `{s}`, {s}\n", .{ e.name, e.when });
            }
            try w.appendSlice(gpa, "\n");
        }

        if (sc.notes.len > 0) try w.print(gpa, "{s}\n\n", .{sc.notes});
    }

    try w.print(gpa, "---\n\n{d} calls defined.\n", .{abi.table.len});

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = buf.items });
    std.debug.print("wrote {s} ({d} calls)\n", .{ out_path, abi.table.len });
}

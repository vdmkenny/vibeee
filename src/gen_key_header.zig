//! Writes the C header naming this system's key numbers and modifier bits.
//!
//! Both live in one place, `KeyCode` and `Modifiers` in the syscall table,
//! and a C program needs them by name. Written from those declarations
//! rather than beside them: two lists agreeing today is not two lists
//! agreeing, and a key renumbered on one side would reach a program as a
//! different key with nothing to say so.
//!
//! Everything is named, not a chosen few. Choosing would mean choosing
//! again whenever somebody wanted one that was not chosen.

const std = @import("std");
const abi = @import("lib/syscalls.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;

    // A hundred or so keys, each name walked a character at a time to
    // shout it. Well within reach, but past the default allowance.
    @setEvalBranchQuota(std.meta.fields(abi.KeyCode).len * 200);

    const args = try init.minimal.args.toSlice(arena);
    if (args.len < 2) {
        std.debug.print("usage: gen-key-header <out.h>\n", .{});
        return error.Usage;
    }

    var text: std.ArrayList(u8) = .empty;
    try text.appendSlice(arena,
        \\/* Generated from KeyCode and Modifiers in src/lib/syscalls.zig.
        \\ * Do not edit: the numbers are theirs, and this is written from
        \\ * them so the two cannot come to disagree. */
        \\#ifndef _VIBEEE_KEYS_H
        \\#define _VIBEEE_KEYS_H
        \\
        \\/* Which key it was. Letters and digits also arrive as a codepoint;
        \\ * these are for the keys that are not text. */
        \\
    );
    inline for (std.meta.fields(abi.KeyCode)) |key| {
        try text.print(arena, "#define VB_KEY_{s} {d}\n", .{ comptime shout(key.name), key.value });
    }

    try text.appendSlice(arena,
        \\
        \\/* What was held down with it, as a mask over the `modifiers` byte. */
        \\
    );
    // A packed struct's fields are its bits in order, so the mask for one
    // is where the fields before it end.
    comptime var bit: u8 = 0;
    inline for (std.meta.fields(abi.Modifiers)) |modifier| {
        const width = @bitSizeOf(modifier.type);
        if (comptime named(modifier.name) and width == 1) {
            try text.print(arena, "#define VB_MOD_{s} 0x{X:0>2}\n", .{
                comptime shout(modifier.name),
                @as(u8, 1) << bit,
            });
        }
        bit += width;
    }

    try text.appendSlice(arena, "\n#endif /* _VIBEEE_KEYS_H */\n");
    if (std.fs.path.dirname(args[1])) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = args[1], .data = text.items });
}

/// Whether a field is one of the struct's own or padding it needed. The
/// padding has no name worth giving C.
fn named(comptime name: []const u8) bool {
    return name.len > 0 and name[0] != '_';
}

/// A field name as C spells a constant: upper case throughout. The names
/// are already words separated by underscores, so nothing else changes.
///
/// Called with `comptime` at each use, so the array it builds is folded
/// into the program rather than being a local it would hand a pointer to.
fn shout(comptime name: []const u8) *const [name.len]u8 {
    comptime {
        var loud: [name.len]u8 = undefined;
        for (name, 0..) |c, i| loud[i] = std.ascii.toUpper(c);
        const frozen = loud;
        return &frozen;
    }
}

//! Syscall dispatch.
//!
//! The table in `lib/syscalls.zig` is the contract; this file binds each entry
//! to an implementation. The binding is checked at comptime in both directions:
//! a documented syscall with no `sys_<name>` function fails the build, and so
//! does a handler with no table entry. The interface therefore cannot drift
//! from its documentation, because neither can exist alone.
//!
//! The handlers themselves live in `syscall/`, grouped by what they act on.
//! Splitting them out is what keeps that check honest: the groups do not import
//! each other or this file, so a handler cannot quietly reach into another
//! subsystem's helpers, and the shared plumbing they *do* need is exactly what
//! `syscall/context.zig` exposes.

const std = @import("std");
const abi = @import("lib").syscalls;
const ctx = @import("syscall/context.zig");
const sched = @import("sched.zig");

/// Every module that may contribute handlers. Adding a group is one line; the
/// binding below searches all of them.
const groups = .{
    @import("syscall/core.zig"),
    @import("syscall/file.zig"),
    @import("syscall/ipc.zig"),
    @import("syscall/proc.zig"),
};

pub const Errno = ctx.Errno;
pub const Args = ctx.Args;
pub const Result = ctx.Result;

const Handler = ctx.Handler;

/// Find the handler for a table entry, wherever it lives.
fn handlerFor(comptime name: []const u8) ?Handler {
    const fn_name = "sys_" ++ name;
    inline for (groups) |group| {
        if (@hasDecl(group, fn_name)) return &@field(group, fn_name);
    }
    return null;
}

/// Bind table entries to handlers, and prove the binding is total.
const handlers: [abi.table.len]Handler = blk: {
    var out: [abi.table.len]Handler = undefined;
    for (abi.table, 0..) |sc, i| {
        out[i] = handlerFor(sc.name) orelse @compileError(
            "syscall '" ++ sc.name ++ "' is in the table but no group defines `sys_" ++
                sc.name ++ "`",
        );
    }
    break :blk out;
};

// Every `sys_*` function must appear in the table. Catches the opposite
// mistake: an implemented call nobody documented, which userspace would have
// no way to learn about.
comptime {
    // Four groups times their declarations times a string compare each is more
    // comptime work than the default budget allows.
    @setEvalBranchQuota(20_000);
    for (groups) |group| {
        for (@typeInfo(group).@"struct".decls) |decl| {
            if (!std.mem.startsWith(u8, decl.name, "sys_")) continue;
            if (abi.find(decl.name["sys_".len..]) == null) @compileError(
                "handler `" ++ decl.name ++ "` has no entry in lib/syscalls.zig; " ++
                    "an undocumented syscall is unusable",
            );
        }
    }
}

// Force analysis of the binding table. Zig is lazy: without this the
// completeness checks above only fire once something calls dispatch(), which
// would make them useless exactly when a syscall is half-added.
comptime {
    _ = handlers;
}

pub fn dispatch(number: usize, args: Args) Result {
    if (number >= handlers.len) return Errno.nosys.value();
    const result = handlers[number](args);

    // The handler has unwound, so anything it was holding is released and this
    // is a safe place to act on a kill that arrived while it ran.
    if (sched.currentKilled()) sched.exitWith(sched.KILLED_STATUS);

    return result;
}

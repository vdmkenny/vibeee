//! How a program ends: `exit`, `_exit` and `abort`.
//!
//! Here rather than in `start` because they are wanted by two kinds of
//! program that do not want the same beginning: one written in C, which takes
//! the whole of `start` including its `_start`, and one written in Zig that
//! carries vendored C and has an entry point of its own. Both need to be able
//! to leave.

const stdio = @import("stdio.zig");
const sys = @import("sys");

/// Handlers registered with `atexit`, and the order they run in.
const HANDLER_MAX = 32;
var handlers: [HANDLER_MAX]?*const fn () callconv(.c) void = @splat(null);
var registered: usize = 0;

export fn atexit(handler: ?*const fn () callconv(.c) void) callconv(.c) c_int {
    if (registered == HANDLER_MAX) return -1;
    handlers[registered] = handler;
    registered += 1;
    return 0;
}

/// Leave, running what was registered and flushing what was buffered.
///
/// Last registered first, which is the order C promises and the only one that
/// makes sense: a handler registered later may depend on what an earlier one
/// still has standing.
export fn exit(status: c_int) callconv(.c) noreturn {
    while (registered > 0) {
        registered -= 1;
        if (handlers[registered]) |handler| handler();
    }
    stdio.flushAll();
    sys.exit(@intCast(@as(u8, @truncate(@as(u32, @bitCast(status))))));
}

/// Leave without any of that, for a program that has decided its own state is
/// not to be trusted.
export fn _exit(status: c_int) callconv(.c) noreturn {
    sys.exit(@intCast(@as(u8, @truncate(@as(u32, @bitCast(status))))));
}

export fn abort() callconv(.c) noreturn {
    sys.exit(134); // 128 + SIGABRT, which is what a shell reports for one.
}

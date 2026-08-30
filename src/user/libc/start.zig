//! Getting from the kernel's idea of a new process to C's.
//!
//! The kernel hands over a stack holding argc, the argv pointers and a null,
//! and jumps to `_start`. C wants those as arguments to `main` and wants
//! whatever `main` returns to become the exit status. This is that, and
//! nothing else: everything a program can see is set up by the time `main`
//! runs, and torn down after it returns.

const sys = @import("sys");
const stdio = @import("stdio.zig");

/// Provided by the program being linked. The one symbol this library expects
/// rather than provides.
extern fn main(argc: c_int, argv: [*c][*c]u8, envp: [*c][*c]u8) c_int;

/// No environment is handed over yet, so every program sees an empty one
/// rather than a null nothing can walk.
var empty: [1]?[*:0]u8 = .{null};
export var environ: [*c][*c]u8 = undefined;

/// The kernel enters every program as one C call whose argument is the
/// argc/argv frame it built: alignment, the terminating return address and
/// the parameter are all the kernel's work, so this is a plain function.
export fn _start(stack: [*]const usize) callconv(.c) noreturn {
    const argc: c_int = @intCast(stack[0]);
    const argv: [*c][*c]u8 = @constCast(@ptrCast(stack + 1));

    environ = @ptrCast(&empty);

    exit(main(argc, argv, environ));
}

/// What `atexit` remembers. Bounded because the alternative is an allocation
/// on a path that runs before anything has asked for memory.
const ATEXIT_MAX = 16;
var handlers: [ATEXIT_MAX]?*const fn () callconv(.c) void = @splat(null);
var registered: usize = 0;

export fn atexit(handler: *const fn () callconv(.c) void) callconv(.c) c_int {
    if (registered == ATEXIT_MAX) return -1;
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

/// Registered and never called.
///
/// There is no asynchronous delivery here, by decision: a handler that can run
/// between any two instructions is a class of bug that only shows up under
/// load. Ported code that installs one compiles and runs; what it installed
/// simply does not fire, which is the same outcome as the signal never
/// arriving and is not a state the program has no code for.
const SIGNAL_MAX = 32;
var installed: [SIGNAL_MAX]?*const anyopaque = @splat(null);

export fn signal(which: c_int, handler: ?*const anyopaque) callconv(.c) ?*const anyopaque {
    if (which < 0 or which >= SIGNAL_MAX) return @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

    const before = installed[@intCast(which)];
    installed[@intCast(which)] = handler;
    return before;
}

export fn raise(which: c_int) callconv(.c) c_int {
    _ = which;
    return 0;
}

export fn abort() callconv(.c) noreturn {
    sys.exit(134); // 128 + SIGABRT, which is what a shell reports for one.
}

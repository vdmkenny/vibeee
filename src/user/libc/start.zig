//! Getting from the kernel's idea of a new process to C's.
//!
//! The kernel hands over a stack holding argc, the argv pointers and a
//! null, then the environment and its null, and jumps to `_start`. C
//! wants those as arguments to `main` and wants whatever `main` returns to
//! become the exit status. This is that, and
//! nothing else: everything a program can see is set up by the time `main`
//! runs, and torn down after it returns.

const env = @import("env.zig");

/// Provided by the program being linked. The one symbol this library expects
/// rather than provides.
extern fn main(argc: c_int, argv: [*c][*c]u8, envp: [*c][*c]u8) c_int;

/// Where a program goes when it is finished, in `stop.zig`: this library is
/// linked whole for a C program, so the call resolves whether or not this
/// file names the module.
extern fn exit(status: c_int) callconv(.c) noreturn;

/// The kernel enters every program as one C call whose argument is the
/// argc/argv frame it built: alignment, the terminating return address and
/// the parameter are all the kernel's work, so this is a plain function.
export fn _start(stack: [*]const usize) callconv(.c) noreturn {
    const argc: c_int = @intCast(stack[0]);
    const argv: [*c][*c]u8 = @ptrCast(@constCast(stack + 1));

    // The environment sits after the arguments and the null that ends
    // them, which is where C's own layout puts it.
    env.adopt(@ptrCast(@constCast(stack + 1 + @as(usize, @intCast(argc)) + 1)));

    exit(main(argc, argv, env.environ));
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

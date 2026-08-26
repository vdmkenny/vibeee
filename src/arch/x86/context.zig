//! Kernel thread context switching.
//!
//! Only the callee-saved registers are switched. Everything else is already on
//! the stack by the time we get here, because a switch always happens inside a
//! function call, either a voluntary `yield` or an interrupt handler that has
//! pushed the full frame. That is what makes the switch four pushes and four
//! pops rather than a full register save.
//!
//! Both routines are written as global assembly rather than Zig functions.
//! `switchTo` defines the exact stack layout that `initStack` has to reproduce
//! for a thread that has never run, and a compiler-generated prologue would add
//! a frame that `initStack` knows nothing about, the first switch into a new
//! thread would then `ret` into whatever happened to be on the stack.

const std = @import("std");

comptime {
    asm (
    // Global assembly inherits whatever section was last selected, and the
    // Multiboot header block selects `.multiboot`. Without this the switch
    // routines land in `.boot` at a low physical address, which is unmapped
    // once the identity mapping is dropped.
        \\.section .text,"ax",@progbits
        \\
    // ---------------------------------------------------------------
    // void vibeeeSwitchContext(usize *save_sp, usize new_sp)
    //
    // cdecl, so at entry: [esp] return address, [esp+4] save_sp,
    // [esp+8] new_sp. Arguments are read before anything is pushed.
    //
    // Returns in the *incoming* thread: each thread's stack holds its own
    // return address, so `ret` lands wherever that thread last stopped.
    // ---------------------------------------------------------------
        \\.global vibeeeSwitchContext
        \\.type vibeeeSwitchContext,@function
        \\vibeeeSwitchContext:
        \\  movl 4(%esp), %eax
        \\  movl 8(%esp), %edx
        \\  pushl %ebx
        \\  pushl %esi
        \\  pushl %edi
        \\  pushl %ebp
        \\  movl %esp, (%eax)
        \\  movl %edx, %esp
        \\  popl %ebp
        \\  popl %edi
        \\  popl %esi
        \\  popl %ebx
        \\  ret
        \\
        // ---------------------------------------------------------------
        // Entry trampoline for a thread that has never run.
        //
        // Exists to enable interrupts: a thread is first entered from inside
        // an interrupt handler or a yield, both of which run with IF clear,
        // and without this the new thread would run un-preemptible until it
        // happened to block.
        // ---------------------------------------------------------------
        \\.global vibeeeThreadStart
        \\.type vibeeeThreadStart,@function
        \\vibeeeThreadStart:
        \\  sti
        \\  ret
    );
}

pub extern fn vibeeeSwitchContext(save_sp: *usize, new_sp: usize) callconv(.c) void;
extern const vibeeeThreadStart: anyopaque;

pub const switchTo = vibeeeSwitchContext;

/// Build a stack that `switchTo` can resume into, as though the thread had
/// already been running and had stopped inside it.
///
/// Layout, from the top down:
///     arg                 argument to entry, cdecl
///     exit_to             where entry returns to when it finishes
///     entry               popped by vibeeeThreadStart's `ret`
///     vibeeeThreadStart   popped by switchTo's `ret`
///     ebp edi esi ebx     restored by switchTo          <- returned sp
pub fn initStack(
    stack: []u8,
    entry: *const fn (usize) callconv(.c) void,
    arg: usize,
    exit_to: *const fn () callconv(.c) noreturn,
) usize {
    var sp = std.mem.alignBackward(usize, @intFromPtr(stack.ptr) + stack.len, 16);

    const push = struct {
        fn word(p: *usize, value: usize) void {
            p.* -= @sizeOf(usize);
            @as(*usize, @ptrFromInt(p.*)).* = value;
        }
    }.word;

    push(&sp, arg);
    push(&sp, @intFromPtr(exit_to));
    push(&sp, @intFromPtr(entry));
    push(&sp, @intFromPtr(&vibeeeThreadStart));

    // Callee-saved registers, zeroed: a fresh thread has nothing to restore,
    // and zeros make a stray value obvious in a backtrace.
    push(&sp, 0); // ebp
    push(&sp, 0); // edi
    push(&sp, 0); // esi
    push(&sp, 0); // ebx

    return sp;
}

//! Entry into Ring 3.
//!
//! The privilege drop is one `iret` with a hand-built frame: the CPU cannot be
//! "switched" to user mode, only returned to it, so the kernel fabricates the
//! frame a user-mode interrupt would have pushed.
//!
//! See design/00-vibeee.md §6.7.

const std = @import("std");
const gdt = @import("gdt.zig");
const paging = @import("paging.zig");
const pmm = @import("../../kernel/pmm.zig");

/// Top of the initial user stack. Below the loaded image, and well clear of the
/// null page so a null dereference still faults.
pub const USER_STACK_TOP: usize = 0x3FFF_0000;
pub const USER_STACK_PAGES = 4;

pub const Error = error{OutOfMemory};

/// Give a freshly loaded process its stack.
pub fn setupStack(space: *paging.AddressSpace) Error!usize {
    var i: usize = 0;
    while (i < USER_STACK_PAGES) : (i += 1) {
        const phys = pmm.allocFrame() catch return error.OutOfMemory;
        @memset(@as([*]u8, @ptrFromInt(paging.physToVirt(phys)))[0..paging.PAGE_SIZE], 0);
        const virt = USER_STACK_TOP - (i + 1) * paging.PAGE_SIZE;
        space.map(virt, phys, true) catch return error.OutOfMemory;
    }
    return USER_STACK_TOP;
}

/// Drop to Ring 3. Does not return: from here the only way back into the kernel
/// is a trap.
///
/// `kernel_stack_top` is what the CPU loads into ESP on the next privilege
/// transition, so it must be a stack this code is no longer using.
pub fn enter(entry: usize, stack_top: usize, kernel_stack_top: usize) noreturn {
    gdt.setKernelStack(@intCast(kernel_stack_top));

    asm volatile (
    // The iret frame, bottom-up: ss, esp, eflags, cs, eip.
    //
    // The pushes come before the segment reloads on purpose: reloading DS
    // needs a scratch register, and doing that first risks destroying an
    // input the compiler happened to allocate to the same register. Once
    // the frame is on the stack, no input is live.
        \\ pushl %[uds]
        \\ pushl %[stack]
        // IF set so user code is preemptible; IOPL 0 so it cannot use in/out.
        \\ pushl $0x202
        \\ pushl %[ucs]
        \\ pushl %[entry]
        // Data segments need the user selectors before the iret, or the first
        // user-mode memory access faults on a DPL 0 segment.
        \\ movw %[uds], %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ movw %%ax, %%fs
        \\ movw %%ax, %%gs
        \\ iret
        :
        : [uds] "i" (@as(u32, gdt.USER_DATA)),
          [ucs] "i" (@as(u32, gdt.USER_CODE)),
          [entry] "r" (entry),
          [stack] "r" (stack_top),
        : .{ .eax = true, .memory = true });
    unreachable;
}

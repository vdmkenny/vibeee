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

/// Give a freshly loaded process its stack, with arguments on it.
///
/// The initial stack follows the C convention a `_start` expects: argc, then
/// the argv pointers, then a null, then the strings themselves. Building it
/// here rather than in the program means a shell can hand arguments to anything
/// without every program agreeing on a private protocol.
///
/// Written through the linear map while the process is not yet running, so the
/// address space never has to be switched to populate it.
pub fn setupStack(space: *paging.AddressSpace, args: []const []const u8) Error!usize {
    // Track each page's kernel-visible address, so the stack can be written
    // before it is mapped anywhere the process can see.
    var frames: [USER_STACK_PAGES]usize = undefined;

    var i: usize = 0;
    while (i < USER_STACK_PAGES) : (i += 1) {
        const phys = pmm.allocFrame() catch return error.OutOfMemory;
        frames[i] = phys;
        @memset(@as([*]u8, @ptrFromInt(paging.physToVirt(phys)))[0..paging.PAGE_SIZE], 0);
        const virt = USER_STACK_TOP - (i + 1) * paging.PAGE_SIZE;
        space.map(virt, phys, true) catch return error.OutOfMemory;
    }

    // Only the topmost page is used for arguments; anything longer than that
    // belongs in a file rather than a command line.
    const top_phys = frames[0];
    const page: [*]u8 = @ptrFromInt(paging.physToVirt(top_phys));

    // Offsets are relative to the top page, whose last byte is USER_STACK_TOP-1.
    var offset: usize = paging.PAGE_SIZE;

    var arg_addrs: [MAX_ARGS]usize = undefined;
    const count = @min(args.len, MAX_ARGS);

    // Strings first, downward from the top.
    var n: usize = count;
    while (n > 0) {
        n -= 1;
        const arg = args[n];
        if (arg.len + 1 > offset) return error.OutOfMemory;
        offset -= arg.len + 1;
        @memcpy(page[offset..][0..arg.len], arg);
        page[offset + arg.len] = 0;
        arg_addrs[n] = USER_STACK_TOP - paging.PAGE_SIZE + offset;
    }

    // Then the pointer array and argc. Aligned to 16 rather than 4: SSE loads
    // and stores require it, and the compiler emits them freely in user code —
    // a 4-byte-aligned stack makes the first `movaps` fault.
    offset = std.mem.alignBackward(usize, offset, 16);
    const words = count + 2; // argc, argv[0..count], null terminator
    const frame_bytes = std.mem.alignForward(usize, words * 4, 16);
    if (frame_bytes > offset) return error.OutOfMemory;
    offset -= frame_bytes;

    const stack_words: [*]u32 = @alignCast(@ptrCast(page + offset));
    stack_words[0] = @intCast(count);
    for (0..count) |k| stack_words[1 + k] = @intCast(arg_addrs[k]);
    stack_words[1 + count] = 0;

    return USER_STACK_TOP - paging.PAGE_SIZE + offset;
}

pub const MAX_ARGS = 16;

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

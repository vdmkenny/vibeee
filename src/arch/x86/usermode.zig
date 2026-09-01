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

/// Sixty-four kilobytes, which is what `design/11-userspace.md` says a stack
/// here is.
///
/// Sixteen kilobytes was not enough for a program that draws: a control that
/// builds a list of rows before handing them to a table puts kilobytes in one
/// frame. Thirty-two was not enough for one that decodes a picture: a
/// vendored decoder builds its Huffman tables in a frame of its own, and four
/// kilobytes of that on top of a drawing pass is over the edge.
///
/// The wall was real both times and the growth is what it costs to do the
/// work, so the number doubled rather than the work being avoided. Nothing
/// below the bottom page is mapped, so an overflow still faults at once and
/// says where, rather than quietly writing into whatever is under it.
pub const USER_STACK_PAGES = 16;

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
/// Build the frame a program starts on: its arguments, then what it has
/// been told about where it is.
///
/// The shape is C's, because C's `main` is what receives it: a count, the
/// argument pointers, a null, the environment pointers, and another null.
/// A program that ignores the second half sees exactly what it saw before
/// there was one.
pub fn setupStack(
    space: *paging.AddressSpace,
    args: []const []const u8,
    env: []const []const u8,
) Error!usize {
    // Track each page's kernel-visible address, so the stack can be written
    // before it is mapped anywhere the process can see.
    var frames: [USER_STACK_PAGES]usize = undefined;

    var i: usize = 0;
    while (i < USER_STACK_PAGES) : (i += 1) {
        const phys = pmm.allocFrame() catch return error.OutOfMemory;
        frames[i] = phys;
        @memset(@as([*]u8, @ptrFromInt(paging.physToVirt(phys)))[0..paging.PAGE_SIZE], 0);
        const virt = USER_STACK_TOP - (i + 1) * paging.PAGE_SIZE;
        space.map(virt, phys, .{ .writable = true }) catch return error.OutOfMemory;
    }

    // Only the topmost page is used for arguments; anything longer than that
    // belongs in a file rather than a command line.
    const top_phys = frames[0];
    const page: [*]u8 = @ptrFromInt(paging.physToVirt(top_phys));

    // Offsets are relative to the top page, whose last byte is USER_STACK_TOP-1.
    var offset: usize = paging.PAGE_SIZE;

    var arg_addrs: [MAX_ARGS]usize = undefined;
    var env_addrs: [MAX_ENV]usize = undefined;
    const count = @min(args.len, MAX_ARGS);
    const env_count = @min(env.len, MAX_ENV);

    // Strings first, downward from the top: the environment above the
    // arguments, though nothing depends on the order.
    var e: usize = env_count;
    while (e > 0) {
        e -= 1;
        offset = writeString(page, offset, env[e]) orelse return error.OutOfMemory;
        env_addrs[e] = USER_STACK_TOP - paging.PAGE_SIZE + offset;
    }

    var n: usize = count;
    while (n > 0) {
        n -= 1;
        offset = writeString(page, offset, args[n]) orelse return error.OutOfMemory;
        arg_addrs[n] = USER_STACK_TOP - paging.PAGE_SIZE + offset;
    }

    // Then the pointer array and argc, in a frame of one fixed size: the
    // worst case is eighty bytes of a page that arrives zeroed, and a
    // constant shape has no arithmetic to get wrong. Aligned to 16 rather
    // than 4: SSE loads and stores require it, and the compiler emits them
    // freely in user code, a 4-byte-aligned stack makes the first `movaps`
    // fault.
    // A count, the arguments and their null, then the environment and
    // its null.
    const frame_bytes = comptime std.mem.alignForward(
        usize,
        (MAX_ARGS + MAX_ENV + 3) * @sizeOf(u32),
        16,
    );
    offset = std.mem.alignBackward(usize, offset, 16);
    if (frame_bytes + CALL_BYTES > offset) return error.OutOfMemory;
    offset -= frame_bytes;

    const stack_words: [*]u32 = @alignCast(@ptrCast(page + offset));
    stack_words[0] = @intCast(count);
    for (0..count) |k| stack_words[1 + k] = @intCast(arg_addrs[k]);
    stack_words[1 + count] = 0;

    const env_at = 2 + count;
    for (0..env_count) |k| stack_words[env_at + k] = @intCast(env_addrs[k]);
    stack_words[env_at + env_count] = 0;

    // Entry is one C call: the argument frame's address as the only
    // parameter, above a zero return address that ends every backtrace.
    // The parameter sits on a sixteen-byte boundary so entry lands where
    // the convention puts it, and `_start` is then a plain function in
    // every program rather than assembly reading the stack raw.
    const frame_address: u32 = @intCast(USER_STACK_TOP - paging.PAGE_SIZE + offset);
    offset -= CALL_BYTES;
    const call_words: [*]u32 = @alignCast(@ptrCast(page + offset));
    call_words[0] = 0;
    call_words[1] = frame_address;

    return USER_STACK_TOP - paging.PAGE_SIZE + offset;
}

pub const MAX_ENV = @import("lib").syscalls.MAX_ENV;
const MAX_ARGS = 16;

/// The entry call's own bytes: a return address and one parameter, spaced so
/// the parameter keeps the sixteen-byte boundary the compiler assumes.
const CALL_BYTES = 20;

/// Drop to Ring 3. Does not return: from here the only way back into the kernel
/// is a trap.
///
/// `kernel_stack_top` is what the CPU loads into ESP on the next privilege
/// transition, so it must be a stack this code is no longer using.
/// One string onto the stack, NUL-terminated, and where it now begins.
fn writeString(page: [*]u8, offset: usize, text: []const u8) ?usize {
    if (text.len + 1 > offset) return null;
    const at = offset - (text.len + 1);
    @memcpy(page[at..][0..text.len], text);
    page[at + text.len] = 0;
    return at;
}

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

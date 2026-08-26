//! The pre-paging half of boot, shared by both entry paths.
//!
//! Everything here is linked at its physical address in `.boot`, because it
//! executes before CR0.PG is set and the kernel's virtual addresses do not yet
//! resolve. That constraint is why this file is separate and small: it must not
//! call into the rest of the kernel, and nothing will warn if it does.

const std = @import("std");
const paging = @import("paging.zig");
const bootinfo = @import("../../kernel/bootinfo.zig");

pub const Handoff = enum(u32) {
    /// EBX pointed at a BootInfo we built ourselves in stage2.
    stage2 = 0,
    /// EBX pointed at a Multiboot 1 info block, still to be translated.
    multiboot = 1,
    /// Not booted by anything we recognise.
    unknown = 2,
};

/// Boot stack. Lives in `.bootdata` rather than `.bss` for two reasons: it must
/// be usable before paging, and `.bss` is cleared while this stack is in use.
pub export var boot_stack: [16 * 1024]u8 align(16) linksection(".bootdata") =
    [_]u8{0} ** (16 * 1024);

export var handoff_kind: u32 linksection(".bootdata") = @intFromEnum(Handoff.unknown);
export var handoff_ptr: u32 linksection(".bootdata") = 0;

/// BootInfo for the Multiboot path, which has to be translated from the
/// bootloader's own format. In `.bootdata` so its physical address is knowable.
export var mb_boot_info: bootinfo.BootInfo linksection(".bootdata") =
    std.mem.zeroes(bootinfo.BootInfo);

pub fn stackTop() usize {
    return @intFromPtr(&boot_stack) + boot_stack.len;
}

/// Turn on paging and continue at `highEntry` in the kernel window.
///
/// The jump has to be indirect through a register holding the *virtual*
/// address: a relative jump would keep executing in the identity mapping, which
/// exists only to survive this instant.
pub fn enterHigherHalf(kind: Handoff, ptr: u32) linksection(".text.boot") callconv(.c) noreturn {
    handoff_kind = @intFromEnum(kind);
    handoff_ptr = ptr;

    paging.setupBootPaging();

    // Move the stack pointer to the linear-map alias of the same memory before
    // leaving low addresses. Physically it is the identical stack; only the
    // address changes. Without this the kernel keeps pushing to a low address
    // that `dropIdentityMapping` is about to unmap, and faults on the next call.
    const high_stack = paging.physToVirt(@intFromPtr(&boot_stack) + boot_stack.len);

    asm volatile (
        \\ movl %[sp], %%esp
        \\ xorl %%ebp, %%ebp
        \\ jmp *%[entry]
        :
        : [entry] "r" (&highEntry),
          [sp] "r" (high_stack),
    );
    unreachable;
}

extern var __bss_start: anyopaque;
extern var __bss_end: anyopaque;

/// First code to run at a virtual address.
///
/// Still on the boot stack here, deliberately: clearing `.bss` would otherwise
/// wipe the stack out from under this function. Threads get real stacks when
/// the scheduler arrives.
fn highEntry() callconv(.c) noreturn {
    const start = @intFromPtr(&__bss_start);
    const end = @intFromPtr(&__bss_end);
    const bss: [*]u8 = @ptrFromInt(start);
    @memset(bss[0 .. end - start], 0);

    const kind: Handoff = @enumFromInt(handoff_kind);
    const bi: *bootinfo.BootInfo = switch (kind) {
        .stage2 => @ptrFromInt(paging.physToVirt(handoff_ptr)),
        .multiboot => blk: {
            // Deliberately parsed here rather than pre-paging: the parser wants
            // @memcpy and friends, which may be out-of-line calls into code
            // that is only reachable once paging is on.
            const mb: *bootinfo.BootInfo = @ptrFromInt(
                paging.physToVirt(@intFromPtr(&mb_boot_info)),
            );
            @import("multiboot.zig").translate(mb, handoff_ptr);
            break :blk mb;
        },
        .unknown => blk: {
            const mb: *bootinfo.BootInfo = @ptrFromInt(
                paging.physToVirt(@intFromPtr(&mb_boot_info)),
            );
            mb.magic = bootinfo.MAGIC;
            mb.version = bootinfo.VERSION;
            break :blk mb;
        },
    };

    @import("../../kernel/main.zig").kmain(bi);
}

//! Entry point for the real boot path: stage2 loads the kernel as a flat binary
//! at physical 1 MiB and jumps to offset 0.
//!
//! The linker places this stub first in the image, so "offset 0 of the flat
//! binary" and "this function" are the same address. That spares stage2 an ELF
//! parser written in real mode — code that would be miserable to debug on a
//! machine with no serial port.
//!
//! Contract, matching design/01-boot.md:
//!   EAX = 0x0EEEB007
//!   EBX = physical address of a BootInfo
//!   protected mode, flat 32-bit segments, paging off, interrupts off

const std = @import("std");
const bootinfo = @import("../../kernel/bootinfo.zig");
const boot = @import("boot.zig");

export fn _flat_start() linksection(".text.boot.entry") callconv(.naked) noreturn {
    asm volatile (
        \\ cli
        \\ cld
        \\ movl %[stack_top], %%esp
        \\ xorl %%ebp, %%ebp
        \\ cmpl %[magic], %%eax
        \\ jne 1f
        \\ pushl %%ebx
        \\ pushl %[kind]
        \\ call enterHigherHalfC
        \\ 1:
        \\ call flatHandoffInvalid
        \\ 2: hlt
        \\ jmp 2b
        :
        : [stack_top] "i" (@intFromPtr(&boot.boot_stack) + boot.boot_stack.len),
          [magic] "i" (bootinfo.MAGIC),
          [kind] "i" (@intFromEnum(boot.Handoff.stage2)),
    );
}

/// Reported before paging, so it writes straight to VGA text memory at its
/// physical address and depends on nothing else.
export fn flatHandoffInvalid() linksection(".text.boot") callconv(.c) noreturn {
    const msg = "vibeee: stage2 handoff invalid - rebuild the image";
    const vga: [*]volatile u16 = @ptrFromInt(0xB8000);
    var i: usize = 0;
    while (i < 80 * 25) : (i += 1) vga[i] = 0x4F20; // white on red
    for (msg, 0..) |c, n| {
        if (n >= 80) break;
        vga[80 + 2 + n] = 0x4F00 | @as(u16, c);
    }
    while (true) asm volatile ("cli; hlt");
}

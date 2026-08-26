//! A minimal Ring 3 program, as raw machine code.
//!
//! Deliberately position-independent: it builds its message on its own stack
//! rather than referencing a data address, so the image can be mapped anywhere
//! without relocation. That keeps the first user-mode bring-up free of an ELF
//! loader — which arrives with real processes, and is much easier to debug once
//! Ring 3 is known to work at all.
//!
//! What it does:
//!     write(STDOUT, "ring3 ok\n", 9)
//!     getpid()
//!     exit(0)

comptime {
    asm (
        \\.section .rodata,"a",@progbits
        \\.balign 16
        \\.global user_blob_start
        \\user_blob_start:
        \\
        // Build "ring3 ok\n" on the stack, last dword first so the string ends
        // up in order at the lowest address.
        \\  pushl $0x0000000a          // "\n"
        \\  pushl $0x6b6f2033          // "3 ok"
        \\  pushl $0x676e6972          // "ring"
        \\
        // write(1, esp, 9)
        \\  movl $1, %eax
        \\  movl $1, %ebx
        \\  movl %esp, %ecx
        \\  movl $9, %edx
        \\  int $0x80
        \\
        // getpid(), just to exercise a second call and a return value.
        \\  movl $6, %eax
        \\  int $0x80
        \\
        // exit(0)
        \\  movl $0, %eax
        \\  xorl %ebx, %ebx
        \\  int $0x80
        \\
        // exit does not return; if it ever does, stop here rather than running
        // off the end of the page.
        \\1:
        \\  jmp 1b
        \\
        \\.global user_blob_end
        \\user_blob_end:
        \\.section .text,"ax",@progbits
    );
}

extern const user_blob_start: anyopaque;
extern const user_blob_end: anyopaque;

/// The program image, as bytes to copy into a user page.
pub fn image() []const u8 {
    const start = @intFromPtr(&user_blob_start);
    const end = @intFromPtr(&user_blob_end);
    const p: [*]const u8 = @ptrFromInt(start);
    return p[0 .. end - start];
}

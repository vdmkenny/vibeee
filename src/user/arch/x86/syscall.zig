//! The two instructions that enter the kernel, which no function can spell.
//!
//! Everything else about a syscall, numbers, argument marshalling, errno
//! shapes, lives above in `user/syscall.zig`; this file is only the trap and
//! the fast path, and it is the userspace counterpart of the rule that
//! assembly lives in an architecture directory or not at all.

/// The trap path: works from the first instruction of every x86.
pub inline fn trap(nr: u32, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile ("int $0x80"
        : [ret] "={eax}" (-> isize),
        : [nr] "{eax}" (nr),
          [a0] "{ebx}" (a0),
          [a1] "{ecx}" (a1),
          [a2] "{edx}" (a2),
          [a3] "{esi}" (a3),
          [a4] "{edi}" (a4),
        : .{ .memory = true });
}

/// The fast path.
///
/// SYSENTER saves neither the stack pointer nor the address to come back to,
/// so both are stashed first: the stack pointer in `ebp`, and the return
/// address pushed just below it where the kernel reads it back. SYSEXIT is
/// given them in `ecx` and `edx`, which is why both are clobbered on return.
pub inline fn fast(nr: u32, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile (
        \\ push %%ebp
        \\ push $1f
        \\ mov  %%esp, %%ebp
        \\ sysenter
        \\ 1:
        \\ add  $4, %%esp
        \\ pop  %%ebp
        : [ret] "={eax}" (-> isize),
        : [nr] "{eax}" (nr),
          [a0] "{ebx}" (a0),
          [a1] "{ecx}" (a1),
          [a2] "{edx}" (a2),
          [a3] "{esi}" (a3),
          [a4] "{edi}" (a4),
        : .{ .memory = true, .ecx = true, .edx = true });
}

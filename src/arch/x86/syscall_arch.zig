//! x86 side of the syscall path: unpack the trap frame into the portable
//! argument struct and put the result back in `eax`.
//!
//! `int 0x80` only, for now. SYSENTER is the intended fast path, the MSRs and
//! the stack dance are the whole of the difference, and libc picks between
//! them from CPUID at start-up, so the ABI here does not change when it lands.

const idt = @import("idt.zig");
const syscall = @import("../../kernel/syscall.zig");

pub fn init() void {
    idt.setHandler(idt.SYSCALL_VECTOR, onSyscall);
}

fn onSyscall(frame: *idt.Frame) void {
    const result = syscall.dispatch(frame.eax, .{
        .a0 = frame.ebx,
        .a1 = frame.ecx,
        .a2 = frame.edx,
        .a3 = frame.esi,
        .a4 = frame.edi,
        // The low two bits of the saved CS are the caller's privilege level.
        // Kernel-mode callers (the boot self-test) skip user-pointer checks.
        .from_user = frame.cs & 3 != 0,
    });
    frame.eax = @bitCast(@as(i32, @truncate(result)));
}

/// Issue a syscall from kernel mode, for self-tests.
pub fn invoke(number: u32, a0: usize, a1: usize, a2: usize) isize {
    return asm volatile ("int $0x80"
        : [ret] "={eax}" (-> isize),
        : [nr] "{eax}" (number),
          [a0] "{ebx}" (a0),
          [a1] "{ecx}" (a1),
          [a2] "{edx}" (a2),
        : .{ .memory = true });
}

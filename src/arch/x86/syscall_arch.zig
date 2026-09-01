//! x86 side of the syscall path.
//!
//! Two ways in, one ABI. `int 0x80` always works and is trivially debuggable;
//! `SYSENTER` skips the IDT lookup, the stack switch and the segment loads
//! entirely, which on this core is most of what a syscall costs. Userspace
//! picks between them once, at start-up, and the register convention is the
//! same either way.
//!
//! **SYSENTER saves nothing.** It loads CS, SS, ESP and EIP from three MSRs
//! and leaves the caller's ESP and EIP gone. The stub therefore stashes its
//! stack pointer in `ebp` and pushes the address to come back to just below
//! it, which is what `SYSEXIT` is given back. That arrangement is the whole
//! difference between the two paths.

const std = @import("std");
const cpu = @import("cpu.zig");
const gdt = @import("gdt.zig");
const hal = @import("../../kernel/hal.zig");
const idt = @import("idt.zig");
const sched = @import("../../kernel/sched.zig");
const syscall = @import("../../kernel/syscall.zig");

/// Where the CPU takes the fast path's kernel context from.
/// The three SYSENTER MSRs, consecutive by definition.
const Msr = enum(u32) {
    sysenter_cs = 0x174,
    sysenter_esp = 0x175,
    sysenter_eip = 0x176,

    fn write(self: Msr, value: u64) void {
        cpu.writeMsr(@intFromEnum(self), value);
    }
};

var armed = false;

/// Whether the fast path is usable.
///
/// Userspace asks, rather than testing CPUID for itself: a CPU that has
/// SYSENTER on a kernel that has not programmed the MSRs would jump to
/// nowhere, and the capability bit cannot tell the two apart.
pub fn fastPathArmed() bool {
    return armed;
}

pub fn init() void {
    idt.setHandler(idt.SYSCALL_VECTOR, onSyscall);

    if (!hal.cpuInfo().fast_syscall) return;

    // SYSEXIT takes the user selectors as fixed offsets from this one: code at
    // +16 and stack at +24. The GDT is laid out to match, and a comptime check
    // keeps it that way.
    comptime {
        if (gdt.USER_CODE & ~@as(u16, 3) != gdt.KERNEL_CODE + 16) {
            @compileError("SYSEXIT requires user code at kernel code + 16");
        }
        if (gdt.USER_DATA & ~@as(u16, 3) != gdt.KERNEL_CODE + 24) {
            @compileError("SYSEXIT requires user data at kernel code + 24");
        }
    }

    Msr.sysenter_cs.write(gdt.KERNEL_CODE);
    Msr.sysenter_eip.write(@intFromPtr(&sysenterEntry));
    // The stack is per-thread and set on every switch, below.
    armed = true;
}

/// Point the fast path at a thread's kernel stack.
///
/// Must happen on every context switch, for the same reason the TSS `esp0`
/// does: a stale value sends the next syscall onto a stack that belongs to
/// someone else, or to nobody.
pub fn setKernelStack(esp0: u32) void {
    if (armed) Msr.sysenter_esp.write(esp0);
}

// ---------------------------------------------------------------------------
// int 0x80
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// SYSENTER
// ---------------------------------------------------------------------------

/// What the entry stub leaves on the kernel stack, lowest address first.
const Frame = extern struct {
    /// The call number on the way in, the result on the way out.
    number: u32,
    a0: u32,
    a1: u32,
    a2: u32,
    a3: u32,
    a4: u32,
    /// Filled in from the user stack: where SYSEXIT should land.
    return_eip: u32,
    /// The stack pointer the stub stashed before trapping.
    user_esp: u32,
};

/// Where the CPU arrives on SYSENTER, with a kernel stack and nothing else.
///
/// SYSENTER clears the interrupt flag, so interrupts are turned back on before
/// dispatching: a syscall that blocks or takes a long time must be preemptible
/// like any other kernel work. They are left on through SYSEXIT, which does
/// not restore the flag itself, so turning them off here would hand userspace
/// a machine that never takes another interrupt.
export fn sysenterEntry() callconv(.naked) noreturn {
    asm volatile (
        \\ push %%ebp
        \\ push %%ebp
        \\ push %%edi
        \\ push %%esi
        \\ push %%edx
        \\ push %%ecx
        \\ push %%ebx
        \\ push %%eax
        // SYSENTER loads CS and SS and leaves the data segments alone, and
        // SYSEXIT restores neither, so the kernel establishes its own here and
        // puts the user's back below. Both halves are needed: a context switch
        // carries no segment registers, so a thread resumed inside a syscall
        // holds whatever selector the previously running thread left behind.
        // Returning to ring 3 with a ring 0 one still reads and writes, the
        // descriptor being cached and flat, right up until an interrupt
        // returns through IRET and the CPU nulls a segment whose DPL sits
        // below the privilege level it returns to. The next store faults.
        \\ movw %[kds], %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ sti
        \\ push %%esp
        \\ call sysenterDispatch
        \\ add $4, %%esp
        \\ movw %[uds], %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ pop %%eax
        \\ add $20, %%esp
        \\ pop %%edx
        \\ pop %%ecx
        \\ sysexit
        :
        : [kds] "i" (@as(u16, gdt.KERNEL_DATA)),
          [uds] "i" (@as(u16, gdt.USER_DATA)),
    );
}

export fn sysenterDispatch(frame: *Frame) callconv(.c) void {
    // The address to come back to sits at the stashed stack pointer, which is
    // a user pointer like any a syscall is handed and is checked like one: the
    // word must be aligned and every byte of it must sit on a page the caller
    // can read. Range alone was not enough. A stub that trapped with a wild
    // `ebp` pointing at nothing mapped would have had the kernel fault in its
    // own context here, on every such call, and a fault there stops the
    // machine rather than the program.
    const t = sched.currentThread() orelse sched.exitWith(MALFORMED);
    const stack = frame.user_esp;
    if (!std.mem.isAligned(stack, @alignOf(u32)) or
        !t.space.permits(stack, @sizeOf(u32), .read))
    {
        sched.exitWith(MALFORMED);
    }
    frame.return_eip = @as(*const u32, @ptrFromInt(stack)).*;

    const result = syscall.dispatch(frame.number, .{
        .a0 = frame.a0,
        .a1 = frame.a1,
        .a2 = frame.a2,
        .a3 = frame.a3,
        .a4 = frame.a4,
        .from_user = true,
    });
    frame.number = @bitCast(@as(i32, @truncate(result)));
}

/// What a process reports when it enters the kernel with a stack pointer that
/// cannot be one of its own. There is nothing to return an error to: the place
/// a return would go is exactly what was wrong.
const MALFORMED: i32 = -14;

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

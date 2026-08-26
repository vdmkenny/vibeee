//! x86 implementation of the HAL contract in kernel/hal.zig.

const std = @import("std");
const cpu = @import("cpu.zig");
const fpu = @import("fpu.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const port = @import("port.zig");
const paging = @import("paging.zig");
const context = @import("context.zig");
const timer = @import("timer.zig");

pub const PAGE_SIZE = paging.PAGE_SIZE;
pub const KERNEL_BASE = paging.KERNEL_VMA;

pub const disableInterrupts = cpu.cli;
pub const enableInterrupts = cpu.sti;
pub const saveAndDisableInterrupts = cpu.saveAndDisableInterrupts;
pub const restoreInterrupts = cpu.restoreInterrupts;
pub const halt = cpu.halt;

/// Idle with interrupts enabled, so the halt is actually wakeable.
///
/// C1 (plain HLT) only. Deeper C-states are deliberately not used on this
/// platform: the research confirms the TSC and the LAPIC timer both stop in C3
/// on this Dothan part, which would cost us the timer we schedule on for a
/// battery saving we have not measured. Revisit in M4.
pub fn idle() void {
    asm volatile (
        \\ sti
        \\ hlt
        ::: .{ .memory = true });
}

pub const physToVirt = paging.physToVirt;
pub const virtToPhys = paging.virtToPhys;
pub const invalidatePage = paging.invalidatePage;
pub const dropBootIdentityMapping = paging.dropIdentityMapping;
pub const AddressSpace = paging.AddressSpace;
pub const kernelAddressSpace = paging.kernelAddressSpace;
pub const setupUserStack = @import("usermode.zig").setupStack;
pub const enterUserMode = @import("usermode.zig").enter;
pub const mapMmio = paging.mapMmio;
pub const isLinearPhys = paging.isLinear;

pub fn initCpu(kernel_stack_top: usize) void {
    cpu.cli();
    gdt.init(@intCast(kernel_stack_top));
    idt.init();
    // Before any user code runs: its compiler emits SSE freely, and without
    // this those instructions fault as invalid opcodes.
    fpu.enable();
}

pub const initSyscalls = @import("syscall_arch.zig").init;
pub const invokeSyscall = @import("syscall_arch.zig").invoke;

pub fn initInterruptController() void {
    // Remap the PICs out of the exception range, then mask them. The 701 has a
    // usable IOAPIC (declared in the MADT) and that is what we route through;
    // the PICs are remapped purely so a spurious legacy line cannot arrive
    // looking like a CPU fault. IOAPIC bring-up lands with ACPI parsing in M1.
    idt.remapPic();
    idt.maskAllPic();
}

pub const FpuState = fpu.State;
pub const enableFpu = fpu.enable;
pub const saveFpu = fpu.save;
pub const restoreFpu = fpu.restore;
pub const initFpuState = fpu.initState;

/// Point the CPU at the kernel stack to use on the next privilege transition.
///
/// Must be updated on every context switch. The CPU reads it from the TSS when
/// user code traps, so a stale value sends a syscall onto another thread's
/// stack, and once that thread has exited and its stack been freed, onto
/// memory the allocator has handed to someone else.
pub const setKernelStack = gdt.setKernelStack;

pub const switchContext = context.switchTo;
pub const initThreadStack = context.initStack;

pub const initTimer = timer.init;
pub const monotonicMicros = timer.monotonicMicros;
pub const tickCount = timer.tickCount;
pub const timerSourceName = timer.sourceName;
pub const setPmTimerPort = timer.setPmTimerPort;

pub inline fn cycleCounter() u64 {
    return cpu.readTsc();
}

var brand_buf: [49]u8 = undefined;

pub fn cpuInfo() @import("../../kernel/hal.zig").CpuInfo {
    const f = cpu.Features.detect();
    const r = cpu.cpuid(0, 0);
    var vendor: [12]u8 = undefined;
    std.mem.writeInt(u32, vendor[0..4], r.ebx, .little);
    std.mem.writeInt(u32, vendor[4..8], r.edx, .little);
    std.mem.writeInt(u32, vendor[8..12], r.ecx, .little);
    const vendor_static = struct {
        var buf: [12]u8 = undefined;
    };
    vendor_static.buf = vendor;

    return .{
        .vendor = &vendor_static.buf,
        .brand = cpu.brandString(&brand_buf),
        .fast_syscall = f.sep,
        .freq_scaling = f.est,
    };
}

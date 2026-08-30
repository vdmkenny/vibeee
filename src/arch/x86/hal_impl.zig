//! x86 implementation of the HAL contract in kernel/hal.zig.

const std = @import("std");
const cpu = @import("cpu.zig");
const fpu = @import("fpu.zig");
const gdt = @import("gdt.zig");
const console = @import("../../kernel/console.zig");
const idt = @import("idt.zig");
const irq = @import("../../kernel/irq.zig");
const lapic = @import("lapic.zig");
const port = @import("port.zig");
const paging = @import("paging.zig");
const context = @import("context.zig");
const timer = @import("timer.zig");

pub const PAGE_SIZE = paging.PAGE_SIZE;
pub const KERNEL_BASE = paging.KERNEL_VMA;

pub const disableInterrupts = cpu.cli;
pub const enableInterrupts = cpu.sti;
pub const saveAndDisableInterrupts = cpu.saveAndDisableInterrupts;
pub const outl = port.outl;
pub const inl = port.inl;
pub const restoreInterrupts = cpu.restoreInterrupts;
pub const halt = cpu.halt;
pub const raiseInvalidOpcode = cpu.raiseInvalidOpcode;
pub const resetByTripleFault = cpu.resetByTripleFault;

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

const syscall_arch = @import("syscall_arch.zig");

pub const loadIoBitmap = gdt.loadIoBitmap;
pub const enableIoBitmap = gdt.enableIoBitmap;
pub const denyIoPorts = gdt.denyIoPorts;

pub const InterruptFrame = idt.Frame;
pub const IrqToken = idt.IrqToken;
pub const IRQ_LINE_COUNT = idt.MAX_GSI;
pub const gsiClaimed = idt.gsiClaimed;
pub const resolveIrq = idt.resolveIrq;
pub const claimGsi = idt.claimGsi;
pub const releaseGsi = idt.releaseGsi;

pub fn deferIrq(token: IrqToken) void {
    if (token.trigger == .level) lapic.deferEoi(token.vector);
}

pub fn irqMatches(token: IrqToken, frame: *InterruptFrame) bool {
    return token.vector == @as(u8, @truncate(frame.vector));
}

pub fn irqLabel(token: IrqToken) u32 {
    return token.vector;
}

pub fn armIrq(token: IrqToken) void {
    idt.armGsi(token.gsi);
}

pub fn irqAwaitingAck(token: IrqToken) bool {
    return token.trigger == .level and lapic.eoiAwaitingAck(token.vector);
}

pub fn acknowledgeIrq(token: IrqToken) void {
    if (token.trigger == .level) lapic.acknowledgeEoi(token.vector);
}

pub const initSyscalls = syscall_arch.init;
pub const fastSyscallArmed = syscall_arch.fastPathArmed;
pub const invokeSyscall = syscall_arch.invoke;

/// Bring up whatever will deliver interrupts.
///
/// The PICs are remapped first either way: with the IOAPIC they are masked
/// straight afterwards so a stray legacy line cannot arrive looking like a CPU
/// fault, and without it they are what delivers everything.
///
/// `routing` is what firmware said about the machine, which the architecture
/// has no way to discover for itself. Null, or a description with no
/// controller in it, leaves the 8259s in charge: a machine that describes none
/// still boots. Falling back rather than failing matters here, because there
/// is no serial port to find out on.
pub fn initInterruptController(routing: ?irq.Routing) void {
    idt.remapPic();
    idt.maskAllPic();

    const described = routing orelse return;
    if (idt.useIoApic(described)) {
        console.info("apic", "local at {x:0>8}, {d} controller(s), {d} described line(s)", .{
            described.local_address,
            described.controllers.len,
            described.lines.len,
        });
        return;
    }
    console.warn("apic: described but unusable; using the 8259s", .{});
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
pub fn setKernelStack(esp0: u32) void {
    gdt.setKernelStack(esp0);
    // The fast path takes its stack from an MSR rather than from the TSS, so
    // both have to be moved together or one of them goes stale.
    syscall_arch.setKernelStack(esp0);
}

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

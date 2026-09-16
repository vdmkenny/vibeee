//! x86 implementation of the HAL contract in kernel/hal.zig.

const std = @import("std");
const Processor = @import("lib").processor.Processor;
const cpu = @import("cpu.zig");
const fpu = @import("fpu.zig");
const gdt = @import("gdt.zig");
const console = @import("../../kernel/console.zig");
const idt = @import("idt.zig");
const pic = @import("pic.zig");
const irq = @import("../../kernel/irq.zig");
const lapic = @import("lapic.zig");
const port = @import("port.zig");
const paging = @import("paging.zig");
const context = @import("context.zig");
const timer = @import("timer.zig");
const nmiwatch = @import("nmiwatch.zig");
const s3 = @import("s3.zig");

pub const PAGE_SIZE = paging.PAGE_SIZE;
pub const KERNEL_BASE = paging.KERNEL_VMA;

pub const disableInterrupts = cpu.cli;
pub const enableInterrupts = cpu.sti;
pub const saveAndDisableInterrupts = cpu.saveAndDisableInterrupts;

/// Ask the MTRRs to write-combine a physical range. See mtrr.zig.
pub const writeCombine = @import("mtrr.zig").writeCombine;
pub const mtrrRangeCount = @import("mtrr.zig").rangeCount;
pub const mtrrRangeAt = @import("mtrr.zig").rangeAt;
pub const inb = port.inb;
pub const outb = port.outb;
pub const inw = port.inw;
pub const outw = port.outw;
pub const inl = port.inl;
pub const outl = port.outl;
pub const insw = port.insw;
pub const outsw = port.outsw;
pub const ioWait = port.ioWait;
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
pub const Access = paging.Access;
pub const kernelAddressSpace = paging.kernelAddressSpace;
pub const setupUserStack = @import("usermode.zig").setupStack;
pub const enterUserMode = @import("usermode.zig").enter;
pub const mapMmio = paging.mapMmio;
pub const isLinearPhys = paging.isLinear;

/// The instruction-set extensions user programs may be compiled to use, named
/// as the compiler names them and as `cpu.Features` holds them.
const extensions = [_]std.Target.x86.Feature{
    .cmov,   .mmx,      .sse,   .sse2, .sse3,   .ssse3, .sse4_1,
    .sse4_2, .popcnt,   .movbe, .aes,  .pclmul, .sha,   .sse4a,
    .lzcnt,  .@"3dnow",
};

/// The extensions of the processor user programs are compiled for. Not the
/// kernel's own target, which leaves SIMD out of its code.
const model_extensions = (std.meta.stringToEnum(Processor, @import("build_options").processor) orelse
    @compileError("unknown processor")).extensions();

/// The first extension user programs are compiled to use that the running
/// processor lacks.
pub fn missingCpuFeature() ?[]const u8 {
    const has = cpu.Features.detect();
    inline for (extensions) |feature| {
        if (std.Target.x86.featureSetHas(model_extensions, feature) and !@field(has, @tagName(feature))) {
            return @tagName(feature);
        }
    }
    return null;
}

/// Bytes from the processor's random number generator. False when it has none
/// or it would not answer.
pub fn processorRandom(into: []u8) bool {
    if (!cpu.Features.detect().rdrand) return false;
    var at: usize = 0;
    while (at < into.len) {
        const word = rdrand() orelse return false;
        const bytes = std.mem.asBytes(&word);
        const n = @min(bytes.len, into.len - at);
        @memcpy(into[at..][0..n], bytes[0..n]);
        at += n;
    }
    return true;
}

/// One word from RDRAND. It clears the carry flag while it has none ready, so
/// it is asked a few times, as Intel advises.
fn rdrand() ?u32 {
    for (0..10) |_| {
        var word: u32 = undefined;
        const ready = asm volatile (
            \\ rdrand %%eax
            \\ movl %%eax, (%%edx)
            \\ setc %%al
            \\ movzbl %%al, %%eax
            : [ready] "={eax}" (-> u32),
            : [word] "{edx}" (&word),
        );
        if (ready != 0) return word;
    }
    return null;
}

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

/// Take a legacy ISA line for a driver the kernel builds in: install the
/// handler on whichever vector the active controller routed the line to, and
/// let it through.
pub fn claimLegacyIrq(line: u8, handler: idt.Handler) void {
    idt.setHandler(idt.legacyVector(line), handler);
    idt.setIrqMask(line, false);
}
pub const IrqToken = idt.IrqToken;
pub const IRQ_LINE_COUNT = idt.MAX_GSI;
pub const gsiClaimed = idt.gsiClaimed;
pub const resolveIrq = idt.resolveIrq;
pub const claimGsi = idt.claimGsi;
pub const releaseGsi = idt.releaseGsi;

pub const armNmiWatchdog = nmiwatch.arm;
pub const wedgeSoon = timer.wedgeSoon;

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

pub const interruptsInService = struct {
    fn call(into: []u8) usize {
        return lapic.vectorsOf(.in_service, into);
    }
}.call;

pub const interruptsRequested = struct {
    fn call(into: []u8) usize {
        return lapic.vectorsOf(.request, into);
    }
}.call;

pub const interruptsLevel = struct {
    fn call(into: []u8) usize {
        return lapic.vectorsOf(.trigger_mode, into);
    }
}.call;

pub const interruptPriority = lapic.processorPriority;

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
    pic.remap(idt.IRQ_BASE);
    pic.maskAll();

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

pub const sleepToMemory = s3.sleepToMemory;

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
pub const pmTimerRuns = timer.pmTimerRuns;

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

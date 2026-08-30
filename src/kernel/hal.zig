//! THE portability contract.
//!
//! `kernel/` must never import anything from `arch/` directly, it imports this
//! file, and `build.zig` binds the implementation for the target. Porting
//! vibeee to another architecture means implementing exactly what is listed
//! here, and this file is deliberately kept to one readable page so that
//! statement stays true and auditable.
//!
//! See design/00-vibeee.md §3.

const builtin = @import("builtin");

/// The active architecture backend. Adding an architecture means adding a
/// branch here and a directory under src/arch/.
pub const impl = switch (builtin.cpu.arch) {
    .x86 => @import("../arch/x86/hal_impl.zig"),
    else => @compileError(
        \\vibeee has no HAL implementation for this architecture.
        \\Implement src/arch/<name>/hal_impl.zig against the interface in
        \\src/kernel/hal.zig and add a branch here.
    ),
};

/// Whether this build has an architecture backend at all.
///
/// False only in the host test build, which compiles the portable parts
/// natively so their tables and algorithms can be checked without an emulator.
/// A module worth testing there guards its hardware access on this, and the
/// guarded code is then never analysed for a target that could not run it.
pub const available: bool = builtin.cpu.arch == .x86;

/// Compile-time capability flags. Code that needs port I/O (x86-only) guards
/// on this rather than on the architecture name, so an architecture that grows
/// the capability later does not need every call site edited.
pub const caps = struct {
    pub const port_io: bool = @hasDecl(impl, "inb");
    pub const has_ioapic: bool = @hasDecl(impl, "ioapicInit");
};

// ---------------------------------------------------------------------------
// Interrupt control
// ---------------------------------------------------------------------------

pub const disableInterrupts = impl.disableInterrupts;
pub const enableInterrupts = impl.enableInterrupts;
/// Disable interrupts, returning the previous state for nested restore.
pub const saveAndDisableInterrupts = impl.saveAndDisableInterrupts;
pub const outl = impl.outl;
pub const inl = impl.inl;
pub const restoreInterrupts = impl.restoreInterrupts;
/// Park the CPU until the next interrupt. The idle loop's entire body.
pub const idle = impl.idle;
pub const halt = impl.halt;
/// A deliberate invalid opcode, for exercising the exception path on demand.
pub const raiseInvalidOpcode = impl.raiseInvalidOpcode;
/// Reset by triple fault, the last resort that needs no chipset.
pub const resetByTripleFault = impl.resetByTripleFault;

// ---------------------------------------------------------------------------
// Early platform bring-up, in the order the kernel calls them
// ---------------------------------------------------------------------------

/// Descriptor tables, exception vectors, whatever the architecture needs before
/// it can survive a fault. Must leave interrupts disabled.
pub const initCpu = impl.initCpu;
/// Interrupt controller: routing, masking, EOI. Called after initCpu.
pub const initInterruptController = impl.initInterruptController;
/// Install the syscall entry path. After this, user code can trap into the
/// kernel; before it, the syscall vector is a fault like any other.
pub const initSyscalls = impl.initSyscalls;
/// Port access for a process the device manager trusted with it.
pub const loadIoBitmap = impl.loadIoBitmap;
pub const enableIoBitmap = impl.enableIoBitmap;
pub const denyIoPorts = impl.denyIoPorts;

/// Claiming a global interrupt line for a handler, for the driver capability.
pub const InterruptFrame = impl.InterruptFrame;
pub const IrqToken = impl.IrqToken;
/// Number of architecture interrupt identifiers representable by the backend.
pub const IRQ_LINE_COUNT = impl.IRQ_LINE_COUNT;
pub const gsiClaimed = impl.gsiClaimed;
pub const claimGsi = impl.claimGsi;
pub const resolveIrq = impl.resolveIrq;
pub const releaseGsi = impl.releaseGsi;
pub const deferIrq = impl.deferIrq;
/// Compare an opaque architecture token with the interrupt being dispatched.
pub const irqMatches = impl.irqMatches;
/// Numeric token identity for diagnostics only.
pub const irqLabel = impl.irqLabel;
/// Make a claimed route deliverable when its architecture deferred that step.
pub const armIrq = impl.armIrq;
pub const irqAwaitingAck = impl.irqAwaitingAck;
pub const acknowledgeIrq = impl.acknowledgeIrq;

/// Whether the fast syscall path is programmed and usable.
pub const fastSyscallArmed = impl.fastSyscallArmed;
/// Issue a syscall from kernel mode. Self-tests only.
pub const invokeSyscall = impl.invokeSyscall;

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

pub const PAGE_SIZE = impl.PAGE_SIZE;
/// Bits of address within a page. Derived, so it cannot disagree with PAGE_SIZE.
pub const PAGE_SHIFT: u5 = @ctz(@as(u32, PAGE_SIZE));
/// Kernel-half base of the linear physical map.
pub const KERNEL_BASE = impl.KERNEL_BASE;
pub const physToVirt = impl.physToVirt;
pub const virtToPhys = impl.virtToPhys;
pub const invalidatePage = impl.invalidatePage;
/// Release the boot-time identity mapping, once the kernel is running from its
/// virtual addresses and no longer needs low addresses to resolve.
pub const dropBootIdentityMapping = impl.dropBootIdentityMapping;
/// A process address space. The kernel half is shared by all of them, so a
/// syscall needs no address-space switch.
pub const AddressSpace = impl.AddressSpace;
/// The address space the kernel booted with, used by kernel-only threads.
pub const kernelAddressSpace = impl.kernelAddressSpace;
/// Build a process's initial stack, with arguments on it in whatever form the
/// architecture's entry convention expects.
pub const setupUserStack = impl.setupUserStack;
/// Drop to user mode. Does not return.
pub const enterUserMode = impl.enterUserMode;
/// Map a device aperture into the kernel half. Needed for anything at a
/// physical address above RAM, which the linear map does not reach.
pub const mapMmio = impl.mapMmio;
/// True when a physical address is reachable through the linear map.
pub const isLinearPhys = impl.isLinearPhys;

// ---------------------------------------------------------------------------
// Threads
// ---------------------------------------------------------------------------

/// Save the outgoing stack pointer through the first argument and resume the
/// context at the second. Returns in the incoming thread.
/// Saved floating-point and SIMD state, switched with the thread that owns it.
pub const FpuState = impl.FpuState;
pub const saveFpu = impl.saveFpu;
pub const restoreFpu = impl.restoreFpu;
pub const initFpuState = impl.initFpuState;

/// Point the CPU at the kernel stack for the next privilege transition.
pub const setKernelStack = impl.setKernelStack;

pub const switchContext = impl.switchContext;
/// Build a stack that `switchContext` can resume into, for a thread that has
/// never run.
pub const initThreadStack = impl.initThreadStack;

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

/// Monotonic microseconds. Backed by whichever source survived the selection
/// ladder in design §6.5, on the 701 that is HPET if we managed to force-enable
/// it, otherwise the ACPI PM timer. Never the TSC, which halts in idle.
pub const monotonicMicros = impl.monotonicMicros;
pub const tickCount = impl.tickCount;
/// Start the periodic tick. Must follow the interrupt controller.
pub const initTimer = impl.initTimer;
/// Which clock source won the selection ladder, for the boot log.
pub const timerSourceName = impl.timerSourceName;
/// Cheap relative counter, valid only within a scheduling quantum.
pub const cycleCounter = impl.cycleCounter;

// ---------------------------------------------------------------------------
// CPU identity, for logging and for feature gating
// ---------------------------------------------------------------------------

pub const CpuInfo = struct {
    vendor: []const u8,
    brand: []const u8,
    /// Set when the architecture offers a fast syscall entry (SYSENTER/SVC).
    fast_syscall: bool,
    /// Set when frequency scaling exists at all. False on the 701, the
    /// Celeron M has SpeedStep fused off, so there is no governor to write.
    freq_scaling: bool,
};

pub const cpuInfo = impl.cpuInfo;

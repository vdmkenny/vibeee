//! The host interface uACPI is written against, answered from userspace.
//!
//! uACPI asks its host for the few things it cannot do itself: where the tables
//! are, memory and ports to reach, memory to allocate, and a way to wait.
//! Every one is a syscall here, which is the point of running an interpreter
//! for somebody else's bytecode in a process rather than in the kernel: what it
//! can touch is what `platd` was granted, and nothing else.
//!
//! Exported with the C ABI because uACPI is C. There is no shim between these
//! and it: they are the definitions it links against.

const std = @import("std");
const heap = @import("ulib").heap;
const out = @import("ulib").out;
const ports = @import("ulib").ports;
const sys = @import("sys");

/// uACPI's own numbering, which crosses the boundary as plain integers.
const Status = enum(u32) {
    ok = 0,
    not_found = 6,
    unimplemented = 8,

    fn value(self: Status) u32 {
        return @intFromEnum(self);
    }
};

/// Its log levels, which run the other way from what a reader expects: one is
/// the worst.
const Level = enum(u32) { err = 1, warn = 2, info = 3, trace = 4, debug = 5 };

// ---------------------------------------------------------------------------
// Where the tables are
// ---------------------------------------------------------------------------

/// The kernel found the root pointer during its own table walk and can say
/// where it was, which saves searching the BIOS area again from a process that
/// would have to map it to look.
export fn uacpi_kernel_get_rsdp(out_address: *u32) callconv(.c) u32 {
    var buf: [32]u8 = @splat(0);
    const at = std.fmt.parseInt(u32, info.ask("acpi", &buf), 16) catch
        return Status.not_found.value();
    if (at == 0) return Status.not_found.value();

    out_address.* = at;
    return Status.ok.value();
}

const info = @import("ulib").info;

// ---------------------------------------------------------------------------
// Physical memory
// ---------------------------------------------------------------------------

/// The kernel maps whole pages, so the offset within the page is put back
/// afterwards: a table rarely begins on a boundary and uACPI expects the
/// address it asked for.
export fn uacpi_kernel_map(phys: u32, len: usize) callconv(.c) ?[*]u8 {
    const base = std.mem.alignBackward(u32, phys, PAGE);
    const skew = phys - base;

    // A refusal is worth saying: uACPI does not check, and a null handed back
    // becomes a fault somewhere with no obvious connection to the mapping.
    const mapped = sys.mapDevice(base, len + skew) orelse {
        out.text("acpi fail    cannot map firmware memory\n");
        out.flush();
        return null;
    };
    return @as([*]u8, @ptrCast(@volatileCast(mapped))) + skew;
}

/// Nothing is given back.
///
/// A mapping costs page-table entries, this process holds a handful of tables
/// for its whole life, and giving one back would mean remembering what was
/// rounded away to find the page again. The trade is a few pages against a
/// bookkeeping structure and the bugs in it.
export fn uacpi_kernel_unmap(_: ?[*]u8, _: usize) callconv(.c) void {}

const PAGE = 4096;

// ---------------------------------------------------------------------------
// Memory the interpreter allocates
// ---------------------------------------------------------------------------

export fn uacpi_kernel_alloc(size: usize) callconv(.c) ?*anyopaque {
    return heap.alloc(size);
}

export fn uacpi_kernel_alloc_zeroed(size: usize) callconv(.c) ?*anyopaque {
    return heap.zeroed(1, size);
}

export fn uacpi_kernel_free(pointer: ?*anyopaque) callconv(.c) void {
    heap.release(pointer);
}

// ---------------------------------------------------------------------------
// Ports
// ---------------------------------------------------------------------------
//
// A range is granted once and the base becomes the handle, because that is all
// a handle has to carry: the reads and writes that follow are offsets from it.

export fn uacpi_kernel_io_map(base: u32, len: usize, out_handle: *?*anyopaque) callconv(.c) u32 {
    if (sys.ioportGrant(@truncate(base), len) < 0) return Status.not_found.value();

    out_handle.* = @ptrFromInt(base);
    return Status.ok.value();
}

/// A grant is not taken back. It was made to this process for the life of the
/// process, and the kernel drops it when the process ends.
export fn uacpi_kernel_io_unmap(_: ?*anyopaque) callconv(.c) void {}

export fn uacpi_kernel_io_read8(handle: ?*anyopaque, offset: usize, value: *u8) callconv(.c) u32 {
    value.* = ports.in8(portOf(handle, offset));
    return Status.ok.value();
}

export fn uacpi_kernel_io_read16(handle: ?*anyopaque, offset: usize, value: *u16) callconv(.c) u32 {
    value.* = ports.in16(portOf(handle, offset));
    return Status.ok.value();
}

export fn uacpi_kernel_io_read32(handle: ?*anyopaque, offset: usize, value: *u32) callconv(.c) u32 {
    value.* = ports.in32(portOf(handle, offset));
    return Status.ok.value();
}

export fn uacpi_kernel_io_write8(handle: ?*anyopaque, offset: usize, value: u8) callconv(.c) u32 {
    ports.out8(portOf(handle, offset), value);
    return Status.ok.value();
}

export fn uacpi_kernel_io_write16(handle: ?*anyopaque, offset: usize, value: u16) callconv(.c) u32 {
    ports.out16(portOf(handle, offset), value);
    return Status.ok.value();
}

export fn uacpi_kernel_io_write32(handle: ?*anyopaque, offset: usize, value: u32) callconv(.c) u32 {
    ports.out32(portOf(handle, offset), value);
    return Status.ok.value();
}

fn portOf(handle: ?*anyopaque, offset: usize) u16 {
    return @truncate(@intFromPtr(handle) + offset);
}

// ---------------------------------------------------------------------------
// Memory-mapped registers
// ---------------------------------------------------------------------------
//
// Already mapped by `uacpi_kernel_map`, so these are the accesses themselves.
// Volatile, because a register read has an effect and a compiler that decided
// two of them were the same read would be right about the value and wrong
// about the device.

export fn uacpi_kernel_mmio_read8(at: *volatile u8) callconv(.c) u8 {
    return at.*;
}
export fn uacpi_kernel_mmio_read16(at: *volatile u16) callconv(.c) u16 {
    return at.*;
}
export fn uacpi_kernel_mmio_read32(at: *volatile u32) callconv(.c) u32 {
    return at.*;
}
export fn uacpi_kernel_mmio_read64(at: *volatile u64) callconv(.c) u64 {
    return at.*;
}
export fn uacpi_kernel_mmio_write8(at: *volatile u8, value: u8) callconv(.c) void {
    at.* = value;
}
export fn uacpi_kernel_mmio_write16(at: *volatile u16, value: u16) callconv(.c) void {
    at.* = value;
}
export fn uacpi_kernel_mmio_write32(at: *volatile u32, value: u32) callconv(.c) void {
    at.* = value;
}
export fn uacpi_kernel_mmio_write64(at: *volatile u64, value: u64) callconv(.c) void {
    at.* = value;
}

// ---------------------------------------------------------------------------
// PCI configuration space
// ---------------------------------------------------------------------------

/// One segment only, which is what a machine of this age has: there is no
/// ECAM here, just the two ports below.
///
/// Reached through `abi.c` rather than exported directly, because uACPI passes
/// the address as a struct by value and that is the one shape whose calling
/// convention is worth writing in C to be sure of.
export fn platd_pci_open(
    segment: u16,
    bus: u8,
    device: u8,
    function: u8,
    out_handle: *?*anyopaque,
) callconv(.c) u32 {
    if (segment != 0) return Status.not_found.value();
    if (!haveConfigPorts()) return Status.not_found.value();

    const selector: u32 = (@as(u32, bus) << 16) |
        (@as(u32, device) << 11) |
        (@as(u32, function) << 8);

    out_handle.* = @ptrFromInt(selector | ENABLE);
    return Status.ok.value();
}

export fn uacpi_kernel_pci_device_close(_: ?*anyopaque) callconv(.c) void {}

export fn uacpi_kernel_pci_read8(handle: ?*anyopaque, offset: usize, value: *u8) callconv(.c) u32 {
    value.* = @truncate(configRead(handle, offset) >> shiftFor(offset));
    return Status.ok.value();
}

export fn uacpi_kernel_pci_read16(handle: ?*anyopaque, offset: usize, value: *u16) callconv(.c) u32 {
    value.* = @truncate(configRead(handle, offset) >> shiftFor(offset));
    return Status.ok.value();
}

export fn uacpi_kernel_pci_read32(handle: ?*anyopaque, offset: usize, value: *u32) callconv(.c) u32 {
    value.* = configRead(handle, offset);
    return Status.ok.value();
}

export fn uacpi_kernel_pci_write8(handle: ?*anyopaque, offset: usize, value: u8) callconv(.c) u32 {
    return configMerge(handle, offset, value, 0xFF);
}

export fn uacpi_kernel_pci_write16(handle: ?*anyopaque, offset: usize, value: u16) callconv(.c) u32 {
    return configMerge(handle, offset, value, 0xFFFF);
}

export fn uacpi_kernel_pci_write32(handle: ?*anyopaque, offset: usize, value: u32) callconv(.c) u32 {
    configWrite(handle, offset, value);
    return Status.ok.value();
}

/// Configuration space is addressed a whole word at a time, so a narrower
/// write is a read, a splice and a write back.
fn configMerge(handle: ?*anyopaque, offset: usize, value: u32, mask: u32) u32 {
    const shift = shiftFor(offset);
    const was = configRead(handle, offset);

    configWrite(handle, offset, (was & ~(mask << shift)) | ((value & mask) << shift));
    return Status.ok.value();
}

fn configRead(handle: ?*anyopaque, offset: usize) u32 {
    ports.out32(ADDRESS, selectorFor(handle, offset));
    return ports.in32(DATA);
}

fn configWrite(handle: ?*anyopaque, offset: usize, value: u32) void {
    ports.out32(ADDRESS, selectorFor(handle, offset));
    ports.out32(DATA, value);
}

fn selectorFor(handle: ?*anyopaque, offset: usize) u32 {
    return @as(u32, @truncate(@intFromPtr(handle))) | (@as(u32, @truncate(offset)) & 0xFC);
}

fn shiftFor(offset: usize) u5 {
    return @intCast((offset & 3) * 8);
}

/// Ask for the two configuration ports, once.
///
/// Every other port this process touches is one uACPI asked to map, and it
/// never asks for these: it expects its host to already have whatever reaching
/// configuration space takes. On this machine that is the address and data
/// pair, so this is where they are asked for.
fn haveConfigPorts() bool {
    if (granted) return true;
    if (sys.ioportGrant(ADDRESS, 8) < 0) return false;

    granted = true;
    return true;
}

var granted = false;

const ADDRESS: u16 = 0xCF8;
const DATA: u16 = 0xCFC;
const ENABLE: u32 = 0x8000_0000;

// ---------------------------------------------------------------------------
// Time
// ---------------------------------------------------------------------------

/// Busy-waiting, because that is what a stall is for: it appears in bus timing
/// where yielding would let something else touch the device mid-sequence.
export fn uacpi_kernel_stall(micros: u8) callconv(.c) void {
    const until = sys.clockMicros() + micros;
    while (sys.clockMicros() < until) {}
}

export fn uacpi_kernel_sleep(millis: u64) callconv(.c) void {
    sys.sleepMicros(@intCast(millis * 1000));
}

export fn uacpi_kernel_get_nanoseconds_since_boot() callconv(.c) u64 {
    return sys.clockMicros() * 1000;
}

// ---------------------------------------------------------------------------
// Locking, on a server with one thread
// ---------------------------------------------------------------------------
//
// Every one of these is a token nobody contends for. `platd` serves one request
// at a time and an evaluation runs to completion inside one, so a real lock
// would be a syscall to discover that nothing else was waiting. Interrupts are
// the kernel's and are not this process's to disable.

export fn uacpi_kernel_create_mutex() callconv(.c) ?*anyopaque {
    return &token;
}
export fn uacpi_kernel_free_mutex(_: ?*anyopaque) callconv(.c) void {}
export fn uacpi_kernel_acquire_mutex(_: ?*anyopaque, _: u16) callconv(.c) u32 {
    return Status.ok.value();
}
export fn uacpi_kernel_release_mutex(_: ?*anyopaque) callconv(.c) void {}

export fn uacpi_kernel_create_spinlock() callconv(.c) ?*anyopaque {
    return &token;
}
export fn uacpi_kernel_free_spinlock(_: ?*anyopaque) callconv(.c) void {}
export fn uacpi_kernel_lock_spinlock(_: ?*anyopaque) callconv(.c) c_ulong {
    return 0;
}
export fn uacpi_kernel_unlock_spinlock(_: ?*anyopaque, _: c_ulong) callconv(.c) void {}

export fn uacpi_kernel_get_thread_id() callconv(.c) ?*anyopaque {
    return &token;
}

export fn uacpi_kernel_disable_interrupts() callconv(.c) c_ulong {
    return 0;
}
export fn uacpi_kernel_restore_interrupts(_: c_ulong) callconv(.c) void {}

var token: u8 = 0;

// ---------------------------------------------------------------------------
// Events, which nothing here waits on yet
// ---------------------------------------------------------------------------

/// The kernel's own counting events, one syscall each.
///
/// A handle is a small number and a handle of zero is standard input, so it is
/// carried as one more than itself: null would otherwise be indistinguishable
/// from a valid event.
export fn uacpi_kernel_create_event() callconv(.c) ?*anyopaque {
    const handle = sys.eventCreate();
    if (handle < 0) return null;
    return @ptrFromInt(@as(usize, @intCast(handle)) + 1);
}

export fn uacpi_kernel_free_event(event: ?*anyopaque) callconv(.c) void {
    if (handleOf(event)) |handle| _ = sys.close(handle);
}

export fn uacpi_kernel_signal_event(event: ?*anyopaque) callconv(.c) void {
    if (handleOf(event)) |handle| _ = sys.eventSignal(handle);
}

/// A counting event has nothing to reset: an unconsumed signal is a signal
/// that has not been acted on, and dropping it would lose the news.
export fn uacpi_kernel_reset_event(_: ?*anyopaque) callconv(.c) void {}

fn handleOf(event: ?*anyopaque) ?u32 {
    const carried = @intFromPtr(event);
    return if (carried == 0) null else @intCast(carried - 1);
}

/// Wait for one, servicing the interrupt that would signal it.
///
/// This is where uACPI waits for the firmware to release the global lock, and
/// the release arrives as a system control interrupt whose handler signals the
/// very event being waited for. So the wait services that interrupt itself:
/// `platd` has one thread, and during start-up it is inside uACPI and has not
/// reached the loop that would otherwise do it. Waiting without servicing is
/// waiting for something only this could cause.
///
/// **Bounded across the loop, not the attempt.** uACPI asks sixty-five
/// thousand times and waits between each, so a wait that is generous per
/// attempt is a machine that never finishes starting: twenty milliseconds
/// apiece is twenty minutes. What matters is the total, because a firmware
/// that has not released the lock in a tenth of a second is not about to.
/// After that this answers at once and lets the loop run itself out.
export fn uacpi_kernel_wait_for_event(event: ?*anyopaque, millis: u16) callconv(.c) bool {
    const handle = handleOf(event) orelse return false;

    if (spent >= BUDGET_US or !sci.attached()) return false;

    const slice = @min(@as(usize, millis) * 1000, SLICE_US);
    spent += slice;

    const woke = sys.waitMany(&.{ handle, sci.event }, slice);
    if (woke == 0) {
        // Got it. Whatever this was waiting for has happened, so the next
        // thing to wait starts with the full budget.
        spent = 0;
        return true;
    }

    // The interrupt, or nothing. Servicing it is what may signal the event
    // this is waiting for, so it is done here rather than left for a loop
    // this call is standing in front of.
    if (woke > 0) sci.service();
    return false;
}

/// How long the whole of one acquisition may spend waiting.
var spent: usize = 0;

/// Long enough for a firmware that is about to release the lock, short enough
/// that a service does not disappear while one that will not is asked sixty-five
/// thousand times.
const BUDGET_US: usize = 100_000;

/// How long to sit in one wait before looking again. Short, because what is
/// being waited for is caused by work this same thread has to do.
const SLICE_US: usize = 2000;

/// Long enough that the firmware has a chance to finish what it is doing,
/// short enough that a service does not disappear for a minute if it never
/// does. uACPI asks for sixty-five seconds and retries sixty-five thousand
/// times; taking that literally is a machine that stops for a fortnight.
const WAIT_MAX_MS: usize = 20;

// ---------------------------------------------------------------------------
// The rest
// ---------------------------------------------------------------------------

export fn uacpi_kernel_initialize(_: u32) callconv(.c) u32 {
    return Status.ok.value();
}

export fn uacpi_kernel_deinitialize() callconv(.c) void {}

/// A `Breakpoint` or a `Fatal` in the firmware's own bytecode.
///
/// Reported and carried on. `Fatal` means the firmware has decided something
/// is unrecoverable, and on a machine whose only job is to be a netbook, saying
/// so and continuing beats stopping on the say-so of a table.
export fn uacpi_kernel_handle_firmware_request(_: ?*anyopaque) callconv(.c) u32 {
    out.text("acpi         the firmware asked to stop; carrying on\n");
    out.flush();
    return Status.ok.value();
}

/// The system control interrupt, which is how the firmware says anything at
/// all: a general-purpose event, a lid closing, the global lock being released.
///
/// Attached rather than handled here. The line becomes an event the serve loop
/// waits on beside its channel, and the handler runs there, on the one thread
/// this process has. Running it in an interrupt context is not available and
/// would not be wanted: an AML method can take milliseconds.
pub var sci: Line = .{};

pub const Line = struct {
    /// Which interrupt uACPI asked for, and the event it becomes once armed.
    line: u32 = 0,
    event: u32 = 0,
    handler: ?*const fn (?*anyopaque) callconv(.c) u32 = null,
    context: ?*anyopaque = null,

    pub fn attached(self: Line) bool {
        return self.handler != null and self.event != 0;
    }

    /// Make the line live, once there is something able to answer it.
    pub fn arm(self: *Line) bool {
        if (self.handler == null or self.event != 0) return false;

        self.event = sys.irqAttach(self.line) catch return false;
        return true;
    }

    /// Run what uACPI installed, and tell the kernel the line may fire again.
    pub fn service(self: Line) void {
        if (self.handler) |run| _ = run(self.context);
        _ = sys.irqAck(self.event);
    }
};

export fn uacpi_kernel_install_interrupt_handler(
    irq: u32,
    handler: ?*const fn (?*anyopaque) callconv(.c) u32,
    context: ?*anyopaque,
    out_handle: *?*anyopaque,
) callconv(.c) u32 {
    // Remembered, and not attached yet.
    //
    // uACPI installs this while the namespace is still initialising, and the
    // line must not be live before the general-purpose events are finalised:
    // the handler cannot dispatch a GPE it has not been told about, so it
    // cannot clear the one that fired, and the interrupt arrives again the
    // moment it is acknowledged. On the target machine that is a boot that
    // never finishes. QEMU never raises it, which is why this only appeared on
    // hardware.
    //
    // `arm` is called when bring-up is done.
    sci = .{ .line = irq, .handler = handler, .context = context };
    out_handle.* = @ptrFromInt(@as(usize, irq) + 1);
    return Status.ok.value();
}

export fn uacpi_kernel_uninstall_interrupt_handler(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) u32 {
    sci = .{};
    return Status.ok.value();
}

/// Run now rather than later. There is one thread, so deferring work would
/// mean building a queue that only this could drain, and draining it is what
/// the caller wanted anyway.
export fn uacpi_kernel_schedule_work(
    _: u32,
    handler: ?*const fn (?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
) callconv(.c) u32 {
    if (handler) |run| run(ctx);
    return Status.ok.value();
}

export fn uacpi_kernel_wait_for_work_completion() callconv(.c) u32 {
    return Status.ok.value();
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

/// uACPI has already formatted the line; what arrives is text and a level.
export fn uacpi_kernel_log(level: u32, text: [*:0]const u8) callconv(.c) void {
    const said = std.mem.span(text);

    out.pad(switch (@as(Level, @enumFromInt(level))) {
        .err => "acpi fail",
        .warn => "acpi warn",
        .info => "acpi",
        .trace => "acpi trace",
        .debug => "acpi debug",
    }, 13);
    out.text(said);
    if (said.len == 0 or said[said.len - 1] != '\n') out.byte('\n');
    out.flush();
}

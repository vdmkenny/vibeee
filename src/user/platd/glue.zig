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
const log = @import("ulib").log;
const out = @import("ulib").out;
const ports = @import("ulib").ports;
const sys = @import("sys");
const uacpi = @import("uacpi.zig");
const work = @import("work.zig");

/// uACPI's own numbering, which crosses the boundary as plain integers.
/// One status enum for the whole process, `uacpi.zig`'s.
const Status = uacpi.Status;

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
        log.fail("acpi", "cannot map firmware memory");
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

    // Each range once, when it is first asked for. Which ports the bytecode
    // reaches is not knowable in advance, and the one named just before a
    // silent stop is the answer to what the machine was doing when it stopped:
    // a write to the firmware's trap port enters system management mode, and
    // whether that returns is the firmware's decision alone.
    log.begin("platd", .dim);
    out.text("firmware asked for ports 0x");
    out.hex(base, 2);
    out.text("..0x");
    out.hex(base + len - 1, 2);
    log.end();

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
    return ioWrite(u8, handle, offset, value);
}

export fn uacpi_kernel_io_write16(handle: ?*anyopaque, offset: usize, value: u16) callconv(.c) u32 {
    return ioWrite(u16, handle, offset, value);
}

export fn uacpi_kernel_io_write32(handle: ?*anyopaque, offset: usize, value: u32) callconv(.c) u32 {
    return ioWrite(u32, handle, offset, value);
}

/// One shape for the three widths, bracketing the trap port on both sides.
fn ioWrite(comptime T: type, handle: ?*anyopaque, offset: usize, value: T) u32 {
    const at = portOf(handle, offset);
    knock(at, value);
    switch (T) {
        u8 => ports.out8(at, value),
        u16 => ports.out16(at, value),
        u32 => ports.out32(at, value),
        else => @compileError("a port takes one of the three widths"),
    }
    answered(at);
    return Status.ok.value();
}

/// Where the chipset listens for the firmware's own attention. The FADT names
/// it too; 0xB2 is where every ICH has kept it.
const TRAP_PORT: u16 = 0xB2;

/// Say a trap-port write before it happens, whatever its width, because it
/// may not return: the CPU disappears into the firmware's own handler, and
/// whether it comes back is that handler's decision. A boot that stops with
/// this as its last line has named both the door and the knock.
fn isTrap(at: u16) bool {
    return at == TRAP_PORT or at == TRAP_PORT + 1;
}

fn knock(at: u16, value: u32) void {
    if (!isTrap(at)) return;

    log.begin("platd", .dim);
    out.text("trap port 0x");
    out.hex(at, 2);
    out.text(" takes 0x");
    out.hex(value, 2);
    log.end();
}

/// The other bracket. A knock with no answer line after it is the firmware
/// never having handed the CPU back; an answer line followed by silence moves
/// the fault out of the firmware and into what ran next.
fn answered(at: u16) void {
    if (!isTrap(at)) return;
    log.say("platd", .dim, "trap answered");
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

    // The handle is the kernel's packed location; the kernel owns the
    // configuration ports, because this process is not the only one that
    // reads them and the pair cannot serve two selectors at once.
    const location = (@as(u32, bus) << 8) | (@as(u32, device & 0x1F) << 3) | (function & 0x7);
    out_handle.* = @ptrFromInt(location | HANDLE_MARK);
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

/// A location handle is never null even for bus zero device zero, so the
/// packed location carries a mark bit above the location bits.
const HANDLE_MARK: u32 = 1 << 31;

fn configRead(handle: ?*anyopaque, offset: usize) u32 {
    return sys.pciRead(locationOf(handle), @truncate(offset & 0xFC));
}

fn configWrite(handle: ?*anyopaque, offset: usize, value: u32) void {
    sys.pciWrite(locationOf(handle), @truncate(offset & 0xFC), value);
}

fn locationOf(handle: ?*anyopaque) u32 {
    return @as(u32, @truncate(@intFromPtr(handle))) & ~HANDLE_MARK;
}

fn shiftFor(offset: usize) u5 {
    return @intCast((offset & 3) * 8);
}

/// The address register, as the mechanism lays it out. The low two bits of an
/// offset select a byte within the dword the port returns, so they are not
/// part of the address written.
const Selector = packed struct(u32) {
    _byte: u2 = 0,
    register: u6 = 0,
    function: u3 = 0,
    device: u5 = 0,
    bus: u8 = 0,
    _reserved: u7 = 0,
    enable: bool = false,
};

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

/// Uncontended does not mean interchangeable. uACPI recognises the mutex that
/// stands for the global lock by comparing handles, so every mutex must have
/// its own: with one shared handle, acquiring any AML mutex acquires the
/// firmware's global lock, and the next locked operation waits forever on a
/// lock this process is holding. Never dereferenced, so a bare number serves.
var next_mutex: usize = 1;

export fn uacpi_kernel_create_mutex() callconv(.c) ?*anyopaque {
    next_mutex += 1;
    return @ptrFromInt(next_mutex);
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

    if (spent >= BUDGET_US) return false;

    const slice = @min(@as(usize, millis) * 1000, SLICE_US);
    spent += slice;

    // Bring-up runs before the line is live, and the global lock is released
    // by the firmware raising it. With nothing to wait on, the handler is
    // called directly: it is what reads the status bits and signals whatever
    // the release was holding up.
    if (!sci.attached()) {
        sci.poll();
        if (sys.waitMany(&.{handle}, slice) == 0) {
            spent = 0;
            return true;
        }
        return false;
    }

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

    /// Run what uACPI installed.
    ///
    /// The handler reads the firmware's status bits and dispatches what it
    /// finds. Which thread calls it is not part of what it does, so it is also
    /// how the firmware is asked directly while there is no line.
    pub fn poll(self: Line) void {
        if (self.handler) |run| _ = run(self.context);
    }

    /// The same, and tell the kernel the line may fire again.
    pub fn service(self: Line) void {
        self.poll();
        _ = sys.irqAck(self.event);
    }
};

export fn uacpi_kernel_install_interrupt_handler(
    irq: u32,
    handler: ?*const fn (?*anyopaque) callconv(.c) u32,
    context: ?*anyopaque,
    out_handle: *?*anyopaque,
) callconv(.c) u32 {
    // Remembered, not attached. uACPI installs this while the namespace is
    // still initialising, and the line must stay dark until the
    // general-purpose events are finalised: a handler that has not been told
    // about a GPE cannot clear the one that fired, so the interrupt arrives
    // again the moment it is acknowledged. `arm` makes it live.
    sci = .{ .line = irq, .handler = handler, .context = context };
    out_handle.* = @ptrFromInt(@as(usize, irq) + 1);
    return Status.ok.value();
}

export fn uacpi_kernel_uninstall_interrupt_handler(_: ?*anyopaque, _: ?*anyopaque) callconv(.c) u32 {
    sci = .{};
    return Status.ok.value();
}

/// Queued, never run here. The caller is the interpreter's own dispatch, and
/// the work is AML: running it in place would enter the interpreter from
/// inside itself. The serve loop drains the queue.
export fn uacpi_kernel_schedule_work(
    _: u32,
    handler: ?*const fn (?*anyopaque) callconv(.c) void,
    ctx: ?*anyopaque,
) callconv(.c) u32 {
    const run = handler orelse return Status.ok.value();
    return if (work.submit(run, ctx)) Status.ok.value() else Status.denied.value();
}

/// Called from the top of the loop, where running AML is allowed.
export fn uacpi_kernel_wait_for_work_completion() callconv(.c) u32 {
    work.drain();
    return Status.ok.value();
}

// ---------------------------------------------------------------------------
// Logging
// ---------------------------------------------------------------------------

/// uACPI has already formatted the line; what arrives is text and a level.
export fn uacpi_kernel_log(level: u32, text: [*:0]const u8) callconv(.c) void {
    const said = std.mem.span(text);

    // The label says where the line came from and the colour says how bad it
    // is, which is what the kernel's own log does with its column.
    log.begin("acpi", switch (@as(Level, @enumFromInt(level))) {
        .err => .bad,
        .warn => .warn,
        .info => .key,
        .trace, .debug => .dim,
    });

    // uACPI ends its lines and `log` ends them too, so one of the two has to
    // give way.
    out.text(if (said.len > 0 and said[said.len - 1] == '\n') said[0 .. said.len - 1] else said);
    log.end();
}

//! IDT and interrupt entry.
//!
//! The 256 entry stubs are generated at comptime rather than written out by
//! hand or emitted from a NASM macro, this is one of the places Zig genuinely
//! beats the C+asm equivalent, since the stub table and the dispatch table are
//! guaranteed to agree by construction.
//!
//! Gate DPLs matter for privilege safety (design/00-vibeee.md §6.7): hardware
//! IRQ and exception gates are DPL 0 so Ring 3 cannot forge them with `int`,
//! and only the syscall vector is DPL 3.

const std = @import("std");
const console = @import("../../kernel/console.zig");
const nmiwatch = @import("nmiwatch.zig");
const ioapic = @import("ioapic.zig");
const lapic = @import("lapic.zig");
const irq_mod = @import("../../kernel/irq.zig");
const port = @import("port.zig");
const gdt = @import("gdt.zig");

pub const SYSCALL_VECTOR: u8 = 0x80;
/// PIC fallback keeps the conventional contiguous hardware range.
pub const IRQ_BASE: u8 = 32;
/// The SCI is isolated in the lowest APIC priority class. A firmware server
/// that cannot clear it may quarantine this vector, but cannot suppress any
/// other device interrupt while it is being restarted or diagnosed.
const SCI_VECTOR: u8 = 0x20;
const DEVICE_VECTOR_BASE: u8 = 0x30;
const LEGACY_VECTOR_BASE: u8 = 0x50;
const KEYBOARD_VECTOR: u8 = 0xD1;
const MOUSE_VECTOR: u8 = 0xDC;
/// Higher than every deferred userspace vector, so a held device line cannot
/// stop preemption or timeout processing.
pub const TIMER_VECTOR: u8 = 0xE0;

/// Architecture token retained by the portable IRQ object. Keeping trigger
/// mode with the vector makes the EOI policy data rather than a GSI heuristic.
pub const IrqToken = packed struct(u32) {
    vector: u8,
    gsi: u8,
    trigger: irq_mod.Trigger,
    _reserved: u15 = 0,
};

/// Register state pushed by the stubs. Field order is the reverse of the push
/// sequence, `interrupt.s`-equivalent logic lives in `stub()` below.
pub const Frame = extern struct {
    // pushed by us
    gs: u32,
    fs: u32,
    es: u32,
    ds: u32,
    edi: u32,
    esi: u32,
    ebp: u32,
    esp_dummy: u32,
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,
    vector: u32,
    error_code: u32,
    // pushed by the CPU
    eip: u32,
    cs: u32,
    eflags: u32,
    // only present on a privilege change (Ring 3 -> Ring 0)
    user_esp: u32,
    user_ss: u32,
};

pub const Handler = *const fn (*Frame) void;

const GateType = enum(u4) {
    interrupt32 = 0xE, // clears IF on entry
    trap32 = 0xF, // leaves IF alone
};

const Gate = packed struct(u64) {
    offset_low: u16,
    selector: u16,
    zero: u8,
    gate_type: u4,
    storage: u1,
    dpl: u2,
    present: bool,
    offset_high: u16,
};

const Descriptor = extern struct {
    limit: u16 align(1),
    base: u32 align(1),
};

var idt: [256]Gate align(8) = std.mem.zeroes([256]Gate);
var handlers: [256]?Handler = .{null} ** 256;

/// These vectors push an error code themselves; for all others we push a dummy
/// zero so the Frame layout is uniform.
fn pushesErrorCode(comptime vec: u8) bool {
    return switch (vec) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

/// Comptime-generated entry stub for one vector.
fn stub(comptime vec: u8) fn () callconv(.naked) void {
    return struct {
        fn entry() callconv(.naked) void {
            if (comptime !pushesErrorCode(vec)) {
                asm volatile ("pushl $0");
            }
            asm volatile (
                \\ pushl %[v]
                \\ pushal
                \\ pushl %%ds
                \\ pushl %%es
                \\ pushl %%fs
                \\ pushl %%gs
                \\ movw %[kds], %%ax
                \\ movw %%ax, %%ds
                \\ movw %%ax, %%es
                \\ movw %%ax, %%fs
                \\ movw %%ax, %%gs
                \\ pushl %%esp
                \\ call isrDispatch
                \\ addl $4, %%esp
                \\ popl %%gs
                \\ popl %%fs
                \\ popl %%es
                \\ popl %%ds
                \\ popal
                \\ addl $8, %%esp
                \\ iret
                :
                : [v] "i" (@as(u32, vec)),
                  [kds] "i" (gdt.KERNEL_DATA),
            );
        }
    }.entry;
}

export fn isrDispatch(frame: *Frame) callconv(.c) void {
    const vec: u8 = @truncate(frame.vector);

    // The watchdog's NMI first, before anything that could deadlock with
    // the very state it interrupts: no breadcrumbs, no scheduler, no EOI,
    // because NMI delivery owes the APIC nothing.
    if (vec == 2 and nmiwatch.onNmi(frame)) return;

    console.interruptEntered(vec);
    if (handlers[vec]) |h| {
        h(frame);
    } else if (vec < 32) {
        @import("fault.zig").onException(frame);
    } else if (vec != lapic.SPURIOUS_VECTOR) {
        // A line delivering into a vector nobody claimed. Held down and said
        // once: a level line nobody acknowledges at its device refires the
        // moment it is acknowledged at the controller, and a machine that is
        // all interrupt handler does nothing else.
        quietUnclaimed(vec);
    }

    // Only routed hardware vectors receive an EOI. In particular, int 0x80 is
    // above IRQ_BASE but is a software trap; acknowledging it while a device
    // EOI is deferred would retire the wrong interrupt.
    if (lapic.active()) {
        if (vector_triggers[vec] != null and !lapic.isEoiDeferred(vec)) lapic.eoi();
    } else if (vec >= IRQ_BASE and vec < IRQ_BASE + 16) {
        const irq = vec - IRQ_BASE;
        if (irq >= 8) port.outb(0xA0, 0x20);
        port.outb(0x20, 0x20);
    }

    console.interruptLeft(vec);

    // Preemption happens here rather than inside the handler: the interrupt
    // controller has been acknowledged, so switching stacks now cannot strand
    // a line un-acknowledged and wedge further interrupts.
    // The low two bits of the saved CS are the privilege level the interrupt
    // came from, which is how the scheduler knows the thread holds no kernel
    // state and can be ended here.
    @import("../../kernel/sched.zig").onInterruptExit(frame.cs & 3 == 3);
}

fn quietUnclaimed(vec: u8) void {
    const trigger = vector_triggers[vec];
    if (lapic.active() and trigger == .level) {
        // No owner can lower the device pin. Keeping the vector in service is
        // the only safe quarantine when runtime IOAPIC writes are forbidden.
        lapic.deferEoi(vec);
    }
}

fn setGate(vec: u8, handler: *const anyopaque, dpl: u2, gate_type: GateType) void {
    const addr = @intFromPtr(handler);
    idt[vec] = .{
        .offset_low = @truncate(addr & 0xFFFF),
        .selector = gdt.KERNEL_CODE,
        .zero = 0,
        .gate_type = @intFromEnum(gate_type),
        .storage = 0,
        .dpl = dpl,
        .present = true,
        .offset_high = @truncate((addr >> 16) & 0xFFFF),
    };
}

pub fn init() void {
    inline for (0..256) |i| {
        const vec: u8 = @intCast(i);
        // Only the syscall gate is reachable from Ring 3.
        const dpl: u2 = if (vec == SYSCALL_VECTOR) 3 else 0;
        setGate(vec, &stub(vec), dpl, .interrupt32);
    }

    const desc = Descriptor{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    asm volatile ("lidt (%[d])"
        :
        : [d] "r" (&desc),
        : .{ .memory = true });
}

pub fn setHandler(vec: u8, handler: Handler) void {
    handlers[vec] = handler;
}

pub fn unsetHandler(vec: u8) void {
    handlers[vec] = null;
}

/// Remap the 8259 PICs away from vectors 0-15, which collide with the CPU
/// exception range.
///
/// Done whether or not the IOAPIC is used. With it, the PICs are masked
/// afterwards and this only ensures a stray legacy interrupt cannot
/// masquerade as a fault; without it, they are what delivers everything.
pub fn remapPic() void {
    const PIC1_CMD = 0x20;
    const PIC1_DATA = 0x21;
    const PIC2_CMD = 0xA0;
    const PIC2_DATA = 0xA1;

    port.outb(PIC1_CMD, 0x11); // ICW1: init + ICW4 to follow
    port.ioWait();
    port.outb(PIC2_CMD, 0x11);
    port.ioWait();
    port.outb(PIC1_DATA, IRQ_BASE); // ICW2: vector offsets
    port.ioWait();
    port.outb(PIC2_DATA, IRQ_BASE + 8);
    port.ioWait();
    port.outb(PIC1_DATA, 0x04); // ICW3: slave on IRQ2
    port.ioWait();
    port.outb(PIC2_DATA, 0x02);
    port.ioWait();
    port.outb(PIC1_DATA, 0x01); // ICW4: 8086 mode
    port.ioWait();
    port.outb(PIC2_DATA, 0x01);
    port.ioWait();
}

pub fn maskAllPic() void {
    port.outb(0x21, 0xFF);
    port.outb(0xA1, 0xFF);
}

/// Let an ISA interrupt through, or stop it.
///
/// Named for the line a driver knows about rather than for the controller
/// carrying it: which one that is depends on what the firmware described, and
/// a driver asking for its own line should not have to find out.
pub fn setIrqMask(irq: u8, masked: bool) void {
    if (ioapic.active()) {
        ioapic.setMask(routing.resolve(irq).gsi, masked);
        return;
    }
    setPicMask(irq, masked);
}

fn vectorFor(irq: usize) u8 {
    if (!ioapic.active()) return IRQ_BASE + @as(u8, @intCast(irq));
    if (irq == 0) return TIMER_VECTOR;
    const gsi = routing.resolve(@intCast(irq)).gsi;
    if (routing.isSci(gsi)) return SCI_VECTOR;
    if (irq == 1) return KEYBOARD_VECTOR;
    if (irq == 12) return MOUSE_VECTOR;
    return LEGACY_VECTOR_BASE + @as(u8, @intCast(irq));
}

pub fn timerVector() u8 {
    return if (ioapic.active()) TIMER_VECTOR else IRQ_BASE;
}

/// The vector assigned to a legacy IRQ by the active controller.
pub fn legacyVector(irq: u8) u8 {
    return vectorFor(irq);
}

/// Which vector each global line was routed to at boot, or null for one that
/// was not routed at all.
///
/// The ISA lines are routed by their legacy number and land wherever firmware
/// said, so the reverse lookup cannot be arithmetic. Everything above them is
/// unrouted until a driver asks for it.
var gsi_vectors: [MAX_GSI]?u8 = @splat(null);
var vector_triggers: [256]?irq_mod.Trigger = @splat(null);

/// An IOAPIC has twenty-four inputs. Two of them would be a server part.
pub const MAX_GSI = 48;

comptime {
    const last_legacy_vector = LEGACY_VECTOR_BASE + irq_mod.MAX_LINES - 1;
    const device_vector_count = MAX_GSI - irq_mod.MAX_LINES;
    const last_device_vector = DEVICE_VECTOR_BASE + device_vector_count - 1;
    if (IRQ_BASE < 32 or SCI_VECTOR >= LEGACY_VECTOR_BASE) {
        @compileError("the SCI must occupy the lowest hardware priority class");
    }
    if (last_device_vector >= LEGACY_VECTOR_BASE) {
        @compileError("legacy and device interrupt vectors overlap");
    }
    if (last_legacy_vector >= SYSCALL_VECTOR or
        KEYBOARD_VECTOR >> 4 != MOUSE_VECTOR >> 4 or
        KEYBOARD_VECTOR >> 4 <= last_legacy_vector >> 4 or
        TIMER_VECTOR >> 4 <= KEYBOARD_VECTOR >> 4)
    {
        @compileError("kernel interrupt vectors do not outrank deferred userspace vectors");
    }
    if (MAX_GSI > std.math.maxInt(u8) + 1) {
        @compileError("IrqToken cannot represent every global interrupt line");
    }
}

/// The vector a global line delivers on, routing it first if nothing has.
///
/// Null when there is no controller to route with: on the 8259s there are
/// sixteen lines and no way to add one, so a driver asking for a global line
/// is asking for something this machine cannot do.
pub fn vectorForGsi(gsi: u32) ?u8 {
    if (!ioapic.active() or gsi >= MAX_GSI) return null;
    return gsi_vectors[gsi];
}

/// Whether something has already claimed the line.
pub fn gsiClaimed(gsi: u32) bool {
    if (gsi >= MAX_GSI) return false;
    const vector = gsi_vectors[gsi] orelse return false;
    return handlers[vector] != null;
}

/// Take a global line for a handler, or null if something else has it.
pub fn claimGsi(gsi: u32, handler: Handler) ?IrqToken {
    if (gsiClaimed(gsi)) return null;
    const vector = vectorForGsi(gsi) orelse return null;
    const trigger = vector_triggers[vector] orelse return null;

    setHandler(vector, handler);
    // No controller write: device lines were routed at boot, and level lines
    // are held by deferred LAPIC EOI while their userspace owner services them.
    return .{ .vector = vector, .gsi = @intCast(gsi), .trigger = trigger };
}

/// Open a route that boot deliberately left masked, but only if firmware has
/// not changed the entry since. PCI lines on the target are above the legacy
/// range and are already open; this path primarily keeps emulated legacy-PIRQ
/// machines usable without exposing controller details to portable code.
pub fn armGsi(gsi: u32) void {
    if (gsi >= MAX_GSI or routing.isSci(gsi)) return;
    const expected = boot_entries[gsi] orelse return;
    // A line boot left open needs nothing, and the boot record answers that
    // without the hardware: even a controller read starts by writing the
    // shared index register, and on this machine the firmware answers a
    // runtime touch of that pair with a trap that may never return.
    if (!expected.masked) return;
    ioapic.unmaskIfMatches(gsi, expected);
}

pub fn releaseGsi(gsi: u32) void {
    if (gsi < MAX_GSI) {
        if (gsi_vectors[gsi]) |vector| unsetHandler(vector);
    }
}

/// Where a firmware-described interrupt number actually lands.
///
/// The sixteen legacy numbers are what a driver reads out of a table the
/// firmware wrote, and the firmware may have moved any of them: the FADT says
/// the system control interrupt is 9 whether it arrives on line 9 or not.
/// Everything above the legacy range names a line directly.
pub fn resolveIrq(number: u32) irq_mod.Line {
    if (number >= irq_mod.MAX_LINES) return .{ .irq = 0, .gsi = number };
    return routing.resolve(@intCast(number));
}

/// What the firmware said about the legacy lines. Empty until the MADT has
/// been read, which is fine: nothing asks before then.
var routing: irq_mod.Routing = .{};

/// Bring up the IOAPIC and route the ISA lines to the vectors the handlers are
/// already installed at. False when there is no MADT or no controller in it,
/// in which case the 8259s stay in charge.
pub fn useIoApic(info: irq_mod.Routing) bool {
    routing = info;
    if (!lapic.init(info.local_address)) return false;
    if (!ioapic.init(&routing)) return false;

    // The same sixteen vectors the PICs were remapped to, so every driver and
    // every handler keeps the number it already had.
    //
    // Overridden lines are routed first and the global lines they take are
    // then off limits. Without that, IRQ 2 claims the line the timer was moved
    // onto and overwrites it: on the PICs IRQ 2 is the cascade and never a
    // device, and with an IOAPIC there is no cascade at all, so its number is
    // free for the firmware to reuse and here it does.
    const destination = lapic.id();
    var taken: [MAX_GSI]bool = @splat(false);

    for (0..irq_mod.MAX_LINES) |irq| {
        const line = routing.describedLine(@intCast(irq)) orelse continue;
        // Non-SCI legacy lines stay masked until an owner first waits. The SCI
        // route is open now while its chipset source gate remains closed, so
        // enabling firmware events later needs no controller rewrite.
        const vector = vectorFor(irq);
        const masked = !routing.isSci(line.gsi);
        ioapic.route(line.gsi, vector, line.polarity, line.trigger, destination, masked);
        if (line.gsi < taken.len) taken[line.gsi] = true;
        rememberRoute(line.gsi, vector, line.trigger);
    }

    for (0..irq_mod.MAX_LINES) |irq| {
        if (routing.describedLine(@intCast(irq)) != null) continue;
        if (taken[irq]) continue;
        const vector = vectorFor(irq);
        const masked = !routing.isSci(@intCast(irq));
        ioapic.route(@intCast(irq), vector, .high, .edge, destination, masked);
        rememberRoute(@intCast(irq), vector, .edge);
    }

    // The lines above the legacy sixteen are the PIRQ pins the firmware's
    // routing tables name, routed open now, in the boot window where every
    // machine tolerates controller writes. How they trigger is the board's
    // own answer, carried in the routing: level for PCI's electrical truth
    // on a machine with sane firmware, and the FALLING EDGE of the
    // active-low wires where the firmware punishes every runtime word said
    // to the controller, the level completion doorbell included. A level
    // entry owes that doorbell to drop its remote-IRR; on such firmware the
    // entry then believes its last interrupt is still in service and an
    // asserted line delivers nothing more. An edge entry holds no such
    // state, and what makes edge lossless is the drivers' own discipline:
    // each services until its status reads quiet and says whether it found
    // work, so the wire is released on exit, every later cause is a fresh
    // edge, and a neighbour's cause hidden under a shared low wire is
    // chased by the acknowledgement's cascade.
    var gsi: u32 = irq_mod.MAX_LINES;
    const pins = @min(ioapic.inputs(), MAX_GSI);
    while (gsi < pins) : (gsi += 1) {
        if (taken[gsi]) continue;
        const vector = DEVICE_VECTOR_BASE + @as(u8, @intCast(gsi - irq_mod.MAX_LINES));
        ioapic.route(gsi, vector, .low, routing.pirq_trigger, destination, false);
        rememberRoute(gsi, vector, routing.pirq_trigger);
    }

    captureBootEntries();
    maskAllPic();

    // The routes as the controller itself reads them back, for the lines the
    // machine's diagnosis has turned on: what boot believes it wrote and what
    // the silicon holds are two different facts on this firmware.
    if (console.isDebug()) {
        for ([_]u32{ 9, 16, 17 }) |line| {
            if (boot_entries[line]) |entry| {
                console.debug("irq", "line {d} reads back {x:0>8}", .{
                    line, @as(u32, @bitCast(entry)),
                });
            }
        }
        console.debug("irq", "controller version {x}", .{ioapic.version()});
    }
    return true;
}

fn rememberRoute(gsi: u32, vector: u8, trigger: irq_mod.Trigger) void {
    if (gsi >= MAX_GSI) return;
    gsi_vectors[gsi] = vector;
    vector_triggers[vector] = trigger;
}

/// What boot wrote into a line's redirection entry, remembered so a later
/// moment can tell whether the entry it sees is still the one it wrote. The
/// firmware co-owns the controller, and a line whose entry changed since
/// boot is one nobody should write again at runtime.
var boot_entries: [MAX_GSI]?ioapic.Route = @splat(null);

pub fn captureBootEntries() void {
    var gsi: u32 = 0;
    const pins = @min(ioapic.inputs(), MAX_GSI);
    while (gsi < pins) : (gsi += 1) {
        boot_entries[gsi] = ioapic.entryLow(gsi);
    }
}

fn setPicMask(irq: u8, masked: bool) void {
    const p: u16 = if (irq < 8) 0x21 else 0xA1;
    const bit: u3 = @truncate(irq & 7);
    var mask = port.inb(p);
    if (masked) {
        mask |= (@as(u8, 1) << bit);
    } else {
        mask &= ~(@as(u8, 1) << bit);
    }
    port.outb(p, mask);

    // The second PIC reaches the CPU through the first one's line 2. Unmasking
    // a line on it achieves nothing while that cascade is masked, so it is
    // opened here rather than left for every caller to remember.
    if (!masked and irq >= 8) setPicMask(2, false);
}

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
const ioapic = @import("ioapic.zig");
const lapic = @import("lapic.zig");
const irq_mod = @import("../../kernel/irq.zig");
const port = @import("port.zig");
const gdt = @import("gdt.zig");

pub const SYSCALL_VECTOR: u8 = 0x80;
pub const IRQ_BASE: u8 = 32;

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

    // Acknowledged at the controller that delivered it, whichever vector it
    // was. An interrupt the local APIC delivers and never sees acknowledged
    // raises its priority floor for good, and everything at or below, the
    // timer included, is silently never delivered again. Only the spurious
    // vector is excepted: it is the APIC's own and takes no acknowledgement.
    if (lapic.active()) {
        if (vec >= IRQ_BASE and vec != lapic.SPURIOUS_VECTOR) lapic.eoi();
    } else if (vec >= IRQ_BASE and vec < IRQ_BASE + 16) {
        const irq = vec - IRQ_BASE;
        if (irq >= 8) port.outb(0xA0, 0x20);
        port.outb(0x20, 0x20);
    }

    // Preemption happens here rather than inside the handler: the interrupt
    // controller has been acknowledged, so switching stacks now cannot strand
    // a line un-acknowledged and wedge further interrupts.
    // The low two bits of the saved CS are the privilege level the interrupt
    // came from, which is how the scheduler knows the thread holds no kernel
    // state and can be ended here.
    @import("../../kernel/sched.zig").onInterruptExit(frame.cs & 3 == 3);
}

/// Which unclaimed vectors have already been complained about, so a storm
/// costs one line rather than a screenful.
var complained: [256]bool = @splat(false);

fn quietUnclaimed(vec: u8) void {
    for (gsi_vector, 0..) |v, gsi| {
        if (v == vec) setGsiMask(@intCast(gsi), true);
    }

    if (complained[vec]) return;
    complained[vec] = true;
    @import("../../kernel/console.zig").fail("vector {x} has no handler; its line is masked", .{vec});
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
    return IRQ_BASE + @as(u8, @intCast(irq));
}

/// Which vector each global line was routed to at boot, or zero for one that
/// was not routed at all.
///
/// The ISA lines are routed by their legacy number and land wherever firmware
/// said, so the reverse lookup cannot be arithmetic. Everything above them is
/// unrouted until a driver asks for it.
var gsi_vector: [MAX_GSI]u8 = @splat(0);

/// An IOAPIC has twenty-four inputs. Two of them would be a server part.
const MAX_GSI = 48;

/// Where interrupts that are not one of the sixteen legacy lines are sent.
/// Far enough above them that the two ranges cannot be confused in a dump.
const DEVICE_VECTOR_BASE: u8 = 0x30;

/// The vector a global line delivers on, routing it first if nothing has.
///
/// Null when there is no controller to route with: on the 8259s there are
/// sixteen lines and no way to add one, so a driver asking for a global line
/// is asking for something this machine cannot do.
pub fn vectorForGsi(gsi: u32) ?u8 {
    if (!ioapic.active() or gsi >= MAX_GSI) return null;
    if (gsi_vector[gsi] != 0) return gsi_vector[gsi];

    // Reached only for a line beyond what boot routed, which on this
    // controller is none: every input is routed before anything runs.
    const vector = DEVICE_VECTOR_BASE + @as(u8, @intCast(gsi));
    ioapic.route(gsi, vector, gsi >= irq_mod.MAX_LINES, true, lapic.id());
    gsi_vector[gsi] = vector;
    return vector;
}

/// Whether something has already claimed the line.
pub fn gsiClaimed(gsi: u32) bool {
    const vector = if (gsi < MAX_GSI and gsi_vector[gsi] != 0) gsi_vector[gsi] else return false;
    return handlers[vector] != null;
}

/// Take a global line for a handler, or null if something else has it.
pub fn claimGsi(gsi: u32, handler: Handler) ?u8 {
    if (gsiClaimed(gsi)) return null;
    const vector = vectorForGsi(gsi) orelse return null;

    setHandler(vector, handler);
    // No mask write: every routed entry is born masked and stays masked until
    // the first wait arms it, so claiming touches the controller not at all.
    // On this machine the firmware also runs the controller from system
    // management mode, and the less it can notice the better.
    return vector;
}

pub fn releaseGsi(gsi: u32) void {
    setGsiMask(gsi, true);
    if (gsi < MAX_GSI and gsi_vector[gsi] != 0) unsetHandler(gsi_vector[gsi]);
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

/// Mask or unmask a global line. Named apart from `setIrqMask`, which takes a
/// legacy number and resolves it: a driver holding a global line already knows
/// which one it has.
pub fn setGsiMask(gsi: u32, masked: bool) void {
    if (ioapic.active()) ioapic.setMask(gsi, masked);
}

/// A global line's redirection entry, low word, zero without an IOAPIC.
pub fn gsiEntryLow(gsi: u32) u32 {
    if (!ioapic.active()) return 0;
    return ioapic.entryLow(gsi);
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
    var taken: [64]bool = @splat(false);

    for (0..16) |irq| {
        const line = routing.describedLine(@intCast(irq)) orelse continue;
        ioapic.route(line.gsi, vectorFor(irq), line.active_low, line.level, destination);
        if (line.gsi < taken.len) taken[line.gsi] = true;
        if (line.gsi < MAX_GSI) gsi_vector[line.gsi] = vectorFor(irq);
    }

    for (0..16) |irq| {
        if (routing.describedLine(@intCast(irq)) != null) continue;
        if (taken[irq]) continue;
        ioapic.route(@intCast(irq), vectorFor(irq), false, false, destination);
        gsi_vector[irq] = vectorFor(irq);
    }

    // The lines above the legacy sixteen, routed now and never again: these
    // are the PIRQ pins the firmware's routing tables name, level and low as
    // that hardware signals, masked until a driver's first wait. Routed at
    // boot because this machine's firmware co-owns the controller from
    // system management mode and tolerates the boot writing entries while a
    // rewrite at runtime is followed shortly by a trap that never returns.
    var gsi: u32 = 16;
    const pins = @min(ioapic.inputs(), MAX_GSI);
    while (gsi < pins) : (gsi += 1) {
        const vector = DEVICE_VECTOR_BASE + @as(u8, @intCast(gsi));
        ioapic.route(gsi, vector, true, true, destination);
        gsi_vector[gsi] = vector;
    }

    captureBootEntries();
    maskAllPic();
    return true;
}

/// What boot wrote into a line's redirection entry, remembered so a later
/// moment can tell whether the entry it sees is still the one it wrote. The
/// firmware co-owns the controller, and a line whose entry changed since
/// boot is one nobody should write again at runtime.
var boot_entries: [MAX_GSI]u32 = @splat(0);

pub fn bootEntry(gsi: u32) u32 {
    if (gsi >= MAX_GSI or boot_entries[gsi] == 0) return 0;
    return boot_entries[gsi];
}

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

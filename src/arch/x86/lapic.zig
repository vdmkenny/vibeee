//! The local APIC.
//!
//! What acknowledges an interrupt once the IOAPIC is delivering them. The
//! 8259s are acknowledged by writing to a port; the LAPIC by writing to a
//! register in its own memory-mapped page, and the two are not
//! interchangeable: acknowledging the wrong one leaves the line asserted and
//! nothing else is ever delivered.
//!
//! Only what interrupt delivery needs. The LAPIC timer, IPIs and the
//! performance counters are all here in hardware and none of them have a
//! caller on a machine with one core.

const cpu = @import("cpu.zig");
const paging = @import("paging.zig");

const Register = enum(usize) {
    id = 0x020,
    /// Task priority: which interrupts are allowed through at all.
    task_priority = 0x080,
    /// Processor priority: what the hardware is actually gating on now.
    processor_priority = 0x0A0,
    eoi = 0x0B0,
    /// Spurious interrupt vector, whose bit 8 is the software enable.
    spurious = 0x0F0,
    /// Three 256-bit registers, eight dwords each, sixteen bytes apart:
    /// which vectors are in service, which arrived level, which wait.
    in_service = 0x100,
    trigger_mode = 0x180,
    request = 0x200,
};

/// The MSR carrying the base address and the hardware enable.
const APIC_BASE_MSR = 0x1B;
/// The APIC base MSR: the enable bit powers the unit; the rest is its address.
const BaseMsr = packed struct(u64) {
    _0: u11 = 0,
    enabled: bool = false,
    _rest: u52 = 0,
};

/// Delivered when an interrupt is withdrawn between being raised and being
/// taken. Needs a vector even though the handler does nothing, and the low
/// four bits must be set on older parts.
pub const SPURIOUS_VECTOR: u8 = 0xFF;

/// The spurious interrupt vector register, whose enable bit is what actually
/// lets interrupts through. Named fields rather than a shifted constant, so
/// what is being turned on is written down.
const Spurious = packed struct(u32) {
    vector: u8,
    enabled: bool,
    focus_checking_off: bool = false,
    _reserved: u22 = 0,
};

comptime {
    if (@sizeOf(BaseMsr) != 8 or @sizeOf(Spurious) != 4) {
        @compileError("LAPIC register shapes have the wrong width");
    }
    if (@bitOffsetOf(BaseMsr, "enabled") != 11 or
        @bitOffsetOf(Spurious, "enabled") != 8)
    {
        @compileError("LAPIC enable fields are in the wrong bit position");
    }
}

var base: ?[*]volatile u32 = null;

/// A level interrupt handed to userspace cannot be acknowledged at the local
/// APIC until that process has cleared the device. The APIC EOI register is
/// non-specific, so nested deliveries are retired in strict reverse order.
const DeferredEoi = packed struct(u16) {
    vector: u8 = 0,
    acknowledged: bool = false,
    _reserved: u7 = 0,
};

/// One entry per APIC priority class is sufficient: a vector cannot nest under
/// another vector in the same or a lower class.
pub const MAX_DEFERRED = 16;
var deferred: [MAX_DEFERRED]DeferredEoi = @splat(.{});
var deferred_len: usize = 0;

pub fn active() bool {
    return base != null;
}

/// Map the LAPIC and enable it. False if it cannot be reached, in which case
/// the caller stays on the 8259s.
pub fn init(phys: u32) bool {
    if (phys == 0) return false;

    const virt = paging.mapMmio(phys, 0x1000, .uncached) catch return false;
    base = @ptrFromInt(virt);

    // The firmware normally leaves it enabled, but a machine that came out of
    // a mode where it was not would deliver nothing at all.
    var current: BaseMsr = @bitCast(cpu.readMsr(APIC_BASE_MSR));
    if (!current.enabled) {
        current.enabled = true;
        cpu.writeMsr(APIC_BASE_MSR, @bitCast(current));
    }

    // Accept every priority. There is one core and nothing to defer to.
    write(.task_priority, 0);
    // Separate from the enable in the MSR: that one powers the unit, this one
    // lets interrupts through.
    write(.spurious, @bitCast(Spurious{ .vector = SPURIOUS_VECTOR, .enabled = true }));
    return true;
}

pub fn id() u8 {
    return @truncate(read(.id) >> 24);
}

/// Acknowledge the interrupt being handled.
pub fn eoi() void {
    write(.eoi, 0);
}

/// Keep the current vector in service until its userspace owner acknowledges
/// it. Re-entering the same vector before EOI is impossible, but treating an
/// existing entry as idempotent keeps the invariant explicit.
pub fn deferEoi(vector: u8) void {
    const was = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(was);

    for (deferred[0..deferred_len]) |entry| {
        if (entry.vector == vector) return;
    }
    if (deferred_len == deferred.len) {
        @panic("too many nested deferred interrupts");
    }

    deferred[deferred_len] = .{ .vector = vector };
    deferred_len += 1;
}

pub fn isEoiDeferred(vector: u8) bool {
    const was = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(was);

    for (deferred[0..deferred_len]) |entry| {
        if (entry.vector == vector) return true;
    }
    return false;
}

/// True only while this vector still needs an owner to clear its source. An
/// acknowledged lower-priority vector can remain on the stack behind a higher
/// one, but a replacement driver must not mistake that for new work.
pub fn eoiAwaitingAck(vector: u8) bool {
    const was = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(was);

    for (deferred[0..deferred_len]) |entry| {
        if (entry.vector == vector) return !entry.acknowledged;
    }
    return false;
}

/// Mark one deferred vector complete and retire every completed vector now
/// at the top, returning how many were retired and their vectors through
/// `retired`. LAPIC EOI always targets the highest-priority in-service
/// vector, so acknowledging out of order must wait rather than EOI the
/// wrong source; the caller completes each retired vector wherever else
/// completion must be said.
pub fn acknowledgeEoi(vector: u8, retired: *[MAX_DEFERRED]u8) usize {
    const was = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(was);

    for (deferred[0..deferred_len]) |*entry| {
        if (entry.vector != vector) continue;
        entry.acknowledged = true;
        break;
    } else return 0;

    var n: usize = 0;
    while (deferred_len > 0 and deferred[deferred_len - 1].acknowledged) {
        eoi();
        deferred_len -= 1;
        retired[n] = deferred[deferred_len].vector;
        n += 1;
        deferred[deferred_len] = .{};
    }
    return n;
}

/// One 256-bit vector register as the set bits' vector numbers, written
/// into `into`. The answer to "what is the controller holding right now",
/// which no software state can substitute for.
pub fn vectorsOf(register: enum { in_service, trigger_mode, request }, into: []u8) usize {
    const base_reg: Register = switch (register) {
        .in_service => .in_service,
        .trigger_mode => .trigger_mode,
        .request => .request,
    };
    var n: usize = 0;
    for (0..8) |word| {
        const regs = base orelse return 0;
        const bits = regs[(@intFromEnum(base_reg) + word * 0x10) / @sizeOf(u32)];
        for (0..32) |bit| {
            if (bits & (@as(u32, 1) << @intCast(bit)) == 0) continue;
            if (n == into.len) return n;
            into[n] = @intCast(word * 32 + bit);
            n += 1;
        }
    }
    return n;
}

/// The priority the hardware is gating deliveries on right now.
pub fn processorPriority() u32 {
    return read(.processor_priority);
}

fn read(register: Register) u32 {
    const regs = base orelse return 0;
    return regs[@intFromEnum(register) / @sizeOf(u32)];
}

fn write(register: Register, value: u32) void {
    const regs = base orelse return;
    regs[@intFromEnum(register) / @sizeOf(u32)] = value;
}

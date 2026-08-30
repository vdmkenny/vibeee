//! The I/O APIC.
//!
//! Where a device line becomes a vector. The 8259s decide that by their own
//! fixed order and a base offset; this decides it per line, in a redirection
//! table the kernel writes, which is what makes a line's polarity, its trigger
//! mode and its destination something the firmware can describe rather than
//! something the driver has to know.
//!
//! Reached through two registers rather than mapped directly: an index is
//! written to one and the value read or written through the other, which means
//! every access is two writes and none of them can be reordered.

const cpu = @import("cpu.zig");
const irq = @import("../../kernel/irq.zig");
const paging = @import("paging.zig");

/// Where the index and data registers sit in the controller's page.
const REGSEL = 0x00;
const IOWIN = 0x10;

/// Register indices.
const REG_ID = 0x00;
const REG_VERSION = 0x01;
/// The first redirection entry. Each takes two registers.
const REG_REDIRECT = 0x10;

const Mapped = struct {
    info: irq.Controller,
    regs: [*]volatile u32,
};

var controllers: [irq.MAX_CONTROLLERS]Mapped = undefined;
var count: usize = 0;

pub fn active() bool {
    return count > 0;
}

/// How many inputs the controllers actually have, as the highest line any of
/// them answers for plus one.
pub fn inputs() u32 {
    var highest: u32 = 0;
    for (controllers[0..count]) |c| {
        const top = c.info.gsi_base + c.info.inputs;
        if (top > highest) highest = top;
    }
    return highest;
}

/// Map each controller and mask every line it owns.
///
/// Masked rather than left as the firmware had them: what the firmware routed
/// is for the firmware's own use, and a line still enabled from before would
/// deliver into a vector nothing has claimed.
pub fn init(info: *irq.Routing) bool {
    count = 0;

    for (info.list(), 0..) |entry, i| {
        const virt = paging.mapMmio(entry.address, 0x1000, .uncached) catch continue;
        const regs: [*]volatile u32 = @ptrFromInt(virt);

        controllers[count] = .{ .info = entry, .regs = regs };
        // The input count is in the version register's second byte, one less
        // than the number of entries. The table does not carry it.
        const pin_count = ((read(&controllers[count], REG_VERSION) >> 16) & 0xFF) + 1;
        controllers[count].info.inputs = pin_count;
        info.controllers.mutable()[i].inputs = pin_count;

        var line: u32 = 0;
        while (line < pin_count) : (line += 1) {
            writeEntry(&controllers[count], line, .{});
        }

        count += 1;
    }

    return count > 0;
}

/// A redirection entry, laid out as the hardware has it.
///
/// A packed struct rather than shifted constants: the field positions are the
/// declaration, the compiler checks the whole thing adds up to sixty-four
/// bits, and reading one back gives named fields rather than a word to mask
/// apart. C's bitfields cannot be relied on for this; Zig's can.
pub const Delivery = enum(u3) { fixed = 0, lowest = 1, smi = 2, nmi = 4, init = 5, external = 7, _ };

pub const Route = packed struct(u32) {
    vector: u8 = 0,
    delivery: Delivery = .fixed,
    /// Address a set of CPUs rather than one by its APIC id.
    logical: bool = false,
    /// Hardware sets it while a previous one is still on its way. Read only.
    pending: bool = false,
    polarity: irq.Polarity = .high,
    /// Hardware sets it between accepting a level interrupt and being told the
    /// device is done. Read only.
    servicing: bool = false,
    trigger: irq.Trigger = .edge,
    /// Nothing is delivered while this is set.
    masked: bool = true,
    _reserved: u15 = 0,
};

const Redirect = packed struct(u64) {
    route: Route = .{},
    _reserved: u24 = 0,
    /// Which CPU, by APIC id.
    destination: u8 = 0,
};

comptime {
    if (@bitSizeOf(Route) != 32 or @bitSizeOf(Redirect) != 64) {
        @compileError("an IOAPIC redirection entry must be one qword");
    }
    if (@bitOffsetOf(Route, "polarity") != 13 or
        @bitOffsetOf(Route, "trigger") != 15 or
        @bitOffsetOf(Route, "masked") != 16)
    {
        @compileError("IOAPIC route fields do not match the redirection table");
    }
}

/// The index and data registers are one shared pair. An interrupt landing
/// between selecting and accessing runs a handler that selects for itself,
/// and the interrupted access then lands on whatever the handler chose:
/// every sequence below holds interrupts off around the pair.
fn hold() bool {
    return cpu.saveAndDisableInterrupts();
}

const release = cpu.restoreInterrupts;

/// Send a global interrupt to `vector` on `destination`, masked to begin with.
pub fn route(
    gsi: u32,
    vector: u8,
    polarity: irq.Polarity,
    trigger: irq.Trigger,
    destination: u8,
    masked: bool,
) void {
    const owner = find(gsi) orelse return;
    const was = hold();
    defer release(was);
    // Unmasked for almost every line: this machine has exactly one window
    // that tolerates a redirection write, and it is this boot-time one. The
    // firmware's trap answers any later write by never returning. The SCI is
    // the exception and arrives masked, because its gate belongs to the
    // chipset, which opens it only once the firmware handshake is over.
    writeEntry(owner, gsi - owner.info.gsi_base, .{
        .route = .{
            .vector = vector,
            .polarity = polarity,
            .trigger = trigger,
            .masked = masked,
        },
        .destination = destination,
    });
}

/// The low half of a line's redirection entry: vector, delivery mode,
/// polarity, trigger and mask in one word. For the narration around a first
/// unmask, where what the hardware would deliver is the question.
pub fn entryLow(gsi: u32) ?Route {
    const owner = find(gsi) orelse return null;
    const was = hold();
    defer release(was);
    return @bitCast(read(owner, REG_REDIRECT + (gsi - owner.info.gsi_base) * 2));
}

/// The controller's version byte, for the boot narration: which completion
/// protocols exist at all is decided by it.
pub fn version() u32 {
    if (count == 0) return 0;
    const was = hold();
    defer release(was);
    return read(&controllers[0], REG_VERSION) & 0xFF;
}

pub fn setMask(gsi: u32, masked: bool) void {
    const owner = find(gsi) orelse return;
    const line = gsi - owner.info.gsi_base;

    const was = hold();
    defer release(was);
    var entry = readEntry(owner, line);
    if (entry.route.masked == masked) return;

    // A mask already in the wanted state is left alone. The write is the one
    // thing a shared controller notices, and firmware that also owns this
    // machine notices more than the value.
    entry.route.masked = masked;
    writeEntry(owner, line, entry);
}

/// Unmask only the exact route boot installed. Firmware co-owns this register
/// file; if it has rewritten an entry, preserving its value is safer than
/// asserting ownership with another runtime write.
pub fn unmaskIfMatches(gsi: u32, expected: Route) void {
    const owner = find(gsi) orelse return;
    const line = gsi - owner.info.gsi_base;

    const was = hold();
    defer release(was);
    var entry = readEntry(owner, line);
    if (@as(u32, @bitCast(entry.route)) != @as(u32, @bitCast(expected)) or
        !entry.route.masked) return;
    entry.route.masked = false;
    writeEntry(owner, line, entry);
}

fn find(gsi: u32) ?*Mapped {
    for (controllers[0..count]) |*c| {
        if (gsi >= c.info.gsi_base and gsi < c.info.gsi_base + c.info.inputs) return c;
    }
    return null;
}

/// The high half first, so the destination is in place before the entry
/// becomes usable. Writing the low half last, which carries the mask bit, is
/// what makes that ordering matter.
fn writeEntry(c: *Mapped, line: u32, entry: Redirect) void {
    const bits: u64 = @bitCast(entry);
    const index = REG_REDIRECT + line * 2;

    write(c, index + 1, @truncate(bits >> 32));
    write(c, index, @truncate(bits));
}

fn readEntry(c: *Mapped, line: u32) Redirect {
    const index = REG_REDIRECT + line * 2;
    const low: u64 = read(c, index);
    const high: u64 = read(c, index + 1);
    return @bitCast(low | (high << 32));
}

fn read(c: *Mapped, index: u32) u32 {
    c.regs[REGSEL / 4] = index;
    // 82093AA-class controllers latch on the first window read: it returns
    // the previous register's value, and only the second read is the one
    // that was selected. QEMU answers correctly on the first, which is how
    // a kernel developed under it ships a read that sees garbage on the
    // machine.
    _ = c.regs[IOWIN / 4];
    return c.regs[IOWIN / 4];
}

fn write(c: *Mapped, index: u32, value: u32) void {
    c.regs[REGSEL / 4] = index;
    c.regs[IOWIN / 4] = value;
}

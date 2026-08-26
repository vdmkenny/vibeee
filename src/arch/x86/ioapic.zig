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
        const inputs = ((read(&controllers[count], REG_VERSION) >> 16) & 0xFF) + 1;
        controllers[count].info.inputs = inputs;
        info.controllers[i].inputs = inputs;

        var line: u32 = 0;
        while (line < inputs) : (line += 1) {
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
const Redirect = packed struct(u64) {
    vector: u8 = 0,
    delivery: Delivery = .fixed,
    /// Address a set of CPUs rather than one by its APIC id.
    logical: bool = false,
    /// Hardware sets it while a previous one is still on its way. Read only.
    pending: bool = false,
    active_low: bool = false,
    /// Hardware sets it between accepting a level interrupt and being told the
    /// device is done. Read only.
    servicing: bool = false,
    level: bool = false,
    /// Nothing is delivered while this is set.
    masked: bool = true,
    _reserved: u39 = 0,
    /// Which CPU, by APIC id.
    destination: u8 = 0,

    const Delivery = enum(u3) { fixed = 0, lowest = 1, smi = 2, nmi = 4, init = 5, external = 7 };
};

/// Send a global interrupt to `vector` on `destination`, masked to begin with.
pub fn route(gsi: u32, vector: u8, active_low: bool, level: bool, destination: u8) void {
    const owner = find(gsi) orelse return;
    writeEntry(owner, gsi - owner.info.gsi_base, .{
        .vector = vector,
        .active_low = active_low,
        .level = level,
        .destination = destination,
        .masked = true,
    });
}

pub fn setMask(gsi: u32, masked: bool) void {
    const owner = find(gsi) orelse return;
    const line = gsi - owner.info.gsi_base;

    var entry = readEntry(owner, line);
    entry.masked = masked;
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
    return c.regs[IOWIN / 4];
}

fn write(c: *Mapped, index: u32, value: u32) void {
    c.regs[REGSEL / 4] = index;
    c.regs[IOWIN / 4] = value;
}

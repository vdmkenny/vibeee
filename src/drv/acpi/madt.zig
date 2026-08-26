//! The MADT: where the interrupt controllers are, and how the legacy lines
//! reach them.
//!
//! The one ACPI table the kernel cannot do without. Where the LAPIC and each
//! IOAPIC live is not discoverable any other way, and neither is the mapping
//! from an ISA interrupt number to the global line it actually arrives on:
//! firmware is free to wire the timer to any input it likes, and on most
//! machines it does not wire it to the one with the same number.

const std = @import("std");
const irq = @import("../../kernel/irq.zig");
const tables = @import("tables.zig");

const Madt = extern struct {
    header: tables.Header,
    lapic_address: u32 align(1),
    flags: u32 align(1),
};

const EntryHeader = extern struct {
    kind: u8,
    length: u8,
};

const Kind = enum(u8) {
    local_apic = 0,
    io_apic = 1,
    source_override = 2,
    _,
};

/// Read the MADT, or null if there is none.
pub fn parse() ?irq.Routing {
    const table = tables.find("APIC") orelse return null;
    const madt: *align(1) const Madt = @ptrCast(table);

    var out = irq.Routing{ .local_address = madt.lapic_address };

    // The controller entries follow the two fixed fields.
    const start = @sizeOf(Madt) - @sizeOf(tables.Header);
    const entries = tables.body(table);
    if (start >= entries.len) return out;

    var at: usize = start;
    while (at + @sizeOf(EntryHeader) <= entries.len) {
        const entry: *align(1) const EntryHeader = @ptrCast(&entries[at]);
        // A zero length would leave this walking the same entry forever, which
        // is the one way a malformed table could hang the boot.
        if (entry.length < @sizeOf(EntryHeader)) break;
        if (at + entry.length > entries.len) break;

        const payload = entries[at + @sizeOf(EntryHeader) .. at + entry.length];
        switch (@as(Kind, @enumFromInt(entry.kind))) {
            .io_apic => readIoApic(&out, payload),
            .source_override => readOverride(&out, payload),
            else => {},
        }

        at += entry.length;
    }

    return out;
}

fn readIoApic(out: *irq.Routing, payload: []const u8) void {
    if (payload.len < 10) return;

    out.addController(.{
        .id = payload[0],
        // payload[1] is reserved.
        .address = std.mem.readInt(u32, payload[2..6], .little),
        .gsi_base = std.mem.readInt(u32, payload[6..10], .little),
    });
}

fn readOverride(out: *irq.Routing, payload: []const u8) void {
    if (payload.len < 8) return;

    // payload[0] is the bus, always ISA.
    const flags = std.mem.readInt(u16, payload[6..8], .little);
    out.addLine(.{
        .irq = payload[1],
        .gsi = std.mem.readInt(u32, payload[2..6], .little),
        // Two bits each, where 0 means "whatever the bus does" and the ISA bus
        // is active high and edge triggered.
        .active_low = flags & 0b11 == 0b11,
        .level = (flags >> 2) & 0b11 == 0b11,
    });
}

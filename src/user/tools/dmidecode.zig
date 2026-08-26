//! dmidecode — decode the firmware's DMI/SMBIOS tables.
//!
//! The kernel hands over the raw structure table and this does all the
//! decoding. That split keeps several dozen structure layouts out of kernel
//! memory permanently, for information almost nothing reads more than once.
//!
//! Covers the structure types that say something useful about a machine. Others
//! are listed by type and size rather than skipped, so an unfamiliar table
//! still shows what is in it.

const sys = @import("../syscall.zig");
const out = @import("out.zig");

const Header = extern struct {
    type: u8,
    length: u8,
    handle: u16 align(1),
};

fn typeName(t: u8) []const u8 {
    return switch (t) {
        0 => "BIOS Information",
        1 => "System Information",
        2 => "Base Board Information",
        3 => "Chassis Information",
        4 => "Processor Information",
        7 => "Cache Information",
        8 => "Port Connector",
        9 => "System Slot",
        16 => "Physical Memory Array",
        17 => "Memory Device",
        19 => "Memory Array Mapped Address",
        32 => "System Boot Information",
        127 => "End of Table",
        else => "Other",
    };
}

/// String fields, by structure type and offset into the formatted area.
const StringField = struct { type: u8, offset: u8, label: []const u8 };

const string_fields = [_]StringField{
    .{ .type = 0, .offset = 0x04, .label = "Vendor" },
    .{ .type = 0, .offset = 0x05, .label = "Version" },
    .{ .type = 0, .offset = 0x08, .label = "Release Date" },
    .{ .type = 1, .offset = 0x04, .label = "Manufacturer" },
    .{ .type = 1, .offset = 0x05, .label = "Product Name" },
    .{ .type = 1, .offset = 0x06, .label = "Version" },
    .{ .type = 1, .offset = 0x07, .label = "Serial Number" },
    .{ .type = 2, .offset = 0x04, .label = "Manufacturer" },
    .{ .type = 2, .offset = 0x05, .label = "Product Name" },
    .{ .type = 4, .offset = 0x04, .label = "Socket" },
    .{ .type = 4, .offset = 0x07, .label = "Manufacturer" },
    .{ .type = 4, .offset = 0x10, .label = "Version" },
    .{ .type = 17, .offset = 0x10, .label = "Device Locator" },
    .{ .type = 17, .offset = 0x17, .label = "Manufacturer" },
};

var table: [16384]u8 = undefined;

pub fn run(_: []const []const u8) void {
    const n = sys.sysinfo("smbios", &table);
    if (n <= 0) {
        out.text("dmidecode: no SMBIOS table\n");
        out.flush();
        return;
    }

    const data = table[0..@intCast(n)];
    out.text("SMBIOS structure table, ");
    out.decimal(data.len);
    out.text(" bytes\n\n");

    var offset: usize = 0;
    var count: usize = 0;

    while (offset + @sizeOf(Header) <= data.len) {
        const hdr: *align(1) const Header = @ptrCast(&data[offset]);
        if (hdr.length < @sizeOf(Header)) break;
        if (hdr.type == 127) break;

        count += 1;
        out.text("Handle 0x");
        out.hex(hdr.handle, 4);
        out.text(", Type ");
        out.decimal(hdr.type);
        out.text(" — ");
        out.text(typeName(hdr.type));
        out.text("\n");

        const strings_start = offset + hdr.length;
        for (string_fields) |f| {
            if (f.type != hdr.type or f.offset >= hdr.length) continue;
            const index = data[offset + f.offset];
            const value = nthString(data, strings_start, index) orelse continue;
            if (value.len == 0) continue;
            out.text("    ");
            out.pad(f.label, 16);
            out.text(value);
            out.text("\n");
        }

        // Memory devices carry their size as a number rather than a string, and
        // it is the field anyone actually wants from them.
        if (hdr.type == 17 and hdr.length > 0x0D) {
            const size = @as(u16, data[offset + 0x0C]) | (@as(u16, data[offset + 0x0D]) << 8);
            if (size != 0 and size != 0xFFFF) {
                out.text("    ");
                out.pad("Size", 16);
                // Bit 15 clear means megabytes, set means kilobytes.
                if (size & 0x8000 != 0) {
                    out.decimal(size & 0x7FFF);
                    out.text(" kB\n");
                } else {
                    out.decimal(size);
                    out.text(" MB\n");
                }
            }
        }

        offset = endOfStrings(data, strings_start) orelse break;
    }

    out.text("\n");
    out.decimal(count);
    out.text(" structures decoded\n");
    out.flush();
}

fn nthString(data: []const u8, start: usize, index: u8) ?[]const u8 {
    if (index == 0) return null;
    var pos = start;
    var n: u8 = 1;
    while (pos < data.len) {
        var end = pos;
        while (end < data.len and data[end] != 0) end += 1;
        if (end == pos) return null; // empty entry ends the set
        if (n == index) return data[pos..end];
        n += 1;
        pos = end + 1;
    }
    return null;
}

fn endOfStrings(data: []const u8, start: usize) ?usize {
    var pos = start;
    while (pos + 1 < data.len) {
        if (data[pos] == 0 and data[pos + 1] == 0) return pos + 2;
        pos += 1;
    }
    return null;
}

//! ACPI table discovery.
//!
//! Only what shutdown needs: find the FADT, and find the sleep values inside
//! the DSDT.
//!
//! **This is not an ACPI implementation and must not be mistaken for one.** It
//! reads two tables and pattern-matches a single constant package. Everything
//! else this machine needs from ACPI, battery state, the ASUS010 hotkey
//! methods, backlight via PBLS, the WLDS and CAMS power gates, thermal zones,
//! requires evaluating AML, and the plan for that remains uACPI
//! (design/00-vibeee.md §11). What is here exists so that powering off cleanly
//! does not have to wait for an interpreter.

const std = @import("std");
const console = @import("../../kernel/console.zig");
const hal = @import("../../kernel/hal.zig");

const Header = extern struct {
    signature: [4]u8,
    length: u32 align(1),
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),
};

const Rsdp = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32 align(1),
};

/// Only the fields shutdown uses. The table is much larger; the rest is left to
/// the platform driver.
const Fadt = extern struct {
    header: Header,
    firmware_ctrl: u32 align(1),
    dsdt: u32 align(1),
    reserved: u8,
    preferred_pm_profile: u8,
    sci_int: u16 align(1),
    smi_cmd: u32 align(1),
    acpi_enable: u8,
    acpi_disable: u8,
    s4bios_req: u8,
    pstate_cnt: u8,
    pm1a_evt_blk: u32 align(1),
    pm1b_evt_blk: u32 align(1),
    pm1a_cnt_blk: u32 align(1),
    pm1b_cnt_blk: u32 align(1),
    pm2_cnt_blk: u32 align(1),
    pm_tmr_blk: u32 align(1),
};

pub const Info = struct {
    pm1a_control: u16 = 0,
    pm1b_control: u16 = 0,
    pm_timer: u16 = 0,
    smi_command: u16 = 0,
    acpi_enable: u8 = 0,
    /// Sleep type values for S5, from the DSDT.
    slp_typ_a: u8 = 0,
    slp_typ_b: u8 = 0,
    s5_found: bool = false,
};

var info: Info = .{};
var have_info = false;

pub fn get() ?Info {
    return if (have_info) info else null;
}

fn checksumOk(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum == 0;
}

fn mapTable(phys: u32) ?*align(1) const Header {
    if (phys == 0) return null;
    // ACPI tables live in reserved memory below the top of RAM, which the
    // linear map covers. Anything outside it would be a firmware bug.
    if (!hal.isLinearPhys(phys)) return null;
    return @ptrFromInt(hal.physToVirt(phys));
}

/// Locate the FADT and extract the sleep values from the DSDT.
pub fn init(rsdp_phys: u32) void {
    const rsdp_hdr = mapTable(rsdp_phys) orelse return;
    const rsdp: *align(1) const Rsdp = @ptrCast(rsdp_hdr);
    if (!std.mem.eql(u8, rsdp.signature[0..8], "RSD PTR ")) return;

    const rsdt = mapTable(rsdp.rsdt_address) orelse return;
    if (!std.mem.eql(u8, &rsdt.signature, "RSDT")) return;

    const entries = (rsdt.length -| @sizeOf(Header)) / 4;
    const list: [*]align(1) const u32 = @ptrFromInt(@intFromPtr(rsdt) + @sizeOf(Header));

    for (0..entries) |i| {
        const table = mapTable(list[i]) orelse continue;
        if (!std.mem.eql(u8, &table.signature, "FACP")) continue;

        const fadt: *align(1) const Fadt = @ptrCast(table);
        info.pm1a_control = @truncate(fadt.pm1a_cnt_blk);
        info.pm1b_control = @truncate(fadt.pm1b_cnt_blk);
        info.pm_timer = @truncate(fadt.pm_tmr_blk);
        info.smi_command = @truncate(fadt.smi_cmd);
        info.acpi_enable = fadt.acpi_enable;
        have_info = true;

        findS5(fadt.dsdt);
        return;
    }
}

/// Extract the S5 sleep type values from the DSDT.
///
/// `\_S5_` is an AML package holding the values to write for a soft-off. A full
/// interpreter would evaluate it properly; scanning for the name and decoding
/// the package that follows is the long-established shortcut, and it works on
/// essentially every firmware because the encoding of a constant package has no
/// room for variation.
///
/// If the scan fails, poweroff falls back to the emulator ports and finally to
/// halting, never to writing a guessed value into a power register.
fn findS5(dsdt_phys: u32) void {
    const dsdt = mapTable(dsdt_phys) orelse return;
    if (!std.mem.eql(u8, &dsdt.signature, "DSDT")) return;

    const body: [*]const u8 = @ptrFromInt(@intFromPtr(dsdt) + @sizeOf(Header));
    const len = dsdt.length -| @sizeOf(Header);
    if (len < 8) return;

    const idx = std.mem.indexOf(u8, body[0..len], "_S5_") orelse return;

    var p = idx + 4;
    if (p >= len) return;

    // NameOp may precede; PackageOp (0x12) introduces the values.
    if (body[p] == 0x12) {
        p += 1;
        // Skip the package length, whose top two bits give its own byte count.
        if (p >= len) return;
        const lead = body[p];
        p += 1 + (lead >> 6);
        // Element count.
        if (p >= len) return;
        p += 1;
    } else return;

    const value = struct {
        /// Small integers appear as dedicated opcodes rather than bytes:
        /// ZeroOp and OneOp are values, not prefixes.
        fn read(bytes: [*]const u8, limit: usize, pos: *usize) ?u8 {
            if (pos.* >= limit) return null;
            const op = bytes[pos.*];
            pos.* += 1;
            return switch (op) {
                0x00 => 0,
                0x01 => 1,
                0x0A => blk: {
                    if (pos.* >= limit) break :blk null;
                    const v = bytes[pos.*];
                    pos.* += 1;
                    break :blk v;
                },
                else => null,
            };
        }
    };

    info.slp_typ_a = value.read(body, len, &p) orelse return;
    info.slp_typ_b = value.read(body, len, &p) orelse info.slp_typ_a;
    info.s5_found = true;
}

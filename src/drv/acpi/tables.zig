//! ACPI table discovery.
//!
//! Finding a table by signature, and reading the two that the kernel itself
//! needs: the FADT for shutdown, and the MADT for the interrupt controller.
//!
//! **This is not an ACPI implementation and must not be mistaken for one.** It
//! reads two tables and pattern-matches a single constant package. Everything
//! else this machine needs from ACPI, battery state, the ASUS010 hotkey
//! methods, backlight via PBLS, the WLDS and CAMS power gates, thermal zones,
//! requires evaluating AML, and the plan for that remains uACPI
//! (design/00-vibeee.md §11). What is here exists so that powering off cleanly
//! does not have to wait for an interpreter.

const std = @import("std");
const hal = @import("../../kernel/hal.zig");
const firmware = @import("lib").firmware;
const console = @import("../../kernel/console.zig");

pub const Header = extern struct {
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

/// The table up to the register block lengths, which is as far as shutdown
/// and the no-touch check read. The table is much larger; the rest is left to
/// the platform driver.
///
/// Each legacy block field holds a whole port address. Its length is a
/// separate byte further on, so both are read as the fields they are.
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
    gpe0_blk: u32 align(1),
    gpe1_blk: u32 align(1),
    pm1_evt_len: u8,
    pm1_cnt_len: u8,

    comptime {
        // The offsets the ACPI specification gives the two length bytes.
        std.debug.assert(@offsetOf(Fadt, "pm1_evt_len") == 88);
        std.debug.assert(@offsetOf(Fadt, "pm1_cnt_len") == 89);
    }
};

/// The firmware's own scratch table, the part of it this kernel writes.
///
/// One field matters here: where to jump on waking. Firmware reads it out of
/// memory it kept alive through the sleep, which is the only channel there
/// is between a machine going down and the same machine coming back.
const Facs = extern struct {
    signature: [4]u8,
    length: u32 align(1),
    hardware_signature: u32 align(1),
    firmware_waking_vector: u32 align(1),
    global_lock: u32 align(1),
    flags: u32 align(1),
    /// Where a sixty-four bit operating system would put the same address.
    /// Written as zero: the two are alternatives, and firmware told both
    /// takes the wide one.
    x_firmware_waking_vector: u64 align(1),
};

pub const Info = struct {
    /// The system control interrupt's number, as the FADT names it.
    sci_int: u16 = 0,
    pm1a_control: u16 = 0,
    pm1b_control: u16 = 0,
    pm_timer: u16 = 0,
    smi_command: u16 = 0,
    acpi_enable: u8 = 0,
    /// The power management block's event register pair, for the safety
    /// check that keeps a driver from ever driving something the DSDT placed
    /// inside it. Zero length means the FADT did not say.
    pm1a_event: u16 = 0,
    pm1a_event_len: u8 = 0,
    pm1a_control_len: u8 = 0,
    /// What each sleep state is written as, from the DSDT.
    off: SleepType = .{},
    /// Suspend to memory. A machine whose firmware does not offer it says
    /// so by having no `_S3_` at all, which is what `found` answers.
    suspend_to_memory: SleepType = .{},
    /// Where the firmware keeps the address it jumps to on waking, from
    /// the FADT. Zero on a machine whose tables do not say.
    facs: u32 = 0,
};

/// The two values written into the PM1 control registers to enter one
/// sleep state, and whether the tables named it at all.
pub const SleepType = struct {
    a: u8 = 0,
    b: u8 = 0,
    found: bool = false,
};

var info: Info = .{};
var have_info = false;
var rsdt_phys: u32 = 0;

pub fn get() ?Info {
    return if (have_info) info else null;
}

/// The table with this signature, or null.
///
/// Public because the interrupt controller wants the MADT and shutdown wants
/// the FADT, and a second walk of the RSDT for each would be a second place to
/// get the checksum and the entry count wrong.
pub fn find(signature: []const u8) ?*align(1) const Header {
    const rsdt = mapTable(rsdt_phys) orelse return null;

    const entries = (rsdt.length -| @sizeOf(Header)) / 4;
    const list: [*]align(1) const u32 = @ptrFromInt(@intFromPtr(rsdt) + @sizeOf(Header));

    for (0..entries) |i| {
        const table = mapTable(list[i]) orelse continue;
        if (std.mem.eql(u8, &table.signature, signature)) return table;
    }
    return null;
}

/// The bytes of a table after its header.
pub fn body(table: *align(1) const Header) []const u8 {
    const bytes: [*]const u8 = @ptrFromInt(@intFromPtr(table) + @sizeOf(Header));
    return bytes[0..table.length -| @sizeOf(Header)];
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

    // The one table whose checksum is worth refusing on. Its length decides
    // how many pointers `find` walks, so a corrupt one sends the walk through
    // arbitrary physical memory; the tables it points at are read as their own
    // structs, where firmware getting a checksum wrong is common enough that
    // refusing would cost a working machine its power management.
    const rsdt_bytes: [*]const u8 = @ptrCast(rsdt);
    if (!firmware.checksumOk(rsdt_bytes[0..rsdt.length])) {
        console.warn("acpi: the RSDT does not add up; no tables read", .{});
        return;
    }
    rsdt_phys = rsdp.rsdt_address;

    const facp = find("FACP") orelse return;
    // A table too short to hold the fields read below is not one to read
    // from: every FADT since ACPI 1.0 is longer than this struct, so a
    // shorter one is a firmware fault rather than an older revision.
    if (facp.length < @sizeOf(Fadt)) return;
    const fadt: *align(1) const Fadt = @ptrCast(facp);

    info.pm1a_control = @truncate(fadt.pm1a_cnt_blk);
    info.pm1b_control = @truncate(fadt.pm1b_cnt_blk);
    info.pm_timer = @truncate(fadt.pm_tmr_blk);
    info.smi_command = @truncate(fadt.smi_cmd);
    info.acpi_enable = fadt.acpi_enable;
    info.sci_int = fadt.sci_int;
    // The event and control blocks' base and length, which are what the
    // safety check needs.
    info.pm1a_event = @truncate(fadt.pm1a_evt_blk);
    info.pm1a_event_len = fadt.pm1_evt_len;
    info.pm1a_control_len = fadt.pm1_cnt_len;
    have_info = true;

    info.facs = fadt.firmware_ctrl;
    if (findSleepState(fadt.dsdt, "_S5_")) |found| info.off = found;
    if (findSleepState(fadt.dsdt, "_S3_")) |found| info.suspend_to_memory = found;
}

/// Tell the firmware where to jump when the machine wakes.
///
/// False where there is no such table or it is too short to hold the field,
/// which is a machine that cannot be suspended to memory whatever its DSDT
/// says: without this the firmware wakes and has nowhere to go.
pub fn setWakingVector(phys: u32) bool {
    if (!have_info or info.facs == 0) return false;
    const table = mapTable(info.facs) orelse return false;
    if (!std.mem.eql(u8, &table.signature, "FACS")) return false;

    const facs: *align(1) volatile Facs = @ptrCast(@constCast(table));
    if (facs.length < @sizeOf(Facs)) return false;

    facs.firmware_waking_vector = phys;
    facs.x_firmware_waking_vector = 0;
    return true;
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
/// What one sleep state is written as, found by name in the DSDT.
///
/// Read out of the bytes rather than interpreted. An interpreter is the
/// platform service's and arrives much later than this: what is needed
/// here is two small integers out of a named package, which is a shape
/// simple enough to recognise without running anything. A machine whose
/// tables do not name the state answers nothing, which is how a machine
/// that cannot enter it is told from one that can.
fn findSleepState(dsdt_phys: u32, name: []const u8) ?SleepType {
    const dsdt = mapTable(dsdt_phys) orelse return null;
    if (!std.mem.eql(u8, &dsdt.signature, "DSDT")) return null;

    const aml = body(dsdt);
    if (aml.len < 8) return null;

    const idx = std.mem.indexOf(u8, aml, name) orelse return null;

    var p = idx + name.len;
    if (p >= aml.len) return null;

    // NameOp may precede; PackageOp (0x12) introduces the values.
    if (aml[p] == 0x12) {
        p += 1;
        // Skip the package length, whose top two bits give its own byte count.
        if (p >= aml.len) return null;
        const lead = aml[p];
        p += 1 + (lead >> 6);
        // Element count.
        if (p >= aml.len) return null;
        p += 1;
    } else return null;

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

    const a = value.read(aml.ptr, aml.len, &p) orelse return null;
    const b = value.read(aml.ptr, aml.len, &p) orelse a;
    return .{ .a = a, .b = b, .found = true };
}

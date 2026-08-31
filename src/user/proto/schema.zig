//! The settings schema: every domain there is, and every key in each.
//!
//! Held apart from the service that reads and writes them because a schema
//! is a description and a service is a machine. Nothing here talks to the
//! kernel, which is what lets the documentation generator import it on the
//! host and project it into `docs/settings.md` and the manual: a key
//! cannot be documented as something the system does not have, because
//! both readings come from this file.

const std = @import("std");
const hostname = @import("lib").hostname;
const ifmatch = @import("lib").ifmatch;
const ipv4 = @import("lib").ipv4;
const keymaps = @import("keymaps");
const wifi = @import("lib").wifi;

// ---------------------------------------------------------------------------
// The schema
// ---------------------------------------------------------------------------

/// The desktop's look, which `eui` owns the definitions of. Named here as an
/// enum so the set is closed: a completer can offer it and a dropdown can hold
/// it, neither of which works against an open string.
pub const Theme = enum { slate, classic, paper, dusk };

pub const Bar = enum { top, bottom };

pub const Wm = struct {
    theme: Theme = .slate,
    bar: Bar = .top,
    /// Master's share of the screen as a percentage, so the file holds a whole
    /// number rather than a decimal nobody types consistently.
    master: u7 = 58,

    /// Master's share as the fraction a layout wants, held inside the range
    /// that leaves both sides of the screen usable.
    pub fn masterFraction(self: Wm) f32 {
        const percent: f32 = @floatFromInt(@max(@min(self.master, MASTER_MAX), MASTER_MIN));
        return percent / 100.0;
    }

    pub const MASTER_MIN = 20;
    pub const MASTER_MAX = 80;
};

/// Every domain there is. The field name is the domain's name, which is also
/// its file's name, so neither is written twice.
/// Which keyboard layout the keys mean. The registry's own names, so a value
/// accepted here is one the kernel can be given.
pub const Keymap = keymaps.Name;

pub const Input = struct {
    keymap: Keymap = keymaps.default,
};

/// Network interface configuration, as four slots rather than fixed roles:
/// a machine may carry several wired ports, so each slot names which
/// interface it binds through a matcher, and the most specific claim wins.
/// `if0` matching any ethernet with DHCP is the zero-configuration story;
/// `if1` holds the radio down until a driver exists to raise it. Keys are
/// flat because the store's grammar is `domain.key`; the slot view below
/// rebuilds the grouping.
pub const NET_SLOTS = 4;

/// What the machine is, rather than what one interface is. These keys
/// have no slot prefix because there is one of each per machine.
pub const NetMachine = struct {
    /// The name the machine answers to wherever it has to give one. Unset
    /// takes the name derived from the first interface's own address,
    /// which is stable across boots and different on every machine.
    hostname: hostname.Hostname = .{},
};

pub const NetSlot = struct {
    /// Which interface: "ether", "wifi", a driver name as `net` prints it,
    /// or a bus location like "03:00.0". Empty leaves the slot unused.
    match: ifmatch.Match = .none,
    enabled: bool = false,
    /// Unset asks DHCP; "a.b.c.d/nn" claims the address statically.
    address: ipv4.Cidr = .{},
    gateway: ipv4.Maybe = .{},
    /// Up to two, comma separated. Unset defers to the DHCP offer.
    dns: ipv4.Pair = .{},
    /// The network a radio joins. Unset leaves it idle, which is what a
    /// wired slot always is.
    ssid: wifi.Ssid = .{},
    /// What it joins with: nothing, a passphrase, or the derived key,
    /// which is the one to write into an image somebody may read.
    psk: wifi.Psk = .none,
    /// Which channel plan the radio obeys.
    regdomain: wifi.Regulatory = .conservative,
    /// What it transmits at, when the plan's own ceiling does not reach.
    txpower: wifi.TxPower = .regulatory,
};

pub const Net = NetSchema();

/// The flat field set, generated from the slot shape so the two cannot
/// drift: `if0_match`, `if0_enabled` and so on, one group per slot.
fn NetSchema() type {
    // Every field's name is built at compile time, and there are enough of
    // them now that the default allowance runs out partway through.
    @setEvalBranchQuota(40_000);
    const machine_fields = std.meta.fields(NetMachine);
    const slot_fields = std.meta.fields(NetSlot);
    const total = machine_fields.len + NET_SLOTS * slot_fields.len;
    var names: [total][:0]const u8 = undefined;
    var types: [total]type = undefined;
    var attrs: [total]std.builtin.Type.StructField.Attributes = undefined;

    for (machine_fields, 0..) |field, i| {
        const default: field.type = .{};
        names[i] = field.name;
        types[i] = field.type;
        attrs[i] = .{ .default_value_ptr = &default };
    }

    for (0..NET_SLOTS) |slot| {
        for (slot_fields, 0..) |field, i| {
            const default: field.type = switch (@as(std.meta.FieldEnum(NetSlot), @enumFromInt(i))) {
                .match => switch (slot) {
                    0 => .{ .class = .ether },
                    1 => .{ .class = .wifi },
                    else => .none,
                },
                .enabled => slot == 0,
                // A union has no empty literal, so the cases that are one
                // name the state they start in.
                .psk => .none,
                .regdomain => .conservative,
                .txpower => .regulatory,
                else => .{},
            };
            const at = machine_fields.len + slot * slot_fields.len + i;
            names[at] = std.fmt.comptimePrint("if{d}_{s}", .{ slot, field.name });
            types[at] = field.type;
            attrs[at] = .{ .default_value_ptr = &default };
        }
    }

    const frozen_names = names;
    const frozen_types = types;
    const frozen_attrs = attrs;
    return @Struct(.auto, null, &frozen_names, &frozen_types, &frozen_attrs);
}

/// One slot's fields as one value, so a reader handles every slot with the
/// same code and the flat schema stays a storage detail.
pub fn netSlot(cfg: Net, comptime slot: usize) NetSlot {
    @setEvalBranchQuota(40_000);
    const prefix = std.fmt.comptimePrint("if{d}_", .{slot});
    var out: NetSlot = undefined;
    inline for (std.meta.fields(NetSlot)) |field| {
        @field(out, field.name) = @field(cfg, prefix ++ field.name);
    }
    return out;
}

/// The machine's own keys, which belong to no slot.
pub fn netMachine(cfg: Net) NetMachine {
    var out: NetMachine = undefined;
    inline for (std.meta.fields(NetMachine)) |field| {
        @field(out, field.name) = @field(cfg, field.name);
    }
    return out;
}

/// Write one slot's fields back into the flat schema.
pub fn setNetSlot(cfg: *Net, comptime slot: usize, value: NetSlot) void {
    @setEvalBranchQuota(40_000);
    const prefix = std.fmt.comptimePrint("if{d}_", .{slot});
    inline for (std.meta.fields(NetSlot)) |field| {
        @field(cfg, prefix ++ field.name) = @field(value, field.name);
    }
}

pub const Domains = struct {
    input: Input = .{},
    wm: Wm = .{},
    net: Net = .{},
};

/// Every domain's name, in declaration order. Derived rather than listed,
/// so a domain added above is one this knows about.
pub const DOMAIN_NAMES = names: {
    const fields = std.meta.fields(Domains);
    var out: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, i| out[i] = field.name;
    const frozen = out;
    break :names frozen;
};

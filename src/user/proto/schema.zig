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
const palette = @import("lib").palette;
const str = @import("lib").str;
const ifmatch = @import("lib").ifmatch;
const ipv4 = @import("lib").ipv4;
const keymaps = @import("keymaps");
const rgb = @import("lib").rgb;
const wifi = @import("lib").wifi;

// ---------------------------------------------------------------------------
// The schema
// ---------------------------------------------------------------------------

/// The desktop's look, which `eui` owns the definitions of. Named here as an
/// enum so the set is closed: a completer can offer it and a dropdown can hold
/// it, neither of which works against an open string.
pub const Theme = enum { slate, classic, paper, dusk };

pub const Bar = enum { top, bottom };

/// How long the machine waits before it acts on being left alone.
///
/// A closed set of intervals rather than a number of seconds: what somebody
/// chooses here is "soon" or "not for a while", and offering a free number
/// invites a value nobody meant and a machine that sleeps mid-sentence.
pub const Idle = enum {
    never,
    @"30s",
    @"1m",
    @"5m",
    @"10m",
    @"30m",

    /// The interval in seconds, or null for never.
    pub fn seconds(self: Idle) ?u32 {
        return switch (self) {
            .never => null,
            .@"30s" => 30,
            .@"1m" => 60,
            .@"5m" => 5 * 60,
            .@"10m" => 10 * 60,
            .@"30m" => 30 * 60,
        };
    }
};

/// What to do when the pack is nearly empty.
///
/// A choice made before it happens, which is the only time it can be made:
/// a machine at three per cent has no time to ask. Sleeping is not among
/// them: this machine has no suspend yet, and an answer that did nothing
/// would be worse than a short list.
pub const LowAction = enum { warn, screen_off, shut_down };

/// What keeps the machine going, and what it does when that runs out.
pub const Power = struct {
    /// How long before the panel dims, and how long before the screen goes
    /// off. The two things that decide how long a charge lasts on a machine
    /// whose backlight is most of its draw.
    dim_after: Idle = .@"1m",
    blank_after: Idle = .@"10m",
    /// How dim "dim" is, as a share of the level in use.
    dim_to: u8 = 30,
    /// What to do when the battery reaches `low_at`.
    low_action: LowAction = .shut_down,
    low_at: u8 = 5,
};

pub const Wm = struct {
    theme: Theme = .slate,
    bar: Bar = .top,
    /// The desktop behind everything. Unset takes the theme's own, which is
    /// what makes changing the theme change the wall as well until somebody
    /// says otherwise.
    wallpaper: rgb.Colour = .{},
    /// How large the interface is drawn, as a percentage. The panel is dense
    /// enough that what is comfortable is a matter of eyes rather than of
    /// arithmetic, so it is a setting and the only way to choose it is to
    /// look at the machine.
    scale: u8 = 100,
    /// Master's share of the screen as a percentage, so the file holds a whole
    /// number rather than a decimal nobody types consistently.
    master: u7 = 58,
    /// What the interface highlights with. Named colours rather than three
    /// channels: every one of them is pitched to carry white text, which a
    /// hand-mixed colour would not be.
    accent: palette.Accent = .blue,
    /// What the pointer is drawn in, for a screen where the default is hard
    /// to follow.
    pointer: palette.Pointer = .white,

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

/// Where the machine learns what time it is.
///
/// A netbook of this age has usually lost the battery that kept its clock, so
/// it wakes not knowing the date at all. Everything dated depends on this:
/// a file's timestamp, a lease, and a certificate's validity, which cannot be
/// judged by a machine that thinks it is 1970.
pub const Time = struct {
    /// Whether to ask the network at all. On, because a machine with no
    /// clock and a network is better served by asking than by guessing.
    ntp: bool = true,
    /// Who to ask, in order, until one answers. Names rather than addresses:
    /// the pools move, and a machine that hard-coded an address would ask a
    /// server that has since become somebody's laptop.
    server1: Host = Host.of("0.pool.ntp.org"),
    server2: Host = Host.of("1.pool.ntp.org"),
    server3: Host = Host.of("time.cloudflare.com"),
    /// How often to ask again, in minutes. The clock here is a crystal
    /// counted by software, so it drifts; an hour is often enough to stay
    /// close and rare enough to be no burden on a public pool.
    every_minutes: u16 = 60,
};

/// A server's name, as the file spells it.
pub const Host = struct {
    bytes: [48]u8 = @splat(0),
    len: u8 = 0,

    pub const accepts = "a host name, or empty for none";

    pub fn of(comptime name: []const u8) Host {
        var out = Host{ .len = name.len };
        @memcpy(out.bytes[0..name.len], name);
        return out;
    }

    pub fn slice(self: *const Host) []const u8 {
        return self.bytes[0..@min(self.len, self.bytes.len)];
    }

    pub fn isEmpty(self: Host) bool {
        return self.len == 0;
    }

    pub fn parse(text: []const u8) ?Host {
        const trimmed = str.trim(text);
        if (trimmed.len > 48) return null;
        var out = Host{ .len = @intCast(trimmed.len) };
        @memcpy(out.bytes[0..trimmed.len], trimmed);
        return out;
    }

    pub fn spell(self: Host, into: *str.Builder) void {
        into.text(self.slice());
    }

    pub fn eql(self: Host, other: Host) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

/// The name of a program, as the openers table and the shell know it.
/// Empty means nobody has chosen, and the first program willing to take the
/// family opens it.
pub const Program = struct {
    bytes: [16]u8 = @splat(0),
    len: u8 = 0,

    pub const accepts = "a program's name, or empty for whichever will take it";

    pub fn of(comptime name: []const u8) Program {
        var out = Program{ .len = name.len };
        @memcpy(out.bytes[0..name.len], name);
        return out;
    }

    pub fn slice(self: *const Program) []const u8 {
        return self.bytes[0..@min(self.len, self.bytes.len)];
    }

    pub fn isEmpty(self: Program) bool {
        return self.len == 0;
    }

    pub fn parse(text: []const u8) ?Program {
        const trimmed = str.trim(text);
        if (trimmed.len > 16) return null;
        var out = Program{ .len = @intCast(trimmed.len) };
        @memcpy(out.bytes[0..trimmed.len], trimmed);
        return out;
    }

    pub fn spell(self: Program, into: *str.Builder) void {
        into.text(self.slice());
    }

    pub fn eql(self: Program, other: Program) bool {
        return std.mem.eql(u8, self.slice(), other.slice());
    }
};

/// Which program opens what. One key per family a program can be chosen
/// for; unset means the first that will take it, which is what a machine
/// carrying one viewer wants without being told.
pub const Open = struct {
    picture: Program = .{},
    text: Program = .{},
    audio: Program = .{},
    video: Program = .{},
    archive: Program = .{},
    document: Program = .{},
    font: Program = .{},
};

/// Network interface configuration, as four slots rather than fixed roles:
/// a machine may carry several wired ports, so each slot names which
/// interface it binds through a matcher, and the most specific claim wins.
/// `if0` matching any ethernet with DHCP is the zero-configuration story;
/// `if1` matches the radio and starts enabled, which with no network
/// configured to join means scanning and nothing more. Keys are flat
/// because the store's grammar is `domain.key`; the slot view below
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
    /// Whether traffic with no route of its own should leave by this
    /// interface. A wish rather than a rule: an interface that is down or
    /// has no address cannot carry it, and one that can takes it instead
    /// until this one is able again. Unset on every slot leaves the
    /// machine to choose, which it does in slot order.
    default: bool = false,
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
    /// Hold the radio on one channel instead of sweeping the band.
    ///
    /// Zero sweeps, which is what finding out what is in earshot needs. A
    /// number holds it there, which is for a person who knows where their
    /// network is: a sweep gives each channel a fifth of a second, so a
    /// beacon every tenth of a second is heard once or twice a pass, and
    /// holding still hears them all.
    channel: u8 = 0,
    /// Which channel plan the radio obeys.
    regdomain: wifi.Regulatory = .conservative,
    /// What it transmits at, when the plan's own ceiling does not reach.
    txpower: wifi.TxPower = .regulatory,

    // The changes a person makes to a slot, here once so the command, the
    // Settings pane and the bar's menu give a verb one meaning.

    /// Clear any static claim: DHCP asks.
    pub fn askDhcp(self: *NetSlot) void {
        self.enabled = true;
        self.address = .{};
        self.gateway = .{};
    }

    /// Claim an address; the gateway and the servers may be unset.
    pub fn claimStatic(self: *NetSlot, address: ipv4.Cidr, gateway: ipv4.Maybe, dns: ipv4.Pair) void {
        self.enabled = true;
        self.address = address;
        self.gateway = gateway;
        self.dns = dns;
    }

    /// Join a network: its name, and the secret, which is none for an open
    /// network. The interface is enabled with it.
    pub fn join(self: *NetSlot, ssid: wifi.Ssid, psk: wifi.Psk) void {
        self.enabled = true;
        self.ssid = ssid;
        self.psk = psk;
    }

    /// Forget the network a radio was told to join; the rest stays.
    pub fn forget(self: *NetSlot) void {
        self.ssid = .{};
        self.psk = .none;
    }
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
                // Slot 0 is the wired zero-configuration story; slot 1 is
                // the radio, and starts enabled too now that a driver
                // exists to raise it, scanning being all it does with
                // nothing configured to join. The spares stay off until a
                // machine claims one.
                .enabled => switch (slot) {
                    0, 1 => true,
                    else => false,
                },
                // Sweeping, because a machine that has not been told where
                // its network is has to look for it.
                .channel => 0,
                // Nothing is preferred out of the box: the machine picks,
                // and it picks by slot order, which puts the wired slot
                // first without anyone having to say so.
                .default => false,
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
    power: Power = .{},
    time: Time = .{},
    open: Open = .{},
};

/// The most a settings file may hold.
///
/// Read in one go into a buffer of this size, because a settings service on a
/// machine with this much memory should not stream a file it can hold. What
/// matters is that a file past it loses its tail without saying so, which is
/// a setting that reads as its default and cannot be told from one nobody
/// chose. The build measures the shipped files against this, so a file that
/// grew past it is a build that stops rather than a machine that quietly
/// forgets the end of its own configuration.
pub const FILE_MAX = 4096;

/// Every domain's name, in declaration order. Derived rather than listed,
/// so a domain added above is one this knows about.
pub const DOMAIN_NAMES = names: {
    const fields = std.meta.fields(Domains);
    var out: [fields.len][]const u8 = undefined;
    for (fields, 0..) |field, i| out[i] = field.name;
    const frozen = out;
    break :names frozen;
};

//! What a program asks `platd` for.
//!
//! Everything here goes through the firmware's own methods, which is the whole
//! reason it is a service rather than a syscall: entering a sleep state means
//! evaluating `_PTS` and the `_S5_` package the BIOS shipped, and reading a
//! battery means evaluating `_BST` over the embedded controller. None of that
//! can be worked out from outside, and an interpreter belongs in a process.

const std = @import("std");
const lib = @import("lib");
const sys = @import("sys");

pub const SERVICE = "platform";

pub const Tag = enum(u8) {
    /// Off. The firmware is asked properly, which is what this exists for.
    power_off,
    /// Off and on again.
    reboot,
    /// What the battery is doing, and what it was built as.
    battery,
    /// One device from the firmware's namespace, by position. How a caller
    /// finds out what this machine actually offers.
    device,
    /// The panel's brightness, however this machine offers it.
    backlight,
    /// Set it. `index` carries the level, which is what it is for.
    backlight_set,
    /// The next thing the firmware said a person did, if anything.
    hotkey,
    /// An event handle that fires whenever it says another.
    hotkey_watch,
    /// One name under a named device, by position. What the six columns of
    /// `device` cannot say: a vendor's methods are called whatever the vendor
    /// called them, and nothing can guess at those.
    child,
    /// Where a PCI device's interrupt pin goes, from the firmware's routing
    /// table. `param` carries the question, packed as `RouteAsk`.
    pci_route,
    /// One thermal zone by position: what it reads and the two temperatures
    /// the firmware acts on. `end` past the last.
    thermal,
    /// Whether one of the machine's switchable parts is powered. `param`
    /// carries a `FeatureAsk` naming which.
    feature,
    /// Power it on or off. `param` carries the same, `on` included.
    feature_set,
};

pub const Req = extern struct {
    tag: Tag,
    /// Which one, for the requests that walk a list.
    index: u8 = 0,
    _reserved: [2]u8 = @splat(0),
    /// Whose children to walk, for `child`. Four characters, because that is
    /// what a namespace name is.
    name: [4]u8 = @splat(0),
    /// The request's argument, for the tags that take one.
    param: u32 = 0,
};

/// The routing question: which device, which of its four pins, and, when the
/// device sits behind a bridge, which root-bus bridge carries it. The
/// firmware routes a bridge's children through the bridge's own table.
pub const RouteAsk = packed struct(u32) {
    /// INTA is zero, as the configuration space counts them.
    pin: u2 = 0,
    device: u5 = 0,
    behind_bridge: bool = false,
    bridge_device: u5 = 0,
    bridge_function: u3 = 0,
    _rest: u16 = 0,
};

/// The answer: a global line, wired as the routing tables wire them.
pub const Route = extern struct {
    gsi: u32 = 0,
};

/// A part of the machine whose power a firmware method switches.
///
/// Named by what it is rather than by whose method answers: a laptop of this
/// age powers these down to save a battery, every vendor spells the switch
/// differently, and a caller asking for the wireless should not have to know
/// which. A part this machine cannot switch is answered as absent rather than
/// refused: there is nothing there to say no.
pub const Feature = enum(u8) {
    wireless,
    camera,
    card_reader,
    /// The internal ports, which on a machine of this shape is what the
    /// camera and the card reader are reached through: switching these off
    /// takes everything behind them off the bus with it.
    usb_ports,
    modem,
};

/// Which one, and where it is when the caller knows.
///
/// The place matters because the portable way to switch a device's power is
/// its own node in the firmware's namespace, and what ties a node to a device
/// is the address the node carries. A vendor's own method needs none of this
/// and ignores it.
pub const FeatureAsk = packed struct(u32) {
    which: Feature = .wireless,
    on: bool = false,
    /// Whether `location` says anything. A caller that has never seen the
    /// device cannot name where it is, which is the case a vendor method
    /// answers and a portable one cannot.
    located: bool = false,
    _rest: u6 = 0,
    /// `lib.pci.Location`, packed.
    location: u16 = 0,
};

comptime {
    // The place travels as the number a packed location already is. The
    // location's own width is pinned where it is declared; what is not is
    // the field it travels in, and a field narrowed under it would deliver
    // a different place with nothing in the crossing able to say so.
    if (@bitSizeOf(lib.pci.Location) != @bitSizeOf(@FieldType(FeatureAsk, "location"))) {
        @compileError("a pci location no longer fits the field it travels in");
    }
}

/// What one of them is doing.
pub const FeatureState = extern struct {
    /// Whether this machine offers any way to switch it at all. A machine
    /// that does not is not a machine refusing: there is nothing there, and
    /// a caller should say so rather than report a failure.
    present: u8 = 0,
    on: u8 = 0,
    _reserved: [2]u8 = @splat(0),

    pub fn isPresent(self: FeatureState) bool {
        return self.present != 0;
    }

    pub fn isOn(self: FeatureState) bool {
        return self.on != 0;
    }
};

pub const Status = enum(u8) {
    ok,
    /// The firmware refused, or there is no method for it.
    refused,
    /// Nothing here answers that.
    unknown,
    /// Nothing at that position. How a caller walking a list finds the end.
    end,
};

/// The battery as the firmware describes it.
///
/// Capacities are left in the unit the firmware reports them in rather than
/// converted, because converting milliamp-hours to milliwatt-hours needs a
/// voltage that is itself one of these numbers, and doing it here would lose
/// precision twice and hide which reading was measured.
///
/// A capacity of `UNKNOWN` is the firmware saying it does not know, which is
/// not the same as zero and is worth being able to tell apart.
pub const Battery = extern struct {
    present: u8 = 0,
    /// Capacities are in mAh rather than mWh.
    in_milliamps: u8 = 0,
    charging: u8 = 0,
    discharging: u8 = 0,
    critical: u8 = 0,
    /// The health figure is the firmware's own word, not a ratio this side
    /// derived. Set by the quirk for machines whose `_BIF` says "last full"
    /// as a percentage of design and never revisits it: what that produces is
    /// a reported number, and a caller showing it should say so.
    health_reported: u8 = 0,
    _reserved: [2]u8 = @splat(0),

    /// What it holds now, and how fast that is changing.
    remaining: u32 = 0,
    rate: u32 = 0,
    voltage_mv: u32 = 0,

    /// What it was built to hold, and what it last managed to. The pair that
    /// says how worn it is: nothing else reports wear, it is inferred from
    /// these two and from nothing else.
    design: u32 = 0,
    last_full: u32 = 0,
    design_voltage_mv: u32 = 0,

    /// The thresholds the firmware wants acted on.
    warning: u32 = 0,
    low: u32 = 0,

    pub const UNKNOWN: u32 = 0xFFFF_FFFF;

    /// What the pack is doing, as one thing rather than as three flags.
    ///
    /// The flags are how the ACPI format says it; this is what each
    /// combination means. The derivation itself is `lib.battery`'s, so the
    /// arithmetic is host-tested and shared with every program that draws a
    /// battery; this pair of methods is the wire type's own spelling of it.
    pub const State = lib.battery.State;

    pub fn state(self: Battery) State {
        return lib.battery.state(.{
            .charging = self.charging != 0,
            .discharging = self.discharging != 0,
            .critical = self.critical != 0,
        });
    }

    /// The state in words, one name for every caller that shows it.
    pub fn stateLabel(self: Battery) []const u8 {
        return lib.battery.stateLabel(self.state());
    }

    /// The scale this pack reports in. One pair of units per battery, and
    /// the two names agree within a pack: milliamp-hours with milliamps, or
    /// milliwatt-hours with milliwatts.
    pub fn capacityUnit(self: Battery) []const u8 {
        return if (self.in_milliamps != 0) "mAh" else "mWh";
    }

    /// The unit the change is reported in.
    pub fn currentUnit(self: Battery) []const u8 {
        return if (self.in_milliamps != 0) "mA" else "mW";
    }

    /// How much longer the pack will last, when that is knowable.
    ///
    /// Only while discharging: the rate the firmware reports for a charging
    /// pack is not committed to meaning what a time-to-full would need it to
    /// mean, and a full pack has no estimate to give. Unknown rather than
    /// zero when the firmware cannot say the rate, so a caller can tell "no
    /// answer" from "answer: none left".
    pub const Left = extern struct {
        hours: u16 = 0,
        minutes: u8 = 0,
        _reserved: u8 = 0,
    };

    /// Time left, or null when nothing about it is knowable.
    ///
    /// Capacity over rate, in whichever unit the pair reports: milliamp-hours
    /// over milliamps is hours, and the watt pair is the same shape.
    pub fn runtimeLeft(self: Battery) ?Left {
        if (self.state() != .discharging) return null;
        const left = lib.battery.runtimeLeft(self.remaining, self.rate) orelse return null;
        return .{ .hours = left.hours, .minutes = left.minutes };
    }

    pub fn isPresent(self: Battery) bool {
        return self.present != 0;
    }

    /// Charge as a percentage of what it can currently hold, which is the
    /// number a person means by "how full is it".
    pub fn charge(self: Battery) ?u32 {
        return lib.battery.percent(self.remaining, self.last_full);
    }

    /// What it can hold against what it was built to hold. The one number that
    /// says whether the pack is worn out, and the reason `_BIF` is read at all.
    pub fn health(self: Battery) ?u32 {
        return lib.battery.percent(self.last_full, self.design);
    }
};

/// The methods worth knowing a device has.
///
/// Presence, not behaviour: whether the firmware defines the method. What it
/// does when called is its own business and is not asked here.
pub const Methods = packed struct(u8) {
    /// `_BCL`: the brightness levels this panel accepts.
    brightness_levels: bool = false,
    /// `_BCM`: set one of them.
    brightness_set: bool = false,
    /// `_BQC`: which one is in use.
    brightness_now: bool = false,
    /// `_BIF`: what a battery was built as.
    battery_info: bool = false,
    /// `_BST`: what it is doing.
    battery_state: bool = false,
    /// `_STA`: whether the device is there and switched on.
    power_state: bool = false,
    _reserved: u2 = 0,
};

pub const Device = extern struct {
    /// Four characters, which is all the format has room for.
    name: [4]u8 = @splat(0),
    methods: Methods = .{},
    _reserved: [3]u8 = @splat(0),

    /// The name with the format's padding off: four characters padded with
    /// underscores, and the padding is not part of what anything is called.
    pub fn label(self: *const Device) []const u8 {
        var end = self.name.len;
        while (end > 0 and (self.name[end - 1] == '_' or self.name[end - 1] == 0)) end -= 1;
        return self.name[0..end];
    }
};

/// The panel, as whichever method this machine offers describes it.
/// One thermal zone's reading, in tenths of a degree Celsius.
///
/// Tenths because the firmware answers in tenths of a kelvin and rounding on
/// the way through would throw away the only precision there is. Signed
/// because a machine left in a cold room is not a broken sensor.
pub const Thermal = extern struct {
    name: [8]u8 = @splat(0),
    name_len: u8 = 0,
    _pad: [3]u8 = @splat(0),

    now: i32 = UNKNOWN,
    /// Where the firmware cuts the power, and where it wants something done.
    /// Either may be absent: a zone that names no threshold is a zone the
    /// firmware watches by itself.
    critical: i32 = UNKNOWN,
    passive: i32 = UNKNOWN,

    /// A temperature nobody reported. Not zero, which is a real reading.
    pub const UNKNOWN: i32 = -32768;

    /// How many a machine may have. More than this and the extra go
    /// unreported rather than silently replacing the ones already found.
    pub const MAX_ZONES = 4;

    pub fn named(self: *const Thermal) []const u8 {
        return self.name[0..@min(self.name_len, self.name.len)];
    }

    pub fn known(value: i32) bool {
        return value != UNKNOWN;
    }

    /// Whole degrees, for a caller with one line to say it in.
    pub fn degrees(value: i32) i32 {
        return @divTrunc(value, 10);
    }
};

pub const Backlight = extern struct {
    present: u8 = 0,
    _reserved: [3]u8 = @splat(0),
    /// Where it is, and the highest this machine accepts. Levels rather than a
    /// percentage: the number of steps is the panel's and rounding a
    /// percentage onto them would make some steps unreachable.
    level: u32 = 0,
    max: u32 = 0,

    pub fn isPresent(self: Backlight) bool {
        return self.present != 0;
    }

    /// As a percentage, for showing. Not for setting: a level is what the
    /// hardware takes.
    pub fn percent(self: Backlight) u32 {
        if (self.max == 0) return 0;
        return @intCast(@min(@as(u64, self.level) * 100 / self.max, 100));
    }
};

// ---------------------------------------------------------------------------
// Keys the keyboard never sees
// ---------------------------------------------------------------------------

/// What a person pressed, once the machine's own numbering is off it.
///
/// The top row of a netbook is not wired to the keyboard controller. The
/// embedded controller sees those keys and the firmware raises a notification,
/// so they arrive as ACPI rather than as scancodes and have to be named
/// somewhere. Named by what they mean rather than by which key they sit on:
/// the same meaning is a different key on the next machine.
pub const Hotkey = enum(u8) {
    /// The firmware said something this build has no name for. Its own number
    /// and the device that sent it are in the press, which is the only way a
    /// machine nobody has tried yet can still be read.
    unknown,

    brightness_up,
    brightness_down,
    brightness_cycle,
    brightness_off,
    /// The firmware moved it itself and is saying so afterwards, which is what
    /// the vendor method does: there is nothing to do but notice.
    brightness_changed,

    volume_up,
    volume_down,
    mute,

    wireless,
    touchpad,
    display_switch,
    display_off,
    resolution,
    performance,
    lock,

    power,
    sleep,
    /// The lid moved. Which way it moved is `_LID`, which is a question and
    /// not a key: asking it means calling a method, and nothing reads it yet.
    lid_changed,
    battery_changed,
    mains_changed,

    /// For showing. Here rather than at each caller so the tool and the log
    /// cannot come to call the same key two things.
    pub fn label(self: Hotkey) []const u8 {
        return switch (self) {
            .unknown => "unknown",
            .brightness_up => "brightness up",
            .brightness_down => "brightness down",
            .brightness_cycle => "brightness cycle",
            .brightness_off => "brightness off",
            .brightness_changed => "brightness changed",
            .volume_up => "volume up",
            .volume_down => "volume down",
            .mute => "mute",
            .wireless => "wireless",
            .touchpad => "touchpad",
            .display_switch => "display switch",
            .display_off => "display off",
            .resolution => "resolution",
            .performance => "performance",
            .lock => "lock",
            .power => "power",
            .sleep => "sleep",
            .lid_changed => "lid changed",
            .battery_changed => "battery changed",
            .mains_changed => "mains changed",
        };
    }
};

/// One of them, with what the firmware actually sent still attached.
///
/// The raw value and the device outlive the meaning on purpose. A machine
/// whose numbering nobody has written down yet reports `unknown` for
/// everything, and these two fields are what makes writing it down possible.
pub const Press = extern struct {
    hotkey: Hotkey = .unknown,
    _reserved: [3]u8 = @splat(0),
    value: u32 = 0,
    device: [4]u8 = @splat(0),

    /// The sender with the format's padding off: a namespace name is four
    /// characters padded with underscores. Empty means no device sent it, so
    /// it was one of the chipset's own buttons.
    pub fn sender(self: *const Press) []const u8 {
        var end = self.device.len;
        while (end > 0 and (self.device[end - 1] == '_' or self.device[end - 1] == 0)) end -= 1;
        return self.device[0..end];
    }
};

pub const Rep = extern struct {
    status: Status = .ok,
    _reserved: [3]u8 = @splat(0),
    body: Body = .{ .battery = .{} },
};

/// Exactly one of these, chosen by what was asked.
///
/// A union rather than one field per answer: a reply naming all of them would
/// spend the payload on three empty ones, and the payload is a single message.
pub const Body = extern union {
    battery: Battery,
    thermal: Thermal,
    device: Device,
    backlight: Backlight,
    press: Press,
    route: Route,
    feature: FeatureState,
};

comptime {
    if (@sizeOf(Rep) > sys.MAX_PAYLOAD) {
        @compileError("a platform reply must fit in one channel payload");
    }
}

pub const Error = error{ NoService, Refused, End };

/// The next press, or `error.End` once there are none waiting.
///
/// Collected rather than delivered: a caller waits on the event and then takes
/// what is there, which is the same shape settings changes take and means a
/// caller that was busy finds both keys rather than the later one.
pub fn nextHotkey(into: *Press) Error!void {
    var reply = Rep{};
    try call(.hotkey, &reply);
    into.* = reply.body.press;
}

/// An event that fires whenever the firmware reports another one.
pub fn watchHotkeys() Error!u32 {
    const channel = sys.svcConnect(SERVICE);
    if (channel < 0) return error.NoService;
    defer _ = sys.close(@intCast(channel));

    var request = Req{ .tag = .hotkey_watch };
    const message = sys.Message.init(std.mem.asBytes(&request), &.{});

    var reply = sys.Message{};
    if (sys.callMsg(@intCast(channel), &message, &reply) < 0) return error.Refused;

    const handles = reply.handleSlice();
    if (handles.len == 0) return error.Refused;
    return handles[0];
}

/// Ask, and say whether it was done.
///
/// A power-off that works never returns, so a reply is by itself the news that
/// it did not: the machine is still running to receive one.
pub fn ask(tag: Tag) Error!void {
    var reply = Rep{};
    return call(tag, &reply);
}

/// The same, keeping the answer. What a question rather than an instruction
/// needs.
pub fn call(tag: Tag, into: *Rep) Error!void {
    return callAt(tag, 0, into);
}

pub fn callAt(tag: Tag, index: u8, into: *Rep) Error!void {
    return callUnder(tag, "", index, into);
}

/// The same, naming what to look under.
/// Where a PCI device's interrupt pin goes, per the firmware.
pub fn routePci(question: RouteAsk) Error!u32 {
    var reply = Rep{};
    try callWith(.pci_route, @bitCast(question), &reply);
    return reply.body.route.gsi;
}

/// The same as `call`, carrying an argument word.
pub fn callWith(tag: Tag, param: u32, into: *Rep) Error!void {
    const channel = sys.svcConnect(SERVICE);
    if (channel < 0) return error.NoService;
    defer _ = sys.close(@intCast(channel));

    var request = Req{ .tag = tag, .param = param };
    const message = sys.Message.init(std.mem.asBytes(&request), &.{});

    var reply = sys.Message{};
    if (sys.callMsg(@intCast(channel), &message, &reply) < 0) return error.Refused;

    const bytes = reply.bytes();
    if (bytes.len < @sizeOf(Rep)) return error.Refused;
    into.* = @as(*const Rep, @ptrCast(@alignCast(bytes.ptr))).*;

    return switch (into.status) {
        .ok => {},
        .end => error.End,
        else => error.Refused,
    };
}

pub fn callUnder(tag: Tag, name: []const u8, index: u8, into: *Rep) Error!void {
    const channel = sys.svcConnect(SERVICE);
    if (channel < 0) return error.NoService;
    defer _ = sys.close(@intCast(channel));

    var request = Req{ .tag = tag, .index = index };
    @memcpy(request.name[0..@min(name.len, 4)], name[0..@min(name.len, 4)]);

    const message = sys.Message.init(std.mem.asBytes(&request), &.{});

    var reply = sys.Message{};
    if (sys.callMsg(@intCast(channel), &message, &reply) < 0) return error.Refused;

    const bytes = reply.bytes();
    if (bytes.len < @sizeOf(Rep)) return error.Refused;

    into.* = @as(*const Rep, @ptrCast(@alignCast(bytes.ptr))).*;

    return switch (into.status) {
        .ok => {},
        .end => error.End,
        else => error.Refused,
    };
}

// ---------------------------------------------------------------------------
// What a caller asks about the pack
//
// Spelled out once, beside the sound graph's and the interfaces'. Anything
// that draws a battery needs the same two answers, and a second copy of the
// call is a second thing to keep in step with the service.
// ---------------------------------------------------------------------------

/// What the pack is doing, or null when there is no platform service, no
/// firmware answer, or no battery in the machine.
pub fn battery() ?Battery {
    var reply = Rep{};
    call(.battery, &reply) catch return null;
    if (reply.status != .ok) return null;

    const pack = reply.body.battery;
    return if (pack.present != 0) pack else null;
}

/// The `index`th thermal zone, or null past the last.
pub fn thermal(index: u8) ?Thermal {
    var reply = Rep{};
    callAt(.thermal, index, &reply) catch return null;
    if (reply.status != .ok) return null;
    return reply.body.thermal;
}

/// The hottest zone this machine reports, which is the one a person means by
/// "how hot is it". Null when nothing has a sensor.
pub fn hottest() ?Thermal {
    var best: ?Thermal = null;
    var index: u8 = 0;
    while (index < Thermal.MAX_ZONES) : (index += 1) {
        const zone = thermal(index) orelse break;
        if (!Thermal.known(zone.now)) continue;
        if (best == null or zone.now > best.?.now) best = zone;
    }
    return best;
}

/// The panel's brightness, or null when this machine offers no way to ask.
pub fn backlight() ?Backlight {
    var reply = Rep{};
    call(.backlight, &reply) catch return null;
    if (reply.status != .ok) return null;

    const panel = reply.body.backlight;
    return if (panel.isPresent()) panel else null;
}

/// Set it, and answer with what the firmware settled on rather than what was
/// asked for: a level it clamped is one the caller has to see clamped, or a
/// slider snaps back on the next pass and looks broken.
pub fn setBacklight(level: u32) ?Backlight {
    var reply = Rep{};
    callAt(.backlight_set, @truncate(level), &reply) catch return null;
    if (reply.status != .ok) return null;

    const panel = reply.body.backlight;
    return if (panel.isPresent()) panel else null;
}

/// Whether one of the machine's parts is powered, and whether this machine
/// can say at all.
///
/// `where` is the device's place on the bus for a caller that has seen it,
/// and null for one that has not: a machine whose only way to switch a part
/// is the device's own node cannot find that node without it.
pub fn feature(which: Feature, where: ?lib.pci.Location) FeatureState {
    return featureCall(.feature, which, where, false);
}

/// Switch one, and answer with what it is doing afterwards rather than with
/// what was asked for: a firmware that took the call and did nothing is the
/// failure worth seeing, and reading back is the only way to know.
pub fn setFeature(which: Feature, where: ?lib.pci.Location, on: bool) FeatureState {
    return featureCall(.feature_set, which, where, on);
}

fn featureCall(tag: Tag, which: Feature, where: ?lib.pci.Location, on: bool) FeatureState {
    const question = FeatureAsk{
        .which = which,
        .on = on,
        .located = where != null,
        .location = if (where) |at| @bitCast(at) else 0,
    };

    var reply = Rep{};
    callWith(tag, @bitCast(question), &reply) catch return .{};
    if (reply.status != .ok) return .{};
    return reply.body.feature;
}

/// How full it is, against what it last managed to hold rather than what it
/// was built to: a worn pack at its own full is full, and showing it as
/// eighty per cent for the rest of its life is a number nobody can act on.
///
/// Null when the firmware has not said, which is not the same as empty.
pub fn charge(pack: Battery) ?u32 {
    const whole = if (pack.last_full != 0 and pack.last_full != Battery.UNKNOWN)
        pack.last_full
    else
        pack.design;
    if (whole == 0 or whole == Battery.UNKNOWN) return null;
    if (pack.remaining == Battery.UNKNOWN) return null;
    return lib.battery.percent(pack.remaining, whole);
}

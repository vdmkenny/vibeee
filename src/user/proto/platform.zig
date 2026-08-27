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
};

pub const Req = extern struct {
    tag: Tag,
    /// Which one, for the requests that walk a list.
    index: u8 = 0,
    _reserved: [2]u8 = @splat(0),
    /// Whose children to walk, for `child`. Four characters, because that is
    /// what a namespace name is.
    name: [4]u8 = @splat(0),
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
    device: Device,
    backlight: Backlight,
    press: Press,
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

    into.* = @as(*const Rep, @alignCast(@ptrCast(bytes.ptr))).*;

    return switch (into.status) {
        .ok => {},
        .end => error.End,
        else => error.Refused,
    };
}

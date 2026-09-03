//! Everything ASUS about this machine: the vendor device, the hello it
//! expects, its panel methods and its key numbering.
//!
//! ASUS firmware of this era keeps two roads to every feature: its own, where
//! a hotkey is handled by the BIOS trapping into system management mode, and
//! the operating system's, where the same request is a method the OS
//! evaluates. Which road the bytecode takes is switched by the `INIT` method
//! on the vendor device: until somebody calls it, the firmware behaves as if
//! no operating system were present, and on this machine one of its trap
//! handlers never returns.
//!
//! So `INIT` is called once, before anything else touches the device. The
//! argument names the features whose firmware-side handling the OS takes
//! over; `CMSG` afterwards says which control methods this unit has at all.
//! Both are interface facts read from the vendor's published driver, which is
//! the only place this contract is written down.

const lib = @import("lib");
const Vendor = @import("../vendor.zig").Vendor;
const log = @import("ulib").log;
const out = @import("ulib").out;
const proto = @import("proto").platform;
const uacpi = @import("../uacpi.zig");

/// This maker, as the rest of the service sees it. Everything below is
/// reachable only through here: the row is the whole of what this file
/// offers, and what it offers is what any maker has to.
pub const vendor = Vendor{
    .name = "asus",
    .claims = &claims,
    .node = &node,
    .greet = &greet,
    .press = &press,
    .panel = .{
        .find = &panelDevice,
        .read = &panelLevel,
        .write = &setPanelLevel,
        .levels = PANEL_LEVELS,
    },
    .parts = .{
        .find = &featureDevice,
        .read = &featureState,
        .write = &setFeature,
    },
};

/// The id the firmware registers the device under. Its name in the namespace
/// is the vendor's whim; the id is what they had to fix.
const HID = "ASUS010";

/// What `INIT`'s argument means: each bit hands one feature's firmware-side
/// handling to the operating system.
///
/// Wireless and display switching are taken because that is the value the
/// vendor's own driver has always passed, and this firmware has only ever
/// been tested against it. Both are features this system will drive itself;
/// until it does, their keys arrive as hotkeys and do nothing more.
const Handover = packed struct(u32) {
    wlan: bool = false,
    bluetooth: bool = false,
    irda: bool = false,
    camera: bool = false,
    tv: bool = false,
    gps: bool = false,
    display_switch: bool = false,
    modem: bool = false,
    card_reader: bool = false,
    wwan: bool = false,
    wimax: bool = false,
    hwcf: bool = false,
    _rest: u20 = 0,
};

/// Nothing is taken, on this machine: the handover bits arm the vendor's
/// trap handler, and the trap handlers are what stop returning. The keys
/// stay on the firmware's side, where they do not hang the boot, until each
/// feature is driven for itself and its trap is known safe.
const TAKEN = Handover{};

/// What `CMSG` answers: which of the vendor's fixed feature list this unit
/// has. The list is the vendor's and does not vary; which bits are set does,
/// per model, which is why it is asked rather than assumed.
const Methods = packed struct(u32) {
    wlan: bool = false,
    bluetooth: bool = false,
    irda: bool = false,
    ieee1394: bool = false,
    camera: bool = false,
    tv: bool = false,
    gps: bool = false,
    dvd: bool = false,
    display_switch: bool = false,
    panel_brightness: bool = false,
    bios_flash: bool = false,
    acpi_flash: bool = false,
    cpu_speed: bool = false,
    cpu_temperature: bool = false,
    fan_cpu: bool = false,
    fan_chassis: bool = false,
    usb_port_1: bool = false,
    usb_port_2: bool = false,
    usb_port_3: bool = false,
    modem: bool = false,
    card_reader: bool = false,
    wwan: bool = false,
    wimax: bool = false,
    hwcf: bool = false,
    lid: bool = false,
    kind: bool = false,
    panel_power: bool = false,
    touchpad: bool = false,
    _rest: u4 = 0,
};

/// What the unit said it has, or null while ungreeted or when `CMSG` did not
/// answer. Null means unknown, not absent: some of these firmwares underclaim,
/// so an absent answer is treated as permission to try.
var claimed: ?Methods = null;

fn methods() ?Methods {
    return claimed;
}

var found: ?*uacpi.Node = null;
var looked = false;

/// Whether this machine is one of ours.
///
/// The id first, which no machine of another make registers. Failing that,
/// one of the methods: some units of this line ship the methods and register
/// no device for them, and a panel that only this vendor's firmware knows
/// how to dim is still this vendor's panel. Both are named here because both
/// are this file's knowledge.
fn claims() bool {
    if (node() != null) return true;
    for (SIGNATURES) |method| {
        if (uacpi.firstWith(method) != null) return true;
    }
    return false;
}

/// Methods no other maker has. The panel's setter and the radio's, which are
/// the two this build actually drives.
const SIGNATURES = [_][*:0]const u8{ "PBLS", "WLDS" };

/// The vendor device, found once. Null on every machine that is not one.
fn node() ?*uacpi.Node {
    if (looked) return found;
    looked = true;
    found = uacpi.firstWithHid(HID);
    return found;
}

/// Say hello, once the namespace is up and before anything else asks the
/// device for something.
fn greet() void {
    const device = node() orelse return;

    // The greeting itself writes the vendor's trap port, and this machine's
    // trap handler for it sometimes never returns: SMM owns the CPU from
    // that moment and no OS-side timeout exists. So the greeting is left
    // unperformed for now; the firmware keeps its own handling of the keys
    // and the panel. Restored the day the trap's mood is understood.
    if (!GREET) {
        log.note("platd", "vendor firmware left ungreeted; its trap stays closed");
        return;
    }

    if (!uacpi.callWith(device, "INIT", @as(u32, @bitCast(TAKEN)))) {
        log.warn("platd", "the vendor firmware declined the handshake");
        return;
    }

    // Evaluated before the line is begun: evaluating runs firmware code that
    // may log for itself, and a line held open across it comes out with the
    // firmware's lines inside it.
    var mask: u64 = 0;
    const answered = uacpi.uacpi_eval_simple_integer(device, "CMSG", &mask) == .ok;
    if (answered) claimed = @bitCast(@as(u32, @truncate(mask)));

    // Logged because it differs per model and is otherwise only discoverable
    // by calling methods that may not exist.
    log.begin("platd", .key);
    out.text("vendor firmware greeted");
    if (answered) {
        out.text("; control methods 0x");
        out.hex(@truncate(mask), 4);
    }
    log.end();
}

/// Whether the vendor greeting is performed. Off until the trap stays
/// closed: the machine boots without it, on firmware-side key handling.
const GREET = false;

// ---------------------------------------------------------------------------
// The panel
// ---------------------------------------------------------------------------
//
// `PBLS` sets and `PBLG` reads, following the convention every method on the
// device follows: a feature, then S to set it or G to get it.

/// Sixteen levels, which is what the hardware takes and is not discoverable
/// from the namespace. Written down because the alternative is a caller
/// asking for a hundred and getting whatever the firmware makes of it.
const PANEL_LEVELS = 15;

/// The device answering one of the feature's methods.
///
/// `offered` is whether this unit's stated feature list names this one, and
/// null for a unit that stated nothing at all. A unit that stated its
/// features and did not name this one is believed; one that stated nothing
/// is tried anyway, because some of these firmwares underclaim. `anchor` is
/// a method only a unit with this feature has, which is what a unit with no
/// vendor device of the expected id is found by instead.
fn deviceFor(offered: ?bool, anchor: [*:0]const u8) ?*uacpi.Node {
    if (offered) |named| {
        if (!named) return null;
    }
    return node() orelse uacpi.firstWith(anchor);
}

/// What a getter answers, read as the plain integer every one of these
/// returns.
fn readInteger(device: *uacpi.Node, getter: [*:0]const u8) ?u32 {
    var value: u64 = 0;
    if (uacpi.uacpi_eval_simple_integer(device, getter, &value) != .ok) return null;
    return @truncate(value);
}

fn panelDevice() ?*uacpi.Node {
    return deviceFor(if (methods()) |stated| stated.panel_brightness else null, "PBLS");
}

fn panelLevel(device: *uacpi.Node) ?u32 {
    return readInteger(device, "PBLG");
}

fn setPanelLevel(device: *uacpi.Node, level: u32) bool {
    return uacpi.callWith(device, "PBLS", @min(level, PANEL_LEVELS));
}

// ---------------------------------------------------------------------------
// The parts it switches
// ---------------------------------------------------------------------------
//
// Every one of these is a pair of methods on the vendor device following the
// convention the panel follows: a feature, then S to set it or G to get it.
// None of them is behind `INIT`: the panel already works without it, on the
// same device, so what `INIT` hands over is which side answers the key, not
// whether these answer at all.

/// What this maker switches for one part: which part it is, the pair of
/// methods that switch it, and the bit under which a unit states it has it.
const Offer = struct {
    part: proto.Feature,
    set: [*:0]const u8,
    get: [*:0]const u8,
    /// Read out of a unit's stated feature list. A vendor's list is its own
    /// shape and the protocol's is ours, so the two are mapped rather than
    /// assumed to line up.
    stated: *const fn (Methods) bool,
};

/// What these machines switch, and nothing else. A part absent from this
/// list is one this maker does not switch, which is the ordinary case: the
/// protocol names what a laptop of this age might have, and no one maker has
/// all of it.
const offers = [_]Offer{
    .{ .part = .wireless, .set = "WLDS", .get = "WLDG", .stated = &statedWlan },
    .{ .part = .camera, .set = "CAMS", .get = "CAMG", .stated = &statedCamera },
    .{ .part = .card_reader, .set = "CRDS", .get = "CRDG", .stated = &statedCardReader },
    // The three ports are switched together by one method, so the first of
    // them standing for all three is what a unit is saying.
    .{ .part = .usb_ports, .set = "USBS", .get = "USBG", .stated = &statedUsbPorts },
    .{ .part = .modem, .set = "MODS", .get = "MODG", .stated = &statedModem },
};

comptime {
    Vendor.checkTable(Offer, &offers);
}

fn offerFor(which: proto.Feature) ?Offer {
    return Vendor.switching(Offer, &offers, which);
}

fn statedWlan(m: Methods) bool {
    return m.wlan;
}
fn statedCamera(m: Methods) bool {
    return m.camera;
}
fn statedCardReader(m: Methods) bool {
    return m.card_reader;
}
fn statedUsbPorts(m: Methods) bool {
    return m.usb_port_1;
}
fn statedModem(m: Methods) bool {
    return m.modem;
}

/// The vendor device, when this unit offers the part at all. The location is
/// the standard way's to use: a vendor method names the part itself.
fn featureDevice(which: proto.Feature, _: ?lib.pci.Location) ?*uacpi.Node {
    const offer = offerFor(which) orelse return null;
    return deviceFor(
        if (methods()) |stated| offer.stated(stated) else null,
        offer.set,
    );
}

/// What the firmware currently has the part set to, read rather than assumed:
/// this is the whole point of asking before acting on a method nobody here
/// has called before.
fn featureState(which: proto.Feature, device: *uacpi.Node) ?bool {
    const offer = offerFor(which) orelse return null;
    return (readInteger(device, offer.get) orelse return null) != 0;
}

/// Ask for it on or off. What `on` and `off` are worth is the getter's own
/// answer read back after, not assumed here.
fn setFeature(which: proto.Feature, device: *uacpi.Node, on: bool) bool {
    const offer = offerFor(which) orelse return false;
    return uacpi.callWith(device, offer.set, @intFromBool(on));
}

// ---------------------------------------------------------------------------
// The keys
// ---------------------------------------------------------------------------

/// The vendor's own numbering for what a person pressed.
///
/// Not a specification and not derivable from the namespace: what these
/// machines send, which is only knowable by reading it off a running one.
/// Anything absent here arrives as `unknown` carrying its number, which is
/// how the rest of this table gets written.
fn press(value: u64) proto.Hotkey {
    // The brightness keys carry the level the firmware has already moved to
    // in the low nibble, so there is nothing to set and nothing to work out
    // from the direction: the panel is where it says it is.
    if (value >= BRIGHTNESS_FIRST and value <= BRIGHTNESS_LAST) return .brightness_changed;

    return switch (value) {
        0x10, 0x11 => .wireless,
        0x12 => .performance,
        0x13 => .mute,
        0x14 => .volume_down,
        0x15 => .volume_up,
        0x16 => .display_off,
        0x1a => .lock,
        0x1b => .resolution,
        0x30, 0x31, 0x32 => .display_switch,
        0x37 => .touchpad,
        // Not a key. The vendor device is also where this machine says the
        // mains came or went, and a listener that wanted to know has no other
        // way of hearing it: there is no ACPI0003 here.
        0x50, 0x51 => .mains_changed,
        else => .unknown,
    };
}

const BRIGHTNESS_FIRST = 0x20;
const BRIGHTNESS_LAST = 0x2f;

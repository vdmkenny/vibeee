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

const log = @import("ulib").log;
const out = @import("ulib").out;
const proto = @import("proto").platform;
const uacpi = @import("uacpi.zig");

/// The id the firmware registers the device under. Its name in the namespace
/// is the vendor's whim; the id is what they had to fix.
pub const HID = "ASUS010";

/// What `INIT`'s argument means: each bit hands one feature's firmware-side
/// handling to the operating system.
///
/// Wireless and display switching are taken because that is the value the
/// vendor's own driver has always passed, and this firmware has only ever
/// been tested against it. Both are features this system will drive itself;
/// until it does, their keys arrive as hotkeys and do nothing more.
pub const Handover = packed struct(u32) {
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

const TAKEN = Handover{ .wlan = true, .display_switch = true };

/// What `CMSG` answers: which of the vendor's fixed feature list this unit
/// has. The list is the vendor's and does not vary; which bits are set does,
/// per model, which is why it is asked rather than assumed.
pub const Methods = packed struct(u32) {
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

pub fn methods() ?Methods {
    return claimed;
}

var found: ?*uacpi.Node = null;
var looked = false;

/// The vendor device, found once. Null on every machine that is not one.
pub fn node() ?*uacpi.Node {
    if (looked) return found;
    looked = true;
    found = uacpi.firstWithHid(HID);
    return found;
}

/// Say hello, once the namespace is up and before anything else asks the
/// device for something.
pub fn greet() void {
    const device = node() orelse return;

    if (!uacpi.callWith(device, "INIT", @as(u32, @bitCast(TAKEN)))) {
        log.warn("platd", "the vendor firmware declined the handshake");
        return;
    }

    // Logged because it differs per model and is otherwise only discoverable
    // by calling methods that may not exist.
    var mask: u64 = 0;
    log.begin("platd", .key);
    out.text("vendor firmware greeted");
    if (uacpi.uacpi_eval_simple_integer(device, "CMSG", &mask) == .ok) {
        claimed = @bitCast(@as(u32, @truncate(mask)));
        out.text("; control methods 0x");
        out.hex(@truncate(mask), 4);
    }
    log.end();
}

// ---------------------------------------------------------------------------
// The panel
// ---------------------------------------------------------------------------
//
// `PBLS` sets and `PBLG` reads, following the convention every method on the
// device follows: a feature, then S to set it or G to get it.

/// Sixteen levels, which is what the hardware takes and is not discoverable
/// from the namespace. Written down because the alternative is a caller
/// asking for a hundred and getting whatever the firmware makes of it.
pub const PANEL_LEVELS = 15;

/// The device, when this unit both is one and names the panel among its
/// features. A unit that stated its features and did not name the panel is
/// believed; one that stated nothing is tried, because some of these
/// firmwares underclaim.
pub fn panelDevice() ?*uacpi.Node {
    if (methods()) |stated| {
        if (!stated.panel_brightness) return null;
    }
    return node() orelse uacpi.firstWith("PBLS");
}

pub fn panelLevel(device: *uacpi.Node) ?u32 {
    var value: u64 = 0;
    if (uacpi.uacpi_eval_simple_integer(device, "PBLG", &value) != .ok) return null;
    return @truncate(value);
}

pub fn setPanelLevel(device: *uacpi.Node, level: u32) bool {
    return uacpi.callWith(device, "PBLS", @min(level, PANEL_LEVELS));
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
pub fn press(value: u64) proto.Hotkey {
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

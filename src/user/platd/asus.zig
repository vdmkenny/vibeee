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

const info = @import("ulib").info;
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const proto = @import("proto").platform;
const str = @import("ulib").str;
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

/// Whether this machine is one of ours: the vendor device exists, which no
/// machine of another vendor's would say. Everything ASUS in this build
/// hangs off the answer, and the answer is asked once.
pub fn present() bool {
    return node() != null;
}

// ---------------------------------------------------------------------------
// Quirks
// ---------------------------------------------------------------------------
//
// What this vendor's firmware gets wrong, corrected where the reading is
// made. The funnel in `quirks.zig` calls these, so a reader never needs to
// know a machine existed.
//
// Grown over time and by machine: a correction guarded by `present()` and by
// the shape of the data it corrects holds for every model that shares the
// firmware, and the day one of them is found not to, its detection narrows
// here and nothing downstream moves.

/// The DMI product name, for quirks that are about one model rather than the
/// whole vendor. Asked once; empty when the firmware does not say.
///
/// The kernel's `board` is "manufacturer product", and the product is the
/// last token: "ASUSTeK Computer INC. 701" answers "701", which is the word
/// a model gate compares against.
var product: []const u8 = "";
var product_read = false;

pub fn model() []const u8 {
    if (!product_read) {
        product_read = true;
        product = lastWord(info.ask("board", &model_buf));
    }
    return product;
}

/// The last whitespace-separated word of the board's name, which is where
/// the product sits in "manufacturer product".
fn lastWord(text: []const u8) []const u8 {
    var words: [8][]u8 = undefined;
    const n = str.splitWords(text, words[0..]);
    return if (n == 0) "" else words[n - 1];
}

var model_buf: [64]u8 = @splat(0);

/// The Eee PC line's `_BIF`/`_BST` label percentages as capacities: what the
/// table says is "last full capacity 100" means a hundred per cent, standing
/// next to a design capacity the same table honestly states as 5200 mAh
/// (research-quirks), so everything derived from the pair comes out wrong by
/// that factor unless the reading is corrected first.
///
/// The correction scales nothing unless the firmware's own numbers say it
/// must: capacities that look like percentages — no more than a hundred,
/// beside a design capacity that plainly is not one — are the mislabel, and
/// honest numbers pass through exactly as read. That shape is what lets the
/// correction stand unlisted: it holds for every Eee of the family, the 900
/// and 1000 among them, and stays silent on a unit with different firmware.
pub fn correctBattery(into: *proto.Battery) void {
    if (!present()) return;
    if (into.design == 0 or into.design == proto.Battery.UNKNOWN) return;
    if (into.design <= 100) return;

    // Reported as a percentage, kept as a percentage; converted to the real
    // capacity so every consumer downstream does ordinary math. The rate is
    // the firmware's honest one and is not touched.
    if (into.remaining <= 100) into.remaining = lib.battery.percentToCapacity(into.remaining, into.design);
    if (into.last_full <= 100) {
        into.last_full = lib.battery.percentToCapacity(into.last_full, into.design);
        // A "last full" that is a percentage is the firmware's word, and on
        // these DSDTs a word it never revisits: the pack wears out and the
        // number stays what it was. Callers show it as reported.
        into.health_reported = 1;
    }
    if (into.warning <= 100) into.warning = lib.battery.percentToCapacity(into.warning, into.design);
    if (into.low <= 100) into.low = lib.battery.percentToCapacity(into.low, into.design);
}

/// Say hello, once the namespace is up and before anything else asks the
/// device for something.
pub fn greet() void {
    const device = node() orelse return;

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

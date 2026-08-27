//! The vendor's own device, and the hello it expects.
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

    // What this unit can do, as a mask over the vendor's fixed feature list.
    // Logged because it differs per model and is otherwise only discoverable
    // by calling methods that may not exist.
    var methods: u64 = 0;
    log.begin("platd", .key);
    out.text("vendor firmware greeted");
    if (uacpi.uacpi_eval_simple_integer(device, "CMSG", &methods) == .ok) {
        out.text("; control methods 0x");
        out.hex(@truncate(methods), 4);
    }
    log.end();
}

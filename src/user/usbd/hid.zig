//! Keyboards and mice, in the boot protocol every one of them speaks.
//!
//! The reports themselves, and the table between HID's usage numbers and
//! the keys this system names, are in `lib.hid` where they can be tested.
//! What is here is the arrangement: ask the device for the boot protocol,
//! give its interrupt endpoint to the controller to poll, and turn each
//! report that arrives into what changed since the last one.
//!
//! Nothing polls from this side. The controller visits the endpoint in
//! hardware and the device answers with nothing until a key moves, so a
//! keyboard sitting still produces no interrupts and costs no time. When
//! one does arrive, the bus wakes, and this reads what came.

const class = @import("class.zig");
const hc = @import("hc.zig");
const hid = @import("lib").hid;
const log = @import("ulib").log;
const out = @import("ulib").out;
const sys = @import("sys");
const table = @import("ulib").table;
const usb = @import("lib").usb;

pub const name = "hid";

pub const CLASS = usb.Class.human_interface;

/// How many keyboards and mice at once. More than anyone plugs in, fewer
/// than the controller will watch.
pub const MAX_DEVICES = 4;

/// The boot protocol's own report sizes. A device may send fewer bytes
/// than it was asked for, which is what a mouse with no wheel does.
const KEYBOARD_BYTES: u8 = hid.Keys.BYTES;
const MOUSE_BYTES: u8 = 4;

const Device = struct {
    live: bool = false,
    address: u7 = 0,
    interface: u8 = 0,
    kind: hid.BootDevice = .none,
    watch: u8 = 0,
    ops: hc.HcOps = undefined,
    /// What was down last time, which is what makes a report into
    /// keystrokes.
    was: hid.Keys = .{},
    /// Which buttons were held, for telling a click from a movement.
    buttons: hid.MouseButtons = .{},
};

var devices: [MAX_DEVICES]Device = @splat(.{});

pub const ops = class.ClassOps{ .attach = attach, .detach = detach, .woke = woke };
pub const driver = class.ClassDriver{ .name = name, .ops = ops };

pub fn all() []const Device {
    return &devices;
}

// ---------------------------------------------------------------------------
// Coming and going
// ---------------------------------------------------------------------------

fn attach(target: class.Target) bool {
    const kind: hid.BootDevice = @enumFromInt(target.signature.protocol);
    if (kind != .keyboard and kind != .mouse) {
        log.warn(name, "the device speaks no boot protocol this drives");
        return false;
    }

    const view = usb.interfaceFor(
        target.configuration,
        CLASS,
        hid.SUBCLASS_BOOT,
        target.signature.protocol,
    ) orelse {
        log.warn(name, "the device carries no boot interface");
        return false;
    };
    const endpoint = view.find(.interrupt, .in) orelse {
        log.warn(name, "the device has no endpoint to be polled on");
        return false;
    };

    const slot = table.free(&devices) orelse {
        log.warn(name, "no room for another input device");
        return false;
    };

    // Ask for the boot protocol by name. A device that refuses is one
    // whose reports would have to be parsed from its report descriptor,
    // which is more than this drives.
    target.command(usb.Setup.classRequest(
        .out,
        hid.SET_PROTOCOL,
        @intFromEnum(hid.Protocol.boot),
        view.interface.number,
        0,
    )) catch {
        log.warn(name, "the device would not take the boot protocol");
        return false;
    };

    // Report only when something changes. Without this a keyboard
    // repeats its report forever and every held key is an interrupt
    // several hundred times a second.
    target.command(usb.Setup.classRequest(.out, hid.SET_IDLE, 0, view.interface.number, 0)) catch {};

    const bytes: u8 = if (kind == .keyboard) KEYBOARD_BYTES else MOUSE_BYTES;
    const watch = target.ops.watch(target.pipe(endpoint), bytes) catch {
        log.warn(name, "the controller would not poll the endpoint");
        return false;
    };

    slot.* = .{
        .live = true,
        .address = target.address,
        .interface = view.interface.number,
        .kind = kind,
        .watch = watch,
        .ops = target.ops,
    };

    log.begin(name, .key);
    out.text(if (kind == .keyboard) "a keyboard" else "a mouse");
    out.text(", polled every millisecond");
    log.end();
    return true;
}

fn detach(address: u7) void {
    for (&devices) |*device| {
        if (!device.live or device.address != address) continue;

        // Whatever was held is released: a key that was down when the
        // keyboard was unplugged must not stay down forever.
        release(device);
        device.ops.unwatch(device.watch);
        device.* = .{};
    }
}

// ---------------------------------------------------------------------------
// What arrived
// ---------------------------------------------------------------------------

/// The controller interrupted. Whatever any watched device answered with
/// is here, and there is nothing to do when none of them did.
fn woke() void {
    var report: [hid.Keys.BYTES]u8 = @splat(0);
    for (&devices) |*device| {
        if (!device.live) continue;
        while (device.ops.collect(device.watch, &report)) |moved| {
            if (moved == 0) break;
            switch (device.kind) {
                .keyboard => typed(device, report[0..moved]),
                .mouse => moved_by(device, report[0..moved]),
                else => {},
            }
        }
    }
}

/// One keyboard report becomes the keys that changed since the last one.
fn typed(device: *Device, bytes: []const u8) void {
    const now = hid.Keys.parse(bytes) orelse return;

    var keys: [2 * hid.ROLLOVER + 8]sys.KeyReport = undefined;
    var count: usize = 0;

    var walk = hid.changes(device.was, now);
    while (walk.next()) |change| {
        const code = hid.keyFor(change.usage);
        if (code == .none) continue;
        if (count >= keys.len) break;
        keys[count] = .{ .code = code, .pressed = @intFromBool(change.pressed) };
        count += 1;
    }

    // An overflowed report changes nothing, and `changes` says so by
    // walking against the old report; the old report is what stands.
    if (!now.overflowed()) device.was = now;
    if (count != 0) _ = sys.keyPost(keys[0..count]);
}

/// One mouse report becomes one movement. Sent even when nothing moved if
/// a button changed, because a click without motion is still a click.
fn moved_by(device: *Device, bytes: []const u8) void {
    const motion = hid.Motion.parse(bytes) orelse return;

    const before = device.buttons;
    device.buttons = motion.buttons;
    const changed = @as(u8, @bitCast(before)) != @as(u8, @bitCast(motion.buttons));
    if (!changed and !motion.moved()) return;

    const report = sys.PointerReport{
        .dx = motion.dx,
        // Both count the same way: a mouse pushed away from the hand
        // reports negative, and the pointer goes up the screen.
        .dy = motion.dy,
        .wheel = motion.wheel,
        .buttons = .{
            .left = motion.buttons.left,
            .right = motion.buttons.right,
            .middle = motion.buttons.middle,
        },
        .buttons_changed = @intFromBool(changed),
    };
    _ = sys.pointerPost(&.{report});
}

/// Let go of everything a device was holding, because it is gone.
fn release(device: *Device) void {
    if (device.kind != .keyboard) return;

    var keys: [hid.ROLLOVER + 8]sys.KeyReport = undefined;
    var count: usize = 0;

    var walk = hid.changes(device.was, .{});
    while (walk.next()) |change| {
        const code = hid.keyFor(change.usage);
        if (code == .none or count >= keys.len) continue;
        keys[count] = .{ .code = code, .pressed = 0 };
        count += 1;
    }
    if (count != 0) _ = sys.keyPost(keys[0..count]);
}

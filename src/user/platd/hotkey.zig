//! Keys the keyboard controller never sees.
//!
//! The top row of a netbook is not on the keyboard matrix. Fn+F3 goes to the
//! embedded controller, which tells the firmware, which raises an ACPI
//! notification against one of its own devices. Nothing reaches the keyboard
//! driver at any point, so a system that only reads scancodes has no brightness
//! keys and no way to discover that it is missing them.
//!
//! What a notification means depends on which device sent it. `0x80` from a
//! battery is a state change, from the display device it is an output switch,
//! and from the vendor's own device it is not defined by anything. So the
//! devices worth hearing are found first and the value is read against the one
//! it came from.
//!
//! A handler on the root hears every device including the ones not listed here,
//! and those are queued as `unknown` with their number intact. That is
//! deliberate: this machine's numbering was not knowable in advance either, and
//! the way to learn the next machine's is to watch it say so.

const backlight = @import("backlight.zig");
const log = @import("ulib").log;
const out = @import("ulib").out;
const proto = @import("proto").platform;
const sys = @import("sys");
const uacpi = @import("uacpi.zig");

// ---------------------------------------------------------------------------
// Who is worth hearing
// ---------------------------------------------------------------------------

/// What a device's notifications mean, which is a property of the device and
/// not of the number.
const Kind = enum { vendor, display, power_button, lid, battery, mains };

const Source = struct {
    kind: Kind,
    /// A hardware id where the specification gives one. The display device has
    /// none and is known only by offering the method that dims it.
    hid: ?[*:0]const u8 = null,
    method: ?[*:0]const u8 = null,
};

const sources = [_]Source{
    .{ .kind = .vendor, .hid = "ASUS010" },
    .{ .kind = .display, .method = "_BCM" },
    .{ .kind = .power_button, .hid = "PNP0C0C" },
    .{ .kind = .lid, .hid = "PNP0C0D" },
    .{ .kind = .battery, .hid = "PNP0C0A" },
    .{ .kind = .mains, .hid = "ACPI0003" },
};

/// The node each source turned out to be, found once. Compared by pointer when
/// a notification arrives, so recognising the sender costs no interpreter time
/// in a handler that runs inside uACPI's own dispatch.
var owners: [sources.len]?*uacpi.Node = @splat(null);

/// Start listening, and say who is being listened to.
pub fn listen() void {
    var heard: usize = 0;

    for (sources, 0..) |source, i| {
        owners[i] = if (source.hid) |hid|
            uacpi.firstWithHid(hid)
        else if (source.method) |method|
            uacpi.firstWith(method)
        else
            null;
        if (owners[i] != null) heard += 1;
    }

    const handle = sys.eventCreate();
    if (handle >= 0) event = @intCast(handle);

    // On the root rather than on each of them. A handler there receives every
    // notification, which is what makes a device nobody thought of still
    // audible.
    if (uacpi.uacpi_install_notify_handler(uacpi.namespace_root(), arrived, null) != .ok) {
        log.warn("platd", "no hotkeys; the firmware would not take a notify handler");
        return;
    }

    // The buttons the chipset owns. Not in the namespace on most machines:
    // a power button sets a bit in the power management block and the firmware
    // never describes it, so listening for it is asking by name rather than
    // finding it. Enabled by the act of installing.
    const flags = uacpi.fadtFlags();
    for (buttons) |b| {
        if (flags & b.is_device != 0) continue;
        if (uacpi.uacpi_install_fixed_event_handler(b.event, b.handler, null) == .ok) {
            heard += 1;
        }
    }

    log.begin("platd", if (heard > 0) .key else .warn);
    out.text("hotkeys from ");
    out.decimal(heard);
    out.text(" of ");
    out.decimal(sources.len + buttons.len);
    out.text(" sources");
    log.end();
}

/// A fixed event and what it means. There is no value to read and no device to
/// read it from: the event is the whole message.
const Button = struct {
    event: uacpi.FixedEvent,
    handler: *const fn (?*anyopaque) callconv(.c) u32,
    /// The flag that says this one is a device in the namespace instead, in
    /// which case it is heard through `sources` and asking for a fixed handler
    /// only produces a failure at every boot about a thing that is not wrong.
    is_device: u32,
};

const buttons = [_]Button{
    .{ .event = .power_button, .handler = &powerPressed, .is_device = uacpi.FADT_POWER_BUTTON_IS_DEVICE },
    .{ .event = .sleep_button, .handler = &sleepPressed, .is_device = uacpi.FADT_SLEEP_BUTTON_IS_DEVICE },
};

fn powerPressed(_: ?*anyopaque) callconv(.c) u32 {
    return pressed(.power);
}

fn sleepPressed(_: ?*anyopaque) callconv(.c) u32 {
    return pressed(.sleep);
}

/// Queued and not acted on. What a machine does when the power button is
/// pressed is a decision about the session that is running, and this service
/// knows nothing about sessions: it holds the firmware, not the policy.
fn pressed(which: proto.Hotkey) u32 {
    push(.{ .hotkey = which });
    if (event != 0) _ = sys.eventSignal(event);
    return uacpi.INTERRUPT_HANDLED;
}

// ---------------------------------------------------------------------------
// What a number means
// ---------------------------------------------------------------------------

/// The generic notifications, which are the specification's and mean the same
/// on any machine that raises them at all.
fn meaning(kind: Kind, value: u64) proto.Hotkey {
    return switch (kind) {
        .vendor => vendor(value),
        .display => switch (value) {
            0x80, 0x81, 0x82, 0x83, 0x84 => .display_switch,
            0x85 => .brightness_cycle,
            0x86 => .brightness_up,
            0x87 => .brightness_down,
            0x88 => .brightness_off,
            else => .unknown,
        },
        .power_button => .power,
        .lid => .lid_changed,
        .battery => .battery_changed,
        .mains => .mains_changed,
    };
}

/// The vendor's own numbering.
///
/// Not a specification and not derivable from the namespace: what these
/// machines send, which is only knowable by reading it off a running one.
/// Anything absent here arrives as `unknown` carrying its number, which is how
/// the rest of this table gets written.
fn vendor(value: u64) proto.Hotkey {
    // The brightness keys carry the level the firmware has already moved to in
    // the low nibble, so there is nothing to set and nothing to work out from
    // the direction: the panel is where it says it is.
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

// ---------------------------------------------------------------------------
// Hearing one
// ---------------------------------------------------------------------------

/// Runs inside uACPI's dispatch, so it does as little as a thing can do:
/// recognise the sender, queue what it said, wake whoever was waiting.
///
/// Nothing is evaluated here. Acting on a key means calling a method, and
/// calling a method from inside a notify is asking the interpreter to re-enter
/// itself while it is holding a node it is still walking. What this service
/// owes the panel is counted and paid on the serve loop instead.
fn arrived(_: ?*anyopaque, node: ?*uacpi.Node, value: u64) callconv(.c) uacpi.Status {
    const name = uacpi.namespace_node_name(node);

    var press = proto.Press{ .value = @truncate(value), .device = name.text };
    if (kindOf(node)) |kind| press.hotkey = meaning(kind, value);

    // Only the ones that could not be named. A key that worked is not news,
    // and a number nobody has written down yet is the whole of what a machine
    // this has not met before is able to say.
    if (press.hotkey == .unknown) unnamed(press);

    owe(press.hotkey);
    push(press);

    if (event != 0) _ = sys.eventSignal(event);
    return .ok;
}

fn unnamed(press: proto.Press) void {
    log.begin("platd", .dim);
    out.text(uacpi.trimmed(&press.device));
    out.text(" said 0x");
    out.hex(press.value, 2);
    out.text(", which has no meaning here yet");
    log.end();
}

fn kindOf(node: ?*uacpi.Node) ?Kind {
    for (owners, sources) |owner, source| {
        if (owner != null and owner == node) return source.kind;
    }
    return null;
}

// ---------------------------------------------------------------------------
// What this service owes the panel
// ---------------------------------------------------------------------------

/// Steps the brightness keys have asked for and not yet been given.
///
/// A count rather than a flag, because two presses are two steps and a person
/// holding a key expects to arrive somewhere. Paid on the serve loop, where
/// calling a method is safe.
var owed: i32 = 0;

fn owe(hotkey: proto.Hotkey) void {
    owed += switch (hotkey) {
        .brightness_up => 1,
        .brightness_down => -1,
        else => 0,
    };
}

/// Pay it. Called from the serve loop after the interrupt has been serviced.
///
/// Here rather than published to a subscriber: nothing else can reach the
/// panel, and a brightness key that needs a desktop running to work is a
/// brightness key that does not work.
pub fn apply() void {
    while (owed != 0) {
        const by: i32 = if (owed > 0) 1 else -1;
        owed -= by;
        backlight.step(by);
    }
}

// ---------------------------------------------------------------------------
// Handing them on
// ---------------------------------------------------------------------------

/// One counting event, duplicated to each watcher: a press has to reach
/// everybody listening, and that is what one event with several holders is.
var event: u32 = 0;

/// Presses queued for whoever is listening.
///
/// A ring rather than one slot, because two keys pressed before anyone looks
/// are two keys and the second is not the more interesting one. Small: a
/// listener this far behind has stopped listening, and the oldest press is the
/// one worth dropping.
const DEPTH = 16;
var queued: [DEPTH]proto.Press = undefined;
var first: usize = 0;
var count: usize = 0;

fn push(press: proto.Press) void {
    if (count == DEPTH) {
        first = (first + 1) % DEPTH;
        count -= 1;
    }
    queued[(first + count) % DEPTH] = press;
    count += 1;
}

/// The oldest one waiting, or `end` when there are none.
pub fn take(into: *proto.Press) proto.Status {
    if (count == 0) return .end;

    into.* = queued[first];
    first = (first + 1) % DEPTH;
    count -= 1;
    return .ok;
}

/// Hand back the event, so a caller hears of the next press rather than having
/// to ask whether there was one.
pub fn subscribe(reply: *sys.Message) proto.Status {
    if (event == 0) return .refused;

    // Sending retains rather than consumes, so this stays ours and every
    // watcher ends up holding the same event.
    reply.handles[0] = event;
    reply.handle_count = 1;
    return .ok;
}

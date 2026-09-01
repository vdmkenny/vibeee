//! Input core: keycodes, modifier state, and the event queue.
//!
//! Keycodes identify a *physical key position*, never a symbol. What a key
//! produces is the keymap's business (kernel/keymap.zig), and the separation is
//! what lets the same hardware serve US-International and Belgian AZERTY
//! without the driver knowing either exists.
//!
//! Naming follows the US layout purely as a convention for talking about
//! positions, `.q` is the key where Q sits on a US keyboard, which on AZERTY
//! produces `a`.

const event_mod = @import("event.zig");

/// Layout-independent key identity. Defined in the ABI because a shortcut is
/// bound to a physical key, and the program binding it is on the far side of a
/// syscall from the driver reporting it.
const console = @import("console.zig");
const display = @import("display.zig");
const keymap = @import("keymap.zig");

pub const KeyCode = @import("lib").syscalls.KeyCode;

/// One definition, shared with userspace through the ABI.
pub const Modifiers = @import("lib").syscalls.Modifiers;

pub const Event = struct {
    code: KeyCode,
    pressed: bool,
    mods: Modifiers,
    /// Unicode codepoint, or 0 for a key that produces no character. Filled in
    /// by the keymap layer.
    codepoint: u21 = 0,
};

/// One definition, shared with userspace through the ABI: the driver below and
/// the toolkit above must agree on which bit is which.
pub const Buttons = @import("lib").syscalls.Buttons;

/// What a pointing device reports, after the driver has turned the wire format
/// into something device-independent.
pub const PointerReport = struct {
    dx: i16 = 0,
    dy: i16 = 0,
    /// Positive scrolls up. Zero on a device with no wheel.
    wheel: i8 = 0,
    buttons: Buttons = .{},
    /// Whether this report changed a button, as opposed to only moving.
    buttons_changed: bool = false,
};

/// A pointer event, with the position already accumulated.
///
/// Position as well as delta because every consumer wants the position and
/// only some want the delta, and accumulating it in one place means they
/// cannot disagree about where the pointer is.
pub const PointerEvent = struct {
    x: i16 = 0,
    y: i16 = 0,
    dx: i16 = 0,
    dy: i16 = 0,
    wheel: i8 = 0,
    buttons: Buttons = .{},
    buttons_changed: bool = false,

    /// Motion with a button held: the thing a consumer needs to distinguish
    /// from a click and from a hover, and the reason button state travels on
    /// every event rather than being polled separately.
    pub fn isDrag(self: PointerEvent) bool {
        return !self.buttons_changed and self.buttons.any() and (self.dx != 0 or self.dy != 0);
    }
};

/// Event ring. Sized so a burst of typing during a slow operation is not lost,
/// but small enough that stale input cannot pile up unboundedly.
const QUEUE_SIZE = 64;

var queue: [QUEUE_SIZE]Event = undefined;
var head: usize = 0;
var tail: usize = 0;
var dropped: u32 = 0;

var mods: Modifiers = .{};

pub fn modifiers() Modifiers {
    return mods;
}

/// Update modifier state from a key transition. Called by the driver before
/// the event is posted, so the event carries the state including itself.
pub fn applyModifier(code: KeyCode, pressed: bool) void {
    switch (code) {
        .shift_left, .shift_right => mods.shift = pressed,
        .control_left, .control_right => mods.control = pressed,
        .alt_left => mods.alt = pressed,
        .alt_right => mods.altgr = pressed,
        .super_left, .super_right => mods.super = pressed,
        // Locks toggle on press and ignore release.
        .caps_lock => if (pressed) {
            mods.caps_lock = !mods.caps_lock;
        },
        .num_lock => if (pressed) {
            mods.num_lock = !mods.num_lock;
        },
        else => {},
    }
}

/// Set while a process is reading raw key events.
///
/// The keyboard has one stream and two possible consumers: the line discipline
/// turning keys into lines for a shell, and a compositor wanting keycodes and
/// releases. They cannot both take the same keystroke, so ownership is
/// explicit, the same way the display's is.
/// Zero when nobody has claimed it. The claimant is recorded rather than a
/// bare flag so the claim can be dropped when that process exits: a compositor
/// that crashes while holding the keyboard would otherwise leave the shell
/// with no input and no way to report it.
var key_owner: u32 = 0;

/// Take the keyboard, unless somebody else has it.
///
/// Refused rather than granted twice, the same way the display is: two
/// programs cannot both take the same keystroke, and one that overwrote the
/// claim would leave the other reading from the same queue and racing it for
/// every key, then flush what it had not read on the way out. A claimant that
/// exits releases, so the only claim that stands in the way is a live one.
pub fn claimKeys(owner: u32) bool {
    if (key_owner != 0 and key_owner != owner) return false;
    key_owner = owner;
    return true;
}

pub fn releaseKeys() void {
    key_owner = 0;
    raw_head = raw_tail;
}

pub fn keyOwner() u32 {
    return key_owner;
}

/// Raw key events, for the claimant. Presses and releases both, where the line
/// discipline only ever sees presses that produce characters.
var raw_queue: [QUEUE_SIZE]Event = undefined;
var raw_head: usize = 0;
var raw_tail: usize = 0;
var key_event: event_mod.Event = .{};

pub fn keyReady() *event_mod.Event {
    return &key_event;
}

pub fn pollKey() ?Event {
    if (raw_head == raw_tail) return null;
    const e = raw_queue[raw_head];
    raw_head = (raw_head + 1) % QUEUE_SIZE;
    return e;
}

pub fn hasKeyEvents() bool {
    return raw_head != raw_tail;
}

fn postRaw(e: Event) void {
    const next = (raw_tail + 1) % QUEUE_SIZE;
    if (next == raw_head) return;
    raw_queue[raw_tail] = e;
    raw_tail = next;
    key_event.signalLocked();
}

/// Ctrl+C, when nobody has claimed the keyboard: the user asking whatever
/// runs at the console to stop. Signalled here at delivery time rather than
/// from the line discipline's pump, because the process it is aimed at is
/// exactly the one too busy to be reading.
var stop_event: event_mod.Event = .{};

pub fn stopEvent() *event_mod.Event {
    return &stop_event;
}

/// One key, from whichever keyboard: modifiers applied, layout switch
/// honoured, characters produced, and the event posted.
///
/// Every keyboard does exactly this and must do it identically. A key
/// arriving over USB and the same key on the built-in keyboard have to
/// mean the same thing, so what a key *means* is decided here and a
/// driver's only job is to say which key and whether it went down.
pub fn postKey(code: KeyCode, pressed: bool) void {
    if (code == .none) return;

    applyModifier(code, pressed);
    const held = modifiers();

    // Super and space together cycles layouts. Bound by position rather
    // than by symbol, so it stays in the same physical place when the
    // layout changes, which is the whole point of a layout-switch key.
    if (pressed and code == .space and held.super) {
        const layout = keymap.cycleLayout();
        keymap.resetCompose();
        console.field("layout", "{s}", .{layout.name});
        return;
    }

    var event = Event{ .code = code, .pressed = pressed, .mods = held };

    // Only presses produce characters; a release that generated one would
    // double every keystroke.
    if (!pressed or code.isModifier()) {
        post(event);
        return;
    }

    const out = keymap.translate(code, held);
    event.codepoint = out.codepoint;
    post(event);

    // A failed composition yields two characters: the accent that could
    // not combine, then the key that followed it.
    if (out.extra != 0) {
        post(.{ .code = code, .pressed = true, .mods = held, .codepoint = out.extra });
    }
}

pub fn post(event: Event) void {
    if (key_owner != 0) {
        postRaw(event);
        return;
    }

    if (event.pressed and event.codepoint == 3) stop_event.signalLocked();

    const next = (tail + 1) % QUEUE_SIZE;
    if (next == head) {
        // Drop the newest rather than the oldest: losing the end of a burst is
        // less confusing than losing what was typed first.
        dropped += 1;
        return;
    }
    queue[tail] = event;
    tail = next;
}

pub fn poll() ?Event {
    if (head == tail) return null;
    const event = queue[head];
    head = (head + 1) % QUEUE_SIZE;
    return event;
}

pub fn hasEvents() bool {
    return head != tail;
}

pub fn droppedCount() u32 {
    return dropped;
}

// ---------------------------------------------------------------------------
// Pointer
//
// A separate ring from the keyboard's. The line discipline consumes key events
// and would swallow pointer events with them, and a pointer moving during
// typing would otherwise evict what was typed.
// ---------------------------------------------------------------------------

const POINTER_QUEUE_SIZE = 64;

var pointer_queue: [POINTER_QUEUE_SIZE]PointerEvent = @splat(.{});
var pointer_head: usize = 0;
var pointer_tail: usize = 0;
var pointer_dropped: u32 = 0;

var pointer_x: i16 = 0;
var pointer_y: i16 = 0;
var pointer_max_x: i16 = 639;
var pointer_max_y: i16 = 479;

/// The size to bound the pointer by before anything has drawn.
///
/// Kept for the machine that never gets a framebuffer: in text mode the
/// display has no geometry to give, and a pointer free to leave the screen is
/// worse than one confined to an approximation of it. As soon as there is a
/// mode, the display's own answer replaces this.
pub fn setPointerBounds(width: usize, height: usize) void {
    pointer_max_x = @intCast(@min(width, 32767) -| 1);
    pointer_max_y = @intCast(@min(height, 32767) -| 1);
    pointer_x = @divTrunc(pointer_max_x, 2);
    pointer_y = @divTrunc(pointer_max_y, 2);
}

/// Whether the screen has ever answered how large it is. Until it has, the
/// pointer sits where it started rather than in the middle of a box nobody
/// has measured.
var bounds_known = false;

/// How far the pointer may go, asked of the display rather than remembered
/// from boot.
///
/// A number set once at start-up is a number that is wrong after a modeset,
/// and the way that shows is a pointer that cannot reach the right of the
/// screen. The display knows what it is running at; the console answers for
/// a machine whose framebuffer nobody has taken.
fn measureScreen() void {
    const shown = display.describe();
    const width: usize = if (shown.width != 0) shown.width else console.pixelSize().width;
    const height: usize = if (shown.height != 0) shown.height else console.pixelSize().height;
    if (width == 0 or height == 0) return;

    const max_x: i16 = @intCast(@min(width, 32767) -| 1);
    const max_y: i16 = @intCast(@min(height, 32767) -| 1);
    if (bounds_known and max_x == pointer_max_x and max_y == pointer_max_y) return;

    pointer_max_x = max_x;
    pointer_max_y = max_y;

    if (!bounds_known) {
        // The middle of the screen is where a pointer nobody has moved yet
        // belongs: a cursor that starts in the corner reads as a cursor that
        // is stuck there.
        bounds_known = true;
        pointer_x = @divTrunc(max_x, 2);
        pointer_y = @divTrunc(max_y, 2);
    } else {
        // A smaller mode leaves the pointer outside it otherwise.
        pointer_x = clamp(pointer_x, max_x);
        pointer_y = clamp(pointer_y, max_y);
    }
}

/// Accumulate a report into a position and queue the event.
pub fn postPointer(report: PointerReport) void {
    measureScreen();

    pointer_x = clamp(pointer_x + report.dx, pointer_max_x);
    pointer_y = clamp(pointer_y + report.dy, pointer_max_y);

    last_buttons = report.buttons;

    const event = PointerEvent{
        .x = pointer_x,
        .y = pointer_y,
        .dx = report.dx,
        .dy = report.dy,
        .wheel = report.wheel,
        .buttons = report.buttons,
        .buttons_changed = report.buttons_changed,
    };

    const next = (pointer_tail + 1) % POINTER_QUEUE_SIZE;
    if (next == pointer_head) {
        // Motion may be dropped, a button transition may not: losing a press
        // or a release leaves a consumer believing a button is in the state it
        // is not, and a drag that never ends is worse than a jumpy pointer.
        if (!report.buttons_changed) {
            pointer_dropped += 1;
            return;
        }
        pointer_head = (pointer_head + 1) % POINTER_QUEUE_SIZE;
        pointer_dropped += 1;
    }

    pointer_queue[pointer_tail] = event;
    pointer_tail = next;

    // Signalled from the interrupt handler, so interrupts are already off.
    pointer_event.signalLocked();
}

pub fn pollPointer() ?PointerEvent {
    if (pointer_head == pointer_tail) return null;
    const event = pointer_queue[pointer_head];
    pointer_head = (pointer_head + 1) % POINTER_QUEUE_SIZE;
    return event;
}

pub fn hasPointerEvents() bool {
    return pointer_head != pointer_tail;
}

/// Where the pointer is now, for a consumer that wants position without
/// draining the queue.
pub fn pointerPosition() struct { x: i16, y: i16, buttons: Buttons } {
    return .{ .x = pointer_x, .y = pointer_y, .buttons = last_buttons };
}

var last_buttons: Buttons = .{};

/// Signalled whenever a pointer event is queued, so a reader can block instead
/// of polling. Counting, so an event delivered just before a reader arrives is
/// not lost.
var pointer_event: event_mod.Event = .{};

pub fn pointerReady() *event_mod.Event {
    return &pointer_event;
}

fn clamp(value: i32, limit: i16) i16 {
    if (value < 0) return 0;
    if (value > limit) return limit;
    return @intCast(value);
}

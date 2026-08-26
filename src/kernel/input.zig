//! Input core: keycodes, modifier state, and the event queue.
//!
//! Keycodes identify a *physical key position*, never a symbol. What a key
//! produces is the keymap's business (kernel/keymap.zig), and the separation is
//! what lets the same hardware serve US-International and Belgian AZERTY
//! without the driver knowing either exists.
//!
//! Naming follows the US layout purely as a convention for talking about
//! positions — `.q` is the key where Q sits on a US keyboard, which on AZERTY
//! produces `a`.

const std = @import("std");

pub const KeyCode = enum(u8) {
    none = 0,

    escape,
    // Number row, left to right.
    n1, n2, n3, n4, n5, n6, n7, n8, n9, n0,
    minus, equal, backspace,

    tab,
    q, w, e, r, t, y, u, i, o, p,
    bracket_left, bracket_right, enter,

    control_left,
    a, s, d, f, g, h, j, k, l,
    semicolon, apostrophe, grave,

    shift_left, backslash,
    z, x, c, v, b, n, m,
    comma, period, slash, shift_right,

    keypad_asterisk,
    alt_left, space, caps_lock,

    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,

    num_lock, scroll_lock,

    // Keypad.
    kp7, kp8, kp9, kp_minus,
    kp4, kp5, kp6, kp_plus,
    kp1, kp2, kp3, kp0, kp_period,
    kp_enter, kp_slash,

    // Extended (0xE0-prefixed) keys.
    control_right, alt_right,
    home, up, page_up, left, right, end, down, page_down,
    insert, delete,
    super_left, super_right, menu,

    /// The key ISO keyboards have and ANSI ones do not: the extra one beside
    /// the left shift. AZERTY uses it, so it cannot be omitted.
    iso_extra,

    pub fn isModifier(self: KeyCode) bool {
        return switch (self) {
            .shift_left, .shift_right, .control_left, .control_right,
            .alt_left, .alt_right, .super_left, .super_right, .caps_lock,
            => true,
            else => false,
        };
    }
};

pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    /// AltGr, the right Alt key. Distinct from `alt` because layouts use it as
    /// a third symbol level, and Belgian AZERTY depends on it for @ # [ ] { }.
    altgr: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _pad: u1 = 0,

    /// Whether a letter should come out uppercase. Caps Lock and Shift cancel
    /// rather than compound.
    pub fn letterShifted(self: Modifiers) bool {
        return self.shift != self.caps_lock;
    }
};

pub const Event = struct {
    code: KeyCode,
    pressed: bool,
    mods: Modifiers,
    /// Unicode codepoint, or 0 for a key that produces no character. Filled in
    /// by the keymap layer.
    codepoint: u21 = 0,
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

pub fn post(event: Event) void {
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

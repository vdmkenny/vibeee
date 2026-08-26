//! Turning key presses into the bytes a program expects to read.
//!
//! The other half of the emulator. `vt.zig` decides what arriving bytes do to
//! the screen; this decides what a key produces going the other way, which is
//! the part every terminal gets subtly different and every program depends on.
//!
//! Two sources, because the window manager sends two things. A `text` event
//! carries what the layout produced, which is what a character key means; a
//! `key` event carries which physical key it was, which is what an arrow,
//! a function key or a control chord means. Using the wrong one for either is
//! how a terminal ends up sending `Ctrl+Q` on an AZERTY keyboard when the
//! person pressed the key printed `A`.

const std = @import("std");
const abi = @import("lib").syscalls;
const str = @import("lib").str;

const KeyCode = abi.KeyCode;
const Modifiers = abi.Modifiers;

/// Longest sequence any key produces, `CSI 1 ; 5 A` and the like.
pub const MAX = 8;

/// What a key press sends, or an empty slice for one that sends nothing.
///
/// `application` is DECCKM: a full-window program sets it so its arrow keys
/// arrive as `SS3 A` and cannot be confused with a literal `Escape [ A` typed
/// by hand.
pub fn key(code: KeyCode, mods: Modifiers, application: bool, out: []u8) []const u8 {
    var w = Writer{ .buf = out };

    switch (code) {
        .up => w.cursorKey('A', mods, application),
        .down => w.cursorKey('B', mods, application),
        .right => w.cursorKey('C', mods, application),
        .left => w.cursorKey('D', mods, application),
        .home => w.cursorKey('H', mods, application),
        .end => w.cursorKey('F', mods, application),

        .insert => w.tilde(2, mods),
        .delete => w.tilde(3, mods),
        .page_up => w.tilde(5, mods),
        .page_down => w.tilde(6, mods),

        // The first four are `SS3`, the rest are numbered. That split is not a
        // choice: it is what every terminal since the VT220 does and what
        // every terminal database expects.
        .f1 => w.text("\x1BOP"),
        .f2 => w.text("\x1BOQ"),
        .f3 => w.text("\x1BOR"),
        .f4 => w.text("\x1BOS"),
        .f5 => w.tilde(15, mods),
        .f6 => w.tilde(17, mods),
        .f7 => w.tilde(18, mods),
        .f8 => w.tilde(19, mods),
        .f9 => w.tilde(20, mods),
        .f10 => w.tilde(21, mods),
        .f11 => w.tilde(23, mods),
        .f12 => w.tilde(24, mods),

        .enter, .kp_enter => w.byte('\r'),
        // Shift+Tab is a sequence of its own rather than a modified Tab, which
        // is the one exception to the modifier encoding below.
        .tab => if (mods.shift) w.text("\x1B[Z") else w.byte('\t'),
        .escape => w.byte(0x1B),
        // DEL rather than BS. The choice is arbitrary and universal: every
        // terminal database maps the backspace key to 0x7F, and a terminal
        // sending 0x08 gets a shell that cannot delete.
        .backspace => w.byte(0x7F),

        else => {},
    }

    return w.done();
}

/// What a character key sends, given what the layout produced.
///
/// Control chords are decided here rather than from the keycode, so `Ctrl+C`
/// is the key printed `C` whatever the layout puts there.
pub fn text(codepoint: u32, mods: Modifiers, out: []u8) []const u8 {
    var w = Writer{ .buf = out };

    if (mods.control) {
        const control = controlFor(codepoint) orelse return w.done();
        // Alt prefixes with Escape, which is how every terminal sends Meta and
        // how readline and vim expect it.
        if (mods.alt) w.byte(0x1B);
        w.byte(control);
        return w.done();
    }

    if (codepoint < 0x20) return w.done();
    if (mods.alt) w.byte(0x1B);
    w.codepoint(codepoint);
    return w.done();
}

/// The control code a character produces when Ctrl is held.
///
/// The letters are the character with its top bits cleared, which is what the
/// name "control" meant: `Ctrl+A` is 1 because `A` is 65 and 65 mod 32 is 1.
fn controlFor(codepoint: u32) ?u8 {
    return switch (codepoint) {
        'a'...'z' => @intCast(codepoint - 'a' + 1),
        'A'...'Z' => @intCast(codepoint - 'A' + 1),
        '@', ' ' => 0,
        '[' => 0x1B,
        '\\' => 0x1C,
        ']' => 0x1D,
        '^' => 0x1E,
        '_', '-' => 0x1F,
        '?' => 0x7F,
        else => null,
    };
}

/// The modifier parameter terminals encode chords with: 1 plus a bitmask,
/// shift 1, alt 2, ctrl 4. Zero means no modifier and no parameter at all.
fn modifierParam(mods: Modifiers) u8 {
    var bits: u8 = 0;
    if (mods.shift) bits |= 1;
    if (mods.alt) bits |= 2;
    if (mods.control) bits |= 4;
    return if (bits == 0) 0 else bits + 1;
}

const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn byte(self: *Writer, c: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }

    fn text(self: *Writer, s: []const u8) void {
        for (s) |c| self.byte(c);
    }

    fn number(self: *Writer, value: u32) void {
        var buf: [12]u8 = undefined;
        self.text(buf[0..str.decimal(&buf, value)]);
    }

    fn codepoint(self: *Writer, cp: u32) void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(@intCast(cp), &buf) catch return;
        self.text(buf[0..n]);
    }

    /// `CSI final`, or `SS3 final` in application mode, or `CSI 1 ; mod final`
    /// when a modifier is held. A modified cursor key is always `CSI`, because
    /// `SS3` has nowhere to put the parameter.
    fn cursorKey(self: *Writer, final: u8, mods: Modifiers, application: bool) void {
        const param = modifierParam(mods);
        if (param != 0) {
            self.text("\x1B[1;");
            self.number(param);
            self.byte(final);
            return;
        }
        self.text(if (application) "\x1BO" else "\x1B[");
        self.byte(final);
    }

    /// `CSI n ~`, the numbered keys, with the modifier as a second parameter.
    fn tilde(self: *Writer, n: u32, mods: Modifiers) void {
        self.text("\x1B[");
        self.number(n);
        const param = modifierParam(mods);
        if (param != 0) {
            self.byte(';');
            self.number(param);
        }
        self.byte('~');
    }

    fn done(self: *const Writer) []const u8 {
        return self.buf[0..self.len];
    }
};

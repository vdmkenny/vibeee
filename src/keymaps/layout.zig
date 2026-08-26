//! The vocabulary a keyboard layout is written in.
//!
//! Kept separate from the translation engine so a layout file imports only
//! this, adding a layout never means reading the compose machinery.
//!
//! ## Adding a layout
//!
//! 1. Copy an existing file in this directory, e.g. `us_intl.zig`.
//! 2. Fill in `name`, `tag` and the key table.
//! 3. Add one line to `registry.zig`.
//!
//! The table is sparse: list only the keys the layout defines. It is checked at
//! compile time for duplicate keys, so a typo is a build error rather than a key
//! that mysteriously does nothing.

const std = @import("std");
const input = @import("../kernel/input.zig");

pub const KeyCode = input.KeyCode;
pub const Modifiers = input.Modifiers;

/// The four symbol levels a key can produce.
pub const Levels = struct {
    base: u21 = 0,
    shift: u21 = 0,
    altgr: u21 = 0,
    shift_altgr: u21 = 0,
};

/// A dead key produces no character itself; it modifies the next one.
pub const Dead = enum(u8) {
    none = 0,
    acute,
    grave,
    circumflex,
    tilde,
    diaeresis,
    cedilla,
};

pub const Entry = struct {
    levels: Levels = .{},
    /// Set when this key is dead at the corresponding level.
    dead_base: Dead = .none,
    dead_shift: Dead = .none,
    dead_altgr: Dead = .none,
};






/// A layout as written in a layout file: a sparse list of key definitions.
pub const Layout = struct {
    /// Full name, for settings UI.
    name: []const u8,
    /// Two- or three-letter tag for the status bar.
    tag: []const u8,
    keys: []const KeyDef,
};

pub const KeyDef = struct { KeyCode, Entry };

/// Dense lookup built from a sparse layout at comptime.
///
/// Translation runs on every keypress, so it should not be a linear scan, and
/// building the table at comptime is also where duplicate keys get caught.
pub const Compiled = struct {
    name: []const u8,
    tag: []const u8,
    table: [256]Entry,
    defined: [256]bool,

    pub fn lookup(self: *const Compiled, code: KeyCode) ?Entry {
        const i = @intFromEnum(code);
        return if (self.defined[i]) self.table[i] else null;
    }
};

pub fn compile(comptime layout: Layout) Compiled {
    comptime {
        var table: [256]Entry = @splat(.{});
        var defined: [256]bool = @splat(false);

        for (layout.keys) |def| {
            const i = @intFromEnum(def[0]);
            if (defined[i]) @compileError(
                "layout '" ++ layout.name ++ "' defines key '" ++ @tagName(def[0]) ++ "' twice",
            );
            defined[i] = true;
            table[i] = def[1];
        }

        return .{ .name = layout.name, .tag = layout.tag, .table = table, .defined = defined };
    }
}

// ---------------------------------------------------------------------------
// Shorthands for writing key tables
// ---------------------------------------------------------------------------

/// A plain key with base and shifted forms.
pub fn k(base: u21, shift: u21) Entry {
    return .{ .levels = .{ .base = base, .shift = shift } };
}

/// A key with third and fourth levels behind AltGr.
pub fn ka(base: u21, shift: u21, altgr: u21, shift_altgr: u21) Entry {
    return .{ .levels = .{ .base = base, .shift = shift, .altgr = altgr, .shift_altgr = shift_altgr } };
}

/// A letter: base lowercase, shift uppercase. Caps Lock applies to these.
pub fn letter(lower: u21, upper: u21) Entry {
    return .{ .levels = .{ .base = lower, .shift = upper } };
}

/// A dead key: produces nothing itself, modifies the character after it.
pub fn dead(base: Dead, shift: Dead) Entry {
    return .{ .dead_base = base, .dead_shift = shift };
}

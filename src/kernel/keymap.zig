//! Keyboard layouts: keycode plus modifiers to Unicode.
//!
//! Two layouts ship. **US-International** is the default, because that is what
//! gets touch-typed regardless of what the keycaps say. **Belgian AZERTY** is
//! the physical layout of the target machine's keyboard. Both are needed at
//! once, and switching is a hotkey rather than a rebuild.
//!
//! Dead keys and AltGr are not optional extras here, they are load-bearing for
//! both layouts. US-International reaches accented letters by composing `'`,
//! `"`, `` ` ``, `~` and `^` with a following letter, and Belgian AZERTY puts
//! `@ # [ ] { } \ |` behind AltGr, which is most of what programming needs.
//!
//! Compose state lives here, in exactly one place. Every text surface, the
//! terminal, a password field, an editor, therefore behaves identically,
//! which it would not if each widget implemented its own.

const input = @import("input.zig");
const l = @import("../keymaps/layout.zig");
const registry = @import("../keymaps/registry.zig");

const KeyCode = input.KeyCode;
const Modifiers = input.Modifiers;

pub const Dead = l.Dead;
pub const Entry = l.Entry;
pub const Levels = l.Levels;

/// Every layout, compiled to dense lookup tables. Adding one is a file in
/// src/keymaps/ plus a line in its registry, see keymaps/layout.zig.
pub const layouts = &registry.all;

var active: usize = @intFromEnum(registry.default);

pub fn current() *const l.Compiled {
    return &layouts[active];
}

/// Names of every available layout, for a settings list.
pub fn layoutNames(index: usize) ?[]const u8 {
    if (index >= layouts.len) return null;
    return layouts[index].name;
}

pub fn layoutCount() usize {
    return layouts.len;
}

pub fn activeIndex() usize {
    return active;
}

pub fn setLayout(index: usize) void {
    if (index < layouts.len) active = index;
}

/// Cycle to the next layout. Bound to a hotkey so switching does not require
/// finding a settings dialog with the wrong layout active.
pub fn cycleLayout() *const l.Compiled {
    active = (active + 1) % layouts.len;
    return current();
}

// ---------------------------------------------------------------------------
// Dead-key composition
// ---------------------------------------------------------------------------

var pending: Dead = .none;

/// Combining table. Only the pairs both shipped layouts can actually produce.
const Composition = struct { Dead, u21, u21 };

const compositions = [_]Composition{
    .{ .acute, 'a', 0xE1 },      .{ .acute, 'e', 0xE9 },      .{ .acute, 'i', 0xED },
    .{ .acute, 'o', 0xF3 },      .{ .acute, 'u', 0xFA },      .{ .acute, 'y', 0xFD },
    .{ .acute, 'c', 0x107 },     .{ .acute, 'n', 0x144 },     .{ .acute, 's', 0x15B },
    .{ .acute, 'A', 0xC1 },      .{ .acute, 'E', 0xC9 },      .{ .acute, 'I', 0xCD },
    .{ .acute, 'O', 0xD3 },      .{ .acute, 'U', 0xDA },      .{ .acute, 'Y', 0xDD },

    .{ .grave, 'a', 0xE0 },      .{ .grave, 'e', 0xE8 },      .{ .grave, 'i', 0xEC },
    .{ .grave, 'o', 0xF2 },      .{ .grave, 'u', 0xF9 },      .{ .grave, 'A', 0xC0 },
    .{ .grave, 'E', 0xC8 },      .{ .grave, 'I', 0xCC },      .{ .grave, 'O', 0xD2 },
    .{ .grave, 'U', 0xD9 },      .{ .circumflex, 'a', 0xE2 }, .{ .circumflex, 'e', 0xEA },
    .{ .circumflex, 'i', 0xEE }, .{ .circumflex, 'o', 0xF4 }, .{ .circumflex, 'u', 0xFB },
    .{ .circumflex, 'A', 0xC2 }, .{ .circumflex, 'E', 0xCA }, .{ .circumflex, 'I', 0xCE },
    .{ .circumflex, 'O', 0xD4 }, .{ .circumflex, 'U', 0xDB }, .{ .tilde, 'a', 0xE3 },
    .{ .tilde, 'n', 0xF1 },      .{ .tilde, 'o', 0xF5 },      .{ .tilde, 'A', 0xC3 },
    .{ .tilde, 'N', 0xD1 },      .{ .tilde, 'O', 0xD5 },      .{ .diaeresis, 'a', 0xE4 },
    .{ .diaeresis, 'e', 0xEB },  .{ .diaeresis, 'i', 0xEF },  .{ .diaeresis, 'o', 0xF6 },
    .{ .diaeresis, 'u', 0xFC },  .{ .diaeresis, 'y', 0xFF },  .{ .diaeresis, 'A', 0xC4 },
    .{ .diaeresis, 'E', 0xCB },  .{ .diaeresis, 'I', 0xCF },  .{ .diaeresis, 'O', 0xD6 },
    .{ .diaeresis, 'U', 0xDC },  .{ .cedilla, 'c', 0xE7 },    .{ .cedilla, 'C', 0xC7 },
};

/// The character a dead key produces when it fails to compose.
fn deadLiteral(d: Dead) u21 {
    return switch (d) {
        .none => 0,
        .acute => '\'',
        .grave => '`',
        .circumflex => '^',
        .tilde => '~',
        .diaeresis => '"',
        .cedilla => ',',
    };
}

pub const Output = struct {
    /// Codepoint to deliver, or 0 for none.
    codepoint: u21 = 0,
    /// A second codepoint, when a failed composition emits the dead key's own
    /// character followed by the key that did not combine.
    extra: u21 = 0,
    /// True while a dead key is waiting, so a status indicator can show it.
    dead_pending: bool = false,
};

/// Clear any half-finished composition. Called when focus moves, so a dead key
/// pressed in one field cannot leak into the next.
pub fn resetCompose() void {
    pending = .none;
}

pub fn deadPending() bool {
    return pending != .none;
}

/// Translate a key press into characters.
pub fn translate(code: KeyCode, mods: Modifiers) Output {
    const entry = current().lookup(code) orelse return .{ .dead_pending = pending != .none };

    // Pick the level. AltGr wins over shift for the third and fourth levels.
    const dead: Dead = if (mods.altgr)
        entry.dead_altgr
    else if (mods.shift)
        entry.dead_shift
    else
        entry.dead_base;

    var ch: u21 = if (mods.altgr and mods.shift and entry.levels.shift_altgr != 0)
        entry.levels.shift_altgr
    else if (mods.altgr)
        entry.levels.altgr
    else if (mods.shift)
        entry.levels.shift
    else
        entry.levels.base;

    // Caps Lock affects letters only, and cancels with Shift rather than
    // compounding: shift+caps on a letter gives lowercase.
    if (mods.caps_lock and !mods.altgr and entry.levels.base >= 'a' and entry.levels.base <= 'z') {
        ch = if (mods.shift) entry.levels.base else entry.levels.shift;
    }

    // Control turns a letter into its control code, and must beat composition:
    // Ctrl+C is not a candidate for a cedilla.
    if (mods.control and ch >= 'a' and ch <= 'z') {
        pending = .none;
        return .{ .codepoint = ch - 'a' + 1 };
    }
    if (mods.control and ch >= 'A' and ch <= 'Z') {
        pending = .none;
        return .{ .codepoint = ch - 'A' + 1 };
    }

    if (dead != .none) {
        // Pressing the same dead key twice emits its literal character, which
        // is the conventional way to type a bare accent.
        if (pending == dead) {
            pending = .none;
            return .{ .codepoint = deadLiteral(dead) };
        }
        pending = dead;
        return .{ .dead_pending = true };
    }

    if (pending != .none) {
        const waiting = pending;
        pending = .none;

        if (ch == ' ') return .{ .codepoint = deadLiteral(waiting) };

        for (compositions) |c| {
            if (c[0] == waiting and c[1] == ch) return .{ .codepoint = c[2] };
        }

        // No combination exists: emit the accent and the character separately
        // rather than swallowing either.
        return .{ .codepoint = deadLiteral(waiting), .extra = ch };
    }

    return .{ .codepoint = ch };
}

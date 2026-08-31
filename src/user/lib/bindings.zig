//! What the manager's keys do.
//!
//! One table, read twice: the manager looks up what a chord means, and the
//! settings' help pane lists the same rows for a person. The alternative is a
//! list of bindings and a list of descriptions that drift the first time
//! somebody adds a key and forgets the other place.
//!
//! The switch on `Action` in the manager is exhaustive, so a row added here
//! without a handler there is a build error rather than a key that does
//! nothing.

const std = @import("std");
const abi = @import("lib").syscalls;

pub const KeyCode = abi.KeyCode;

pub const Action = enum {
    view_previous,
    next_keymap,
    view_left,
    view_right,
    send_left,
    send_right,
    focus_next,
    focus_previous,
    maximise,
    master_smaller,
    master_larger,
    floating,
    focus_bar,
    launcher,
    new_desktop,
    terminal,
    zoom,
    close_window,
    kill_window,
    close_desktop,
    cycle_theme,
};

pub const Binding = struct {
    code: KeyCode,
    /// Whether shift is part of the chord. Every binding here is held with
    /// the manager's own modifier as well; that is what makes it the
    /// manager's rather than the focused window's.
    shift: bool = false,
    action: Action,
    /// The chord as somebody would write it down.
    chord: []const u8,
    /// What it does, in the words a person would use.
    says: []const u8,
};

/// Held with Super, always. The number keys are a family of their own and
/// are handled before this table is consulted: nine rows saying the same
/// thing would be a list nobody reads.
pub const all = [_]Binding{
    .{ .code = .enter, .action = .terminal, .chord = "Super+Enter", .says = "a terminal" },
    .{ .code = .p, .action = .launcher, .chord = "Super+P", .says = "the launcher" },
    .{ .code = .b, .action = .focus_bar, .chord = "Super+B", .says = "the keyboard goes to the bar" },

    .{ .code = .j, .action = .focus_next, .chord = "Super+J", .says = "focus the next window" },
    .{ .code = .k, .action = .focus_previous, .chord = "Super+K", .says = "focus the one before" },
    .{ .code = .enter, .shift = true, .action = .zoom, .chord = "Super+Shift+Enter", .says = "make this window the master" },
    .{ .code = .m, .action = .maximise, .chord = "Super+M", .says = "one window at full size, and back" },
    .{ .code = .f, .action = .floating, .chord = "Super+F", .says = "let this window float free of the tiling" },
    .{ .code = .h, .action = .master_smaller, .chord = "Super+H", .says = "give the master less room" },
    .{ .code = .l, .action = .master_larger, .chord = "Super+L", .says = "give the master more" },

    .{ .code = .bracket_left, .action = .view_left, .chord = "Super+[", .says = "the desktop to the left" },
    .{ .code = .bracket_right, .action = .view_right, .chord = "Super+]", .says = "the desktop to the right" },
    .{ .code = .bracket_left, .shift = true, .action = .send_left, .chord = "Super+Shift+[", .says = "take this window there" },
    .{ .code = .bracket_right, .shift = true, .action = .send_right, .chord = "Super+Shift+]", .says = "take this window there" },
    .{ .code = .tab, .action = .view_previous, .chord = "Super+Tab", .says = "back to the last desktop" },
    .{ .code = .n, .action = .new_desktop, .chord = "Super+N", .says = "another desktop" },

    .{ .code = .c, .shift = true, .action = .close_window, .chord = "Super+Shift+C", .says = "ask this window to close" },
    .{ .code = .k, .shift = true, .action = .kill_window, .chord = "Super+Shift+K", .says = "take it away if it will not" },
    .{ .code = .w, .shift = true, .action = .close_desktop, .chord = "Super+Shift+W", .says = "close the whole desktop" },

    .{ .code = .space, .action = .next_keymap, .chord = "Super+Space", .says = "the next keyboard layout" },
    .{ .code = .grave, .action = .cycle_theme, .chord = "Super+`", .says = "the next theme" },
};

/// What the numbers do, said once rather than nine times.
pub const numbers = [_]struct { chord: []const u8, says: []const u8 }{
    .{ .chord = "Super+1..9", .says = "go to that desktop" },
    .{ .chord = "Super+Shift+1..9", .says = "take this window to it" },
};

/// Which action a chord means, or null for one that is nobody's.
pub fn lookup(code: KeyCode, shift: bool) ?Action {
    for (all) |binding| {
        if (binding.code == code and binding.shift == shift) return binding.action;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a chord means one thing" {
    for (all, 0..) |binding, i| {
        for (all[i + 1 ..]) |other| {
            const same = binding.code == other.code and binding.shift == other.shift;
            try testing.expect(!same);
        }
    }
}

test "shift makes a different chord of the same key" {
    try testing.expectEqual(Action.close_window, lookup(.c, true).?);
    try testing.expectEqual(@as(?Action, null), lookup(.c, false));

    try testing.expectEqual(Action.focus_previous, lookup(.k, false).?);
    try testing.expectEqual(Action.kill_window, lookup(.k, true).?);
}

test "every action is reachable" {
    for (std.enums.values(Action)) |action| {
        var found = false;
        for (all) |binding| {
            if (binding.action == action) found = true;
        }
        try testing.expect(found);
    }
}

test "every binding says what it does" {
    for (all) |binding| {
        try testing.expect(binding.chord.len > 0);
        try testing.expect(binding.says.len > 0);
    }
}

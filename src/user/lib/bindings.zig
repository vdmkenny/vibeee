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
    move_left,
    move_right,
    move_up,
    move_down,
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

/// What a binding is about, so a page listing them can group them the way
/// somebody looking for one would: by what they are trying to do rather than
/// by which letter it happens to be.
pub const Group = enum {
    starting,
    windows,
    desktops,
    closing,
    machine,

    pub fn title(self: Group) []const u8 {
        return switch (self) {
            .starting => "Starting things",
            .windows => "Windows",
            .desktops => "Desktops",
            .closing => "Closing",
            .machine => "The machine",
        };
    }
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
    group: Group,
};

/// Held with Super, always. The number keys are a family of their own and
/// are handled before this table is consulted: nine rows saying the same
/// thing would be a list nobody reads.
pub const all = [_]Binding{
    .{ .code = .enter, .action = .terminal, .chord = "Super+Enter", .says = "a terminal", .group = .starting },
    .{ .code = .p, .action = .launcher, .chord = "Super+P", .says = "the launcher", .group = .starting },
    .{ .code = .b, .action = .focus_bar, .chord = "Super+B", .says = "the keyboard goes to the bar", .group = .starting },

    .{ .code = .j, .action = .focus_next, .chord = "Super+J", .says = "focus the next window", .group = .windows },
    .{ .code = .k, .action = .focus_previous, .chord = "Super+K", .says = "focus the one before", .group = .windows },
    .{ .code = .enter, .shift = true, .action = .zoom, .chord = "Super+Shift+Enter", .says = "make this window the master", .group = .windows },
    .{ .code = .m, .action = .maximise, .chord = "Super+M", .says = "one window at full size, and back", .group = .windows },
    .{ .code = .f, .action = .floating, .chord = "Super+F", .says = "let this window float free of the tiling", .group = .windows },
    .{ .code = .left, .shift = true, .action = .move_left, .chord = "Super+Shift+Left", .says = "move a floating window left", .group = .windows },
    .{ .code = .right, .shift = true, .action = .move_right, .chord = "Super+Shift+Right", .says = "move a floating window right", .group = .windows },
    .{ .code = .up, .shift = true, .action = .move_up, .chord = "Super+Shift+Up", .says = "move a floating window up", .group = .windows },
    .{ .code = .down, .shift = true, .action = .move_down, .chord = "Super+Shift+Down", .says = "move a floating window down", .group = .windows },
    .{ .code = .h, .action = .master_smaller, .chord = "Super+H", .says = "give the master less room", .group = .windows },
    .{ .code = .l, .action = .master_larger, .chord = "Super+L", .says = "give the master more", .group = .windows },

    .{ .code = .bracket_left, .action = .view_left, .chord = "Super+[", .says = "the desktop to the left", .group = .desktops },
    .{ .code = .bracket_right, .action = .view_right, .chord = "Super+]", .says = "the desktop to the right", .group = .desktops },
    .{ .code = .bracket_left, .shift = true, .action = .send_left, .chord = "Super+Shift+[", .says = "take this window there", .group = .desktops },
    .{ .code = .bracket_right, .shift = true, .action = .send_right, .chord = "Super+Shift+]", .says = "take this window there", .group = .desktops },
    .{ .code = .tab, .action = .view_previous, .chord = "Super+Tab", .says = "back to the last desktop", .group = .desktops },
    .{ .code = .n, .action = .new_desktop, .chord = "Super+N", .says = "another desktop", .group = .desktops },

    .{ .code = .c, .shift = true, .action = .close_window, .chord = "Super+Shift+C", .says = "ask this window to close", .group = .closing },
    .{ .code = .k, .shift = true, .action = .kill_window, .chord = "Super+Shift+K", .says = "take it away if it will not", .group = .closing },
    .{ .code = .w, .shift = true, .action = .close_desktop, .chord = "Super+Shift+W", .says = "close the whole desktop", .group = .closing },

    .{ .code = .space, .action = .next_keymap, .chord = "Super+Space", .says = "the next keyboard layout", .group = .machine },
    .{ .code = .grave, .action = .cycle_theme, .chord = "Super+`", .says = "the next theme", .group = .machine },
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

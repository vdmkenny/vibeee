//! The window manager's settings.
//!
//! The schema lives in `proto.settings`, because the Settings app and `cfg`
//! edit the same thing and a second copy of the field list is a second thing to
//! keep in step. What is here is the manager's own business: reading the domain
//! once at start, and putting the theme it names into effect.

const settings = @import("proto").settings;
const cursor = @import("cursor.zig");
const theme = @import("eui").theme;

pub const Config = settings.Wm;

var active: Config = .{};
var keys: settings.Input = .{};

/// Read the settings and apply what they say, returning the result.
pub fn load() *const Config {
    active = settings.load("wm");
    keys = settings.load("input");
    apply();
    return &active;
}

/// Take up a change somebody else made. Returns true when anything moved, so a
/// caller can skip the relayout that follows nothing.
pub fn reload() bool {
    const fresh = settings.load("wm");
    if (std.meta.eql(fresh, active)) return false;

    active = fresh;
    apply();
    return true;
}

fn apply() void {
    // The scale first: `use` builds the theme that is drawn with, and it
    // builds it at whatever size was last asked for.
    theme.setScale(active.scale);
    if (theme.byName(@tagName(active.theme))) |chosen| theme.use(chosen);
    theme.setAccent(active.accent.rgb());
    cursor.setColour(active.pointer.rgb(), active.pointer.outline());
}

pub fn current() *const Config {
    return &active;
}

/// The keyboard settings. Not applied here: `cfgd` hands the layout to the
/// kernel, and this is only what the bar draws.
pub fn keyboard() *const settings.Input {
    return &keys;
}

/// Take up a keyboard change, whoever made it. True when it moved.
pub fn reloadKeyboard() bool {
    const fresh = settings.load("input");
    if (std.meta.eql(fresh, keys)) return false;

    keys = fresh;
    return true;
}

const std = @import("std");

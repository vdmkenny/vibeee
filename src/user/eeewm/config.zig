//! The window manager's settings.
//!
//! The schema lives in `proto.settings`, because the Settings app and `cfg`
//! edit the same thing and a second copy of the field list is a second thing to
//! keep in step. What is here is the manager's own business: reading the domain
//! once at start, and putting the theme it names into effect.

const settings = @import("proto").settings;
const theme = @import("eui").theme;

pub const Config = settings.Wm;

var active: Config = .{};

/// Read the settings and apply what they say, returning the result.
pub fn load() *const Config {
    active = settings.load("wm");
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
    if (theme.byName(@tagName(active.theme))) |chosen| theme.use(chosen);
}

pub fn current() *const Config {
    return &active;
}

const std = @import("std");

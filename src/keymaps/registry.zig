//! Every keyboard layout the system knows about.
//!
//! Adding one is a new file in this directory plus a single line here. Nothing
//! else in the system needs to change: the settings UI, the switch hotkey and
//! the status-bar indicator all read this list.
//!
//! Order matters only in that the first entry is the default.

const l = @import("layout.zig");

pub const all = [_]l.Compiled{
    l.compile(@import("us_intl.zig").layout),
    l.compile(@import("be_azerty.zig").layout),
};

/// Layout selected when no configuration says otherwise.
pub const default_index = 0;

//! What the window manager reads from `/etc/eeewm.cfg`.
//!
//! The struct is the schema: `ulib.config` walks it, so a new setting is a
//! field here and a line in the file, with nothing to keep in step. Every
//! field has a default that makes a usable desktop, because a machine with no
//! configuration file is the normal case and should not be a broken one.
//!
//! ```
//! # /etc/eeewm.cfg
//! theme = classic     # classic, paper, dusk
//! bar   = top         # top or bottom
//! layout = tall       # tall, wide, monocle
//! master = 58         # master's share of the screen, per cent
//! ```

const config = @import("ulib").config;
const layout = @import("layout.zig");
const theme = @import("eui").theme;

pub const PATH = "/etc/eeewm.cfg";

pub const BarPosition = enum { top, bottom };

pub const Config = struct {
    /// One of the names in `eui.theme`. An unknown name keeps the default
    /// rather than leaving the desktop unreadable.
    theme: [16]u8 = nameOf("classic"),
    bar: BarPosition = .top,
    layout: layout.Layout = .tall,
    /// Master's share as a percentage, so the file holds a whole number rather
    /// than a decimal nobody can type consistently.
    master: u8 = 58,

    pub fn themeName(self: *const Config) []const u8 {
        var n: usize = 0;
        while (n < self.theme.len and self.theme[n] != 0) n += 1;
        return self.theme[0..n];
    }

    /// Master's share as the fraction the layout wants, clamped to the range
    /// that leaves both sides usable.
    pub fn masterFraction(self: *const Config) f32 {
        const percent: f32 = @floatFromInt(@max(@min(self.master, 80), 20));
        return percent / 100.0;
    }
};

fn nameOf(comptime text: []const u8) [16]u8 {
    var out: [16]u8 = @splat(0);
    @memcpy(out[0..text.len], text);
    return out;
}

var storage: [512]u8 = @splat(0);
var active: Config = .{};

/// Read the file, apply what it says, and return the result.
pub fn load() *const Config {
    active = .{};
    _ = config.load(PATH, &active, &storage);

    if (theme.byName(active.themeName())) |chosen| theme.use(chosen);
    return &active;
}

pub fn current() *const Config {
    return &active;
}

//! libeui: the shared control library.
//!
//! The `comctl` of the system. Anything putting an interface on screen, the
//! window manager's own furniture included, draws it from here, so a control
//! looks and behaves the same everywhere and a new program gets the whole look
//! by asking for controls rather than by drawing rectangles.
//!
//! **A control an application needs goes here, not in the application.** If it
//! is reusable it belongs to the toolkit, and the second program to want a
//! list box should find one rather than write a worse one. An app growing its
//! own widgets is how a system ends up with four kinds of button that behave
//! differently, which is the failure this library exists to prevent.
//!
//! Deliberately free of syscalls. It draws into a surface somebody else
//! obtained and reacts to input somebody else read, which is what lets the
//! same code paint the compositor's furniture, an application's window, and
//! eventually a test harness with no screen at all.

pub const draw = @import("draw.zig");
pub const chooser = @import("chooser.zig");
pub const context_menu = @import("context_menu.zig");
pub const menubar = @import("menubar.zig");
pub const scroll = @import("scroll.zig");
pub const scrollpane = @import("scrollpane.zig");
pub const statusbar = @import("statusbar.zig");
pub const table = @import("table.zig");
pub const text = @import("text.zig");
pub const icon = @import("icon.zig");
pub const keys = @import("keys.zig");
pub const meter = @import("meter.zig");
pub const footer = @import("footer.zig");
pub const gauge = @import("gauge.zig");
pub const chrome = @import("chrome.zig");
pub const facts = @import("facts.zig");
pub const grid = @import("grid.zig");
pub const Grid = grid.Grid;
pub const popover = @import("popover.zig");
pub const rail = @import("rail.zig");
pub const region = @import("region.zig");
pub const row = @import("row.zig");
pub const slider = @import("slider.zig");
pub const strip = @import("strip.zig");
pub const thumb = @import("thumb.zig");
pub const theme = @import("theme.zig");
pub const widget = @import("widget.zig");

/// Re-exported because almost every caller wants them by these names.
pub const Rect = draw.Rect;
pub const Surface = draw.Surface;
pub const Color = draw.Color;
pub const Context = widget.Context;
pub const Theme = theme.Theme;

// The toolkit's modules are only analysed when something reaches them, so
// without this the tests inside them are not skipped but never seen.
test {
    @import("std").testing.refAllDecls(@This());
}

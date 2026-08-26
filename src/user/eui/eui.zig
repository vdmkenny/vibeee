//! libeui: the shared control library.
//!
//! The `comctl` of the system. Anything putting an interface on screen, the
//! window manager's own furniture included, draws it from here, so a control
//! looks and behaves the same everywhere and a new program gets the whole look
//! by asking for controls rather than by drawing rectangles.
//!
//! Deliberately free of syscalls. It draws into a surface somebody else
//! obtained and reacts to input somebody else read, which is what lets the
//! same code paint the compositor's furniture, an application's window, and
//! eventually a test harness with no screen at all.

pub const draw = @import("draw.zig");
pub const theme = @import("theme.zig");
pub const widget = @import("widget.zig");

/// Re-exported because almost every caller wants them by these names.
pub const Rect = draw.Rect;
pub const Surface = draw.Surface;
pub const Color = draw.Color;
pub const Context = widget.Context;
pub const Theme = theme.Theme;

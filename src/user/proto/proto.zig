//! The window protocol, both halves.
//!
//! `wm` is the wire: types only, compiled identically by client and server.
//! `client` is the application side of the conversation, so the sequence in
//! design/10-gui.md §5.2 is written once rather than in every app.
//!
//! The server side is not here. It is policy, not protocol: which window goes
//! where, who has focus, what a tag means. That belongs to the window manager.

pub const dialog = @import("dialog.zig");
pub const FileDialog = dialog.FileDialog;
pub const net = @import("net.zig");
pub const platform = @import("platform.zig");
pub const service = @import("service.zig");
pub const audio = @import("audio.zig");
pub const devices = @import("devices.zig");
pub const anchors = @import("anchors.zig");
pub const panes = @import("panes.zig");
pub const settings = @import("settings.zig");
pub const usb = @import("usb.zig");
pub const socket = @import("socket.zig");
pub const wm = @import("wm.zig");
pub const app = @import("app.zig");
pub const client = @import("client.zig");

pub const Req = wm.Req;
pub const Rep = wm.Rep;
pub const Ev = wm.Ev;
pub const Connection = client.Connection;

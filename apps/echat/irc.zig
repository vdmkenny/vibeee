//! The IRC protocol engine.
//!
//! Line parsing and rendering, `RPL_ISUPPORT`, and the connection state
//! machine. Nothing here opens a socket, waits or allocates, so all of it is
//! tested on the host against the shared parser vectors.
//!
//! A client sits on top: it owns the connection, the buffers and the window,
//! and asks this what the bytes mean.

pub const line = @import("irc/line.zig");
pub const support = @import("irc/support.zig");
pub const session = @import("irc/session.zig");

pub const Line = line.Line;
pub const Stream = line.Stream;
pub const Command = line.Command;
pub const Reply = line.Reply;
pub const Verb = line.Verb;
pub const Source = line.Source;
pub const Support = support.Support;
pub const Session = session.Session;
pub const Cap = session.Cap;
pub const Credentials = session.Credentials;
pub const parse = line.parse;
pub const render = line.render;

test {
    // Each module's tests live beside it; naming them here makes one run
    // cover the whole engine.
    _ = line;
    _ = support;
    _ = session;
}

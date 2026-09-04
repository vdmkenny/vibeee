//! What echat remembers between runs.
//!
//! The system's settings live in `cfgd` under the domains its own schema
//! names; this is not one of those. echat is an extra application, so its
//! schema is its own and the system carries no knowledge of it. What is
//! shared is the store itself: the same `key = value` grammar, the same
//! parser, and the settings volume, so a network is edited with the one text
//! editor on the machine and read back by the same code every other
//! configured thing uses.
//!
//! One record per network, a blank line between them:
//!
//!     at = irc.example.org
//!     nick = kenny
//!     account = kenny
//!     password = ...
//!     join = #vibeee #zig
//!     open = yes

const std = @import("std");
const ulib = @import("ulib");

/// Where it is kept: the settings volume, which survives an image being
/// rebuilt, beside everything else a machine was told.
pub const PATH = "/cfg/echat.cfg";

/// Networks a person may have. The same bound the client can connect to at
/// once, since a network configured but unreachable is one that would sit in
/// the list saying nothing.
pub const NETWORKS = 4;

/// Room for a host with a port after it, a nick, an account.
pub const NAME = 64;
/// A password, which is longer than a name and is not shown.
pub const SECRET = 128;
/// The channels to join, space separated.
pub const CHANNELS = 160;

/// The most a file may come to: every record at its longest, and room for
/// the comments somebody writes around them.
pub const FILE_MAX = 4096;

/// One network, as it is written down.
pub const Network = struct {
    /// Where to reach it: a name, optionally with `:port`, and a plus in
    /// front of the port for TLS. A bare name is TLS.
    at: [NAME]u8 = @splat(0),
    /// What to be called there. Empty takes the machine's own name.
    nick: [NAME]u8 = @splat(0),
    /// The account to prove and what proves it. Empty asks for nothing,
    /// which is what a network with no account wants.
    account: [NAME]u8 = @splat(0),
    password: [SECRET]u8 = @splat(0),
    /// Joined once the network says hello.
    join: [CHANNELS]u8 = @splat(0),
    /// Reached when the window opens.
    open: bool = false,

    /// A field's text, which is the bytes before the first zero.
    pub fn text(field: []const u8) []const u8 {
        const end = std.mem.indexOfScalar(u8, field, 0) orelse field.len;
        return field[0..end];
    }

    /// Whether this record names a network at all.
    pub fn named(self: *const Network) bool {
        return text(&self.at).len != 0;
    }
};

/// Every network written down, and how many there are.
pub const Book = struct {
    networks: [NETWORKS]Network = @splat(.{}),
    len: usize = 0,

    pub fn slice(self: *const Book) []const Network {
        return self.networks[0..self.len];
    }
};

/// Read what is written down. An unreadable or missing file is a machine
/// with no networks configured, which is what a new one has.
pub fn read(buffer: []u8) Book {
    var book: Book = .{};
    book.len = ulib.config.loadEach(PATH, &book.networks, buffer);

    // A record with no name is a stanza somebody left half written; it is
    // not a network, and counting it would put a blank row in the list.
    var kept: usize = 0;
    for (book.networks[0..book.len]) |network| {
        if (!network.named()) continue;
        book.networks[kept] = network;
        kept += 1;
    }
    book.len = kept;
    return book;
}

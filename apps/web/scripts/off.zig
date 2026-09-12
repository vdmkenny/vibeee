//! A page's scripts, for a reader built without them.
//!
//! The same calls as `scripts.zig`, and none of them do anything: no engine
//! is compiled in, so no page has a script in it and no click is ever taken.
//! A reader built this way is the one it was before scripts existed, and
//! `web.zig` does not know the difference.

const lexbor = @import("lexbor");

/// There is no page with a script in it.
pub const Page = opaque {};

pub fn open(
    _: *lexbor.Document,
    _: []const u8,
    _: [*:0]const u8,
    _: *const fn ([]const u8) ?[]u8,
    _: *const fn ([]const u8) void,
    _: *const fn ([]const u8, []u8) usize,
    _: *const fn ([]const u8, []const u8) void,
) ?*Page {
    return null;
}

/// Nothing, and none: a reader built without them is never asked.
pub fn askedLast(_: *Page) ?[]const u8 {
    return null;
}

pub fn askedCount(_: *Page) u32 {
    return 0;
}

pub fn errorLast(_: *Page) ?[]const u8 {
    return null;
}

pub fn errorSource(_: *Page) []const u8 {
    return "";
}

/// Nothing: a reader built without them was never asked.
pub fn whyNot() []const u8 {
    return "";
}

/// None, and none: a reader built without them has no scripts to count.
pub fn scriptsRan(_: *Page) u32 {
    return 0;
}

pub fn scriptsThrew(_: *Page) u32 {
    return 0;
}

pub fn close(_: *Page) void {}

pub fn click(_: *Page, _: *anyopaque) bool {
    return false;
}

pub fn typed(_: *Page, _: *anyopaque, _: bool) void {}

pub fn cookiesFor(_: *Page, _: [*:0]const u8, _: [*:0]const u8) ?[*:0]u8 {
    return null;
}

pub fn changed(_: *Page) bool {
    return false;
}

pub fn loop(_: *Page) bool {
    return false;
}

pub fn waits(_: *Page) ?u32 {
    return null;
}

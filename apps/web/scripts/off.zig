//! A page's scripts, for a reader built without them.
//!
//! The same calls as `scripts.zig`, and none of them do anything: no engine
//! is compiled in, so no page has a script in it and no click is ever taken.
//! A reader built this way is the one it was before scripts existed, and
//! `web.zig` does not know the difference.



/// There is no page with a script in it.
pub const Page = opaque {};

pub fn open(_: *anyopaque, _: []const u8, _: [*:0]const u8) ?*Page {
    return null;
}

pub fn close(_: *Page) void {}

pub fn click(_: *Page, _: *anyopaque) bool {
    return false;
}

pub fn typed(_: *Page, _: *anyopaque, _: bool) void {}

pub fn changed(_: *Page) bool {
    return false;
}

pub fn loop(_: *Page) bool {
    return false;
}

pub fn waits(_: *Page) ?u32 {
    return null;
}

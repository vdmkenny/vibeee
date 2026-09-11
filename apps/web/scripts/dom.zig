//! The document's face, as a script reaches it: the pin.
//!
//! `dom/dom.c` is what stands behind these calls, and this is the only way
//! the reader reaches it, so a signature changed on either side fails the
//! build on its own rather than at a call site in the middle of a page.

const js = @import("js");

/// A document a script is running against: the engine, and the page's own
/// tree bound into it.
pub const Document = js.Engine;

extern fn dom_bind(document: *js.Engine, tree: *anyopaque, address: [*:0]const u8, user_agent: [*:0]const u8, fetch: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?[*:0]u8, taken: ?*anyopaque) bool;
extern fn dom_cookies_for(document: *js.Engine, host: [*:0]const u8, path: [*:0]const u8) ?[*:0]u8;
extern fn dom_load(document: *js.Engine, tree: *anyopaque) void;
extern fn dom_click(document: *js.Engine, node: *anyopaque) bool;
extern fn dom_changed_at(document: *js.Engine, node: *anyopaque, sent: bool) void;
extern fn dom_changed(document: *js.Engine) bool;
extern fn dom_loop(document: *js.Engine) bool;
extern fn dom_waits(document: *js.Engine, in_ms: *u32) bool;
extern fn dom_release(document: *js.Engine) void;

/// Give a script the tree `tree`, whose page came from `address`.
pub fn bind(document: *js.Engine, tree: *anyopaque, address: [*:0]const u8, user_agent: [*:0]const u8, fetch: ?*const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?[*:0]u8, taken: ?*anyopaque) bool {
    return dom_bind(document, tree, address, user_agent, fetch, taken);
}

/// What to send as `Cookie` for a page at `host` and `path`, or nothing.
pub fn cookiesFor(document: *js.Engine, host: [*:0]const u8, path: [*:0]const u8) ?[*:0]u8 {
    return dom_cookies_for(document, host, path);
}

/// Run every script the document carries, then tell it that it is ready.
pub fn load(document: *js.Engine, tree: *anyopaque) void {
    dom_load(document, tree);
}

/// A click on `node`, and on what it stands inside. True where a listener
/// asked for the click to go no further, which is a link not followed.
pub fn click(document: *js.Engine, node: *anyopaque) bool {
    return dom_click(document, node);
}

/// What was typed or ticked in the control at `node`: `input`, `change`, and
/// `submit` where a form was sent.
pub fn typed(document: *js.Engine, node: *anyopaque, sent: bool) void {
    dom_changed_at(document, node, sent);
}

/// Whether a script has changed the document since the last time this was
/// asked, and so whether the page reads differently.
pub fn changed(document: *js.Engine) bool {
    return dom_changed(document);
}

/// Run what a script left waiting: the promises it made, the timers it set.
pub fn loop(document: *js.Engine) bool {
    return dom_loop(document);
}

/// When the next timer is due, in thousandths of a second since the machine
/// was started, or nothing where no timer is waiting.
pub fn waits(document: *js.Engine) ?u32 {
    var at: u32 = 0;
    return if (dom_waits(document, &at)) at else null;
}

/// Give back the document, and everything a script left hanging on it.
pub fn release(document: *js.Engine) void {
    dom_release(document);
}

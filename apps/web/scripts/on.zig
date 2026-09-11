//! A page's scripts: when they run, and what the reader does about it.
//!
//! The reader keeps a page's tree while the page is on screen, so that a
//! script has something to work on and the reader has something to read it
//! back from. This is the policy around that: give a page's tree to a script
//! when the page is put on screen, run what the page carries, listen for a
//! click or a word typed, and read the page again whenever a script has
//! changed it.
//!
//! The whole of the engine and the document behind it is `src/user/js` and
//! `dom.zig`; this file is only when and why. A reader built without them
//! gets `scripts_off.zig`, which says the same things and does none of them.
//! Which of the two it is, is the build's to say: both are the module
//! `scripts`, and the reader asks for that and nothing more.

const std = @import("std");
const js = @import("js");
const dom = @import("dom.zig");

/// A page's tree with a script in it.
pub const Page = js.Engine;

/// The engine, started the first time a page wants one and kept: a runtime is
/// the expensive half, and one freed while a script still has objects in it
/// takes the reader with it. A context is made per page and given back with
/// it, so nothing a script was ever given outlives its tree.
var machine: ?*js.Machine = null;

fn engine() ?*js.Machine {
    if (machine) |running| return running;
    machine = js.start();
    return machine;
}

/// Give a page's tree to a script and run what the page carries. None where
/// the engine would not start, which is a page that reads as though it had
/// no scripts.
///
/// The tree comes across as a pointer and nothing more: which kind of tree
/// it is, is the reader's business, and this module is not to be given a
/// second copy of the reader's own files to know.
pub fn open(tree: *anyopaque, address: []const u8, user_agent: [*:0]const u8) ?*Page {
    const page = js.open(engine() orelse return null) orelse return null;
    var buf: [512]u8 = undefined;
    const where = std.fmt.bufPrintZ(&buf, "{s}", .{address}) catch {
        js.close(page);
        return null;
    };
    if (!dom.bind(page, tree, where.ptr, user_agent)) {
        js.close(page);
        return null;
    }
    dom.load(page, tree);
    return page;
}

/// Stop, and give back everything held: a page gone from the screen takes
/// its tree and its script with it.
pub fn close(page: *Page) void {
    dom.release(page);
    js.close(page);
}

/// A click on the element at `node`. True where a script asked for the click
/// to go no further, which is a link that is not followed.
pub fn click(page: *Page, node: *anyopaque) bool {
    return dom.click(page, node);
}

/// What was typed or ticked in the control at `node`, and whether a form was
/// sent with it.
pub fn typed(page: *Page, node: *anyopaque, sent: bool) void {
    dom.typed(page, node, sent);
}

/// Whether a script has changed the page since the last time this was asked,
/// and so whether the reader must read it again.
pub fn changed(page: *Page) bool {
    return dom.changed(page);
}

/// Run what a script left waiting. True where it changed the page, and so
/// where the reader must read it again.
pub fn loop(page: *Page) bool {
    return dom.loop(page) and dom.changed(page);
}

/// When the next timer a script set is due, in thousandths of a second since
/// the machine was started: what a window with a page on screen waits on,
/// where it would otherwise wait on nothing.
pub fn waits(page: *Page) ?u32 {
    return dom.waits(page);
}

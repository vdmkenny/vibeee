//! What is on the bus, and what is driving it.
//!
//! The first thing to look at when a machine does less than it should. A
//! device with nothing against it is one nothing has claimed, and one whose
//! driver merely matched is one a driver was written for but cannot yet run,
//! which on unfamiliar hardware is usually the answer.

const std = @import("std");
const driver = @import("lib").driver;
const info = @import("ulib").info;
const ink = @import("ulib").ink;
const out = @import("ulib").out;
const str = @import("ulib").str;

const ADDRESS = 10;
const ID = 12;
const CLASS = 8;
const INTERFACE = 4;
const DRIVER = 13;
const STATE = 10;

/// Two colon-joined fields in one column, which is how both the identifiers
/// and the class codes read.
fn pair(left: []const u8, right: []const u8, width: usize) void {
    var joined: [16]u8 = @splat(0);
    var text = str.Builder{ .buf = &joined };
    text.text(left);
    text.byte(':');
    text.text(right);
    out.pad(text.done(), width);
}

/// What a state word names. Anything unrecognised reads as unclaimed, which
/// draws dim: a device nothing took should look absent rather than look like
/// something that went wrong.
fn stateOf(word: []const u8) driver.State {
    return std.meta.stringToEnum(driver.State, word) orelse .unclaimed;
}

/// Text in a fixed column, so it can be handed to `ink.write` whole rather
/// than coloured and padded in two steps that could disagree about the width.
fn padded(text: []const u8, width: usize) []const u8 {
    var built = str.Builder{ .buf = &column };
    built.text(text);
    while (built.len < width) built.byte(' ');
    return built.done();
}

var column: [@max(DRIVER, STATE) + 1]u8 = @splat(0);

pub fn devices(_: []const []const u8) void {
    var buf: [2048]u8 = @splat(0);
    const table = info.ask("pci", &buf);

    if (table.len == 0) {
        out.text("no devices; bus enumeration may have failed\n");
        out.flush();
        return;
    }

    // Widths chosen once, so the header and the rows cannot drift apart.
    ink.use(.dim);
    out.pad("address", ADDRESS);
    out.pad("id", ID);
    out.pad("class", CLASS);
    out.pad("if", INTERFACE);
    out.pad("driver", DRIVER);
    out.pad("state", STATE);
    out.text("what\n");
    ink.plain();

    var lines = str.lines(table);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = str.fields(line);

        // The identifiers are dim: they are how a device is looked up, not
        // what anybody reads the table for.
        ink.use(.dim);
        out.pad(it.next() orelse "", ADDRESS);
        pair(it.next() orelse "", it.next() orelse "", ID);
        pair(it.next() orelse "", it.next() orelse "", CLASS);
        // The programming interface, which on some classes is the only
        // thing separating two quite different devices.
        out.pad(it.next() orelse "", INTERFACE);
        ink.plain();

        // The driver is named whatever became of it, and the state beside it
        // says which: this is the boot probe's table, seen from userspace, and
        // the two should not tell different stories about the same device.
        // Nor look different while telling the same one, which is why the
        // colour comes from the shared `Confidence` rather than from here.
        const name = it.next() orelse "-";
        const state = it.next() orelse "";

        const role = stateOf(state).role();
        ink.write(role, padded(name, DRIVER));
        ink.write(role, padded(state, STATE));

        out.text(it.next() orelse "");
        out.byte('\n');
    }
    out.flush();
}

//! What is on the bus, and what is driving it.
//!
//! The first thing to look at when a machine does less than it should. A
//! device with nothing against it is one nothing has claimed, and one whose
//! driver merely matched is one a driver was written for but cannot yet run,
//! which on unfamiliar hardware is usually the answer.

const info = @import("ulib").info;
const out = @import("ulib").out;
const str = @import("ulib").str;

const ADDRESS = 10;
const ID = 12;
const CLASS = 8;
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

pub fn devices(_: []const []const u8) void {
    var buf: [2048]u8 = @splat(0);
    const table = info.ask("pci", &buf);

    if (table.len == 0) {
        out.text("no devices; bus enumeration may have failed\n");
        out.flush();
        return;
    }

    // Widths chosen once, so the header and the rows cannot drift apart.
    out.pad("address", ADDRESS);
    out.pad("id", ID);
    out.pad("class", CLASS);
    out.pad("driver", DRIVER);
    out.pad("state", STATE);
    out.text("what\n");

    var lines = str.lines(table);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = str.fields(line);

        out.pad(it.next() orelse "", ADDRESS);
        pair(it.next() orelse "", it.next() orelse "", ID);
        pair(it.next() orelse "", it.next() orelse "", CLASS);

        // The driver is named whatever became of it, and the state beside it
        // says which: this is the boot probe's table, seen from userspace, and
        // the two should not tell different stories about the same device.
        out.pad(it.next() orelse "-", DRIVER);
        out.pad(it.next() orelse "", STATE);
        out.text(it.next() orelse "");
        out.byte('\n');
    }
    out.flush();
}

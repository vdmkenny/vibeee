//! What the panel is doing, and asking it to do something else.
//!
//! Named for the thing rather than after another system's tool for it. With no
//! argument it reports; with a size it asks the adapter for that mode.

const sys = @import("sys");
const info = @import("ulib").info;
const out = @import("ulib").out;
const str = @import("ulib").str;

pub fn display(args: []const []const u8) void {
    if (args.len == 0) {
        report();
        return;
    }
    request(args[0]);
}

fn report() void {
    var buf: [128]u8 = @splat(0);

    show("mode", info.ask("display", &buf), &buf);
    show("console", info.ask("console", &buf), &buf);
    show("adapter", info.ask("display.adapter", &buf), &buf);
    show("font", info.ask("font", &buf), &buf);
    out.flush();
}

/// `ask` writes into the buffer it is given, so the value has to be printed
/// before the next question overwrites it.
fn show(label: []const u8, value: []const u8, _: []u8) void {
    if (value.len == 0) return;
    out.pad(label, 9);
    out.text(value);
    out.byte('\n');
}

/// Parse `800x480` and ask for it.
fn request(spec: []const u8) void {
    const cross = indexOfX(spec) orelse {
        out.text("usage: display [<width>x<height>]\n");
        out.flush();
        return;
    };

    const width = str.toUnsigned(spec[0..cross]);
    const height = str.toUnsigned(spec[cross + 1 ..]);

    if (width == 0 or height == 0) {
        out.text("display: not a size\n");
        out.flush();
        return;
    }

    // Zero bits per pixel means whatever the adapter prefers, which for
    // everything here is 32.
    const result = sys.setMode(@intCast(width), @intCast(height), 0);
    out.text(switch (result) {
        0 => "display: mode set\n",
        -1 => "display: no driver can set modes on this adapter; " ++
            "what the firmware left is what there is\n",
        -16 => "display: something owns the screen; close it first\n",
        -22 => "display: this adapter cannot do that size\n",
        else => "display: the adapter refused\n",
    });
    out.flush();
}

fn indexOfX(spec: []const u8) ?usize {
    for (spec, 0..) |c, i| {
        if (c == 'x' or c == 'X') return i;
    }
    return null;
}

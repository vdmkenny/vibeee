//! Interrupt lines: what userspace has taken, and taking one to try it.
//!
//! The beginning of the tooling `devmgd` will need. Which lines are attached
//! and how many interrupts each has seen is the first question anyone asks
//! when a device outside the kernel has gone quiet, and it is knowable only
//! from the kernel.

const sys = @import("sys");
const info = @import("ulib").info;
const out = @import("ulib").out;
const str = @import("ulib").str;

pub fn irq(args: []const []const u8) void {
    if (args.len == 0) {
        list();
        return;
    }
    take(str.toUnsigned(args[0]));
}

fn list() void {
    var buf: [512]u8 = @splat(0);
    const text = info.ask("irq", &buf);

    if (text.len == 0) {
        out.text("no interrupt lines are held outside the kernel\n");
        out.flush();
        return;
    }

    out.text("line  state   count\n");

    var lines = str.lines(text);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        var it = str.fields(line);

        out.decimalRight(str.toUnsigned(it.next() orelse "0"), 4);
        out.text("  ");
        out.pad(it.next() orelse "", 8);
        out.decimal(str.toUnsigned(it.next() orelse "0"));
        out.byte('\n');
    }
    out.flush();
}

/// Take a line, wait a moment, and say what arrived.
///
/// A line the kernel is already serving is refused rather than stolen: two
/// handlers on one line means whichever ran second finds it already masked.
fn take(gsi: usize) void {
    const handle = sys.irqAttach(@intCast(gsi)) catch |err| {
        out.text("irq ");
        out.decimal(gsi);
        out.text(switch (err) {
            error.Denied => ": only a driver may take a line, and this is not one\n",
            error.Busy => ": something already answers for it\n",
            error.NoLine => ": not a line this machine has\n",
            error.OutOfMemory => ": out of memory\n",
        });
        out.flush();
        return;
    };
    defer _ = sys.close(handle);

    out.text("irq ");
    out.decimal(gsi);
    out.text(": held, waiting one second\n");
    out.flush();

    // Waiting is what unmasks it. Nothing arriving is the ordinary answer for
    // a device nobody has told to do anything.
    var lines = [_]u32{handle};
    const fired = sys.waitMany(&lines, 1_000_000) >= 0;

    out.text(if (fired) "  an interrupt arrived\n" else "  quiet\n");
    if (fired) _ = sys.irqAck(handle, false);
    out.flush();
}

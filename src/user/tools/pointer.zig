//! pointer: show what the pointing device is doing.
//!
//! There is no GUI to consume pointer events yet, so this is how the driver
//! and the event path get exercised: position, buttons, wheel and whether the
//! movement is a drag, printed as it happens.
//!
//! Runs for a bounded number of events rather than until interrupted, because
//! there is no signal to interrupt it with and a program that could not be
//! stopped would be worse than one that stops on its own.

const sys = @import("sys");
const out = @import("ulib").out;
const str = @import("ulib").str;

const DEFAULT_EVENTS = 20;

pub fn run(args: []const []const u8) void {
    const wanted = if (args.len > 0) @max(str.toUnsigned(args[0]), 1) else DEFAULT_EVENTS;

    out.text("move the pointer or click; ");
    out.decimal(wanted);
    out.text(" events then exit\n\n");
    out.flush();

    var buf: [16]sys.PointerEvent = undefined;
    var seen: usize = 0;

    while (seen < wanted) {
        // Ten seconds is long enough that a slow reader is not cut off, and
        // short enough that a machine with no pointing device says so instead
        // of appearing to hang.
        const events = sys.pointerRead(&buf, 10_000_000);
        if (events.len == 0) {
            out.text("no pointer events; is a pointing device attached?\n");
            out.flush();
            return;
        }

        for (events) |event| {
            if (seen >= wanted) break;
            report(event);
            seen += 1;
        }
        out.flush();
    }
}

fn report(event: sys.PointerEvent) void {
    out.decimalRight(@intCast(@max(event.x, 0)), 4);
    out.byte(',');
    out.decimalRight(@intCast(@max(event.y, 0)), 4);
    out.text("  ");

    out.byte(if (event.buttons.left) 'L' else '.');
    out.byte(if (event.buttons.middle) 'M' else '.');
    out.byte(if (event.buttons.right) 'R' else '.');

    if (event.wheel != 0) {
        out.text(if (event.wheel > 0) "  wheel up" else "  wheel down");
    }

    // The distinction the event carries so a consumer does not have to keep
    // its own history: a button change is a click, motion with a button
    // already held is a drag.
    if (event.buttons_changed != 0) {
        out.text("  click");
    } else if (event.isDrag()) {
        out.text("  drag");
    }

    out.byte('\n');
}

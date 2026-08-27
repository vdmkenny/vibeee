//! hotkeys: the keys that do not arrive as keys.
//!
//! Two things to do with them. Without arguments, take whatever the firmware
//! has said and not yet been collected, which is what a script wants. With
//! `watch`, wait and print each one as it happens, which is what a person
//! wants when they are trying to find out what their machine sends.
//!
//! Waiting rather than asking again: the service hands out an event, so a key
//! nobody pressed costs nothing.

const ink = @import("ulib").ink;
const out = @import("ulib").out;
const platform = @import("proto").platform;
const str = @import("ulib").str;
const sys = @import("sys");

pub fn run(args: []const []const u8) void {
    const watching = args.len > 0 and str.eql(args[0], "watch");

    if (!watching) {
        if (drain() == 0) out.text("nothing pressed\n");
        out.flush();
        return;
    }

    const event = platform.watchHotkeys() catch {
        out.text("hotkeys: the platform service is not answering\n");
        out.flush();
        return;
    };
    defer _ = sys.close(event);

    out.text("listening; nothing here reaches the keyboard\n");
    out.flush();

    while (true) {
        _ = drain();
        out.flush();
        _ = sys.waitMany(&.{event}, sys.FOREVER);
    }
}

/// Everything waiting, and how much that was.
fn drain() usize {
    var seen: usize = 0;

    while (true) {
        var press = platform.Press{};
        platform.nextHotkey(&press) catch |err| {
            if (err != error.End and seen == 0) {
                out.text("hotkeys: the platform service is not answering\n");
            }
            return seen;
        };
        show(press);
        seen += 1;
    }
}

fn show(press: platform.Press) void {
    // The number and the device stay visible even for a key that is
    // recognised. They are what a person needs to see when the meaning turns
    // out to be wrong on their machine, and hiding them once it works is how
    // the next machine becomes a mystery.
    ink.use(if (press.hotkey == .unknown) .warn else .accent);
    out.pad(press.hotkey.label(), 20);
    ink.plain();

    const device = press.sender();
    if (device.len == 0) {
        // A fixed event: the chipset raised it, and there is no device that
        // sent it and no number it sent.
        out.text(" chipset\n");
        return;
    }

    out.text(" ");
    out.text(device);
    out.text("  0x");
    out.hex(press.value, 2);
    out.byte('\n');
}

//! hw: the parts of the machine the firmware can switch, and switching them.
//!
//! A netbook of this age powers parts of itself down to save a battery, and a
//! part that is off is on no bus at all: it is not a device that failed to
//! bind, it is a device the machine is not currently carrying. Nothing else
//! says so, which is why this exists. A camera missing from `usb` and a radio
//! missing from `devices` look exactly like hardware that is broken, and one
//! line here tells the two apart.
//!
//!   hw              what this machine can switch, and how each stands
//!   hw <part>       just that one
//!   hw <part> on    switch it on
//!   hw <part> off   switch it off

const ink = @import("ulib").ink;
const out = @import("ulib").out;
const platform = @import("proto").platform;
const std = @import("std");

pub fn run(args: []const []const u8) void {
    if (args.len == 0) return list();

    const which = std.meta.stringToEnum(platform.Feature, args[0]) orelse {
        out.text("no part of this machine is called that; `hw` lists them\n");
        out.flush();
        return;
    };

    if (args.len == 1) return show(which, platform.feature(which, null));

    const on = switching(args[1]) orelse {
        out.text("say on or off\n");
        out.flush();
        return;
    };
    show(which, platform.setFeature(which, null, on));
}

fn switching(word: []const u8) ?bool {
    if (std.mem.eql(u8, word, "on")) return true;
    if (std.mem.eql(u8, word, "off")) return false;
    return null;
}

fn list() void {
    var any = false;
    for (std.enums.values(platform.Feature)) |which| {
        const state = platform.feature(which, null);
        if (!state.isPresent()) continue;
        show(which, state);
        any = true;
    }

    if (!any) out.text("this machine offers no way to switch any of its parts\n");
    out.flush();
}

/// What it is doing, or that nothing here can say. A part this machine cannot
/// switch is not a refusal and should not read as one.
fn show(which: platform.Feature, state: platform.FeatureState) void {
    out.text(@tagName(which));
    out.text("  ");
    if (!state.isPresent()) {
        ink.use(.dim);
        out.text("not switchable here\n");
    } else if (state.isOn()) {
        ink.use(.good);
        out.text("on\n");
    } else {
        ink.use(.dim);
        out.text("off\n");
    }
    ink.plain();
    out.flush();
}

//! thermal: how hot the machine is, and what the firmware will do about it.
//!
//! Every zone the firmware describes, what it reads now, and the two
//! temperatures it acts on: the one where it wants the machine slowed, and
//! the one where it cuts the power. A zone that names neither is one the
//! firmware watches without telling anybody how.

const ink = @import("ulib").ink;
const style = @import("lib").style;
const out = @import("ulib").out;
const platform = @import("proto").platform;

pub fn run(_: []const []const u8) void {
    var index: u8 = 0;
    var found = false;

    while (index < platform.Thermal.MAX_ZONES) : (index += 1) {
        const zone = platform.thermal(index) orelse break;
        if (!found) {
            out.text("zone      now   passive  critical\n");
            found = true;
        }

        out.pad(zone.named(), 10);
        temperature(zone.now, .accent);
        out.text("  ");
        temperature(zone.passive, .dim);
        out.text("  ");
        temperature(zone.critical, .warn);
        out.text("\n");
    }

    if (!found) out.text("this machine reports no thermal zones\n");
    out.flush();
}

/// A reading in whole degrees with its tenth, or a dash for one the firmware
/// did not give: a blank column and a zero are different answers.
fn temperature(value: i32, colour: style.Role) void {
    if (!platform.Thermal.known(value)) {
        ink.use(.dim);
        out.pad("-", 8);
        ink.plain();
        return;
    }

    ink.use(colour);
    out.decimal(@intCast(@divTrunc(value, 10)));
    out.text(".");
    out.decimal(@intCast(@mod(@abs(value), 10)));
    out.text(" C");
    ink.plain();
}

//! backlight: how bright the panel is, and making it otherwise.
//!
//! Levels rather than a percentage. The number of steps belongs to the panel,
//! and rounding a percentage onto sixteen of them would make some of them
//! unreachable: asking for 50 and 53 would land on the same step while 7 and 8
//! are a real difference. The percentage is shown alongside for reading.

const ink = @import("ulib").ink;
const out = @import("ulib").out;
const platform = @import("proto").platform;
const str = @import("ulib").str;

pub fn run(args: []const []const u8) void {
    const asked = if (args.len > 0) str.toUnsigned(args[0]) else null;
    const panel = (if (asked) |level| platform.setBacklight(level) else platform.backlight()) orelse {
        out.text("this machine offers no way to set the backlight\n");
        out.flush();
        return;
    };

    // What came back, not what was asked for: a level the firmware clamped is
    // one the caller should see clamped.
    ink.use(.accent);
    out.decimal(panel.level);
    ink.plain();
    out.text(" of ");
    out.decimal(panel.max);
    out.text("  (");
    out.decimal(panel.percent());
    out.text("%)\n");
    out.flush();
}

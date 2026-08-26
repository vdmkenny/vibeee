//! date — print the wall-clock time, and say where it came from.
//!
//! The provenance line is not decoration. On a machine whose CMOS battery
//! died nineteen years ago, "the clock says 2026 because the RTC said so" and
//! "the clock says 2026 because nothing has set it" are the difference between
//! trusting a file's timestamp and not, and the user is the only one who can
//! tell which is which.

const sys = @import("../syscall.zig");
const out = @import("../lib/out.zig");
const info = @import("../lib/info.zig");
const str = @import("../lib/str.zig");
const time = @import("../lib/time.zig");

pub fn run(args: []const []const u8) void {
    const seconds = blk: {
        const us = sys.realtimeMicros() orelse {
            out.text("date: the clock has not been set\n");
            out.text("      no working real-time clock was found at boot; file\n");
            out.text("      timestamps will be wrong until one is\n");
            out.flush();
            return;
        };
        break :blk @divFloor(us, 1_000_000);
    };

    if (args.len > 0 and (str.eql(args[0], "epoch") or str.eql(args[0], "-e"))) {
        // The raw number, for scripting and for checking the conversion.
        out.decimal(@intCast(seconds));
        out.byte('\n');
        out.flush();
        return;
    }

    time.writeStamp(seconds);
    out.text(" UTC\n");

    var buf: [64]u8 = @splat(0);
    const source = info.ask("clock", &buf);
    if (source.len > 0) {
        out.text("source  ");
        out.text(source);
        out.byte('\n');
    }

    out.flush();
}

//! date, print the wall-clock time, and say where it came from.
//!
//! The provenance line is not decoration. On a machine whose CMOS battery
//! died nineteen years ago, "the clock says 2026 because the RTC said so" and
//! "the clock says 2026 because nothing has set it" are the difference between
//! trusting a file's timestamp and not, and the user is the only one who can
//! tell which is which.

const std = @import("std");
const settings = @import("proto").settings;
const sys = @import("sys");
const out = @import("ulib").out;
const info = @import("ulib").info;
const time = @import("ulib").time;

pub fn run(args: []const []const u8) void {
    // `date sync` asks the time service to go and find out now, rather than
    // waiting for its next hour. What the GUI's clock can be told, a command
    // can tell it.
    if (args.len > 0 and std.mem.eql(u8, args[0], "sync")) return sync();


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

    if (args.len > 0 and (std.mem.eql(u8, args[0], "epoch") or std.mem.eql(u8, args[0], "-e"))) {
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

/// Ask the time service for a fresh reading and wait for the answer.
///
/// The service is nudged through its settings watch: writing the domain it is
/// watching is what wakes it, and it re-reads and asks straight away. That is
/// one mechanism rather than a second channel for one verb.
fn sync() void {
    const before = sys.realtimeMicros();

    const current = settings.load("time");
    settings.set("time.ntp", if (current.ntp) "true" else "false") catch {
        out.text("date: the settings service is not answering\n");
        out.flush();
        return;
    };

    out.text("asking the time servers");
    out.flush();

    // A public pool answers in well under a second; three is the service's
    // own patience per server, and it has three servers to try.
    var waited: usize = 0;
    while (waited < 10_000_000) : (waited += 250_000) {
        sys.sleepMicros(250_000);
        const now = sys.realtimeMicros();
        if (now != null and (before == null or now.? != before.?)) {
            out.text("\n");
            time.writeStamp(@divFloor(now.?, 1_000_000));
            out.text("\n");
            out.flush();
            return;
        }
        out.text(".");
        out.flush();
    }

    out.text("\ndate: no time server answered; `log timed` says what happened\n");
    out.flush();
}

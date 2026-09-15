//! check: compare a volume against itself, and repair what can be.
//!
//! The command behind what `mount` does by itself on a volume that was not
//! unmounted cleanly. See `fat/check.zig` for what is compared.
//!
//!   check /home        repair what can be repaired
//!   check -n /home     say what is wrong and change nothing

const std = @import("std");
const abi = @import("lib").syscalls;
const out = @import("ulib").out;
const sys = @import("sys");

pub fn run(args: []const []const u8) void {
    var flags = abi.CheckFlags{};
    var rest = args;
    while (rest.len > 0 and std.mem.startsWith(u8, rest[0], "-")) {
        if (std.mem.eql(u8, rest[0], "-n")) {
            flags.report_only = true;
        } else {
            return usage();
        }
        rest = rest[1..];
    }
    if (rest.len != 1) return usage();

    const path = rest[0];
    const report = sys.checkVolume(path, flags) catch |err| {
        out.fault("check", path, describe(err));
        out.flush();
        return;
    };

    if (report.quiet()) {
        out.text(path);
        out.text(": nothing to put right\n");
        out.flush();
        return;
    }

    out.text(path);
    out.text(":\n");

    say(report.lost, "clusters nothing pointed at");
    say(report.reclaimed, "of those given back");
    say(report.trimmed, "chains cut back to their record");
    say(report.resized, "records brought down to their chain");
    say(report.broken, "chains that left the volume or looped");
    say(report.mirrored, "table sectors brought back into step");
    say(report.crossed, "clusters claimed twice, which were left alone");
    say(report.too_deep, "directories too deeply nested to walk");

    if (!report.sound()) {
        out.text(path);
        out.text(" is mounted read-only: repair it on another machine\n");
    } else if (flags.report_only) {
        out.text("nothing was changed\n");
    }
    out.flush();
}

fn say(count: u32, what: []const u8) void {
    if (count == 0) return;
    out.text("  ");
    out.decimal(count);
    out.byte(' ');
    out.text(what);
    out.byte('\n');
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NotFound => "nothing is mounted there",
        error.Busy => "something on it is open",
        error.NoMemory => "not enough memory to walk it",
        error.Denied => "only a program that may mount may check",
        else => @errorName(err),
    };
}

fn usage() void {
    out.text("usage: check [-n] <mount point>\n");
    out.flush();
}

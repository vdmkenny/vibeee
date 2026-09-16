//! check: check a mounted volume and repair it. See `fat/check.zig`.
//!
//!   check /home        check and repair
//!   check -n /home     report only

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
        out.text(": clean\n");
        out.flush();
        return;
    }

    out.text(path);
    out.text(":\n");

    say(report.lost, "lost clusters");
    say(report.reclaimed, "clusters freed");
    say(report.trimmed, "chains trimmed");
    say(report.resized, "sizes corrected");
    say(report.broken, "broken chains");
    say(report.mirrored, "FAT sectors resynchronised");
    say(report.crossed, "cross-linked clusters, not repaired");
    say(report.too_deep, "directories too deep to check");

    if (!report.sound()) {
        out.text(path);
        out.text(": read-only until repaired on another system\n");
    } else if (flags.report_only) {
        out.text("no changes made\n");
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

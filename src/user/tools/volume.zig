//! format and grow: making a filesystem, and extending one.
//!
//!   format hd0p3          make a new filesystem, choosing the width
//!   format -t fat16 sd1   make one of a named width
//!   grow hd0p3            extend the filesystem over the whole volume
//!   grow -n hd0p3         say what growing would come to, and stop
//!
//! Both refuse a mounted volume. Both ask before writing, because format
//! destroys what is there and grow can lose it if power is cut part way.

const std = @import("std");
const abi = @import("lib").syscalls;
const out = @import("ulib").out;
const sys = @import("sys");

pub fn format(args: []const []const u8) void {
    var flags = abi.FormatFlags{};
    var rest = args;
    while (rest.len > 1 and std.mem.startsWith(u8, rest[0], "-")) {
        if (std.mem.eql(u8, rest[0], "-t")) {
            if (rest.len < 3) return formatUsage();
            flags.kind = widthNamed(rest[1]) orelse return formatUsage();
            rest = rest[2..];
        } else {
            return formatUsage();
        }
    }
    if (rest.len != 1) return formatUsage();

    const volume = rest[0];
    out.text("format ");
    out.text(volume);
    out.text(": everything on it becomes unreachable.\n");
    if (!confirmed(volume)) return;

    sys.formatVolume(volume, flags) catch |err| {
        out.fault("format", volume, describe(err));
        out.flush();
        return;
    };
    out.text(volume);
    out.text(": a new filesystem, empty\n");
    out.flush();
}

pub fn grow(args: []const []const u8) void {
    var only_say = false;
    var rest = args;
    while (rest.len > 1 and std.mem.startsWith(u8, rest[0], "-")) {
        if (std.mem.eql(u8, rest[0], "-n")) {
            only_say = true;
        } else {
            return growUsage();
        }
        rest = rest[1..];
    }
    if (rest.len != 1) return growUsage();

    const volume = rest[0];
    if (only_say) {
        // Nothing here can say what a grow would come to without doing it:
        // the kernel plans and applies under one lock, so that a volume
        // cannot be mounted in between.
        out.text("grow -n is not available: ask for the grow itself\n");
        out.flush();
        return;
    }

    out.text("grow ");
    out.text(volume);
    out.text(": data moves. Losing power part way leaves it unreadable.\n");
    if (!confirmed(volume)) return;

    const report = sys.growVolume(volume) catch |err| {
        out.fault("grow", volume, describe(err));
        out.flush();
        return;
    };

    out.text(volume);
    out.text(": ");
    out.decimal(report.was);
    out.text(" clusters became ");
    out.decimal(report.now);
    if (report.moved != 0) {
        out.text(", and ");
        out.decimal(report.moved);
        out.text(" moved");
    }
    out.byte('\n');
    out.flush();
}

/// Ask, and take nothing but the volume's own name for an answer.
///
/// A name rather than a letter: both of these are asked for once and are not
/// undone, and typing what is about to be written to is the difference
/// between meaning it and pressing a key.
fn confirmed(volume: []const u8) bool {
    out.text("type its name to go ahead: ");
    out.flush();

    var buf: [64]u8 = undefined;
    const got = sys.read(sys.STDIN, &buf) catch 0;
    const typed = std.mem.trim(u8, buf[0..got], " \t\r\n");
    if (std.mem.eql(u8, typed, volume)) return true;

    out.text("left alone\n");
    out.flush();
    return false;
}

fn widthNamed(name: []const u8) ?abi.FatKind {
    if (std.mem.eql(u8, name, "fat12")) return .fat12;
    if (std.mem.eql(u8, name, "fat16")) return .fat16;
    if (std.mem.eql(u8, name, "fat32")) return .fat32;
    return null;
}

fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.NotFound => "no volume of that name",
        error.Busy => "it is mounted; unmount it first",
        error.Invalid => "too small, already full, or past what its width can address",
        error.NoMemory => "not enough memory",
        error.Denied => "only a program that may mount may do this",
        else => @errorName(err),
    };
}

fn formatUsage() void {
    out.text("usage: format [-t fat12|fat16|fat32] <volume>\n");
    out.flush();
}

fn growUsage() void {
    out.text("usage: grow <volume>\n");
    out.flush();
}

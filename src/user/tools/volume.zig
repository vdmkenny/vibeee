//! format and grow.
//!
//!   format hd0p1          make a new filesystem, width chosen by size
//!   format -t fat16 usb0  make one of a named width
//!   grow usb0p3           extend the partition and filesystem over free space
//!
//! Both refuse a mounted volume. Both ask for the volume's name before writing:
//! format destroys the contents, and grow loses them on a power cut.

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
    out.text(": all data on it will be lost\n");
    if (!confirmed(volume)) return;

    sys.formatVolume(volume, flags) catch |err| {
        out.fault("format", volume, describe(err));
        out.flush();
        return;
    };
    out.text(volume);
    out.text(": formatted\n");
    out.flush();
}

pub fn grow(args: []const []const u8) void {
    if (args.len != 1) return growUsage();

    const volume = args[0];
    out.text("grow ");
    out.text(volume);
    out.text(": data will move; power loss during the move destroys the volume\n");
    if (!confirmed(volume)) return;

    const report = sys.growVolume(volume) catch |err| {
        out.fault("grow", volume, describe(err));
        out.flush();
        return;
    };

    out.text(volume);
    out.text(": ");
    out.decimal(report.was);
    out.text(" to ");
    out.decimal(report.now);
    out.text(" clusters");
    if (report.moved != 0) {
        out.text(", ");
        out.decimal(report.moved);
        out.text(" moved");
    }
    out.byte('\n');
    out.flush();
}

/// Ask for the volume's name. Anything else cancels.
fn confirmed(volume: []const u8) bool {
    out.text("type the volume name to continue: ");
    out.flush();

    var buf: [64]u8 = undefined;
    const got = sys.read(sys.STDIN, &buf) catch 0;
    const typed = std.mem.trim(u8, buf[0..got], " \t\r\n");
    if (std.mem.eql(u8, typed, volume)) return true;

    out.text("cancelled\n");
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

//! eeefetch — system information, in the neofetch tradition.
//!
//! Everything shown comes from the kernel's `sysinfo` interface rather than
//! from files the tool assumes exist, so it works on a system with no /proc and
//! keeps working as the kernel learns to report more.

const sys = @import("../syscall.zig");
const out = @import("../lib/out.zig");
const info = @import("../lib/info.zig");
const logo = @import("lib").logo;
const str = @import("../lib/str.zig");

const Row = struct { label: []const u8, key: []const u8 };

/// Order matters: identity first, then what the machine is, then what it is
/// doing. Anything the kernel cannot answer is skipped rather than shown empty.
const rows = [_]Row{
    .{ .label = "board", .key = "board" },
    .{ .label = "bios", .key = "bios" },
    .{ .label = "kernel", .key = "kernel" },
    .{ .label = "arch", .key = "arch" },
    .{ .label = "cpu", .key = "cpu" },
    .{ .label = "", .key = "cpu.features" },
    .{ .label = "memory", .key = "mem" },
    .{ .label = "", .key = "mem.hardware" },
    .{ .label = "display", .key = "display" },
    .{ .label = "", .key = "console" },
    .{ .label = "font", .key = "font" },
    .{ .label = "keymap", .key = "keymap" },
    .{ .label = "storage", .key = "storage" },
    .{ .label = "mounts", .key = "mounts" },
};

pub fn run(_: []const []const u8) void {
    var buf: [512]u8 = undefined;

    for (logo.lines) |line| {
        out.text(line);
        out.text("\n");
    }

    for (rows) |row| {
        const value = info.ask(row.key, &buf);
        if (value.len == 0) continue;

        // Multi-line values (storage, mounts) are indented under their label so
        // the columns still line up.
        var it = str.lines(value);
        var first = true;
        while (it.next()) |line| {
            if (line.len == 0) continue;
            emit(if (first) row.label else "", line);
            first = false;
        }
    }

    // Uptime last, formatted rather than raw: seconds since boot is not what a
    // reader wants to see.
    const uptime = info.ask("uptime", &buf);
    if (uptime.len > 0) {
        const seconds = str.toUnsigned(uptime);
        out.text(" ");
        out.pad("uptime", 9);
        writeDuration(seconds);
        out.text("\n");
    }

    out.flush();
}

fn emit(label: []const u8, value: []const u8) void {
    out.text(" ");
    out.pad(label, 9);
    out.text(value);
    out.text("\n");
}

fn writeDuration(total: usize) void {
    const hours = total / 3600;
    const minutes = (total % 3600) / 60;
    const seconds = total % 60;

    if (hours > 0) {
        out.decimal(hours);
        out.text("h ");
    }
    if (hours > 0 or minutes > 0) {
        out.decimal(minutes);
        out.text("m ");
    }
    out.decimal(seconds);
    out.text("s");
}


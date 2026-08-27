//! eeefetch, system information, in the neofetch tradition.
//!
//! Everything shown comes from the kernel's `sysinfo` interface rather than
//! from files the tool assumes exist, so it works on a system with no /proc and
//! keeps working as the kernel learns to report more.

const ink = @import("ulib").ink;
const out = @import("ulib").out;
const info = @import("ulib").info;
const logo = @import("lib").logo;
const str = @import("ulib").str;

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
    .{ .label = "syscall", .key = "syscall" },
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

    // The same colour the kernel drew it in at boot, by the same role: this
    // is the machine saying its own name, twice.
    for (logo.lines) |line| {
        ink.write(.key, line);
        out.byte('\n');
    }

    ink.write(.value, "vibeee");
    ink.use(.dim);
    out.text("  ");
    out.text(info.ask("arch", &buf));
    ink.plain();
    out.text("\n\n");

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
        out.byte(' ');
        ink.write(.key, "uptime   ");
        writeDuration(seconds);
        out.text("\n");
    }

    out.flush();
}

/// A label and what it is worth. The label carries the colour, which is the
/// boot log's arrangement: one coloured word to scan down, and the values
/// plain so they are read rather than scanned.
fn emit(label: []const u8, value: []const u8) void {
    out.byte(' ');

    var padded: [LABEL]u8 = @splat(' ');
    @memcpy(padded[0..@min(label.len, LABEL)], label[0..@min(label.len, LABEL)]);
    ink.write(.key, &padded);

    out.text(value);
    out.byte('\n');
}

/// Width of the label column, so `emit` and the uptime line below cannot drift
/// apart about where the values start.
const LABEL = 9;

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


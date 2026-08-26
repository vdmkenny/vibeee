//! System information, addressed by key.
//!
//! A keyed text interface rather than a struct-returning syscall: the set of
//! things worth reporting grows constantly, and a struct means an ABI break
//! every time it does. Text costs a little formatting and lets a tool ask for
//! something the kernel did not exist to answer when the tool was written.
//!
//! This is where a `/sys` filesystem would go on a system that had one. It does
//! not, so the same idea is expressed as a syscall — and the shape is
//! deliberately close enough that turning it into files later changes the
//! plumbing rather than the meaning.

const std = @import("std");
const block = @import("block.zig");
const console = @import("console.zig");
const hal = @import("hal.zig");
const heap = @import("heap.zig");
const keymap = @import("keymap.zig");
const pmm = @import("pmm.zig");
const sched = @import("sched.zig");
const vfs = @import("vfs.zig");

pub const VERSION = "0.1.0-M0";

/// Filled in by the composition root, which is the only place that may know
/// about firmware tables and drivers at once.
pub const Platform = struct {
    system_manufacturer: ?[]const u8 = null,
    system_product: ?[]const u8 = null,
    bios_vendor: ?[]const u8 = null,
    bios_version: ?[]const u8 = null,
    /// Raw SMBIOS structure table, for a userspace decoder.
    smbios_table: ?[]const u8 = null,
    video: ?[]const u8 = null,
};

var platform: Platform = .{};

pub fn setPlatform(p: Platform) void {
    platform = p;
}

pub const Error = error{ UnknownKey, NoSpace };

/// Write the value for `key` into `buf`, returning the number of bytes.
pub fn query(key: []const u8, buf: []u8) Error!usize {
    var w = Writer{ .buf = buf };

    if (eq(key, "kernel")) {
        try w.print("vibeee {s}", .{VERSION});
    } else if (eq(key, "arch")) {
        try w.print("{s}", .{@tagName(@import("builtin").cpu.arch)});
    } else if (eq(key, "cpu")) {
        const info = hal.cpuInfo();
        try w.print("{s}", .{info.brand});
    } else if (eq(key, "cpu.features")) {
        const info = hal.cpuInfo();
        try w.print("{s}, {s}", .{
            if (info.fast_syscall) "sysenter" else "int80",
            if (info.freq_scaling) "freq scaling" else "fixed clock",
        });
    } else if (eq(key, "mem")) {
        const m = pmm.stats();
        try w.print("{d}/{d} MiB used", .{
            (m.totalBytes() - m.freeBytes()) / (1024 * 1024),
            m.totalBytes() / (1024 * 1024),
        });
    } else if (eq(key, "mem.total")) {
        try w.print("{d}", .{pmm.stats().totalBytes()});
    } else if (eq(key, "mem.free")) {
        try w.print("{d}", .{pmm.stats().freeBytes()});
    } else if (eq(key, "heap")) {
        const h = heap.stats();
        try w.print("{d} bytes live, {d} frames", .{ h.live_bytes, h.frames });
    } else if (eq(key, "uptime")) {
        try w.print("{d}", .{hal.monotonicMicros() / 1_000_000});
    } else if (eq(key, "threads")) {
        try w.print("{d}", .{sched.stats().threads});
    } else if (eq(key, "video")) {
        try w.print("{s}", .{platform.video orelse "unknown"});
    } else if (eq(key, "console")) {
        try w.print("{d}x{d}, {s}", .{ console.width(), console.height(), console.fontName() });
    } else if (eq(key, "keymap")) {
        try w.print("{s}", .{keymap.current().name});
    } else if (eq(key, "board")) {
        try w.print("{s} {s}", .{
            platform.system_manufacturer orelse "unknown",
            platform.system_product orelse "",
        });
    } else if (eq(key, "bios")) {
        try w.print("{s} {s}", .{
            platform.bios_vendor orelse "unknown",
            platform.bios_version orelse "",
        });
    } else if (eq(key, "storage")) {
        try writeStorage(&w);
    } else if (eq(key, "mounts")) {
        try writeMounts(&w);
    } else if (eq(key, "smbios")) {
        const table = platform.smbios_table orelse return error.UnknownKey;
        if (table.len > buf.len) return error.NoSpace;
        @memcpy(buf[0..table.len], table);
        return table.len;
    } else {
        return error.UnknownKey;
    }

    return w.len;
}

fn writeStorage(w: *Writer) Error!void {
    var first = true;
    for (block.list()) |*dev| {
        if (dev.offset != 0) continue; // whole devices only
        if (!first) try w.print("\n", .{});
        first = false;
        try w.print("{s} {d} MiB", .{ dev.name, dev.bytes() / (1024 * 1024) });
    }
    if (first) try w.print("none", .{});
}

fn writeMounts(w: *Writer) Error!void {
    var first = true;
    for (vfs.list()) |*m| {
        if (!m.in_use) continue;
        if (!first) try w.print("\n", .{});
        first = false;
        try w.print("{s} on {s}", .{ m.path(), m.device.name });
    }
    if (first) try w.print("none", .{});
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Bounded writer: truncating a report is better than failing it, but the
/// caller still needs to know the buffer was too small for `smbios`.
const Writer = struct {
    buf: []u8,
    len: usize = 0,

    fn print(self: *Writer, comptime fmt: []const u8, args: anytype) Error!void {
        var stream = std.Io.Writer.fixed(self.buf[self.len..]);
        stream.print(fmt, args) catch return error.NoSpace;
        self.len += stream.end;
    }
};

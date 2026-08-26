//! System information, addressed by key.
//!
//! A keyed text interface rather than a struct-returning syscall: the set of
//! things worth reporting grows constantly, and a struct means an ABI break
//! every time it does. Text costs a little formatting and lets a tool ask for
//! something the kernel did not exist to answer when the tool was written.
//!
//! This is where a `/sys` filesystem would go on a system that had one. It does
//! not, so the same idea is expressed as a syscall, and the shape is
//! deliberately close enough that turning it into files later changes the
//! plumbing rather than the meaning.

const std = @import("std");
const block = @import("block.zig");
const console = @import("console.zig");
const display = @import("display.zig");
const hal = @import("hal.zig");
const clock = @import("clock.zig");
const heap = @import("heap.zig");
const irqevent = @import("irqevent.zig");
const keymap = @import("keymap.zig");
const klog = @import("klog.zig");
const pmm = @import("pmm.zig");
const probe = @import("probe.zig");
const sched = @import("sched.zig");
const svc = @import("svc.zig");
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

    /// What the firmware says is physically fitted, which is not the same as
    /// what the allocator ended up with.
    ram_total_mb: u32 = 0,
    ram_devices: u8 = 0,
    ram_speed_mhz: u16 = 0,
    ram_type: []const u8 = "",

    /// Display mode, when a framebuffer is running.
    fb_width: u16 = 0,
    fb_height: u16 = 0,
    fb_bpp: u8 = 0,
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
    } else if (eq(key, "syscall")) {
        // What the kernel armed, not what the CPU can do. A stub that chose
        // from CPUID alone would use a fast path whose MSRs were never
        // programmed, and jump to nothing.
        try w.print("{s}", .{if (hal.fastSyscallArmed()) "sysenter" else "int80"});
    } else if (eq(key, "cpu.features")) {
        const info = hal.cpuInfo();
        try w.print("{s}, {s}", .{
            if (info.fast_syscall) "sysenter" else "int80",
            if (info.freq_scaling) "freq scaling" else "fixed clock",
        });
    } else if (eq(key, "mem")) {
        const m = pmm.stats();
        const total = m.totalBytes() / (1024 * 1024);
        const used = (m.totalBytes() - m.freeBytes()) / (1024 * 1024);
        try w.print("{d} MiB used / {d} MiB", .{ used, total });

        // The firmware's figure is worth showing when it differs: the gap is
        // memory the map reserved, and seeing it beats wondering where it went.
        if (platform.ram_total_mb != 0 and platform.ram_total_mb != total) {
            try w.print(" ({d} MiB fitted)", .{platform.ram_total_mb});
        }
    } else if (eq(key, "mem.total")) {
        try w.print("{d}", .{pmm.stats().totalBytes()});
    } else if (eq(key, "mem.free")) {
        try w.print("{d}", .{pmm.stats().freeBytes()});
    } else if (eq(key, "heap")) {
        const h = heap.stats();
        try w.print("{d} bytes live, {d} frames", .{ h.live_bytes, h.frames });
    } else if (eq(key, "uptime")) {
        try w.print("{d}", .{clock.monotonicMicros() / 1_000_000});
    } else if (eq(key, "svc")) {
        try writeServices(&w);
    } else if (eq(key, "clock")) {
        if (!clock.valid()) return error.UnknownKey;
        try w.print("{s}", .{clock.sourceName()});
    } else if (eq(key, "threads")) {
        try w.print("{d}", .{sched.stats().threads});
    } else if (eq(key, "mem.hardware")) {
        if (platform.ram_devices == 0) return error.UnknownKey;
        try w.print("{d} MiB", .{platform.ram_total_mb});
        if (platform.ram_type.len > 0) try w.print(" {s}", .{platform.ram_type});
        if (platform.ram_speed_mhz != 0) try w.print("-{d}", .{platform.ram_speed_mhz});
        try w.print(", {d} module{s}", .{
            platform.ram_devices,
            if (platform.ram_devices == 1) "" else "s",
        });
    } else if (eq(key, "display")) {
        if (platform.fb_width != 0) {
            try w.print("{d}x{d} {d}bpp", .{ platform.fb_width, platform.fb_height, platform.fb_bpp });
        } else {
            try w.print("text mode", .{});
        }
    } else if (eq(key, "display.adapter")) {
        const a = display.describeAdapter();
        if (a.backend.len == 0) {
            try w.print("unrecognised, using the firmware's mode", .{});
        } else {
            try w.print("{s} ({s}), {s}", .{
                a.backend,
                a.family,
                if (a.can_set) "can set modes" else "no modeset yet",
            });
        }
    } else if (eq(key, "console")) {
        try w.print("{d}x{d} cells", .{ console.width(), console.height() });
    } else if (eq(key, "font")) {
        try w.print("{s}", .{console.fontName()});
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
    } else if (eq(key, "irq")) {
        try writeIrqs(&w);
    } else if (eq(key, "threads.list")) {
        try writeThreads(&w);
    } else if (eq(key, "pci")) {
        try writeDevices(&w);
    } else if (eq(key, "disks")) {
        try writeDisks(&w);
    } else if (eq(key, "storage")) {
        try writeStorage(&w);
    } else if (eq(key, "mounts")) {
        try writeMounts(&w);
    } else if (eq(key, "log")) {
        // Copied straight out rather than formatted: it is already text, and
        // the ring is larger than the writer's idea of a line.
        const n = klog.copyOut(buf);
        if (n == 0) return error.UnknownKey;
        return n;
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

/// One line per registered service. The registry is the map of what is running
/// and answerable, which is the first thing worth knowing when something that
/// should respond does not.
fn writeServices(w: *Writer) Error!void {
    var first = true;
    for (svc.list()) |name| {
        if (!first) try w.print("\n", .{});
        try w.print("{s}", .{name});
        first = false;
    }
    if (first) return error.UnknownKey;
}

/// One line per thread: id, parent, state, priority, ticks, name, running.
///
/// The parent is included so a display can draw the process tree. Which
/// process started which is most of what a supervisor's user wants to know,
/// and it is knowable only here.
fn writeThreads(w: *Writer) Error!void {
    const Ctx = struct {
        w: *Writer,
        failed: bool = false,

        fn visit(self: *@This(), t: sched.Snapshot) void {
            if (self.failed) return;
            self.w.print("{d}\t{d}\t{s}\t{d}\t{d}\t{s}\t{d}\n", .{
                t.id,
                t.parent_id,
                @tagName(t.state),
                t.priority,
                t.cpu_ticks,
                t.name,
                @intFromBool(t.is_current),
            }) catch {
                // Truncate rather than fail: a partial list is more use than
                // none, and the caller can ask for a bigger buffer.
                self.failed = true;
            };
        }
    };

    var ctx = Ctx{ .w = w };
    sched.forEachThread(&ctx, Ctx.visit);
}

/// One line per device on the bus: where it is, what it is, and what claimed
/// it. The table the device manager matches its manifests against, and the one
/// anyone porting to an unfamiliar machine reads first.
fn writeDevices(w: *Writer) Error!void {
    const Ctx = struct {
        w: *Writer,
        any: bool = false,

        fn visit(self: *@This(), b: probe.Binding) void {
            self.any = true;
            self.w.print("{x:0>2}:{x:0>2}.{d}\t{x:0>4}\t{x:0>4}\t{x:0>2}\t{x:0>2}\t{s}\t{s}\n", .{
                b.dev.location[0],
                b.dev.location[1],
                b.dev.location[2],
                b.dev.vendor,
                b.dev.device,
                b.dev.class,
                b.dev.subclass,
                // Named only when something actually took the device. A probe
                // entry with no attach is a placeholder for a driver that has
                // not been written, and reporting it as the owner would stop
                // the device manager from offering the device to one that has.
                if (b.attached) (if (b.driver) |d| d.name else "-") else "-",
                b.dev.description,
            }) catch {};
        }
    };

    var ctx = Ctx{ .w = w };
    probe.forEachDevice(&ctx, Ctx.visit);
    if (!ctx.any) return error.UnknownKey;
}

/// One line per interrupt a userspace driver has taken: line, state, count.
///
/// The map of which device is being served from outside the kernel, which is
/// the first thing worth knowing when one has gone quiet.
fn writeIrqs(w: *Writer) Error!void {
    const Ctx = struct {
        w: *Writer,
        any: bool = false,

        fn visit(self: *@This(), line: irqevent.Snapshot) void {
            self.any = true;
            self.w.print("{d}\t{s}\t{d}\n", .{
                line.gsi,
                if (line.held) "held" else if (line.armed) "armed" else "masked",
                line.count,
            }) catch {};
        }
    };

    var ctx = Ctx{ .w = w };
    irqevent.forEach(&ctx, Ctx.visit);
    if (!ctx.any) return error.UnknownKey;
}

/// Storage described the way a person would ask about it, not the way the
/// block layer stores it: each whole disk, then the volumes on it.
fn writeDisks(w: *Writer) Error!void {
    for (block.list(), 0..) |*dev, i| {
        if (dev.offset != 0) continue;

        try w.print("{s}\t{d}\t{s}\n", .{
            dev.name,
            dev.bytes(),
            if (dev.read_only) "read-only" else "read-write",
        });

        // Partitions carry their parent's context pointer, so they are matched
        // by name prefix rather than by identity.
        for (block.list()) |*part| {
            if (part.offset == 0) continue;
            if (!std.mem.startsWith(u8, part.name, dev.name)) continue;

            var mounted_at: []const u8 = "";
            for (vfs.list()) |*m| {
                if (m.in_use and std.mem.eql(u8, m.device.name, part.name)) {
                    mounted_at = m.path();
                }
            }

            try w.print("  {s}\t{d}\t{s}\n", .{ part.name, part.bytes(), mounted_at });
        }
        _ = i;
    }
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

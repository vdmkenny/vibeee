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
const str = @import("lib").str;
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
const builtin = @import("builtin");
const svc = @import("svc.zig");
const vfs = @import("vfs.zig");
const quirks = @import("../quirks/quirks.zig");

/// What this kernel is, and what it was built for.
///
/// The architecture comes from the compiler rather than from a build flag,
/// so it is what the binary actually is: a kernel that says x86 while
/// running on ARM would be a kernel nobody could report a fault against.
pub const VERSION = "0.1.0-" ++ @tagName(builtin.cpu.arch);

/// Filled in by the composition root, which is the only place that may know
/// about firmware tables and drivers at once.
pub const Platform = struct {
    system_manufacturer: ?[]const u8 = null,
    system_product: ?[]const u8 = null,
    bios_vendor: ?[]const u8 = null,
    bios_version: ?[]const u8 = null,
    /// Raw SMBIOS structure table, for a userspace decoder.
    smbios_table: ?[]const u8 = null,
    /// The kernel command line, kept for init, which reads it to decide what
    /// comes up this boot: the SD path has no equivalent of GRUB's editor,
    /// so one baked-in line must reach further than the kernel itself.
    cmdline: []const u8 = "",
    /// Where the firmware left the ACPI root pointer, for the userspace
    /// process that interprets the tables. A physical address and nothing
    /// more: reaching it needs the driver capability, which is the point.
    acpi_rsdp: u32 = 0,
    /// The power management block's event and control register ranges, from
    /// the FADT, and the chipset's own power management block, from the LPC
    /// bridge. A driver must never drive anything the DSDT places inside
    /// any of them, so the ranges are published for exactly that check.
    pm1a_event: u16 = 0,
    pm1a_event_len: u8 = 0,
    pm1a_control: u16 = 0,
    pm1a_control_len: u8 = 0,
    pm_block: u16 = 0,
    pm_block_len: u8 = 0,

    /// What the firmware says is physically fitted, which is not the same as
    /// what the allocator ended up with.
    ram_total_mb: u32 = 0,
    ram_devices: u8 = 0,
    ram_speed_mhz: u16 = 0,
    ram_type: []const u8 = "",
};

var platform: Platform = .{};

pub fn setPlatform(p: Platform) void {
    platform = p;
}

pub const Error = error{ UnknownKey, NoSpace };

/// Every question this answers.
///
/// The names are the enum's, so the lookup is one and the switch below is
/// total: a name added here without an answer will not compile, and an answer
/// for a name nobody can ask cannot be written.
pub const Key = enum {
    /// Every other one of these, so a caller can ask what there is rather
    /// than be told in a manual that drifts from the list.
    keys,
    kernel,
    cmdline,
    @"log.verbose",
    @"log.debug",
    arch,
    cpu,
    syscall,
    @"cpu.features",
    mem,
    @"mem.dma",
    @"mem.total",
    @"mem.free",
    heap,
    uptime,
    svc,
    clock,
    threads,
    @"mem.hardware",
    display,
    @"display.adapter",
    @"display.panel",
    @"display.registers",
    console,
    font,
    keymap,
    board,
    bios,
    quirks,
    @"quirks.ec",
    @"quirks.battery",
    mtrr,
    irq,
    apic,
    @"threads.list",
    acpi,
    @"acpi.pm",
    pci,
    disks,
    storage,
    mounts,
    log,
    smbios,
};

/// Write the value for `key` into `buf`, returning the number of bytes.
pub fn query(name: []const u8, buf: []u8) Error!usize {
    const key = std.meta.stringToEnum(Key, name) orelse return error.UnknownKey;
    var w = str.Builder{ .buf = buf };

    switch (key) {
        .keys => {
            for (std.enums.values(Key), 0..) |which, i| {
                if (i != 0) w.byte('\n');
                w.text(@tagName(which));
            }
        },
        .kernel => {
            w.print("vibeee {s}", .{VERSION});
        },
        .cmdline => {
            if (platform.cmdline.len == 0) return error.UnknownKey;
            w.print("{s}", .{platform.cmdline});
        },
        .@"log.verbose" => {
            // The two gates services log under, so their lines follow the
            // kernel's own: one `verbose` on the command line decides for the
            // whole boot, and one `debug` for the fault-chasing tier beneath it.
            w.print("{d}", .{@intFromBool(console.isVerbose())});
        },
        .@"log.debug" => {
            w.print("{d}", .{@intFromBool(console.isDebug())});
        },
        .arch => {
            w.print("{s}", .{@tagName(@import("builtin").cpu.arch)});
        },
        .cpu => {
            const info = hal.cpuInfo();
            w.print("{s}", .{info.brand});
        },
        .syscall => {
            // What the kernel armed, not what the CPU can do. A stub that chose
            // from CPUID alone would use a fast path whose MSRs were never
            // programmed, and jump to nothing.
            w.print("{s}", .{if (hal.fastSyscallArmed()) "sysenter" else "int80"});
        },
        .@"cpu.features" => {
            const info = hal.cpuInfo();
            w.print("{s}, {s}", .{
                if (info.fast_syscall) "sysenter" else "int80",
                if (info.freq_scaling) "freq scaling" else "fixed clock",
            });
        },
        .mem => {
            const m = pmm.stats();
            const total = m.totalBytes() / (1024 * 1024);
            const used = (m.totalBytes() - m.freeBytes()) / (1024 * 1024);
            w.print("{d} MiB used / {d} MiB", .{ used, total });

            // The firmware's figure is worth showing when it differs: the gap is
            // memory the map reserved, and seeing it beats wondering where it went.
            if (platform.ram_total_mb != 0 and platform.ram_total_mb != total) {
                w.print(" ({d} MiB fitted)", .{platform.ram_total_mb});
            }
        },
        .@"mem.dma" => {
            // The fragmentation reading: free bytes say how much there is, and
            // this says how much of it the things that need one piece can use.
            // A refusal count above zero is the event the band exists to prevent.
            const m = pmm.stats();
            w.print("largest run {d} KiB, band {d} of {d} KiB free, {d} refusals", .{
                pmm.largestRunBytes() / 1024,
                pmm.bandFreeBytes() / 1024,
                pmm.bandBytes() / 1024,
                m.contig_refusals,
            });
        },
        .@"mem.total" => {
            w.print("{d}", .{pmm.stats().totalBytes()});
        },
        .@"mem.free" => {
            w.print("{d}", .{pmm.stats().freeBytes()});
        },
        .heap => {
            const h = heap.stats();
            w.print("{d} bytes live, {d} frames", .{ h.live_bytes, h.frames });
        },
        .uptime => {
            w.print("{d}", .{clock.monotonicMicros() / 1_000_000});
        },
        .svc => {
            try writeServices(&w);
        },
        .clock => {
            if (!clock.valid()) return error.UnknownKey;
            w.print("{s}", .{clock.sourceName()});
        },
        .threads => {
            w.print("{d}", .{sched.stats().threads});
        },
        .@"mem.hardware" => {
            if (platform.ram_devices == 0) return error.UnknownKey;
            w.print("{d} MiB", .{platform.ram_total_mb});
            if (platform.ram_type.len > 0) w.print(" {s}", .{platform.ram_type});
            if (platform.ram_speed_mhz != 0) w.print("-{d}", .{platform.ram_speed_mhz});
            w.print(", {d} module{s}", .{
                platform.ram_devices,
                if (platform.ram_devices == 1) "" else "s",
            });
        },
        .display => {
            // The display module first: once a compositor owns the screen the
            // console is suspended and would answer nothing, but the screen is
            // very much in a mode. The console's answer covers the boot, before
            // anything has taken over.
            const owned = display.describe();
            const px = console.pixelSize();
            if (owned.width != 0 and display.isOwned()) {
                w.print("{d}x{d} 32bpp, composited", .{ owned.width, owned.height });
            } else if (px.width != 0) {
                w.print("{d}x{d} 32bpp", .{ px.width, px.height });
            } else {
                w.print("text mode", .{});
            }
        },
        .@"display.adapter" => {
            const a = display.describeAdapter();
            if (a.backend.len == 0) {
                w.print("unrecognised, using the firmware's mode", .{});
            } else {
                w.print("{s} ({s}), {s}", .{
                    a.backend,
                    a.family,
                    if (a.can_set) "can set modes" else "no modeset yet",
                });
            }
        },
        .@"display.panel" => {
            if (display.panelMode()) |p| {
                w.print("{d}x{d}", .{ p.width, p.height });
            }
        },
        .@"display.registers" => {
            if (display.registerReporter()) |f| {
                w.delegate(f);
            } else {
                w.print("no adapter that reports registers", .{});
            }
        },
        .console => {
            w.print("{d}x{d} cells", .{ console.width(), console.height() });
        },
        .font => {
            w.print("{s}", .{console.fontName()});
        },
        .keymap => {
            w.print("{s}", .{keymap.current().name});
        },
        .board => {
            w.print("{s} {s}", .{
                platform.system_manufacturer orelse "unknown",
                platform.system_product orelse "",
            });
        },
        .bios => {
            w.print("{s} {s}", .{
                platform.bios_vendor orelse "unknown",
                platform.bios_version orelse "",
            });
        },
        .quirks => {
            const list = quirks.appliedQuirks();
            if (list.len == 0) return error.UnknownKey;
            for (list, 0..) |quirk, i| {
                if (i > 0) w.print("\n", .{});
                w.print("{s}: {s}", .{ quirk.name, quirk.why });
            }
        },
        .@"quirks.ec" => {
            const c = quirks.get();
            if (c.ec_data_port == null or c.ec_status_port == null) return error.UnknownKey;
            w.print("{x} {x}", .{ c.ec_data_port.?, c.ec_status_port.? });
        },
        .@"quirks.battery" => {
            if (!quirks.get().battery_percent_mislabel) return error.UnknownKey;
            w.print("1", .{});
        },
        .mtrr => {
            // The memory-type map, straight off the registers: when the boot log
            // says the firmware already typed the framebuffer, this says with
            // what, which is the fact a fix would be built on.
            if (!hal.caps.write_combine) return error.UnknownKey;
            const count = hal.impl.mtrrRangeCount();
            if (count == 0) return error.UnknownKey;
            var shown = false;
            for (0..count) |slot| {
                const range = hal.impl.mtrrRangeAt(slot) orelse continue;
                if (shown) w.print("\n", .{});
                shown = true;
                w.print("{x:0>8} +{x:0>8} {s}", .{ range.base, range.size, range.typeName() });
            }
            if (!shown) w.print("no ranges programmed", .{});
        },
        .irq => {
            try writeIrqs(&w);
        },
        .apic => {
            // The controller's own account: the gate value, then the vectors in
            // service, requested-but-waiting, and marked level. What software
            // state cannot substitute for when a delivery is late.
            w.print("ppr {x}", .{hal.interruptPriority()});
            var vectors: [16]u8 = undefined;
            const groups = [_]struct { name: []const u8, read: *const fn ([]u8) usize }{
                .{ .name = " isr", .read = hal.interruptsInService },
                .{ .name = " irr", .read = hal.interruptsRequested },
                .{ .name = " tmr", .read = hal.interruptsLevel },
            };
            for (groups) |group| {
                w.print("{s}", .{group.name});
                const n = group.read(&vectors);
                for (vectors[0..n]) |vector| w.print(" {x}", .{vector});
            }
        },
        .@"threads.list" => {
            writeThreads(&w);
        },
        .acpi => {
            // Where the tables begin, for the process that interprets them. A
            // physical address rather than anything mapped: what to do with it is
            // the asker's business, and it needs the driver capability to do it.
            w.print("{x}", .{platform.acpi_rsdp});
        },
        .@"acpi.pm" => {
            // The power management block's ranges, base and length pairs, in
            // hex. What must never be driven, asked of the firmware's own table
            // and of the chipset rather than guessed.
            if (platform.pm1a_event_len == 0 and platform.pm1a_control_len == 0 and
                platform.pm_block_len == 0) return error.UnknownKey;
            w.print("{x} {x} {x} {x} {x} {x}", .{
                platform.pm1a_event,   platform.pm1a_event_len,
                platform.pm1a_control, platform.pm1a_control_len,
                platform.pm_block,     platform.pm_block_len,
            });
        },
        .pci => {
            try writeDevices(&w);
        },
        .disks => {
            writeDisks(&w);
        },
        .storage => {
            writeStorage(&w);
        },
        .mounts => {
            writeMounts(&w);
        },
        .log => {
            // The whole ring, copied straight out rather than formatted: it is
            // already text, and the ring is larger than the writer's idea of a
            // line.
            const n = klog.copyOut(buf);
            if (n == 0) return error.UnknownKey;
            return n;
        },
        .smbios => {
            const table = platform.smbios_table orelse return error.UnknownKey;
            if (table.len > buf.len) return error.NoSpace;
            @memcpy(buf[0..table.len], table);
            return table.len;
        },
    }

    // Asked once, at the end. A report that did not fit is a report the
    // caller must not read as complete, and finding that out at each of the
    // fifty places one is written would put the same `try` on every line.
    if (!w.whole()) return error.NoSpace;
    return w.done().len;
}

/// One line per registered service. The registry is the map of what is running
/// and answerable, which is the first thing worth knowing when something that
/// should respond does not.
fn writeServices(w: *str.Builder) Error!void {
    var first = true;
    for (svc.list()) |name| {
        if (!first) w.print("\n", .{});
        w.print("{s}", .{name});
        first = false;
    }
    if (first) return error.UnknownKey;
}

/// One line per thread: id, parent, state, priority, ticks, name, running.
///
/// The parent is included so a display can draw the process tree. Which
/// process started which is most of what a supervisor's user wants to know,
/// and it is knowable only here.
fn writeThreads(w: *str.Builder) void {
    const Ctx = struct {
        w: *str.Builder,

        fn visit(self: *@This(), t: sched.Snapshot) void {
            // Stops at the first line that does not fit rather than carrying
            // on and leaving a hole in the middle of the listing: a reader can
            // act on one that stops short, and cannot act on one missing
            // something from the middle.
            if (!self.w.whole()) return;
            self.w.print("{d}\t{d}\t{s}\t{d}\t{d}\t{s}\t{d}\t{d}\t{d}\n", .{
                t.id,
                t.parent_id,
                @tagName(t.state),
                t.priority,
                t.cpu_ticks,
                t.name,
                @intFromBool(t.is_current),
                t.bytes,
                t.uptime_s,
            });
        }
    };

    var ctx = Ctx{ .w = w };
    sched.forEachThread(&ctx, Ctx.visit);
}

/// One line per device on the bus: where it is, what it is, and what claimed
/// it. The table the device manager matches its manifests against, and the one
/// anyone porting to an unfamiliar machine reads first.
fn writeDevices(w: *str.Builder) Error!void {
    const Ctx = struct {
        w: *str.Builder,
        any: bool = false,

        fn visit(self: *@This(), b: probe.Binding) void {
            // Stops at the first line that does not fit rather than leaving a
            // hole in the middle of the listing.
            if (!self.w.whole()) return;
            self.any = true;
            // The driver is named whatever became of it, with the state
            // beside it saying which. A caller that only wants what is running
            // filters on the state; one that wants the whole picture, as the
            // boot table shows it, has the same facts to draw it from.
            self.w.print("{x:0>2}:{x:0>2}.{d}\t{x:0>4}\t{x:0>4}\t{x:0>2}\t{x:0>2}\t{x:0>2}\t{s}\t{s}\t{s}\n", .{
                b.dev.location[0],
                b.dev.location[1],
                b.dev.location[2],
                b.dev.vendor,
                b.dev.device,
                b.dev.class,
                b.dev.subclass,
                b.dev.prog_if,
                if (b.driver == null) "-" else b.driverName(),
                @tagName(b.state()),
                b.dev.description,
            });
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
fn writeIrqs(w: *str.Builder) Error!void {
    const Ctx = struct {
        w: *str.Builder,
        any: bool = false,

        fn visit(self: *@This(), line: irqevent.Snapshot) void {
            self.any = true;
            // Seven fields, always, each one thing: a reader that has to
            // count words to find a number reads whichever word happens to
            // sit there. Zero on a healthy machine is the forced count, which
            // is the reader's to leave unsaid rather than this one's to omit.
            self.w.print("{d}\t{s}\t{s}\t{d}\t{d}\t{d}\t{d}\n", .{
                line.gsi,
                if (line.held) "held" else if (line.armed) "armed" else "masked",
                @tagName(line.trigger),
                line.owners,
                line.count,
                line.forced,
                line.cascades,
            });
        }
    };

    var ctx = Ctx{ .w = w };
    irqevent.forEach(&ctx, Ctx.visit);
    if (!ctx.any) return error.UnknownKey;
}

/// Storage described the way a person would ask about it, not the way the
/// block layer stores it: each whole disk, then the volumes on it.
fn writeDisks(w: *str.Builder) void {
    for (block.list()) |*dev| {
        if (dev.offset != 0 or dev.retired) continue;

        // A medium with a filesystem written straight onto it is mounted
        // as the whole disk, which is how most sticks and cards arrive.
        // Saying where it went beats saying whether it could be written.
        w.print("{s}\t{d}\t{s}\n", .{
            dev.name,
            dev.bytes(),
            mountOf(dev.name) orelse if (dev.read_only) "read-only" else "read-write",
        });

        // Partitions carry their parent's context pointer, so they are matched
        // by name prefix rather than by identity.
        for (block.list()) |*part| {
            if (part.offset == 0 or part.retired) continue;
            if (!std.mem.startsWith(u8, part.name, dev.name)) continue;

            w.print("  {s}\t{d}\t{s}\n", .{ part.name, part.bytes(), mountOf(part.name) orelse "" });
        }
    }
}

/// Where a volume is mounted, if it is. One lookup, because a whole disk
/// and a partition are asked the same question.
fn mountOf(name: []const u8) ?[]const u8 {
    for (vfs.list()) |*m| {
        if (m.in_use and std.mem.eql(u8, m.device.name, name)) return m.path();
    }
    return null;
}

fn writeStorage(w: *str.Builder) void {
    var first = true;
    for (block.list()) |*dev| {
        if (dev.offset != 0) continue; // whole devices only
        if (!first) w.print("\n", .{});
        first = false;
        w.print("{s} {d} MiB", .{ dev.name, dev.bytes() / (1024 * 1024) });
    }
    if (first) w.print("none", .{});
}

fn writeMounts(w: *str.Builder) void {
    var first = true;
    for (vfs.list(), 0..) |*m, index| {
        if (!m.in_use) continue;
        if (!first) w.print("\n", .{});
        first = false;
        w.print("{s} on {s}", .{ m.path(), m.device.name });
        // Said plainly, because a caller deciding whether a write is worth
        // making has no other way to find out.
        if (m.device.is_volatile) w.print(" volatile", .{});

        // How full it is, in bytes, named so a reader takes them by name
        // rather than by position: this line is read by a shell command and
        // by a file manager, and the two must not disagree about which number
        // is which.
        const usage = vfs.usageAt(index);
        w.print(" free={d} size={d}", .{ usage.free, usage.total });
    }
    if (first) w.print("none", .{});
}

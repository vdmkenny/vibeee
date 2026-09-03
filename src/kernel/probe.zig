//! Hardware probing and driver binding.
//!
//! The registry is built at comptime; binding happens at runtime by asking each
//! candidate driver how confident it is. That ordering is what lets one image
//! boot on hardware it was not designed for: the GMA900 driver answers `.exact`
//! only on 8086:2592, while the VESA driver answers `.weak` on any VGA-class
//! device, so an unknown machine still gets a framebuffer instead of a black
//! screen.
//!
//! See design/00-vibeee.md §4.

const std = @import("std");
const console = @import("console.zig");
const lib = @import("lib");

/// Shared with userspace, so the boot probe's table and the `devices` tool
/// agree about what the words mean and how each is coloured.
pub const Confidence = @import("lib").driver.Confidence;

/// Shared with userspace for the same reason `Confidence` is: the boot table
/// and the `devices` tool report the same bindings and should not differ about
/// what they are called or how they look.
pub const State = @import("lib").driver.State;

pub const Match = union(enum) {
    /// Vendor+device.
    pci_id: struct { vendor: u16, device: u16 },
    /// Class+subclass, for generic fallback drivers.
    pci_class: struct { class: u8, subclass: u8 },
    /// Legacy device with no bus presence (i8042, PIT, RTC, CMOS).
    platform: []const u8,
};

pub const Driver = struct {
    name: []const u8,
    kind: enum { bus, block, video, input, net, audio, usb, platform, misc },
    match: []const Match,
    /// Returns how well this driver fits. Drivers that need to touch the device
    /// to be sure (the Synaptics/Elantech probe ladder) do it here.
    probe: *const fn (dev: Device) Confidence,
    /// Bring the device up. Left null while a driver is designed but not yet
    /// written, so the probe table doubles as an honest status board.
    attach: ?*const fn (dev: Device) anyerror!void = null,
    /// What the part actually is, for one whose class says otherwise.
    ///
    /// A device's class is its own claim about itself, and some of them are
    /// wrong: several radios of this era declare themselves ethernet
    /// controllers. A driver that recognised the exact part knows better
    /// than the claim does, and this is where it says so. Null leaves the
    /// bus's own description standing, which is the ordinary case.
    describes: ?[]const u8 = null,
};

/// A device offered for binding.
///
/// Bus-neutral on purpose: `location` is whatever identifies the device on its
/// own bus (PCI bus/slot/function today, USB bus/port/interface later), and the
/// bus driver is responsible for filling it in and for the description.
pub const Device = struct {
    bus: []const u8,
    location: [3]u16,
    vendor: u16,
    device: u16,
    class: u8,
    subclass: u8,
    prog_if: u8,
    description: []const u8,
    /// Bus-owned shutdown used before resources held by a userspace driver are
    /// reclaimed. Null for devices that cannot initiate independent transfers.
    quiesce: ?*const fn (location: [3]u16) void = null,
};

pub const Binding = struct {
    dev: Device,
    driver: ?*const Driver,
    confidence: Confidence,
    attached: bool = false,
    failed: bool = false,
    /// Which process claimed it from userspace, or zero for a kernel driver.
    /// The claim dies with the claimer, so a restarted driver finds its
    /// device free rather than reading its own past self as competition.
    claimed_by: u32 = 0,

    pub fn state(self: Binding) State {
        if (self.driver == null) return .unclaimed;
        if (self.failed) return .failed;
        return if (self.attached) .driven else .matched;
    }

    /// What is driving the device, or the empty string when nothing is.
    pub fn driverName(self: Binding) []const u8 {
        const d = self.driver orelse return "";
        return d.name;
    }
};

var bindings: [64]Binding = undefined;
var binding_count: usize = 0;

/// A userspace driver took the device at `location` on the PCI bus.
///
/// The table's word for a bound kernel driver is `driven`, and a device a
/// process drives deserves the same word: everything reading the table, the
/// listing and a second service probing for unclaimed hardware alike, would
/// otherwise read a driven device as free.
pub const ClaimError = error{ NotFound, Busy };

pub fn claimDevice(location: [3]u16, claimer: u32) ClaimError!void {
    for (bindings[0..binding_count]) |*b| {
        if (!std.mem.eql(u8, b.dev.bus, "pci")) continue;
        if (b.dev.location[0] != location[0] or
            b.dev.location[1] != location[1] or
            b.dev.location[2] != location[2]) continue;

        if (b.attached and b.claimed_by != claimer) return error.Busy;
        b.attached = true;
        b.claimed_by = claimer;
        return;
    }
    return error.NotFound;
}

pub fn releaseDevice(location: [3]u16, claimer: u32) bool {
    for (bindings[0..binding_count]) |*b| {
        if (!std.mem.eql(u8, b.dev.bus, "pci")) continue;
        if (b.dev.location[0] != location[0] or
            b.dev.location[1] != location[1] or
            b.dev.location[2] != location[2]) continue;
        if (b.claimed_by != claimer) return false;

        quiesce(b);
        b.attached = false;
        b.claimed_by = 0;
        return true;
    }
    return false;
}

/// The claimer is gone; its devices are free again.
pub fn dropClaims(claimer: u32) void {
    if (claimer == 0) return;
    for (bindings[0..binding_count]) |*b| {
        if (b.claimed_by != claimer) continue;
        quiesce(b);
        b.attached = false;
        b.claimed_by = 0;
    }
}

/// Stop a dead userspace driver from issuing new DMA before its shared-memory
/// handles return those pages to the allocator. Configuration cycles are read
/// back so the command write has completed before teardown continues.
fn quiesce(binding: *const Binding) void {
    const stop = binding.dev.quiesce orelse return;
    stop(binding.dev.location);
}

/// Drivers available to bind, supplied by the composition root.
var registry: []const Driver = &.{};

/// How to walk the buses again, supplied with the drivers. Which buses exist
/// is the composition root's knowledge: this file binds devices to drivers and
/// deliberately knows of no bus at all.
var walk: ?*const fn () void = null;

/// Start a probing pass with the given driver set. Bus drivers then call
/// `consider` for each device they find, `attachAll` brings them up, and
/// `report` prints the outcome. `again` runs that walk a second time, for
/// hardware that arrives after the boot has been through it once.
pub fn begin(drivers: []const Driver, again: ?*const fn () void) void {
    registry = drivers;
    walk = again;
    binding_count = 0;
}

/// Walk the buses again, so the table says what is there now rather than what
/// was there at boot. What a device switched on by a firmware method needs:
/// nothing announces it, so somebody has to look.
pub fn rescan() bool {
    const again = walk orelse return false;
    again();
    return true;
}

/// Drop every device on `bus` that `present` no longer finds.
///
/// The question is the bus driver's to answer and the table is this file's to
/// change, which is why it is asked rather than told. Walked backwards so that
/// filling a hole with the last entry cannot skip the entry that moved.
pub fn sweep(bus: []const u8, present: *const fn (location: [3]u16) bool) void {
    var i = binding_count;
    while (i > 0) {
        i -= 1;
        const b = &bindings[i];
        if (!std.mem.eql(u8, b.dev.bus, bus)) continue;
        if (present(b.dev.location)) continue;
        _ = forget(bus, b.dev.location);
    }
}

/// Offer one device for binding. Called by bus drivers; the composition root
/// (src/platform.zig) is what connects the two, so kernel core needs no
/// knowledge of which buses exist.
///
/// A device already at that place is left as it is, claim and all: a walk
/// that runs again over a machine that has not changed must not turn a
/// driven device into a second row saying nobody drives it. Different
/// hardware in the same place replaces the row instead, because the entry
/// describes the place and what is in it, and what is in it has changed.
pub fn consider(dev: Device) void {
    if (find(dev.bus, dev.location)) |existing| {
        if (existing.dev.vendor == dev.vendor and existing.dev.device == dev.device) return;
        existing.* = bound(dev);
        return;
    }

    if (binding_count >= bindings.len) return;
    bindings[binding_count] = bound(dev);
    binding_count += 1;
}

/// The device with the driver that fits it best, which is what an entry is.
fn bound(dev: Device) Binding {
    var best: ?*const Driver = null;
    var best_conf: Confidence = .no;
    for (registry) |*drv| {
        const c = drv.probe(dev);
        if (@intFromEnum(c) > @intFromEnum(best_conf)) {
            best_conf = c;
            best = drv;
        }
    }

    var entry = Binding{ .dev = dev, .driver = best, .confidence = best_conf };
    // Only a driver that recognised the exact part may rename it. One that
    // matched a whole class knows no more about what it is than the class
    // did, and a generic fallback renaming every device it half matched
    // would be worse than the claim it replaced.
    if (best_conf == .exact) {
        if (best.?.describes) |what| entry.dev.description = what;
    }
    return entry;
}

/// Where the entry for one place on one bus is, or null when nothing is
/// recorded there.
fn indexOf(bus: []const u8, location: [3]u16) ?usize {
    for (bindings[0..binding_count], 0..) |b, i| {
        if (!std.mem.eql(u8, b.dev.bus, bus)) continue;
        if (std.mem.eql(u16, &b.dev.location, &location)) return i;
    }
    return null;
}

fn find(bus: []const u8, location: [3]u16) ?*Binding {
    return &bindings[indexOf(bus, location) orelse return null];
}

/// Drop the entry at `location` on `bus`, which is a device that has gone.
///
/// Stopped before it is forgotten: the entry is what says a userspace driver
/// holds it, so once the row is gone nothing is left to quiesce it by, and a
/// part still mastering the bus would keep doing so with nobody accountable.
pub fn forget(bus: []const u8, location: [3]u16) bool {
    const index = indexOf(bus, location) orelse return false;
    quiesce(&bindings[index]);

    // The order of the table is discovery order and nothing reads meaning
    // into it, so the last entry fills the hole rather than the tail moving.
    binding_count -= 1;
    bindings[index] = bindings[binding_count];
    return true;
}

/// Bring up every bound device.
///
/// Ordered by confidence rather than by discovery: an exact match should
/// initialise before a generic fallback that matched the same class, so the
/// fallback sees hardware already claimed and stays out of the way.
///
/// A driver that fails to attach is recorded, not fatal. One dead device should
/// not cost the machine every other device behind it in the list.
pub fn attachAll() void {
    var level: u8 = @intFromEnum(Confidence.exact);
    while (true) : (level -= 1) {
        for (bindings[0..binding_count]) |*b| {
            if (@intFromEnum(b.confidence) != level) continue;
            const drv = b.driver orelse continue;
            const attach = drv.attach orelse continue;
            if (b.attached or b.failed) continue;

            attach(b.dev) catch |err| {
                b.failed = true;
                console.warn("{s}: attach failed on {s}: {s}", .{
                    drv.name, b.dev.description, @errorName(err),
                });
                continue;
            };
            b.attached = true;
        }
        if (level == @intFromEnum(Confidence.weak)) break;
    }
}

/// One line per device: location, ids, class, the driver bound to it, and how
/// confidently. What `devmgd` matches its manifests against.
pub fn forEachDevice(context: anytype, comptime visit: fn (@TypeOf(context), Binding) void) void {
    for (bindings[0..binding_count]) |b| visit(context, b);
}

/// Print what bound to what. This table is the porting worksheet on unfamiliar
/// hardware and the first thing to ask for in a bug report.
pub fn report() void {
    if (binding_count == 0) {
        console.warn("no pci devices; config access may be broken", .{});
        return;
    }

    // Two numbers because they answer different questions. A table entry that
    // names a device is not a driver running on it: the bridges and the USB
    // controllers match an entry that only describes them.
    var matched: usize = 0;
    var driven: usize = 0;
    for (bindings[0..binding_count]) |b| {
        if (b.driver != null) matched += 1;
        if (b.attached) driven += 1;
    }
    console.info("pci", "{d} devices, {d} matched, {d} driven", .{ binding_count, matched, driven });

    // The per-device table is a porting and bug-report aid, not something a
    // user needs at every boot.
    if (!console.isVerbose()) return;

    for (bindings[0..binding_count]) |b| {
        console.setColor(console.colourOf(.dim), .black);
        console.printf("  {x:0>2}:{x:0>2}.{d} {x:0>4}:{x:0>4} ", .{
            b.dev.location[0], b.dev.location[1], b.dev.location[2], b.dev.vendor, b.dev.device,
        });

        if (b.driver) |d| {
            console.setColor(console.colourOf(b.confidence.role()), .black);
            console.printf("{s: <12}", .{d.name});
            console.setColor(.dark_grey, .black);
            // The marker states what actually happened, so a driver that
            // exists but failed cannot be mistaken for one that is running.
            console.printf("{s: <7}{s} ", .{ @tagName(b.confidence), b.state().mark() });
        } else {
            console.printf("{s: <12}{s: <9}", .{ "-", "" });
        }

        console.printf("{s}\n", .{b.dev.description});
        console.setColor(.light_grey, .black);
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// A device at a place, with ids a test can tell apart.
fn testDevice(slot: u16, vendor: u16, device: u16) Device {
    return .{
        .bus = "pci",
        .location = .{ 0, slot, 0 },
        .vendor = vendor,
        .device = device,
        .class = 0x02,
        .subclass = 0x00,
        .prog_if = 0,
        .description = "test device",
    };
}

fn testCount() usize {
    var seen: usize = 0;
    forEachDevice(&seen, struct {
        fn visit(counter: *usize, _: Binding) void {
            counter.* += 1;
        }
    }.visit);
    return seen;
}

test "a walk that runs again over an unchanged machine changes nothing" {
    begin(&.{}, null);
    consider(testDevice(1, 0x8086, 0x100E));
    consider(testDevice(2, 0x168C, 0x001C));
    try testing.expectEqual(@as(usize, 2), testCount());

    // The same walk again. Twice, because the bug this guards against is an
    // entry appended per pass rather than per device.
    consider(testDevice(1, 0x8086, 0x100E));
    consider(testDevice(2, 0x168C, 0x001C));
    consider(testDevice(1, 0x8086, 0x100E));
    try testing.expectEqual(@as(usize, 2), testCount());
}

test "a device that was claimed keeps its claim across a walk" {
    begin(&.{}, null);
    consider(testDevice(1, 0x8086, 0x100E));
    try claimDevice(.{ 0, 1, 0 }, 42);

    consider(testDevice(1, 0x8086, 0x100E));

    const held = find("pci", .{ 0, 1, 0 }).?;
    try testing.expect(held.attached);
    try testing.expectEqual(@as(u32, 42), held.claimed_by);
}

test "different hardware in the same place replaces the entry" {
    begin(&.{}, null);
    consider(testDevice(1, 0x8086, 0x100E));
    try claimDevice(.{ 0, 1, 0 }, 42);

    consider(testDevice(1, 0x168C, 0x001C));
    try testing.expectEqual(@as(usize, 1), testCount());

    // The claim was on what was there, not on the place: a card swapped for
    // another must not be handed the first one's driver as if nothing moved.
    const now = find("pci", .{ 0, 1, 0 }).?;
    try testing.expectEqual(@as(u16, 0x168C), now.dev.vendor);
    try testing.expect(!now.attached);
    try testing.expectEqual(@as(u32, 0), now.claimed_by);
}

test "a device that stopped answering is dropped, and the rest stay" {
    begin(&.{}, null);
    consider(testDevice(1, 0x8086, 0x100E));
    consider(testDevice(2, 0x168C, 0x001C));
    consider(testDevice(3, 0x1969, 0x2048));

    // The middle one, so that filling the hole with the last entry is what
    // has to keep the other two.
    sweep("pci", struct {
        fn present(location: [3]u16) bool {
            return location[1] != 2;
        }
    }.present);

    try testing.expectEqual(@as(usize, 2), testCount());
    try testing.expect(find("pci", .{ 0, 1, 0 }) != null);
    try testing.expect(find("pci", .{ 0, 2, 0 }) == null);
    try testing.expect(find("pci", .{ 0, 3, 0 }) != null);
}

test "a sweep leaves another bus alone" {
    begin(&.{}, null);
    consider(testDevice(1, 0x8086, 0x100E));

    var usb = testDevice(1, 0x0000, 0x0000);
    usb.bus = "usb";
    consider(usb);

    // Nothing on pci answers, and the usb entry is not pci's to remove.
    sweep("pci", struct {
        fn present(_: [3]u16) bool {
            return false;
        }
    }.present);

    try testing.expectEqual(@as(usize, 1), testCount());
    try testing.expect(find("usb", .{ 0, 1, 0 }) != null);
}

test "the driver that recognised the part names it; one that guessed does not" {
    const table = [_]Driver{
        .{
            .name = "exactly",
            .kind = .net,
            .match = &.{},
            .probe = &struct {
                fn probe(dev: Device) Confidence {
                    return if (dev.vendor == 0x168C) .exact else .no;
                }
            }.probe,
            .describes = "wireless controller",
        },
        .{
            .name = "roughly",
            .kind = .net,
            .match = &.{},
            .probe = &struct {
                fn probe(dev: Device) Confidence {
                    return if (dev.class == 0x02) .weak else .no;
                }
            }.probe,
            .describes = "something else entirely",
        },
    };

    begin(&table, null);
    consider(testDevice(1, 0x168C, 0x001C));
    consider(testDevice(2, 0x8086, 0x100E));

    // The part whose class says one thing and whose driver knows another.
    try testing.expectEqualStrings(
        "wireless controller",
        find("pci", .{ 0, 1, 0 }).?.dev.description,
    );

    // The one nothing recognised exactly keeps what the bus called it, so a
    // generic driver cannot rename every device it half matched.
    try testing.expectEqualStrings(
        "test device",
        find("pci", .{ 0, 2, 0 }).?.dev.description,
    );
}

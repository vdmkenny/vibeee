//! The panel's brightness, however this machine happens to offer it.
//!
//! One interface and a backend per way of doing it, which is the shape the
//! display drivers already take: what a caller wants is a level, and which
//! method carries it there is the machine's business rather than the caller's.
//!
//! The choice is made here rather than in a tool. If a tool chose, every tool
//! would have to, and they would disagree the first time one of them was
//! written against a machine the other had not seen.

const asus = @import("asus.zig");
const log = @import("ulib").log;
const out = @import("ulib").out;
const proto = @import("proto").platform;
const uacpi = @import("uacpi.zig");

/// How a machine offers brightness.
const Backend = struct {
    /// What to call it in the boot log. Which one was picked is the first
    /// thing worth knowing when the panel does not dim, and inferring it from
    /// silence is how an afternoon goes.
    name: []const u8,
    /// Whether this machine has it, and where. Sets `where` when it does.
    find: *const fn () ?*uacpi.Node,
    read: *const fn (node: *uacpi.Node) ?u32,
    write: *const fn (node: *uacpi.Node, level: u32) bool,
    /// Highest level the method accepts. Zero means ask `levels`.
    max: u32,
};

/// Standard first, because a machine that has it is one this works on without
/// knowing anything about who made it. The vendor's own is the fallback, and on
/// the Eee PC it is the only one: the panel there offers no `_BCM` at all.
const backends = [_]Backend{
    .{ .name = "standard", .find = &standardDevice, .read = &standardRead, .write = &standardWrite, .max = 0 },
    .{ .name = "asus", .find = &asus.panelDevice, .read = &asus.panelLevel, .write = &asus.setPanelLevel, .max = asus.PANEL_LEVELS },
};

/// A backend and the device it drives, found once and kept: the namespace does
/// not change under a running machine.
const Chosen = struct {
    backend: Backend,
    node: *uacpi.Node,
};

var chosen: ?Chosen = null;
var looked = false;

pub fn pick() ?Chosen {
    if (looked) return chosen;
    looked = true;

    for (backends) |backend| {
        if (backend.find()) |node| {
            chosen = .{ .backend = backend, .node = node };
            return chosen;
        }
    }
    return null;
}

/// Say which way this machine offers it, once, at start-up.
///
/// Probed here rather than on the first request so the answer is in the boot
/// log whether or not anybody asks: a machine whose panel will not dim should
/// not have to be interrogated to find out that nothing claimed it.
pub fn report() void {
    const found = pick() orelse {
        log.warn("platd", "no backlight; neither _BCM nor a vendor method");
        return;
    };

    // Two whole lines rather than one: which backend claimed the panel is
    // known before its method is called, and the call runs firmware code. A
    // boot that stops between the two lines has named where it stopped.
    const name = uacpi.namespace_node_name(found.node);

    log.begin("platd", .key);
    out.text("backlight via ");
    out.text(found.backend.name);
    out.text(" on ");
    out.text(uacpi.trimmed(&name.text));
    log.end();

    var panel = proto.Backlight{};
    const got = read(&panel) == .ok and panel.isPresent();

    log.begin("platd", if (got) .key else .warn);
    if (got) {
        // The range too: it is what a caller has to know and the one number
        // that differs between the two ways of doing this.
        out.text("panel at ");
        out.decimal(panel.level);
        out.text(" of ");
        out.decimal(panel.max);
    } else {
        out.text("the panel would not answer");
    }
    log.end();
}

pub fn read(into: *proto.Backlight) proto.Status {
    const found = pick() orelse {
        into.* = .{};
        return .ok;
    };

    const level = found.backend.read(found.node) orelse return .refused;
    into.* = .{
        .present = 1,
        .level = level,
        .max = if (found.backend.max != 0) found.backend.max else standardMax(found.node),
    };
    return .ok;
}

pub fn write(level: u32, into: *proto.Backlight) proto.Status {
    // A machine with no backlight answers a set the same way it answers a
    // read: there is none. Reporting it as a refusal would read as the
    // firmware having said no to something it was never asked.
    const found = pick() orelse {
        into.* = .{};
        return .ok;
    };
    if (!found.backend.write(found.node, level)) return .refused;

    // Read back rather than report what was asked for. A level the firmware
    // clamped is a level the caller should see clamped, and it is the only way
    // to find out what a method actually accepts.
    return read(into);
}

// ---------------------------------------------------------------------------
// The standard way
// ---------------------------------------------------------------------------
//
// `_BCM` sets, `_BQC` reads, `_BCL` lists what the panel accepts. Defined by
// the specification, so a machine that has it needs nothing else known about
// it.

fn standardDevice() ?*uacpi.Node {
    return uacpi.firstWith("_BCM");
}

fn standardRead(node: *uacpi.Node) ?u32 {
    var value: u64 = 0;
    if (uacpi.uacpi_eval_simple_integer(node, "_BQC", &value) != .ok) return null;
    return @truncate(value);
}

fn standardWrite(node: *uacpi.Node, level: u32) bool {
    return uacpi.callWith(node, "_BCM", level);
}

/// The last entry of `_BCL`, which lists the levels in ascending order after
/// two entries saying what the firmware uses on mains and on battery.
fn standardMax(node: *uacpi.Node) u32 {
    var package: ?*uacpi.Object = null;
    if (uacpi.uacpi_eval_simple_package(node, "_BCL", &package) != .ok) return 100;
    defer uacpi.uacpi_object_unref(package);

    var levels: uacpi.ObjectArray = undefined;
    if (uacpi.uacpi_object_get_package(package, &levels) != .ok) return 100;
    if (levels.count == 0) return 100;

    var highest: u64 = 0;
    if (uacpi.uacpi_object_get_integer(levels.objects[levels.count - 1], &highest) != .ok) {
        return 100;
    }
    return @truncate(highest);
}

// ---------------------------------------------------------------------------
// Stepping
// ---------------------------------------------------------------------------

/// One step brighter or darker, and stop at the ends.
///
/// What a brightness key means. A step rather than a percentage for the same
/// reason a level is: sixteen steps is what this panel has, and moving by five
/// percent would move by nothing most of the time and by two steps sometimes.
pub fn step(by: i32) void {
    var panel = proto.Backlight{};
    if (read(&panel) != .ok or !panel.isPresent()) return;

    const moved = @as(i64, panel.level) + by;
    const level: u32 = @intCast(@min(@max(moved, 0), @as(i64, panel.max)));
    if (level == panel.level) return;

    _ = write(level, &panel);
}

//! devmgd: matches devices to drivers, and starts them with what they need.
//!
//! The kernel binds its own built-in drivers as it enumerates the bus. This
//! handles the other kind: driver servers that live in userspace, are declared
//! by a manifest rather than compiled in, and get exactly the capabilities
//! their manifest asks for and nothing else.
//!
//! Why a separate program rather than part of `init`: what a device is and
//! what a service is have nothing in common beyond both being started. init
//! knows about dependency order and restart policy; this knows about vendor
//! ids and apertures, and neither wants the other's table.
//!
//! `design/00-vibeee.md` §4.

const sys = @import("sys");
const config = @import("ulib").config;
const dir = @import("ulib").dir;
const log = @import("ulib").log;
const out = @import("ulib").out;
const str = @import("ulib").str;

/// Where drivers live: each one's program and the manifest describing it, side
/// by side. Not in /bin because nothing here is ever run by name. A driver is
/// reached by matching hardware, so it has no business in what a shell searches
/// or completes.
const DRIVER_DIR = "/lib/drivers";

/// What marks the manifest of the pair. Dropped in rather than listed anywhere:
/// adding a driver should be adding two files and telling nothing.
const MANIFEST_SUFFIX = ".man";

/// Enough for a machine of this era. A netbook has six to a dozen devices and
/// nothing like that many drivers.
const MAX_DRIVERS = 16;

/// What a manifest says. Field names are the keys in the file, so the two
/// cannot drift.
const Manifest = struct {
    name: []const u8 = "",
    binary: []const u8 = "",
    /// `pci:vendor:device`, in hex, or `pci-class:class:subclass` for a driver
    /// that handles a whole family.
    match: []const u8 = "",
    /// Comma-separated capability names. A driver that does not say gets the
    /// driver capability and nothing else, which is the whole point of it
    /// being a separate program.
    caps: []const u8 = "driver",
};

var manifests: [MAX_DRIVERS]Manifest = @splat(.{});
var manifest_count: usize = 0;

/// The text every manifest's fields point into, so it has to outlive them.
var manifest_text: [4096]u8 = @splat(0);
var manifest_used: usize = 0;

export fn _start() callconv(.c) noreturn {
    devmgdMain();
}

fn devmgdMain() noreturn {
    readManifests();
    bindDevices();

    out.flush();
    sys.exit(0);
}

// ---------------------------------------------------------------------------
// Manifests
// ---------------------------------------------------------------------------

fn readManifests() void {
    var names: [dir.MAX * 16]u8 = undefined;
    var listing: dir.Listing = .{};

    dir.read(DRIVER_DIR, &names, &listing) catch {
        // No directory at all is the ordinary case on a machine with no
        // userspace drivers yet, and is not worth a line.
        return;
    };

    for (listing.items()) |entry| {
        if (entry.is_dir) continue;
        if (!str.endsWith(entry.name, MANIFEST_SUFFIX)) continue;
        readOne(entry.name);
    }
}

var path_buf: [96]u8 = @splat(0);

fn readOne(name: []const u8) void {
    if (manifest_count == MAX_DRIVERS) return;

    var path = str.Builder{ .buf = &path_buf };
    path.text(DRIVER_DIR);
    path.byte('/');
    path.text(name);

    const handle = sys.open(path.done(), .{});
    if (handle < 0) return;
    defer _ = sys.close(@intCast(handle));

    // Read into the tail of the shared buffer: the parsed fields are slices of
    // it, so every manifest's text has to stay where it was put.
    const room = manifest_text[manifest_used..];
    if (room.len == 0) return;

    const n = sys.read(@intCast(handle), room);
    if (n <= 0) return;

    const text = room[0..@intCast(n)];
    manifest_used += @intCast(n);

    var current = Manifest{};
    var dirty = false;

    var lines = str.lines(text);
    while (lines.next()) |raw| {
        const line = str.trim(raw);
        if (line.len == 0 or line[0] == '#') continue;

        const kv = config.pair(line) orelse continue;
        if (config.assign(&current, kv.key, kv.value) == .assigned) dirty = true;
    }

    if (!dirty or current.name.len == 0 or current.binary.len == 0) return;
    manifests[manifest_count] = current;
    manifest_count += 1;
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

const Device = struct {
    vendor: u16,
    device: u16,
    class: u8,
    subclass: u8,
    /// What the kernel bound, or "-" for nothing.
    driver: []const u8,
    /// What became of that binding, from the kernel's own vocabulary. A driver
    /// that merely matched is not driving the device, and the device is still
    /// there to be offered to one that can.
    state: []const u8,
    description: []const u8,

    fn isDriven(self: Device) bool {
        return str.eql(self.state, "driven");
    }
};

fn bindDevices() void {
    var buf: [2048]u8 = @splat(0);
    const table = ask("pci", &buf);
    if (table.len == 0) return;

    var matched: usize = 0;

    var lines = str.lines(table);
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const dev = parseDevice(line) orelse continue;

        // Something in the kernel already drives it. Two drivers on one device
        // is worse than the wrong one of them.
        if (dev.isDriven()) continue;

        const manifest = matchFor(dev) orelse continue;
        matched += 1;
        _ = start(manifest, dev);
    }

    // Said only when there was something to match against and nothing fitted,
    // which is worth knowing; a manifest that matched and failed has already
    // said so for itself.
    if (manifest_count > 0 and matched == 0) {
        log.warn("devmgd", "no device matched a manifest");
    }
}

fn parseDevice(line: []const u8) ?Device {
    var it = str.fields(line);
    _ = it.next() orelse return null; // location, which nothing here matches on

    return .{
        .vendor = @intCast(str.fromHex(it.next() orelse return null)),
        .device = @intCast(str.fromHex(it.next() orelse return null)),
        .class = @intCast(str.fromHex(it.next() orelse return null)),
        .subclass = @intCast(str.fromHex(it.next() orelse return null)),
        .driver = it.next() orelse "-",
        .state = it.next() orelse "",
        .description = it.next() orelse "",
    };
}

/// The manifest that fits a device best.
///
/// An exact vendor and device beats a class, the same ranking the kernel's own
/// probe uses: a driver written for one part should win over one written for
/// the family it belongs to.
fn matchFor(dev: Device) ?*const Manifest {
    // Exact first, so a driver written for one part is never passed over for
    // one written for the family it belongs to.
    for (manifests[0..manifest_count]) |*m| {
        if (fits(m.match, dev) == true) return m;
    }
    for (manifests[0..manifest_count]) |*m| {
        if (fits(m.match, dev) == false) return m;
    }
    return null;
}

/// Whether a match string covers a device, and whether it does so exactly.
/// Null means it does not cover it at all.
fn fits(spec: []const u8, dev: Device) ?bool {
    var it = str.split(spec, ':');
    const kind = str.trim(it.next() orelse return null);

    const first = str.fromHex(str.trim(it.next() orelse return null));
    const second = str.fromHex(str.trim(it.next() orelse return null));

    if (str.eql(kind, "pci")) {
        return if (dev.vendor == first and dev.device == second) true else null;
    }
    if (str.eql(kind, "pci-class")) {
        return if (dev.class == first and dev.subclass == second) false else null;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Starting
// ---------------------------------------------------------------------------

fn start(manifest: *const Manifest, dev: Device) bool {
    const pid = sys.spawnStreams(manifest.binary, &.{manifest.name}, .{
        .flags = @bitCast(sys.SpawnFlags{ .detached = true }),
        .caps = capsFrom(manifest.caps),
    });

    if (pid < 0) {
        log.begin("devmgd", .bad);
        out.text(manifest.name);
        out.text(": cannot start");
        log.end();
        return false;
    }

    log.begin("devmgd", .key);
    out.text(manifest.name);
    out.text(" for ");
    out.text(dev.description);
    log.end();
    return true;
}

/// A manifest's capability list, resolved against the ABI's own field names so
/// adding a capability needs no change here.
fn capsFrom(list: []const u8) u32 {
    var granted = sys.Caps{};
    var it = str.split(list, ',');
    while (it.next()) |raw| {
        const wanted = str.trim(raw);
        inline for (@typeInfo(sys.Caps).@"struct".fields) |field| {
            if (field.type == bool and str.eql(wanted, field.name)) {
                @field(granted, field.name) = true;
            }
        }
    }
    return @bitCast(granted);
}

fn ask(key: []const u8, buf: []u8) []const u8 {
    const n = sys.sysinfo(key, buf);
    return if (n > 0) buf[0..@intCast(n)] else "";
}

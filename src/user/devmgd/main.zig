//! devmgd: the one authority on which driver drives which device.
//!
//! The kernel binds its own built-ins as it enumerates the bus; this
//! owns the other kind. A manifest in `/lib/drivers` names the hardware
//! it fits and one of two homes for its driver: a standalone binary the
//! manager starts and stops, or a service that will come and ask what it
//! has been assigned. Either way the vendor and device numbers live in
//! the manifest files and nowhere else: no service compiles in a PCI id.
//!
//! Resident, because matching is not a moment: drivers can be stopped and
//! started, the manifest directory can be read again for something newly
//! installed, and services ask their questions whenever they start. The
//! serve loop is the whole of the runtime cost; between questions this
//! process waits and costs nothing.
//!
//! `design/00-vibeee.md` §4.

const sys = @import("sys");
const config = @import("ulib").config;
const dir = @import("ulib").dir;
const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const pciscan = @import("ulib").pciscan;
const proto = @import("proto").devices;
const std = @import("std");
const str = @import("ulib").str;

/// Where drivers live: each one's manifest, and the program beside it when
/// the driver is a standalone process. Not in /bin because nothing here is
/// ever run by name from a shell.
const DRIVER_DIR = "/lib/drivers";

/// What marks a manifest. Dropped in rather than listed anywhere: adding a
/// driver is adding files and telling nobody.
const MANIFEST_SUFFIX = ".man";

const MAX_DRIVERS = 12;
const MAX_BOUND = 12;

/// What a manifest says. Field names are the keys in the file, so the two
/// cannot drift.
const Manifest = struct {
    name: []const u8 = "",
    /// The program to start, for a standalone driver.
    binary: []const u8 = "",
    /// The service that will claim the assignment, for a compiled-in one.
    /// A manifest names exactly one of `binary` and `service`.
    service: []const u8 = "",
    /// `pci:vendor:device`, in hex, or `pci-class:class:subclass` for a
    /// driver that handles a whole family.
    match: []const u8 = "",
    /// Comma-separated capability names for a standalone driver. One that
    /// does not say gets the driver capability and nothing else, which is
    /// the whole point of it being a separate program.
    caps: []const u8 = "driver",
};

var manifests: [MAX_DRIVERS]Manifest = @splat(.{});
var manifest_count: usize = 0;

/// The text every manifest's fields point into, so it has to outlive them.
var manifest_text: [4096]u8 = @splat(0);
var manifest_used: usize = 0;

/// One device bound to one manifest: either a process the manager runs, or
/// an assignment a service claims.
const Bound = struct {
    live: bool = false,
    manifest: usize = 0,
    location: lib.pci.Location = .{ .bus = 0, .device = 0, .function = 0 },
    state: proto.DriverState = .assigned,
    pid: u32 = 0,
};

var bound: [MAX_BOUND]Bound = @splat(.{});
var service: u32 = 0;

export fn _start() callconv(.c) noreturn {
    devmgdMain();
}

fn devmgdMain() noreturn {
    const channel = sys.svcRegister(proto.SERVICE);
    if (channel < 0) {
        log.note("devmgd", "already serving; letting this instance stand down");
        sys.exit(0);
    }
    service = @intCast(channel);

    readManifests();
    bindDevices();
    out.flush();

    serve();
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

    const file = sys.open(path.done(), .{});
    if (file < 0) return;
    defer _ = sys.close(@intCast(file));

    // Read into the tail of the shared buffer: the parsed fields are slices
    // of it, so every manifest's text has to stay where it was put.
    const room = manifest_text[manifest_used..];
    if (room.len == 0) return;

    const n = sys.read(@intCast(file), room);
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

    // A manifest names its driver and exactly one home for it.
    if (!dirty or current.name.len == 0) return;
    if ((current.binary.len == 0) == (current.service.len == 0)) return;
    if (current.name.len > proto.NAME_MAX or current.service.len > proto.NAME_MAX) return;

    // Reading again must not double an already-known driver.
    for (manifests[0..manifest_count]) |existing| {
        if (str.eql(existing.name, current.name)) return;
    }
    manifests[manifest_count] = current;
    manifest_count += 1;
}

// ---------------------------------------------------------------------------
// Matching
// ---------------------------------------------------------------------------

fn bindDevices() void {
    var scan = pciscan.Scan{};
    if (!scan.start()) return;

    var matched: usize = 0;
    while (scan.next()) |entry| {
        // Something in the kernel already drives it. Two drivers on one
        // device is worse than the wrong one of them.
        if (entry.driven) continue;
        if (alreadyBound(entry.location)) {
            matched += 1;
            continue;
        }

        const found = matchFor(entry) orelse continue;
        matched += 1;
        bind(found, entry.location);
    }

    if (manifest_count > 0 and matched == 0) {
        log.warn("devmgd", "no device matched a manifest");
    }
}

fn alreadyBound(location: lib.pci.Location) bool {
    for (bound) |b| {
        if (b.live and @as(u16, @bitCast(b.location)) == @as(u16, @bitCast(location))) return true;
    }
    return false;
}

/// The manifest that fits a device best: an exact vendor and device beats
/// a class, the same ranking the kernel's own probe uses.
fn matchFor(entry: pciscan.Entry) ?usize {
    for (manifests[0..manifest_count], 0..) |m, i| {
        if (fits(m.match, entry) == true) return i;
    }
    for (manifests[0..manifest_count], 0..) |m, i| {
        if (fits(m.match, entry) == false) return i;
    }
    return null;
}

/// Whether a match string covers a device, and whether it does so exactly.
/// Null means it does not cover it at all.
fn fits(spec: []const u8, entry: pciscan.Entry) ?bool {
    var it = str.split(spec, ':');
    const kind = str.trim(it.next() orelse return null);

    const first = str.fromHex(str.trim(it.next() orelse return null));
    const second = str.fromHex(str.trim(it.next() orelse return null));

    if (str.eql(kind, "pci")) {
        return if (entry.vendor == first and entry.device == second) true else null;
    }
    if (str.eql(kind, "pci-class")) {
        return if (entry.class == first and entry.subclass == second) false else null;
    }
    return null;
}

fn bind(manifest_index: usize, location: lib.pci.Location) void {
    const slot = freeSlot() orelse return;
    const manifest = &manifests[manifest_index];

    slot.* = .{
        .live = true,
        .manifest = manifest_index,
        .location = location,
    };

    if (manifest.service.len != 0) {
        // A service's driver: recorded, claimed later, narrated now so the
        // boot log says who was given what.
        slot.state = .assigned;
        sayBinding(manifest.name, location, manifest.service);
        return;
    }

    if (startProcess(slot)) {
        sayBinding(manifest.name, location, "");
    }
}

fn freeSlot() ?*Bound {
    for (&bound) |*b| {
        if (!b.live) return b;
    }
    return null;
}

fn startProcess(slot: *Bound) bool {
    const manifest = &manifests[slot.manifest];
    const pid = sys.spawnStreams(manifest.binary, &.{manifest.name}, .{
        .flags = @bitCast(sys.SpawnFlags{ .detached = true }),
        .caps = capsFrom(manifest.caps),
    });

    if (pid < 0) {
        log.begin("devmgd", .bad);
        out.text(manifest.name);
        out.text(": cannot start");
        log.end();
        slot.state = .stopped;
        return false;
    }
    slot.pid = @intCast(pid);
    slot.state = .running;
    return true;
}

fn sayBinding(name: []const u8, location: lib.pci.Location, claimer: []const u8) void {
    log.begin("devmgd", .key);
    out.text(name);
    out.text(" at ");
    var place: [8]u8 = undefined;
    out.text(lib.pci.spell(location, &place));
    if (claimer.len != 0) {
        out.text(" for ");
        out.text(claimer);
    }
    log.end();
}

/// A manifest's capability list, resolved against the ABI's own field
/// names so adding a capability needs no change here.
fn capsFrom(granted_list: []const u8) u32 {
    var granted = sys.Caps{};
    var it = str.split(granted_list, ',');
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

// ---------------------------------------------------------------------------
// The channel: claims and control
// ---------------------------------------------------------------------------

fn serve() noreturn {
    while (true) {
        var message = sys.Message{};
        const request = sys.recv(service, &message, sys.FOREVER) orelse continue;
        handle(&message, request.token);
        out.flush();
    }
}

fn handle(message: *const sys.Message, token: u32) void {
    const bytes = message.bytes();
    if (bytes.len < @sizeOf(proto.Req)) return refuse(token);
    const req: *const proto.Req = @ptrCast(@alignCast(bytes.ptr));

    switch (req.tag) {
        .claim => claim(req, token),
        .list => list(req, token),
        .start => control(req, token, .running),
        .stop => control(req, token, .stopped),
        .rescan => rescan(token),
    }
}

/// The `index`th assignment recorded for the asking service.
fn claim(req: *const proto.Req, token: u32) void {
    const wanted = req.nameSlice();
    var seen: u32 = 0;

    for (bound) |b| {
        if (!b.live) continue;
        const manifest = &manifests[b.manifest];
        if (manifest.service.len == 0 or !str.eql(manifest.service, wanted)) continue;

        if (seen == req.index) {
            var assignment = proto.Assignment{
                .location = @bitCast(b.location),
                .driver_len = @intCast(manifest.name.len),
            };
            @memcpy(assignment.driver[0..manifest.name.len], manifest.name);
            replyBody(token, .{ .assignment = assignment });
            return;
        }
        seen += 1;
    }
    replyEnd(token);
}

fn list(req: *const proto.Req, token: u32) void {
    var seen: u32 = 0;
    for (bound) |b| {
        if (!b.live) continue;
        if (seen == req.index) {
            const manifest = &manifests[b.manifest];
            var info = proto.DriverInfo{
                .name_len = @intCast(manifest.name.len),
                .state = b.state,
                .location = @bitCast(b.location),
                .service_len = @intCast(manifest.service.len),
            };
            @memcpy(info.name[0..manifest.name.len], manifest.name);
            @memcpy(info.service[0..manifest.service.len], manifest.service);
            replyBody(token, .{ .driver = info });
            return;
        }
        seen += 1;
    }
    replyEnd(token);
}

/// Start or stop a standalone driver process by its manifest name. A
/// service's compiled-in driver has no process to control here; its
/// service owns its lifetime.
fn control(req: *const proto.Req, token: u32, wanted: proto.DriverState) void {
    const name = req.nameSlice();
    for (&bound) |*b| {
        if (!b.live) continue;
        const manifest = &manifests[b.manifest];
        if (!str.eql(manifest.name, name)) continue;
        if (manifest.service.len != 0) return refuse(token);

        switch (wanted) {
            .running => {
                if (b.state == .running) return refuse(token);
                if (!startProcess(b)) return refuse(token);
            },
            .stopped => {
                if (b.state != .running) return refuse(token);
                _ = sys.kill(b.pid);
                b.pid = 0;
                b.state = .stopped;
            },
            .assigned => return refuse(token),
        }
        replyBody(token, .{ .none = 0 });
        return;
    }
    refuse(token);
}

/// Read the manifests again and bind anything newly matched: how a driver
/// dropped into `/lib/drivers` on a running machine comes alive.
fn rescan(token: u32) void {
    readManifests();
    bindDevices();
    replyBody(token, .{ .none = 0 });
}

fn refuse(token: u32) void {
    var reply = proto.Rep{ .status = .refused };
    replyWith(token, &reply);
}

fn replyEnd(token: u32) void {
    var reply = proto.Rep{ .status = .end };
    replyWith(token, &reply);
}

fn replyBody(token: u32, body: proto.Body) void {
    var reply = proto.Rep{ .body = body };
    replyWith(token, &reply);
}

fn replyWith(token: u32, reply: *const proto.Rep) void {
    var answer = sys.Message.init(std.mem.asBytes(reply), &.{});
    _ = sys.replyMsg(service, token, &answer);
}

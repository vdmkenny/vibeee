//! What the device manager and everyone else say to each other.
//!
//! One authority matches hardware to drivers: the manager reads the
//! manifests, walks the bus, and remembers who should drive what. A
//! standalone driver is a process the manager starts and stops; a driver
//! that lives inside a service is an assignment the service comes and
//! asks for. Either way the knowledge of vendors and devices is in the
//! manifests, and nowhere else.

const std = @import("std");
const sys = @import("sys");

pub const SERVICE = "devices";

/// The longest driver or service name a manifest may use.
pub const NAME_MAX = 15;

pub const Tag = enum(u8) {
    /// The assignments recorded for service `name`, walked by `index`:
    /// `body.assignment`, or `end` past the last. How a service learns
    /// what it should drive without knowing a single vendor id.
    claim,
    /// One driver the manager knows, by `index`: `body.driver`.
    list,
    /// Start the stopped driver process named `name`.
    start,
    /// Stop the running driver process named `name`.
    stop,
    /// Read the manifest directory again and bind anything new.
    rescan,
};

pub const Status = enum(u8) {
    ok,
    refused,
    end,
};

pub const Req = extern struct {
    tag: Tag,
    name_len: u8 = 0,
    _pad: [2]u8 = @splat(0),
    index: u32 = 0,
    name: [NAME_MAX]u8 = @splat(0),

    pub fn named(tag: Tag, text: []const u8) ?Req {
        if (text.len > NAME_MAX) return null;
        var req = Req{ .tag = tag, .name_len = @intCast(text.len) };
        @memcpy(req.name[0..text.len], text);
        return req;
    }

    pub fn nameSlice(self: *const Req) []const u8 {
        return self.name[0..@min(self.name_len, NAME_MAX)];
    }
};

/// One device a service should drive: where it is, and which of the
/// service's compiled-in drivers the manifest named for it.
pub const Assignment = extern struct {
    /// `lib.pci.Location`, packed.
    location: u16 = 0,
    driver_len: u8 = 0,
    _pad: u8 = 0,
    driver: [NAME_MAX]u8 = @splat(0),

    pub fn driverSlice(self: *const Assignment) []const u8 {
        return self.driver[0..@min(self.driver_len, NAME_MAX)];
    }
};

/// How a driver stands, for the listing and the control verbs.
pub const DriverState = enum(u8) {
    /// Recorded for a service to claim.
    assigned,
    /// A process the manager started, still running as far as it knows.
    running,
    /// A process the manager stopped, or that never started.
    stopped,
};

pub const DriverInfo = extern struct {
    name: [NAME_MAX]u8 = @splat(0),
    name_len: u8 = 0,
    state: DriverState = .stopped,
    location: u16 = 0,
    /// Which service consumes it, empty for a standalone process.
    service: [NAME_MAX]u8 = @splat(0),
    service_len: u8 = 0,

    pub fn nameSlice(self: *const DriverInfo) []const u8 {
        return self.name[0..@min(self.name_len, NAME_MAX)];
    }

    pub fn serviceSlice(self: *const DriverInfo) []const u8 {
        return self.service[0..@min(self.service_len, NAME_MAX)];
    }
};

pub const Rep = extern struct {
    status: Status = .ok,
    _pad: [3]u8 = @splat(0),
    body: Body = .{ .none = 0 },
};

pub const Body = extern union {
    none: u32,
    assignment: Assignment,
    driver: DriverInfo,
};

pub const Error = error{ NoService, Refused, End };

pub fn call(request: Req, into: *Rep) Error!void {
    const channel = sys.svcConnect(SERVICE);
    if (channel < 0) return error.NoService;
    defer _ = sys.close(@intCast(channel));

    const message = sys.Message.init(std.mem.asBytes(&request), &.{});
    var answer = sys.Message{};
    if (sys.callMsg(@intCast(channel), &message, &answer) < 0) return error.Refused;

    const bytes = answer.bytes();
    if (bytes.len < @sizeOf(Rep)) return error.Refused;
    into.* = @as(*const Rep, @alignCast(@ptrCast(bytes.ptr))).*;

    return switch (into.status) {
        .ok => {},
        .end => error.End,
        .refused => error.Refused,
    };
}

/// A service's claim walk, waiting out the manager's own startup: the
/// manager binds the bus once at boot, and a service racing it should ask
/// again rather than conclude it owns nothing.
pub fn claimNext(service_name: []const u8, index: u32, into: *Assignment) Error!void {
    var req = Req.named(.claim, service_name) orelse return error.Refused;
    req.index = index;

    var waited: u32 = 0;
    while (true) {
        var reply = Rep{};
        if (call(req, &reply)) {
            into.* = reply.body.assignment;
            return;
        } else |err| {
            if (err != error.NoService or waited >= 2_000_000) return err;
            sys.sleepMicros(20_000);
            waited += 20_000;
        }
    }
}

comptime {
    if (@sizeOf(Req) > sys.MAX_PAYLOAD) @compileError("a devices request must fit one payload");
    if (@sizeOf(Rep) > sys.MAX_PAYLOAD) @compileError("a devices reply must fit one payload");
}

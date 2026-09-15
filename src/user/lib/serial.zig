//! The program's side of a serial port.
//!
//! Ask which ports there are, take one, and read and write its bytes
//! through the ring that came with it. The bytes never cross a channel:
//! what does is the small part, which is how the line is set and what the
//! far end says it is doing.
//!
//! Waiting is on the port's own event, so a program with nothing to say
//! and nothing arriving costs nothing at all.

const lib = @import("lib");
const proto = @import("proto").serial;
const sys = @import("sys");

/// What a line is set to, and what it says it is doing. Named here as
/// well as in `lib.serial`, so a caller of this needs nothing else.
pub const Line = lib.serial.Line;
pub const Held = lib.serial.Held;
pub const State = lib.serial.State;
pub const Info = proto.PortInfo;
pub const Error = proto.Error;

/// The lines a program holds up while it has the port: both, because a
/// great many devices send nothing until they are told somebody is here.
pub const PRESENT: Held = .{ .dtr = true, .rts = true };

/// How many ports the machine has, driven or not.
pub fn count() Error!u32 {
    var reply = proto.Rep{};
    try proto.call(.{ .tag = .count }, &reply);
    return reply.body.count;
}

/// One port, by the number it is listed under.
pub fn at(index: u32) Error!Info {
    var reply = proto.Rep{};
    try proto.call(.{ .tag = .port, .index = index }, &reply);
    return reply.body.port;
}

/// The port a person named, by the name it is listed under.
///
/// The table is sparse, so a row nothing occupies is skipped rather than
/// read as the end of it: a port pulled out leaves the ones after it
/// where they were.
pub fn named(what: []const u8) Error!u32 {
    var index: u32 = 0;
    while (true) : (index += 1) {
        const info = try at(index);
        if (info.name_len == 0) continue;
        if (lib.str.eqlFold(info.nameSlice(), what)) return index;
    }
}

/// An event signalled whenever a port is offered or taken away, and the
/// channel it came from, which has to be held for the event to keep
/// meaning anything.
pub const Watch = struct {
    channel: u32,
    event: u32,

    pub fn close(self: Watch) void {
        sys.close(self.event);
        sys.close(self.channel);
    }
};

/// Wait on the ports rather than asking after them.
///
/// For a program that wants a port that is not there yet: an adapter is
/// plugged in at a moment nothing else marks, and asking again every so
/// often is a syscall a minute forever on a machine where one may never
/// be plugged in at all.
pub fn watch() Error!Watch {
    const channel = sys.svcConnect(proto.SERVICE) catch return error.NoService;
    errdefer sys.close(channel);

    var reply = proto.Rep{};
    var handles: [1]u32 = undefined;
    try proto.callTaking(@intCast(channel), .{ .tag = .watch }, &reply, &handles);
    return .{ .channel = @intCast(channel), .event = handles[0] };
}

/// One port, open.
pub const Port = struct {
    channel: u32,
    index: u32,
    shm: u32,
    /// Where the segment is mapped, kept because the mapping holds it as
    /// much as the handle does.
    base: [*]u8,
    ev: u32,
    doorbell: u32,
    view: proto.View,
    info: Info,

    pub fn open(index: u32) Error!Port {
        const channel = sys.svcConnect(proto.SERVICE) catch return error.NoService;
        errdefer sys.close(channel);

        var reply = proto.Rep{};
        var handles: [proto.GRANT_HANDLES]u32 = undefined;
        try proto.callTaking(@intCast(channel), .{ .tag = .open, .index = index }, &reply, &handles);

        const base = sys.shmMap(handles[0], .{ .writable = true }) orelse {
            for (handles) |handle| sys.close(handle);
            return error.Refused;
        };
        const view = proto.View.of(base) catch {
            sys.shmUnmap(base);
            for (handles) |handle| sys.close(handle);
            return error.Refused;
        };
        return .{
            .channel = @intCast(channel),
            .index = index,
            .shm = handles[0],
            .base = base,
            .ev = handles[1],
            .doorbell = handles[2],
            .view = view,
            .info = reply.body.port,
        };
    }

    pub fn close(self: *const Port) void {
        var reply = proto.Rep{};
        proto.callOn(self.channel, .{ .tag = .close, .index = self.index }, &reply) catch {};
        sys.shmUnmap(self.base);
        sys.close(self.shm);
        sys.close(self.ev);
        sys.close(self.doorbell);
        sys.close(self.channel);
    }

    /// As much as `into` holds of what has arrived.
    pub fn read(self: *const Port, into: []u8) u32 {
        return self.view.from.read(into);
    }

    /// As much of `bytes` as the ring takes, the service told when any.
    ///
    /// Partial rather than all or nothing: a full ring means the device
    /// has not kept up, and a caller with more to say waits on the same
    /// event it waits on for bytes.
    pub fn write(self: *const Port, bytes: []const u8) u32 {
        const took = self.view.to.write(bytes);
        if (took != 0) sys.eventSignal(self.doorbell);
        return took;
    }

    /// The handle to wait on: signalled when something arrived, when
    /// room was made for what is being written, or when the line
    /// changed.
    pub fn waitHandle(self: *const Port) u32 {
        return self.ev;
    }

    /// Whether the port has gone: the device was unplugged, or somebody
    /// else took it.
    pub fn ended(self: *const Port) bool {
        return self.view.from.isClosed();
    }

    /// Whether anything arrived with nowhere to put it since this was
    /// last asked, which is a gap in what has been read rather than a
    /// delay in it.
    pub fn lost(self: *const Port) bool {
        return self.view.from.takeOverflow();
    }

    /// Set how the line is to be treated, and hold up the lines that say
    /// a program is here.
    pub fn set(self: *Port, line: Line, held: Held) Error!void {
        var reply = proto.Rep{};
        try proto.callOn(
            self.channel,
            .{ .tag = .set_line, .index = self.index, .line = line, .held = held },
            &reply,
        );
        self.info = reply.body.port;
    }

    /// Hold the line at break for so many milliseconds.
    pub fn breaking(self: *const Port, milliseconds: u16) Error!void {
        var reply = proto.Rep{};
        return proto.callOn(
            self.channel,
            .{ .tag = .send_break, .index = self.index, .value = milliseconds },
            &reply,
        );
    }

    /// The port as it stands now, which is how the far end's state is
    /// read: the service keeps it as the device reports it.
    pub fn look(self: *Port) Error!Info {
        var reply = proto.Rep{};
        try proto.callOn(self.channel, .{ .tag = .port, .index = self.index }, &reply);
        self.info = reply.body.port;
        return self.info;
    }
};

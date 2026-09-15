//! Serial ports, offered to programs.
//!
//! A driver here finds a port on a device and offers it; this gives it a
//! name, answers what programs ask about it, and carries its bytes. What
//! kind of device it is stops at the offer: what a serial port does is in
//! `Ops`, and a second driver for a different chip is that table and
//! nothing else.
//!
//! **The bytes go through a ring and never through the channel.** A
//! program that has the port open holds a shared segment with one ring
//! each way. It waits on an event and is woken when something arrives;
//! it rings a doorbell when it has written something, and this service,
//! waiting on that doorbell alongside everything else, sends it. Nothing
//! polls on either side, and a port with nothing coming or going costs
//! nothing at all.
//!
//! **One program to a port, and the last to ask has it.** A byte read is
//! gone, so two readers would each get some of the traffic and neither
//! would get the message. Taking a port that somebody else had leaves
//! their ring closed and their segment theirs: they see it end rather
//! than quietly losing half of what arrives, and a program that exited
//! without giving the port back does not hold it forever. Everything
//! after that is the holder's alone: the kernel says who sent a message,
//! so a port cannot be set or given back by somebody who has not got it.

const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const proto = @import("proto").serial;
const str = @import("ulib").str;
const sys = @import("sys");
const table = @import("ulib").table;

const Held = lib.serial.Held;
const Line = lib.serial.Line;
const State = lib.serial.State;

/// How many ports at once. More than anyone plugs into this machine, and
/// each one costs a watched endpoint on its controller.
pub const MAX_PORTS = 4;

/// The most that is sent to a device in one go, and how many of those
/// one pass will do.
///
/// Together these bound how long a program with a full ring can keep
/// this service from everything else it carries: a transfer to a device
/// is waited on, and a disk being read behind the same controller waits
/// with it. What is left over is not dropped; the doorbell is rung again
/// and the pass comes back round after everything else has had its turn.
const CHUNK = 256;
const ROUNDS = 4;

/// Which port on which device. A device may carry more than one, and the
/// interface that takes its requests is what tells them apart.
pub const Which = struct {
    address: u7 = 0,
    interface: u8 = 0,

    fn same(self: Which, other: Which) bool {
        return self.address == other.address and self.interface == other.interface;
    }
};

/// What a driver for a kind of serial device provides.
pub const Ops = struct {
    /// Set how the line is to be treated. Answering false leaves the
    /// port at whatever it was.
    setLine: *const fn (which: Which, line: Line) bool,
    /// Hold up or drop the lines that say a program is here.
    hold: *const fn (which: Which, held: Held) bool,
    /// Send what a program wrote, answering how much moved. The bytes
    /// are this service's own buffer, handed on as they are so a write
    /// crossing to the device is not copied twice.
    send: *const fn (which: Which, bytes: []u8) usize,
    /// Hold the line at break for so many milliseconds. Absent where the
    /// device cannot time it itself, since holding it here would stop
    /// everything else this service carries for as long as it lasted.
    breaking: ?*const fn (which: Which, milliseconds: u16) bool = null,
    /// A program took the port, or gave it back.
    ///
    /// Where a driver stands its read on the device. Bytes arriving with
    /// nobody to take them go nowhere, so a device that talks to itself
    /// would otherwise wake this service forever for something nobody
    /// wants. Absent on a driver with nothing to start or stop.
    opened: ?*const fn (which: Which, open: bool) void = null,
};

/// What a driver says about a port as it offers it.
pub const About = struct {
    vendor: u16 = 0,
    product: u16 = 0,
    /// Whether the device has anywhere to say what its line is doing.
    reports: bool = false,
    /// The line as the driver has already set it, which is what a
    /// program sees before it asks for anything else.
    line: Line = .{},
    held: Held = .{},
};

const Port = struct {
    live: bool = false,
    which: Which = .{},
    ops: *const Ops = undefined,
    vendor: u16 = 0,
    product: u16 = 0,
    reports: bool = false,
    line: Line = .{},
    held: Held = .{},
    state: State = .{},
    /// Whether anything arrived with nowhere to put it since the port
    /// was opened.
    lost: bool = false,
    /// The process holding it, as the kernel attested it. Zero when
    /// nobody has it.
    owner: u32 = 0,
    name: [proto.NAME_MAX]u8 = @splat(0),
    name_len: u8 = 0,
    /// The segment a program's bytes travel through, while one has it.
    shm: u32 = 0,
    base: ?[*]u8 = null,
    /// What the program waits on, rung when something arrived or when
    /// room was made for what it is writing.
    ev: u32 = 0,
    view: proto.View = undefined,

    fn taken(self: *const Port) bool {
        return self.base != null;
    }

    fn nameSlice(self: *const Port) []const u8 {
        return self.name[0..@min(self.name_len, self.name.len)];
    }
};

var ports: [MAX_PORTS]Port = @splat(.{});

/// The one doorbell every program with a port open rings, so this service
/// waits on a single handle however many ports are open.
var bell: u32 = 0;
var service: u32 = 0;

/// Signalled when a port is offered or taken away, for programs waiting
/// for one to appear. Made the first time somebody asks: a machine nobody
/// is watching the ports of does not carry an event for it.
var table_changed: u32 = 0;

/// Say that the table changed.
fn stirred() void {
    if (table_changed != 0) sys.eventSignal(table_changed);
}

/// Take the service name and make the doorbell.
///
/// Called once the bus has been walked, for the same reason the bus's own
/// name is: a name that is up says the ports behind it are there. Ports
/// found before this are already in the table; what this adds is the way
/// to ask about them.
pub fn start() void {
    bell = sys.eventCreate() catch {
        log.warn("serial", "no doorbell; ports will not be offered");
        return;
    };
    const taken = sys.svcRegister(proto.SERVICE) catch {
        log.warn("serial", "the service name was refused; ports will not be offered");
        sys.close(bell);
        bell = 0;
        return;
    };
    service = @intCast(taken);
}

/// The handles worth waking for: the channel programs ask on, and the
/// doorbell they ring when they have written something.
pub fn watching(into: []u32) usize {
    if (service == 0 or into.len < 2) return 0;
    into[0] = service;
    into[1] = bell;
    return 2;
}

pub fn channel() u32 {
    return service;
}

pub fn doorbell() u32 {
    return bell;
}

// ---------------------------------------------------------------------------
// Coming and going
// ---------------------------------------------------------------------------

/// Offer a port. Answering false leaves the device driven and its port
/// unnamed, which is what running out of room looks like.
pub fn offer(which: Which, ops: *const Ops, about: About) bool {
    if (forWhich(which) != null) return true;

    const slot = table.free(&ports) orelse {
        log.warn("serial", "no room for another port");
        return false;
    };
    const index = table.indexOf(&ports, slot);

    slot.* = .{
        .live = true,
        .which = which,
        .ops = ops,
        .vendor = about.vendor,
        .product = about.product,
        .reports = about.reports,
        .line = about.line,
        .held = about.held,
    };
    slot.name_len = nameFor(&slot.name, index);
    stirred();

    var spelt: [24]u8 = undefined;
    log.begin("serial", .key);
    out.text(slot.nameSlice());
    out.text(": ");
    out.text(slot.line.spell(&spelt));
    log.end();
    return true;
}

/// Withdraw every port of a device that has gone.
pub fn withdraw(address: u7) void {
    for (&ports) |*port| {
        if (!port.live or port.which.address != address) continue;
        // Closed rather than silently dropped: a program reading the
        // ring sees the port end instead of waiting on bytes that are
        // never coming.
        release(port, .closed);
        log.begin("serial", .key);
        out.text(port.nameSlice());
        out.text(" is gone");
        log.end();
        port.* = .{};
        stirred();
    }
}

/// What becomes of a program's ring when its port is taken away.
const Ending = enum {
    /// The device went, or somebody else took the port: the ring is
    /// marked finished so the program stops waiting on it.
    closed,
    /// The program gave it back and knows perfectly well.
    given_back,
};

fn release(port: *Port, ending: Ending) void {
    if (port.base == null) return;
    if (port.ops.opened) |tell| tell(port.which, false);
    if (ending == .closed) {
        port.view.from.close();
        port.view.to.close();
        sys.eventSignal(port.ev);
    }
    sys.shmUnmap(port.base.?);
    sys.close(port.shm);
    sys.close(port.ev);
    port.base = null;
    port.shm = 0;
    port.ev = 0;
    port.owner = 0;
}

/// What a port is called: the kind and a number, the way every other
/// device on this machine is named.
fn nameFor(into: *[proto.NAME_MAX]u8, index: usize) u8 {
    var text = str.Builder{ .buf = into };
    text.text("ser");
    text.number(index);
    return @intCast(text.done().len);
}

fn forWhich(which: Which) ?*Port {
    for (&ports) |*port| {
        if (port.live and port.which.same(which)) return port;
    }
    return null;
}

// ---------------------------------------------------------------------------
// The bytes
// ---------------------------------------------------------------------------

/// Bytes a device sent. Called by the driver when its controller woke and
/// the endpoint had something on it.
pub fn arrived(which: Which, bytes: []const u8) void {
    if (bytes.len == 0) return;
    const port = forWhich(which) orelse return;
    // Nobody is reading: the bytes go nowhere rather than into a ring
    // that would be full by the time somebody did.
    if (!port.taken()) return;

    const took = port.view.from.write(bytes);
    if (took < bytes.len) {
        port.view.from.markOverflow();
        port.lost = true;
    }
    sys.eventSignal(port.ev);
}

/// What the device says its end of the line is doing.
pub fn said(which: Which, state: State) void {
    const port = forWhich(which) orelse return;
    port.state = state;
    // A program watching the line wakes for this as it does for bytes:
    // a carrier dropping is news whether or not anything came with it.
    if (port.taken()) sys.eventSignal(port.ev);
}

/// Send what the programs have written. Called because the doorbell rang.
///
/// Every port in one pass, because one doorbell serves them all and the
/// one that rang is not worth working out. A port with nothing in its
/// ring costs a load and a comparison.
pub fn pump() void {
    var buffer: [CHUNK]u8 = undefined;
    var again = false;

    for (&ports) |*port| {
        if (!port.live or !port.taken()) continue;

        var moved: usize = 0;
        for (0..ROUNDS) |_| {
            const took = port.view.to.read(buffer[0..]);
            if (took == 0) break;
            const sent = port.ops.send(port.which, buffer[0..took]);
            moved += sent;
            // The device would not take it all, so it will not take any
            // more now either. What is left stays in the ring.
            if (sent < took) break;
        }
        // Room was made: a program held up against a full ring wakes.
        if (moved != 0) sys.eventSignal(port.ev);
        if (!port.view.to.isEmpty()) again = true;
    }

    // Still something to send. Rung rather than sent now, so everything
    // else waiting on this service is served before this comes round
    // again: one program writing hard must not stop a disk being read.
    if (again) sys.eventSignal(bell);
}

// ---------------------------------------------------------------------------
// What programs ask
// ---------------------------------------------------------------------------

/// Everything a program has asked since the last pass.
pub fn drain() void {
    while (true) {
        var message = sys.Message{};
        const request = sys.recv(service, &message, sys.POLL) orelse return;
        handle(&message, request.token);
    }
}

fn handle(message: *const sys.Message, token: u32) void {
    const req = proto.requestIn(message) orelse return refuse(token);
    if (!proto.known(req.tag)) return refuse(token);
    const sender = message.sender;

    switch (req.tag) {
        .count => {
            var live: u32 = 0;
            for (&ports) |*port| {
                if (port.live) live += 1;
            }
            replyBody(token, .{ .count = live });
        },
        .port => {
            if (req.index >= ports.len) return replyEnd(token);
            const port = at(req.index) orelse {
                // The table is sparse: a row nothing occupies is one to
                // skip, not the end of the walk. A port pulled out
                // leaves its row empty and the ones after it where they
                // were, so what a person was told a port is called does
                // not change under them.
                return replyBody(token, .{ .port = .{} });
            };
            replyBody(token, .{ .port = describe(port) });
        },
        .open => open(req.index, sender, token),
        .close => {
            const port = held(req.index, sender) orelse return refuse(token);
            release(port, .given_back);
            replyBody(token, .{ .port = describe(port) });
        },
        .set_line => setLine(req, sender, token),
        .send_break => sendBreak(req, sender, token),
        .watch => watch(token),
    }
}

/// Hand over the event that says the table changed.
fn watch(token: u32) void {
    if (table_changed == 0) {
        table_changed = sys.eventCreate() catch return refuse(token);
    }
    var reply = proto.Rep{};
    proto.answerWith(service, token, &reply, &.{table_changed});
}

fn at(index: u32) ?*Port {
    if (index >= ports.len) return null;
    const port = &ports[@intCast(index)];
    return if (port.live) port else null;
}

/// The port at `index`, if this sender is the one holding it.
///
/// Taking a port is anybody's; everything after that is the holder's.
/// The sender is the kernel's word rather than the message's, so it is
/// not something a caller can claim to be somebody else by.
fn held(index: u32, sender: u32) ?*Port {
    const port = at(index) orelse return null;
    if (!port.taken() or port.owner != sender) return null;
    return port;
}

fn describe(port: *Port) proto.PortInfo {
    var info = proto.PortInfo{
        .vendor = port.vendor,
        .product = port.product,
        .state = port.state,
        .line = port.line,
        .held = port.held,
        .reports = @intFromBool(port.reports),
        .taken = @intFromBool(port.taken()),
        .lost = @intFromBool(port.lost),
        .name_len = port.name_len,
    };
    @memcpy(&info.name, &port.name);
    return info;
}

fn open(index: u32, sender: u32, token: u32) void {
    const port = at(index) orelse return replyEnd(token);

    // Whoever had it sees their ring end. They keep their own segment,
    // so nothing they are still holding goes out from under them.
    release(port, .closed);

    const created = sys.shmCreate(proto.SHM_BYTES) catch return refuse(token);
    const base = sys.shmMap(@intCast(created), .{ .writable = true }) orelse {
        sys.close(@intCast(created));
        return refuse(token);
    };
    const ev = sys.eventCreate() catch {
        sys.shmUnmap(base);
        sys.close(@intCast(created));
        return refuse(token);
    };
    const view = proto.View.make(base) catch {
        sys.shmUnmap(base);
        sys.close(@intCast(created));
        sys.close(ev);
        return refuse(token);
    };

    port.shm = @intCast(created);
    port.base = base;
    port.ev = ev;
    port.view = view;
    port.lost = false;
    port.owner = sender;
    if (port.ops.opened) |tell| tell(port.which, true);

    var reply = proto.Rep{ .body = .{ .port = describe(port) } };
    proto.answerWith(service, token, &reply, &.{ port.shm, port.ev, bell });
}

fn setLine(req: *const proto.Req, sender: u32, token: u32) void {
    const port = held(req.index, sender) orelse return refuse(token);
    if (!req.line.sane()) return refuse(token);

    if (!port.ops.setLine(port.which, req.line)) return refuse(token);
    port.line = req.line;

    // The lines go with the settings: a program saying how it wants the
    // port is also saying it is there.
    if (port.ops.hold(port.which, req.held)) port.held = req.held;
    replyBody(token, .{ .port = describe(port) });
}

fn sendBreak(req: *const proto.Req, sender: u32, token: u32) void {
    const port = held(req.index, sender) orelse return refuse(token);
    const hold = port.ops.breaking orelse return refuse(token);
    if (!hold(port.which, req.value)) return refuse(token);
    replyBody(token, .{ .port = describe(port) });
}

fn refuse(token: u32) void {
    var reply = proto.Rep{ .status = .refused };
    proto.answer(service, token, &reply);
}

fn replyEnd(token: u32) void {
    var reply = proto.Rep{ .status = .end };
    proto.answer(service, token, &reply);
}

fn replyBody(token: u32, body: proto.Body) void {
    var reply = proto.Rep{ .body = body };
    proto.answer(service, token, &reply);
}

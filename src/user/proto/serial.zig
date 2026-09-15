//! What programs and the bus service say about serial ports.
//!
//! Wire types only, compiled by both sides. A program asks which ports
//! there are, takes one, and reads and writes its bytes through the ring
//! it was granted; the bytes never cross the channel. What does cross it
//! is the small part: how the line is set, which of the two lines the
//! host holds up, and what the device says its end is doing.
//!
//! One program to a port. A byte read is gone, so two readers would each
//! get some of the traffic and neither would get the message. Opening one
//! somebody else had takes it and leaves their end closed; everything
//! after opening is the holder's alone, since the kernel says who sent a
//! message and the service takes its word for it.

const lib = @import("lib");
const ring = lib.ring;
/// What a line is set to, and what it says it is doing. Named here as
/// well, so a caller of this protocol needs nothing else to ask.
pub const serial = lib.serial;
const endpoint = @import("endpoint.zig");
const Endpoint = endpoint.Endpoint;

pub const SERVICE = "serial";

pub const Tag = enum(u8) {
    /// How many ports there are, driven or not.
    count,
    /// One port, at `index`, or `end` past the table: `body.port`. A row
    /// nothing occupies answers with an unnamed port, which is a row to
    /// skip rather than the end of the walk.
    port,
    /// Take the port at `index`. The reply grants the segment its bytes
    /// travel through, the event this program waits on, and the one it
    /// rings when it has written something.
    open,
    /// Give it back. Whatever was still in the rings goes with it.
    close,
    /// Set the port at `index` to `line`, holding up the lines `held`
    /// names: `body.port` answers with the port as it now stands.
    set_line,
    /// Hold the port at `index` at break for `value` milliseconds, or
    /// until told otherwise where that is `BREAK_UNTIL_TOLD`. Refused by
    /// a port whose device cannot time a break itself.
    send_break,
};

pub const Status = enum(u8) {
    ok,
    refused,
    /// Nothing at that index: how a walker finds the end of the table.
    end,
    /// Somebody else has the port.
    taken,

    pub fn check(self: Status) Error!void {
        return switch (self) {
            .ok => {},
            .refused => error.Refused,
            .end => error.End,
            .taken => error.Taken,
        };
    }
};

pub const Req = extern struct {
    tag: Tag,
    held: serial.Held = .{},
    /// Milliseconds, for `send_break`.
    value: u16 = 0,
    index: u32 = 0,
    line: serial.Line = .{},
    _tail: u8 = 0,
};

/// Hold the line at break until something says otherwise.
pub const BREAK_UNTIL_TOLD: u16 = 0xFFFF;

/// As long as a port's name is. Long enough for the kind and a number,
/// which is all a port is called.
pub const NAME_MAX = 8;

pub const PortInfo = extern struct {
    /// Who the device is on the bus, so two adapters can be told apart.
    vendor: u16 = 0,
    product: u16 = 0,
    /// What the device last said its end of the line is doing. All zero
    /// on a port whose device has nowhere to say it.
    state: serial.State = .{},
    /// How the line is set now.
    line: serial.Line = .{},
    /// Which lines the host is holding up.
    held: serial.Held = .{},
    /// Whether the device has anywhere to say what its line is doing. A
    /// port without it works; its state simply never changes.
    reports: u8 = 0,
    /// Whether a program has it open.
    taken: u8 = 0,
    /// Whether anything arrived faster than it was read since the port
    /// was opened. Said here rather than in the ring, because the one
    /// place it cannot be said is in the ring that had no room.
    lost: u8 = 0,
    name_len: u8 = 0,
    name: [NAME_MAX]u8 = @splat(0),
    _tail: [2]u8 = @splat(0),

    pub fn nameSlice(self: *const PortInfo) []const u8 {
        return self.name[0..@min(self.name_len, self.name.len)];
    }
};

pub const Rep = extern struct {
    status: Status = .ok,
    _pad: [3]u8 = @splat(0),
    body: Body = .{ .count = 0 },
};

pub const Body = extern union {
    count: u32,
    port: PortInfo,
};

/// What `open` hands over: the segment, the event this program waits on,
/// and the one it rings when it has written something.
pub const GRANT_HANDLES = 3;

// ---------------------------------------------------------------------------
// The rings
// ---------------------------------------------------------------------------

/// How much each direction of a port holds.
///
/// A third of a second at the fastest line these devices run, which is
/// long enough that a program busy with something else for a moment
/// loses nothing, and short enough that what it eventually reads is
/// still worth having.
pub const CAPACITY: u32 = 4096;

/// Where the bytes begin: the two sets of counters come first, one to a
/// direction, each in its own aligned slot so neither side's writes land
/// in the other's.
const HEADERS: usize = 64;

pub const SHM_BYTES: usize = HEADERS + 2 * @as(usize, CAPACITY);

/// Both directions of one port, as either side sees them.
///
/// Each ring has one writer and one reader, which is what lets them work
/// with two counters and no lock: the service fills `from` and drains
/// `to`, and the program does the opposite.
pub const View = struct {
    /// The device into the program.
    from: ring.Ring,
    /// The program into the device.
    to: ring.Ring,

    const FROM = 0;
    const TO = 1;

    /// Lay fresh rings over a new segment. The service does this once,
    /// when it makes the segment.
    pub fn make(base: [*]u8) ring.Error!View {
        return .{
            .from = try ring.Ring.init(headerAt(base, FROM), bytesAt(base, FROM)),
            .to = try ring.Ring.init(headerAt(base, TO), bytesAt(base, TO)),
        };
    }

    /// Bind to rings that are already there, which is what a program
    /// does with the segment it was granted.
    pub fn of(base: [*]u8) ring.Error!View {
        return .{
            .from = try ring.Ring.attach(headerAt(base, FROM), bytesAt(base, FROM)),
            .to = try ring.Ring.attach(headerAt(base, TO), bytesAt(base, TO)),
        };
    }

    fn headerAt(base: [*]u8, which: usize) *volatile ring.Header {
        return @ptrCast(@alignCast(base + which * @sizeOf(ring.Header)));
    }

    fn bytesAt(base: [*]u8, which: usize) []u8 {
        return (base + HEADERS + which * CAPACITY)[0..CAPACITY];
    }
};

pub const Error = error{ NoService, Refused, End, Taken };

pub const link = Endpoint(SERVICE, Req, Rep, Error);
pub const call = link.call;
pub const callOn = link.callOn;
pub const callTaking = link.callTaking;
pub const requestIn = link.requestIn;

/// Whether a request tag is one this protocol defines. See `endpoint.known`.
pub const known = endpoint.known;
pub const answer = link.answer;
pub const answerWith = link.answerWith;

comptime {
    if (2 * @sizeOf(ring.Header) > HEADERS) @compileError("the counters do not fit before the bytes");
    if (CAPACITY & (CAPACITY - 1) != 0) @compileError("a ring's capacity is a power of two");
}

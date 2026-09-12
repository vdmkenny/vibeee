//! worker_proto: what the reader and the worker say to each other.
//!
//! Wire only: the frames, their tags, and the fields each tag carries. No
//! transport, no engine, no parser, no allocation, so `web` and
//! `script_worker` compile the same definitions and neither can drift from
//! the other — which is the whole reason this is a file of its own rather
//! than the same shape written out twice. design/13-script-worker.md §5.
//!
//! A frame is a four-byte length, then that many bytes: a tag and the fields
//! after it. The length is what makes the messages bounded. Whoever is
//! reading knows how much of a stream one message is before it has read any
//! of it, and can say "not yet" instead of waiting; a message that claims
//! more than `MAX_INLINE` is refused rather than believed. Longer payloads
//! travel by shared memory, which is not built yet.
//!
//! Decoded messages borrow from the bytes they were decoded from: their
//! fields point into the frame, so nothing here copies and nothing here
//! needs an allocator. Keep the frame as long as the message is read.
//!
//! Reading a stream: `frameLen` says whether a whole frame has arrived and
//! how long it is; when it is there, `decode` takes it and the reader moves
//! on by the length `frameLen` gave.

const std = @import("std");

/// The length prefix at the front of every frame: a u32, little-endian.
pub const HEADER_LEN = 4;

/// The most one message carries inline, §5. What is longer goes by shared
/// memory.
pub const MAX_INLINE = 64 * 1024;

/// The most one frame is, prefix included: what a caller keeps in order to
/// be able to write any message, or to read any one of them.
pub const MAX_FRAME = HEADER_LEN + MAX_INLINE;

// ---------------------------------------------------------------------------
// How long each field may be.
//
// A field over its cap is refused by `encode` rather than sent cut short,
// and a frame claiming one is refused by `decode` rather than read. The caps
// do not compete with the inline cap: they catch a field that is wrong on
// its own — an address that cannot be an address — before the frame around
// it is built, and they are what a receiver checks a claimed length against
// before it reads a byte.
// ---------------------------------------------------------------------------

/// An address: the bound `url` keeps.
pub const ADDRESS_MAX = 2048;
/// What the reader calls itself to a site.
pub const AGENT_MAX = 256;
/// An encoding's name, as a page spells it.
pub const CHARSET_MAX = 32;
/// A page's markup.
pub const MARKUP_MAX = 48 * 1024;
/// One stylesheet the reader kept.
pub const SHEET_MAX = 8 * 1024;
/// How many stylesheets one `start` carries.
pub const MAX_SHEETS = 8;
/// A script's source, or the URL it is to be fetched from.
pub const SOURCE_MAX = 32 * 1024;
/// What was typed into a control.
pub const VALUE_MAX = 8 * 1024;
/// What a fetch answered with.
pub const BODY_MAX = 48 * 1024;
/// A cookie line, read or written.
pub const COOKIE_MAX = 4096;
/// An exception's text.
pub const ERROR_MAX = 4096;
/// The name of an API a script asked for and did not get.
pub const NAME_MAX = 64;

// ---------------------------------------------------------------------------
// The messages
// ---------------------------------------------------------------------------

/// Every message, in the order of the two tables in §5: what the reader
/// sends the worker, then what the worker answers with.
pub const Tag = enum(u8) {
    // web -> worker
    start,
    script,
    click,
    typed,
    fetch_reply,
    cookie_read,
    cookie_write,
    tick,
    stop,

    // worker -> web
    page,
    navigate,
    fetch_request,
    cookie_value,
    script_error,
    missing,
    stopped,
};

/// Which way a message goes. A worker sent a `page` is being sent something
/// it cannot have meant to send, and the same the other way round: worth
/// being able to say out loud.
pub const Direction = enum {
    to_worker,
    from_worker,
};

pub fn directionOf(tag: Tag) Direction {
    return switch (tag) {
        .start,
        .script,
        .click,
        .typed,
        .fetch_reply,
        .cookie_read,
        .cookie_write,
        .tick,
        .stop,
        => .to_worker,

        .page,
        .navigate,
        .fetch_request,
        .cookie_value,
        .script_error,
        .missing,
        .stopped,
        => .from_worker,
    };
}

/// Why a worker is no longer running. The reader shows what it can of this:
/// a page whose scripts stopped because they were asked to is not a page
/// whose scripts stopped because they broke.
pub const StopReason = enum(u8) {
    /// The reader asked: `stop` arrived, or the navigation moved on.
    asked,
    /// Something in this process faulted: the engine, the bridge, the parse.
    fault,
    /// A page's scripts are switched off, so no worker was started for it.
    scripts_off,
};

/// The stylesheets a `start` carries, a bounded number of them. A page's
/// styles are handfuls, and a list that could grow without end inside a
/// message that cannot is a list someone will read past the end of.
pub const Sheets = struct {
    len: usize = 0,
    items: [MAX_SHEETS][]const u8 = [_][]const u8{""} ** MAX_SHEETS,

    pub const Error = error{Full};

    pub fn add(self: *Sheets, text: []const u8) Error!void {
        if (self.len == MAX_SHEETS) return error.Full;
        self.items[self.len] = text;
        self.len += 1;
    }

    pub fn at(self: *const Sheets, index: usize) ?[]const u8 {
        return if (index < self.len) self.items[index] else null;
    }
};

pub const Start = struct {
    address: []const u8 = "",
    agent: []const u8 = "",
    markup: []const u8 = "",
    charset: []const u8 = "",
    sheets: Sheets = .{},
};

/// A script to run: `source` itself, or `url` to fetch it from when
/// `source` is empty.
pub const Script = struct {
    url: []const u8 = "",
    source: []const u8 = "",
};

pub const Click = struct {
    control: u32 = 0,
    run: u32 = 0,
};

pub const Typed = struct {
    control: u32 = 0,
    submitted: bool = false,
    value: []const u8 = "",
};

/// What a `fetchRequest` came back with. `failed` rather than a status that
/// means it: a fetch that never reached the site has no status to report.
pub const FetchReply = struct {
    id: u32 = 0,
    status: u16 = 0,
    failed: bool = false,
    body: []const u8 = "",
};

/// Which request this asks about: the id a `fetchRequest` went out with.
pub const Id = struct {
    id: u32 = 0,
};

/// One line of text: a cookie to write, or the name of an API that was
/// missing.
pub const Text = struct {
    text: []const u8 = "",
};

/// A page model. Its own serialization is still open (§11); here it is
/// bytes whose length is known.
pub const Blob = struct {
    bytes: []const u8 = "",
};

/// Where a page wants to go.
pub const Address = struct {
    address: []const u8 = "",
};

pub const FetchRequest = struct {
    id: u32 = 0,
    address: []const u8 = "",
};

pub const CookieValue = struct {
    id: u32 = 0,
    line: []const u8 = "",
};

pub const ScriptError = struct {
    url: []const u8 = "",
    text: []const u8 = "",
};

pub const Stopped = struct {
    reason: StopReason = .asked,
};

pub const Message = union(Tag) {
    start: Start,
    script: Script,
    click: Click,
    typed: Typed,
    fetch_reply: FetchReply,
    cookie_read: Id,
    cookie_write: Text,
    tick: void,
    stop: void,

    page: Blob,
    navigate: Address,
    fetch_request: FetchRequest,
    cookie_value: CookieValue,
    script_error: ScriptError,
    missing: Text,
    stopped: Stopped,

    /// Which message this is: the tag, which is what goes on the wire.
    pub fn tag(self: Message) Tag {
        return @as(Tag, self);
    }

    /// Which way it goes. See `directionOf`.
    pub fn direction(self: Message) Direction {
        return directionOf(self.tag());
    }
};

/// Whether two messages say the same thing. Fields are compared by their
/// bytes, not by where they point, so a decoded message equals the one that
/// was encoded even though it points into the frame it came out of.
pub fn eql(a: Message, b: Message) bool {
    if (a.tag() != b.tag()) return false;
    return switch (a) {
        .start => std.mem.eql(u8, a.start.address, b.start.address) and
            std.mem.eql(u8, a.start.agent, b.start.agent) and
            std.mem.eql(u8, a.start.markup, b.start.markup) and
            std.mem.eql(u8, a.start.charset, b.start.charset) and
            sheetsEql(a.start.sheets, b.start.sheets),
        .script => std.mem.eql(u8, a.script.url, b.script.url) and
            std.mem.eql(u8, a.script.source, b.script.source),
        .click => a.click.control == b.click.control and a.click.run == b.click.run,
        .typed => a.typed.control == b.typed.control and
            a.typed.submitted == b.typed.submitted and
            std.mem.eql(u8, a.typed.value, b.typed.value),
        .fetch_reply => a.fetch_reply.id == b.fetch_reply.id and
            a.fetch_reply.status == b.fetch_reply.status and
            a.fetch_reply.failed == b.fetch_reply.failed and
            std.mem.eql(u8, a.fetch_reply.body, b.fetch_reply.body),
        .cookie_read => a.cookie_read.id == b.cookie_read.id,
        .cookie_write => std.mem.eql(u8, a.cookie_write.text, b.cookie_write.text),
        .tick, .stop => true,
        .page => std.mem.eql(u8, a.page.bytes, b.page.bytes),
        .navigate => std.mem.eql(u8, a.navigate.address, b.navigate.address),
        .fetch_request => a.fetch_request.id == b.fetch_request.id and
            std.mem.eql(u8, a.fetch_request.address, b.fetch_request.address),
        .cookie_value => a.cookie_value.id == b.cookie_value.id and
            std.mem.eql(u8, a.cookie_value.line, b.cookie_value.line),
        .script_error => std.mem.eql(u8, a.script_error.url, b.script_error.url) and
            std.mem.eql(u8, a.script_error.text, b.script_error.text),
        .missing => std.mem.eql(u8, a.missing.text, b.missing.text),
        .stopped => a.stopped.reason == b.stopped.reason,
    };
}

fn sheetsEql(a: Sheets, b: Sheets) bool {
    if (a.len != b.len) return false;
    for (0..a.len) |index| {
        if (!std.mem.eql(u8, a.items[index], b.items[index])) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

/// The message did not fit: a field is over its cap, the frame is over
/// `MAX_INLINE`, or `out` is smaller than the frame would be. Nothing is
/// sent cut short, so this is the only way out of a message that is too
/// long.
pub const EncodeError = error{TooLarge};

/// Write `message` into `out`, prefix and all, and return the part of `out`
/// that is the frame.
pub fn encode(message: Message, out: []u8) EncodeError![]u8 {
    var w: std.Io.Writer = .fixed(out);
    // The prefix is filled in last, when the body's length is known, and its
    // four bytes are taken first so the body is written after them.
    try putInt(&w, u32, 0);
    try putByte(&w, @intFromEnum(message.tag()));
    try putFields(&w, message);

    const frame = w.buffered();
    const body = frame[HEADER_LEN..];
    if (body.len > MAX_INLINE) return error.TooLarge;

    var prefix: [HEADER_LEN]u8 = undefined;
    std.mem.writeInt(u32, &prefix, @intCast(body.len), .little);
    @memcpy(frame[0..HEADER_LEN], &prefix);
    return frame;
}

fn putFields(w: *std.Io.Writer, message: Message) EncodeError!void {
    switch (message) {
        .start => |m| {
            try putField(w, m.address, ADDRESS_MAX);
            try putField(w, m.agent, AGENT_MAX);
            try putField(w, m.markup, MARKUP_MAX);
            try putField(w, m.charset, CHARSET_MAX);
            try putInt(w, u16, @intCast(m.sheets.len));
            for (m.sheets.items[0..m.sheets.len]) |sheet| try putField(w, sheet, SHEET_MAX);
        },
        .script => |m| {
            try putField(w, m.url, ADDRESS_MAX);
            try putField(w, m.source, SOURCE_MAX);
        },
        .click => |m| {
            try putInt(w, u32, m.control);
            try putInt(w, u32, m.run);
        },
        .typed => |m| {
            try putInt(w, u32, m.control);
            try putBool(w, m.submitted);
            try putField(w, m.value, VALUE_MAX);
        },
        .fetch_reply => |m| {
            try putInt(w, u32, m.id);
            try putInt(w, u16, m.status);
            try putBool(w, m.failed);
            try putField(w, m.body, BODY_MAX);
        },
        .cookie_read => |m| try putInt(w, u32, m.id),
        .cookie_write => |m| try putField(w, m.text, COOKIE_MAX),
        .tick, .stop => {},
        .page => |m| try putField(w, m.bytes, MAX_INLINE),
        .navigate => |m| try putField(w, m.address, ADDRESS_MAX),
        .fetch_request => |m| {
            try putInt(w, u32, m.id);
            try putField(w, m.address, ADDRESS_MAX);
        },
        .cookie_value => |m| {
            try putInt(w, u32, m.id);
            try putField(w, m.line, COOKIE_MAX);
        },
        .script_error => |m| {
            try putField(w, m.url, ADDRESS_MAX);
            try putField(w, m.text, ERROR_MAX);
        },
        .missing => |m| try putField(w, m.text, NAME_MAX),
        .stopped => |m| try putByte(w, @intFromEnum(m.reason)),
    }
}

/// A length and then that many bytes, which is how every text field goes.
fn putField(w: *std.Io.Writer, bytes: []const u8, cap: usize) EncodeError!void {
    if (bytes.len > cap) return error.TooLarge;
    try putInt(w, u32, @intCast(bytes.len));
    w.writeAll(bytes) catch return error.TooLarge;
}

fn putInt(w: *std.Io.Writer, comptime T: type, value: T) EncodeError!void {
    w.writeInt(T, value, .little) catch return error.TooLarge;
}

fn putByte(w: *std.Io.Writer, byte: u8) EncodeError!void {
    w.writeByte(byte) catch return error.TooLarge;
}

fn putBool(w: *std.Io.Writer, value: bool) EncodeError!void {
    try putByte(w, if (value) 1 else 0);
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

pub const DecodeError = error{
    /// The frame is cut short: fewer bytes than its prefix claims, or a
    /// field promised and not there. Not a refusal — the rest may still
    /// arrive, so a caller reading a stream waits rather than gives up.
    Truncated,
    /// The frame claims more than `MAX_INLINE`, or a field more than its
    /// cap. Refused: nothing that long can be sent, so this is not a
    /// message that got cut short but one that never was one.
    TooLarge,
    /// A tag this protocol does not name.
    BadTag,
    /// A field that is not a value its type can hold: a boolean that is
    /// neither, a stop reason nobody named, more stylesheets than fit.
    BadField,
};

/// What `frameLen` answers: too short to say, or claiming what cannot be.
pub const FrameError = error{ Truncated, TooLarge };

/// How long the frame at the front of `bytes` is, prefix included. Shorter
/// than `HEADER_LEN`, or shorter than its own prefix claims, and the frame
/// has not all arrived yet; a prefix past the cap, and it never will.
pub fn frameLen(bytes: []const u8) FrameError!usize {
    if (bytes.len < HEADER_LEN) return error.Truncated;
    var prefix: [HEADER_LEN]u8 = undefined;
    @memcpy(&prefix, bytes[0..HEADER_LEN]);
    const body: usize = @intCast(std.mem.readInt(u32, &prefix, .little));
    if (body > MAX_INLINE) return error.TooLarge;
    const total = HEADER_LEN + body;
    if (bytes.len < total) return error.Truncated;
    return total;
}

/// Read one frame off the front of `bytes`. What follows it, if anything
/// does, is left alone: `frameLen` says how much to move on by. Bytes left
/// over inside the frame once its fields are read are ignored, so a field
/// added to a message later is not a reason for an older reader to refuse
/// the whole thing.
pub fn decode(bytes: []const u8) DecodeError!Message {
    const total = frameLen(bytes) catch |err| return err;
    var r: std.Io.Reader = .fixed(bytes[HEADER_LEN..total]);
    const tag = r.takeEnum(Tag, .little) catch |err| return switch (err) {
        error.EndOfStream, error.ReadFailed => error.Truncated,
        error.InvalidEnumTag => error.BadTag,
    };
    return getFields(&r, tag);
}

fn getFields(r: *std.Io.Reader, tag: Tag) DecodeError!Message {
    return switch (tag) {
        .start => blk: {
            const address = try getField(r, ADDRESS_MAX);
            const agent = try getField(r, AGENT_MAX);
            const markup = try getField(r, MARKUP_MAX);
            const charset = try getField(r, CHARSET_MAX);
            const count = try getInt(r, u16);
            if (count > MAX_SHEETS) return error.BadField;
            var sheets: Sheets = .{ .len = @intCast(count) };
            for (0..count) |index| sheets.items[index] = try getField(r, SHEET_MAX);
            break :blk .{ .start = .{
                .address = address,
                .agent = agent,
                .markup = markup,
                .charset = charset,
                .sheets = sheets,
            } };
        },
        .script => blk: {
            const url = try getField(r, ADDRESS_MAX);
            const source = try getField(r, SOURCE_MAX);
            break :blk .{ .script = .{ .url = url, .source = source } };
        },
        .click => blk: {
            const control = try getInt(r, u32);
            const run = try getInt(r, u32);
            break :blk .{ .click = .{ .control = control, .run = run } };
        },
        .typed => blk: {
            const control = try getInt(r, u32);
            const submitted = try getBool(r);
            const value = try getField(r, VALUE_MAX);
            break :blk .{ .typed = .{ .control = control, .submitted = submitted, .value = value } };
        },
        .fetch_reply => blk: {
            const id = try getInt(r, u32);
            const status = try getInt(r, u16);
            const failed = try getBool(r);
            const body = try getField(r, BODY_MAX);
            break :blk .{ .fetch_reply = .{
                .id = id,
                .status = status,
                .failed = failed,
                .body = body,
            } };
        },
        .cookie_read => .{ .cookie_read = .{ .id = try getInt(r, u32) } },
        .cookie_write => .{ .cookie_write = .{ .text = try getField(r, COOKIE_MAX) } },
        .tick => .{ .tick = {} },
        .stop => .{ .stop = {} },
        .page => .{ .page = .{ .bytes = try getField(r, MAX_INLINE) } },
        .navigate => .{ .navigate = .{ .address = try getField(r, ADDRESS_MAX) } },
        .fetch_request => blk: {
            const id = try getInt(r, u32);
            const address = try getField(r, ADDRESS_MAX);
            break :blk .{ .fetch_request = .{ .id = id, .address = address } };
        },
        .cookie_value => blk: {
            const id = try getInt(r, u32);
            const line = try getField(r, COOKIE_MAX);
            break :blk .{ .cookie_value = .{ .id = id, .line = line } };
        },
        .script_error => blk: {
            const url = try getField(r, ADDRESS_MAX);
            const text = try getField(r, ERROR_MAX);
            break :blk .{ .script_error = .{ .url = url, .text = text } };
        },
        .missing => .{ .missing = .{ .text = try getField(r, NAME_MAX) } },
        .stopped => .{ .stopped = .{ .reason = try getReason(r) } },
    };
}

/// A length and then that many bytes. The length is checked against `cap`
/// before anything is read for it, which is the whole point of writing it
/// there: a frame saying a field is four gigabytes long is refused, not
/// waited for.
fn getField(r: *std.Io.Reader, cap: usize) DecodeError![]const u8 {
    const len = getLen(r) catch return error.Truncated;
    if (len > cap) return error.TooLarge;
    return r.take(len) catch return error.Truncated;
}

fn getLen(r: *std.Io.Reader) DecodeError!usize {
    return @intCast(r.takeInt(u32, .little) catch return error.Truncated);
}

fn getInt(r: *std.Io.Reader, comptime T: type) DecodeError!T {
    return r.takeInt(T, .little) catch return error.Truncated;
}

fn getBool(r: *std.Io.Reader) DecodeError!bool {
    return switch (r.takeByte() catch return error.Truncated) {
        0 => false,
        1 => true,
        else => error.BadField,
    };
}

fn getReason(r: *std.Io.Reader) DecodeError!StopReason {
    return r.takeEnum(StopReason, .little) catch |err| return switch (err) {
        error.EndOfStream, error.ReadFailed => error.Truncated,
        error.InvalidEnumTag => error.BadField,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Encode into `into`, read it back, and hand over what came out. The
/// message points into `into`, so `into` has to outlive it.
fn roundTrip(message: Message, into: []u8) !Message {
    const frame = try encode(message, into);
    try testing.expectEqual(frame.len, try frameLen(frame));
    return decode(frame);
}

/// A frame built by hand, so the tests can put in one what `encode` would
/// refuse to write: a length that lies, a tag nobody named.
fn frameInto(out: []u8, body: []const u8) []u8 {
    var w: std.Io.Writer = .fixed(out);
    w.writeInt(u32, @intCast(body.len), .little) catch unreachable;
    w.writeAll(body) catch unreachable;
    return w.buffered();
}

test "every message comes back as it went in" {
    var into: [MAX_FRAME]u8 = undefined;

    var sheets: Sheets = .{};
    try sheets.add("p{margin:0}");
    try sheets.add("h1{font-size:2em}");

    const messages = [_]Message{
        .{ .start = .{
            .address = "https://example.be/one",
            .agent = "vibeee/0.1",
            .markup = "<html><body>one</body></html>",
            .charset = "utf-8",
            .sheets = sheets,
        } },
        .{ .script = .{ .source = "document.title = 'one'" } },
        .{ .script = .{ .url = "https://example.be/one.js" } },
        .{ .click = .{ .control = 3, .run = 7 } },
        .{ .typed = .{ .control = 1, .submitted = true, .value = "hello" } },
        .{ .fetch_reply = .{ .id = 9, .status = 404, .body = "not here" } },
        .{ .fetch_reply = .{ .id = 10, .failed = true } },
        .{ .cookie_read = .{ .id = 11 } },
        .{ .cookie_write = .{ .text = "sid=secret; Path=/" } },
        .{ .tick = {} },
        .{ .stop = {} },
        .{ .page = .{ .bytes = "\x01\x02three" } },
        .{ .navigate = .{ .address = "https://example.be/two" } },
        .{ .fetch_request = .{ .id = 12, .address = "https://example.be/api" } },
        .{ .cookie_value = .{ .id = 11, .line = "sid=secret" } },
        .{ .script_error = .{ .url = "https://example.be/one.js", .text = "TypeError" } },
        .{ .missing = .{ .text = "localStorage" } },
        .{ .stopped = .{ .reason = .fault } },
    };

    for (messages) |message| {
        const got = try roundTrip(message, &into);
        try testing.expectEqual(message.tag(), got.tag());
        try testing.expect(eql(message, got));
    }
}

test "two frames in a row come out as two messages" {
    var into: [64]u8 = undefined;
    const first = try encode(.{ .tick = {} }, &into);
    const second = try encode(.{ .stop = {} }, into[first.len..]);

    var at: usize = 0;
    const one = try frameLen(into[at..]);
    try testing.expect((try decode(into[at..][0..one])) == .tick);
    at += one;
    const two = try frameLen(into[at..]);
    try testing.expectEqual(first.len + second.len, at + two);
    try testing.expect((try decode(into[at..][0..two])) == .stop);
}

test "a frame that has not all arrived is refused as cut short" {
    var into: [MAX_FRAME]u8 = undefined;
    const frame = try encode(.{ .stopped = .{ .reason = .asked } }, &into);

    try testing.expectError(error.Truncated, frameLen(frame[0 .. HEADER_LEN - 1]));
    try testing.expectError(error.Truncated, frameLen(frame[0 .. frame.len - 1]));
    try testing.expectError(error.Truncated, decode(frame[0 .. frame.len - 1]));
    try testing.expectError(error.Truncated, decode(&.{ 0, 0 }));
}

test "a frame that claims more than the cap is refused, not waited for" {
    var frame: [HEADER_LEN]u8 = undefined;
    std.mem.writeInt(u32, &frame, MAX_INLINE + 1, .little);
    try testing.expectError(error.TooLarge, frameLen(&frame));
    try testing.expectError(error.TooLarge, decode(&frame));
}

test "a frame with no tag in it is cut short" {
    try testing.expectError(error.Truncated, decode(&.{ 0, 0, 0, 0 }));
}

test "a tag this protocol does not name is refused" {
    var into: [HEADER_LEN + 1]u8 = undefined;
    const frame = frameInto(&into, &.{0xff});
    try testing.expectError(error.BadTag, decode(frame));
}

test "a field longer than its cap is refused by the writer" {
    var address: [ADDRESS_MAX + 1]u8 = undefined;
    @memset(&address, 'a');
    var into: [MAX_FRAME]u8 = undefined;
    try testing.expectError(error.TooLarge, encode(.{ .navigate = .{ .address = &address } }, &into));
}

test "a message longer than the inline cap is refused by the writer" {
    var bytes: [MAX_INLINE]u8 = undefined;
    var into: [MAX_FRAME]u8 = undefined;
    // A page's payload is the whole message, so the most it can carry is
    // the cap less the tag and the length in front of it.
    const most = MAX_INLINE - 1 - HEADER_LEN;
    try testing.expectEqual(MAX_FRAME, (try encode(.{ .page = .{ .bytes = bytes[0..most] } }, &into)).len);
    try testing.expectError(error.TooLarge, encode(.{ .page = .{ .bytes = bytes[0 .. most + 1] } }, &into));
}

test "a field a frame claims is too long is refused rather than read" {
    var into: [HEADER_LEN + 5]u8 = undefined;
    const frame = frameInto(&into, &.{ @intFromEnum(Tag.navigate), 0xff, 0xff, 0xff, 0xff });
    try testing.expectError(error.TooLarge, decode(frame));
}

test "a field that promises more than the frame holds is cut short" {
    var into: [HEADER_LEN + 6]u8 = undefined;
    const frame = frameInto(&into, &.{ @intFromEnum(Tag.navigate), 8, 0, 0, 0, 'h' });
    try testing.expectError(error.Truncated, decode(frame));
}

test "a boolean that is neither is refused" {
    var into: [HEADER_LEN + 10]u8 = undefined;
    const frame = frameInto(&into, &.{ @intFromEnum(Tag.typed), 0, 0, 0, 0, 2, 0, 0, 0, 0 });
    try testing.expectError(error.BadField, decode(frame));
}

test "a stop reason nobody named is refused" {
    var into: [HEADER_LEN + 2]u8 = undefined;
    const frame = frameInto(&into, &.{ @intFromEnum(Tag.stopped), 99 });
    try testing.expectError(error.BadField, decode(frame));
}

test "more stylesheets than fit are refused" {
    var body: [32]u8 = undefined;
    var bw: std.Io.Writer = .fixed(&body);
    bw.writeByte(@intFromEnum(Tag.start)) catch unreachable;
    // Four empty fields, then a count past the cap.
    for (0..4) |_| bw.writeInt(u32, 0, .little) catch unreachable;
    bw.writeInt(u16, MAX_SHEETS + 1, .little) catch unreachable;

    var into: [HEADER_LEN + 32]u8 = undefined;
    try testing.expectError(error.BadField, decode(frameInto(&into, bw.buffered())));
}

test "a start carries every stylesheet it was given, and no more" {
    var sheets: Sheets = .{};
    for (0..MAX_SHEETS) |_| try sheets.add("s{}");
    try testing.expectError(error.Full, sheets.add("one too many"));

    var into: [MAX_FRAME]u8 = undefined;
    const message = Message{ .start = .{ .address = "https://example.be", .sheets = sheets } };
    const got = try roundTrip(message, &into);
    try testing.expectEqual(@as(usize, MAX_SHEETS), got.start.sheets.len);
    try testing.expect(eql(message, got));
}

test "the tags point the way §5's two tables say" {
    for ([_]Message{ .{ .start = .{} }, .{ .stop = {} } }) |message| {
        try testing.expectEqual(Direction.to_worker, message.direction());
    }
    for ([_]Message{ .{ .page = .{} }, .{ .stopped = .{} } }) |message| {
        try testing.expectEqual(Direction.from_worker, message.direction());
    }
}

test "a message that does not fit the buffer it is given is refused" {
    var small: [8]u8 = undefined;
    try testing.expectError(
        error.TooLarge,
        encode(.{ .navigate = .{ .address = "https://example.be" } }, &small),
    );
}

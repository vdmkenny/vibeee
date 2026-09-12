//! HTTP/1.1: a request, and the response to it taken as it arrives.
//!
//! Every request asks for its connection to be kept. A page's stylesheets and
//! its pictures mostly come from its own site one after another, and a sealed
//! connection reached again for each would be a handshake apiece on a
//! processor for which that is most of the work.
//!
//! The response is fed in whatever pieces the socket delivers: the head, the
//! chunk sizes and the body are each found across the edges of reads, which
//! is exactly what the tests below exercise. Pure, and allocation-free but
//! for the body, which goes to a sink the caller bounds.

const std = @import("std");
const builtin = @import("builtin");
const Bounded = @import("lib").bounded.Bounded;
const rgb = @import("lib").rgb;
const url_mod = @import("url");

/// The largest request the reader puts together. Modern consent and sign-in
/// flows legitimately carry several kilobytes of cookies; a one-kilobyte
/// header turns a received session into no session on the very next redirect.
pub const REQUEST_MAX = url_mod.ADDRESS_MAX + 10 * 1024;

const Url = url_mod.Url;
const Writer = std.Io.Writer;

/// What the reader calls itself to a site: the program and its version, the
/// system it runs on, and the kind of machine that is.
pub const USER_AGENT = "vibeee-web/1.0 (vibeee; " ++ @tagName(builtin.cpu.arch) ++ ")";

/// What a request is for, which says what the site is told.
pub const Wanted = enum { page, style, picture };

/// What a request tells the site the reader takes: a page as markup or as
/// words, a stylesheet, and a picture in a format its decoder reads, so that
/// a site able to answer in several answers in one of those.
const accepts = std.EnumArray(Wanted, []const u8).init(.{
    .page = "text/html, text/plain;q=0.8, */*;q=0.1",
    .style = "text/css, */*;q=0.1",
    .picture = "image/png, image/jpeg, image/gif;q=0.8",
});

/// What a request carries to a site, and how: nothing, which is what a GET
/// asks with, or a form's answers as the body of a POST.
pub const Sent = union(enum) {
    nothing,
    /// A form's answers, as `application/x-www-form-urlencoded`, which is how
    /// a form that sends no files sends them.
    form: []const u8,
};

/// What a request asks of a site: what it is for, whether for the version
/// made for small screens and slow connections, how what it sends is drawn,
/// and what it carries.
pub const Asking = struct {
    wanted: Wanted = .page,
    /// Says the screen is small and the connection dear, with the client
    /// hints' mobile hint and `Save-Data`, which is what a site with a
    /// lighter version for either reads.
    mobile: bool = false,
    /// Whether the page is drawn light or dark, which a site with a version
    /// in each reads from the client hint for the colours a person prefers.
    shade: rgb.Shade = .light,
    /// How wide a picture is drawn at most, in the screen's own pixels, where
    /// that is known: what a site with several sizes of one reads to send the
    /// size that is enough.
    width: ?u16 = null,
    /// What it carries: a form's answers, sent as the body of a POST.
    sent: Sent = .nothing,
    /// What the page's scripts have kept for this site, as a `Cookie` line
    /// is written: `name=value` pairs, or nothing where there are none.
    cookies: []const u8 = "",
};

/// The request for `url`, written into `out`.
pub fn request(out: []u8, url: Url, asking: Asking) ?[]const u8 {
    var w: Writer = .fixed(out);
    writeRequest(&w, url, asking) catch return null;
    return w.buffered();
}

fn writeRequest(w: *Writer, url: Url, asking: Asking) Writer.Error!void {
    switch (asking.sent) {
        .nothing => try w.writeAll("GET "),
        .form => try w.writeAll("POST "),
    }
    try url.writeTarget(w);
    try w.writeAll(" HTTP/1.1\r\nHost: ");
    try url.writeHost(w);
    try w.print("\r\nUser-Agent: " ++ USER_AGENT ++ "\r\nAccept: {s}\r\n", .{accepts.get(asking.wanted)});
    // Global Privacy Control, with every request: the person reading does
    // not agree to their visit being sold or shared, which some sites are
    // bound by law to honour.
    try w.writeAll("Sec-GPC: 1\r\n");
    if (asking.mobile) try w.writeAll("Sec-CH-UA-Mobile: ?1\r\nSave-Data: on\r\n");
    // What the page's scripts have kept for this site, which is all this
    // reader knows of cookies: a script writes them, and they are sent back.
    if (asking.cookies.len > 0) try w.print("Cookie: {s}\r\n", .{asking.cookies});
    // The hints a reader sends only on a sealed connection: which shade the
    // page is drawn in, and how wide a picture is drawn.
    if (url.scheme == .https) {
        try w.print("Sec-CH-Prefers-Color-Scheme: \"{t}\"\r\n", .{asking.shade});
        if (asking.wanted == .picture) {
            if (asking.width) |width| try w.print("Sec-CH-Width: {d}\r\n", .{width});
        }
    }
    // Identity, because the one thing a reader must not do with a page is
    // fail to decompress it, and the saving on a small page is not worth a
    // second decoder in the image.
    try w.writeAll("Accept-Encoding: identity\r\nConnection: keep-alive\r\n");
    switch (asking.sent) {
        .nothing => try w.writeAll("\r\n"),
        // The answers go after the head, in the one encoding a form on a page
        // that sends no files is written in. Their length is sent as well,
        // which is how the site knows where they end.
        .form => |answers| {
            try w.writeAll("Content-Type: application/x-www-form-urlencoded\r\n");
            try w.print("Content-Length: {d}\r\n\r\n", .{answers.len});
            try w.writeAll(answers);
        },
    }
}

/// The media type a `Content-Type` value names, without its parameters:
/// `text/html` from `text/html; charset=utf-8`.
pub fn mediaOf(content_type: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, content_type, ';') orelse content_type.len;
    return std.mem.trim(u8, content_type[0..end], &std.ascii.whitespace);
}

/// The most a response's head may come to. Past it the server is saying
/// something other than a page.
pub const HEAD_MAX = 16 * 1024;

/// Where the body goes, and the most of it there may be.
pub const Body = struct {
    bytes: std.ArrayList(u8) = .empty,
    limit: usize,

    pub fn append(self: *Body, gpa: std.mem.Allocator, more: []const u8) Error!void {
        if (self.bytes.items.len + more.len > self.limit) return error.TooLarge;
        self.bytes.appendSlice(gpa, more) catch return error.OutOfMemory;
    }

    pub fn deinit(self: *Body, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
    }
};

pub const Error = error{
    /// The head was longer than any page's is.
    HeadTooLong,
    /// What arrived was not HTTP, or not HTTP this reads.
    Malformed,
    /// The body was larger than the sink takes.
    TooLarge,
    /// The connection ended before the response did.
    Truncated,
    /// The connection ended before any of the response arrived.
    Unanswered,
    OutOfMemory,
};

/// Where a body ends, and how much of it is still owed.
pub const Framing = union(enum) {
    /// At a length, of which this much is still to come.
    length: u64,
    /// At a chunk of size zero.
    chunked: Chunked,
    /// Where the server closes the connection.
    close,
};

/// How far through a chunked body the reading is.
pub const Chunked = struct {
    at: Part = .size,
    /// What is still owed of the chunk being read, or its size as that is
    /// read.
    remaining: u64 = 0,

    const Part = enum {
        /// The hexadecimal size, up to the end of its line.
        size,
        /// Past a `;`: an extension, which says nothing a reader needs.
        extension,
        data,
        /// The line end every chunk's data is followed by.
        data_end,
        /// After the last chunk: header lines, until an empty one.
        trailer_start,
        trailer,
    };
};

/// Where in the head a header's value sits, rather than a slice into it, so
/// a response can be copied without its values pointing at the old copy.
const Span = struct {
    at: u16 = 0,
    len: u16 = 0,

    /// Where `value`, a slice of `head`, is in it.
    fn within(head: []const u8, value: []const u8) Span {
        return .{ .at = @intCast(@intFromPtr(value.ptr) - @intFromPtr(head.ptr)), .len = @intCast(value.len) };
    }

    fn of(self: Span, head: []const u8) ?[]const u8 {
        return if (self.len == 0) null else head[self.at..][0..self.len];
    }
};

/// The headers a reader acts on. Every other one is passed over.
const Header = enum { content_length, transfer_encoding, location, content_type, connection };

const headers = std.StaticStringMapWithEql(Header, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
    .{ "content-length", .content_length },
    .{ "transfer-encoding", .transfer_encoding },
    .{ "location", .location },
    .{ "content-type", .content_type },
    .{ "connection", .connection },
});

pub const Response = struct {
    phase: Phase = .head,
    head: Bounded(u8, HEAD_MAX) = .{},
    status: u16 = 0,
    /// The body's whole length when the head gave one, for saying how far
    /// along a fetch is.
    total: ?u64 = null,
    location_at: Span = .{},
    content_type_at: Span = .{},
    /// Whether the site keeps the connection once the body is done: HTTP/1.1
    /// that does not say it closes, or 1.0 that says it keeps, with a body
    /// that ends at its length rather than where the connection does.
    keeps: bool = false,

    pub const Phase = union(enum) {
        head,
        body: Framing,
        done,
    };

    /// Take what arrived, putting any of the body in it into `body`.
    pub fn feed(self: *Response, gpa: std.mem.Allocator, bytes: []const u8, body: *Body) Error!void {
        var rest = bytes;
        while (rest.len > 0) {
            rest = switch (self.phase) {
                .head => try self.takeHead(rest),
                .body => |*framing| try self.takeBody(gpa, framing, rest, body),
                .done => return,
            };
        }
    }

    /// The connection ended. Only a body framed by its end is finished by
    /// that. One that said how long it was, or is mid-chunk, was cut short,
    /// and so was a head, unless none of it came at all.
    pub fn finish(self: *Response) Error!void {
        switch (self.phase) {
            .done => {},
            .head => return if (self.head.isEmpty()) error.Unanswered else error.Truncated,
            .body => |framing| switch (framing) {
                .close => self.phase = .done,
                .length, .chunked => return error.Truncated,
            },
        }
    }

    pub fn location(self: *const Response) ?[]const u8 {
        return self.location_at.of(self.head.slice());
    }

    pub fn contentType(self: *const Response) ?[]const u8 {
        return self.content_type_at.of(self.head.slice());
    }

    /// Whether the connection can carry another request now.
    pub fn reusable(self: *const Response) bool {
        return self.phase == .done and self.keeps;
    }

    /// Whether the status is a redirect with somewhere to go.
    pub fn redirects(self: *const Response) bool {
        return switch (self.status) {
            301, 302, 303, 307, 308 => self.location() != null,
            else => false,
        };
    }

    fn takeHead(self: *Response, bytes: []const u8) Error![]const u8 {
        const before = self.head.len;
        _ = self.head.extend(bytes);
        const took = self.head.len - before;
        // Where the blank line could start: three bytes back, in case the
        // last read ended partway through it.
        const end = std.mem.indexOfPos(u8, self.head.slice(), before -| 3, "\r\n\r\n") orelse {
            if (self.head.isFull()) return error.HeadTooLong;
            return bytes[took..];
        };
        const head_end = end + 4;
        // What came after the blank line in this read belongs to the body.
        const after = bytes[took - (self.head.len - head_end) ..];
        self.head.truncate(head_end);

        const framing = try self.parseHead();
        // An interim response, the hints a server sends ahead of the real
        // one, is a head with no body and another head behind it.
        if (self.status >= 100 and self.status < 200) {
            self.* = .{};
            return after;
        }
        // A response that cannot have a body has none, whatever it says.
        const empty = self.status == 204 or self.status == 304 or switch (framing) {
            .length => |n| n == 0,
            else => false,
        };
        self.phase = if (empty) .done else .{ .body = framing };
        return after;
    }

    /// Read the status and the headers a reader acts on, and say how the
    /// body is framed.
    fn parseHead(self: *Response) Error!Framing {
        const head = self.head.slice();
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const status_line = lines.next() orelse return error.Malformed;
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.Malformed;
        const code_at = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.Malformed;
        const code = status_line[code_at + 1 ..];
        if (code.len < 3) return error.Malformed;
        self.status = std.fmt.parseInt(u16, code[0..3], 10) catch return error.Malformed;

        var length: ?u64 = null;
        var chunked = false;
        // A 1.1 site keeps a connection unless it says it closes it, and a
        // 1.0 site closes one unless it says it keeps it.
        var stays = std.mem.startsWith(u8, status_line, "HTTP/1.1");
        while (lines.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            switch (headers.get(line[0..colon]) orelse continue) {
                .content_length => length = std.fmt.parseInt(u64, value, 10) catch return error.Malformed,
                .transfer_encoding => chunked = std.ascii.findIgnoreCase(value, "chunked") != null,
                .location => self.location_at = .within(head, value),
                .content_type => self.content_type_at = .within(head, value),
                .connection => {
                    if (std.ascii.findIgnoreCase(value, "keep-alive") != null) stays = true;
                    if (std.ascii.findIgnoreCase(value, "close") != null) stays = false;
                },
            }
        }

        // Chunking outranks a length, as the specification has it: a head
        // carrying both was put together by something that added one.
        const framing: Framing = if (chunked) .{ .chunked = .{} } else if (length) |n| .{ .length = n } else .close;
        if (framing == .length) self.total = length;
        // A body the end of the connection frames leaves no connection to keep.
        self.keeps = stays and framing != .close;
        return framing;
    }

    fn takeBody(self: *Response, gpa: std.mem.Allocator, framing: *Framing, bytes: []const u8, body: *Body) Error![]const u8 {
        switch (framing.*) {
            .close => {
                try body.append(gpa, bytes);
                return bytes[bytes.len..];
            },
            .length => |*remaining| {
                const take: usize = @intCast(@min(remaining.*, bytes.len));
                try body.append(gpa, bytes[0..take]);
                remaining.* -= take;
                if (remaining.* == 0) self.phase = .done;
                return bytes[take..];
            },
            .chunked => |*chunked| return self.takeChunked(gpa, chunked, bytes, body),
        }
    }

    fn takeChunked(self: *Response, gpa: std.mem.Allocator, chunked: *Chunked, bytes: []const u8, body: *Body) Error![]const u8 {
        var i: usize = 0;
        while (i < bytes.len) {
            const c = bytes[i];
            switch (chunked.at) {
                .size => {
                    i += 1;
                    switch (c) {
                        '0'...'9', 'a'...'f', 'A'...'F' => {
                            // A multiple of sixteen that did not overflow
                            // has room for one more digit.
                            const shifted = std.math.mul(u64, chunked.remaining, 16) catch return error.Malformed;
                            chunked.remaining = shifted + (std.fmt.charToDigit(c, 16) catch unreachable);
                        },
                        ';', ' ', '\t' => chunked.at = .extension,
                        '\r' => {},
                        '\n' => chunked.at = if (chunked.remaining == 0) .trailer_start else .data,
                        else => return error.Malformed,
                    }
                },
                .extension => {
                    i += 1;
                    if (c == '\n') chunked.at = if (chunked.remaining == 0) .trailer_start else .data;
                },
                .data => {
                    const take: usize = @intCast(@min(chunked.remaining, bytes.len - i));
                    try body.append(gpa, bytes[i..][0..take]);
                    i += take;
                    chunked.remaining -= take;
                    if (chunked.remaining == 0) chunked.at = .data_end;
                },
                .data_end => {
                    i += 1;
                    if (c == '\n') chunked.at = .size;
                },
                .trailer_start => {
                    i += 1;
                    switch (c) {
                        '\r' => {},
                        '\n' => {
                            self.phase = .done;
                            return bytes[i..];
                        },
                        else => chunked.at = .trailer,
                    }
                },
                .trailer => {
                    i += 1;
                    if (c == '\n') chunked.at = .trailer_start;
                },
            }
        }
        return bytes[i..];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Feed `wire` in pieces of `step`, the way a socket might deliver it.
fn fed(wire: []const u8, step: usize) !struct { response: *Response, body: Body } {
    const response = try testing.allocator.create(Response);
    response.* = .{};
    var body = Body{ .limit = 1 << 20 };
    var at: usize = 0;
    while (at < wire.len) {
        const end = @min(at + step, wire.len);
        try response.feed(testing.allocator, wire[at..end], &body);
        at = end;
    }
    return .{ .response = response, .body = body };
}

test "a request asks for the page and for the connection to be kept" {
    var buf: [512]u8 = undefined;
    const req = request(&buf, url_mod.parse("https://man7.org/linux/read.2.html").?, .{}).?;
    try testing.expect(std.mem.startsWith(u8, req, "GET /linux/read.2.html HTTP/1.1\r\nHost: man7.org\r\n"));
    try testing.expect(std.mem.indexOf(u8, req, "Connection: keep-alive\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, req, "User-Agent: vibeee-web/1.0 (vibeee; ") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\r\nSec-GPC: 1\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));
}

test "a request names a port that is not the scheme's own, and an empty path is the root" {
    var buf: [512]u8 = undefined;
    const req = request(&buf, url_mod.parse("http://10.0.2.2:8099").?, .{}).?;
    try testing.expect(std.mem.startsWith(u8, req, "GET / HTTP/1.1\r\nHost: 10.0.2.2:8099\r\n"));
}

test "a picture is asked for in the formats the decoder reads" {
    var buf: [512]u8 = undefined;
    const req = request(&buf, url_mod.parse("http://a.org/eee.jpg").?, .{ .wanted = .picture }).?;
    try testing.expect(std.mem.indexOf(u8, req, "\r\nAccept: image/png, image/jpeg, image/gif;q=0.8\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, req, "text/html") == null);
    // And on a connection kept for the next one, with the same privacy
    // signal a page's request carries.
    try testing.expect(std.mem.indexOf(u8, req, "\r\nConnection: keep-alive\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, req, "\r\nSec-GPC: 1\r\n") != null);
}

test "a stylesheet is asked for as one" {
    var buf: [512]u8 = undefined;
    const req = request(&buf, url_mod.parse("https://a.org/site.css").?, .{ .wanted = .style }).?;
    try testing.expect(std.mem.indexOf(u8, req, "\r\nAccept: text/css, */*;q=0.1\r\n") != null);
}

test "a request for the version for small screens says so, and any other says nothing" {
    const where = url_mod.parse("https://a.org/").?;
    var small_buf: [512]u8 = undefined;
    const small = request(&small_buf, where, .{ .mobile = true }).?;
    try testing.expect(std.mem.indexOf(u8, small, "\r\nSec-CH-UA-Mobile: ?1\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, small, "\r\nSave-Data: on\r\n") != null);

    var plain_buf: [512]u8 = undefined;
    const plain = request(&plain_buf, where, .{}).?;
    try testing.expect(std.mem.indexOf(u8, plain, "Sec-CH-UA-Mobile") == null);
    try testing.expect(std.mem.indexOf(u8, plain, "Save-Data") == null);
}

test "a sealed request says the shade the page is drawn in, and a picture's how wide it is drawn" {
    var page_buf: [512]u8 = undefined;
    const page = request(&page_buf, url_mod.parse("https://a.org/").?, .{ .shade = .dark, .width = 480 }).?;
    try testing.expect(std.mem.indexOf(u8, page, "\r\nSec-CH-Prefers-Color-Scheme: \"dark\"\r\n") != null);
    // A page is not a picture, whatever width it is given.
    try testing.expect(std.mem.indexOf(u8, page, "Sec-CH-Width") == null);

    var picture_buf: [512]u8 = undefined;
    const picture = request(&picture_buf, url_mod.parse("https://a.org/eee.jpg").?, .{ .wanted = .picture, .width = 480 }).?;
    try testing.expect(std.mem.indexOf(u8, picture, "\r\nSec-CH-Prefers-Color-Scheme: \"light\"\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, picture, "\r\nSec-CH-Width: 480\r\n") != null);
}

test "a form's answers go as the body of a POST, with what they are and how long" {
    var buf: [512]u8 = undefined;
    const sent = request(&buf, url_mod.parse("https://a.org/lite/").?, .{ .sent = .{ .form = "q=eee&lang=en" } }).?;

    try testing.expect(std.mem.startsWith(u8, sent, "POST /lite/ HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, sent, "Content-Type: application/x-www-form-urlencoded\r\n") != null);
    try testing.expect(std.mem.indexOf(u8, sent, "Content-Length: 13\r\n") != null);
    // Behind the head's own empty line, which is where a body goes.
    try testing.expect(std.mem.endsWith(u8, sent, "\r\n\r\nq=eee&lang=en"));
}

test "a request that carries nothing is a GET with no body" {
    var buf: [512]u8 = undefined;
    const sent = request(&buf, url_mod.parse("https://a.org/lite/").?, .{}).?;

    try testing.expect(std.mem.startsWith(u8, sent, "GET /lite/ HTTP/1.1\r\n"));
    try testing.expect(std.mem.indexOf(u8, sent, "Content-Length") == null);
    try testing.expect(std.mem.endsWith(u8, sent, "\r\n\r\n"));
}

test "a request in the clear says neither" {
    var buf: [512]u8 = undefined;
    const req = request(&buf, url_mod.parse("http://a.org/eee.jpg").?, .{ .wanted = .picture, .width = 480, .shade = .dark }).?;
    try testing.expect(std.mem.indexOf(u8, req, "Sec-CH-Prefers-Color-Scheme") == null);
    try testing.expect(std.mem.indexOf(u8, req, "Sec-CH-Width") == null);
}

test "a response says whether its connection carries another request" {
    const cases = [_]struct { wire: []const u8, reusable: bool }{
        .{ .wire = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nhi", .reusable = true },
        .{ .wire = "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nhi", .reusable = false },
        .{ .wire = "HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nhi", .reusable = false },
        .{ .wire = "HTTP/1.0 200 OK\r\nConnection: Keep-Alive\r\nContent-Length: 2\r\n\r\nhi", .reusable = true },
        .{ .wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nhi\r\n0\r\n\r\n", .reusable = true },
        // Framed by the end of the connection, which leaves none to keep.
        .{ .wire = "HTTP/1.1 200 OK\r\n\r\nhi", .reusable = false },
    };
    for (cases) |case| {
        var got = try fed(case.wire, 64);
        defer testing.allocator.destroy(got.response);
        defer got.body.deinit(testing.allocator);
        try testing.expectEqual(case.reusable, got.response.reusable());
    }
}

test "a content type's media type is what comes before its parameters" {
    try testing.expectEqualStrings("text/html", mediaOf(" text/html ; charset=utf-8"));
    try testing.expectEqualStrings("text/plain", mediaOf("text/plain"));
}

test "a body with a length ends at it, in any size of piece" {
    const wire = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nCONTENT-LENGTH: 11\r\n\r\nhello world";
    for ([_]usize{ 1, 2, 3, 7, 64 }) |step| {
        var got = try fed(wire, step);
        defer testing.allocator.destroy(got.response);
        defer got.body.deinit(testing.allocator);
        try testing.expect(got.response.phase == .done);
        try testing.expectEqual(@as(u16, 200), got.response.status);
        try testing.expectEqualStrings("hello world", got.body.bytes.items);
        try testing.expectEqualStrings("text/html", got.response.contentType().?);
        try testing.expectEqual(@as(?u64, 11), got.response.total);
    }
}

test "a chunked body is joined across chunk and read edges" {
    const wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n" ++ "1;ext=1\r\n \r\n" ++ "5\r\nworld\r\n" ++ "0\r\nX-Trailer: y\r\n\r\n";
    for ([_]usize{ 1, 2, 5, 13, 128 }) |step| {
        var got = try fed(wire, step);
        defer testing.allocator.destroy(got.response);
        defer got.body.deinit(testing.allocator);
        try testing.expect(got.response.phase == .done);
        try testing.expectEqualStrings("hello world", got.body.bytes.items);
    }
}

test "a body framed by the connection ends when it does" {
    const wire = "HTTP/1.0 200 OK\r\n\r\nall of it";
    var got = try fed(wire, 4);
    defer testing.allocator.destroy(got.response);
    defer got.body.deinit(testing.allocator);
    try testing.expect(got.response.phase == .body);
    try got.response.finish();
    try testing.expect(got.response.phase == .done);
    try testing.expectEqualStrings("all of it", got.body.bytes.items);
}

test "a body cut short of its length is not finished by the connection ending" {
    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort";
    var got = try fed(wire, 8);
    defer testing.allocator.destroy(got.response);
    defer got.body.deinit(testing.allocator);
    try testing.expectError(error.Truncated, got.response.finish());
}

test "a connection that ends before anything arrives was not answered" {
    const response = try testing.allocator.create(Response);
    defer testing.allocator.destroy(response);
    response.* = .{};
    try testing.expectError(error.Unanswered, response.finish());
}

test "a head cut short is a response cut short" {
    var got = try fed("HTTP/1.1 200 OK\r\nContent-Ty", 4);
    defer testing.allocator.destroy(got.response);
    defer got.body.deinit(testing.allocator);
    try testing.expectError(error.Truncated, got.response.finish());
}

test "a redirect says where to" {
    const wire = "HTTP/1.1 301 Moved\r\nLocation: https://a.org/new\r\nContent-Length: 0\r\n\r\n";
    var got = try fed(wire, 3);
    defer testing.allocator.destroy(got.response);
    defer got.body.deinit(testing.allocator);
    try testing.expect(got.response.redirects());
    try testing.expectEqualStrings("https://a.org/new", got.response.location().?);
    try testing.expect(got.response.phase == .done);
}

test "hints sent ahead of the response are passed over" {
    const wire = "HTTP/1.1 103 Early Hints\r\nLink: </style.css>\r\n\r\n" ++
        "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok";
    var got = try fed(wire, 5);
    defer testing.allocator.destroy(got.response);
    defer got.body.deinit(testing.allocator);
    try testing.expectEqual(@as(u16, 200), got.response.status);
    try testing.expectEqualStrings("ok", got.body.bytes.items);
}

test "a body larger than the sink takes is refused" {
    const wire = "HTTP/1.1 200 OK\r\nContent-Length: 20\r\n\r\n01234567890123456789";
    const response = try testing.allocator.create(Response);
    defer testing.allocator.destroy(response);
    response.* = .{};
    var body = Body{ .limit = 10 };
    defer body.deinit(testing.allocator);
    try testing.expectError(error.TooLarge, response.feed(testing.allocator, wire, &body));
}

test "what is not HTTP is refused" {
    const response = try testing.allocator.create(Response);
    defer testing.allocator.destroy(response);
    response.* = .{};
    var body = Body{ .limit = 10 };
    defer body.deinit(testing.allocator);
    try testing.expectError(error.Malformed, response.feed(testing.allocator, "SSH-2.0-OpenSSH\r\n\r\n", &body));
}

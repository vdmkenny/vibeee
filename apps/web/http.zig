//! HTTP/1.1, one request and one response to a connection.
//!
//! The request asks for the connection to be closed after it. A reader asks
//! for one page at a time, so a connection kept open for a second is state to
//! get wrong for no gain on a machine that reads that slowly.
//!
//! The response is fed in whatever pieces the socket delivers: the head, the
//! chunk sizes and the body are each found across the edges of reads, which
//! is exactly what the tests below exercise. Pure, and allocation-free but
//! for the body, which goes to a sink the caller bounds.

const std = @import("std");

/// The request for `target` on `host`, written into `out`.
pub fn request(out: []u8, host: []const u8, port: u16, default_port: u16, target: []const u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(out);
    const path = if (target.len == 0 or target[0] == '?') "/" else "";
    w.print("GET {s}{s} HTTP/1.1\r\n", .{ path, target }) catch return null;
    if (port == default_port) {
        w.print("Host: {s}\r\n", .{host}) catch return null;
    } else {
        w.print("Host: {s}:{d}\r\n", .{ host, port }) catch return null;
    }
    // Identity, because the one thing a reader must not do with a page is
    // fail to decompress it, and the saving on a small page is not worth a
    // second decoder in the image.
    w.writeAll("User-Agent: web/1 (vibeee)\r\n" ++
        "Accept: text/html, text/plain;q=0.8, */*;q=0.1\r\n" ++
        "Accept-Encoding: identity\r\n" ++
        "Connection: close\r\n" ++
        "\r\n") catch return null;
    return w.buffered();
}

/// Where the body ends: at a length, at a zero-sized chunk, or where the
/// server closes the connection.
pub const Framing = enum { length, chunked, close };

/// The most a response's head may come to. Past it the server is saying
/// something other than a page.
pub const HEAD_MAX = 16 * 1024;

/// Where the body goes, and the most of it there may be.
pub const Body = struct {
    bytes: std.ArrayListUnmanaged(u8) = .empty,
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

/// Where in the head a header's value sits, rather than a slice into it, so
/// a response can be copied without its values pointing at the old copy.
const Span = struct {
    at: u16 = 0,
    len: u16 = 0,

    fn of(self: Span, head: []const u8) ?[]const u8 {
        return if (self.len == 0) null else head[self.at..][0..self.len];
    }
};

pub const Response = struct {
    phase: Phase = .head,

    head: [HEAD_MAX]u8 = undefined,
    head_len: usize = 0,

    status: u16 = 0,
    framing: Framing = .close,
    /// Bytes still owed: of the whole body for `.length`, of the current
    /// chunk for `.chunked`.
    remaining: u64 = 0,
    /// The body's whole length when the head gave one, for saying how far
    /// along a fetch is.
    total: ?u64 = null,
    chunk: Chunk = .size,

    location_at: Span = .{},
    content_type_at: Span = .{},

    pub const Phase = enum { head, body, done };

    const Chunk = enum {
        /// Reading the hexadecimal size, up to the end of its line.
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

    /// Take what arrived, putting any of the body in it into `body`.
    pub fn feed(self: *Response, gpa: std.mem.Allocator, bytes: []const u8, body: *Body) Error!void {
        var rest = bytes;
        while (rest.len > 0 and self.phase != .done) {
            rest = switch (self.phase) {
                .head => try self.takeHead(rest),
                .body => try self.takeBody(gpa, rest, body),
                .done => unreachable,
            };
        }
    }

    /// The connection ended. Only a body framed by its end is finished by
    /// that. One that said how long it was, or is mid-chunk, was cut short,
    /// and so was a head, unless none of it came at all.
    pub fn finish(self: *Response) Error!void {
        switch (self.phase) {
            .done => {},
            .head => return if (self.head_len == 0) error.Unanswered else error.Truncated,
            .body => switch (self.framing) {
                .close => self.phase = .done,
                .length, .chunked => return error.Truncated,
            },
        }
    }

    pub fn location(self: *const Response) ?[]const u8 {
        return self.location_at.of(&self.head);
    }

    pub fn contentType(self: *const Response) ?[]const u8 {
        return self.content_type_at.of(&self.head);
    }

    /// Whether the status is a redirect with somewhere to go.
    pub fn redirects(self: *const Response) bool {
        return switch (self.status) {
            301, 302, 303, 307, 308 => self.location() != null,
            else => false,
        };
    }

    fn takeHead(self: *Response, bytes: []const u8) Error![]const u8 {
        // Where the blank line could start: three bytes back, in case the
        // last read ended partway through it.
        const from = self.head_len -| 3;
        const room = self.head.len - self.head_len;
        const take = @min(room, bytes.len);
        @memcpy(self.head[self.head_len..][0..take], bytes[0..take]);
        self.head_len += take;

        const end = std.mem.indexOfPos(u8, self.head[0..self.head_len], from, "\r\n\r\n") orelse {
            if (self.head_len == self.head.len) return error.HeadTooLong;
            return bytes[take..];
        };
        const head_end = end + 4;
        // What came after the blank line in this read belongs to the body.
        const surplus = self.head_len - head_end;
        const after = bytes[take - surplus ..];

        try self.parseHead(self.head[0..head_end]);

        // An interim response, the hints a server sends ahead of the real
        // one, is a head with no body and another head behind it.
        if (self.status >= 100 and self.status < 200) {
            self.head_len = 0;
            self.status = 0;
            self.location_at = .{};
            self.content_type_at = .{};
            return after;
        }

        self.head_len = head_end;
        self.phase = .body;
        // A response that cannot have a body has none, whatever it says.
        if (self.status == 204 or self.status == 304 or
            (self.framing == .length and self.remaining == 0))
        {
            self.phase = .done;
        }
        return after;
    }

    fn parseHead(self: *Response, head: []const u8) Error!void {
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        const status_line = lines.next() orelse return error.Malformed;
        if (!std.mem.startsWith(u8, status_line, "HTTP/1.")) return error.Malformed;
        const code_at = std.mem.indexOfScalar(u8, status_line, ' ') orelse return error.Malformed;
        const code = status_line[code_at + 1 ..];
        if (code.len < 3) return error.Malformed;
        self.status = std.fmt.parseInt(u16, code[0..3], 10) catch return error.Malformed;

        var length: ?u64 = null;
        var chunked = false;
        while (lines.next()) |line| {
            if (line.len == 0) break;
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const name = line[0..colon];
            const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
            const value_at: u16 = @intCast(@intFromPtr(value.ptr) - @intFromPtr(head.ptr));
            const span = Span{ .at = value_at, .len = @intCast(value.len) };

            if (std.ascii.eqlIgnoreCase(name, "content-length")) {
                length = std.fmt.parseInt(u64, value, 10) catch return error.Malformed;
            } else if (std.ascii.eqlIgnoreCase(name, "transfer-encoding")) {
                chunked = std.ascii.indexOfIgnoreCase(value, "chunked") != null;
            } else if (std.ascii.eqlIgnoreCase(name, "location")) {
                self.location_at = span;
            } else if (std.ascii.eqlIgnoreCase(name, "content-type")) {
                self.content_type_at = span;
            }
        }

        // Chunking outranks a length, as the specification has it: a head
        // carrying both was put together by something that added one.
        if (chunked) {
            self.framing = .chunked;
            self.chunk = .size;
            self.remaining = 0;
        } else if (length) |n| {
            self.framing = .length;
            self.remaining = n;
            self.total = n;
        } else {
            self.framing = .close;
        }
    }

    fn takeBody(self: *Response, gpa: std.mem.Allocator, bytes: []const u8, body: *Body) Error![]const u8 {
        switch (self.framing) {
            .close => {
                try body.append(gpa, bytes);
                return bytes[bytes.len..];
            },
            .length => {
                const take: usize = @intCast(@min(self.remaining, bytes.len));
                try body.append(gpa, bytes[0..take]);
                self.remaining -= take;
                if (self.remaining == 0) self.phase = .done;
                return bytes[take..];
            },
            .chunked => return self.takeChunked(gpa, bytes, body),
        }
    }

    fn takeChunked(self: *Response, gpa: std.mem.Allocator, bytes: []const u8, body: *Body) Error![]const u8 {
        var i: usize = 0;
        while (i < bytes.len and self.phase != .done) {
            const c = bytes[i];
            switch (self.chunk) {
                .size => {
                    i += 1;
                    switch (c) {
                        '0'...'9', 'a'...'f', 'A'...'F' => {
                            const digit = std.fmt.charToDigit(c, 16) catch unreachable;
                            if (self.remaining > std.math.maxInt(u64) / 16) return error.Malformed;
                            self.remaining = self.remaining * 16 + digit;
                        },
                        ';', ' ', '\t' => self.chunk = .extension,
                        '\r' => {},
                        '\n' => self.chunk = if (self.remaining == 0) .trailer_start else .data,
                        else => return error.Malformed,
                    }
                },
                .extension => {
                    i += 1;
                    if (c == '\n') self.chunk = if (self.remaining == 0) .trailer_start else .data;
                },
                .data => {
                    const take: usize = @intCast(@min(self.remaining, bytes.len - i));
                    try body.append(gpa, bytes[i..][0..take]);
                    i += take;
                    self.remaining -= take;
                    if (self.remaining == 0) self.chunk = .data_end;
                },
                .data_end => {
                    i += 1;
                    if (c == '\n') self.chunk = .size;
                },
                .trailer_start => {
                    i += 1;
                    switch (c) {
                        '\r' => {},
                        '\n' => self.phase = .done,
                        else => self.chunk = .trailer,
                    }
                },
                .trailer => {
                    i += 1;
                    if (c == '\n') self.chunk = .trailer_start;
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

test "a request asks for the page and for the connection to close" {
    var buf: [512]u8 = undefined;
    const req = request(&buf, "man7.org", 443, 443, "/linux/read.2.html").?;
    try testing.expect(std.mem.startsWith(u8, req, "GET /linux/read.2.html HTTP/1.1\r\nHost: man7.org\r\n"));
    try testing.expect(std.mem.indexOf(u8, req, "Connection: close\r\n") != null);
    try testing.expect(std.mem.endsWith(u8, req, "\r\n\r\n"));
}

test "a request names a port that is not the scheme's own, and an empty path is the root" {
    var buf: [512]u8 = undefined;
    const req = request(&buf, "10.0.2.2", 8099, 80, "").?;
    try testing.expect(std.mem.startsWith(u8, req, "GET / HTTP/1.1\r\nHost: 10.0.2.2:8099\r\n"));
}

test "a body with a length ends at it, in any size of piece" {
    const wire = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 11\r\n\r\nhello world";
    for ([_]usize{ 1, 2, 3, 7, 64 }) |step| {
        var got = try fed(wire, step);
        defer testing.allocator.destroy(got.response);
        defer got.body.deinit(testing.allocator);
        try testing.expectEqual(Response.Phase.done, got.response.phase);
        try testing.expectEqual(@as(u16, 200), got.response.status);
        try testing.expectEqualStrings("hello world", got.body.bytes.items);
        try testing.expectEqualStrings("text/html", got.response.contentType().?);
    }
}

test "a chunked body is joined across chunk and read edges" {
    const wire = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" ++
        "5\r\nhello\r\n" ++ "1;ext=1\r\n \r\n" ++ "5\r\nworld\r\n" ++ "0\r\nX-Trailer: y\r\n\r\n";
    for ([_]usize{ 1, 2, 5, 13, 128 }) |step| {
        var got = try fed(wire, step);
        defer testing.allocator.destroy(got.response);
        defer got.body.deinit(testing.allocator);
        try testing.expectEqual(Response.Phase.done, got.response.phase);
        try testing.expectEqualStrings("hello world", got.body.bytes.items);
    }
}

test "a body framed by the connection ends when it does" {
    const wire = "HTTP/1.0 200 OK\r\n\r\nall of it";
    var got = try fed(wire, 4);
    defer testing.allocator.destroy(got.response);
    defer got.body.deinit(testing.allocator);
    try testing.expectEqual(Response.Phase.body, got.response.phase);
    try got.response.finish();
    try testing.expectEqual(Response.Phase.done, got.response.phase);
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
    try testing.expectEqual(Response.Phase.done, got.response.phase);
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

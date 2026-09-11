//! Where a page is, and where a link on it points.
//!
//! Pure arithmetic over text, host-tested. A reader that resolved a link one
//! directory out would fetch the wrong page, and the fault would look like a
//! site that had moved rather than like a bug here.
//!
//! IPv4 and names only: the network service speaks nothing else, so an
//! address in brackets is not one this can reach and is refused as one.

const std = @import("std");

/// The longest address this reader keeps. Longer ones exist, almost all of
/// them tracking parameters on a link, and a page reached by one is still
/// reached by what fits here more often than not; past it a link is simply
/// not followed rather than followed somewhere cut short.
pub const ADDRESS_MAX = 2048;

pub const Scheme = enum {
    http,
    https,
    /// A page on this machine, which is what `web page.html` reads.
    file,

    pub fn defaultPort(self: Scheme) u16 {
        return switch (self) {
            .http => 80,
            .https => 443,
            .file => 0,
        };
    }

    /// Whether what goes over the wire is sealed.
    pub fn sealed(self: Scheme) bool {
        return self == .https;
    }

    fn named(text: []const u8) ?Scheme {
        inline for (std.meta.fields(Scheme)) |field| {
            if (std.ascii.eqlIgnoreCase(text, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }
};

/// An absolute address, as slices of the text it was read from.
pub const Url = struct {
    scheme: Scheme,
    /// Empty for a file.
    host: []const u8 = "",
    port: u16 = 0,
    /// The path and the query, which is what a request asks for. Empty, or
    /// beginning with a slash or a question mark; a request puts a slash in
    /// front of the last two. The fragment is not here: it names a place in
    /// the page and never leaves the machine.
    path: []const u8 = "",

    /// The path without its query, for a file on disk and for working out
    /// which directory a relative link starts from.
    pub fn file(self: Url) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.path, '?') orelse self.path.len;
        return self.path[0..end];
    }
};

/// Read an absolute address. Null for anything that is not one this reader
/// can fetch: an unknown scheme, a missing host, a port that is not one.
pub fn parse(text: []const u8) ?Url {
    const marker = std.mem.indexOf(u8, text, "://") orelse return null;
    const scheme = Scheme.named(text[0..marker]) orelse return null;
    const rest = withoutFragment(text[marker + 3 ..]);

    if (scheme == .file) {
        // `file:///home/page.html`: an empty host and then the path. A named
        // host means another machine's file, which is not one this can open.
        const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
        const host = rest[0..slash];
        if (host.len != 0 and !std.ascii.eqlIgnoreCase(host, "localhost")) return null;
        return .{ .scheme = .file, .path = rest[slash..] };
    }

    const authority_end = std.mem.indexOfAny(u8, rest, "/?") orelse rest.len;
    const authority = rest[0..authority_end];
    // A user and a password in the address are how a page is dressed up as
    // another site; nothing here needs them.
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "@[]") != null) return null;

    var host = authority;
    var port = scheme.defaultPort();
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        host = authority[0..colon];
        port = std.fmt.parseInt(u16, authority[colon + 1 ..], 10) catch return null;
        if (port == 0) return null;
    }
    if (host.len == 0) return null;

    return .{ .scheme = scheme, .host = host, .port = port, .path = rest[authority_end..] };
}

/// Write `url` out whole, for the address field and for keeping.
pub fn format(url: Url, out: []u8) ?[]const u8 {
    var w = Writer{ .buf = out };
    w.origin(url);
    w.text(if (url.path.len == 0 or url.path[0] == '?') "/" else "");
    w.text(url.path);
    return w.done();
}

/// Where `reference`, found on the page at `base`, points, written into
/// `out`. Null for a link this reader does not follow: another scheme, a
/// jump within the page, an address too long to hold.
pub fn resolve(base: Url, reference: []const u8, out: []u8) ?[]const u8 {
    const ref = withoutFragment(std.mem.trim(u8, reference, " \t\r\n\x0c"));
    // A link that is only a fragment names a place on this page.
    if (ref.len == 0) return null;

    if (schemeOf(ref)) |named| {
        // A scheme this reader knows is an address in its own right; any
        // other, `mailto:` or `javascript:`, is not a page to go to.
        _ = Scheme.named(named) orelse return null;
        const url = parse(ref) orelse return null;
        return format(url, out);
    }

    var w = Writer{ .buf = out };

    if (std.mem.startsWith(u8, ref, "//")) {
        // The same scheme, a new host.
        w.text(@tagName(base.scheme));
        w.text(":");
        w.text(ref);
        const joined = w.done() orelse return null;
        // Parsed again, so a host with a port in it is checked like any
        // other, and written back out so the path is normalised.
        var scratch: [4096]u8 = undefined;
        if (joined.len > scratch.len) return null;
        @memcpy(scratch[0..joined.len], joined);
        const url = parse(scratch[0..joined.len]) orelse return null;
        return format(url, out);
    }

    w.origin(base);

    if (ref[0] == '?') {
        w.text(base.file());
        if (base.file().len == 0) w.text("/");
        w.text(ref);
        return w.done();
    }

    // An absolute path stands alone; a relative one starts in the directory
    // the base page is in, which is its path up to and including the last
    // slash.
    var joined: [4096]u8 = undefined;
    var j = Writer{ .buf = &joined };
    if (ref[0] != '/') {
        const dir = base.file();
        const cut = if (std.mem.lastIndexOfScalar(u8, dir, '/')) |slash| slash + 1 else 0;
        j.text(if (cut == 0) "/" else dir[0..cut]);
    }
    j.text(ref);
    const path = j.done() orelse return null;

    const query_at = std.mem.indexOfScalar(u8, path, '?') orelse path.len;
    var normal: [4096]u8 = undefined;
    const clean = normalise(path[0..query_at], &normal) orelse return null;
    w.text(clean);
    w.text(path[query_at..]);
    return w.done();
}

/// The scheme a reference begins with, if it begins with one: letters,
/// digits, plus, minus and dot up to a colon, before any slash, question
/// mark or fragment. `a:b` is a scheme; `a/b:c` is a relative path.
fn schemeOf(ref: []const u8) ?[]const u8 {
    for (ref, 0..) |c, i| {
        switch (c) {
            ':' => return if (i == 0) null else ref[0..i],
            'a'...'z', 'A'...'Z' => {},
            '0'...'9', '+', '-', '.' => if (i == 0) return null,
            else => return null,
        }
    }
    return null;
}

fn withoutFragment(text: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, text, '#') orelse text.len;
    return text[0..end];
}

/// Take the `.` and `..` segments out of an absolute path. A path climbing
/// above the root stays at the root, which is what every browser does and
/// what a link written for a site at the top of its host expects.
fn normalise(path: []const u8, out: []u8) ?[]const u8 {
    std.debug.assert(path.len > 0 and path[0] == '/');
    var len: usize = 0;
    // Whether the path ends on a directory, which keeps its trailing slash.
    var ends_dir = false;

    var segments = std.mem.splitScalar(u8, path[1..], '/');
    while (segments.next()) |segment| {
        ends_dir = false;
        if (segment.len == 0 or std.mem.eql(u8, segment, ".")) {
            ends_dir = true;
            continue;
        }
        if (std.mem.eql(u8, segment, "..")) {
            len = std.mem.lastIndexOfScalar(u8, out[0..len], '/') orelse 0;
            ends_dir = true;
            continue;
        }
        if (len + 1 + segment.len > out.len) return null;
        out[len] = '/';
        @memcpy(out[len + 1 ..][0..segment.len], segment);
        len += 1 + segment.len;
    }

    if (len == 0 or ends_dir) {
        if (len + 1 > out.len) return null;
        out[len] = '/';
        len += 1;
    }
    return out[0..len];
}

/// Text into a fixed buffer, remembering whether it ever ran out rather than
/// failing at every step.
const Writer = struct {
    buf: []u8,
    len: usize = 0,
    over: bool = false,

    fn text(self: *Writer, bytes: []const u8) void {
        if (self.over) return;
        if (self.len + bytes.len > self.buf.len) {
            self.over = true;
            return;
        }
        @memcpy(self.buf[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }

    fn origin(self: *Writer, url: Url) void {
        self.text(@tagName(url.scheme));
        self.text("://");
        self.text(url.host);
        if (url.scheme != .file and url.port != url.scheme.defaultPort()) {
            var digits: [5]u8 = undefined;
            const port = std.fmt.bufPrint(&digits, "{d}", .{url.port}) catch unreachable;
            self.text(":");
            self.text(port);
        }
    }

    fn done(self: *const Writer) ?[]const u8 {
        return if (self.over) null else self.buf[0..self.len];
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectResolved(base: []const u8, ref: []const u8, want: ?[]const u8) !void {
    const url = parse(base) orelse return error.BaseDidNotParse;
    var out: [512]u8 = undefined;
    const got = resolve(url, ref, &out);
    if (want) |w| {
        try testing.expectEqualStrings(w, got orelse return error.DidNotResolve);
    } else {
        try testing.expect(got == null);
    }
}

test "an address says its scheme, host, port and path" {
    const url = parse("https://man7.org:8443/linux/man2/read.2.html?x=1#top").?;
    try testing.expectEqual(Scheme.https, url.scheme);
    try testing.expectEqualStrings("man7.org", url.host);
    try testing.expectEqual(@as(u16, 8443), url.port);
    try testing.expectEqualStrings("/linux/man2/read.2.html?x=1", url.path);
    try testing.expectEqualStrings("/linux/man2/read.2.html", url.file());
}

test "a missing port is the scheme's own" {
    try testing.expectEqual(@as(u16, 80), parse("http://example.org").?.port);
    try testing.expectEqual(@as(u16, 443), parse("https://example.org/").?.port);
}

test "what is not a fetchable address does not parse" {
    try testing.expect(parse("ftp://example.org/") == null);
    try testing.expect(parse("https:///nohost") == null);
    try testing.expect(parse("https://user:pw@example.org/") == null);
    try testing.expect(parse("https://[::1]/") == null);
    try testing.expect(parse("https://example.org:0/") == null);
    try testing.expect(parse("https://example.org:99999/") == null);
    try testing.expect(parse("example.org") == null);
}

test "a file address is a path on this machine" {
    const url = parse("file:///home/page.html").?;
    try testing.expectEqual(Scheme.file, url.scheme);
    try testing.expectEqualStrings("/home/page.html", url.path);
    try testing.expect(parse("file://elsewhere/home/page.html") == null);
}

test "a relative link starts in the base page's directory" {
    try expectResolved("https://a.org/docs/guide/intro.html", "setup.html", "https://a.org/docs/guide/setup.html");
    try expectResolved("https://a.org/docs/guide/", "setup.html", "https://a.org/docs/guide/setup.html");
    try expectResolved("https://a.org", "setup.html", "https://a.org/setup.html");
}

test "dot segments climb, and stop at the root" {
    try expectResolved("https://a.org/docs/guide/intro.html", "../api/", "https://a.org/docs/api/");
    try expectResolved("https://a.org/docs/guide/intro.html", "./x.html", "https://a.org/docs/guide/x.html");
    try expectResolved("https://a.org/a/b", "../../../x", "https://a.org/x");
    try expectResolved("https://a.org/a/b/c", "..", "https://a.org/a/");
}

test "an absolute path, a new host, and a query each start where they say" {
    try expectResolved("https://a.org/docs/x.html", "/about", "https://a.org/about");
    try expectResolved("https://a.org/docs/x.html", "//b.org/y", "https://b.org/y");
    try expectResolved("http://a.org:8080/docs/x.html", "?page=2", "http://a.org:8080/docs/x.html?page=2");
    try expectResolved("http://a.org:8080/docs/x.html", "/y", "http://a.org:8080/y");
}

test "an absolute link stands alone, and other schemes are not followed" {
    try expectResolved("https://a.org/", "http://b.org/page", "http://b.org/page");
    try expectResolved("https://a.org/", "mailto:someone@a.org", null);
    try expectResolved("https://a.org/", "javascript:void(0)", null);
}

test "a fragment names a place on the page, and whitespace around a link is not part of it" {
    try expectResolved("https://a.org/x", "#top", null);
    try expectResolved("https://a.org/x", "  page.html#part \n", "https://a.org/page.html");
}

test "a colon in the first segment makes a scheme, and a leading dot makes a path" {
    // `Talk:Main` is an address in a scheme called `talk`, which is why a site
    // writes such a page as `./Talk:Main`, or from its root.
    try expectResolved("https://a.org/wiki/", "Talk:Main", null);
    try expectResolved("https://a.org/wiki/", "./Talk:Main", "https://a.org/wiki/Talk:Main");
    try expectResolved("https://a.org/wiki/", "/wiki/Talk:Main", "https://a.org/wiki/Talk:Main");
}

test "an address too long for the buffer is refused rather than cut" {
    const url = parse("https://a.org/").?;
    var small: [16]u8 = undefined;
    try testing.expect(resolve(url, "/a/very/long/path/indeed", &small) == null);
}

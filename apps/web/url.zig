//! Where a page is, and where a link on it points.
//!
//! Pure arithmetic over text, host-tested. A reader that resolved a link one
//! directory out would fetch the wrong page, and the fault would look like a
//! site that had moved rather than like a bug here.
//!
//! IPv4 and names only: the network service speaks nothing else, so an
//! address in brackets is not one this can reach and is refused as one.

const std = @import("std");
const Bounded = @import("lib").bounded.Bounded;

const Writer = std.Io.Writer;

/// The longest address this reader keeps. Longer ones exist, almost all of
/// them tracking parameters on a link, and a page reached by one is still
/// reached by what fits here more often than not; past it a link is simply
/// not followed rather than followed somewhere cut short.
pub const ADDRESS_MAX = 2048;

/// An address kept rather than borrowed: where a fetch is aimed, and each
/// place the history remembers.
pub const Address = Bounded(u8, ADDRESS_MAX);

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
    /// beginning with a slash or a question mark. The fragment is not here:
    /// it names a place in the page and never leaves the machine.
    path: []const u8 = "",

    /// The path without its query, for a file on disk and for working out
    /// which directory a relative link starts from.
    pub fn file(self: Url) []const u8 {
        const end = std.mem.indexOfScalar(u8, self.path, '?') orelse self.path.len;
        return self.path[0..end];
    }

    /// The whole address, which is what `{f}` prints: for the address field
    /// and for keeping.
    pub fn format(self: Url, w: *Writer) Writer.Error!void {
        try self.writeOrigin(w);
        try self.writeTarget(w);
    }

    /// The host, and the port where it is not the scheme's own: what a
    /// request's `Host` line says.
    pub fn writeHost(self: Url, w: *Writer) Writer.Error!void {
        try w.writeAll(self.host);
        if (self.scheme != .file and self.port != self.scheme.defaultPort()) try w.print(":{d}", .{self.port});
    }

    /// What a request asks for: the path and the query, with a slash in
    /// front of an empty path or a bare query.
    pub fn writeTarget(self: Url, w: *Writer) Writer.Error!void {
        if (self.path.len == 0 or self.path[0] == '?') try w.writeByte('/');
        try w.writeAll(self.path);
    }

    /// Where every address on the site starts: the scheme and the host.
    fn writeOrigin(self: Url, w: *Writer) Writer.Error!void {
        try w.print("{s}://", .{@tagName(self.scheme)});
        try self.writeHost(w);
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

/// Where `reference`, found on the page at `base`, points, written into
/// `out`. Null for a link this reader does not follow: another scheme, a
/// jump within the page, an address too long to hold.
pub fn resolve(base: Url, reference: []const u8, out: []u8) ?[]const u8 {
    const ref = withoutFragment(std.mem.trim(u8, reference, &c0_or_space));
    // A link that is only a fragment names a place on this page.
    if (ref.len == 0) return null;

    if (schemeOf(ref)) |named| {
        // A scheme this reader knows is an address in its own right; any
        // other, `mailto:` or `javascript:`, is not a page to go to.
        _ = Scheme.named(named) orelse return null;
        return std.fmt.bufPrint(out, "{f}", .{parse(ref) orelse return null}) catch null;
    }

    if (std.mem.startsWith(u8, ref, "//")) {
        // The same scheme and another host, read whole so that a host with
        // a port in it is checked like any other.
        var whole: [ADDRESS_MAX]u8 = undefined;
        const joined = std.fmt.bufPrint(&whole, "{s}:{s}", .{ @tagName(base.scheme), ref }) catch return null;
        return std.fmt.bufPrint(out, "{f}", .{parse(joined) orelse return null}) catch null;
    }

    var w: Writer = .fixed(out);
    writeRelative(&w, base, ref) catch return null;
    return w.buffered();
}

/// A reference with neither a scheme nor a host, written out against `base`.
fn writeRelative(w: *Writer, base: Url, ref: []const u8) Writer.Error!void {
    try base.writeOrigin(w);
    if (ref[0] == '?') {
        // A new query on the same path.
        const path = base.file();
        try w.writeAll(if (path.len == 0) "/" else path);
        return w.writeAll(ref);
    }
    const query_at = std.mem.indexOfScalar(u8, ref, '?') orelse ref.len;
    const path = ref[0..query_at];
    // An absolute path stands alone; a relative one starts in the directory
    // the base page is in.
    try writeNormalised(w, if (path[0] == '/') "" else directoryOf(base.file()), path);
    try w.writeAll(ref[query_at..]);
}

/// `dir` followed by `path`, as one absolute path with its `.` and `..`
/// segments taken out. A path climbing above the root stays at the root,
/// which is what every browser does and what a link written for a site at
/// the top of its host expects.
fn writeNormalised(w: *Writer, dir: []const u8, path: []const u8) Writer.Error!void {
    const root = w.end;
    // Whether the path ends on a directory, which keeps its trailing slash.
    var ends_dir = false;
    for ([_][]const u8{ dir, path }) |part| {
        var segments = std.mem.splitScalar(u8, part, '/');
        while (segments.next()) |segment| {
            if (std.mem.eql(u8, segment, "..")) {
                const written = w.buffered()[root..];
                w.undo(written.len - (std.mem.lastIndexOfScalar(u8, written, '/') orelse 0));
                ends_dir = true;
            } else if (segment.len == 0 or std.mem.eql(u8, segment, ".")) {
                ends_dir = true;
            } else {
                try w.print("/{s}", .{segment});
                ends_dir = false;
            }
        }
    }
    if (ends_dir or w.end == root) try w.writeByte('/');
}

/// The directory a path is in: up to and including its last slash, or the
/// root where it has none.
fn directoryOf(path: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    return path[0 .. slash + 1];
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

/// What the URL standard strips from both ends of an address: the C0
/// controls and the space.
const c0_or_space: [0x21]u8 = table: {
    var bytes: [0x21]u8 = undefined;
    for (&bytes, 0..) |*byte, value| byte.* = @intCast(value);
    break :table bytes;
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

test "an address writes itself out whole, with the slash a request needs" {
    try testing.expectFmt("https://a.org/", "{f}", .{parse("https://a.org").?});
    try testing.expectFmt("http://a.org:8080/x?q=1", "{f}", .{parse("http://a.org:8080/x?q=1#top").?});
    try testing.expectFmt("https://a.org/?q=1", "{f}", .{parse("https://a.org?q=1").?});
    try testing.expectFmt("file:///home/page.html", "{f}", .{parse("file:///home/page.html").?});
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

test "a fragment names a place on the page, and what is around a link is not part of it" {
    try expectResolved("https://a.org/x", "#top", null);
    try expectResolved("https://a.org/x", "  page.html#part \n", "https://a.org/page.html");
    try expectResolved("https://a.org/x", "\x00\tpage.html\x1f", "https://a.org/page.html");
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

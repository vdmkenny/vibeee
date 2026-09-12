//! The cookies a reader keeps while it is open.
//!
//! A cookie belongs to a site, not the document that happened to write it.
//! A document goes when the reader follows a link or a redirect; the cookie
//! must still go with the request for the page on the other side. The jar is
//! deliberately a session jar: there is no disk persistence yet, but a page
//! can set a cookie, redirect, fetch again, and receive the one it set.

const std = @import("std");
const url = @import("url");

pub const Jar = struct {
    const Cookie = struct {
        name: []const u8,
        value: []const u8,
        domain: []const u8,
        path: []const u8,
        host_only: bool,
        secure: bool,
        http_only: bool,
    };

    cookies: std.ArrayList(Cookie) = .empty,

    pub fn count(self: *const Jar) usize {
        return self.cookies.items.len;
    }

    pub fn deinit(self: *Jar, gpa: std.mem.Allocator) void {
        for (self.cookies.items) |cookie| free(gpa, cookie);
        self.cookies.deinit(gpa);
    }

    /// Take one `Set-Cookie` field or `document.cookie` assignment. A script
    /// cannot make an HttpOnly cookie; a response can. Max-Age zero removes
    /// one, which is the expiry form sites use most often.
    pub fn take(self: *Jar, gpa: std.mem.Allocator, from: url.Url, field: []const u8, from_http: bool) void {
        var parts = std.mem.splitScalar(u8, field, ';');
        const first = trim(parts.next() orelse return);
        const equal = std.mem.indexOfScalar(u8, first, '=') orelse return;
        const name = trim(first[0..equal]);
        const value = trim(first[equal + 1 ..]);
        if (name.len == 0) return;

        var domain = from.host;
        var path = defaultPath(from.file());
        var host_only = true;
        var secure = false;
        var http_only = false;
        var remove = false;

        while (parts.next()) |part| {
            const attribute = trim(part);
            const at = std.mem.indexOfScalar(u8, attribute, '=');
            const key = trim(attribute[0 .. at orelse attribute.len]);
            const setting = if (at) |equal_at| trim(attribute[equal_at + 1 ..]) else "";
            if (std.ascii.eqlIgnoreCase(key, "domain")) {
                const named = std.mem.trimStart(u8, setting, ".");
                if (named.len == 0 or !domainContains(from.host, named)) return;
                domain = named;
                host_only = false;
            } else if (std.ascii.eqlIgnoreCase(key, "path")) {
                if (setting.len > 0 and setting[0] == '/') path = setting;
            } else if (std.ascii.eqlIgnoreCase(key, "secure")) {
                secure = true;
            } else if (std.ascii.eqlIgnoreCase(key, "httponly")) {
                http_only = from_http;
            } else if (std.ascii.eqlIgnoreCase(key, "max-age")) {
                const seconds = std.fmt.parseInt(i64, setting, 10) catch continue;
                remove = seconds <= 0;
            }
        }

        for (self.cookies.items, 0..) |*cookie, at| {
            if (!std.mem.eql(u8, cookie.name, name) or !std.ascii.eqlIgnoreCase(cookie.domain, domain) or !std.mem.eql(u8, cookie.path, path)) continue;
            if (remove) {
                free(gpa, cookie.*);
                _ = self.cookies.orderedRemove(at);
                return;
            }
            gpa.free(cookie.value);
            cookie.value = dupe(gpa, value) orelse return;
            cookie.secure = secure;
            if (from_http) cookie.http_only = http_only;
            return;
        }
        if (remove) return;
        self.cookies.append(gpa, .{
            .name = dupe(gpa, name) orelse return,
            .value = dupe(gpa, value) orelse return,
            .domain = dupe(gpa, domain) orelse return,
            .path = dupe(gpa, path) orelse return,
            .host_only = host_only,
            .secure = secure,
            .http_only = http_only,
        }) catch {};
    }

    /// The request's `Cookie` value, or the text `document.cookie` exposes.
    /// HttpOnly cookies go to a site but never to its script.
    pub fn write(self: *const Jar, from: url.Url, include_http_only: bool, into: []u8) []const u8 {
        var out: std.Io.Writer = .fixed(into);
        var written: usize = 0;
        for (self.cookies.items) |cookie| {
            if (!matches(cookie, from, include_http_only)) continue;
            if (written > 0) out.writeAll("; ") catch return "";
            out.writeAll(cookie.name) catch return "";
            out.writeByte('=') catch return "";
            out.writeAll(cookie.value) catch return "";
            written += 1;
        }
        return out.buffered();
    }

    /// Every Set-Cookie field in one response head. Redirect responses pass
    /// through this too, before the fetch turns to their Location.
    pub fn takeHead(self: *Jar, gpa: std.mem.Allocator, from: url.Url, head: []const u8) void {
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        _ = lines.next();
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(trim(line[0..colon]), "set-cookie")) continue;
            self.take(gpa, from, trim(line[colon + 1 ..]), true);
        }
    }
};

fn trim(text: []const u8) []const u8 {
    return std.mem.trim(u8, text, &std.ascii.whitespace);
}

fn dupe(gpa: std.mem.Allocator, text: []const u8) ?[]const u8 {
    return gpa.dupe(u8, text) catch null;
}

fn free(gpa: std.mem.Allocator, cookie: Jar.Cookie) void {
    gpa.free(cookie.name);
    gpa.free(cookie.value);
    gpa.free(cookie.domain);
    gpa.free(cookie.path);
}

fn domainContains(host: []const u8, domain: []const u8) bool {
    return std.ascii.eqlIgnoreCase(host, domain) or (host.len > domain.len and host[host.len - domain.len - 1] == '.' and std.ascii.eqlIgnoreCase(host[host.len - domain.len ..], domain));
}

fn defaultPath(path: []const u8) []const u8 {
    if (path.len == 0 or path[0] != '/') return "/";
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return "/";
    return if (slash == 0) "/" else path[0..slash];
}

fn matches(cookie: Jar.Cookie, from: url.Url, include_http_only: bool) bool {
    if (cookie.secure and from.scheme != .https) return false;
    if (cookie.http_only and !include_http_only) return false;
    if (cookie.host_only) {
        if (!std.ascii.eqlIgnoreCase(from.host, cookie.domain)) return false;
    } else if (!domainContains(from.host, cookie.domain)) return false;
    const path = from.file();
    if (!std.mem.startsWith(u8, path, cookie.path)) return false;
    return cookie.path.len == 1 or path.len == cookie.path.len or path[cookie.path.len] == '/';
}

test "a session cookie survives another document" {
    const testing = std.testing;
    var jar: Jar = .{};
    defer jar.deinit(testing.allocator);
    const one = url.parse("https://example.test/one/two").?;
    const two = url.parse("https://example.test/one/three").?;
    jar.take(testing.allocator, one, "a=b; Path=/one", false);
    var line: [64]u8 = undefined;
    try testing.expectEqualStrings("a=b", jar.write(two, true, &line));
}

test "a response cookie is hidden from its script" {
    const testing = std.testing;
    var jar: Jar = .{};
    defer jar.deinit(testing.allocator);
    const where = url.parse("https://example.test/").?;
    jar.take(testing.allocator, where, "sid=secret; HttpOnly", true);
    var line: [64]u8 = undefined;
    try testing.expectEqualStrings("sid=secret", jar.write(where, true, &line));
    try testing.expectEqualStrings("", jar.write(where, false, &line));
}

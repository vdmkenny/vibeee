//! Turning a typed command word into a path to run.
//!
//! The rule is the one every shell has: a word with a slash in it is already
//! a path and is used as typed, and a word without one names a program on
//! the search path. The working directory is deliberately not searched for
//! bare names, so what runs depends on what was typed rather than on where
//! you happen to be standing.
//!
//! Whether a candidate is there is asked of the caller, since that is the
//! filesystem's business and the rule above is checked without one.

const std = @import("std");

/// What separates one directory from the next on a search path.
pub const SEPARATOR = ':';

/// Where a bare name is looked for when nothing says otherwise.
///
/// Programs installed under home come first, so a machine's own copy of
/// something wins over the one it shipped with, and an extra application
/// is run by typing its name like any other.
pub const DEFAULT_PATH = "/home/bin:/bin";

/// Whether a program is at a path. Supplied by the caller.
pub const Have = *const fn (path: []const u8) bool;

/// The directories a search path names, in the order they are searched.
pub const Directories = struct {
    rest: []const u8,

    pub fn next(self: *Directories) ?[]const u8 {
        while (self.rest.len != 0) {
            const end = std.mem.indexOfScalar(u8, self.rest, SEPARATOR) orelse self.rest.len;
            const one = self.rest[0..end];
            self.rest = if (end == self.rest.len) "" else self.rest[end + 1 ..];
            // An empty entry is not the working directory, as it is in some
            // shells: nothing here searches where you are standing.
            if (one.len != 0) return one;
        }
        return null;
    }
};

pub fn directories(path: []const u8) Directories {
    return .{ .rest = path };
}

/// `dir` and `name` with exactly one separator between them, however many
/// the directory ended with.
pub fn joined(dir: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    const trimmed = if (dir.len != 0 and dir[dir.len - 1] == '/') dir[0 .. dir.len - 1] else dir;
    if (trimmed.len + 1 + name.len > buf.len) return null;

    @memcpy(buf[0..trimmed.len], trimmed);
    buf[trimmed.len] = '/';
    @memcpy(buf[trimmed.len + 1 ..][0..name.len], name);
    return buf[0 .. trimmed.len + 1 + name.len];
}

/// Whether `name` says where a program is rather than just naming one.
///
/// The same question decides what a word runs and what a half-typed word
/// completes against, so both ask it here.
pub fn isPath(name: []const u8) bool {
    return std.mem.indexOfScalar(u8, name, '/') != null;
}

/// The path `name` should be run from, or null when nothing on `path` has
/// it and the caller should say so under the name that was typed.
///
/// A word that says where a program is comes back as typed, whether
/// absolute or relative: the kernel resolves it against the working
/// directory and collapses "." and ".." there, in the one place every
/// syscall agrees on.
pub fn pathFor(name: []const u8, path: []const u8, buf: []u8, have: Have) ?[]const u8 {
    if (name.len == 0) return null;
    if (isPath(name)) return name;

    var walk = directories(path);
    while (walk.next()) |dir| {
        const candidate = joined(dir, name, buf) orelse continue;
        if (have(candidate)) return candidate;
    }
    return null;
}

const testing = std.testing;

/// A machine carrying `ls` in both places and `doom` only under home.
fn present(path: []const u8) bool {
    const there = [_][]const u8{ "/bin/ls", "/home/bin/ls", "/home/bin/doom" };
    for (there) |one| {
        if (std.mem.eql(u8, one, path)) return true;
    }
    return false;
}

test "a word says where a program is only if it has a separator" {
    try testing.expect(!isPath("doom"));
    try testing.expect(!isPath(""));
    try testing.expect(isPath("./doom"));
    try testing.expect(isPath("/home/doom"));
    try testing.expect(isPath("sub/prog"));
}

test "a search path is its directories in order, and empty entries are not one" {
    var walk = directories("/home/bin:/bin");
    try testing.expectEqualStrings("/home/bin", walk.next().?);
    try testing.expectEqualStrings("/bin", walk.next().?);
    try testing.expectEqual(@as(?[]const u8, null), walk.next());

    // Nothing stands for the working directory, however the path is written.
    var odd = directories(":/bin::/home/bin:");
    try testing.expectEqualStrings("/bin", odd.next().?);
    try testing.expectEqualStrings("/home/bin", odd.next().?);
    try testing.expectEqual(@as(?[]const u8, null), odd.next());

    var none = directories("");
    try testing.expectEqual(@as(?[]const u8, null), none.next());
}

test "a directory and a name are joined with one separator" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("/bin/ls", joined("/bin", "ls", &buf).?);
    try testing.expectEqualStrings("/bin/ls", joined("/bin/", "ls", &buf).?);
    // And refused rather than cut short when it will not fit.
    var small: [4]u8 = undefined;
    try testing.expectEqual(@as(?[]const u8, null), joined("/bin", "ls", &small));
}

test "a bare name comes from the first place on the path that has it" {
    var buf: [64]u8 = undefined;
    // Home comes first, so its copy wins over the one that shipped.
    try testing.expectEqualStrings("/home/bin/ls", pathFor("ls", DEFAULT_PATH, &buf, present).?);
    // And a name only the system has is found further along.
    try testing.expectEqualStrings("/bin/ls", pathFor("ls", "/bin", &buf, present).?);
    // One only home has is found nowhere else.
    try testing.expectEqualStrings("/home/bin/doom", pathFor("doom", DEFAULT_PATH, &buf, present).?);
}

test "a name nothing on the path has is not a path" {
    var buf: [64]u8 = undefined;
    // The caller says so under the name that was typed rather than under a
    // guess at where it should have been.
    try testing.expectEqual(@as(?[]const u8, null), pathFor("nowhere", DEFAULT_PATH, &buf, present));
    try testing.expectEqual(@as(?[]const u8, null), pathFor("ls", "", &buf, present));
    try testing.expectEqual(@as(?[]const u8, null), pathFor("", DEFAULT_PATH, &buf, present));
}

test "a path is used as typed and is never looked for" {
    var buf: [64]u8 = undefined;
    // The case that matters: a program in the working directory is reached
    // by saying so, not by having a directory pasted in front.
    try testing.expectEqualStrings("./doom", pathFor("./doom", DEFAULT_PATH, &buf, present).?);
    try testing.expectEqualStrings("../bin/doom", pathFor("../bin/doom", DEFAULT_PATH, &buf, present).?);
    try testing.expectEqualStrings("sub/prog", pathFor("sub/prog", DEFAULT_PATH, &buf, present).?);
    try testing.expectEqualStrings("/home/doom", pathFor("/home/doom", DEFAULT_PATH, &buf, present).?);
}

test "a candidate that does not fit is passed over rather than truncated" {
    var buf: [10]u8 = undefined;
    // "/home/bin/ls" does not fit; "/bin/ls" does.
    try testing.expectEqualStrings("/bin/ls", pathFor("ls", DEFAULT_PATH, &buf, present).?);
}

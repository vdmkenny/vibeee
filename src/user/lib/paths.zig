//! Paths, as text.
//!
//! Joining and taking apart, which every tool that walks a tree or moves a
//! file needs and each was writing again slightly differently. Nothing here
//! touches the filesystem: whether a path names anything is a question for
//! whoever opens it.

const std = @import("std");
const str = @import("lib").str;

pub const SEPARATOR = '/';

/// Where something is: the path without its last component, and the root
/// for what is directly under it. A trailing slash is ignored, as `base`
/// ignores it, so `parent("/home/pictures/")` is `/home`.
pub fn parent(path: []const u8) []const u8 {
    return std.fs.path.dirnamePosix(path) orelse "/";
}

/// The last component: what something is called, without where it is.
///
/// A trailing slash is ignored, so `base("/etc/")` is `etc` rather than
/// nothing, which is what somebody writing `mv x /etc/` means by it.
pub fn base(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and path[end - 1] == SEPARATOR) end -= 1;

    var start = end;
    while (start > 0 and path[start - 1] != SEPARATOR) start -= 1;
    return path[start..end];
}

/// `dir` and `name` with exactly one separator between them, however many
/// either of them arrived with.
/// The two, joined into `buf`, or null when they do not fit.
///
/// A path cut short names something else, and a caller acting on one moves
/// or removes whatever that turns out to be. Refused rather than
/// truncated; a caller only showing a path can use `join` and settle for
/// what came back.
pub fn joined(dir: []const u8, name: []const u8, buf: []u8) ?[]const u8 {
    var built = str.Builder{ .buf = buf };
    write(&built, dir, name);
    return if (built.whole()) built.done() else null;
}

/// The same, cut short where it does not fit. For showing a path rather
/// than acting on one.
pub fn join(dir: []const u8, name: []const u8, buf: []u8) []const u8 {
    var built = str.Builder{ .buf = buf };
    write(&built, dir, name);
    return built.done();
}

fn write(built: *str.Builder, dir: []const u8, name: []const u8) void {
    var end = dir.len;
    while (end > 1 and dir[end - 1] == SEPARATOR) end -= 1;
    built.text(dir[0..end]);

    if (end > 0 and dir[end - 1] != SEPARATOR) built.byte(SEPARATOR);

    var from: usize = 0;
    while (from < name.len and name[from] == SEPARATOR) from += 1;
    built.text(name[from..]);
}

test "the parent is the path without its last component, and the root has itself" {
    const testing = std.testing;
    try testing.expectEqualStrings("/home", parent("/home/pictures"));
    try testing.expectEqualStrings("/home", parent("/home/pictures/"));
    try testing.expectEqualStrings("/", parent("/home"));
    try testing.expectEqualStrings("/", parent("/"));
}

test "a joined path that does not fit is refused rather than cut short" {
    var room: [16]u8 = undefined;
    try std.testing.expectEqualStrings("/home/notes", joined("/home", "notes", &room).?);

    // One byte short is a different path, and naming it would move or
    // remove whatever it turns out to be.
    var tight: [8]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), joined("/home", "notes", &tight));
    // Shown rather than acted on, the same call cuts it.
    try std.testing.expectEqualStrings("/home/no", join("/home", "notes", &tight));

    // Exactly the room it needs is not too little.
    var exact: [11]u8 = undefined;
    try std.testing.expectEqualStrings("/home/notes", joined("/home", "notes", &exact).?);
}

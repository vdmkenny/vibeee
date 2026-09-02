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
pub fn join(dir: []const u8, name: []const u8, buf: []u8) []const u8 {
    var built = str.Builder{ .buf = buf };

    var end = dir.len;
    while (end > 1 and dir[end - 1] == SEPARATOR) end -= 1;
    built.text(dir[0..end]);

    if (end > 0 and dir[end - 1] != SEPARATOR) built.byte(SEPARATOR);

    var from: usize = 0;
    while (from < name.len and name[from] == SEPARATOR) from += 1;
    built.text(name[from..]);

    return built.done();
}

test "the parent is the path without its last component, and the root has itself" {
    const testing = std.testing;
    try testing.expectEqualStrings("/home", parent("/home/pictures"));
    try testing.expectEqualStrings("/home", parent("/home/pictures/"));
    try testing.expectEqualStrings("/", parent("/home"));
    try testing.expectEqualStrings("/", parent("/"));
}

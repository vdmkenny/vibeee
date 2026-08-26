//! Path resolution.
//!
//! One place where a relative path becomes an absolute one, so `open`, `stat`,
//! `spawn` and everything after them agree. Resolving in each syscall would
//! guarantee they eventually disagree.
//!
//! "." and ".." are collapsed here rather than left to the filesystem: FAT does
//! store them as real entries, but a path that walks up through a mount point
//! would escape the volume, and the arithmetic belongs above the driver.

const std = @import("std");
const sched = @import("sched.zig");

pub const MAX = 128;

pub const Error = error{ TooLong, Malformed };

/// Turn `input` into an absolute, normalised path in `buf`.
pub fn resolve(input: []const u8, buf: []u8) Error![]const u8 {
    if (input.len == 0) return error.Malformed;

    // Component starts within buf, so ".." can pop the last one.
    var starts: [32]usize = undefined;
    var depth: usize = 0;
    var len: usize = 0;

    buf[0] = '/';
    len = 1;

    var rest = input;
    if (input[0] != '/') {
        // Relative: begin from the working directory.
        const base = sched.cwd();
        if (base.len > buf.len) return error.TooLong;
        @memcpy(buf[0..base.len], base);
        len = base.len;

        // Record the components already present so ".." can unwind into them.
        var i: usize = 1;
        while (i < len) : (i += 1) {
            if (buf[i] == '/') continue;
            if (buf[i - 1] == '/') {
                if (depth == starts.len) return error.TooLong;
                starts[depth] = i;
                depth += 1;
            }
        }
    }

    while (rest.len > 0) {
        while (rest.len > 0 and rest[0] == '/') rest = rest[1..];
        if (rest.len == 0) break;

        var end: usize = 0;
        while (end < rest.len and rest[end] != '/') end += 1;
        const component = rest[0..end];
        rest = rest[end..];

        if (std.mem.eql(u8, component, ".")) continue;

        if (std.mem.eql(u8, component, "..")) {
            // Above the root is still the root, rather than an error: that is
            // what every shell does, and erroring would surprise.
            if (depth > 0) {
                depth -= 1;
                len = starts[depth];
                if (len > 1) len -= 1; // drop the separator too
            } else {
                len = 1;
            }
            continue;
        }

        if (len > 1) {
            if (len + 1 > buf.len) return error.TooLong;
            buf[len] = '/';
            len += 1;
        }
        if (len + component.len > buf.len) return error.TooLong;
        if (depth == starts.len) return error.TooLong;

        starts[depth] = len;
        depth += 1;
        @memcpy(buf[len..][0..component.len], component);
        len += component.len;
    }

    if (len == 0) {
        buf[0] = '/';
        len = 1;
    }
    return buf[0..len];
}

//! Reading configuration into a struct.
//!
//! The struct is the schema: field names are the keys and field types are the
//! value grammar, so adding an option means adding a field and nothing else. A
//! separate table of key names would be a second place to forget.
//!
//! Deliberately small. `key = value`, `#` comments, blank lines separating
//! stanzas where a file holds several records. No sections, no nesting, no
//! quoting: every one of those is a thing to get wrong in a file someone edits
//! by hand on a machine with one text editor.

const std = @import("std");
const str = @import("str.zig");
const sys = @import("sys");

/// Assign one key to one field of `target`, driven by the shape of its type.
///
/// Returns false for a key the struct does not have, so a typo is ignored
/// rather than silently mis-assigned. Supported field types are strings,
/// enums, booleans and unsigned integers, which is everything the
/// configuration files here need.
pub fn assign(target: anytype, key: []const u8, value: []const u8) bool {
    const T = @typeInfo(@TypeOf(target)).pointer.child;

    inline for (std.meta.fields(T)) |field| {
        if (str.eql(key, field.name)) {
            @field(target, field.name) = parse(field.type, value, @field(target, field.name));
            return true;
        }
    }
    return false;
}

fn parse(comptime T: type, value: []const u8, fallback: T) T {
    // A fixed byte array is how a string is stored without an allocator: the
    // file buffer is reused, so a slice into it would dangle.
    if (@typeInfo(T) == .array and @typeInfo(T).array.child == u8) {
        var out: T = @splat(0);
        const n = @min(value.len, out.len);
        @memcpy(out[0..n], value[0..n]);
        return out;
    }

    return switch (@typeInfo(T)) {
        // An unrecognised value keeps the default rather than failing the
        // whole file: one bad line should cost one setting.
        .@"enum" => std.meta.stringToEnum(T, value) orelse fallback,
        .bool => str.eql(value, "true") or str.eql(value, "yes") or str.eql(value, "on"),
        .int => @intCast(@min(str.toUnsigned(value), std.math.maxInt(T))),
        .float => fallback,
        else => value,
    };
}

/// Split a `key = value` line. Null for a comment, a blank line, or anything
/// without a separator.
pub fn pair(line: []const u8) ?struct { key: []const u8, value: []const u8 } {
    const text = str.trim(line);
    if (text.len == 0 or text[0] == '#') return null;

    for (text, 0..) |c, i| {
        if (c != '=') continue;
        return .{ .key = str.trim(text[0..i]), .value = str.trim(text[i + 1 ..]) };
    }
    return null;
}

/// Read a file whose every line configures one field of `target`.
///
/// Missing or unreadable is not an error: a program should start with its
/// defaults rather than refuse to run because nobody wrote a config file.
pub fn load(path: []const u8, target: anytype, buffer: []u8) bool {
    const handle = sys.open(path, .{});
    if (handle < 0) return false;
    defer _ = sys.close(@intCast(handle));

    const n = sys.read(@intCast(handle), buffer);
    if (n <= 0) return false;

    var lines = str.lines(buffer[0..@intCast(n)]);
    while (lines.next()) |line| {
        if (pair(line)) |kv| _ = assign(target, kv.key, kv.value);
    }
    return true;
}

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
const str = @import("lib").str;
const file = @import("file.zig");

/// What became of one `key = value`.
///
/// Richer than "did it work" because the two failures want different answers:
/// a file skips the line and keeps the default, and a caller setting one key
/// on purpose has to be told which of the two it got wrong.
pub const Outcome = enum { assigned, no_such_key, bad_value };

/// Assign one key to one field of `target`, driven by the shape of its type.
///
/// The struct is the schema, so a key it does not have is a typo rather than a
/// setting, and a value its type does not accept is rejected rather than
/// quietly rounded to something.
pub fn assign(target: anytype, key: []const u8, value: []const u8) Outcome {
    const T = @typeInfo(@TypeOf(target)).pointer.child;

    inline for (std.meta.fields(T)) |field| {
        if (std.mem.eql(u8, key, field.name)) {
            const parsed = parse(field.type, value) orelse return .bad_value;
            @field(target, field.name) = parsed;
            return .assigned;
        }
    }
    return .no_such_key;
}

/// Whether `value` is one this key would accept, without assigning it.
pub fn accepts(target: anytype, key: []const u8, value: []const u8) Outcome {
    var trial = target.*;
    return assign(&trial, key, value);
}

/// A value read as `T`, or null when the type does not accept it.
fn parse(comptime T: type, value: []const u8) ?T {
    // Any text is a string, so neither of the two ways of holding one can be
    // given a value it refuses.
    //
    // A slice borrows the buffer the file was read into, which is why a caller
    // taking one has to keep that buffer. A fixed array copies instead, for a
    // caller that outlives the read, which is most of them.
    if (T == []const u8) return value;

    if (@typeInfo(T) == .array and @typeInfo(T).array.child == u8) {
        var out: T = @splat(0);
        const n = @min(value.len, out.len);
        @memcpy(out[0..n], value[0..n]);
        return out;
    }

    // A type that spells and parses itself is its own grammar: an address,
    // a prefix, a list. The pair of declarations is the contract, so a type
    // with only half of it does not silently round-trip wrong.
    if (comptime selfSpelling(T)) return T.parse(value);

    return switch (@typeInfo(T)) {
        .@"enum" => std.meta.stringToEnum(T, value),
        .bool => forBool(value),
        .int => forInt(T, value),
        else => null,
    };
}

/// Whether a type carries its own config grammar: `parse` in, `spell` out.
fn selfSpelling(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"enum", .@"union" => std.meta.hasFn(T, "parse") and std.meta.hasFn(T, "spell"),
        else => false,
    };
}

fn forBool(value: []const u8) ?bool {
    for ([_][]const u8{ "true", "yes", "on" }) |yes| {
        if (std.mem.eql(u8, value, yes)) return true;
    }
    for ([_][]const u8{ "false", "no", "off" }) |no| {
        if (std.mem.eql(u8, value, no)) return false;
    }
    return null;
}

/// Digits only, and within range. A number the type cannot hold is a value
/// somebody meant differently, not one to clamp on their behalf.
fn forInt(comptime T: type, value: []const u8) ?T {
    if (value.len == 0) return null;
    for (value) |c| {
        if (c < '0' or c > '9') return null;
    }
    const n = str.toUnsigned(value);
    if (n > std.math.maxInt(T)) return null;
    return @intCast(n);
}

/// Every key this schema has, as a comptime list, for a caller listing or
/// completing them. Derived from the type so it cannot fall behind it.
pub fn keys(comptime T: type) []const []const u8 {
    comptime {
        var listed: [std.meta.fields(T).len][]const u8 = undefined;
        for (std.meta.fields(T), 0..) |field, i| listed[i] = field.name;
        const frozen = listed;
        return &frozen;
    }
}

/// Every value one key accepts, or an empty list where that is not a closed
/// set. What a completer offers and what a dropdown holds.
pub fn choices(comptime T: type, comptime key: []const u8) []const []const u8 {
    comptime {
        // Comparing every key of a wide schema is a lot of comptime loop
        // iterations; the default quota is sized for less.
        @setEvalBranchQuota(std.meta.fields(T).len * 400);
        for (std.meta.fields(T)) |field| {
            if (!std.mem.eql(u8, key, field.name)) continue;
            if (@typeInfo(field.type) != .@"enum") return &.{};

            const tags = std.meta.fields(field.type);
            var listed: [tags.len][]const u8 = undefined;
            for (tags, 0..) |tag, i| listed[i] = tag.name;
            const frozen = listed;
            return &frozen;
        }
        return &.{};
    }
}

/// Write `target` back out as the file it was read from.
///
/// Every key every time, rather than only what differs from the default: a
/// file somebody can read and edit is worth more here than a short one, and
/// the whole of it is a few hundred bytes.
pub fn render(target: anytype, into: *str.Builder) void {
    const T = @typeInfo(@TypeOf(target)).pointer.child;
    inline for (std.meta.fields(T)) |field| {
        into.text(field.name);
        into.text(" = ");
        format(into, @field(target, field.name));
        into.byte('\n');
    }
}

/// One value, written the way the file spells it. Public because a display is
/// the same question as a file line, and answering it twice is how the two come
/// to disagree.
pub fn format(into: *str.Builder, value: anytype) void {
    const T = @TypeOf(value);
    if (@typeInfo(T) == .array and @typeInfo(T).array.child == u8) {
        return into.text(std.mem.span(@ptrCast(&value)));
    }
    if (comptime selfSpelling(T)) return value.spell(into);
    switch (@typeInfo(T)) {
        .@"enum" => into.text(@tagName(value)),
        .bool => into.text(if (value) "true" else "false"),
        .int => into.number(value),
        else => {},
    }
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
/// Read a file holding several records of one shape, a blank line between
/// them, and say how many were filled. Records past what `into` holds are
/// dropped.
///
/// The grammar already said a blank line separates records; this is what
/// reads them. A file of one record is a file of one record, so a caller with
/// a single stanza can use either.
pub fn loadEach(path: []const u8, into: anytype, buffer: []u8) usize {
    const n = file.readWhole(path, buffer) orelse return 0;
    return eachFrom(buffer[0..n], into);
}

/// The same, from text already in hand. Split from the reading so the
/// grammar can be exercised without a file to read.
pub fn eachFrom(text: []const u8, into: anytype) usize {
    if (text.len == 0) return 0;

    var count: usize = 0;
    var started = false;
    var lines = str.lines(text);
    while (lines.next()) |line| {
        if (pair(line)) |kv| {
            if (!started) {
                if (count == into.len) return count;
                started = true;
                count += 1;
            }
            _ = assign(&into[count - 1], kv.key, kv.value);
            continue;
        }
        // A blank line ends a record; a comment is not a line at all, so a
        // file may be annotated without splitting what it describes.
        if (str.trim(line).len == 0) started = false;
    }
    return count;
}

/// Write several records back, a blank line between them.
pub fn renderEach(records: anytype, into: *str.Builder) void {
    for (records, 0..) |record, index| {
        if (index != 0) into.text("\n");
        var one = record;
        render(&one, into);
    }
}

pub fn load(path: []const u8, target: anytype, buffer: []u8) bool {
    const n = file.readWhole(path, buffer) orelse return false;
    if (n == 0) return false;

    var lines = str.lines(buffer[0..n]);
    while (lines.next()) |line| {
        if (pair(line)) |kv| _ = assign(target, kv.key, kv.value);
    }
    return true;
}

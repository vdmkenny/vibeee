//! Reading configuration into a struct.
//!
//! The struct is the schema: field names are the keys and field types are the
//! value grammar, so adding an option means adding a field and nothing else. A
//! separate table of key names would be a second place to forget.
//!
//! Deliberately small. `key = value`, `#` comments, blank lines separating
//! stanzas where a file holds several records. Quoted values preserve exact
//! bytes with escaped quotes, backslashes and hexadecimal octets. Unquoted
//! values retain the original whitespace-trimming grammar.

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
        // Refused rather than cut short, like every other type here: a
        // password one character too long was accepted and the client
        // authenticated with a shorter secret than was written. The last
        // byte is the terminator `format` reads back, so what fits is one
        // less than the array holds.
        var out: T = @splat(0);
        if (value.len >= out.len or std.mem.indexOfScalar(u8, value, 0) != null) return null;
        @memcpy(out[0..value.len], value);
        return out;
    }

    // A setting nobody has chosen. Empty is the file saying so, which is a
    // value and not a refusal: "the theme's own" and "black" are different
    // answers, and a field that could not hold the first one had to invent a
    // colour that means it.
    if (@typeInfo(T) == .optional) {
        const Inner = @typeInfo(T).optional.child;
        if (value.len == 0) return @as(T, null);
        return parse(Inner, value) orelse null;
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

/// A number the field's own type holds. One it cannot hold is a value
/// somebody meant differently, not one to clamp on their behalf.
fn forInt(comptime T: type, value: []const u8) ?T {
    return std.fmt.parseInt(T, value, 10) catch null;
}

/// Every key this schema has, as a comptime list, for a caller listing or
/// completing them. Derived from the type so it cannot fall behind it.
/// A packed struct of flags, from a comma-separated list of the names of
/// the ones to set.
///
/// Resolved against the type's own field names, so a flag added to the
/// type is a flag this understands with no change here. A name the type
/// does not have is ignored rather than refused: a manifest written for a
/// build with one more flag should still describe the flags this build
/// does have.
pub fn flags(comptime T: type, list: []const u8) T {
    var set = T{};
    var it = str.split(list, ',');
    while (it.next()) |raw| {
        const wanted = str.trim(raw);
        inline for (@typeInfo(T).@"struct".fields) |field| {
            if (field.type == bool and std.mem.eql(u8, wanted, field.name)) {
                @field(set, field.name) = true;
            }
        }
    }
    return set;
}

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
        const start = into.len;
        format(into, @field(target, field.name));
        quoteValue(into, start);
        into.byte('\n');
    }
}

/// One exact value, for display or IPC. `render` adds file quoting around
/// this spelling when needed; `assign` accepts it without interpreting quotes.
pub fn format(into: *str.Builder, value: anytype) void {
    const T = @TypeOf(value);
    if (T == []const u8 or T == []u8) return into.text(value);
    if (@typeInfo(T) == .array and @typeInfo(T).array.child == u8) {
        return into.text(value[0 .. std.mem.indexOfScalar(u8, &value, 0) orelse value.len]);
    }
    // Unset writes nothing, which is how the file says nobody chose.
    if (@typeInfo(T) == .optional) {
        if (value) |chosen| format(into, chosen);
        return;
    }
    if (comptime selfSpelling(T)) return value.spell(into);
    switch (@typeInfo(T)) {
        .@"enum" => into.text(@tagName(value)),
        .bool => into.text(if (value) "true" else "false"),
        .int => into.number(value),
        else => {},
    }
}

/// Escape the spelling already in the builder, expanding backwards so no
/// temporary buffer limits a value or lends a slice to its parsed result.
fn quoteValue(into: *str.Builder, start: usize) void {
    if (into.cut) return;
    const value = into.buf[start..into.len];
    var quoted = str.trim(value).len != value.len;
    var extra: usize = 2;
    for (value) |c| {
        if (c == '"' or c == '\\') {
            quoted = true;
            extra += 1;
        } else if (c < 0x20 or c >= 0x7f) {
            quoted = true;
            extra += 3;
        }
    }
    if (!quoted) return;
    if (extra > into.buf.len - into.len) {
        into.cut = true;
        return;
    }
    var read_at = into.len;
    into.len += extra;
    var write_at = into.len - 1;
    into.buf[write_at] = '"';
    while (read_at > start) {
        read_at -= 1;
        const c = into.buf[read_at];
        if (c == '"' or c == '\\') {
            write_at -= 2;
            into.buf[write_at] = '\\';
            into.buf[write_at + 1] = c;
        } else if (c < 0x20 or c >= 0x7f) {
            write_at -= 4;
            into.buf[write_at] = '\\';
            into.buf[write_at + 1] = 'x';
            into.buf[write_at + 2] = std.fmt.digitToChar(c >> 4, .lower);
            into.buf[write_at + 3] = std.fmt.digitToChar(c & 0xf, .lower);
        } else {
            write_at -= 1;
            into.buf[write_at] = c;
        }
    }
    into.buf[start] = '"';
}

/// Decode only file values. `assign` and `format` exchange exact values, not
/// file syntax. The result borrows the caller's writable file buffer.
fn unquote(value: []u8) ?[]const u8 {
    if (value.len == 0 or value[0] != '"') return value;
    var read_at: usize = 1;
    var written: usize = 0;
    while (read_at < value.len) {
        var c = value[read_at];
        read_at += 1;
        if (c == '"') return if (read_at == value.len) value[0..written] else null;
        if (c == '\\') {
            if (read_at == value.len) return null;
            c = value[read_at];
            read_at += 1;
            switch (c) {
                '"', '\\' => {},
                'n' => c = '\n',
                'r' => c = '\r',
                't' => c = '\t',
                'x' => {
                    if (value.len - read_at < 2) return null;
                    const high = std.fmt.charToDigit(value[read_at], 16) catch return null;
                    const low = std.fmt.charToDigit(value[read_at + 1], 16) catch return null;
                    c = (high << 4) | low;
                    read_at += 2;
                },
                else => return null,
            }
        }
        value[written] = c;
        written += 1;
    }
    return null;
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
    const n = file.readEntire(path, buffer) catch return 0;
    return eachFrom(buffer[0..n], into);
}

/// The same, from text already in hand. Split from the reading so the
/// grammar can be exercised without a file to read. Quoted values decode in
/// place; slice fields borrow `text` and must not outlive it.
pub fn eachFrom(text: []u8, into: anytype) usize {
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
            // pair only borrowed from our mutable text; no const input is changed.
            const value = unquote(@constCast(kv.value)) orelse continue;
            _ = assign(&into[count - 1], kv.key, value);
            continue;
        }
        // A blank line ends a record; a comment is not a line at all, so a
        // file may be annotated without splitting what it describes.
        if (str.trim(line).len == 0) started = false;
    }
    return count;
}

pub fn load(path: []const u8, target: anytype, buffer: []u8) bool {
    const n = file.readEntire(path, buffer) catch return false;
    if (n == 0) return false;

    var lines = str.lines(buffer[0..n]);
    while (lines.next()) |line| {
        if (pair(line)) |kv| {
            const value = unquote(@constCast(kv.value)) orelse continue;
            _ = assign(target, kv.key, value);
        }
    }
    return true;
}

test "file rendering preserves exact strings and typed spellings" {
    const wifi = @import("lib").wifi;
    const Schema = struct {
        text: []const u8 = "",
        fixed: [16]u8 = @splat(0),
        ssid: wifi.Ssid = .{},
        psk: wifi.Psk = .none,
        number: u8 = 0,
    };
    var original = Schema{
        .text = " \"\\\t\r\n\x00\xff# = ",
        .ssid = wifi.Ssid.of(" \"\\\n\x00\xff ").?,
        .psk = wifi.Psk.parse(" " ** 8).?,
        .number = 42,
    };
    try std.testing.expectEqual(Outcome.assigned, assign(&original, "fixed", " spaced "));
    var buffer: [512]u8 = undefined;
    var body = str.Builder{ .buf = &buffer };
    render(&original, &body);
    try std.testing.expect(!body.cut);
    var loaded = [_]Schema{.{}};
    try std.testing.expectEqual(@as(usize, 1), eachFrom(buffer[0..body.len], &loaded));
    try std.testing.expectEqualStrings(original.text, loaded[0].text);
    try std.testing.expectEqualSlices(u8, &original.fixed, &loaded[0].fixed);
    try std.testing.expect(original.ssid.eql(loaded[0].ssid));
    try std.testing.expect(original.psk.eql(loaded[0].psk));
    try std.testing.expectEqual(original.number, loaded[0].number);
    // Borrowed strings still live in the caller's file buffer, not a token
    // or decoder's stack frame. Owned types survive reuse of that buffer.
    try std.testing.expect(@intFromPtr(loaded[0].text.ptr) >= @intFromPtr(&buffer));
    try std.testing.expect(@intFromPtr(loaded[0].text.ptr) + loaded[0].text.len <= @intFromPtr(&buffer) + buffer.len);
    @memset(&buffer, 0);
    try std.testing.expect(original.ssid.eql(loaded[0].ssid));
    try std.testing.expect(original.psk.eql(loaded[0].psk));
}

test "legacy unquoted values and quoted escapes share the file grammar" {
    const Schema = struct { name: []const u8 = "", count: u8 = 0 };
    var text = ("# comment\nname =  old # name  \ncount = 7\n\n" ++
        "name = \" \\t\\r\\n\\x00\\xff\\\"\\\\ \"\ncount = \"8\"\n").*;
    var rows = [_]Schema{ .{}, .{} };
    try std.testing.expectEqual(@as(usize, 2), eachFrom(&text, &rows));
    try std.testing.expectEqualStrings("old # name", rows[0].name);
    try std.testing.expectEqual(@as(u8, 7), rows[0].count);
    try std.testing.expectEqualStrings(" \t\r\n\x00\xff\"\\ ", rows[1].name);
    try std.testing.expectEqual(@as(u8, 8), rows[1].count);
}

test "malformed quoted values leave the previous setting unchanged" {
    const Schema = struct { name: []const u8 = "kept", after: bool = false };
    for ([_][]const u8{ "\"unfinished", "\"bad\\q\"", "\"\\x0\"", "\"\\xzz\"", "\"ok\"junk", "\"tail\\" }) |bad| {
        var buffer: [128]u8 = undefined;
        var text = str.Builder{ .buf = &buffer };
        text.text("name = ");
        text.text(bad);
        text.text("\nafter = true\n");
        var rows = [_]Schema{.{}};
        _ = eachFrom(buffer[0..text.len], &rows);
        try std.testing.expectEqualStrings("kept", rows[0].name);
        try std.testing.expect(rows[0].after);
    }
}

test "quoting detects overflow including expansion and exact boundaries" {
    const Schema = struct { v: []const u8 };
    const value = Schema{ .v = "\n" };
    const expected = "v = \"\\x0a\"\n";
    var buffer: [expected.len + 1]u8 = undefined;
    for (0..buffer.len + 1) |size| {
        var body = str.Builder{ .buf = buffer[0..size] };
        render(&value, &body);
        try std.testing.expectEqual(size < expected.len, body.cut);
        if (!body.cut) try std.testing.expectEqualStrings(expected, body.done());
    }
}

test "every octet round trips through the quoted file spelling" {
    var octets: [256]u8 = undefined;
    for (&octets, 0..) |*octet, i| octet.* = @intCast(i);
    const Schema = struct { value: []const u8 = "" };
    const original = Schema{ .value = &octets };
    var buffer: [1024]u8 = undefined;
    var body = str.Builder{ .buf = &buffer };
    render(&original, &body);
    try std.testing.expect(!body.cut);
    var loaded = [_]Schema{.{}};
    _ = eachFrom(buffer[0..body.len], &loaded);
    try std.testing.expectEqualSlices(u8, &octets, loaded[0].value);
}

test "raw assignment and formatting do not interpret file quotes" {
    const Schema = struct { value: [32]u8 = @splat(0), optional: ?[]const u8 = null };
    var row = Schema{};
    const exact = " \"words\\n\" ";
    try std.testing.expectEqual(Outcome.assigned, assign(&row, "value", exact));
    var buffer: [32]u8 = undefined;
    var body = str.Builder{ .buf = &buffer };
    format(&body, row.value);
    try std.testing.expectEqualStrings(exact, body.done());
    try std.testing.expectEqual(Outcome.assigned, assign(&row, "optional", " "));
    try std.testing.expectEqualStrings(" ", row.optional.?);
    try std.testing.expectEqual(Outcome.bad_value, assign(&row, "value", "a\x00b"));
}

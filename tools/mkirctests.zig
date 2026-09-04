//! Generates a Zig table from the pinned IRC parser vectors.
//!
//! `third_party/irc-parser-tests` is reference data, like `ath_hal`: the cases
//! are read from it and written out as Zig, so nothing in the table is typed
//! by hand and re-pinning the reference means re-running this.
//!
//! It reads only the subset of YAML those files use: block maps and sequences,
//! double-quoted scalars, comments. Anything else is an error rather than a
//! guess, since a misread vector is a test that passes for the wrong
//! reason.

const std = @import("std");

/// The files to read and the table each becomes.
const Vectors = struct {
    file: []const u8,
    table: []const u8,
    doc: []const u8,
};

const VECTORS = [_]Vectors{
    .{ .file = "msg-split.yaml", .table = "split", .doc = "A line and the atoms a parser must find in it." },
    .{ .file = "msg-join.yaml", .table = "join", .doc = "Atoms and every line a writer may render them as." },
    .{ .file = "userhost-split.yaml", .table = "userhost", .doc = "A source and the three names inside it." },
};

/// One case. Holds every key the three files use, so one reader serves all of
/// them and each table keeps the fields it has.
const Case = struct {
    /// The line to parse or source to split, empty for a case that goes from
    /// atoms to lines.
    input: []const u8 = "",
    desc: []const u8 = "",
    tags: std.ArrayList([2][]const u8) = .empty,
    source: ?[]const u8 = null,
    verb: ?[]const u8 = null,
    params: std.ArrayList([]const u8) = .empty,
    matches: std.ArrayList([]const u8) = .empty,
    nick: ?[]const u8 = null,
    user: ?[]const u8 = null,
    host: ?[]const u8 = null,
    /// False where the reference says the line cannot be parsed.
    atoms: bool = false,
};

/// A line's structure, before anything looks at its key.
const Line = struct {
    indent: usize,
    dash: bool,
    key: ?[]const u8,
    value: ?[]const u8,
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: mkirctests <vectors-dir> <out.zig>\n", .{});
        return error.Usage;
    }

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    try out.print(gpa,
        \\//! IRC parser vectors, generated from {s} by `make irctests`.
        \\//! Do not edit: re-pin the reference and run it again.
        \\
        \\/// One case every implementation must agree about.
        \\pub const Case = struct {{
        \\    input: []const u8 = "",
        \\    desc: []const u8 = "",
        \\    tags: []const [2][]const u8 = &.{{}},
        \\    source: ?[]const u8 = null,
        \\    verb: ?[]const u8 = null,
        \\    params: []const []const u8 = &.{{}},
        \\    matches: []const []const u8 = &.{{}},
        \\    nick: ?[]const u8 = null,
        \\    user: ?[]const u8 = null,
        \\    host: ?[]const u8 = null,
        \\    /// False where the reference says the line cannot be parsed.
        \\    atoms: bool = true,
        \\}};
        \\
    , .{args[1]});

    for (VECTORS) |vectors| {
        const path = try std.fs.path.join(gpa, &.{ args[1], vectors.file });
        defer gpa.free(path);
        const source = try cwd.readFileAlloc(io, path, gpa, .limited(4 << 20));
        defer gpa.free(source);

        var cases = try read(gpa, source);
        defer {
            for (cases.items) |*c| {
                c.tags.deinit(gpa);
                c.params.deinit(gpa);
                c.matches.deinit(gpa);
            }
            cases.deinit(gpa);
        }

        try out.print(gpa,
            \\
            \\/// {s}
            \\pub const {s} = [_]Case{{
            \\
        , .{ vectors.doc, vectors.table });
        for (cases.items) |c| try emit(gpa, &out, c);
        try out.appendSlice(gpa, "};\n");
    }

    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.items });
}

/// Read every case in one file.
fn read(gpa: std.mem.Allocator, source: []const u8) !std.ArrayList(Case) {
    var cases: std.ArrayList(Case) = .empty;
    errdefer cases.deinit(gpa);

    // Which list an indented entry under the last key belongs to.
    const Under = enum { none, tags, params, matches };
    var under: Under = .none;
    // The atoms are a block: their contents are indented under the key, so a
    // key at that depth or shallower is outside them.
    var atoms_at: ?usize = null;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = split(raw) orelse continue;

        if (line.dash and line.indent <= 2) {
            try cases.append(gpa, .{});
            under = .none;
            atoms_at = null;
        }
        const current = if (cases.items.len == 0) null else &cases.items[cases.items.len - 1];

        // A sequence entry: a parameter or a rendering.
        if (line.dash and line.indent >= 6) {
            const c = current orelse return error.Stray;
            const value = try unquote(gpa, line.value orelse return error.Stray);
            switch (under) {
                .params => try c.params.append(gpa, value),
                .matches => try c.matches.append(gpa, value),
                else => return error.Stray,
            }
            continue;
        }

        const key = line.key orelse continue;
        const c = current orelse continue;
        if (std.mem.eql(u8, key, "tests")) continue;
        if (atoms_at) |depth| {
            if (line.indent <= depth) atoms_at = null;
        }
        const in_atoms = atoms_at != null;

        // Keys that open a list, and the one that opens the atoms.
        if (std.mem.eql(u8, key, "atoms")) {
            c.atoms = true;
            atoms_at = line.indent;
            under = .none;
            continue;
        }
        if (in_atoms and std.mem.eql(u8, key, "tags")) {
            under = .tags;
            continue;
        }
        if (in_atoms and std.mem.eql(u8, key, "params")) {
            under = .params;
            continue;
        }
        if (!in_atoms and std.mem.eql(u8, key, "matches")) {
            under = .matches;
            continue;
        }

        // Keys carrying a scalar. `source` outside the atoms is the value
        // being split, not an atom of it.
        const value = line.value orelse "\"\"";
        if (!in_atoms) {
            if (std.mem.eql(u8, key, "input") or std.mem.eql(u8, key, "source")) {
                c.input = try unquote(gpa, value);
                under = .none;
                continue;
            }
            if (std.mem.eql(u8, key, "desc")) {
                c.desc = try unquote(gpa, value);
                under = .none;
                continue;
            }
            return error.UnknownKey;
        }

        const atom = found: {
            inline for (.{ "source", "verb", "nick", "user", "host" }) |name| {
                if (std.mem.eql(u8, key, name)) {
                    @field(c, name) = try unquote(gpa, value);
                    break :found true;
                }
            }
            break :found false;
        };
        if (atom) {
            under = .none;
            continue;
        }

        // Anything else under the tags is a tag. Anything else at all is an
        // unhandled key, which is worth stopping for.
        if (under != .tags) return error.UnknownKey;
        try c.tags.append(gpa, .{ try unquote(gpa, key), try unquote(gpa, value) });
    }
    return cases;
}

/// Split one line into its parts. Null for a blank or comment line.
fn split(raw: []const u8) ?Line {
    const ends = std.mem.trimEnd(u8, raw, " \t\r");
    const body = std.mem.trimStart(u8, ends, " ");
    if (body.len == 0 or body[0] == '#') return null;

    const indent = ends.len - body.len;
    var rest = body;
    var dash = false;
    if (std.mem.startsWith(u8, rest, "- ")) {
        dash = true;
        rest = std.mem.trimStart(u8, rest[2..], " ");
    }

    // A key ends at the first colon that is not inside quotes.
    var quoted = false;
    var at: ?usize = null;
    for (rest, 0..) |ch, i| {
        if (ch == '"' and (i == 0 or rest[i - 1] != '\\')) quoted = !quoted;
        if (ch == ':' and !quoted) {
            at = i;
            break;
        }
    }

    const colon = at orelse return .{ .indent = indent, .dash = dash, .key = null, .value = rest };
    const value = std.mem.trimStart(u8, rest[colon + 1 ..], " ");
    return .{
        .indent = indent,
        .dash = dash,
        .key = rest[0..colon],
        .value = if (value.len == 0) null else value,
    };
}

/// Decode a double-quoted scalar, or return a bare word as it is.
fn unquote(gpa: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (text.len < 2 or text[0] != '"') return gpa.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    var i: usize = 1;
    while (i < text.len - 1) : (i += 1) {
        if (text[i] != '\\') {
            try out.append(gpa, text[i]);
            continue;
        }
        i += 1;
        if (i >= text.len - 1) return error.BadEscape;
        if (text[i] == 'x') {
            if (i + 2 >= text.len - 1) return error.BadEscape;
            try out.append(gpa, try std.fmt.parseInt(u8, text[i + 1 ..][0..2], 16));
            i += 2;
            continue;
        }
        try out.append(gpa, switch (text[i]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\' => '\\',
            '"' => '"',
            else => return error.BadEscape,
        });
    }
    return out.toOwnedSlice(gpa);
}

fn emit(gpa: std.mem.Allocator, w: *std.ArrayList(u8), c: Case) !void {
    try w.appendSlice(gpa, "    .{");
    if (c.input.len != 0) try field(gpa, w, "input", c.input);
    if (c.desc.len != 0) try field(gpa, w, "desc", c.desc);
    if (c.tags.items.len != 0) {
        try w.appendSlice(gpa, " .tags = &.{ ");
        for (c.tags.items, 0..) |tag, i| {
            if (i != 0) try w.appendSlice(gpa, ", ");
            try w.appendSlice(gpa, ".{ ");
            try quote(gpa, w, tag[0]);
            try w.appendSlice(gpa, ", ");
            try quote(gpa, w, tag[1]);
            try w.appendSlice(gpa, " }");
        }
        try w.appendSlice(gpa, " },");
    }
    inline for (.{ "source", "verb", "nick", "user", "host" }) |name| {
        if (@field(c, name)) |value| try field(gpa, w, name, value);
    }
    inline for (.{ "params", "matches" }) |name| {
        const list = @field(c, name).items;
        if (list.len != 0) {
            try w.print(gpa, " .{s} = &.{{ ", .{name});
            for (list, 0..) |item, i| {
                if (i != 0) try w.appendSlice(gpa, ", ");
                try quote(gpa, w, item);
            }
            try w.appendSlice(gpa, " },");
        }
    }
    if (!c.atoms) try w.appendSlice(gpa, " .atoms = false,");
    try w.appendSlice(gpa, " },\n");
}

fn field(gpa: std.mem.Allocator, w: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    try w.print(gpa, " .{s} = ", .{name});
    try quote(gpa, w, value);
    try w.append(gpa, ',');
}

fn quote(gpa: std.mem.Allocator, w: *std.ArrayList(u8), text: []const u8) !void {
    try w.append(gpa, '"');
    for (text) |ch| switch (ch) {
        '"' => try w.appendSlice(gpa, "\\\""),
        '\\' => try w.appendSlice(gpa, "\\\\"),
        '\n' => try w.appendSlice(gpa, "\\n"),
        '\r' => try w.appendSlice(gpa, "\\r"),
        '\t' => try w.appendSlice(gpa, "\\t"),
        else => if (ch < 0x20 or ch == 0x7F)
            try w.print(gpa, "\\x{x:0>2}", .{ch})
        else
            try w.append(gpa, ch),
    };
    try w.append(gpa, '"');
}

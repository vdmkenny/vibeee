//! Writes the settings reference from the schema, into `docs/settings.md`
//! and into the manual pages that ask for it.
//!
//! The schema is the source of truth and this is a projection of it.
//! Running as part of the build means no page can describe a key the
//! system does not have, and no key can be added without the page that
//! covers it gaining a line, which is the usual way settings
//! documentation goes wrong.
//!
//! A page asks by carrying the marker line below, naming the domain it
//! covers. Everything after that line belongs to this program, so a page
//! puts it last and writes whatever it likes above it.

const std = @import("std");
const schema = @import("user/proto/schema.zig");
const str = @import("lib").str;

/// What a page carries to ask for keys. The domains it wants follow, or
/// `all` for a page that covers the lot.
const MARKER = "Settings, generated from the schema:";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const doc_path = if (args.len > 1) args[1] else "docs/settings.md";
    const manual_dir = if (args.len > 2) args[2] else "manual";
    const etc_dir = if (args.len > 3) args[3] else "etc";

    var doc: std.ArrayList(u8) = .empty;
    defer doc.deinit(gpa);
    try writeReference(gpa, &doc);
    var changed: usize = 0;
    if (try replaceFile(gpa, init.io, doc_path, doc.items)) changed += 1;
    changed += try updateManual(gpa, init.io, manual_dir);
    try checkShipped(gpa, init.io, etc_dir);
    if (changed > 0) std.debug.print("settings docs: {d} file(s) rewritten\n", .{changed});
}

// ---------------------------------------------------------------------------
// The reference
// ---------------------------------------------------------------------------

fn writeReference(gpa: std.mem.Allocator, doc: *std.ArrayList(u8)) !void {
    try doc.appendSlice(gpa,
        \\# vibeee settings
        \\
        \\<!-- Generated from src/user/proto/schema.zig by `zig build settings-docs`.
        \\     Do not edit: change the schema instead. -->
        \\
        \\Every key the system has, what it accepts, and what it is when nobody has
        \\said otherwise. Keys are declared by the system, so a name it does not know
        \\is an error rather than a new setting.
        \\
        \\    cfg                       every domain and key
        \\    cfg net                   one domain
        \\    cfg set net.hostname pi   change one
        \\    cfg reset net.hostname    put it back
        \\
        \\Values are read from `/etc/<domain>.cfg` first and then from `/cfg` on top,
        \\so an image ships with the first and a machine remembers the second.
        \\
        \\
    );

    inline for (std.meta.fields(schema.Domains)) |domain| {
        try doc.appendSlice(gpa, "## " ++ domain.name ++ "\n\n");
        try doc.appendSlice(gpa, "| key | accepts | default |\n|---|---|---|\n");

        const defaults: domain.type = .{};
        inline for (std.meta.fields(domain.type)) |field| {
            try doc.appendSlice(gpa, "| `" ++ domain.name ++ "." ++ field.name ++ "` | ");
            try escaped(gpa, doc, accepted(field.type));
            try doc.appendSlice(gpa, " | ");

            var spelled: [128]u8 = undefined;
            const text = spell(field.type, @field(defaults, field.name), &spelled);
            if (text.len == 0) {
                try doc.appendSlice(gpa, "unset");
            } else {
                try doc.append(gpa, '`');
                try doc.appendSlice(gpa, text);
                try doc.append(gpa, '`');
            }
            try doc.appendSlice(gpa, " |\n");
        }
        try doc.append(gpa, '\n');
    }
}

// ---------------------------------------------------------------------------
// What the image ships with
//
// The files in `etc` are hand written, because the prose in them is worth
// more than anything generated would be. What is not left to a person is
// remembering to add a line when a key is added: a key with no entry there
// is a setting nobody discovers, so the build says so rather than waiting
// for somebody to notice.
// ---------------------------------------------------------------------------

fn checkShipped(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !void {
    var missing: usize = 0;

    inline for (std.meta.fields(schema.Domains)) |domain| {
        const path = try std.fs.path.join(gpa, &.{ dir_path, domain.name ++ ".cfg" });
        defer gpa.free(path);

        if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 * 1024))) |source| {
            defer gpa.free(source);
            inline for (std.meta.fields(domain.type)) |key| {
                if (!mentions(source, key.name)) {
                    std.debug.print("{s}: no line for {s}.{s}\n", .{ path, domain.name, key.name });
                    missing += 1;
                }
            }
        } else |_| {
            std.debug.print("{s}: the {s} settings ship without a file\n", .{ path, domain.name });
            missing += 1;
        }
    }

    if (missing > 0) return error.SettingNotShipped;
}

/// Whether a file has a line for `key`, set or left empty. A commented line
/// does not count: the point is that somebody opening the file finds the
/// setting, and a key hidden behind a hash is one they will not.
fn mentions(source: []const u8, key: []const u8) bool {
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = str.trim(line);
        if (!std.mem.startsWith(u8, trimmed, key)) continue;

        const rest = str.trim(trimmed[key.len..]);
        if (rest.len > 0 and rest[0] == '=') return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// The manual
// ---------------------------------------------------------------------------

fn updateManual(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });

    var written: usize = 0;
    var walker = dir.iterate();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;

        const path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        defer gpa.free(path);

        const source = dir.readFileAlloc(io, entry.name, gpa, .limited(64 * 1024)) catch continue;
        defer gpa.free(source);

        const at = std.mem.indexOf(u8, source, MARKER) orelse continue;
        const rest = source[at + MARKER.len ..];
        const line = rest[0 .. std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len];
        if (str.trim(line).len == 0) {
            std.debug.print("{s}: the marker names no domain\n", .{path});
            return error.NoDomainNamed;
        }

        var page: std.ArrayList(u8) = .empty;
        defer page.deinit(gpa);
        try page.appendSlice(gpa, source[0 .. at + MARKER.len]);
        try page.append(gpa, ' ');
        try page.appendSlice(gpa, str.trim(line));
        try page.appendSlice(gpa, "\n");

        const every = std.mem.eql(u8, str.trim(line), "all");
        inline for (std.meta.fields(schema.Domains)) |domain| {
            if (every or wanted(line, domain.name)) {
                try page.appendSlice(gpa, "\n");
                if (every) try page.appendSlice(gpa, "  [" ++ domain.name ++ "]\n");
                try writeKeys(gpa, &page, domain.name);
            }
        }

        if (try replaceFile(gpa, io, path, page.items)) written += 1;
    }
    return written;
}

/// Whether the marker's line names this domain. A page may name several,
/// because a tool that edits two of them documents both.
fn wanted(line: []const u8, domain: []const u8) bool {
    var words = str.words(line);
    while (words.next()) |word| {
        if (std.mem.eql(u8, word, domain)) return true;
    }
    return false;
}

/// One domain's keys, in the manual's own shape: the key and what it is
/// now, then what it accepts beneath.
fn writeKeys(gpa: std.mem.Allocator, page: *std.ArrayList(u8), domain: []const u8) !void {
    inline for (std.meta.fields(schema.Domains)) |field| {
        if (std.mem.eql(u8, field.name, domain)) {
            const defaults: field.type = .{};
            inline for (std.meta.fields(field.type)) |key| {
                const name = field.name ++ "." ++ key.name;
                try page.appendSlice(gpa, "  " ++ name);

                var spelled: [128]u8 = undefined;
                const text = spell(key.type, @field(defaults, key.name), &spelled);
                try pad(gpa, page, name.len + 2, 28);
                try page.appendSlice(gpa, if (text.len == 0) "unset" else text);
                try page.append(gpa, '\n');

                try page.appendSlice(gpa, "      ");
                try page.appendSlice(gpa, accepted(key.type));
                try page.append(gpa, '\n');
            }
        }
    }
}

/// A table cell cannot hold a bare pipe, and a list of what a key accepts
/// is mostly pipes.
fn escaped(gpa: std.mem.Allocator, doc: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |c| {
        if (c == '|') try doc.append(gpa, '\\');
        try doc.append(gpa, c);
    }
}

fn pad(gpa: std.mem.Allocator, page: *std.ArrayList(u8), written: usize, column: usize) !void {
    var at = written;
    while (at < column) : (at += 1) try page.append(gpa, ' ');
    if (at == written) try page.append(gpa, ' ');
}

// ---------------------------------------------------------------------------
// What a type accepts, and what a value looks like
// ---------------------------------------------------------------------------

/// What may be written for a key.
///
/// A type whose grammar is its own `parse` says so in an `accepts`
/// declaration, because no amount of reflection can read a function. The
/// shapes that have no grammar beyond themselves are described from their
/// fields.
fn accepted(comptime T: type) []const u8 {
    if (comptime std.meta.hasFn(T, "parse") and @hasDecl(T, "accepts")) return T.accepts;

    return switch (@typeInfo(T)) {
        .bool => "true | false",
        .@"enum" => comptime blk: {
            var out: []const u8 = "";
            for (std.meta.fields(T), 0..) |field, i| {
                out = out ++ (if (i == 0) "" else " | ") ++ field.name;
            }
            break :blk out;
        },
        .int => "a number",
        else => "a value",
    };
}

/// How a value is written in a settings file, which is what a default has
/// to be shown as.
fn spell(comptime T: type, value: T, buf: []u8) []const u8 {
    if (comptime std.meta.hasFn(T, "spell")) {
        var built = str.Builder{ .buf = buf };
        value.spell(&built);
        return built.done();
    }
    return switch (@typeInfo(T)) {
        .bool => if (value) "true" else "false",
        .@"enum" => @tagName(value),
        .int => std.fmt.bufPrint(buf, "{d}", .{value}) catch "",
        else => "",
    };
}

/// Write a file only when what it holds would change, and answer whether
/// it did.
///
/// This runs on every build, so writing unconditionally would touch a
/// source file every time and make the tree look edited when nothing
/// about it moved.
fn replaceFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8, contents: []const u8) !bool {
    if (std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20))) |existing| {
        defer gpa.free(existing);
        if (std.mem.eql(u8, existing, contents)) return false;
    } else |_| {}

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents });
    return true;
}

//! Fails the build on an import nothing uses.
//!
//! Zig reports an unused local, but a container-level `const x = @import(...)`
//! is a declaration rather than a variable, so an import left behind when its
//! last caller moved away compiles cleanly and forever. That is how a module
//! ends up appearing to depend on something it does not, which is exactly the
//! kind of claim `check-layering.zig` exists to police: a stale import is a
//! layering violation waiting to be believed.
//!
//! Textual rather than semantic, and deliberately so: a tool that had to build
//! a syntax tree to answer this would be a compiler, and the shape it looks for
//! is one line long.

const std = @import("std");

/// A binding this ignores, because it is re-exported rather than called.
///
/// `pub` is the whole test: a module that gathers other modules for its callers
/// uses none of them itself, and that is its purpose rather than an oversight.
fn isReexport(line: []const u8) bool {
    return std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "pub ");
}

/// The name bound by `const NAME = @import(...)`, or null for any other line.
///
/// Only bindings at the left margin count. An import inside a function is a
/// local, which the compiler already refuses to leave unused.
fn boundName(line: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, line, "const ")) return null;
    if (std.mem.indexOf(u8, line, "@import(") == null) return null;

    const after = line["const ".len..];
    const eq = std.mem.indexOfScalar(u8, after, '=') orelse return null;
    const name = std.mem.trimEnd(u8, after[0..eq], " ");
    if (name.len == 0) return null;

    for (name) |c| {
        if (!isWordByte(c)) return null;
    }
    return name;
}

fn isWordByte(c: u8) bool {
    return c == '_' or std.ascii.isAlphanumeric(c);
}

/// Whether `name` appears in `source` as a name rather than inside a longer
/// one, ignoring the line that declares it.
///
/// The boundary test is what makes this usable: `str` occurs inside `stream`
/// and a substring search would call every import used.
fn isUsed(source: []const u8, name: []const u8, declared_on: usize) bool {
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        line_no += 1;
        if (line_no == declared_on) continue;

        var at: usize = 0;
        while (std.mem.indexOfPos(u8, line, at, name)) |found| {
            at = found + name.len;
            const before_ok = found == 0 or !isWordByte(line[found - 1]);
            const after_ok = at == line.len or !isWordByte(line[at]);
            if (before_ok and after_ok) return true;
        }
    }
    return false;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var root = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer root.close(io);

    var walker = try root.walk(gpa);
    defer walker.deinit();

    var stale: usize = 0;

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const source = root.readFileAlloc(io, entry.path, gpa, .limited(4 << 20)) catch continue;
        defer gpa.free(source);

        var line_no: usize = 0;
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            line_no += 1;
            if (isReexport(line)) continue;
            const name = boundName(line) orelse continue;
            if (isUsed(source, name, line_no)) continue;

            stale += 1;
            std.debug.print("src/{s}:{d}: `{s}` is imported and never used\n", .{ entry.path, line_no, name });
        }
    }

    if (stale > 0) {
        std.debug.print("\n{d} unused import(s)\n", .{stale});
        return error.UnusedImport;
    }
}

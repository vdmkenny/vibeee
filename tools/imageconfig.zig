//! The image configuration tool behind `make menuconfig` and the other
//! configuration targets. What the options are and what they do is
//! `src/config`; this is the terminal and the files.
//!
//!   imageconfig menu <config>                  edit a configuration
//!   imageconfig defconfig <preset> <config>    write a preset
//!   imageconfig savedefconfig <config> <file>  write what differs from the defaults
//!   imageconfig olddefconfig <config>          rewrite a configuration whole
//!   imageconfig list                           name the presets
//!   imageconfig plan <config> <build dir>      write the Makefile's variables and the generated /etc files

const std = @import("std");
const config = @import("config");

const options = config.options;
const dotconfig = config.dotconfig;
const Config = options.Config;
const Io = std.Io;

const Command = enum { menu, defconfig, savedefconfig, olddefconfig, list, plan };

const USAGE =
    \\usage: imageconfig menu <config>
    \\       imageconfig defconfig <preset> <config>
    \\       imageconfig savedefconfig <config> <file>
    \\       imageconfig olddefconfig <config>
    \\       imageconfig list
    \\       imageconfig plan <config> <build dir>
    \\
;

/// The most a configuration or a file the plan filters may hold.
const FILE_MAX = 256 * 1024;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);

    const command = if (args.len > 1) std.meta.stringToEnum(Command, args[1]) else null;
    const wanted: usize = switch (command orelse .list) {
        .list => 2,
        .menu, .olddefconfig => 3,
        .defconfig, .savedefconfig, .plan => 4,
    };
    if (command == null or args.len != wanted) {
        std.debug.print("{s}", .{USAGE});
        std.process.exit(2);
    }

    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buffer);
    const out = &stdout.interface;
    defer out.flush() catch {};

    switch (command.?) {
        .menu => try menu(io, init.gpa, arena, args[2], out),
        .defconfig => {
            const preset = std.meta.stringToEnum(config.presets.Preset, args[2]) orelse {
                std.debug.print("imageconfig: no preset named {s}; `make list-defconfigs` names them\n", .{args[2]});
                std.process.exit(1);
            };
            try save(io, arena, args[3], preset.about().config, .full);
            try out.print("Configuration written to {s}.\n", .{args[3]});
        },
        .savedefconfig => {
            try save(io, arena, args[3], try load(io, arena, args[2]), .minimal);
            try out.print("Saved to {s}.\n", .{args[3]});
        },
        .olddefconfig => try save(io, arena, args[2], try load(io, arena, args[2]), .full),
        .list => try list(out),
        .plan => try plan(io, arena, try load(io, arena, args[2]), args[3]),
    }
}

/// The configuration in `path`: defaults when there is no such file. Lines it
/// cannot use are reported and passed over.
fn load(io: Io, arena: std.mem.Allocator, path: []const u8) !Config {
    const text = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(FILE_MAX)) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    var problems: dotconfig.Problems = .{};
    const loaded = dotconfig.read(text, &problems);
    for (problems.slice()) |problem| switch (problem.what) {
        .unknown => |name| std.debug.print("{s}:{d}: no option {s}, passed over\n", .{ path, problem.line, name }),
        .malformed => std.debug.print("{s}:{d}: not a configuration line, passed over\n", .{ path, problem.line }),
        .refused => |option| std.debug.print("{s}:{d}: a value {s} does not take, passed over\n", .{ path, problem.line, dotconfig.symbol(option) }),
    };
    return loaded;
}

/// Write a configuration. A file already there with other contents is kept as
/// `<path>.old`.
fn save(io: Io, arena: std.mem.Allocator, path: []const u8, value: Config, style: dotconfig.Style) !void {
    var out: Io.Writer.Allocating = .init(arena);
    try dotconfig.write(&value, style, &out.writer);
    const cwd = Io.Dir.cwd();
    if (cwd.readFileAlloc(io, path, arena, .limited(FILE_MAX))) |before| {
        if (std.mem.eql(u8, before, out.written())) return;
        const old = try std.fmt.allocPrint(arena, "{s}.old", .{path});
        try cwd.rename(path, cwd, old, io);
    } else |_| {}
    try cwd.writeFile(io, .{ .sub_path = path, .data = out.written() });
}

/// Write `bytes` to `path` unless it already holds them, so what depends on
/// the file is rebuilt only when it changes.
fn update(io: Io, arena: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const cwd = Io.Dir.cwd();
    if (cwd.readFileAlloc(io, path, arena, .limited(FILE_MAX))) |before| {
        if (std.mem.eql(u8, before, bytes)) return;
    } else |_| {}
    try cwd.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn list(out: *Io.Writer) Io.Writer.Error!void {
    for (std.enums.values(config.presets.Group)) |group| {
        try out.print("{s}\n", .{switch (group) {
            .image => "What goes in the image, for the Eee PC 701:",
            .machine => "Machines, each the default image for its processor:",
        }});
        for (std.enums.values(config.presets.Preset)) |preset| {
            const about = preset.about();
            if (about.group != group) continue;
            var name: [64]u8 = undefined;
            try listed(out, std.fmt.bufPrint(&name, "{s}_defconfig", .{@tagName(preset)}) catch unreachable, about.summary);
        }
    }
    try listed(out, "defconfig", "The default: the Eee PC 701 with everything but the extra applications.");
}

fn listed(out: *Io.Writer, target: []const u8, summary: []const u8) Io.Writer.Error!void {
    try out.print("  {s:<30}{s}\n", .{ target, summary });
}

/// The /etc files the plan writes from the committed ones, by their names.
const Generated = enum { services, disabled, openers };

fn plan(io: Io, arena: std.mem.Allocator, value: Config, build: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const image: config.plan.Plan = .init(value);
    const services = try cwd.readFileAlloc(io, "etc/services", arena, .limited(FILE_MAX));

    const etc = try std.fs.path.join(arena, &.{ build, "etc" });
    try cwd.createDirPath(io, etc);
    for (std.enums.values(Generated)) |which| {
        const text = try cwd.readFileAlloc(io, try std.fs.path.join(arena, &.{ "etc", @tagName(which) }), arena, .limited(FILE_MAX));
        var out: Io.Writer.Allocating = .init(arena);
        try switch (which) {
            .services => image.services(text, &out.writer),
            .disabled => image.disabled(text, &out.writer),
            .openers => image.openers(text, &out.writer),
        };
        try update(io, arena, try std.fs.path.join(arena, &.{ etc, @tagName(which) }), out.written());
    }

    var drivers: std.ArrayList([]const u8) = .empty;
    var dir = try cwd.openDir(io, "drivers", .{ .iterate = true });
    defer dir.close(io);
    var entries = dir.iterate();
    while (try entries.next(io)) |entry| {
        if (!std.mem.endsWith(u8, entry.name, ".man")) continue;
        const manifest = try dir.readFileAlloc(io, entry.name, arena, .limited(FILE_MAX));
        if (image.keepsDriver(manifest, services)) try drivers.append(arena, try arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, drivers.items, {}, lessThan);

    var out: Io.Writer.Allocating = .init(arena);
    try image.makefile(drivers.items, &out.writer);
    try update(io, arena, try std.fs.path.join(arena, &.{ build, "config.mk" }), out.written());
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

// ---------------------------------------------------------------------------
// The menu, in a terminal
// ---------------------------------------------------------------------------

/// How an editing session ended.
const Outcome = union(enum) {
    /// Written to this file.
    saved: []const u8,
    /// Left with changes not written.
    unsaved,
    unchanged,
};

fn menu(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8, out: *Io.Writer) !void {
    if (!try Io.File.stdin().isTty(io)) {
        std.debug.print("imageconfig: the menu needs a terminal\n", .{});
        std.process.exit(1);
    }
    // Said once the terminal is back to how it was.
    switch (try edit(io, gpa, arena, path, out)) {
        .saved => |to| try out.print("Configuration written to {s}.\n", .{to}),
        .unsaved => try out.writeAll("Your configuration changes were not saved.\n"),
        .unchanged => {},
    }
}

/// The editor in the terminal's alternate screen, with keys read raw.
fn edit(io: Io, gpa: std.mem.Allocator, arena: std.mem.Allocator, path: []const u8, out: *Io.Writer) !Outcome {
    const stdin = Io.File.stdin();
    var editor: config.menu.Editor = .init(try load(io, arena, path), path);

    const original = try std.posix.tcgetattr(stdin.handle);
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    // .NOW keeps keys typed while the tool was starting.
    try std.posix.tcsetattr(stdin.handle, .NOW, raw);
    defer std.posix.tcsetattr(stdin.handle, .NOW, original) catch {};

    try out.writeAll("\x1b[?1049h");
    defer {
        out.writeAll("\x1b[0m\x1b[?25h\x1b[?1049l") catch {};
        out.flush() catch {};
    }

    var cells: []config.screen.Cell = &.{};
    defer gpa.free(cells);
    // The size of the frame on the terminal, and whether it shows the editor
    // as it is now.
    var shown: ?Size = null;
    var current = false;
    var saved: ?[]const u8 = null;

    while (true) {
        const size = terminalSize(io, shown);
        const resized = shown == null or !std.meta.eql(shown.?, size);
        if (resized or !current) {
            if (cells.len < @as(usize, size.cols) * size.rows) {
                gpa.free(cells);
                cells = try gpa.alloc(config.screen.Cell, @as(usize, size.cols) * size.rows);
            }
            var screen = config.screen.Screen.init(cells, size.cols, size.rows);
            editor.draw(&screen);
            try screen.write(out, resized);
            try out.flush();
            shown = size;
            current = true;
        }

        // A quarter of a second without a key is a chance to notice a resize.
        var polled = [_]std.posix.pollfd{.{ .fd = stdin.handle, .events = std.posix.POLL.IN, .revents = 0 }};
        if (try std.posix.poll(&polled, 250) == 0) continue;
        var bytes: [64]u8 = undefined;
        const got = try std.posix.read(stdin.handle, &bytes);
        if (got == 0) break;

        var at: usize = 0;
        while (at < got) {
            const decoded = config.keys.first(bytes[at..got]);
            at += decoded.len;
            const key = decoded.key orelse continue;
            switch (editor.press(key)) {
                .none => {},
                .quit => break,
                .save => |target| if (write(io, arena, target, &editor)) {
                    saved = try arena.dupe(u8, target);
                },
                .load => |source| {
                    const text = Io.Dir.cwd().readFileAlloc(io, source, arena, .limited(FILE_MAX)) catch {
                        editor.failed("That file could not be read.");
                        continue;
                    };
                    var problems: dotconfig.Problems = .{};
                    editor.wasLoaded(dotconfig.read(text, &problems));
                },
                .save_and_quit => |target| if (write(io, arena, target, &editor)) {
                    return .{ .saved = try arena.dupe(u8, target) };
                },
            }
        } else {
            current = false;
            continue;
        }
        break;
    }
    if (editor.changed()) return .unsaved;
    return if (saved) |to| .{ .saved = to } else .unchanged;
}

/// Write the editor's configuration, telling it whether that worked.
fn write(io: Io, arena: std.mem.Allocator, target: []const u8, editor: *config.menu.Editor) bool {
    save(io, arena, target, editor.config, .full) catch {
        editor.failed("The configuration could not be written.");
        return false;
    };
    editor.wasSaved();
    return true;
}

const Size = struct { cols: u16, rows: u16 };

/// The terminal's size. When it cannot be asked, the size last known, or
/// 80 by 24 before there is one.
fn terminalSize(io: Io, known: ?Size) Size {
    const fallback = known orelse Size{ .cols = 80, .rows = 24 };
    var size: std.posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = io.operate(.{ .device_io_control = .{
        .file = Io.File.stdout(),
        .code = std.posix.T.IOCGWINSZ,
        .arg = &size,
    } }) catch return fallback;
    if (result.device_io_control < 0 or size.col == 0 or size.row == 0) return fallback;
    return .{ .cols = size.col, .rows = size.row };
}

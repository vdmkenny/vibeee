//! Generates docs/libeui.md from the toolkit itself.
//!
//! The toolkit is the source of truth and this is a projection of it, the same
//! arrangement the syscall table and the settings schema have. A control added
//! to `eui.Context` appears in the guide on the next build, a picture added to
//! `eui.icon` is drawn in it, and a colour added to the theme lands in the
//! table with its value in every theme.
//!
//! What cannot be derived is written here: what the toolkit is for, how a
//! program's frame is shaped, and which rule decides where a control belongs.
//! Everything else is read out of the code, because a hand-written list of
//! controls is a list that stops being true.

const std = @import("std");
const eui = @import("eui");

const Context = eui.widget.Context;

pub fn main(init: std.process.Init) !void {
    // Every signature in the guide is spelled at compile time, and a table of
    // forty controls is more branches than the default allowance.
    @setEvalBranchQuota(200_000);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const out_path = if (args.len > 1) args[1] else "docs/libeui.md";

    const gpa = init.gpa;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const w = &buf;

    try w.appendSlice(gpa,
        \\# libeui, the toolkit
        \\
        \\<!-- Generated from src/user/eui/ by `zig build eui-docs`.
        \\     Do not edit: change the toolkit instead. -->
        \\
        \\Every program that draws draws with this. It has no syscalls in it: a
        \\control is given a surface and a rectangle and it paints, and the
        \\program it belongs to is the one that talks to the window manager.
        \\That is what makes the whole toolkit testable on a host with no
        \\machine under it.
        \\
        \\## The frame a program draws
        \\
        \\```zig
        \\ctx.begin(pointer_x, pointer_y, buttons);
        \\if (ctx.damaged) surface.fill(area, theme.current().surface);
        \\
        \\if (ctx.button(save_rect, "Save")) save();
        \\
        \\ctx.end();
        \\connection.commit(window, ctx.damageList()) catch {};
        \\```
        \\
        \\A control is a call that both draws and answers: `ctx.button` returns
        \\whether it was pressed this pass, so there is no separate event
        \\handler to keep in step with the drawing. State that must outlive a
        \\pass lives in the caller, and the context keeps only what it needs to
        \\know whether a control has to be repainted.
        \\
        \\Nothing repaints unless it changed. `ctx.damaged` is true when the
        \\whole window has to be redrawn; otherwise each control decides for
        \\itself, and `ctx.damageList()` is the set of rectangles the manager is
        \\asked to put on the screen. A program that filled its background every
        \\pass would flicker on hardware, which is why the fill above is inside
        \\the test.
        \\
        \\## Where a control belongs
        \\
        \\In the toolkit, if two programs could want it. An applet that draws
        \\its own slider has made a second slider that will drift from this one.
        \\Geometry is pure and tested on the host; painting is the part that
        \\needs a screen, and it is kept thin enough to be checked by looking.
        \\
        \\
    );

    // The toolkit's own source, for the dividers inside it.
    const widget_path = if (args.len > 2) args[2] else "src/user/eui/widget.zig";
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, widget_path, gpa, .limited(1 << 20));
    defer gpa.free(source);
    const grouping = readGrouping(source);

    try controls(gpa, w, &grouping);
    try modules(gpa, w);
    try iconTable(gpa, w);
    try themeTable(gpa, w);

    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = out_path, .data = buf.items });
}

/// Every call on the context, in three groups the code itself decides.
///
/// A control is a call that takes a rectangle and paints in it. A frame call
/// takes no rectangle: it begins a pass, ends one, or answers a question about
/// the pass. Anything that touches an `Entry` is machinery a control is built
/// out of rather than something an application calls. No list is kept here:
/// the shape of a call is what puts it in its group.
fn controls(gpa: std.mem.Allocator, w: *std.ArrayList(u8), grouping: *const Grouping) !void {
    try section(gpa, w, grouping, .control,
        \\## Controls
        \\
        \\Each takes the rectangle it occupies and returns what the person did
        \\with it this pass.
        \\
        \\
    );

    try section(gpa, w, grouping, .frame,
        \\## The pass
        \\
        \\What a program calls around its controls, once each way.
        \\
        \\
    );

    try section(gpa, w, grouping, .authoring,
        \\## For control authors
        \\
        \\What a new control is built out of: a slot that remembers what it
        \\looked like last pass, the pointer's business with it, and whether
        \\that means it has to be painted again.
        \\
        \\
    );
}

const Group = enum { frame, authoring, control };

/// Which group each call belongs to, taken from the dividers the toolkit's
/// own source already has.
///
/// Read out of the file rather than guessed from a signature: `label` and
/// `addDamage` have the same shape and belong in different halves of the
/// guide, and the code says which is which on the line above them.
const Grouping = struct {
    names: [128][]const u8 = @splat(""),
    groups: [128]Group = @splat(.frame),
    count: usize = 0,

    fn of(self: *const Grouping, name: []const u8) Group {
        for (self.names[0..self.count], self.groups[0..self.count]) |known, group| {
            if (std.mem.eql(u8, known, name)) return group;
        }
        return .frame;
    }
};

fn readGrouping(source: []const u8) Grouping {
    var out = Grouping{};
    var group: Group = .frame;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const text = std.mem.trim(u8, line, " \t\r");
        if (std.mem.eql(u8, text, "// For control authors")) group = .authoring;
        if (std.mem.eql(u8, text, "// Controls")) group = .control;

        const marker = "pub fn ";
        if (std.mem.startsWith(u8, text, marker)) {
            const rest = text[marker.len..];
            const open = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
            if (out.count == out.names.len) continue;
            out.names[out.count] = rest[0..open];
            out.groups[out.count] = group;
            out.count += 1;
        }
    }
    return out;
}

fn section(gpa: std.mem.Allocator, w: *std.ArrayList(u8), grouping: *const Grouping, group: Group, head: []const u8) !void {
    try w.appendSlice(gpa, head);
    try w.appendSlice(gpa, "| call | signature |\n|---|---|\n");
    inline for (@typeInfo(Context).@"struct".decls) |decl| {
        const field = @field(Context, decl.name);
        if (@typeInfo(@TypeOf(field)) == .@"fn" and grouping.of(decl.name) == group) {
            try w.print(gpa, "| `{s}` | `{s}` |\n", .{ decl.name, comptime signature(@TypeOf(field)) });
        }
    }
    try w.appendSlice(gpa, "\n");
}

/// A call's shape without the module paths, which are noise in a table.
fn signature(comptime Fn: type) []const u8 {
    @setEvalBranchQuota(100_000);
    const info = @typeInfo(Fn).@"fn";
    comptime var out: []const u8 = "fn (";
    inline for (info.params, 0..) |param, i| {
        if (i > 0) out = out ++ ", ";
        // A generic parameter has no type to name: the control takes whatever
        // the caller's enum is, and says so.
        out = out ++ (if (param.type) |T| shortName(T) else "anytype");
    }
    return out ++ ") " ++ (if (info.return_type) |R| shortName(R) else "anytype");
}

/// "widget.Context" rather than "eui.widget.Context": the module path is the
/// same for every row and says nothing.
fn shortName(comptime T: type) []const u8 {
    @setEvalBranchQuota(100_000);
    const full = @typeName(T);
    const last = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    const before = std.mem.lastIndexOfScalar(u8, full[0..last], '.') orelse return full;
    return full[before + 1 ..];
}

/// The parts a window is laid out with, and the numbers each one owns.
fn modules(gpa: std.mem.Allocator, w: *std.ArrayList(u8)) !void {
    try w.appendSlice(gpa,
        \\## Parts
        \\
        \\Geometry lives apart from painting, so where a thing goes can be
        \\tested without drawing it.
        \\
        \\
    );

    const parts = .{
        .{ "rail", eui.rail, "The column of sections down the side of a window." },
        .{ "footer", eui.footer, "The strip along its bottom: a message and the buttons." },
        .{ "row", eui.row, "Fixed cells packed against one end, dropping what will not fit." },
        .{ "slider", eui.slider, "A value you drag, and where its parts land." },
        .{ "meter", eui.meter, "A level you read, with a peak that trails it." },
        .{ "popover", eui.popover, "A panel beside the thing that opened it, kept on screen." },
        .{ "region", eui.region, "What is left of a rectangle once others cover it." },
        .{ "scroll", eui.scroll, "How far down a list is, and the bar that says so." },
        .{ "table", eui.table, "Columns, and which one a press landed in." },
    };

    inline for (parts) |part| {
        try w.print(gpa, "### `eui.{s}`\n\n{s}\n\n", .{ part[0], part[2] });

        var listed = false;
        inline for (@typeInfo(part[1]).@"struct".decls) |decl| {
            const field = @field(part[1], decl.name);
            const kind = @typeInfo(@TypeOf(field));
            if (kind == .@"fn") {
                if (!listed) {
                    try w.appendSlice(gpa, "| call | signature |\n|---|---|\n");
                    listed = true;
                }
                try w.print(gpa, "| `{s}` | `{s}` |\n", .{ decl.name, comptime signature(@TypeOf(field)) });
            }
        }
        if (listed) try w.appendSlice(gpa, "\n");

        var numbered = false;
        inline for (@typeInfo(part[1]).@"struct".decls) |decl| {
            const field = @field(part[1], decl.name);
            if (@TypeOf(field) == i32 or @TypeOf(field) == u8 or @TypeOf(field) == usize) {
                if (!numbered) {
                    try w.appendSlice(gpa, "Numbers it owns:\n\n");
                    numbered = true;
                }
                try w.print(gpa, "- `{s}` = {d}\n", .{ decl.name, field });
            }
        }
        if (numbered) try w.appendSlice(gpa, "\n");
    }
}

/// The pictures, drawn. A name alone does not tell anybody what they get.
fn iconTable(gpa: std.mem.Allocator, w: *std.ArrayList(u8)) !void {
    try w.appendSlice(gpa,
        \\## Pictures
        \\
        \\Twelve by twelve, one bit deep, drawn through the same blitter as a
        \\letter and in the ink the caller passes. Drawn here as they are drawn
        \\on the screen.
        \\
        \\```
        \\
    );

    const icons = eui.icon;
    inline for (std.enums.values(icons.Icon)) |which| {
        try w.print(gpa, "{s}\n", .{@tagName(which)});
        const bits = icons.rows(which);
        for (0..icons.HEIGHT) |y| {
            try w.appendSlice(gpa, "  ");
            for (0..icons.WIDTH) |x| {
                const byte = bits[y * icons.ROW_BYTES + x / 8];
                const lit = byte & (@as(u8, 0x80) >> @intCast(x % 8)) != 0;
                try w.appendSlice(gpa, if (lit) "##" else "  ");
            }
            try w.appendSlice(gpa, "\n");
        }
        try w.appendSlice(gpa, "\n");
    }
    try w.appendSlice(gpa, "```\n\n");
}

/// Every colour and metric, in every theme.
fn themeTable(gpa: std.mem.Allocator, w: *std.ArrayList(u8)) !void {
    const theme = eui.theme;

    try w.appendSlice(gpa,
        \\## Themes
        \\
        \\One value holds every colour and every measurement, so a control that
        \\reads the theme is a control that follows the interface's size without
        \\knowing that it does. Metrics are given at a hundred per cent; the
        \\interface scale multiplies them.
        \\
    );

    // The header names the themes that exist rather than a list of them.
    try w.appendSlice(gpa, "| element |");
    inline for (theme.all) |t| try w.print(gpa, " {s} |", .{t.name});
    try w.appendSlice(gpa, "\n|---|");
    inline for (theme.all) |_| try w.appendSlice(gpa, "---|");
    try w.appendSlice(gpa, "\n");

    inline for (@typeInfo(theme.Theme).@"struct".fields) |field| {
        if (field.type == eui.Color) {
            try w.print(gpa, "| `{s}` |", .{field.name});
            inline for (theme.all) |t| {
                try w.print(gpa, " `#{X:0>6}` |", .{@field(t, field.name)});
            }
            try w.appendSlice(gpa, "\n");
        }
    }
    try w.appendSlice(gpa, "\n| metric | value |\n|---|---|\n");
    inline for (@typeInfo(theme.Theme).@"struct".fields) |field| {
        if (field.type == i32) {
            try w.print(gpa, "| `{s}` | {d} |\n", .{ field.name, @field(theme.all[0], field.name) });
        }
    }
    try w.appendSlice(gpa, "\n");
}

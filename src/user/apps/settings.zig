//! Settings: the desktop's own control panel.
//!
//! Edits what `/etc/eeewm.cfg` holds and writes it back, so a change survives
//! a restart rather than lasting until the manager exits. The first real
//! application, and deliberately so: it needs nothing that does not already
//! work, and it exercises the toolkit, the window protocol and the filesystem
//! write path together under something a person would actually use.
//!
//! Applies changes live where it can. A theme picked from a list should be
//! visible before the file is saved, because the point of choosing one is
//! seeing it.

const std = @import("std");
const eui = @import("eui");
const proto = @import("proto");
const sys = @import("sys");
const out = @import("ulib").out;

const wm = proto.wm;
const sound = proto.audio;
const rgb = @import("lib").rgb;
const hostname = @import("lib").hostname;
const net = proto.net;
const str = @import("lib").str;
const info = @import("ulib").info;
const bindings = @import("ulib").bindings;
const keymaps = @import("keymaps");
const palette = @import("lib").palette;
const platform = proto.platform;
const theme = eui.theme;

const store = proto.settings;

/// The frame's context, which is where every control call goes.
const ctx = &proto.app.ctx;

/// What the controls edit. The schema, not a copy of it: `cfg` and this app
/// change the same settings and a second field list is a second thing to keep
/// in step.
var current: store.Wm = .{};
/// The keyboard's own domain, which the bar and this app both write.
var input: store.Input = .{};
var saved = true;

/// What the machine calls itself, asked once. The rail says it under the
/// sections and the About pane says it at the top: one fact, one reading of
/// it, and no chance of the two disagreeing after a version bump.
var version_buf: [64]u8 = @splat(0);
var version: []const u8 = "";

export fn _start(frame: [*]const u32) callconv(.c) noreturn {
    // A section named on the command line opens there. One entry in the
    // launcher can then be about this computer rather than about settings.
    const argc: usize = frame[0];
    if (argc >= 2) {
        const wanted = str.span(@as([*:0]const u8, @ptrFromInt(frame[2])));
        if (Section.parse(wanted)) |which| section = which;
    }

    load();
    version = info.ask("kernel", &version_buf);
    readMachineName();

    proto.app.run("settings", "Settings", 260, 200, .{ .draw = draw });
}

// ---------------------------------------------------------------------------
// The store
// ---------------------------------------------------------------------------

fn load() void {
    current = store.load("wm");
    input = store.load("input");
    readVolume();
}

/// What the sound service says the default output is at.
///
/// Kept here rather than asked for on every pass: a paint happens whenever
/// the pointer moves, and a call into another process per motion is a cost
/// nothing about the picture justifies.
var volume: sound.VolumeInfo = .{ .percent = 0, .muted = 0 };
var has_sound = false;

fn readVolume() void {
    if (sound.master()) |level| {
        volume = level;
        has_sound = true;
    } else {
        has_sound = false;
    }
}

fn setVolume(percent: u8, muted: bool) void {
    if (!has_sound) return;
    if (!sound.setMaster(percent, muted)) return;
    readVolume();
    ctx.damage();
}

/// Hand the changes to `cfgd`, which is the only thing that writes them.
///
/// Only what differs is sent, and the service tells every watcher, so the
/// desktop finds out the same way a shell would.
fn save() void {
    store.save("wm", current) catch return;
    saved = true;
}

// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------

/// A heading over a row of controls, and where the row starts.
fn group(y: *i32, area: eui.Rect, title: []const u8) i32 {
    ctx.labelDim(.{ .x = area.x, .y = y.*, .w = area.w, .h = 16 }, title);
    y.* += 18;
    return y.*;
}

/// A setting just changed: mark the file stale and repaint, since the group
/// that changed has a sibling to un-select and the status line to update.
fn change() void {
    saved = false;
    ctx.damage();
}

/// Three channels, a reading of what they make, and a square of it.
///
/// Returns where the next thing goes. The colour applies as it is dragged,
/// because a wallpaper picker that showed the answer only after saving would
/// be a picker nobody could use.
fn wallpaper(area: eui.Rect) i32 {
    const t = theme.current();
    const row = t.control_height;
    const pad = t.padding;

    const swatch = eui.Rect{ .x = area.x, .y = area.y, .w = 72, .h = area.h };
    const chosen = current.wallpaper.orElse(t.desktop);
    ctx.surface.fill(swatch, chosen);
    ctx.surface.frame(swatch, t.border);

    var text: [8]u8 = undefined;
    var spelled = str.Builder{ .buf = &text };
    current.wallpaper.spell(&spelled);
    ctx.label(
        .{ .x = swatch.x, .y = swatch.bottom() + 2, .w = swatch.w, .h = 16 },
        if (current.wallpaper.set) spelled.done() else "theme",
    );

    const left = swatch.right() + pad * 2;
    const width = area.right() - left;

    // Read out of the colour rather than kept beside it, so what the sliders
    // show and what the wall is cannot come apart.
    var channels = [_]u8{ current.wallpaper.r, current.wallpaper.g, current.wallpaper.b };
    if (!current.wallpaper.set) {
        channels = .{
            @truncate(chosen >> 16),
            @truncate(chosen >> 8),
            @truncate(chosen),
        };
    }

    // A label, the slider, and what it reads. The number is there because
    // a colour is often copied from somewhere rather than found by eye.
    const label_w: i32 = 14;
    const value_w: i32 = 34;
    const names = [_][]const u8{ "R", "G", "B" };
    // Each channel in its own, muted to the palette rather than the pure
    // primary: three identical bars are three bars nobody can tell apart at
    // a glance, and a saturated red beside this accent is a different
    // interface.
    const tints = [_]u32{ 0xC04A3A, 0x3E9450, 0x3A6FD0 };

    var moved = false;
    for (&channels, 0..) |*channel, i| {
        const top = area.y + @as(i32, @intCast(i)) * (row + pad);
        ctx.label(.{ .x = left, .y = top + 4, .w = label_w, .h = 16 }, names[i]);

        const at = eui.Rect{
            .x = left + label_w,
            .y = top,
            .w = width - label_w - value_w - pad,
            .h = row,
        };

        var reading: [4]u8 = undefined;
        const digits = str.decimal(&reading, channel.*);
        ctx.label(
            .{ .x = at.right() + pad, .y = top + 4, .w = value_w, .h = 16 },
            reading[0..digits],
        );

        const wanted = ctx.slider(at, .{ .min = 0, .max = 255 }, channel.*, .{ .fill = tints[i] });
        if (wanted != channel.*) {
            channel.* = @intCast(wanted);
            moved = true;
        }
    }

    if (moved) {
        current.wallpaper = rgb.Colour.of(channels[0], channels[1], channels[2]);
        change();
    }

    return area.bottom() + 18;
}

/// Which part of the machine is being changed.
///
/// Listed as they gain something to hold: a heading over an empty pane is a
/// promise the machine has not kept, so a section appears here when there is
/// a setting under it and not before.
const Section = enum {
    display,
    input,
    audio,
    power,
    help,
    about,

    fn parse(name: []const u8) ?Section {
        for (std.enums.values(Section)) |which| {
            if (str.eql(which.title(), name) or str.eql(@tagName(which), name)) return which;
        }
        return null;
    }

    fn title(self: Section) []const u8 {
        return switch (self) {
            .display => "Display",
            .input => "Input",
            .audio => "Audio",
            .power => "Power",
            .help => "Help",
            .about => "About",
        };
    }

    fn icon(self: Section) eui.icon.Icon {
        return switch (self) {
            .display => .display,
            .input => .keyboard,
            .audio => .speaker,
            .power => .battery,
            .help => .help,
            .about => .about,
        };
    }
};

var section: Section = .display;

fn draw() void {
    const t = theme.current();
    const surface = ctx.surface;
    const area = eui.Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };

    const body = eui.footer.above(area);
    const rail = eui.rail.column(body, 0);
    const beside = eui.rail.beside(body, rail);
    const pane = eui.Rect{
        .x = beside.x + t.menu_padding,
        .y = beside.y + t.menu_padding,
        .w = beside.w - t.menu_padding * 2,
        .h = beside.h - t.menu_padding,
    };

    drawRail(rail);

    switch (section) {
        .display => drawDisplay(pane),
        .input => drawInput(pane),
        .audio => drawAudio(pane),
        .power => drawPower(pane),
        .help => drawHelp(pane),
        .about => drawAbout(pane),
    }

    drawFooter(area);
}

fn drawRail(rail: eui.Rect) void {
    var rows: [std.enums.values(Section).len]eui.rail.Item = undefined;
    for (std.enums.values(Section), 0..) |which, i| {
        rows[i] = .{ .label = which.title(), .icon = which.icon() };
    }

    const chosen = ctx.rail(rail, &rows, @intFromEnum(section), version);
    if (chosen != @intFromEnum(section)) {
        section = @enumFromInt(chosen);
        // A different pane entirely, so the whole window is repainted rather
        // than the row that was pressed.
        ctx.damage();
    }
}

fn drawDisplay(pane: eui.Rect) void {
    const t = theme.current();
    const row = t.control_height;
    var y = pane.y;
    const full = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = row };

    y = group(&y, full, "Theme");
    // Drawn as what each one looks like: the desktop's ground, the bar's
    // strip and a block of its highlight. Applied on the spot rather than on
    // save, because seeing it is the point of choosing it.
    var looks: [8]eui.widget.Context.Sample = undefined;
    const shown = @min(theme.all.len, looks.len);
    for (theme.all[0..shown], 0..) |candidate, i| {
        looks[i] = .{
            .label = candidate.name,
            .ground = candidate.desktop,
            .strip = candidate.bar,
            // The highlight in use, not the theme's own: the tile is a
            // picture of what choosing it would give you, and the highlight
            // is chosen separately.
            .mark = current.accent.rgb(),
        };
    }

    const picked = ctx.samples(
        .{ .x = pane.x, .y = y, .w = full.w, .h = eui.widget.Context.sampleHeight() },
        looks[0..shown],
        @intFromEnum(current.theme),
    );
    if (picked != @intFromEnum(current.theme)) {
        current.theme = @enumFromInt(picked);
        if (theme.byName(@tagName(current.theme))) |chosen| theme.use(chosen);
        theme.setAccent(current.accent.rgb());
        change();
    }
    y += eui.widget.Context.sampleHeight() + t.padding;

    // The highlight, as colours rather than as words: what somebody is
    // choosing is what it looks like.
    y = group(&y, full, "Highlight");
    y = pickColour(
        .{ .x = pane.x, .y = y, .w = full.w, .h = theme.enlarged(18) },
        palette.Accent,
        &current.accent,
        applyAccent,
    );
    y += t.padding;

    y = group(&y, full, "Pointer");
    y = pickColour(
        .{ .x = pane.x, .y = y, .w = full.w, .h = theme.enlarged(18) },
        palette.Pointer,
        &current.pointer,
        null,
    );
    y += t.padding;

    // Applied as it is dragged, and this window is drawn with it: what it
    // feels like is the only question, and the answer is on the screen.
    y = group(&y, full, "Scale");
    var reading: [5]u8 = @splat(0);
    const spelled = str.decimal(&reading, current.scale);
    ctx.label(
        .{ .x = pane.right() - 40, .y = y + 4, .w = 40, .h = 16 },
        reading[0..spelled],
    );
    const wanted_scale = ctx.slider(
        .{ .x = pane.x, .y = y, .w = full.w - 46, .h = row },
        .{ .min = theme.SCALE_MIN, .max = theme.SCALE_MAX },
        current.scale,
        .{},
    );
    if (wanted_scale != current.scale) {
        current.scale = @intCast(wanted_scale);
        theme.setScale(current.scale);
        change();
    }
    y += row + t.padding;

    y = group(&y, full, "Bar");
    const bar = ctx.choice(.{ .x = pane.x, .y = y, .w = full.w, .h = row }, current.bar);
    if (bar != current.bar) {
        current.bar = bar;
        change();
    }
    y += row + t.padding;

    // The wall behind everything. Three channels rather than a list of
    // colours: the panel is one flat colour and which one is a matter of
    // taste that a list of six would only get near.
    y = group(&y, full, "Wallpaper");
    _ = wallpaper(.{ .x = pane.x, .y = y, .w = full.w, .h = row * 3 + t.padding * 2 });
}

fn drawAudio(pane: eui.Rect) void {
    const t = theme.current();
    const row = t.control_height;
    var y = pane.y;
    const full = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = row };

    y = group(&y, full, "Volume");
    if (!has_sound) {
        ctx.label(.{ .x = pane.x, .y = y, .w = full.w, .h = 16 }, "Nothing is serving sound.");
        return;
    }

    const level = ctx.slider(
        .{ .x = pane.x, .y = y, .w = full.w - 84, .h = row },
        .{ .min = 0, .max = 100 },
        volume.percent,
        .{},
    );
    if (ctx.toggle(.{ .x = pane.x + full.w - 78, .y = y, .w = 78, .h = row }, "Mute", volume.muted != 0)) {
        setVolume(volume.percent, volume.muted == 0);
    } else if (level != volume.percent) {
        setVolume(@intCast(level), volume.muted != 0);
    }
}

/// What this computer is, as the kernel describes it.
///
/// The same questions `eeefetch` asks, because there is one answer to each
/// and two lists of them would disagree the first time one gained a line.
/// Anything the kernel cannot answer is left out rather than shown empty.
/// What the keyboard is.
///
/// One setting, and the one the bar used to carry: the layout moved here when
/// the two letters in the status area stopped earning their width. The chord
/// that cycles it still works, and this and the chord write the same key, so
/// whichever one is used the other agrees.
fn drawInput(pane: eui.Rect) void {
    const t = theme.current();
    const row = t.control_height;
    var y = pane.y;
    const full = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = row };

    y = group(&y, full, "Keyboard layout");
    const wanted = ctx.choiceOf(.{ .x = pane.x, .y = y, .w = full.w, .h = row }, input.keymap, &keymaps.names);
    if (wanted != input.keymap) {
        input.keymap = wanted;
        store.set("input.keymap", @tagName(wanted)) catch {};
        ctx.damage();
    }
    y += row + t.padding;

    ctx.labelDim(
        .{ .x = pane.x, .y = y, .w = full.w, .h = 16 },
        "Applies at once, everywhere. Super+Space cycles it too.",
    );
}

/// What the battery is doing, and what the panel is set to.
///
/// The same two things the bar's power menu carries, because they are the
/// same two things: this is where they are read at length, and the menu is
/// where they are changed in passing.
fn drawPower(pane: eui.Rect) void {
    const t = theme.current();
    const row = t.control_height;
    var y = pane.y;
    const full = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = row };

    y = group(&y, full, "Battery");
    if (platform.battery()) |cell| {
        const bar_w = @divTrunc(pane.w - factColumn(pane), 3);
        const percent = platform.charge(cell) orelse 0;

        var reading: [24]u8 = @splat(0);
        var line = str.Builder{ .buf = &reading };
        line.number(percent);
        line.text("%, ");
        line.text(cell.stateLabel());

        ctx.progress(.{ .x = pane.x, .y = y + 6, .w = bar_w, .h = 10 }, @intCast(@min(percent, 100)));
        ctx.label(.{ .x = pane.x + bar_w + t.gap, .y = y + 4, .w = pane.w - bar_w, .h = row }, line.done());
        y += row;

        if (cell.runtimeLeft()) |left| {
            var buf: [24]u8 = @splat(0);
            var spelled = str.Builder{ .buf = &buf };
            spelled.duration(@as(usize, left.hours) * 3600 + @as(usize, left.minutes) * 60);
            y = drawFact(pane, y, "Time left", spelled.done());
        }
        if (cell.health()) |health| {
            var buf: [8]u8 = @splat(0);
            var spelled = str.Builder{ .buf = &buf };
            spelled.number(@min(health, 100));
            spelled.byte('%');
            y = drawFact(pane, y, "Health", spelled.done());
        }
    } else {
        ctx.labelDim(.{ .x = pane.x, .y = y, .w = full.w, .h = 16 }, "This machine has no battery.");
        y += row;
    }

    y += t.padding;
    y = group(&y, full, "Backlight");

    if (platform.backlight()) |panel_light| {
        var reading: [16]u8 = @splat(0);
        var line = str.Builder{ .buf = &reading };
        line.number(panel_light.level);
        line.text(" of ");
        line.number(panel_light.max);

        // Levels rather than a percentage: the steps belong to the panel, and
        // a percentage rounded onto them makes some of them unreachable.
        const wanted = ctx.slider(
            .{ .x = pane.x, .y = y, .w = full.w - theme.enlarged(84), .h = row },
            .{ .min = 1, .max = @intCast(panel_light.max) },
            @intCast(panel_light.level),
            .{},
        );
        ctx.label(
            .{ .x = pane.right() - theme.enlarged(78), .y = y + 4, .w = theme.enlarged(78), .h = row },
            line.done(),
        );
        if (wanted != @as(i32, @intCast(panel_light.level))) _ = platform.setBacklight(@intCast(wanted));
    } else {
        ctx.labelDim(
            .{ .x = pane.x, .y = y, .w = full.w, .h = 16 },
            "This machine offers no way to set the backlight.",
        );
    }
}


/// The keys that move windows around, from the table the manager dispatches
/// from: a list here that the manager did not read would be a list that says
/// what the machine used to do.
fn drawHelp(pane: eui.Rect) void {
    const t = theme.current();
    var y = pane.y;
    const full = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height };

    y = group(&y, full, "Desktops and windows");

    const chord_w = @max(theme.enlarged(120), @divTrunc(pane.w, 3));
    for (bindings.all) |binding| {
        if (y + t.menu_row_height > pane.bottom()) break;
        ctx.label(.{ .x = pane.x, .y = y, .w = chord_w, .h = t.control_height }, binding.chord);
        ctx.labelDim(
            .{ .x = pane.x + chord_w, .y = y, .w = pane.w - chord_w, .h = t.control_height },
            binding.says,
        );
        y += theme.enlarged(16);
    }

    y += t.padding;
    for (bindings.numbers) |row| {
        if (y + t.menu_row_height > pane.bottom()) break;
        ctx.label(.{ .x = pane.x, .y = y, .w = chord_w, .h = t.control_height }, row.chord);
        ctx.labelDim(
            .{ .x = pane.x + chord_w, .y = y, .w = pane.w - chord_w, .h = t.control_height },
            row.says,
        );
        y += theme.enlarged(16);
    }
}

/// What this computer is, and nothing about what it is doing. How much
/// memory is fitted belongs here; how much of it is in use belongs in the
/// monitor, and a page that answered both would be a monitor with a
/// letterhead.
///
/// Falls through to a second key when the first is unknown: a machine whose
/// firmware never described its memory can still say how much of it the
/// kernel found.
const Fact = struct { label: []const u8, key: []const u8, then: []const u8 = "" };

/// How large the monogram is drawn, in multiples of the interface face.
const MARK_SCALE: i32 = 3;

/// What it is running.
const software = [_]Fact{
    .{ .label = "System", .key = "kernel" },
    .{ .label = "Architecture", .key = "arch" },
    .{ .label = "Booted with", .key = "cmdline" },
};

/// What it is.
const hardware = [_]Fact{
    .{ .label = "Processor", .key = "cpu" },
    .{ .label = "Memory", .key = "mem.hardware", .then = "mem.total" },
    .{ .label = "Graphics", .key = "display.adapter" },
    .{ .label = "Screen", .key = "display.panel", .then = "display" },
    .{ .label = "Storage", .key = "storage" },
    .{ .label = "Firmware", .key = "bios" },
};

fn drawAbout(pane: eui.Rect) void {
    const t = theme.current();
    var y = drawIdentity(pane);

    y = group(&y, pane, "Software");
    y = drawFacts(pane, y, &software);
    y += t.padding;

    y = group(&y, pane, "Hardware");
    y = drawFacts(pane, y, &hardware);
}

fn drawFacts(pane: eui.Rect, from: i32, facts: []const Fact) i32 {
    var y = from;
    for (facts) |fact| {
        var buf: [128]u8 = undefined;
        var value = info.ask(fact.key, &buf);
        if (value.len == 0 and fact.then.len > 0) value = describe(fact.then, &buf);
        if (value.len == 0) continue;
        y = drawFact(pane, y, fact.label, value);
    }
    return y;
}

/// A fallback key's answer, in the words the row wants. `mem.total` is a
/// count of bytes, which is a number for a program rather than an answer for
/// a person.
fn describe(key: []const u8, buf: []u8) []const u8 {
    if (str.eql(key, "mem.total")) {
        const bytes = info.askNumber("mem.total");
        if (bytes == 0) return "";
        var line = str.Builder{ .buf = buf };
        line.quantity(bytes / (1024 * 1024), "MiB");
        return line.done();
    }
    return info.ask(key, buf);
}

/// The head of the page: what this machine is called, what it is, and what it
/// is running. Three lines and a mark, because the question "about this
/// computer" is answered by four things and everything else is detail.
fn drawIdentity(pane: eui.Rect) i32 {
    const t = theme.current();
    const mark_size = eui.Surface.iconLargeSize(MARK_SCALE) + t.menu_padding;
    const mark = eui.Rect{ .x = pane.x, .y = pane.y, .w = mark_size, .h = mark_size };

    if (ctx.damaged) {
        ctx.surface.fill(mark, t.accent);
        const size = eui.Surface.iconLargeSize(MARK_SCALE);
        ctx.surface.iconLarge(
            mark.x + @divTrunc(mark.w - size, 2),
            mark.y + @divTrunc(mark.h - size, 2),
            .logo,
            t.accent_text,
            MARK_SCALE,
        );
    }

    const left = mark.right() + t.menu_padding;
    const wide = pane.right() - left;
    var y = pane.y;

    if (ctx.damaged) {
        ctx.surface.textLarge(left, y, machine(), t.text, 2);
    }
    y += eui.Surface.textLargeHeight(2) + t.padding;

    var buf: [128]u8 = undefined;
    const board = info.ask("board", &buf);
    ctx.label(.{ .x = left, .y = y, .w = wide, .h = t.control_height }, if (board.len > 0) board else "unknown board");

    // A rule under the head, which is what separates what the machine is from
    // what is in it.
    const below = @max(mark.bottom(), y + eui.Surface.textHeight()) + t.menu_padding;
    if (ctx.damaged) {
        ctx.surface.fill(.{ .x = pane.x, .y = below, .w = pane.w, .h = 1 }, t.line);
    }
    return below + t.menu_padding;
}

/// A row of swatches for a named-colour setting, whichever list it comes
/// from. Returns where the next thing goes.
///
/// Generic over the enum because the two lists are two lists: writing the
/// same loop twice is how one of them ends up drawn differently.
fn pickColour(
    area: eui.Rect,
    comptime Named: type,
    value: *Named,
    comptime live: ?fn (Named) void,
) i32 {
    const values = std.enums.values(Named);

    var colours: [16]eui.Color = undefined;
    const count = @min(values.len, colours.len);
    for (values[0..count], 0..) |named, i| colours[i] = named.rgb();

    const chosen = ctx.swatches(area, colours[0..count], @intFromEnum(value.*));
    if (chosen != @intFromEnum(value.*)) {
        value.* = @enumFromInt(chosen);
        if (live) |apply| apply(value.*);
        change();
    }
    return area.bottom() + theme.current().padding;
}

/// The highlight applies while the window is open, because the window is
/// drawn in it: choosing a colour you cannot see until you save is choosing
/// blind.
fn applyAccent(accent: palette.Accent) void {
    theme.setAccent(accent.rgb());
    ctx.damage();
}

/// The label column: a quarter of the pane, so the values line up down the
/// page whatever they say.
fn factColumn(pane: eui.Rect) i32 {
    return @max(theme.enlarged(80), @divTrunc(pane.w, 5));
}

fn drawFact(pane: eui.Rect, y: i32, label: []const u8, value: []const u8) i32 {
    const t = theme.current();
    const label_w = factColumn(pane);
    ctx.labelDim(.{ .x = pane.x, .y = y + 2, .w = label_w, .h = t.control_height }, label);
    ctx.label(.{ .x = pane.x + label_w, .y = y + 2, .w = pane.w - label_w, .h = t.control_height }, value);
    return y + t.menu_row_height;
}

/// What this machine answers to. The configured name if there is one, and
/// otherwise the one derived from its own address, which is the same rule
/// the network service applies: two answers to "what is this machine called"
/// would be one too many.
var machine_buf: [hostname.MAX]u8 = @splat(0);
var machine_len: usize = 0;

fn machine() []const u8 {
    return machine_buf[0..machine_len];
}

fn readMachineName() void {
    const configured = store.netMachine(store.load("net")).hostname;
    var address: [6]u8 = @splat(0);
    if (net.interfaceAt(0)) |iface| address = iface.mac;

    const name = hostname.Hostname.resolve(configured, address);
    const text = name.slice();
    @memcpy(machine_buf[0..text.len], text);
    machine_len = text.len;
}

fn drawFooter(area: eui.Rect) void {
    // Everything here applies as soon as it is saved, the bar's position
    // included. Saying so is worth a line: a person who has just moved the
    // bar wants to know whether to expect it to move.
    const pressed = ctx.footer(
        area,
        if (saved) "Saved settings apply at once." else "Unsaved changes.",
        &.{ "Save", "Close" },
        0,
    );

    if (pressed) |which| switch (which) {
        0 => {
            save();
            ctx.damage();
        },
        else => sys.exit(0),
    };

}

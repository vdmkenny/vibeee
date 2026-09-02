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
const env = @import("ulib").env;
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
const Section = proto.panes.Section;
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
/// What the machine does when it is left alone, and when the pack runs out.
var power: store.Power = .{};
var saved = true;

/// What the machine calls itself, asked once. The rail says it under the
/// sections and the About pane says it at the top: one fact, one reading of
/// it, and no chance of the two disagreeing after a version bump.
var version_buf: [64]u8 = @splat(0);
var version: []const u8 = "";

export fn _start(frame: [*]const u32) callconv(.c) noreturn {
    // A section named on the command line opens there. One entry in the
    // launcher can then be about this computer rather than about settings.
    if (env.argument(frame)) |wanted| {
        if (Section.parse(wanted)) |which| section = which;
    }

    load();
    version = info.ask("kernel", &version_buf);
    readMachineName();
    readPlatform();

    proto.app.run("settings", "Settings", 260, 200, .{
        .draw = draw,
        .tick = tick,
        .tick_us = tickPeriod(),
    });
}

// ---------------------------------------------------------------------------
// The store
// ---------------------------------------------------------------------------

fn load() void {
    current = store.load("wm");
    input = store.load("input");
    power = store.load("power");
    readVolume();
}

/// How often the meters are read while they are on show. Off that pane the
/// frame's default one-second wait comes back and nothing is asked at all.
const METER_TICK_US: usize = 150_000;

/// How often a pane reads the platform service. The firmware answers these
/// by talking to the embedded controller, which is slow, and nothing they
/// show changes faster than a person can notice.
const PLATFORM_TICK_US: usize = 2_000_000;

/// What the meters showed last, with peaks that fall rather than vanish: a
/// peak that mattered for one read is gone before an eye lands on it.
var meter_left: u8 = 0;
var meter_right: u8 = 0;
var meter_capture: u8 = 0;
var meter_playing = false;
var peak_left: u8 = 0;
var peak_right: u8 = 0;

/// The wait timed out, which is when what ages is read again: the pane on
/// screen decides what that is, and a pane showing nothing that ages reads
/// nothing at all.
fn tick() bool {
    switch (section) {
        .power, .display => {
            readPlatform();
            return true;
        },
        .audio => {},
        else => return false,
    }
    if (!has_sound) return false;

    const fresh = sound.levels() orelse return false;
    meter_left = fresh.left;
    meter_right = fresh.right;
    meter_capture = fresh.capture;
    meter_playing = fresh.playing != 0;

    const audio_lib = @import("lib").audio;
    peak_left = @max(fresh.left, audio_lib.falling(peak_left, fresh.left, 3));
    peak_right = @max(fresh.right, audio_lib.falling(peak_right, fresh.right, 3));
    return true;
}

/// How often the pane on screen has anything new to say. Meters move with
/// the sound and wake the window often; a battery and a panel move slowly
/// and are asked of a service that answers through the firmware, so they
/// are asked seldom.
fn syncTick() void {
    proto.app.retick(tickPeriod());
    readPlatform();
}

fn tickPeriod() usize {
    return switch (section) {
        .audio => METER_TICK_US,
        .power, .display => PLATFORM_TICK_US,
        else => 1_000_000,
    };
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

/// What the platform service says about the machine, for the same reason
/// the volume above is kept: every one of these is a call into another
/// process, a paint happens whenever the pointer moves, and the firmware
/// answers some of them by talking to the embedded controller, which is
/// slow enough to be felt as a window that lags the hand moving over it.
/// Read when the pane is opened and while it is the pane on screen.
var cell: ?proto.platform.Battery = null;
var lamp: ?proto.platform.Backlight = null;
var zones: [proto.platform.Thermal.MAX_ZONES]?proto.platform.Thermal = @splat(null);

fn readPlatform() void {
    switch (section) {
        .power => {
            cell = platform.battery();
            for (&zones, 0..) |*slot, index| {
                slot.* = platform.thermal(@intCast(index));
            }
        },
        .display => lamp = platform.backlight(),
        .about => readFacts(),
        else => {},
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
    store.save("power", power) catch return;
    saved = true;
}

// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------

/// A hairline across the pane, and where what follows it starts.
///
/// What separates one subject from the next. The design draws the pane as a
/// grid with edges; this is that edge, drawn where a section ends rather than
/// around a cell nothing else knows the shape of.
fn rule(pane: eui.Rect, y: i32) i32 {
    const t = theme.current();
    ctx.surface.fill(.{ .x = pane.x, .y = y, .w = pane.w, .h = 1 }, t.line);
    ctx.addDamage(.{ .x = pane.x, .y = y, .w = pane.w, .h = 1 });
    return y + t.padding * 2;
}

/// The same, upright: what divides two subjects standing side by side.
fn ruleDown(x: i32, from: i32, to: i32) void {
    const t = theme.current();
    ctx.surface.fill(.{ .x = x, .y = from, .w = 1, .h = to - from }, t.line);
    ctx.addDamage(.{ .x = x, .y = from, .w = 1, .h = to - from });
}

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

    // Whatever a section holds, it scrolls when it does not fit: a larger
    // interface, a longer list of devices or a translation with longer words
    // are all things that make a pane taller than the window it is in, and
    // none of them should put a row out of reach.
    const scrolled = &pane_scroll[@intFromEnum(section)];
    const view = eui.scrollpane.begin(ctx, pane, scrolled);
    const inner = eui.Rect{
        .x = view.area.x,
        .y = view.top(),
        .w = view.area.w,
        .h = pane.h + view.offset,
    };

    help_view = view;
    const drawn = switch (section) {
        .display => drawDisplay(inner),
        .input => drawInput(inner),
        .audio => drawAudio(inner),
        .power => drawPower(inner),
        .help => drawHelp(inner),
        .about => drawAbout(inner),
    };
    eui.scrollpane.end(ctx, scrolled, view, drawn - view.top());

    drawFooter(area);
}

/// Where each section has been scrolled to. One each, because a section
/// scrolled halfway and then left should be where it was when it comes back,
/// and because a short pane must not inherit a tall one's offset.
var pane_scroll: [std.enums.values(Section).len]eui.scrollpane.State = @splat(.{});

fn drawRail(rail: eui.Rect) void {
    var rows: [std.enums.values(Section).len]eui.rail.Item = undefined;
    for (std.enums.values(Section), 0..) |which, i| {
        rows[i] = .{ .label = which.title(), .icon = which.icon() };
    }

    const chosen = ctx.rail(rail, &rows, @intFromEnum(section), version);
    if (chosen != @intFromEnum(section)) {
        section = @enumFromInt(chosen);
        syncTick();
        // A different pane entirely, so the whole window is repainted rather
        // than the row that was pressed.
        ctx.damage();
    }
}

fn drawDisplay(pane: eui.Rect) i32 {
    const t = theme.current();
    const row = t.control_height;
    var y = pane.y;
    const full = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = row };

    // The two pictures side by side: what it looks like, and where the bar
    // goes. Both are tiles of the same size, and a column of one of them
    // beside four hundred rows of nothing is what the pane would otherwise
    // be.
    const tile_row = eui.widget.Context.sampleHeight();
    const themes_w = ctx.samplesWidth(theme.all.len);

    const theme_area = eui.Rect{ .x = pane.x, .y = y, .w = themes_w, .h = row };
    const bar_x = pane.x + themes_w + t.control_height;
    const bar_area = eui.Rect{ .x = bar_x, .y = y, .w = pane.right() - bar_x, .h = row };

    var bar_y = y;
    _ = group(&bar_y, bar_area, "Bar");
    y = group(&y, theme_area, "Theme");
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
        .{ .x = theme_area.x, .y = y, .w = themes_w, .h = tile_row },
        looks[0..shown],
        @intFromEnum(current.theme),
    );
    if (picked != @intFromEnum(current.theme)) {
        current.theme = @enumFromInt(picked);
        if (theme.byName(@tagName(current.theme))) |chosen| theme.use(chosen);
        theme.setAccent(current.accent.rgb());
        change();
    }

    const tiles_top = theme_area.y;
    y = drawBarChoice(bar_area, bar_y, y + tile_row) + t.padding;
    ruleDown(bar_x - @divTrunc(t.control_height, 2), tiles_top, y);
    y = rule(pane, y);

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

    y = rule(pane, y);

    // Applied as it is dragged, and this window is drawn with it: what it
    // feels like is the only question, and the answer is on the screen.
    y = group(&y, full, "Scale");
    var reading: [8]u8 = @splat(0);
    var spelled = str.Builder{ .buf = &reading };
    spelled.number(current.scale);
    spelled.byte('%');

    const value_w = theme.enlarged(44);
    ctx.label(
        .{ .x = pane.right() - value_w, .y = y + 4, .w = value_w, .h = 16 },
        spelled.done(),
    );
    const wanted_scale = ctx.slider(
        .{ .x = pane.x, .y = y, .w = full.w - value_w - t.gap, .h = row },
        .{ .min = theme.SCALE_MIN, .max = theme.SCALE_MAX },
        current.scale,
        // Notched, because the face is a bitmap: between the notches the
        // metrics stretch and the letters do not.
        .{ .notches = &theme.SCALE_STEPS },
    );
    if (wanted_scale != current.scale) {
        current.scale = @intCast(wanted_scale);
        theme.setScale(current.scale);
        change();
    }
    y += row + t.padding;

    // The wall behind everything. Three channels rather than a list of

    y = rule(pane, y);

    // The wall behind everything. Three channels rather than a list of
    // colours: the panel is one flat colour and which one is a matter of
    // taste that a list of six would only get near.
    y = group(&y, full, "Wallpaper");
    const wall = eui.Rect{ .x = pane.x, .y = y, .w = full.w, .h = row * 3 + t.padding * 2 };
    _ = wallpaper(wall);
    return wall.bottom();
}

/// Where the bar goes, drawn rather than named: the answer is a picture of a
/// screen with a strip along one edge, and two words are two words.
fn drawBarChoice(area: eui.Rect, from: i32, floor: i32) i32 {
    const t = theme.current();
    const at = theme.current();

    // A pale tile with the strip drawn on one edge, and nothing else in it:
    // this tile is about where the bar goes, so a window drawn under it would
    // be the only thing anybody looked at.
    const chosen_edge = @intFromEnum(current.bar);
    const edges = [_]eui.widget.Context.Sample{
        .{
            .label = "top",
            .ground = at.surface_hot,
            .strip = if (chosen_edge == 0) at.accent else at.text_dim,
            .strip_at = .top,
        },
        .{
            .label = "bottom",
            .ground = at.surface_hot,
            .strip = if (chosen_edge == 1) at.accent else at.text_dim,
            .strip_at = .bottom,
        },
    };

    const where = ctx.samples(
        .{ .x = area.x, .y = from, .w = area.w, .h = eui.widget.Context.sampleHeight() },
        &edges,
        @intFromEnum(current.bar),
    );
    if (where != @intFromEnum(current.bar)) {
        current.bar = @enumFromInt(where);
        change();
    }

    const after = from + eui.widget.Context.sampleHeight();
    ctx.labelDim(
        .{ .x = area.x, .y = after + t.padding, .w = area.w, .h = 16 },
        "The bar moves when the desktop next starts.",
    );

    return @max(floor, after + t.padding + t.control_height);
}

fn drawAudio(pane: eui.Rect) i32 {
    const t = theme.current();
    const row = t.control_height;
    var y = pane.y;
    const full = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = row };

    y = group(&y, full, "Volume");
    if (!has_sound) {
        ctx.label(.{ .x = pane.x, .y = y, .w = full.w, .h = 16 }, "Nothing is serving sound.");
        return y;
    }

    const level = ctx.slider(
        .{ .x = pane.x, .y = y, .w = full.w - theme.enlarged(84), .h = row },
        .{ .min = 0, .max = 100 },
        volume.percent,
        .{},
    );
    if (ctx.toggle(.{ .x = pane.right() - theme.enlarged(78), .y = y, .w = theme.enlarged(78), .h = row }, "Mute", volume.muted != 0)) {
        setVolume(volume.percent, volume.muted == 0);
    } else if (level != volume.percent) {
        setVolume(@intCast(level), volume.muted != 0);
    }
    y += row + t.padding;

    // What is actually coming out, channel by channel. The peaks trail and
    // fall, because a meter only read at the moment you look says nothing
    // about the moment you did not.
    y = group(&y, full, "Output");
    y = drawMeterRow(pane, y, "L", meter_left, peak_left);
    y = drawMeterRow(pane, y, "R", meter_right, peak_right);
    if (!meter_playing) {
        ctx.labelDim(.{ .x = pane.x, .y = y, .w = full.w, .h = 16 }, "Nothing is playing.");
    }
    y += theme.enlarged(16) + t.padding;

    y = drawPorts(pane, y, .sink, "Outputs");
    y += t.padding;

    y = group(&y, full, "Input");
    y = drawMeterRow(pane, y, "Mic", meter_capture, meter_capture);
    y += t.padding;
    return drawPorts(pane, y, .source, "Inputs");
}

/// One meter with its letter, at the design's own thinness.
fn drawMeterRow(pane: eui.Rect, y: i32, label: []const u8, level: u8, peak: u8) i32 {
    const t = theme.current();
    const label_w = theme.enlarged(28);
    const bar = eui.Rect{
        .x = pane.x + label_w,
        .y = y + 3,
        .w = pane.w - label_w,
        .h = theme.enlarged(eui.meter.HEIGHT),
    };

    ctx.labelDim(.{ .x = pane.x, .y = y, .w = label_w, .h = t.control_height }, label);
    eui.widget.paintMeter(ctx.surface, bar, level, peak);
    ctx.addDamage(bar);
    return y + theme.enlarged(16);
}

/// The ports of one direction, the default marked, a press making it so.
/// The same rows the bar's sound menu offers, because they are the same
/// question; here they sit still and carry a heading.
fn drawPorts(pane: eui.Rect, from: i32, direction: sound.graph.Direction, title: []const u8) i32 {
    const t = theme.current();
    var y = from;
    const full = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height };

    var store_ports: [sound.graph.MAX_PORTS]sound.PortInfo = undefined;
    const all = sound.ports(&store_ports);

    var shown = false;
    for (all) |*port| {
        if (port.id == sound.graph.NONE or port.direction != direction) continue;
        if (!shown) {
            y = group(&y, full, title);
            shown = true;
        }

        const at = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = t.menu_row_height };
        if (ctx.toggle(at, sound.nameOf(port), port.default != 0) and port.default == 0) {
            if (sound.makeDefault(port.id)) {
                readVolume();
                ctx.damage();
            }
        }
        y += t.menu_row_height + 2;
    }
    return y;
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
fn drawInput(pane: eui.Rect) i32 {
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
    return y + t.control_height;
}

/// The keys that move windows around, from the table the manager dispatches
/// from: a list here that the manager did not read would be a list that says
/// what the machine used to do.
/// Every key the system answers, grouped by what somebody would be trying to
/// do, and scrolled because there are more of them than fit.
///
/// Both lists are read from where the keys actually live: the manager's table
/// and the toolkit's. A page that kept its own copy would describe the keys
/// as they were when somebody last remembered to edit it.
const HelpRow = struct {
    chord: []const u8,
    says: []const u8,
    /// A heading rather than a key, drawn as one and not selectable.
    heading: bool = false,
};

/// How many rows the page can hold. Bounded like everything here: the two
/// tables are known at build time, and this is checked against them.
const HELP_ROWS = bindings.all.len + bindings.numbers.len + eui.text.CHORDS.len +
    @typeInfo(bindings.Group).@"enum".fields.len + 2;

fn helpRows(into: []HelpRow) []HelpRow {
    var n: usize = 0;

    for (std.enums.values(bindings.Group)) |group_of| {
        var any = false;
        for (bindings.all) |binding| {
            if (binding.group != group_of) continue;
            if (!any) {
                into[n] = .{ .chord = group_of.title(), .says = "", .heading = true };
                n += 1;
                any = true;
            }
            into[n] = .{ .chord = binding.chord, .says = binding.says };
            n += 1;
        }
    }

    into[n] = .{ .chord = "Desktops by number", .says = "", .heading = true };
    n += 1;
    for (bindings.numbers) |row| {
        into[n] = .{ .chord = row.chord, .says = row.says };
        n += 1;
    }

    into[n] = .{ .chord = "Text, anywhere", .says = "", .heading = true };
    n += 1;
    for (eui.text.CHORDS) |row| {
        into[n] = .{ .chord = row.chord, .says = row.says };
        n += 1;
    }

    return into[0..n];
}

/// What the help pane can see of itself this pass, so it draws only that.
var help_view: eui.scrollpane.View = undefined;

/// How tall the intro is when it is scrolled past: the rows below it have to
/// start in the same place whether or not it was drawn.
fn paragraphHeight(width: i32) i32 {
    const wrapped = eui.text.count(HELP_INTRO, eui.text.face, width);
    return @intCast(wrapped * @as(usize, eui.text.face.height));
}

/// What somebody opening this page needs to know before the table means
/// anything: which key the desktop belongs to, and that the rest of it works
/// in every window.
const HELP_INTRO =
    "The desktop is driven from the keyboard. Hold Super with the keys " ++
    "below to move between windows and desktops; those chords never reach " ++
    "the program you are working in. The text keys at the end work in " ++
    "every field and every document.";

fn drawHelp(pane: eui.Rect) i32 {
    const t = theme.current();
    const line = theme.enlarged(16);
    const chord_w = @max(theme.enlarged(120), @divTrunc(pane.w, 3));

    var storage: [HELP_ROWS]HelpRow = undefined;
    var y = pane.y;

    if (help_view.shows(y, t.control_height * 3)) {
        y += eui.text.paragraph(
            ctx.surface,
            .{ .x = pane.x, .y = y, .w = pane.w, .h = pane.h },
            HELP_INTRO,
            t.text_dim,
        );
    } else {
        y += paragraphHeight(pane.w);
    }
    y += t.control_height;

    for (helpRows(&storage)) |row| {
        // Only what is on screen. The rest is scrolled past, and drawing it
        // would spend a control's worth of the pass on a row nobody sees.
        if (!help_view.shows(y, line)) {
            y += line;
            continue;
        }

        if (row.heading) {
            ctx.rowText(
                .{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height },
                row.chord,
                t.text_dim,
            );
        } else {
            ctx.rowText(
                .{ .x = pane.x, .y = y, .w = chord_w, .h = t.control_height },
                row.chord,
                t.text,
            );
            ctx.rowText(
                .{ .x = pane.x + chord_w, .y = y, .w = pane.w - chord_w, .h = t.control_height },
                row.says,
                t.text_dim,
            );
        }
        y += line;
    }
    return y;
}

/// What the battery is doing, what it is made of, and what the panel is set
/// to.
///
/// Everything the firmware reports, because this is the page somebody opens
/// when the machine is not lasting: charge without wear, rate or voltage says
/// nothing about why.
fn drawPower(pane: eui.Rect) i32 {
    const t = theme.current();
    var y = pane.y;

    y = drawPack(pane, y);
    y = rule(pane, drawThermal(pane, y));
    y = rule(pane, drawBacklight(pane, y));

    // What the machine does when it is left alone, and what it does when the
    // pack runs out. Both are decisions that have to be made before they
    // happen: a machine at three per cent has no time to ask.
    y += t.padding;
    y = group(&y, .{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, "When it is left alone");

    // Not every interval in both rows: a screen that dims after half an hour
    // has not dimmed, and one that switches off after thirty seconds is a
    // screen nobody can read.
    y = drawIdleRow(pane, y, "Dim after", &power.dim_after, &.{ .never, .@"30s", .@"1m", .@"5m" });
    y = drawIdleRow(pane, y, "Screen off after", &power.blank_after, &.{ .never, .@"5m", .@"10m", .@"30m" });

    y += t.padding;
    var when: [40]u8 = @splat(0);
    var line = str.Builder{ .buf = &when };
    line.text("When the battery reaches ");
    line.number(power.low_at);
    line.byte('%');
    y = group(&y, .{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height }, line.done());

    const picked = ctx.choiceOf(
        .{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height },
        power.low_action,
        &.{ "warn only", "screen off", "shut down" },
    );
    if (picked != power.low_action) {
        power.low_action = picked;
        change();
    }
    return y + t.control_height + t.padding;
}

/// The battery, at the size a number people actually look for deserves.
///
/// Four things: how full, how long that leaves, how big the pack is and how
/// worn. The rest of what the firmware reports is arithmetic on those, and a
/// column of it is a page nobody reads.
fn drawPack(pane: eui.Rect, from: i32) i32 {
    const t = theme.current();
    const y = from;

    const pack = cell orelse {
        ctx.labelDim(.{ .x = pane.x, .y = y, .w = pane.w, .h = 16 }, "This machine has no battery.");
        return y + t.control_height + t.padding;
    };

    const percent = platform.charge(pack) orelse 0;
    const glyph = eui.Rect{
        .x = pane.x,
        .y = y + t.padding,
        .w = theme.enlarged(46),
        .h = theme.enlarged(26),
    };
    paintBatteryGlyph(glyph, @intCast(@min(percent, 100)), pack.state() == .charging);

    var reading: [12]u8 = @splat(0);
    var said = str.Builder{ .buf = &reading };
    said.number(percent);
    said.byte('%');
    const reading_x = glyph.right() + t.menu_padding;
    ctx.surface.textLarge(reading_x, y + t.padding, said.done(), t.text, 2);

    // What it is doing, and how long that leaves, under the number rather
    // than across it: the number is drawn at twice the face's size, so what
    // follows it clears that and not the size of an ordinary line.
    const under = y + t.padding + eui.Surface.textLargeHeight(2);
    var state: [40]u8 = @splat(0);
    var says = str.Builder{ .buf = &state };
    if (pack.runtimeLeft()) |left| {
        says.duration(@as(usize, left.hours) * 3600 + @as(usize, left.minutes) * 60);
        says.text(" left, ");
    }
    says.text(pack.stateLabel());
    ctx.labelDim(
        .{ .x = reading_x, .y = under, .w = pane.w, .h = eui.Surface.textHeight() },
        says.done(),
    );

    // The pack itself, on the right, where a second column reads as a second
    // subject rather than as more of the first.
    var capacity: [32]u8 = @splat(0);
    var built = str.Builder{ .buf = &capacity };
    built.number(pack.last_full);
    built.byte(' ');
    built.text(pack.capacityUnit());
    rightLabel(pane, y + t.padding, built.done(), t.text_dim);

    if (pack.health()) |worn| {
        var health: [40]u8 = @splat(0);
        var spelled = str.Builder{ .buf = &health };
        spelled.text("health ");
        spelled.number(@min(worn, 100));
        spelled.byte('%');

        rightLabel(pane, y + t.padding + theme.enlarged(18), spelled.done(), t.text_dim);
    }

    // Under whichever column runs longer: the picture on the left, or the
    // number and what it is doing beside it.
    const bottom = @max(glyph.bottom(), under + eui.Surface.textHeight());
    return rule(pane, bottom + t.padding);
}

fn rightLabel(pane: eui.Rect, y: i32, text: []const u8, ink: eui.draw.Color) void {
    const width = eui.Surface.textWidth(text);
    ctx.rowText(.{ .x = pane.right() - width, .y = y, .w = width, .h = 16 }, text, ink);
}

/// A battery, drawn rather than lettered: the one picture nobody has to be
/// taught, at a size that says this is the subject of the page.
fn paintBatteryGlyph(area: eui.Rect, percent: u8, charging: bool) void {
    const t = theme.current();
    const cap_w = @max(theme.enlarged(4), 2);
    const body = eui.Rect{ .x = area.x, .y = area.y, .w = area.w - cap_w, .h = area.h };

    ctx.surface.fill(body, t.surface);
    ctx.surface.borderInset(body, 2, t.text_dim);
    ctx.surface.fill(.{
        .x = body.right(),
        .y = area.y + @divTrunc(area.h, 3),
        .w = cap_w,
        .h = @divTrunc(area.h, 3),
    }, t.text_dim);

    const inside = body.inset(4);
    ctx.surface.fill(.{
        .x = inside.x,
        .y = inside.y,
        .w = eui.widget.filledWidth(inside, percent),
        .h = inside.h,
    }, if (charging)
        t.accent
    else if (eui.gauge.alarming(percent, .when_empty))
        t.warning
    else
        t.accent);

    ctx.addDamage(area);
}

/// The panel's own level, which on this machine is most of what it draws.
fn drawBacklight(pane: eui.Rect, from: i32) i32 {
    const t = theme.current();
    const y = from;

    const level = lamp orelse {
        ctx.labelDim(
            .{ .x = pane.x, .y = y, .w = pane.w, .h = 16 },
            "The backlight cannot be set on this machine.",
        );
        return y + t.control_height;
    };

    const label_w = factColumn(pane);
    var reading: [16]u8 = @splat(0);
    var said = str.Builder{ .buf = &reading };
    said.number(level.level);
    said.text(" of ");
    said.number(level.max);

    const value_w = theme.enlarged(56);
    const bar = eui.Rect{
        .x = pane.x + label_w,
        .y = y,
        .w = pane.w - label_w - value_w - t.gap,
        .h = t.control_height,
    };

    ctx.labelDim(.{ .x = pane.x, .y = y + 4, .w = label_w, .h = t.control_height }, "Backlight");
    // Setting the panel is a conversation with the firmware, so the knob
    // follows the pointer and the panel is told where it landed.
    const chosen = ctx.slider(
        bar,
        .{ .min = 1, .max = @intCast(level.max) },
        @intCast(level.level),
        .{ .commit = .on_rest },
    );
    // The service answers with the level it actually set, which is what the
    // control shows from here: reading it back on the next sample would
    // leave the knob standing where the panel no longer is.
    if (chosen != level.level) lamp = platform.setBacklight(@intCast(chosen)) orelse lamp;
    ctx.label(
        .{ .x = bar.right() + t.gap, .y = y + 4, .w = value_w, .h = t.control_height },
        said.done(),
    );

    return y + t.control_height + t.padding;
}

/// One interval, from the answers that make sense for it.
fn drawIdleRow(
    pane: eui.Rect,
    from: i32,
    label: []const u8,
    value: *store.Idle,
    offered: []const store.Idle,
) i32 {
    const t = theme.current();
    const label_w = factColumn(pane);

    // The words are the values' own names, which are already what a person
    // would write: "30s", "never".
    ctx.labelDim(.{ .x = pane.x, .y = from + 4, .w = label_w, .h = t.control_height }, label);
    const picked = ctx.choiceAmong(
        .{ .x = pane.x + label_w, .y = from, .w = pane.w - label_w, .h = t.control_height },
        value.*,
        offered,
        &.{},
    );
    if (picked != value.*) {
        value.* = picked;
        change();
    }
    return from + t.control_height + t.padding;
}

fn drawThermal(pane: eui.Rect, from: i32) i32 {
    const t = theme.current();
    var y = from;
    const full = eui.Rect{ .x = pane.x, .y = y, .w = pane.w, .h = t.control_height };

    var shown = false;
    for (zones) |maybe| {
        const zone = maybe orelse break;
        if (!proto.platform.Thermal.known(zone.now)) continue;
        if (!shown) {
            y = group(&y, full, "Temperature");
            shown = true;
        }

        const label_w = factColumn(pane);
        const bar_w = @divTrunc(pane.w - label_w, 2);
        const ceiling = if (proto.platform.Thermal.known(zone.critical))
            proto.platform.Thermal.degrees(zone.critical)
        else
            100;
        const now = proto.platform.Thermal.degrees(zone.now);
        const share: u8 = @intCast(@max(0, @min(100, @divTrunc(now * 100, @max(ceiling, 1)))));

        var reading: [40]u8 = @splat(0);
        var line = str.Builder{ .buf = &reading };
        line.number(@intCast(@max(now, 0)));
        line.text(" C");
        if (proto.platform.Thermal.known(zone.passive)) {
            line.text(", slows at ");
            line.number(@intCast(@max(proto.platform.Thermal.degrees(zone.passive), 0)));
        }
        if (proto.platform.Thermal.known(zone.critical)) {
            line.text(", cuts at ");
            line.number(@intCast(@max(ceiling, 0)));
        }

        ctx.labelDim(.{ .x = pane.x, .y = y + 2, .w = label_w, .h = t.control_height }, zone.named());
        ctx.progress(.{ .x = pane.x + label_w, .y = y + 6, .w = bar_w, .h = 10 }, share, .{});
        ctx.label(
            .{ .x = pane.x + label_w + bar_w + t.gap, .y = y + 2, .w = pane.w, .h = t.control_height },
            line.done(),
        );
        y += t.menu_row_height;
    }

    if (shown) y += t.padding;
    return y;
}

/// One measured quantity with its unit, or nothing at all: a firmware that
/// does not know says so by saying nothing, and a row reading "unknown" for
/// every pack on every machine teaches a person to stop reading the page.
fn drawAmount(pane: eui.Rect, y: i32, label: []const u8, value: u32, unit: []const u8) i32 {
    if (value == 0 or value == proto.platform.Battery.UNKNOWN) return y;

    var buf: [32]u8 = @splat(0);
    var line = str.Builder{ .buf = &buf };
    line.number(value);
    line.byte(' ');
    line.text(unit);
    return drawFact(pane, y, label, line.done());
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

fn drawAbout(pane: eui.Rect) i32 {
    const t = theme.current();
    var y = drawIdentity(pane);

    y = group(&y, pane, "Software");
    y = drawFacts(pane, y, &software, 0);
    y += t.padding;

    y = group(&y, pane, "Hardware");
    return drawFacts(pane, y, &hardware, software.len);
}

/// What the kernel answers about itself and the machine under it. Read
/// once, because none of it changes while the machine is running, and a
/// paint happens whenever the pointer moves.
var fact_text: [software.len + hardware.len][128]u8 = @splat(@splat(0));
var fact_len: [software.len + hardware.len]u8 = @splat(0);
var facts_read = false;
var board_text: [128]u8 = @splat(0);
var board_len: u8 = 0;

fn readFacts() void {
    if (facts_read) return;
    facts_read = true;

    for (software ++ hardware, 0..) |fact, at| {
        var value = info.ask(fact.key, &fact_text[at]);
        if (value.len == 0 and fact.then.len > 0) value = describe(fact.then, &fact_text[at]);
        fact_len[at] = @intCast(@min(value.len, fact_text[at].len));
    }

    board_len = @intCast(@min(info.ask("board", &board_text).len, board_text.len));
}

fn drawFacts(pane: eui.Rect, from: i32, facts: []const Fact, at: usize) i32 {
    var y = from;
    for (facts, at..) |fact, index| {
        if (fact_len[index] == 0) continue;
        y = drawFact(pane, y, fact.label, fact_text[index][0..fact_len[index]]);
    }
    return y;
}

/// A fallback key's answer, in the words the row wants. `mem.total` is a
/// count of bytes, which is a number for a program rather than an answer for
/// a person.
fn describe(key: []const u8, buf: []u8) []const u8 {
    if (std.mem.eql(u8, key, "mem.total")) {
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

    const board = board_text[0..board_len];
    ctx.label(.{ .x = left, .y = y, .w = wide, .h = t.control_height }, if (board.len > 0) board else "unknown board");

    // A rule under the head, which is what separates what the machine is from
    // what is in it.
    const below = @max(mark.bottom(), y + eui.Surface.textHeight()) + t.menu_padding;
    if (ctx.damaged) {
        ctx.surface.fill(.{ .x = pane.x, .y = below, .w = pane.w, .h = 1 }, t.line);
    }
    return below + t.menu_padding;
}

/// The label column: a quarter of the pane, so the values line up down the
/// page whatever they say.
fn factColumn(pane: eui.Rect) i32 {
    return eui.facts.column(pane);
}

fn drawFact(pane: eui.Rect, y: i32, label: []const u8, value: []const u8) i32 {
    return eui.facts.one(ctx, pane, y + 2, label, value);
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

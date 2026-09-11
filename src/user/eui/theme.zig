//! The look, in one place.
//!
//! Every colour and every measurement the toolkit and the window manager draw
//! with comes from here, so a theme is a value rather than a search through
//! the drawing code. Nothing below this file hard-codes a colour.
//!
//! **Classic, and shaped by this panel.** 800x480 on a 7-inch screen is about
//! 133 DPI, which is dense enough that a one-pixel line is a hairline and
//! sparse enough that every pixel of chrome is one not spent on content. So:
//! light surfaces with dark text, hairline borders, solid fills, and no
//! gradients or bevels. The panel is 6-bit plus frame-rate control, so a
//! gradient shimmers rather than blends, and a dark theme on a backlit LCD of
//! this era goes muddy rather than sleek.
//!
//! Colours and metrics follow design/10-gui.md §4.3, which fixed the border
//! colours and the bar height against the panel's real geometry.

const std = @import("std");
const rgb = @import("lib").rgb;
const recolour = @import("recolour.zig");

/// A colour is the shape the panel takes it in: three channels in one word,
/// which is also a surface's pixel. So a theme's colour and what is written
/// into the framebuffer are one value, and a channel is a field rather than
/// something shifted out wherever one is needed.
pub const Color = rgb.Colour;

/// A colour written the way a table of them is written. Every entry below
/// goes through it, which is the whole reason it is short.
const hex = rgb.Colour.hex;

pub const Theme = struct {
    name: []const u8,

    /// The empty desktop behind everything.
    desktop: Color,

    /// Window and control surfaces.
    surface: Color,
    /// A control the pointer is over, or a field expecting input.
    surface_hot: Color,
    /// A control being pressed, and the trough of a progress bar.
    surface_pressed: Color,

    text: Color,
    text_dim: Color,
    text_inverted: Color,

    /// The one colour that says "this, here": focus, selection, progress, and
    /// the focused window's border.
    accent: Color,
    accent_text: Color,

    /// Hairline separators and unfocused window borders.
    line: Color,
    border: Color,
    border_focused: Color,

    bar: Color,
    bar_text: Color,
    bar_line: Color,
    /// The terminal's own ground and ink. A terminal is not a window with
    /// text in it: it is a screen inside a screen. The same neutral
    /// near-black in every theme, because what the terminal looks like is
    /// the terminal's business rather than the desktop's, and because a
    /// tinted black fills the screen with that tint the moment a terminal is
    /// the only window on a desktop.
    terminal_ground: Color,
    terminal_ink: Color,

    warning: Color,

    /// Bar height. 22 px at this density leaves 458 rows for tiles.
    bar_height: i32 = 22,
    /// Control height. 24 px is the smallest that stays comfortably hittable
    /// on a touchpad here.
    control_height: i32 = 24,
    /// Tight on purpose: at 800x480 padding is the first thing to spend and
    /// the last thing worth spending.
    padding: i32 = 6,
    /// Menus and the panels that hold them. A row of a list is not a button:
    /// it has no edge of its own to be bounded by, so it wants the room a
    /// control gets from its border. Every menu in the system reads these,
    /// which is what keeps a bar menu and an application's menu the same
    /// shape.
    menu_row_height: i32 = 22,
    menu_padding: i32 = 10,
    /// Between one thing in a row and the next: a picture and its label, a
    /// slider and the number beside it.
    gap: i32 = 8,
    border_width: i32 = 1,
    border_width_focused: i32 = 2,
    /// How far the outside of a control is rounded.
    ///
    /// What a person clicks is rounded: buttons, the choices in a row, the
    /// field they type into. What only marks or measures is not, because a
    /// radius on a four pixel groove or a twelve pixel box is most of it.
    /// Neither is anything structural, which is a plane rather than a thing
    /// to press.
    ///
    /// A row of joined choices rounds its outside and keeps the corners
    /// between neighbours square, which is what makes it read as one control
    /// with one of them chosen.
    corner_radius: i32 = 4,
};

/// The default. Cool neutrals under dark system chrome: the bar is the
/// machine and the surfaces are the work, and the tonal jump between them
/// separates the two without spending a rule on it.
///
/// Solid fills and hairlines like the rest, for the same reason: the panel is
/// six bits plus frame-rate control, so a gradient shimmers rather than
/// blends.
pub const slate = Theme{
    .name = "slate",
    .desktop = hex(0x2B3138),
    .surface = hex(0xE9EAEC),
    .surface_hot = hex(0xF5F6F7),
    .surface_pressed = hex(0xD8DADD),
    .text = hex(0x1A1D21),
    .text_dim = hex(0x5C636B),
    .text_inverted = hex(0xF7F8F9),
    .accent = hex(0x2F6FE0),
    .accent_text = hex(0xFFFFFF),
    .line = hex(0xC6C9CD),
    .border = hex(0xC6C9CD),
    .border_focused = hex(0x2F6FE0),
    .bar = hex(0x1F242A),
    .bar_text = hex(0xD6D9DD),
    .bar_line = hex(0x10141A),
    .warning = hex(0xB33A2B),
    .terminal_ground = hex(0x141414),
    .terminal_ink = hex(0xD8D8D8),
};

/// Warm greys and a single medium blue, the way a workstation looked before
/// anyone had a gradient to spare.
pub const classic = Theme{
    .name = "classic",
    .desktop = hex(0x5C6670),
    .surface = hex(0xD6D3CE),
    .surface_hot = hex(0xE4E2DE),
    .surface_pressed = hex(0xB8B5B0),
    .text = hex(0x14140F),
    .text_dim = hex(0x5A5A54),
    .text_inverted = hex(0xF4F4F0),
    .accent = hex(0x2864A4),
    .accent_text = hex(0xFFFFFF),
    .line = hex(0xA8A498),
    .border = hex(0xA8A498),
    .border_focused = hex(0x2864A4),
    .bar = hex(0xC8C5C0),
    .bar_text = hex(0x14140F),
    .bar_line = hex(0x8C8880),
    .warning = hex(0xA02820),
    .terminal_ground = hex(0x141414),
    .terminal_ink = hex(0xD8D8D8),
};

/// Higher contrast, for sunlight. Same shapes, harder edges.
pub const paper = Theme{
    .name = "paper",
    .desktop = hex(0x707070),
    .surface = hex(0xF0F0EC),
    .surface_hot = hex(0xFFFFFC),
    .surface_pressed = hex(0xD0D0CC),
    .text = hex(0x000000),
    .text_dim = hex(0x4A4A44),
    .text_inverted = hex(0xFFFFFF),
    .accent = hex(0x1A4E8C),
    .accent_text = hex(0xFFFFFF),
    .line = hex(0x808078),
    .border = hex(0x808078),
    .border_focused = hex(0x1A4E8C),
    .bar = hex(0xE0E0DC),
    .bar_text = hex(0x000000),
    .bar_line = hex(0x707068),
    .warning = hex(0x901810),
    .terminal_ground = hex(0x141414),
    .terminal_ink = hex(0xD8D8D8),
};

/// For a dark room, where a lit 7-inch panel is the brightest thing present.
pub const dusk = Theme{
    .name = "dusk",
    .desktop = hex(0x1B1F24),
    .surface = hex(0x2A2E35),
    .surface_hot = hex(0x363B44),
    .surface_pressed = hex(0x1F2229),
    .text = hex(0xD8DBE0),
    .text_dim = hex(0x8A9099),
    .text_inverted = hex(0x14171B),
    .accent = hex(0x3A78BE),
    .accent_text = hex(0xF4F8FC),
    .line = hex(0x424852),
    .border = hex(0x424852),
    .border_focused = hex(0x3A78BE),
    .bar = hex(0x14171B),
    .bar_text = hex(0xC8CCD2),
    .bar_line = hex(0x2A2E35),
    .warning = hex(0xC05050),
    .terminal_ground = hex(0x141414),
    .terminal_ink = hex(0xD8D8D8),
};

pub const all = [_]*const Theme{ &slate, &classic, &paper, &dusk };

/// What everything draws with now. Assigning a different theme and repainting
/// changes the whole interface, which is the point of it being one value.
/// What was chosen, as written. Cycling and naming work on these, not on
/// what is drawn with.
var chosen: *const Theme = &slate;

/// What everything draws with: the chosen theme with the scale applied. A
/// value rather than a pointer, because it is the chosen one multiplied and
/// there is nowhere else for the result to live.
var active: Theme = slate;

/// How large the interface is drawn, as a percentage.
///
/// The panel is 133 DPI, which reads differently to different eyes, and the
/// only way to know is to look at it on the machine. So it is a setting, and
/// the range is the useful one: below a hundred nothing is hittable, and
/// above two hundred a window holds one control.
var magnification: u16 = 100;

pub const SCALE_MIN: u16 = 100;
pub const SCALE_MAX: u16 = 200;
/// Where the face doubles. The letters are a bitmap, so they double or they
/// do not: anything between is a blur, and a blurred letter on a panel this
/// dense is worse than a small one.
pub const SCALE_DOUBLES: u16 = 150;

/// The scales worth stopping at. The face doubles at one of them and every
/// other measure is a fraction of a whole number of pixels, so between them
/// the metrics stretch and the letters do not.
pub const SCALE_STEPS = [_]i32{ 100, 125, 150, 175, 200 };

/// Colours a program asks the controls it draws next to wear instead of the
/// theme's own: a page's button in the page's colours, a name in the colour
/// its owner gave it. What it does not give stays the theme's.
///
/// Words stay readable whatever is asked. The ink, the dim ink and the ink on
/// the accent are each moved as far as they have to be to read on the ground
/// they land on, and the lighter and darker steps a control answers the
/// pointer with are taken from the ground it was given.
pub const Tint = struct {
    /// What the controls are filled with, and what they sit on.
    ground: ?Color = null,
    /// What their words are written in.
    ink: ?Color = null,
    /// What marks the chosen, and where the keyboard is.
    accent: ?Color = null,
};

/// The tint worn now, and the theme as it is drawn in it.
var worn: Tint = .{};
var tinted: Theme = slate;
var drawn: *const Theme = &active;

/// How far a tinted control's lighter and darker steps stand from its
/// ground.
const STEP = 14;

/// How much of the ink the dim ink and the hairlines on a given ground are,
/// in 255ths: the dim ink most of the way from the ground to the ink, and a
/// hairline a fifth of it.
const DIM_SHARE = 160;
const LINE_SHARE = 48;

pub fn current() *const Theme {
    return drawn;
}

/// Draw in `tint` from here on, and say what was worn before, to be put back
/// once the controls it was for are drawn:
///
///     const before = eui.theme.wear(.{ .ground = paper });
///     defer _ = eui.theme.wear(before);
pub fn wear(tint: Tint) Tint {
    const before = worn;
    worn = tint;
    retint();
    return before;
}

/// The tint worn now, which a control remembers it was painted in.
pub fn wearing() Tint {
    return worn;
}

/// The theme drawn with: the active one, or the active one in the tint worn.
fn retint() void {
    if (std.meta.eql(worn, Tint{})) {
        drawn = &active;
        return;
    }
    tinted = active;
    const t = &tinted;
    if (worn.ground) |ground| {
        t.surface = ground;
        t.surface_hot = recolour.lighter(ground, STEP);
        t.surface_pressed = recolour.darker(ground, STEP);
    }
    if (worn.ink) |ink| t.text = ink;
    if (worn.accent) |accent| {
        t.accent = accent;
        t.border_focused = accent;
    }
    if (worn.ground != null or worn.ink != null) {
        t.text = recolour.legible(t.text, t.surface);
        t.text_dim = recolour.legible(t.surface.mix(t.text, DIM_SHARE), t.surface);
        t.line = t.surface.mix(t.text, LINE_SHARE);
        t.border = t.line;
    }
    t.accent_text = recolour.legible(t.accent_text, t.accent);
    drawn = t;
}

pub fn use(theme: *const Theme) void {
    chosen = theme;
    rebuild();
}

pub fn scale() u16 {
    return magnification;
}

pub fn setScale(percent: u16) void {
    magnification = @max(SCALE_MIN, @min(percent, SCALE_MAX));
    rebuild();
}

/// How many pixels of screen one pixel of the face becomes.
pub fn textScale() i32 {
    return if (magnification >= SCALE_DOUBLES) 2 else 1;
}

/// The chosen theme, measured for the screen it is going on.
///
/// Colours are not scaled, and neither are the border widths: a hairline is
/// a hairline at any size, and a two pixel focus ring drawn at four is a
/// window that looks selected from across the room.
/// The highlight somebody chose, or none for the theme's own.
var accent_choice: ?Color = null;

/// Draw the interface in a different highlight.
///
/// One value replaces every use of it: the selected row, the focused edge, a
/// slider's fill and the marks in the bar are all the same colour by
/// construction, and a theme where they drifted apart would look like four
/// decisions rather than one.
pub fn setAccent(colour: ?Color) void {
    accent_choice = colour;
    rebuild();
}

fn rebuild() void {
    active = chosen.*;
    if (accent_choice) |colour| {
        active.accent = colour;
        active.border_focused = colour;
    }
    active.bar_height = enlarge(active.bar_height);
    active.control_height = enlarge(active.control_height);
    active.padding = enlarge(active.padding);
    active.menu_row_height = enlarge(active.menu_row_height);
    active.menu_padding = enlarge(active.menu_padding);
    active.gap = enlarge(active.gap);
    retint();
}

/// A number chosen for a hundred per cent, measured for the size the
/// interface is actually being drawn at.
///
/// Public because not every measurement belongs in the theme: how wide a
/// taskbar tab may grow is the manager's business, but it was still chosen
/// against a twelve pixel face and has to grow with one.
/// How tall a strip along the edge of a window is.
///
/// One height for all of them, whatever they hold: a menu bar, a row of
/// places, a row of keys, a status line. Two windows side by side is the
/// ordinary case on a screen this size, and strips that disagree by a few
/// pixels read as two programs rather than one system.
pub fn stripHeight() i32 {
    const t = current();
    return t.control_height + t.padding;
}

pub fn enlarged(value: i32) i32 {
    return @divTrunc(value * @as(i32, magnification), 100);
}

fn enlarge(value: i32) i32 {
    return enlarged(value);
}

/// Switch to the next theme, for a key binding to call.
pub fn cycle() *const Theme {
    for (all, 0..) |candidate, i| {
        if (candidate == chosen) {
            use(all[(i + 1) % all.len]);
            return chosen;
        }
    }
    use(all[0]);
    return chosen;
}

pub fn byName(name: []const u8) ?*const Theme {
    for (all) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return candidate;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a tint is worn until what was worn before is put back" {
    try testing.expect(current() == &active);
    const before = wear(.{ .ground = Color.hex(0x202020) });
    try testing.expect(current().surface.eql(.hex(0x202020)));
    _ = wear(before);
    try testing.expect(current() == &active);
}

test "words stay readable on a tinted ground, and its steps are taken from it" {
    const before = wear(.{ .ground = Color.hex(0x202020), .ink = Color.hex(0x303030) });
    defer _ = wear(before);
    const t = current();
    const apart = @as(i32, t.text.lightness()) - @as(i32, t.surface.lightness());
    try testing.expect(@abs(apart) >= recolour.CONTRAST);
    try testing.expect(t.surface_hot.lightness() > t.surface.lightness());
    try testing.expect(t.surface_pressed.lightness() < t.surface.lightness());
}

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

pub const Color = u32;

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
    /// How far the outside of a joined row of controls is rounded.
    ///
    /// Everything else is square: on a panel at 1:1 with no subpixel
    /// positioning, square is what stays crisp. A row of choices is the one
    /// exception, and only around its outside, because that is what makes
    /// three buttons read as one control with one of them chosen rather than
    /// as three buttons that happen to be adjacent.
    group_radius: i32 = 4,
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
    .desktop = 0x2B3138,
    .surface = 0xE9EAEC,
    .surface_hot = 0xF5F6F7,
    .surface_pressed = 0xD8DADD,
    .text = 0x1A1D21,
    .text_dim = 0x5C636B,
    .text_inverted = 0xF7F8F9,
    .accent = 0x2F6FE0,
    .accent_text = 0xFFFFFF,
    .line = 0xC6C9CD,
    .border = 0xC6C9CD,
    .border_focused = 0x2F6FE0,
    .bar = 0x1F242A,
    .bar_text = 0xD6D9DD,
    .bar_line = 0x10141A,
    .warning = 0xB33A2B,
    .terminal_ground = 0x141414,
    .terminal_ink = 0xD8D8D8,
};

/// Warm greys and a single medium blue, the way a workstation looked before
/// anyone had a gradient to spare.
pub const classic = Theme{
    .name = "classic",
    .desktop = 0x5C6670,
    .surface = 0xD6D3CE,
    .surface_hot = 0xE4E2DE,
    .surface_pressed = 0xB8B5B0,
    .text = 0x14140F,
    .text_dim = 0x5A5A54,
    .text_inverted = 0xF4F4F0,
    .accent = 0x2864A4,
    .accent_text = 0xFFFFFF,
    .line = 0xA8A498,
    .border = 0xA8A498,
    .border_focused = 0x2864A4,
    .bar = 0xC8C5C0,
    .bar_text = 0x14140F,
    .bar_line = 0x8C8880,
    .warning = 0xA02820,
    .terminal_ground = 0x141414,
    .terminal_ink = 0xD8D8D8,
};

/// Higher contrast, for sunlight. Same shapes, harder edges.
pub const paper = Theme{
    .name = "paper",
    .desktop = 0x707070,
    .surface = 0xF0F0EC,
    .surface_hot = 0xFFFFFC,
    .surface_pressed = 0xD0D0CC,
    .text = 0x000000,
    .text_dim = 0x4A4A44,
    .text_inverted = 0xFFFFFF,
    .accent = 0x1A4E8C,
    .accent_text = 0xFFFFFF,
    .line = 0x808078,
    .border = 0x808078,
    .border_focused = 0x1A4E8C,
    .bar = 0xE0E0DC,
    .bar_text = 0x000000,
    .bar_line = 0x707068,
    .warning = 0x901810,
    .terminal_ground = 0x141414,
    .terminal_ink = 0xD8D8D8,
};

/// For a dark room, where a lit 7-inch panel is the brightest thing present.
pub const dusk = Theme{
    .name = "dusk",
    .desktop = 0x1B1F24,
    .surface = 0x2A2E35,
    .surface_hot = 0x363B44,
    .surface_pressed = 0x1F2229,
    .text = 0xD8DBE0,
    .text_dim = 0x8A9099,
    .text_inverted = 0x14171B,
    .accent = 0x3A78BE,
    .accent_text = 0xF4F8FC,
    .line = 0x424852,
    .border = 0x424852,
    .border_focused = 0x3A78BE,
    .bar = 0x14171B,
    .bar_text = 0xC8CCD2,
    .bar_line = 0x2A2E35,
    .warning = 0xC05050,
    .terminal_ground = 0x141414,
    .terminal_ink = 0xD8D8D8,
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

pub fn current() *const Theme {
    return &active;
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
var accent_choice: ?u32 = null;

/// Draw the interface in a different highlight.
///
/// One value replaces every use of it: the selected row, the focused edge, a
/// slider's fill and the marks in the bar are all the same colour by
/// construction, and a theme where they drifted apart would look like four
/// decisions rather than one.
pub fn setAccent(colour: ?u32) void {
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

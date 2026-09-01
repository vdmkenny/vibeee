//! Calc: arithmetic, in a window you hold over the thing you are doing.
//!
//! Opens above the tiling rather than in it, because a calculator is a tool
//! rather than a place to work; Super+F puts it into the tiling for anybody
//! who would rather have it there.
//!
//! Typed at or pointed at, whichever is to hand. Every key on the pad has a
//! key on the keyboard, and the pad takes Tab and Enter like every other
//! control in the toolkit, so neither way is the poor relation. The sum
//! itself is `lib.calc`, which knows nothing about windows and is tested
//! without one.

const calc = @import("lib").calc;
const eui = @import("eui");
const proto = @import("proto");

const KeyCode = proto.app.KeyCode;
const Modifiers = proto.app.Modifiers;
const Rect = eui.Rect;
const theme = eui.theme;

const ctx = &proto.app.ctx;

var machine: calc.Machine = .{};

/// The pad, in the order a hand finds it. What each key does is here rather
/// than in the drawing, so the keyboard and the pointer reach the same list.
const Key = struct {
    label: []const u8,
    /// Columns it takes. The zero is as wide as two because it is pressed
    /// more than anything else on the pad.
    across: i32 = 1,
    weight: eui.widget.Emphasis = .plain,
    press: *const fn () void,
};

const KEYS = [_]Key{
    .{ .label = "C", .weight = .quiet, .press = &clear },
    .{ .label = "\u{00B1}", .weight = .quiet, .press = &negate },
    .{ .label = "%", .weight = .quiet, .press = &percent },
    .{ .label = "\u{00F7}", .weight = .quiet, .press = &divide },

    .{ .label = "7", .press = &seven },
    .{ .label = "8", .press = &eight },
    .{ .label = "9", .press = &nine },
    .{ .label = "\u{00D7}", .weight = .quiet, .press = &multiply },

    .{ .label = "4", .press = &four },
    .{ .label = "5", .press = &five },
    .{ .label = "6", .press = &six },
    .{ .label = "\u{2013}", .weight = .quiet, .press = &subtract },

    .{ .label = "1", .press = &one },
    .{ .label = "2", .press = &two },
    .{ .label = "3", .press = &three },
    .{ .label = "+", .weight = .quiet, .press = &add },

    .{ .label = "0", .across = 2, .press = &zero },
    .{ .label = ".", .press = &point },
    .{ .label = "=", .weight = .strong, .press = &equals },
};

const COLUMNS: i32 = 4;
const ROWS: i32 = 5;

/// The window opens at the size the pad wants, so nothing has to be measured
/// twice or guessed at.
fn wanted() struct { w: u16, h: u16 } {
    const t = theme.current();
    const key_h = t.control_height + 6;
    const pad = eui.Grid.heightFor(ROWS, key_h, t.padding);
    return .{
        .w = @intCast(t.padding * 2 + COLUMNS * 46 + (COLUMNS - 1) * t.padding),
        .h = @intCast(readoutHeight() + pad + t.padding * 2),
    };
}

fn readoutHeight() i32 {
    const t = theme.current();
    return t.padding * 2 + eui.Surface.textHeight() + eui.Surface.textLargeHeight(2);
}

export fn _start() callconv(.c) noreturn {
    const size = wanted();
    proto.app.run("calc", "Calc", size.w, size.h, .{
        .draw = draw,
        .key = key,
        .text = typed,
        .floating = true,
    });
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

fn draw() void {
    const t = theme.current();
    const surface = ctx.surface;
    const area = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };
    if (ctx.damaged) ctx.surface.fill(area, t.surface);

    const readout = Rect{ .x = area.x, .y = area.y, .w = area.w, .h = readoutHeight() };
    drawReadout(readout);

    const pad = eui.Grid{
        .area = .{
            .x = area.x + t.padding,
            .y = readout.bottom() + t.padding,
            .w = area.w - t.padding * 2,
            .h = area.bottom() - readout.bottom() - t.padding * 2,
        },
        .columns = COLUMNS,
        .rows = ROWS,
        .gap = t.padding,
    };

    var column: i32 = 0;
    var row: i32 = 0;
    for (KEYS) |k| {
        if (ctx.buttonAs(pad.wide(column, row, k.across), k.label, k.weight)) {
            k.press();
            // The readout was drawn before this key was polled, so the pass
            // that presses it is not the pass that can show the answer.
            ctx.damage();
        }
        column += k.across;
        if (column >= COLUMNS) {
            column = 0;
            row += 1;
        }
    }


}

/// The sum above the answer. A number with nothing above it is a number you
/// have to trust; with the sum above it you can see where it came from.
fn drawReadout(area: Rect) void {
    const t = theme.current();

    var answer: [calc.WRITTEN_MAX]u8 = undefined;
    var above: [calc.WRITTEN_MAX * 2]u8 = undefined;
    const shown = machine.shown(&answer);
    const sum = machine.sum(&above);

    // Repainted only when what it says changes: the readout is the one part
    // of this window that is not a control keeping its own state, and every
    // pointer motion over the pad brings a pass through here.
    const entry = ctx.slotFor(area) orelse return;
    entry.seen = true;
    var mark = eui.widget.Fingerprint{};
    mark.text(shown);
    mark.text(sum);
    const signature = mark.done();
    if (!ctx.damaged and entry.detail == signature) return;
    entry.detail = signature;

    ctx.surface.fill(area, t.surface_pressed);
    ctx.surface.fill(
        .{ .x = area.x, .y = area.bottom() - 1, .w = area.w, .h = 1 },
        t.line,
    );

    const right = area.right() - t.padding;
    ctx.surface.text(
        right - eui.Surface.textWidth(sum),
        area.y + t.padding,
        sum,
        t.text_dim,
    );

    // The answer is the subject of the window, and takes the size that says
    // so. In trouble it is a sentence rather than a number, and a sentence
    // at that size would not fit.
    const large = machine.trouble == null;
    const width = if (large)
        eui.Surface.textLargeWidth(shown, 2)
    else
        eui.Surface.textWidth(shown);
    const y = area.y + t.padding + eui.Surface.textHeight();
    const ink = if (large) t.text else t.warning;
    if (large) {
        ctx.surface.textLarge(right - width, y, shown, ink, 2);
    } else {
        ctx.surface.text(right - width, y, shown, ink);
    }

    ctx.addDamage(area);
}

// ---------------------------------------------------------------------------
// The keyboard
//
// Everything the pad does, done by the keys a person would reach for. The
// character keys arrive as text, so a layout that puts an operator behind a
// modifier still sends the operator.
// ---------------------------------------------------------------------------

fn typed(codepoint: u32) bool {
    switch (codepoint) {
        '0'...'9' => machine.digit(@intCast(codepoint - '0')),
        // Both, because a keypad has one and a Belgian layout has the other
        // where a decimal point belongs.
        '.', ',' => machine.point(),
        '+' => machine.operate(.add),
        '-' => machine.operate(.subtract),
        '*', 'x' => machine.operate(.multiply),
        '/', ':' => machine.operate(.divide),
        '%' => machine.percent(),
        '=' => machine.equals(),
        'c', 'C' => machine.clear(),
        else => return false,
    }
    return true;
}

fn key(code: KeyCode, mods: Modifiers) bool {
    _ = mods;
    switch (code) {
        // Enter always ends the sum. Walking the pad with Tab and pressing
        // the key it landed on is the toolkit's other activation key, the
        // space bar, which a calculator has nothing else to do with: an
        // Enter that meant one thing or the other depending on whether
        // anything had been clicked would be an Enter nobody could rely on.
        .enter => machine.equals(),
        .escape => machine.clear(),
        .backspace => machine.back(),
        else => return false,
    }
    return true;
}

// ---------------------------------------------------------------------------
// What the keys do
//
// One function each, because the pad holds pointers to them and a pointer
// cannot carry an argument with it. They are the whole of the app's logic:
// everything below the surface is `lib.calc`.
// ---------------------------------------------------------------------------

fn zero() void {
    machine.digit(0);
}
fn one() void {
    machine.digit(1);
}
fn two() void {
    machine.digit(2);
}
fn three() void {
    machine.digit(3);
}
fn four() void {
    machine.digit(4);
}
fn five() void {
    machine.digit(5);
}
fn six() void {
    machine.digit(6);
}
fn seven() void {
    machine.digit(7);
}
fn eight() void {
    machine.digit(8);
}
fn nine() void {
    machine.digit(9);
}
fn point() void {
    machine.point();
}
fn negate() void {
    machine.negate();
}
fn percent() void {
    machine.percent();
}
fn clear() void {
    machine.clear();
}
fn equals() void {
    machine.equals();
}
fn add() void {
    machine.operate(.add);
}
fn subtract() void {
    machine.operate(.subtract);
}
fn multiply() void {
    machine.operate(.multiply);
}
fn divide() void {
    machine.operate(.divide);
}

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

/// What pressing something does. The keyboard and the pad want the same
/// answers, and this is where they meet: a digit carries which digit it is,
/// which is exactly what a pointer to a function could not.
const Press = union(enum) {
    digit: u8,
    point,
    negate,
    percent,
    clear,
    back,
    equals,
    operate: calc.Op,
};

fn press(what: Press) void {
    switch (what) {
        .digit => |which| machine.digit(which),
        .point => machine.point(),
        .negate => machine.negate(),
        .percent => machine.percent(),
        .clear => machine.clear(),
        .back => machine.back(),
        .equals => machine.equals(),
        .operate => |op| machine.operate(op),
    }
}

/// The pad, in the order a hand finds it.
const Key = struct {
    label: []const u8,
    /// Columns it takes. The zero is as wide as two because it is pressed
    /// more than anything else on the pad.
    across: i32 = 1,
    weight: eui.widget.Emphasis = .plain,
    does: Press,
};

const KEYS = [_]Key{
    .{ .label = "C", .weight = .quiet, .does = .clear },
    .{ .label = "\u{00B1}", .weight = .quiet, .does = .negate },
    .{ .label = "%", .weight = .quiet, .does = .percent },
    .{ .label = "\u{00F7}", .weight = .quiet, .does = .{ .operate = .divide } },

    .{ .label = "7", .does = .{ .digit = 7 } },
    .{ .label = "8", .does = .{ .digit = 8 } },
    .{ .label = "9", .does = .{ .digit = 9 } },
    .{ .label = "\u{00D7}", .weight = .quiet, .does = .{ .operate = .multiply } },

    .{ .label = "4", .does = .{ .digit = 4 } },
    .{ .label = "5", .does = .{ .digit = 5 } },
    .{ .label = "6", .does = .{ .digit = 6 } },
    .{ .label = "\u{2013}", .weight = .quiet, .does = .{ .operate = .subtract } },

    .{ .label = "1", .does = .{ .digit = 1 } },
    .{ .label = "2", .does = .{ .digit = 2 } },
    .{ .label = "3", .does = .{ .digit = 3 } },
    .{ .label = "+", .weight = .quiet, .does = .{ .operate = .add } },

    .{ .label = "0", .across = 2, .does = .{ .digit = 0 } },
    .{ .label = ".", .does = .point },
    .{ .label = "=", .weight = .strong, .does = .equals },
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
    return t.padding * 2 + eui.Surface.textHeight() + eui.Surface.titleHeight();
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
            press(k.does);
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
        eui.Surface.titleWidth(shown)
    else
        eui.Surface.textWidth(shown);
    const y = area.y + t.padding + eui.Surface.textHeight();
    const ink = if (large) t.text else t.warning;
    if (large) {
        ctx.surface.title(right - width, y, shown, ink);
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
    press(switch (codepoint) {
        '0'...'9' => .{ .digit = @intCast(codepoint - '0') },
        // Both, because a keypad has one and a Belgian layout has the other
        // where a decimal point belongs.
        '.', ',' => .point,
        '+' => .{ .operate = .add },
        '-' => .{ .operate = .subtract },
        '*', 'x' => .{ .operate = .multiply },
        '/', ':' => .{ .operate = .divide },
        '%' => .percent,
        '=' => .equals,
        'c', 'C' => .clear,
        else => return false,
    });
    return true;
}

fn key(code: KeyCode, mods: Modifiers) bool {
    _ = mods;
    press(switch (code) {
        // Enter always ends the sum. Walking the pad with Tab and pressing
        // the key it landed on is the toolkit's other activation key, the
        // space bar, which a calculator has nothing else to do with: an
        // Enter that meant one thing or the other depending on whether
        // anything had been clicked would be an Enter nobody could rely on.
        .enter => .equals,
        .escape => .clear,
        .backspace => .back,
        else => return false,
    });
    return true;
}

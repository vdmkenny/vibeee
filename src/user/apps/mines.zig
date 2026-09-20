//! Mines: a minesweeper, in a window the size of its grid.
//!
//! Floating, like the calculator: a game is something held over the work
//! rather than a place to work. The board is `lib.mines`, which knows
//! nothing about windows and is tested without one.
//!
//! Pointed at or typed at, whichever is to hand. The left button opens a
//! cell and the right flags it; the keys move a cursor, open with the space
//! bar and flag with F. The Game menu holds the grids and a fresh game, and
//! the button over the grid says how many mines are left to find, or starts
//! again once one has been stepped on.

const eui = @import("eui");
const mines = @import("lib").mines;
const proto = @import("proto");
const rgb = @import("lib").rgb;
const std = @import("std");
const sys = @import("sys");

const Color = eui.Color;
const KeyCode = proto.app.KeyCode;
const Modifiers = proto.app.Modifiers;
const Rect = eui.Rect;
const theme = eui.theme;

const ctx = &proto.app.ctx;

/// A cell's side in the window as it opens: the icon's twelve pixels and
/// room around them. A window made smaller draws smaller cells.
const CELL: i32 = 18;

/// The sunken edge around the grid, and the raised edge on every shut cell.
const FRAME: i32 = 2;

/// The grid a game opens on.
const OPENS_ON: mines.Difficulty = .beginner;

/// The board's own colours, which are this game's rather than the theme's:
/// the numbers only read on the grey they were chosen for, and that grey is
/// what a minesweeper has looked like since the first one.
const FIELD = rgb.Colour.hex(0xC0C0C0);
const LIGHT = rgb.Colour.hex(0xFFFFFF);
const SHADOW = rgb.Colour.hex(0x808080);
/// The cell the game ended on, which is the one worth finding again.
const STRUCK = rgb.Colour.hex(0xE03020);
const MINE_INK = rgb.Colour.hex(0x101010);
const FLAG_INK = rgb.Colour.hex(0xC00000);

/// One colour per number, in the order they have always been.
const NUMBERS = [8]Color{
    rgb.Colour.hex(0x0000FF),
    rgb.Colour.hex(0x007B00),
    rgb.Colour.hex(0xFF0000),
    rgb.Colour.hex(0x000080),
    rgb.Colour.hex(0x800000),
    rgb.Colour.hex(0x008080),
    rgb.Colour.hex(0x000000),
    rgb.Colour.hex(0x808080),
};

/// What the menu can ask for. Named rather than numbered: a menu that gains
/// an entry must not change what the others mean.
const Command = enum(u16) { new, beginner, intermediate, expert, close };

const MENUS = [_]eui.menubar.Menu{
    .{ .label = "Game", .items = &.{
        .{ .label = "New", .id = @intFromEnum(Command.new), .shortcut = "R" },
        eui.menubar.Item.separator,
        .{ .label = "Beginner", .id = @intFromEnum(Command.beginner), .shortcut = "1" },
        .{ .label = "Intermediate", .id = @intFromEnum(Command.intermediate), .shortcut = "2" },
        .{ .label = "Expert", .id = @intFromEnum(Command.expert), .shortcut = "3" },
        eui.menubar.Item.separator,
        .{ .label = "Close", .id = @intFromEnum(Command.close), .shortcut = "Ctrl+Q" },
    } },
};

var menus: eui.menubar.State = .{};
var board = mines.Board.init(OPENS_ON);
var cursor_column: u8 = 0;
var cursor_row: u8 = 0;
var prng: std.Random.DefaultPrng = undefined;

// The icon the launcher shows for this program.
comptime {
    eui.icon.carry(eui.icon.of(.mine).*);
}

export fn _start() callconv(.c) noreturn {
    var seed: [8]u8 = @splat(0);
    _ = sys.random(&seed);
    prng = std.Random.DefaultPrng.init(std.mem.readInt(u64, &seed, .little));

    const size = wanted(board.shape);
    proto.app.run("mines", "Mines", size.w, size.h, .{
        .draw = draw,
        .key = key,
        .opens = .floating,
    });
}

/// The window a grid asks for: the menu strip, the button under it, the
/// cells in their frame, and the padding around them.
fn wanted(shape: mines.Shape) struct { w: u16, h: u16 } {
    const t = theme.current();
    const grid_w = @as(i32, shape.columns) * CELL + FRAME * 2;
    const grid_h = @as(i32, shape.rows) * CELL + FRAME * 2;
    return .{
        .w = @intCast(@max(@max(grid_w + t.padding * 2, buttonWidth() + t.padding * 4), menuWidth())),
        .h = @intCast(theme.stripHeight() + t.control_height + grid_h + t.padding * 3),
    };
}

/// Wide enough for either of the two things the button says.
fn buttonWidth() i32 {
    const t = theme.current();
    const most = @max(eui.Surface.textWidth(TRY_AGAIN), eui.Surface.textWidth("999 left"));
    return most + t.padding * 4;
}

const TRY_AGAIN = "try again";

/// Wide enough for the menu to drop without the window's own edge cutting
/// it: the smallest grid is narrower than the menu over it.
fn menuWidth() i32 {
    const t = theme.current();
    var widest: i32 = 0;
    for (MENUS[0].items) |item| {
        var w = eui.Surface.textWidth(item.label);
        if (item.shortcut.len > 0) w += eui.Surface.textWidth(item.shortcut) + t.padding * 4;
        widest = @max(widest, w);
    }
    return widest + t.padding * 8;
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

fn draw() void {
    const t = theme.current();
    const surface = ctx.surface;
    const whole = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };
    if (ctx.damaged) surface.fill(whole, t.surface);

    const parts = eui.chrome.split(whole, .{ .top = true });
    drawButton(parts.body);

    // The grid sits in a sunken frame, as everything drawn in that era did:
    // dark above and left, light below and right.
    const cells = gridArea(parts.body);
    bevel(.{
        .x = cells.x - FRAME,
        .y = cells.y - FRAME,
        .w = cells.w + FRAME * 2,
        .h = cells.h + FRAME * 2,
    }, SHADOW, LIGHT);
    play(cells);

    // Last in the pass: an open menu hangs over the grid, and anything drawn
    // after it would draw over the menu instead.
    if (eui.menubar.run(ctx, parts.top, &menus, &MENUS)) |id| {
        run(@enumFromInt(id));
    }
}

/// The button over the grid: how many mines are still unaccounted for while
/// a game is on, and the way back to a fresh one once it is over. Pressed
/// either way, because a game somebody wants to leave is a game they want to
/// start again.
fn drawButton(body: Rect) void {
    const t = theme.current();
    var counted: [16]u8 = undefined;
    const label = if (board.state.over())
        TRY_AGAIN
    else
        std.fmt.bufPrint(&counted, "{d} left", .{board.remaining()}) catch TRY_AGAIN;

    const width = buttonWidth();
    const where = Rect{
        .x = body.x + @divTrunc(body.w - width, 2),
        .y = body.y + t.padding,
        .w = width,
        .h = t.control_height,
    };
    const weight: eui.widget.Emphasis = if (board.state == .won) .strong else .plain;
    if (ctx.buttonAs(where, label, weight)) {
        board.restart();
        aim(0, 0);
        ctx.damage();
    }
}

/// An edge around a rectangle: one colour above and left, another below and
/// right. Raised or sunken is which way round they go.
fn bevel(area: Rect, top_left: Color, bottom_right: Color) void {
    const surface = ctx.surface;
    surface.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = FRAME }, top_left);
    surface.fill(.{ .x = area.x, .y = area.y, .w = FRAME, .h = area.h }, top_left);
    surface.fill(.{ .x = area.x, .y = area.bottom() - FRAME, .w = area.w, .h = FRAME }, bottom_right);
    surface.fill(.{ .x = area.right() - FRAME, .y = area.y, .w = FRAME, .h = area.h }, bottom_right);
}

/// How many mines are unaccounted for, and what the last move came to.
fn drawStatus(area: Rect) void {
    const t = theme.current();

    var counted: [16]u8 = undefined;
    const left = std.fmt.bufPrint(&counted, "{d} left", .{board.remaining()}) catch "";
    ctx.surface.text(area.x, area.y, left, t.text);

    const said = switch (board.state) {
        .fresh, .playing => "1 2 3 grids, R again",
        .won => "cleared",
        .lost => "a mine, R again",
    };
    const ink = switch (board.state) {
        .won => t.accent,
        .lost => t.warning,
        .fresh, .playing => t.text_dim,
    };
    ctx.surface.text(area.right() - eui.Surface.textWidth(said), area.y, said, ink);
}

/// Where the grid sits: square cells at the largest side that fits, centred
/// in what the button row leaves.
fn gridArea(body: Rect) Rect {
    const t = theme.current();
    const top = body.y + t.padding * 2 + t.control_height;
    const across = @divTrunc(body.w - (t.padding + FRAME) * 2, @as(i32, board.shape.columns));
    const down = @divTrunc(body.bottom() - top - (t.padding + FRAME) * 2, @as(i32, board.shape.rows));
    const side = @max(@min(@min(across, down), CELL), 1);

    const w = side * @as(i32, board.shape.columns);
    const h = side * @as(i32, board.shape.rows);
    return .{
        .x = body.x + @divTrunc(body.w - w, 2),
        .y = top + FRAME + @divTrunc(body.bottom() - top - t.padding - h, 2),
        .w = w,
        .h = h,
    };
}

/// The grid, pointed at and drawn in one pass, as every control in the
/// toolkit is.
fn play(area: Rect) void {
    const side = @divTrunc(area.w, @as(i32, board.shape.columns));

    if (under(area, side)) |where| {
        if (ctx.pressedThisPass()) {
            aim(where.column, where.row);
            _ = board.reveal(where.column, where.row, prng.random());
            ctx.damage();
        } else if (ctx.takeRightPress()) {
            aim(where.column, where.row);
            _ = board.flag(where.column, where.row);
            ctx.damage();
        }
    }

    for (0..board.shape.rows) |row| {
        for (0..board.shape.columns) |column| {
            drawCell(area, side, @intCast(column), @intCast(row));
        }
    }
}

/// The cell the pointer is over, or none when it is elsewhere.
fn under(area: Rect, side: i32) ?struct { column: u8, row: u8 } {
    if (!area.contains(ctx.pointer_x, ctx.pointer_y)) return null;
    const column = @divTrunc(ctx.pointer_x - area.x, side);
    const row = @divTrunc(ctx.pointer_y - area.y, side);
    if (column < 0 or row < 0) return null;
    if (column >= board.shape.columns or row >= board.shape.rows) return null;
    return .{ .column = @intCast(column), .row = @intCast(row) };
}

fn drawCell(area: Rect, side: i32, column: u8, row: u8) void {
    const cell = board.at(column, row);
    const whole = Rect{
        .x = area.x + @as(i32, column) * side,
        .y = area.y + @as(i32, row) * side,
        .w = side,
        .h = side,
    };

    if (cell.revealed) {
        const struck = board.lost_at != null and board.lost_at.? == board.index(column, row);
        ctx.surface.fill(whole, if (struck) STRUCK else FIELD);
        // An opened cell is flat, with the grid showing along its top and
        // left: the sunken side of the same edge the shut ones are raised by.
        ctx.surface.fill(.{ .x = whole.x, .y = whole.y, .w = whole.w, .h = 1 }, SHADOW);
        ctx.surface.fill(.{ .x = whole.x, .y = whole.y, .w = 1, .h = whole.h }, SHADOW);

        if (cell.mine) {
            ctx.surface.iconCentred(whole, .mine, MINE_INK);
        } else if (cell.around != 0) {
            const digit = [_]u8{'0' + @as(u8, cell.around)};
            ctx.surface.text(
                whole.x + @divTrunc(whole.w - eui.Surface.textWidth(&digit), 2),
                whole.y + @divTrunc(whole.h - eui.Surface.textHeight(), 2),
                &digit,
                NUMBERS[cell.around - 1],
            );
        }
    } else {
        ctx.surface.fill(whole, FIELD);
        bevel(whole, LIGHT, SHADOW);
        if (cell.flagged) ctx.surface.iconCentred(whole, .flag, FLAG_INK);
    }

    if (column == cursor_column and row == cursor_row) {
        const t = theme.current();
        const inside = Rect{ .x = whole.x + 1, .y = whole.y + 1, .w = whole.w - 2, .h = whole.h - 2 };
        ctx.surface.fillAround(whole, inside, t.accent);
    }
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

fn key(code: KeyCode, mods: Modifiers) bool {
    if (mods.control and code == .q) {
        run(.close);
        return true;
    }
    switch (eui.menubar.key(&menus, code, mods, &MENUS)) {
        .ignored => {},
        .taken => {
            ctx.damage();
            return true;
        },
        .chosen => |id| {
            run(@enumFromInt(id));
            return true;
        },
    }

    switch (code) {
        .left => step(-1, 0),
        .right => step(1, 0),
        .up => step(0, -1),
        .down => step(0, 1),
        .space, .enter => _ = board.reveal(cursor_column, cursor_row, prng.random()),
        .f => _ = board.flag(cursor_column, cursor_row),
        .r => run(.new),
        .n1 => run(.beginner),
        .n2 => run(.intermediate),
        .n3 => run(.expert),
        else => return false,
    }
    ctx.damage();
    return true;
}

/// What the menu asked for.
fn run(command: Command) void {
    switch (command) {
        .new => {
            board.restart();
            aim(0, 0);
        },
        .beginner => choose(.beginner),
        .intermediate => choose(.intermediate),
        .expert => choose(.expert),
        .close => sys.exit(0),
    }
    ctx.damage();
}

/// Move the cursor, stopping at the edges. A wrap on a grid this size takes
/// the eye further than the hand meant.
fn step(across: i32, down: i32) void {
    const column = std.math.clamp(@as(i32, cursor_column) + across, 0, @as(i32, board.shape.columns) - 1);
    const row = std.math.clamp(@as(i32, cursor_row) + down, 0, @as(i32, board.shape.rows) - 1);
    aim(@intCast(column), @intCast(row));
}

fn aim(column: u8, row: u8) void {
    cursor_column = column;
    cursor_row = row;
}

/// Another grid, a fresh board on it, and a window the size that grid wants.
/// A window the manager keeps at its own size draws smaller cells instead.
fn choose(difficulty: mines.Difficulty) void {
    board = mines.Board.init(difficulty);
    aim(0, 0);
    const size = wanted(board.shape);
    proto.app.resizeTo(size.w, size.h);
}

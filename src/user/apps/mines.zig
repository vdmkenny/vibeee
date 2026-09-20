//! Mines: a minesweeper, in a window the size of its grid.
//!
//! Floating, like the calculator: a game is something held over the work
//! rather than a place to work. The board is `lib.mines`, which knows
//! nothing about windows and is tested without one.
//!
//! Pointed at or typed at, whichever is to hand. The left button opens a
//! cell and the right flags it; the keys move a cursor, open with the space
//! bar, flag with F, start again with R, and choose a grid with 1, 2 and 3.

const eui = @import("eui");
const mines = @import("lib").mines;
const proto = @import("proto");
const std = @import("std");
const sys = @import("sys");

const KeyCode = proto.app.KeyCode;
const Modifiers = proto.app.Modifiers;
const Rect = eui.Rect;
const theme = eui.theme;

const ctx = &proto.app.ctx;

/// A cell's side in the window as it opens: the icon's twelve pixels and
/// room around them. A window made smaller draws smaller cells.
const CELL: i32 = 18;

/// The grid a game opens on.
const OPENS_ON: mines.Difficulty = .beginner;

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

/// The window a grid asks for: its cells, the line above them saying how it
/// stands, and the padding around both.
fn wanted(shape: mines.Shape) struct { w: u16, h: u16 } {
    const t = theme.current();
    return .{
        .w = @intCast(@as(i32, shape.columns) * CELL + t.padding * 2),
        .h = @intCast(@as(i32, shape.rows) * CELL + statusHeight() + t.padding * 2),
    };
}

fn statusHeight() i32 {
    return eui.Surface.textHeight() + theme.current().padding;
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

fn draw() void {
    const t = theme.current();
    const surface = ctx.surface;
    const whole = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };
    if (ctx.damaged) surface.fill(whole, t.surface);

    const status = Rect{
        .x = whole.x + t.padding,
        .y = whole.y + t.padding,
        .w = whole.w - t.padding * 2,
        .h = eui.Surface.textHeight(),
    };
    drawStatus(status);
    play(gridArea(whole, status));
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
/// in what the status line leaves.
fn gridArea(whole: Rect, status: Rect) Rect {
    const t = theme.current();
    const across = @divTrunc(whole.w - t.padding * 2, @as(i32, board.shape.columns));
    const down = @divTrunc(whole.bottom() - status.bottom() - t.padding * 2, @as(i32, board.shape.rows));
    const side = @max(@min(@min(across, down), CELL), 1);

    const w = side * @as(i32, board.shape.columns);
    const h = side * @as(i32, board.shape.rows);
    return .{
        .x = whole.x + @divTrunc(whole.w - w, 2),
        .y = status.bottom() + t.padding + @divTrunc(whole.bottom() - status.bottom() - t.padding - h, 2),
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
    const t = theme.current();
    const cell = board.at(column, row);

    const whole = Rect{
        .x = area.x + @as(i32, column) * side,
        .y = area.y + @as(i32, row) * side,
        .w = side,
        .h = side,
    };
    // The hairline between cells is the ground showing through, which is
    // one fill rather than a line drawn on four edges.
    ctx.surface.fill(whole, t.line);
    const face = Rect{ .x = whole.x, .y = whole.y, .w = side - 1, .h = side - 1 };
    // Opened cells are the lighter face and shut ones the darker: at this
    // size a border tells them apart at a glance and a shade does not.
    ctx.surface.fill(face, if (cell.revealed) t.surface_hot else t.surface_pressed);

    if (cell.flagged) {
        ctx.surface.iconCentred(face, .flag, t.accent);
    } else if (cell.revealed and cell.mine) {
        ctx.surface.iconCentred(face, .mine, t.warning);
    } else if (cell.revealed and cell.around != 0) {
        const digit = [_]u8{'0' + @as(u8, cell.around)};
        ctx.surface.text(
            face.x + @divTrunc(face.w - eui.Surface.textWidth(&digit), 2),
            face.y + @divTrunc(face.h - eui.Surface.textHeight(), 2),
            &digit,
            t.text,
        );
    }

    if (column == cursor_column and row == cursor_row) {
        const inside = Rect{ .x = face.x + 1, .y = face.y + 1, .w = face.w - 2, .h = face.h - 2 };
        ctx.surface.fillAround(face, inside, t.accent);
    }
}

// ---------------------------------------------------------------------------
// Keys
// ---------------------------------------------------------------------------

fn key(code: KeyCode, mods: Modifiers) bool {
    _ = mods;
    switch (code) {
        .left => step(-1, 0),
        .right => step(1, 0),
        .up => step(0, -1),
        .down => step(0, 1),
        .space, .enter => _ = board.reveal(cursor_column, cursor_row, prng.random()),
        .f => _ = board.flag(cursor_column, cursor_row),
        .r => board.restart(),
        .n1 => choose(.beginner),
        .n2 => choose(.intermediate),
        .n3 => choose(.expert),
        else => return false,
    }
    ctx.damage();
    return true;
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

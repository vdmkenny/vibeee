//! Minesweeper's board: where the mines are, what a cell shows, and what a
//! move comes to.
//!
//! The mines are laid on the first reveal, around the cell that opened the
//! board, so an opening move never ends the game and always opens a space.
//! A cell with no mine beside it opens its neighbours, and they theirs, out
//! to the numbered edge of the space.
//!
//! Pure, and tested on the host: a game of this is a board and the moves
//! made on it, and none of it needs a screen.

const std = @import("std");

/// The grids a game is played on, and what each holds.
pub const Difficulty = enum {
    beginner,
    intermediate,
    expert,

    pub fn shape(self: Difficulty) Shape {
        return switch (self) {
            .beginner => .{ .columns = 9, .rows = 9, .mines = 10 },
            .intermediate => .{ .columns = 16, .rows = 16, .mines = 40 },
            .expert => .{ .columns = 30, .rows = 16, .mines = 99 },
        };
    }
};

/// A grid and the mines hidden in it.
pub const Shape = struct {
    columns: u8,
    rows: u8,
    mines: u16,

    pub fn cells(self: Shape) usize {
        return @as(usize, self.columns) * self.rows;
    }
};

/// The largest grid, which is the expert one. Every board carries room for
/// it, so a game changes difficulty without allocating.
pub const MAX_COLUMNS: u8 = 30;
pub const MAX_ROWS: u8 = 16;
pub const MAX_CELLS: usize = @as(usize, MAX_COLUMNS) * MAX_ROWS;

/// What one cell is and what has been done to it.
pub const Cell = packed struct(u8) {
    mine: bool = false,
    revealed: bool = false,
    flagged: bool = false,
    /// Mines in the eight cells around it.
    around: u4 = 0,
    _7: u1 = 0,
};

/// Where a game stands.
pub const State = enum {
    /// No move made, so no mine is laid.
    fresh,
    playing,
    won,
    lost,

    pub fn over(self: State) bool {
        return self == .won or self == .lost;
    }
};

/// What a move came to. A move on a cell that cannot take one is `nothing`.
pub const Move = enum { nothing, opened, flagged, unflagged, won, lost };

pub const Board = struct {
    shape: Shape,
    state: State = .fresh,
    cells: [MAX_CELLS]Cell = @splat(.{}),
    /// Cells without a mine that are revealed, which is what winning counts.
    opened: u16 = 0,
    flags: u16 = 0,

    pub fn init(difficulty: Difficulty) Board {
        return .{ .shape = difficulty.shape() };
    }

    /// The board again, empty, on the same grid.
    pub fn restart(self: *Board) void {
        self.* = .{ .shape = self.shape };
    }

    pub fn at(self: *const Board, column: u8, row: u8) Cell {
        return self.cells[self.index(column, row)];
    }

    pub fn index(self: *const Board, column: u8, row: u8) usize {
        return @as(usize, row) * self.shape.columns + column;
    }

    pub fn inside(self: *const Board, column: i32, row: i32) bool {
        return column >= 0 and row >= 0 and
            column < self.shape.columns and row < self.shape.rows;
    }

    /// Mines not yet accounted for by a flag. Negative when more cells are
    /// flagged than the grid holds mines.
    pub fn remaining(self: *const Board) i32 {
        return @as(i32, self.shape.mines) - self.flags;
    }

    /// Turn a cell's flag on or off. Only a hidden cell takes one.
    pub fn flag(self: *Board, column: u8, row: u8) Move {
        if (self.state.over()) return .nothing;
        const cell = &self.cells[self.index(column, row)];
        if (cell.revealed) return .nothing;
        cell.flagged = !cell.flagged;
        if (cell.flagged) {
            self.flags += 1;
            return .flagged;
        }
        self.flags -= 1;
        return .unflagged;
    }

    /// Open a cell. The first one opened lays the mines around itself, so it
    /// is always a space rather than a number or a mine.
    pub fn reveal(self: *Board, column: u8, row: u8, random: std.Random) Move {
        if (self.state.over()) return .nothing;
        const first = self.index(column, row);
        if (self.cells[first].revealed or self.cells[first].flagged) return .nothing;

        if (self.state == .fresh) {
            self.lay(column, row, random);
            self.state = .playing;
        }

        if (self.cells[first].mine) {
            self.state = .lost;
            self.revealMines();
            return .lost;
        }

        self.open(column, row);
        if (self.opened == self.shape.cells() - self.shape.mines) {
            self.state = .won;
            self.flagMines();
            return .won;
        }
        return .opened;
    }

    /// Open a cell and, where it has no mine beside it, everything its
    /// space reaches. Iterative: a space on the expert grid runs deeper
    /// than a comfortable stack.
    fn open(self: *Board, column: u8, row: u8) void {
        var pending: [MAX_CELLS]u16 = undefined;
        var queued: usize = 0;
        self.show(@intCast(self.index(column, row)), &pending, &queued);

        while (queued > 0) {
            queued -= 1;
            const at_index = pending[queued];
            const spread_column: i32 = @intCast(at_index % self.shape.columns);
            const spread_row: i32 = @intCast(at_index / self.shape.columns);
            for (AROUND) |step| {
                const near_column = spread_column + step.column;
                const near_row = spread_row + step.row;
                if (!self.inside(near_column, near_row)) continue;
                self.show(@intCast(self.index(@intCast(near_column), @intCast(near_row))), &pending, &queued);
            }
        }
    }

    /// Reveal one cell, and queue it when the space carries on through it.
    /// Revealed as it is queued, so no cell is queued twice and the queue
    /// holds at most the grid.
    fn show(self: *Board, where: u16, pending: []u16, queued: *usize) void {
        const cell = &self.cells[where];
        if (cell.revealed or cell.flagged) return;
        cell.revealed = true;
        self.opened += 1;
        if (cell.around != 0) return;
        pending[queued.*] = where;
        queued.* += 1;
    }

    /// Lay the mines, anywhere but the opening cell and the ring around it,
    /// then count each cell's neighbours.
    fn lay(self: *Board, column: u8, row: u8, random: std.Random) void {
        const total = self.shape.cells();
        var laid: u16 = 0;
        while (laid < self.shape.mines) {
            const where = random.uintLessThan(usize, total);
            const cell = &self.cells[where];
            if (cell.mine) continue;
            const mine_column: i32 = @intCast(where % self.shape.columns);
            const mine_row: i32 = @intCast(where / self.shape.columns);
            if (@abs(mine_column - @as(i32, column)) <= 1 and
                @abs(mine_row - @as(i32, row)) <= 1) continue;
            cell.mine = true;
            laid += 1;
        }

        for (0..self.shape.rows) |counted_row| {
            for (0..self.shape.columns) |counted_column| {
                const cell = &self.cells[self.index(@intCast(counted_column), @intCast(counted_row))];
                cell.around = self.count(@intCast(counted_column), @intCast(counted_row));
            }
        }
    }

    /// Mines in the eight cells around one.
    fn count(self: *const Board, column: u8, row: u8) u4 {
        var found: u4 = 0;
        for (AROUND) |step| {
            const near_column = @as(i32, column) + step.column;
            const near_row = @as(i32, row) + step.row;
            if (!self.inside(near_column, near_row)) continue;
            if (self.cells[self.index(@intCast(near_column), @intCast(near_row))].mine) found += 1;
        }
        return found;
    }

    /// Every mine that was not called shown, which is what a lost board
    /// looks like. A flagged one stays flagged: it is already marked, and a
    /// cell is never both.
    fn revealMines(self: *Board) void {
        for (self.cells[0..self.shape.cells()]) |*cell| {
            if (cell.mine and !cell.flagged) cell.revealed = true;
        }
    }

    /// Every mine flagged, so a won board reads as finished rather than as
    /// one flag short.
    fn flagMines(self: *Board) void {
        for (self.cells[0..self.shape.cells()]) |*cell| {
            if (cell.mine and !cell.flagged) {
                cell.flagged = true;
                self.flags += 1;
            }
        }
    }
};

/// The eight steps from a cell to its neighbours.
const AROUND = [8]struct { column: i32, row: i32 }{
    .{ .column = -1, .row = -1 },
    .{ .column = 0, .row = -1 },
    .{ .column = 1, .row = -1 },
    .{ .column = -1, .row = 0 },
    .{ .column = 1, .row = 0 },
    .{ .column = -1, .row = 1 },
    .{ .column = 0, .row = 1 },
    .{ .column = 1, .row = 1 },
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const fuzzing = @import("fuzzing.zig");
const testing = std.testing;
const Choices = fuzzing.Choices;

fn played(seed: u64) std.Random.DefaultPrng {
    return std.Random.DefaultPrng.init(seed);
}

/// A board laid out by hand: a grid, where its mines are, and the numbers
/// counted from them. Its shape declares exactly the mines placed, so the
/// win is the one the board can reach.
fn handmade(columns: u8, rows: u8, mines: []const [2]u8) Board {
    var board = Board{
        .shape = .{ .columns = columns, .rows = rows, .mines = @intCast(mines.len) },
        .state = .playing,
    };
    for (mines) |where| board.cells[board.index(where[0], where[1])].mine = true;
    for (0..rows) |row| {
        for (0..columns) |column| {
            const cell = &board.cells[board.index(@intCast(column), @intCast(row))];
            cell.around = board.count(@intCast(column), @intCast(row));
        }
    }
    return board;
}

/// The mines on a board, counted rather than trusted.
fn minesOn(board: *const Board) u16 {
    var found: u16 = 0;
    for (board.cells[0..board.shape.cells()]) |cell| {
        if (cell.mine) found += 1;
    }
    return found;
}

test "a cell is one byte, and a grid fits the room every board carries" {
    try testing.expectEqual(@as(usize, 1), @sizeOf(Cell));
    for (std.enums.values(Difficulty)) |difficulty| {
        const shape = difficulty.shape();
        try testing.expect(shape.columns <= MAX_COLUMNS and shape.rows <= MAX_ROWS);
        // A grid must hold its mines and leave the opening cell's ring free.
        try testing.expect(shape.mines + 9 <= shape.cells());
    }
}

test "the first cell opened is a space, and no mine is beside it" {
    for (std.enums.values(Difficulty)) |difficulty| {
        var prng = played(0x1E5);
        var board = Board.init(difficulty);
        try testing.expectEqual(State.fresh, board.state);

        const move = board.reveal(4, 4, prng.random());
        try testing.expectEqual(Move.opened, move);
        try testing.expectEqual(State.playing, board.state);
        try testing.expectEqual(difficulty.shape().mines, minesOn(&board));
        try testing.expect(!board.at(4, 4).mine);
        try testing.expectEqual(@as(u4, 0), board.at(4, 4).around);
        try testing.expect(board.at(4, 4).revealed);
    }
}

test "every cell's number is the mines around it" {
    var prng = played(0xC0FFEE);
    var board = Board.init(.intermediate);
    _ = board.reveal(8, 8, prng.random());

    for (0..board.shape.rows) |row| {
        for (0..board.shape.columns) |column| {
            const cell = board.at(@intCast(column), @intCast(row));
            try testing.expectEqual(board.count(@intCast(column), @intCast(row)), cell.around);
        }
    }
}

test "opening a space opens its neighbours, and a number opens only itself" {
    // One mine in the corner, so the cell beside it is a number and the rest
    // of the grid is one space.
    var board = handmade(9, 9, &.{.{ 0, 0 }});
    var prng = played(1);

    try testing.expectEqual(Move.opened, board.reveal(1, 1, prng.random()));
    try testing.expect(board.at(1, 1).revealed);
    try testing.expect(!board.at(2, 2).revealed);
    try testing.expectEqual(@as(u16, 1), board.opened);

    // The space reaches every cell but the mine.
    try testing.expectEqual(Move.won, board.reveal(5, 5, prng.random()));
    try testing.expectEqual(@as(u16, @intCast(board.shape.cells() - 1)), board.opened);
    try testing.expect(!board.at(0, 0).revealed);
}

test "a flag holds a cell shut, and counts against the mines" {
    var prng = played(7);
    var board = Board.init(.beginner);
    _ = board.reveal(4, 4, prng.random());

    var hidden: ?struct { column: u8, row: u8 } = null;
    for (0..board.shape.rows) |row| {
        for (0..board.shape.columns) |column| {
            if (!board.at(@intCast(column), @intCast(row)).revealed) {
                hidden = .{ .column = @intCast(column), .row = @intCast(row) };
            }
        }
    }
    const shut = hidden.?;

    try testing.expectEqual(Move.flagged, board.flag(shut.column, shut.row));
    try testing.expectEqual(@as(i32, 9), board.remaining());
    try testing.expectEqual(Move.nothing, board.reveal(shut.column, shut.row, prng.random()));
    try testing.expectEqual(Move.unflagged, board.flag(shut.column, shut.row));
    try testing.expectEqual(@as(i32, 10), board.remaining());
}

test "a mine ends the game, shows the others, and takes no further move" {
    var board = handmade(9, 9, &.{ .{ 0, 0 }, .{ 8, 8 } });
    var prng = played(3);

    try testing.expectEqual(Move.lost, board.reveal(0, 0, prng.random()));
    try testing.expectEqual(State.lost, board.state);
    try testing.expect(board.at(8, 8).revealed);
    try testing.expectEqual(Move.nothing, board.reveal(4, 4, prng.random()));
    try testing.expectEqual(Move.nothing, board.flag(4, 4));
}

test "a mine that was called stays a flag when the game is lost" {
    var board = handmade(9, 9, &.{ .{ 0, 0 }, .{ 8, 8 } });
    var prng = played(11);

    try testing.expectEqual(Move.flagged, board.flag(8, 8));
    try testing.expectEqual(Move.lost, board.reveal(0, 0, prng.random()));
    try testing.expect(board.at(8, 8).flagged);
    try testing.expect(!board.at(8, 8).revealed);
    try testing.expect(board.at(0, 0).revealed);
}

test "winning flags what is left, and a restart empties the board" {
    var board = handmade(9, 9, &.{.{ 0, 0 }});
    var prng = played(5);

    try testing.expectEqual(Move.won, board.reveal(5, 5, prng.random()));
    try testing.expectEqual(State.won, board.state);
    try testing.expect(board.at(0, 0).flagged);
    try testing.expectEqual(@as(i32, 0), board.remaining());

    board.restart();
    try testing.expectEqual(State.fresh, board.state);
    try testing.expectEqual(@as(u16, 0), board.opened);
    try testing.expectEqual(@as(u16, 0), minesOn(&board));
}

test "every move a board can answer is reachable" {
    var reached = std.EnumSet(Move).initEmpty();
    var prng = played(0xB0A2D);
    var board = Board.init(.beginner);

    reached.insert(board.reveal(4, 4, prng.random()));
    // The same cell again: opened already, so there is nothing to do.
    reached.insert(board.reveal(4, 4, prng.random()));
    for (0..board.shape.rows) |row| {
        for (0..board.shape.columns) |column| {
            if (board.at(@intCast(column), @intCast(row)).revealed) continue;
            reached.insert(board.flag(@intCast(column), @intCast(row)));
            reached.insert(board.flag(@intCast(column), @intCast(row)));
            break;
        }
    }

    // A game played to each of its ends.
    var lost = handmade(9, 9, &.{.{ 0, 0 }});
    reached.insert(lost.reveal(0, 0, prng.random()));

    var won = handmade(9, 9, &.{.{ 0, 0 }});
    reached.insert(won.reveal(5, 5, prng.random()));

    try testing.expect(reached.eql(std.EnumSet(Move).initFull()));
}

// ---------------------------------------------------------------------------
// Fuzzing: a game played at random
// ---------------------------------------------------------------------------

/// What the board says about itself, against what its cells hold. Null when
/// the two agree.
fn disagrees(board: *const Board) ?[]const u8 {
    var opened: u16 = 0;
    var flags: u16 = 0;
    var mines_laid: u16 = 0;
    var mines_shown: u16 = 0;
    var hidden_without_mine: u16 = 0;

    for (0..board.shape.rows) |row| {
        for (0..board.shape.columns) |column| {
            const cell = board.at(@intCast(column), @intCast(row));
            if (cell.mine) mines_laid += 1;
            if (cell.flagged) flags += 1;
            if (cell.revealed and cell.flagged) return "a cell is revealed and flagged at once";
            if (cell.revealed and cell.mine) mines_shown += 1;
            if (cell.revealed and !cell.mine) opened += 1;
            if (!cell.revealed and !cell.mine) hidden_without_mine += 1;
            if (cell.around != board.count(@intCast(column), @intCast(row))) {
                return "a cell's number is not the mines around it";
            }
        }
    }

    if (opened != board.opened) return "the count of opened cells is not what is opened";
    if (flags != board.flags) return "the count of flags is not what is flagged";

    switch (board.state) {
        .fresh => {
            if (mines_laid != 0) return "a board nobody has opened has mines laid";
            if (opened != 0) return "a board nobody has opened has an opened cell";
        },
        .playing => {
            if (mines_laid != board.shape.mines) return "the mines laid are not the grid's";
            if (mines_shown != 0) return "a game still being played shows a mine";
            if (hidden_without_mine == 0) return "every cell but the mines is open and the game goes on";
        },
        .won => {
            if (hidden_without_mine != 0) return "a game is won with a cell still shut";
            if (flags != board.shape.mines) return "a game is won with a mine unflagged";
        },
        .lost => {
            if (mines_shown == 0) return "a game is lost with no mine shown";
        },
    }
    return null;
}

fn playOneGame(from: Choices) anyerror!void {
    var board = Board.init(from.one(Difficulty));
    var prng = std.Random.DefaultPrng.init(from.int(u64));
    const random = prng.random();

    for (0..from.upTo(200)) |_| {
        const column: u8 = @intCast(from.below(board.shape.columns));
        const row: u8 = @intCast(from.below(board.shape.rows));
        const before = board.state;

        const move = if (from.odds(3))
            board.flag(column, row)
        else
            board.reveal(column, row, random);

        if (before.over()) {
            if (move != .nothing) return fail("a finished game took a move");
            if (board.state != before) return fail("a finished game changed");
        }
        if (disagrees(&board)) |why| return fail(why);
    }

    // Opening every cell that has no mine finishes any game that is still on.
    for (0..board.shape.rows) |row| {
        for (0..board.shape.columns) |column| {
            const at_column: u8 = @intCast(column);
            const at_row: u8 = @intCast(row);
            if (board.at(at_column, at_row).flagged) _ = board.flag(at_column, at_row);
            if (board.at(at_column, at_row).mine) continue;
            _ = board.reveal(at_column, at_row, random);
            if (disagrees(&board)) |why| return fail(why);
        }
    }
    if (board.state == .playing) return fail("a board with every safe cell open is still being played");
}

fn fail(why: []const u8) error{TestUnexpectedResult} {
    std.debug.print("mines: {s}\n", .{why});
    return error.TestUnexpectedResult;
}

test "fuzz: a game played at random keeps its own account, whatever is pressed" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            return playOneGame(.{ .fuzzer = smith });
        }
    };
    try std.testing.fuzz({}, Target.one, .{});
}

test "games played at random" {
    try fuzzing.seeded(playOneGame, 0x4D_1E5, 2000);
}

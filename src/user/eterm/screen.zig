//! The character grid a terminal draws, and the operations that change it.
//!
//! Separate from the escape parser so each can be read on its own: this file
//! knows what "scroll the region up by two" means and nothing about how a
//! program asks for it. It is also what makes the emulator testable on the
//! host, where there is no window to look at.

/// The largest grid worth allocating. At 800x480 with an 8x16 face the panel
/// holds 100 by 30; the headroom is for a larger screen, not for scrolling.
pub const MAX_COLS = 128;
pub const MAX_ROWS = 48;

/// Lines kept above the top of the screen. Deliberately modest: scrollback is
/// the largest thing a terminal allocates and the least often read.
pub const SCROLLBACK = 128;

pub const Style = packed struct(u16) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strike: bool = false,
    /// This cell carries its own foreground in `fg`. Clear means the theme's,
    /// which is the common case and, as the zero value, the one that costs
    /// nothing: a grid whose default cell is all zeroes lives in `.bss`
    /// instead of being a hundred kilobytes of spaces in the executable.
    has_fg: bool = false,
    has_bg: bool = false,
    _: u6 = 0,

    pub fn eql(self: Style, other: Style) bool {
        return @as(u16, @bitCast(self)) == @as(u16, @bitCast(other));
    }
};

/// Eight bytes, which is the whole reason for the packed style word: a grid
/// plus its alternate plus scrollback is the terminal's memory, and a cell
/// that grew by four bytes would add a hundred kilobytes to it.
pub const Cell = struct {
    /// Zero is blank, and so is a space: `Pen.cell` folds the two so an erased
    /// cell and a printed space compare equal.
    ch: u32 = 0,
    /// A 256-colour index, meaningful only when the matching bit in `style` is
    /// set.
    fg: u8 = 0,
    bg: u8 = 0,
    style: Style = .{},

    pub fn eql(self: Cell, other: Cell) bool {
        return self.ch == other.ch and self.fg == other.fg and
            self.bg == other.bg and self.style.eql(other.style);
    }
};

/// What a newly written cell takes: the colours and attributes in force.
pub const Pen = struct {
    fg: u8 = 0,
    bg: u8 = 0,
    style: Style = .{},

    pub fn cell(self: Pen, ch: u32) Cell {
        return .{
            .ch = if (ch == ' ') 0 else ch,
            .fg = self.fg,
            .bg = self.bg,
            .style = self.style,
        };
    }

    /// An erased cell. Keeps the background and drops everything else:
    /// painting a coloured region is done by setting a background and erasing,
    /// so dropping it would make that impossible, and keeping the rest would
    /// leave underlines across empty space.
    pub fn blank(self: Pen) Cell {
        return .{
            .bg = self.bg,
            .style = .{ .has_bg = self.style.has_bg },
        };
    }
};

pub const Cursor = struct {
    row: usize = 0,
    col: usize = 0,
    pen: Pen = .{},
    /// The next character goes on the following line. Set when writing filled
    /// the last column rather than moving then: a program that writes the last
    /// column and follows it with a carriage return must not have scrolled.
    wrap_pending: bool = false,
};

pub const Grid = struct {
    cells: [MAX_ROWS * MAX_COLS]Cell = undefined,
    cols: usize = 0,
    rows: usize = 0,

    /// Zero the grid.
    ///
    /// Done here rather than by an initialiser on the field: a global with a
    /// written-out initial value is carried in the executable, and three grids
    /// of blank cells is a hundred and fifty kilobytes of nothing that has to
    /// be read off the disk and then kept resident. Set at startup instead, in
    /// a few instructions.
    pub fn init(self: *Grid) void {
        @memset(&self.cells, .{});
        self.cols = 0;
        self.rows = 0;
    }

    pub fn at(self: *Grid, r: usize, c: usize) *Cell {
        return &self.cells[r * MAX_COLS + c];
    }

    pub fn row(self: *Grid, r: usize) []Cell {
        return self.cells[r * MAX_COLS ..][0..self.cols];
    }

    pub fn clear(self: *Grid, fill: Cell) void {
        for (0..self.rows) |r| {
            @memset(self.row(r), fill);
        }
    }

    /// Move `count` lines of `top..=bottom` up, filling from the bottom.
    pub fn scrollUp(self: *Grid, top: usize, bottom: usize, count: usize, fill: Cell) void {
        if (count == 0 or top > bottom) return;
        const n = @min(count, bottom - top + 1);

        var r = top;
        while (r + n <= bottom) : (r += 1) {
            @memcpy(self.row(r), self.row(r + n));
        }
        while (r <= bottom) : (r += 1) {
            @memset(self.row(r), fill);
        }
    }

    /// The same downwards, which is what an insert-line does.
    pub fn scrollDown(self: *Grid, top: usize, bottom: usize, count: usize, fill: Cell) void {
        if (count == 0 or top > bottom) return;
        const n = @min(count, bottom - top + 1);

        var r = bottom + 1;
        while (r > top + n) {
            r -= 1;
            @memcpy(self.row(r), self.row(r - n));
        }
        while (r > top) {
            r -= 1;
            @memset(self.row(r), fill);
        }
    }

    /// Shift a row's tail left, for delete-character.
    pub fn deleteChars(self: *Grid, r: usize, col: usize, count: usize, fill: Cell) void {
        const line = self.row(r);
        const n = @min(count, line.len - col);

        var i = col;
        while (i + n < line.len) : (i += 1) line[i] = line[i + n];
        while (i < line.len) : (i += 1) line[i] = fill;
    }

    /// Shift a row's tail right, for insert-character.
    pub fn insertChars(self: *Grid, r: usize, col: usize, count: usize, fill: Cell) void {
        const line = self.row(r);
        const n = @min(count, line.len - col);

        var i = line.len;
        while (i > col + n) {
            i -= 1;
            line[i] = line[i - n];
        }
        while (i > col) {
            i -= 1;
            line[i] = fill;
        }
    }
};

//! A terminal screen as a grid of cells: drawn into, then written out as ANSI
//! text in one pass. Colours and borders follow the Linux menuconfig look.

const std = @import("std");

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,

    /// `size` centred in this rectangle.
    pub fn centred(self: Rect, w: i32, h: i32) Rect {
        return .{ .x = self.x + @divTrunc(self.w - w, 2), .y = self.y + @divTrunc(self.h - h, 2), .w = w, .h = h };
    }

    /// This rectangle less `by` cells on every side.
    pub fn inset(self: Rect, by: i32) Rect {
        return .{ .x = self.x + by, .y = self.y + by, .w = self.w - 2 * by, .h = self.h - 2 * by };
    }
};

pub const Point = struct { x: i32, y: i32 };

/// The eight ANSI colours, numbered as the escape codes number them.
pub const Colour = enum(u3) { black, red, green, yellow, blue, magenta, cyan, white };

const Look = struct {
    fg: Colour,
    bg: Colour,
    bold: bool = false,
};

pub const Style = enum {
    backdrop,
    shadow,
    dialog,
    title,
    selected,
    key,
    key_selected,
    button_key,

    fn look(self: Style) Look {
        return switch (self) {
            .backdrop => .{ .fg = .cyan, .bg = .blue, .bold = true },
            .shadow => .{ .fg = .black, .bg = .black },
            .dialog => .{ .fg = .black, .bg = .white },
            .title, .key => .{ .fg = .blue, .bg = .white, .bold = true },
            .selected => .{ .fg = .white, .bg = .blue, .bold = true },
            .key_selected => .{ .fg = .yellow, .bg = .blue, .bold = true },
            .button_key => .{ .fg = .red, .bg = .white, .bold = true },
        };
    }
};

pub const Cell = struct {
    char: u21 = ' ',
    style: Style = .backdrop,
};

const Line = enum(u21) {
    horizontal = '─',
    vertical = '│',
    top_left = '┌',
    top_right = '┐',
    bottom_left = '└',
    bottom_right = '┘',
    tee_left = '├',
    tee_right = '┤',
};

const CSI = "\x1b[";

pub const Screen = struct {
    cols: i32,
    rows: i32,
    cells: []Cell,
    /// Where the terminal shows its cursor, for a field being typed into.
    cursor: ?Point = null,

    /// A screen over `cells`, which holds at least `cols * rows`.
    pub fn init(cells: []Cell, cols: u16, rows: u16) Screen {
        std.debug.assert(cells.len >= @as(usize, cols) * rows);
        var screen: Screen = .{ .cols = cols, .rows = rows, .cells = cells[0 .. @as(usize, cols) * rows] };
        screen.fill(screen.whole(), ' ', .backdrop);
        return screen;
    }

    pub fn whole(self: *const Screen) Rect {
        return .{ .x = 0, .y = 0, .w = self.cols, .h = self.rows };
    }

    pub fn at(self: *const Screen, x: i32, y: i32) ?*Cell {
        if (x < 0 or y < 0 or x >= self.cols or y >= self.rows) return null;
        return &self.cells[@intCast(y * self.cols + x)];
    }

    pub fn put(self: *Screen, x: i32, y: i32, char: u21, style: Style) void {
        const cell = self.at(x, y) orelse return;
        cell.* = .{ .char = char, .style = style };
    }

    /// Restyle a cell, keeping its character.
    pub fn paint(self: *Screen, x: i32, y: i32, style: Style) void {
        const cell = self.at(x, y) orelse return;
        cell.style = style;
    }

    pub fn fill(self: *Screen, area: Rect, char: u21, style: Style) void {
        var y = area.y;
        while (y < area.y + area.h) : (y += 1) {
            var x = area.x;
            while (x < area.x + area.w) : (x += 1) self.put(x, y, char, style);
        }
    }

    /// Up to `width` characters of `s` from `x`. Returns how many it laid out,
    /// whether or not the screen's edge clipped them.
    pub fn text(self: *Screen, x: i32, y: i32, s: []const u8, style: Style, width: i32) i32 {
        var drawn: i32 = 0;
        var chars = (std.unicode.Utf8View.init(s) catch return 0).iterator();
        while (drawn < width) : (drawn += 1) {
            const char = chars.nextCodepoint() orelse break;
            self.put(x + drawn, y, char, style);
        }
        return drawn;
    }

    /// A border around `area`, in the dialog's ink so it shows in any theme.
    pub fn box(self: *Screen, area: Rect) void {
        const right = area.x + area.w - 1;
        const bottom = area.y + area.h - 1;
        var x = area.x + 1;
        while (x < right) : (x += 1) {
            self.put(x, area.y, @intFromEnum(Line.horizontal), .dialog);
            self.put(x, bottom, @intFromEnum(Line.horizontal), .dialog);
        }
        var y = area.y + 1;
        while (y < bottom) : (y += 1) {
            self.put(area.x, y, @intFromEnum(Line.vertical), .dialog);
            self.put(right, y, @intFromEnum(Line.vertical), .dialog);
        }
        self.put(area.x, area.y, @intFromEnum(Line.top_left), .dialog);
        self.put(right, area.y, @intFromEnum(Line.top_right), .dialog);
        self.put(area.x, bottom, @intFromEnum(Line.bottom_left), .dialog);
        self.put(right, bottom, @intFromEnum(Line.bottom_right), .dialog);
    }

    /// A dialog: a box filled with the dialog colour, its shadow, and its title
    /// in the top edge.
    pub fn dialog(self: *Screen, area: Rect, title: []const u8) void {
        self.fill(.{ .x = area.x + 2, .y = area.y + area.h, .w = area.w, .h = 1 }, ' ', .shadow);
        self.fill(.{ .x = area.x + area.w, .y = area.y + 1, .w = 2, .h = area.h }, ' ', .shadow);
        self.fill(area, ' ', .dialog);
        self.box(area);
        if (title.len == 0) return;
        const room = area.w - 4;
        const width = @min(room, @as(i32, @intCast(std.unicode.utf8CountCodepoints(title) catch title.len)));
        const left = area.x + @divTrunc(area.w - width - 2, 2);
        self.put(left, area.y, ' ', .title);
        _ = self.text(left + 1, area.y, title, .title, width);
        self.put(left + 1 + width, area.y, ' ', .title);
    }

    /// The rule across a dialog above its buttons, at row `y`.
    pub fn divider(self: *Screen, area: Rect, y: i32) void {
        self.put(area.x, y, @intFromEnum(Line.tee_left), .dialog);
        var x = area.x + 1;
        while (x < area.x + area.w - 1) : (x += 1) self.put(x, y, @intFromEnum(Line.horizontal), .dialog);
        self.put(area.x + area.w - 1, y, @intFromEnum(Line.tee_right), .dialog);
    }

    /// Word-wrapped `s` inside `area`, from its top. Returns the rows used.
    pub fn paragraph(self: *Screen, area: Rect, s: []const u8, style: Style) i32 {
        var lines = wrap(s, @intCast(@max(area.w, 1)));
        var y: i32 = 0;
        while (lines.next()) |one| : (y += 1) {
            if (y < area.h) _ = self.text(area.x, area.y + y, one, style, area.w);
        }
        return y;
    }

    /// Write the screen out: every row positioned, colours changed only where
    /// they change, then the cursor shown where a field wants it. `fresh`
    /// clears the terminal first, for a first frame or one of another size:
    /// a smaller frame would leave the edges of the last one around it.
    pub fn write(self: *const Screen, out: *std.Io.Writer, fresh: bool) std.Io.Writer.Error!void {
        try out.writeAll(CSI ++ "?25l");
        if (fresh) try out.writeAll(CSI ++ "0m" ++ CSI ++ "2J");
        var current: ?Style = null;
        var y: i32 = 0;
        while (y < self.rows) : (y += 1) {
            try out.print(CSI ++ "{d};1H", .{y + 1});
            for (self.cells[@intCast(y * self.cols)..][0..@intCast(self.cols)]) |cell| {
                if (current != cell.style) {
                    const look = cell.style.look();
                    try out.print(CSI ++ "0;{s}3{d};4{d}m", .{ if (look.bold) "1;" else "", @intFromEnum(look.fg), @intFromEnum(look.bg) });
                    current = cell.style;
                }
                var utf8: [4]u8 = undefined;
                const len = std.unicode.utf8Encode(cell.char, &utf8) catch {
                    try out.writeByte('?');
                    continue;
                };
                try out.writeAll(utf8[0..len]);
            }
        }
        try out.writeAll(CSI ++ "0m");
        if (self.cursor) |cursor| try out.print(CSI ++ "{d};{d}H" ++ CSI ++ "?25h", .{ cursor.y + 1, cursor.x + 1 });
    }
};

/// The lines of `s` wrapped at `width` characters: at spaces where it can, mid
/// word where a word is wider than the line, and at every newline.
pub fn wrap(s: []const u8, width: usize) Lines {
    return .{ .rest = s, .width = width };
}

pub const Lines = struct {
    rest: []const u8,
    width: usize,
    done: bool = false,

    pub fn next(self: *Lines) ?[]const u8 {
        if (self.done) return null;
        const end_of_line = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
        const line = self.rest[0..end_of_line];

        const cut = cutAt(line, self.width);
        const taken = line[0..cut.len];
        if (cut.len == line.len) {
            if (end_of_line == self.rest.len) {
                self.done = true;
            } else {
                self.rest = self.rest[end_of_line + 1 ..];
            }
        } else {
            self.rest = self.rest[cut.resume_at..];
        }
        return std.mem.trimEnd(u8, taken, " ");
    }

    const Cut = struct { len: usize, resume_at: usize };

    /// Where to end the first row of `line`, counted in bytes, and where the
    /// next row starts.
    fn cutAt(line: []const u8, width: usize) Cut {
        var chars: usize = 0;
        var last_space: ?usize = null;
        var i: usize = 0;
        while (i < line.len) {
            if (chars == width) {
                if (line[i] == ' ') return .{ .len = i, .resume_at = i + 1 };
                if (last_space) |space| return .{ .len = space, .resume_at = space + 1 };
                return .{ .len = i, .resume_at = i };
            }
            if (line[i] == ' ') last_space = i;
            i += std.unicode.utf8ByteSequenceLength(line[i]) catch 1;
            chars += 1;
        }
        return .{ .len = line.len, .resume_at = line.len };
    }
};

const testing = std.testing;

/// The characters of row `y`, as UTF-8.
fn rowText(screen: *const Screen, y: i32, into: []u8) []const u8 {
    var len: usize = 0;
    for (screen.cells[@intCast(y * screen.cols)..][0..@intCast(screen.cols)]) |cell| {
        len += std.unicode.utf8Encode(cell.char, into[len..]) catch unreachable;
    }
    return into[0..len];
}

test "a dialog is a box with its title centred in the top edge" {
    var cells: [20 * 6]Cell = undefined;
    var screen = Screen.init(&cells, 20, 6);
    screen.dialog(.{ .x = 1, .y = 1, .w = 16, .h = 4 }, "Hi");

    var row: [80]u8 = undefined;
    try testing.expectEqualStrings(" ┌───── Hi ─────┐   ", rowText(&screen, 1, &row));
    try testing.expectEqualStrings(" │              │   ", rowText(&screen, 2, &row));
    try testing.expectEqualStrings(" └──────────────┘   ", rowText(&screen, 4, &row));
    try testing.expectEqual(Style.dialog, screen.at(1, 2).?.style);
    try testing.expectEqual(Style.dialog, screen.at(16, 2).?.style);
    try testing.expectEqual(Style.shadow, screen.at(17, 2).?.style);
    try testing.expectEqual(Style.shadow, screen.at(3, 5).?.style);
}

test "drawing off the screen is clipped" {
    var cells: [4 * 2]Cell = undefined;
    var screen = Screen.init(&cells, 4, 2);
    screen.box(.{ .x = -2, .y = -3, .w = 8, .h = 4 });
    try testing.expectEqual(@as(i32, 6), screen.text(2, 0, "abcdef", .dialog, 10));

    var row: [16]u8 = undefined;
    try testing.expectEqualStrings("──ab", rowText(&screen, 0, &row));
}

test "text wraps at spaces, splits a word wider than the line, and keeps newlines" {
    const Case = struct { s: []const u8, width: usize, lines: []const []const u8 };
    const cases = [_]Case{
        .{ .s = "one two three", .width = 7, .lines = &.{ "one two", "three" } },
        .{ .s = "abcdefghij", .width = 4, .lines = &.{ "abcd", "efgh", "ij" } },
        .{ .s = "one\n\ntwo", .width = 10, .lines = &.{ "one", "", "two" } },
        .{ .s = "", .width = 10, .lines = &.{""} },
        .{ .s = "é é é", .width = 3, .lines = &.{ "é é", "é" } },
    };
    for (cases) |case| {
        var lines = wrap(case.s, case.width);
        for (case.lines) |want| try testing.expectEqualStrings(want, lines.next().?);
        try testing.expectEqual(@as(?[]const u8, null), lines.next());
    }
}

test "the screen is written row by row with colours only where they change" {
    var cells: [3 * 1]Cell = undefined;
    var screen = Screen.init(&cells, 3, 1);
    screen.put(1, 0, 'x', .selected);
    screen.put(2, 0, 'y', .selected);
    screen.cursor = .{ .x = 2, .y = 0 };

    var room: [256]u8 = undefined;
    var out: std.Io.Writer = .fixed(&room);
    try screen.write(&out, false);
    try testing.expectEqualStrings(
        "\x1b[?25l\x1b[1;1H\x1b[0;1;36;44m \x1b[0;1;37;44mxy\x1b[0m\x1b[1;3H\x1b[?25h",
        out.buffered(),
    );

    out = .fixed(&room);
    try screen.write(&out, true);
    try testing.expect(std.mem.startsWith(u8, out.buffered(), "\x1b[?25l\x1b[0m\x1b[2J\x1b[1;1H"));
}

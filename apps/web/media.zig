//! A stylesheet as it reads in a window: which of its `@media` blocks are for
//! the window, and the sheet with those put in place and the rest left out.
//!
//! Upstream reads the rules inside such a block and keeps what the block is
//! for as the words the sheet wrote, unread, so they are read here. A query is
//! asked of the window a page is drawn in, measured in the page's own pixels,
//! on a screen of colour driven with a pointer that hovers, by a reader that
//! runs no scripts. A question it cannot answer is not this window, which is
//! what the specification makes of a feature it does not know, and with no
//! window at all, a question about its size is one it cannot answer.
//!
//! A page is always told its colours are to be light. A dark theme turns the
//! page's own colours over itself, and a page that had done so as well would
//! be turned back.
//!
//! Pure and host-tested.

const std = @import("std");

const Writer = std.Io.Writer;

/// The window a query is asked about.
pub const Screen = struct {
    /// How wide and how tall it is, in the page's own pixels.
    width: f32,
    height: f32,
    /// How many of the screen's pixels one of the page's is drawn as.
    scale: f32 = 1,
};

/// Whether the queries written as `prelude` are for `screen`: any one of them
/// that is, and every window for none at all. One that cannot be read is not,
/// and does not spoil the rest.
pub fn matches(prelude: []const u8, screen: ?Screen) bool {
    return evaluate(prelude, screen) == .yes;
}

/// Whether the queries could be for a window of some size: what decides
/// whether a stylesheet is worth fetching before the window a page will be
/// drawn in is known, and whatever size it comes to be.
pub fn couldMatch(prelude: []const u8) bool {
    return evaluate(prelude, null) != .no;
}

fn evaluate(prelude: []const u8, screen: ?Screen) Truth {
    if (std.mem.trim(u8, prelude, &std.ascii.whitespace).len == 0) return .yes;
    var lexer = Lexer{ .text = prelude };
    var truth: Truth = .no;
    while (true) {
        var reader = Reader{ .lexer = &lexer, .screen = screen };
        var one = reader.query() orelse .no;
        if (!reader.ended()) one = .no;
        truth = truth.either(one);
        if (truth == .yes or !lexer.pastComma()) return truth;
    }
}

/// The answer to a condition. A feature not known is neither true nor false,
/// and neither is what it is part of: `not` of it is still not known, and a
/// query that comes to it is not this window.
const Truth = enum {
    yes,
    no,
    unknown,

    fn of(value: bool) Truth {
        return if (value) .yes else .no;
    }

    fn negated(self: Truth) Truth {
        return switch (self) {
            .yes => .no,
            .no => .yes,
            .unknown => .unknown,
        };
    }

    fn both(self: Truth, other: Truth) Truth {
        if (self == .no or other == .no) return .no;
        if (self == .unknown or other == .unknown) return .unknown;
        return .yes;
    }

    fn either(self: Truth, other: Truth) Truth {
        if (self == .yes or other == .yes) return .yes;
        if (self == .unknown or other == .unknown) return .unknown;
        return .no;
    }
};

// ---------------------------------------------------------------------------
// Reading a query
// ---------------------------------------------------------------------------

const Token = union(enum) {
    ident: []const u8,
    number: Number,
    /// A name and its opening bracket: `calc(`.
    function: []const u8,
    open,
    close,
    comma,
    colon,
    slash,
    plus,
    minus,
    star,
    compare: Compare,
    end,
    other,

    const Number = struct { value: f32, unit: []const u8 };
};

const Compare = enum { lt, le, gt, ge, eq };

const Lexer = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *Lexer) Token {
        self.skipSpace();
        if (self.at == self.text.len) return .end;
        const c = self.text[self.at];
        if (std.ascii.isDigit(c) or (c == '.' and self.digitAt(self.at + 1))) return self.number();
        if (identStart(c) or (c == '-' and self.at + 1 < self.text.len and identStart(self.text[self.at + 1]))) {
            const start = self.at;
            while (self.at < self.text.len and identPart(self.text[self.at])) self.at += 1;
            const name = self.text[start..self.at];
            if (self.at < self.text.len and self.text[self.at] == '(') {
                self.at += 1;
                return .{ .function = name };
            }
            return .{ .ident = name };
        }
        self.at += 1;
        return switch (c) {
            '(' => .open,
            ')' => .close,
            ',' => .comma,
            ':' => .colon,
            '/' => .slash,
            '+' => .plus,
            '-' => .minus,
            '*' => .star,
            '=' => .{ .compare = .eq },
            '<', '>' => {
                const equal = self.at < self.text.len and self.text[self.at] == '=';
                if (equal) self.at += 1;
                return .{ .compare = if (c == '<') (if (equal) .le else .lt) else if (equal) .ge else .gt };
            },
            else => .other,
        };
    }

    fn peek(self: *const Lexer) Token {
        var copy = self.*;
        return copy.next();
    }

    /// Past the comma that ends the query being read, outside any brackets.
    /// False where the list ends first.
    fn pastComma(self: *Lexer) bool {
        var depth: usize = 0;
        while (true) switch (self.next()) {
            .end => return false,
            .open, .function => depth += 1,
            .close => depth -|= 1,
            .comma => if (depth == 0) return true,
            else => {},
        };
    }

    fn number(self: *Lexer) Token {
        const start = self.at;
        self.at = std.mem.indexOfNonePos(u8, self.text, start, "0123456789.") orelse self.text.len;
        const value = std.fmt.parseFloat(f32, self.text[start..self.at]) catch 0;
        const unit_start = self.at;
        if (self.at < self.text.len and self.text[self.at] == '%') {
            self.at += 1;
        } else {
            while (self.at < self.text.len and std.ascii.isAlphabetic(self.text[self.at])) self.at += 1;
        }
        return .{ .number = .{ .value = value, .unit = self.text[unit_start..self.at] } };
    }

    fn skipSpace(self: *Lexer) void {
        while (self.at < self.text.len) {
            if (std.ascii.isWhitespace(self.text[self.at])) {
                self.at += 1;
            } else if (std.mem.startsWith(u8, self.text[self.at..], "/*")) {
                self.at = skip(self.text, self.at);
            } else return;
        }
    }

    fn digitAt(self: *const Lexer, at: usize) bool {
        return at < self.text.len and std.ascii.isDigit(self.text[at]);
    }

    fn identStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
    }

    fn identPart(c: u8) bool {
        return identStart(c) or std.ascii.isDigit(c) or c == '-';
    }
};

/// Reads one query of a list and answers it. Null for one that is not
/// written the way a query is.
const Reader = struct {
    lexer: *Lexer,
    screen: ?Screen,

    /// Whether the query read ended where a query does.
    fn ended(self: *const Reader) bool {
        return switch (self.lexer.peek()) {
            .end, .comma => true,
            else => false,
        };
    }

    fn query(self: *Reader) ?Truth {
        switch (self.lexer.peek()) {
            .open => return self.condition(),
            .ident => |word| if (std.ascii.eqlIgnoreCase(word, "not") and self.bracketAfterWord()) return self.condition(),
            else => return null,
        }
        var word = self.lexer.next().ident;
        var negated = false;
        if (std.ascii.eqlIgnoreCase(word, "not") or std.ascii.eqlIgnoreCase(word, "only")) {
            negated = std.ascii.eqlIgnoreCase(word, "not");
            word = switch (self.lexer.next()) {
                .ident => |kind| kind,
                else => return null,
            };
        }
        var truth = Truth.of(std.ascii.eqlIgnoreCase(word, "screen") or std.ascii.eqlIgnoreCase(word, "all"));
        if (self.takeWord("and")) truth = truth.both(self.inParensAll() orelse return null);
        return if (negated) truth.negated() else truth;
    }

    /// A condition: one bracketed test, several joined by `and` or by `or`,
    /// or `not` and one.
    fn condition(self: *Reader) ?Truth {
        if (self.takeWord("not")) return (self.inParens() orelse return null).negated();
        var truth = self.inParens() orelse return null;
        if (self.wordIs("and")) {
            while (self.takeWord("and")) truth = truth.both(self.inParens() orelse return null);
        } else if (self.wordIs("or")) {
            while (self.takeWord("or")) truth = truth.either(self.inParens() orelse return null);
        }
        return truth;
    }

    /// Bracketed tests joined by `and`, which is all that may follow a kind
    /// of media.
    fn inParensAll(self: *Reader) ?Truth {
        var truth = self.inParens() orelse return null;
        while (self.takeWord("and")) truth = truth.both(self.inParens() orelse return null);
        return truth;
    }

    fn inParens(self: *Reader) ?Truth {
        if (self.lexer.next() != .open) return null;
        const inner = switch (self.lexer.peek()) {
            .open => self.condition(),
            .ident => |word| if (std.ascii.eqlIgnoreCase(word, "not") and self.bracketAfterWord()) self.condition() else self.feature(),
            else => self.feature(),
        } orelse return null;
        if (self.lexer.next() != .close) return null;
        return inner;
    }

    /// A test of one feature, inside its brackets: on its own, with a value
    /// after a colon, or compared with one or two values either side.
    fn feature(self: *Reader) ?Truth {
        switch (self.lexer.peek()) {
            .ident => {
                const name = self.lexer.next().ident;
                switch (self.lexer.peek()) {
                    .close => return present(name, self.screen),
                    .colon => {
                        _ = self.lexer.next();
                        return plain(name, self.value() orelse return null, self.screen);
                    },
                    .compare => |how| {
                        _ = self.lexer.next();
                        return ranged(name, how, self.value() orelse return null, self.screen);
                    },
                    else => return null,
                }
            },
            else => {
                // A value first: the feature after it is compared with it the
                // other way about.
                const low = self.value() orelse return null;
                const first = switch (self.lexer.next()) {
                    .compare => |how| how,
                    else => return null,
                };
                const name = switch (self.lexer.next()) {
                    .ident => |word| word,
                    else => return null,
                };
                var truth = ranged(name, flipped(first), low, self.screen);
                if (self.lexer.peek() == .compare) {
                    const second = self.lexer.next().compare;
                    truth = truth.both(ranged(name, second, self.value() orelse return null, self.screen));
                }
                return truth;
            },
        }
    }

    /// A value: a length or a number, a ratio, a word, or a `calc()` of
    /// lengths.
    fn value(self: *Reader) ?Value {
        switch (self.lexer.next()) {
            .ident => |word| return .{ .word = word },
            .number => |n| {
                if (n.unit.len == 0 and self.lexer.peek() == .slash) {
                    _ = self.lexer.next();
                    const under = switch (self.lexer.next()) {
                        .number => |d| d.value,
                        else => return null,
                    };
                    if (under == 0) return null;
                    return .{ .amount = .{ .value = n.value / under, .unit = "" } };
                }
                return .{ .amount = n };
            },
            .function => |name| {
                if (!std.ascii.eqlIgnoreCase(name, "calc")) return null;
                const start = self.lexer.*;
                if (self.sum()) |px| {
                    if (self.lexer.next() == .close) return .{ .amount = .{ .value = px, .unit = "px" } };
                }
                // Something in it cannot be measured, or it is not written
                // the way a sum is: either way, what it comes to is not known.
                self.lexer.* = start;
                if (!self.pastClose()) return null;
                return .unknown_length;
            },
            else => return null,
        }
    }

    /// Past the bracket that closes the one just opened. False where the
    /// text ends first.
    fn pastClose(self: *Reader) bool {
        var depth: usize = 0;
        while (true) switch (self.lexer.next()) {
            .end => return false,
            .open, .function => depth += 1,
            .close => if (depth == 0) return true else {
                depth -= 1;
            },
            else => {},
        };
    }

    /// The inside of a `calc()`: lengths added and taken away, and scaled by
    /// plain numbers, in pixels. Nothing where it measures what there is no
    /// window to measure, or is not written as a sum.
    fn sum(self: *Reader) ?f32 {
        var total = self.product() orelse return null;
        while (true) switch (self.lexer.peek()) {
            .plus => {
                _ = self.lexer.next();
                total += self.product() orelse return null;
            },
            .minus => {
                _ = self.lexer.next();
                total -= self.product() orelse return null;
            },
            else => return total,
        };
    }

    fn product(self: *Reader) ?f32 {
        var total = self.term() orelse return null;
        while (true) switch (self.lexer.peek()) {
            .star => {
                _ = self.lexer.next();
                total *= self.term() orelse return null;
            },
            .slash => {
                _ = self.lexer.next();
                const by = self.term() orelse return null;
                if (by == 0) return null;
                total /= by;
            },
            else => return total,
        };
    }

    fn term(self: *Reader) ?f32 {
        switch (self.lexer.next()) {
            .number => |n| return if (n.unit.len == 0) n.value else pixels(n, self.screen),
            .open => {},
            .function => |name| if (!std.ascii.eqlIgnoreCase(name, "calc")) return null,
            else => return null,
        }
        const inner = self.sum() orelse return null;
        return if (self.lexer.next() == .close) inner else null;
    }

    fn wordIs(self: *const Reader, word: []const u8) bool {
        return switch (self.lexer.peek()) {
            .ident => |seen| std.ascii.eqlIgnoreCase(seen, word),
            else => false,
        };
    }

    fn takeWord(self: *Reader, word: []const u8) bool {
        if (!self.wordIs(word)) return false;
        _ = self.lexer.next();
        return true;
    }

    /// Whether the word ahead is followed by a bracket: `not (` begins a
    /// condition, where `not screen` begins a query about a kind of media.
    fn bracketAfterWord(self: *const Reader) bool {
        var copy = self.lexer.*;
        _ = copy.next();
        return copy.next() == .open;
    }
};

/// The same comparison seen from the other side: `600px < width` is
/// `width > 600px`.
fn flipped(how: Compare) Compare {
    return switch (how) {
        .lt => .gt,
        .le => .ge,
        .gt => .lt,
        .ge => .le,
        .eq => .eq,
    };
}

const Value = union(enum) {
    amount: Token.Number,
    word: []const u8,
    /// A `calc()` whose length is not known: of what there is no window to
    /// measure, or not written as a sum.
    unknown_length,
};

/// A length in pixels, where its unit is one, and where what it is measured
/// against is known.
fn pixels(n: Token.Number, screen: ?Screen) ?f32 {
    const Unit = enum { px, em, rem, vw, vh, vmin, vmax, cm, mm, in, pt, pc };
    const units = std.StaticStringMapWithEql(Unit, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
        .{ "px", .px }, .{ "em", .em },     .{ "rem", .rem },   .{ "vw", .vw },
        .{ "vh", .vh }, .{ "vmin", .vmin }, .{ "vmax", .vmax }, .{ "cm", .cm },
        .{ "mm", .mm }, .{ "in", .in },     .{ "pt", .pt },     .{ "pc", .pc },
    });
    if (n.unit.len == 0) return if (n.value == 0) 0 else null;
    const scale: f32 = switch (units.get(n.unit) orelse return null) {
        .px => 1,
        // The size a page's text starts at, which is what an em in a query
        // is measured against.
        .em, .rem => 16,
        .vw => (screen orelse return null).width / 100,
        .vh => (screen orelse return null).height / 100,
        .vmin => @min((screen orelse return null).width, screen.?.height) / 100,
        .vmax => @max((screen orelse return null).width, screen.?.height) / 100,
        .cm => 96.0 / 2.54,
        .mm => 96.0 / 25.4,
        .in => 96,
        .pt => 96.0 / 72.0,
        .pc => 16,
    };
    return n.value * scale;
}

/// How many of the screen's pixels one of the page's is, from a resolution;
/// a bare number is already that.
fn dots(n: Token.Number) ?f32 {
    if (n.unit.len == 0 or std.ascii.eqlIgnoreCase(n.unit, "dppx") or std.ascii.eqlIgnoreCase(n.unit, "x")) return n.value;
    if (std.ascii.eqlIgnoreCase(n.unit, "dpi")) return n.value / 96;
    if (std.ascii.eqlIgnoreCase(n.unit, "dpcm")) return n.value * 2.54 / 96;
    return null;
}

// ---------------------------------------------------------------------------
// What the window is
// ---------------------------------------------------------------------------

const Feature = union(enum) {
    /// One measured on a scale.
    scale: Scale,
    /// One that is one of a few words.
    word: Word,

    const table = std.StaticStringMapWithEql(Feature, std.static_string_map.eqlAsciiIgnoreCase).initComptime(.{
        .{ "width", Feature{ .scale = .width } },
        .{ "device-width", Feature{ .scale = .width } },
        .{ "height", Feature{ .scale = .height } },
        .{ "device-height", Feature{ .scale = .height } },
        .{ "aspect-ratio", Feature{ .scale = .aspect_ratio } },
        .{ "device-aspect-ratio", Feature{ .scale = .aspect_ratio } },
        .{ "resolution", Feature{ .scale = .resolution } },
        .{ "device-pixel-ratio", Feature{ .scale = .resolution } },
        .{ "color", Feature{ .scale = .color } },
        .{ "color-index", Feature{ .scale = .color_index } },
        .{ "monochrome", Feature{ .scale = .monochrome } },
        .{ "grid", Feature{ .scale = .grid } },
        .{ "orientation", Feature{ .word = .orientation } },
        .{ "prefers-color-scheme", Feature{ .word = .prefers_color_scheme } },
        .{ "prefers-reduced-motion", Feature{ .word = .prefers_reduced_motion } },
        .{ "prefers-contrast", Feature{ .word = .prefers_contrast } },
        .{ "hover", Feature{ .word = .hover } },
        .{ "any-hover", Feature{ .word = .hover } },
        .{ "pointer", Feature{ .word = .pointer } },
        .{ "any-pointer", Feature{ .word = .pointer } },
        .{ "scripting", Feature{ .word = .scripting } },
        .{ "forced-colors", Feature{ .word = .forced_colors } },
        .{ "inverted-colors", Feature{ .word = .inverted_colors } },
        .{ "update", Feature{ .word = .update } },
        .{ "display-mode", Feature{ .word = .display_mode } },
        .{ "color-gamut", Feature{ .word = .color_gamut } },
        .{ "dynamic-range", Feature{ .word = .dynamic_range } },
    });
};

/// A feature measured on a scale, and what the window measures on it.
const Scale = enum {
    width,
    height,
    aspect_ratio,
    resolution,
    color,
    color_index,
    monochrome,
    grid,

    /// What the window measures, or nothing where there is no window.
    fn here(self: Scale, screen: ?Screen) ?f32 {
        return switch (self) {
            .width => (screen orelse return null).width,
            .height => (screen orelse return null).height,
            .aspect_ratio => (screen orelse return null).width / @max(screen.?.height, 1),
            .resolution => (screen orelse return null).scale,
            // Eight bits a channel, which is what every surface here holds.
            .color => 8,
            .color_index, .monochrome, .grid => 0,
        };
    }

    /// A value asked about, in this scale's own measure.
    fn measure(self: Scale, amount: Token.Number, screen: ?Screen) ?f32 {
        return switch (self) {
            .width, .height => pixels(amount, screen),
            .resolution => dots(amount),
            .aspect_ratio, .color, .color_index, .monochrome, .grid => if (amount.unit.len == 0) amount.value else null,
        };
    }
};

/// A feature that is one of a few words, and the word the window is.
const Word = enum {
    orientation,
    prefers_color_scheme,
    prefers_reduced_motion,
    prefers_contrast,
    hover,
    pointer,
    scripting,
    forced_colors,
    inverted_colors,
    update,
    display_mode,
    color_gamut,
    dynamic_range,

    /// The word the window is, or nothing where there is no window to say.
    fn here(self: Word, screen: ?Screen) ?[]const u8 {
        return switch (self) {
            .orientation => {
                const window = screen orelse return null;
                return if (window.width >= window.height) "landscape" else "portrait";
            },
            .prefers_color_scheme => "light",
            .prefers_reduced_motion => "reduce",
            .prefers_contrast => "no-preference",
            .hover => "hover",
            .pointer => "fine",
            .scripting => "none",
            .forced_colors, .inverted_colors => "none",
            .update => "fast",
            .display_mode => "browser",
            .color_gamut => "srgb",
            .dynamic_range => "standard",
        };
    }
};

/// The feature a name asks about, and how: `min-` and `max-` ask for the
/// least and the most, and the prefix older engines wrote is let go.
const Asked = struct {
    feature: Feature,
    bound: ?Compare,

    fn of(written: []const u8) ?Asked {
        var name = written;
        if (std.ascii.startsWithIgnoreCase(name, "-webkit-")) name = name["-webkit-".len..];
        var bound: ?Compare = null;
        if (std.ascii.startsWithIgnoreCase(name, "min-")) {
            bound = .ge;
            name = name["min-".len..];
        } else if (std.ascii.startsWithIgnoreCase(name, "max-")) {
            bound = .le;
            name = name["max-".len..];
        }
        const feature = Feature.table.get(name) orelse return null;
        // Only what is measured has a least and a most.
        if (bound != null and feature == .word) return null;
        return .{ .feature = feature, .bound = bound };
    }
};

/// `(name)`: whether the feature is anything but none, or nought.
fn present(written: []const u8, screen: ?Screen) Truth {
    const asked = Asked.of(written) orelse return .unknown;
    if (asked.bound != null) return .unknown;
    return switch (asked.feature) {
        .scale => |scale| .of((scale.here(screen) orelse return .unknown) != 0),
        .word => |word| {
            const here = word.here(screen) orelse return .unknown;
            return .of(!std.ascii.eqlIgnoreCase(here, "none") and !std.ascii.eqlIgnoreCase(here, "no-preference"));
        },
    };
}

/// `(name: value)`.
fn plain(written: []const u8, value: Value, screen: ?Screen) Truth {
    const asked = Asked.of(written) orelse return .unknown;
    return switch (asked.feature) {
        .scale => |scale| compared(scale, asked.bound orelse .eq, value, screen),
        .word => |word| switch (value) {
            .word => |said| .of(std.ascii.eqlIgnoreCase(said, word.here(screen) orelse return .unknown)),
            .amount, .unknown_length => .unknown,
        },
    };
}

/// `(name < value)` and the like.
fn ranged(written: []const u8, how: Compare, value: Value, screen: ?Screen) Truth {
    const asked = Asked.of(written) orelse return .unknown;
    if (asked.bound != null) return .unknown;
    return switch (asked.feature) {
        .scale => |scale| compared(scale, how, value, screen),
        .word => .unknown,
    };
}

fn compared(scale: Scale, how: Compare, value: Value, screen: ?Screen) Truth {
    const amount = switch (value) {
        .amount => |n| n,
        .word, .unknown_length => return .unknown,
    };
    const there = scale.measure(amount, screen) orelse return .unknown;
    const here = scale.here(screen) orelse return .unknown;
    return .of(switch (how) {
        .lt => here < there,
        .le => here <= there,
        .gt => here > there,
        .ge => here >= there,
        .eq => here == there,
    });
}

// ---------------------------------------------------------------------------
// A sheet as it reads in a window
// ---------------------------------------------------------------------------

/// `text`, a stylesheet, as it reads on `screen`, written to `w`: the rules of
/// every `@media` block that is for the window in place of the block, and
/// those of every block that is not, left out.
///
/// So every rule reaches upstream at the top of a sheet, which is where it
/// reads rules whole. Inside a block it reads a rule that begins with a name
/// and a colon, as `a:hover` does, as a declaration, and the rest of the
/// block goes with it.
///
/// A layer's rules are put in place as a matching block's are, without its
/// standing among the layers. Every other rule that holds a block is left
/// out, and so is every rule that is only a statement: an import, a
/// character set, a namespace. So are comments. Nothing is written that was
/// not in `text`, so `w` never needs more room than `text` takes.
pub fn flatten(text: []const u8, screen: ?Screen, w: *Writer) Writer.Error!void {
    var to: Flattening = .{ .w = w };
    try walk(text, screen, &to, 0);
}

/// What the media blocks of `text` come to on `screen`, as one number: two
/// windows it is the same for read the sheet alike.
pub fn outcomes(text: []const u8, screen: ?Screen) u64 {
    var to: Tallying = .{};
    walk(text, screen, &to, 0) catch |err| switch (err) {};
    return to.hasher.final();
}

/// Writes out the rules that read.
const Flattening = struct {
    w: *Writer,

    const Error = Writer.Error;

    fn rules(self: *Flattening, text: []const u8) Error!void {
        try self.w.writeAll(text);
    }

    fn decided(_: *Flattening, _: bool) void {}
};

/// Counts up which media blocks read, in order.
const Tallying = struct {
    hasher: std.hash.Wyhash = .init(0),

    const Error = error{};

    fn rules(_: *Tallying, _: []const u8) Error!void {}

    fn decided(self: *Tallying, yes: bool) void {
        std.hash.autoHash(&self.hasher, yes);
    }
};

/// How deep blocks inside blocks are followed. Anything deeper is left out.
const DEPTH_MAX = 8;

/// Walk `text` as it reads on `screen`, handing `to` what reads: each piece
/// of the rules that are kept to `to.rules`, and whether each media block met
/// is for the window to `to.decided`.
fn walk(text: []const u8, screen: ?Screen, to: anytype, depth: usize) @TypeOf(to.*).Error!void {
    var at: usize = 0;
    while (at < text.len) {
        switch (text[at]) {
            '@' => {
                const rule = AtRule.at(text, at);
                at = rule.end;
                const inner = rule.block orelse continue;
                if (depth == DEPTH_MAX) continue;
                const kept = switch (rule.kind) {
                    .media => kept: {
                        const yes = matches(rule.prelude, screen);
                        to.decided(yes);
                        break :kept yes;
                    },
                    .layer => true,
                    .other => false,
                };
                if (kept) try walk(inner, screen, to, depth + 1);
            },
            '{' => {
                const block = Block.at(text, at);
                try to.rules(text[at..block.end]);
                at = block.end;
            },
            // A stray end of a block ends nothing.
            '}' => at += 1,
            '"', '\'', '\\' => {
                const end = skip(text, at);
                try to.rules(text[at..end]);
                at = end;
            },
            '/' => {
                const end = skip(text, at);
                // A comment is left out, and a slash on its own is not one.
                if (end - at == 1) try to.rules(text[at..end]);
                at = end;
            },
            else => {
                const end = std.mem.indexOfAnyPos(u8, text, at + 1, "@{}\"'/\\") orelse text.len;
                try to.rules(text[at..end]);
                at = end;
            },
        }
    }
}

/// An at-rule in a sheet's text: what kind, what it is for, and what it
/// holds.
const AtRule = struct {
    kind: Kind,
    prelude: []const u8,
    /// The inside of its block, or none for a statement.
    block: ?[]const u8,
    /// Where the text after it starts.
    end: usize,

    const Kind = enum { media, layer, other };

    fn at(text: []const u8, start: usize) AtRule {
        var i = start + 1;
        while (i < text.len and Lexer.identPart(text[i])) i += 1;
        const name = text[start + 1 .. i];
        const kind: Kind = if (std.ascii.eqlIgnoreCase(name, "media"))
            .media
        else if (std.ascii.eqlIgnoreCase(name, "layer"))
            .layer
        else
            .other;

        var depth: usize = 0;
        var j = i;
        while (j < text.len) {
            switch (text[j]) {
                '(', '[' => depth += 1,
                ')', ']' => depth -|= 1,
                ';' => if (depth == 0) return .{ .kind = kind, .prelude = text[i..j], .block = null, .end = j + 1 },
                '{' => if (depth == 0) {
                    const block = Block.at(text, j);
                    return .{ .kind = kind, .prelude = text[i..j], .block = text[j + 1 .. block.inside_end], .end = block.end };
                },
                else => {},
            }
            j = skip(text, j);
        }
        return .{ .kind = kind, .prelude = text[i..], .block = null, .end = text.len };
    }
};

/// Where a block that opens at `open` ends: its inside ends at its closing
/// bracket, and the text after it starts past that. One never closed runs to
/// the end of the text.
const Block = struct {
    inside_end: usize,
    end: usize,

    fn at(text: []const u8, open: usize) Block {
        var depth: usize = 0;
        var i = open;
        while (i < text.len) {
            switch (text[i]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) return .{ .inside_end = i, .end = i + 1 };
                },
                else => {},
            }
            i = skip(text, i);
        }
        return .{ .inside_end = text.len, .end = text.len };
    }
};

/// Where the text after the piece at `at` starts: past a string, a comment
/// or an escaped character, and otherwise past the one character.
fn skip(text: []const u8, at: usize) usize {
    switch (text[at]) {
        '"', '\'' => |quote| {
            var i = at + 1;
            while (i < text.len) : (i += 1) {
                if (text[i] == '\\') {
                    i += 1;
                    continue;
                }
                if (text[i] == quote or text[i] == '\n') return i + 1;
            }
            return text.len;
        },
        '/' => if (at + 1 < text.len and text[at + 1] == '*') {
            const close = std.mem.indexOfPos(u8, text, at + 2, "*/") orelse return text.len;
            return close + 2;
        },
        '\\' => return @min(at + 2, text.len),
        else => {},
    }
    return at + 1;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// A window the size of the panel the system is first made for.
const panel = Screen{ .width = 800, .height = 480 };

fn expectFor(prelude: []const u8, expected: bool) !void {
    testing.expectEqual(expected, matches(prelude, panel)) catch |err| {
        std.debug.print("\"{s}\"\n", .{prelude});
        return err;
    };
}

test "a kind of media is this window, or is not" {
    try expectFor("screen", true);
    try expectFor("all", true);
    try expectFor("ALL", true);
    try expectFor("print", false);
    try expectFor("only screen", true);
    try expectFor("not print", true);
    try expectFor("not screen", false);
    try expectFor("print, screen", true);
    try expectFor("speech", false);
    // None at all is every window.
    try expectFor("", true);
}

test "widths are asked of the window, in whatever unit" {
    try expectFor("screen and (min-width: 640px)", true);
    try expectFor("screen and (min-width:1120px)", false);
    try expectFor("all and (max-width:calc(640px - 1px))", false);
    try expectFor("screen and (max-width: calc(1120px - 1px))", true);
    try expectFor("(min-width: 40em)", true);
    try expectFor("(max-width: 49.99rem)", false);
    try expectFor("(min-width: 100vw)", true);
    try expectFor("(width: 800px)", true);
    try expectFor("(min-height: 600px)", false);
    try expectFor("(orientation: landscape)", true);
    try expectFor("(orientation: portrait)", false);
    try expectFor("(min-aspect-ratio: 16/9)", false);
    try expectFor("(min-aspect-ratio: 4/3)", true);
}

test "a narrower window, or one drawn larger, answers as it is" {
    const tiled = Screen{ .width = 400, .height = 480 };
    try testing.expect(matches("(max-width: 639px)", tiled));
    try testing.expect(matches("(orientation: portrait)", tiled));
    const doubled = Screen{ .width = 400, .height = 240, .scale = 2 };
    try testing.expect(matches("(min-resolution: 2dppx)", doubled));
    try testing.expect(!matches("(min-resolution: 2dppx)", panel));
}

test "a range is read either way round, and between two bounds" {
    try expectFor("(width >= 640px)", true);
    try expectFor("(width > 800px)", false);
    try expectFor("(640px <= width < 1120px)", true);
    try expectFor("(1120px <= width)", false);
    try expectFor("(400px < width <= 700px)", false);
}

test "the window is lit in daylight colours, hovers and runs no scripts" {
    try expectFor("screen and (prefers-color-scheme: dark)", false);
    try expectFor("(prefers-color-scheme: light)", true);
    try expectFor("(prefers-reduced-motion: reduce)", true);
    try expectFor("(hover: hover) and (pointer: fine)", true);
    try expectFor("(pointer: coarse)", false);
    try expectFor("(scripting: none)", true);
    try expectFor("(color)", true);
    try expectFor("(monochrome)", false);
    try expectFor("(-webkit-min-device-pixel-ratio: 2), (min-resolution: 192dpi)", false);
    try expectFor("(min-resolution: 1dppx)", true);
}

test "conditions nest, and what is not known is not this window" {
    try expectFor("not (min-width: 1000px)", true);
    try expectFor("screen and ((min-width: 1000px) or (max-width: 900px))", true);
    try expectFor("(min-width: 1000px) or (orientation: landscape)", true);
    try expectFor("(unknown-feature: 1)", false);
    try expectFor("not (unknown-feature: 1)", false);
    try expectFor("not screen and (unknown-feature)", false);
}

test "a query that cannot be read is not this window, and spares the rest" {
    try expectFor("screen and (", false);
    try expectFor("@@@", false);
    try expectFor("screen and (min-width: 640px) and", false);
    try expectFor("screen (min-width: 1px)", false);
    try expectFor("garbage, screen", true);
    // A bracket left open takes the rest of the list with it.
    try expectFor("garbage (, screen", false);
}

test "with no window to ask about, only what holds for any window reads" {
    try testing.expect(matches("screen", null));
    try testing.expect(!matches("(min-width: 640px)", null));
    try testing.expect(couldMatch("(min-width: 640px)"));
    try testing.expect(couldMatch("not (min-width: 640px)"));
    try testing.expect(couldMatch("screen and (max-width: calc(50vw + 1px))"));
    try testing.expect(!couldMatch("print"));
    try testing.expect(!couldMatch("print and (min-width: 1px)"));
}

fn expectFlat(text: []const u8, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try flatten(text, panel, &w);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "a block for the window is put in place, and one that is not is left out" {
    try expectFlat("a{color:red}@media screen{b{color:blue}}@media print{c{color:green}}d{}", "a{color:red}b{color:blue}d{}");
    try expectFlat("@media screen{@media (min-width:640px){a{}}@media (min-width:1200px){b{}}}", "a{}");
}

test "a layer's rules stay, and every other at-rule goes" {
    try expectFlat("@layer base{a{}}@layer x;@supports (display:grid){b{}}@import url(x.css);@font-face{font-family:x}c{}", "a{}c{}");
}

test "strings, comments and escapes keep their brackets to themselves" {
    try expectFlat("a{content:\"}\"}/* @media print{ */b{}", "a{content:\"}\"}b{}");
    try expectFlat("@media screen{a{content:'{'}}b{}", "a{content:'{'}b{}");
    try expectFlat(".x\\@y{}@media print{z{}}", ".x\\@y{}");
    try expectFlat("a{background:url(a/b.png)}", "a{background:url(a/b.png)}");
}

test "a sheet cut short keeps what it has" {
    try expectFlat("a{color:red", "a{color:red");
    try expectFlat("@media screen{a{}", "a{}");
}

test "two windows read a sheet alike where its blocks answer alike" {
    const sheet = "a{}@media (min-width:640px){b{}}@media (max-width:300px){c{}}";
    const wider = Screen{ .width = 1000, .height = 600 };
    const narrow = Screen{ .width = 400, .height = 480 };
    try testing.expectEqual(outcomes(sheet, panel), outcomes(sheet, wider));
    try testing.expect(outcomes(sheet, panel) != outcomes(sheet, narrow));
}

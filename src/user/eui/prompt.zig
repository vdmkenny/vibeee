//! A question across the bottom of a window, with the ways to answer it.
//!
//! What a program asks when it cannot go on without a decision: whether to
//! save before closing, whether to replace a file. A sheet rather than a
//! window of its own, because the question is about this window and belongs
//! in it; a strip rather than a box in the middle, because the document it
//! is asking about should stay in view.
//!
//! Answered by button, by the letter a choice names, by Enter for the first
//! choice and by Escape for the last: the first is what the program
//! suggests, and the last is always the way out. A question about a number,
//! how much or how many, carries the number on a stepper of its own between
//! the words and the answers, and up and down move it from the keyboard.

const std = @import("std");
const draw = @import("draw.zig");
const footer = @import("footer.zig");
const slider = @import("slider.zig");
const stepper = @import("stepper.zig");
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;
const KeyCode = widget.KeyCode;

/// One way to answer.
pub const Choice = struct {
    label: []const u8,
    /// The letter that chooses it from the keyboard, or zero for none.
    letter: u8 = 0,
    weight: widget.Emphasis = .plain,
};

/// As many as a strip holds beside its question.
pub const MAX_CHOICES = 3;

/// A number the question is about, kept within its range.
pub const Amount = struct {
    value: i32,
    range: slider.Range,
};

/// The question standing in a window, or none.
pub const Prompt = struct {
    question: []const u8 = "",
    choices: []const Choice = &.{},
    amount: ?Amount = null,

    pub fn ask(self: *Prompt, question: []const u8, choices: []const Choice) void {
        std.debug.assert(choices.len > 0 and choices.len <= MAX_CHOICES);
        self.question = question;
        self.choices = choices;
        self.amount = null;
    }

    /// A question with a number in it: how much, how many, how far.
    pub fn askFor(self: *Prompt, question: []const u8, choices: []const Choice, amount: Amount) void {
        self.ask(question, choices);
        self.amount = .{ .value = amount.range.clamp(amount.value), .range = amount.range };
    }

    pub fn dismiss(self: *Prompt) void {
        self.choices = &.{};
        self.amount = null;
    }

    /// The number as it stands, or zero for a question without one.
    pub fn number(self: *const Prompt) i32 {
        return if (self.amount) |amount| amount.value else 0;
    }

    fn move(self: *Prompt, by: i32) bool {
        const amount = &(self.amount orelse return false);
        amount.value = amount.range.clamp(amount.value + by);
        return true;
    }

    pub fn isOpen(self: *const Prompt) bool {
        return self.choices.len > 0;
    }
};

/// Where the sheet sits: the strip along the bottom of `area`.
pub fn sheet(area: Rect) Rect {
    return footer.strip(area);
}

/// What `area` keeps while the sheet stands, so what is under it steps back
/// rather than being clicked through it.
pub fn above(area: Rect) Rect {
    return footer.above(area);
}

/// Draw the sheet and take an answer from its buttons. Null while the
/// question stands, and while there is none. A number on the sheet is
/// moved by its stepper and read back from `number`.
pub fn run(ctx: *widget.Context, area: Rect, state: *Prompt) ?usize {
    if (!state.isOpen()) return null;

    const t = theme.current();
    const bar = sheet(area);
    // The ground and its rule are painted with everything else, on a pass
    // that repaints the window, and never on their own: the words and the
    // buttons on the sheet keep themselves, and a ground painted under them
    // on a quiet pass would wipe them. The program that puts the question
    // damages the window, so the sheet's first pass is a whole one.
    if (ctx.damaged) {
        ctx.surface.fill(bar, t.surface);
        ctx.surface.fill(.{ .x = bar.x, .y = bar.y, .w = bar.w, .h = 1 }, t.line);
        ctx.addDamage(bar);
    }

    var labels: [MAX_CHOICES][]const u8 = undefined;
    for (state.choices, 0..) |choice, i| labels[i] = choice.label;
    var cells: [MAX_CHOICES]Rect = undefined;
    const placed = footer.place(bar, labels[0..state.choices.len], &cells);

    var message = footer.messageRect(bar, placed);
    if (state.amount) |*amount| {
        // The number sits against the answers, and the words keep the rest.
        const wide = stepper.width(t.control_height);
        const counter = Rect{
            .x = message.right() - wide,
            .y = bar.y + @divTrunc(bar.h - t.control_height, 2),
            .w = wide,
            .h = t.control_height,
        };
        message.w = @max(0, message.w - wide - t.gap);
        amount.value = ctx.stepper(counter, amount.range, amount.value);
    }
    ctx.label(message, state.question);

    var chosen: ?usize = null;
    for (placed, state.choices, 0..) |cell, choice, i| {
        if (ctx.buttonAs(cell, choice.label, choice.weight)) chosen = i;
    }
    return chosen;
}

/// Answer from a key: Enter takes the first choice, Escape the last, and up
/// and down move the number when there is one. Null when the key is not an
/// answer.
pub fn key(state: *Prompt, code: KeyCode) ?usize {
    if (!state.isOpen()) return null;
    switch (code) {
        .enter => return 0,
        .escape => return state.choices.len - 1,
        .up => _ = state.move(1),
        .down => _ = state.move(-1),
        else => {},
    }
    return null;
}

/// Answer from a typed letter, in either case. Null when no choice names it.
pub fn letter(state: *const Prompt, codepoint: u32) ?usize {
    if (!state.isOpen() or codepoint > std.math.maxInt(u8)) return null;
    const typed = std.ascii.toLower(@intCast(codepoint));
    for (state.choices, 0..) |choice, i| {
        if (choice.letter != 0 and std.ascii.toLower(choice.letter) == typed) return i;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

const SAVE_OR_NOT = [_]Choice{
    .{ .label = "Save", .letter = 's', .weight = .strong },
    .{ .label = "Discard", .letter = 'd' },
    .{ .label = "Cancel" },
};

test "a prompt stands from the question to its answer" {
    var prompt = Prompt{};
    try testing.expect(!prompt.isOpen());
    try testing.expectEqual(@as(?usize, null), key(&prompt, .enter));

    prompt.ask("Save the changes?", &SAVE_OR_NOT);
    try testing.expect(prompt.isOpen());
    prompt.dismiss();
    try testing.expect(!prompt.isOpen());
}

test "enter suggests, escape is the way out, a letter names its choice" {
    var prompt = Prompt{};
    prompt.ask("Save the changes?", &SAVE_OR_NOT);

    try testing.expectEqual(@as(?usize, 0), key(&prompt, .enter));
    try testing.expectEqual(@as(?usize, 2), key(&prompt, .escape));
    try testing.expectEqual(@as(?usize, null), key(&prompt, .space));

    try testing.expectEqual(@as(?usize, 1), letter(&prompt, 'd'));
    try testing.expectEqual(@as(?usize, 1), letter(&prompt, 'D'));
    try testing.expectEqual(@as(?usize, 0), letter(&prompt, 's'));
    // Cancel names no letter, and a letter nobody names is not an answer.
    try testing.expectEqual(@as(?usize, null), letter(&prompt, 'c'));
    try testing.expectEqual(@as(?usize, null), letter(&prompt, 0x2014));
}

test "a question with a number keeps it within range, and up and down move it" {
    var prompt = Prompt{};
    try testing.expectEqual(@as(i32, 0), prompt.number());

    prompt.askFor("Took how much?", &SAVE_OR_NOT, .{ .value = 12, .range = .{ .min = 1, .max = 9 } });
    try testing.expectEqual(@as(i32, 9), prompt.number());
    try testing.expectEqual(@as(?usize, null), key(&prompt, .down));
    try testing.expectEqual(@as(i32, 8), prompt.number());
    try testing.expectEqual(@as(?usize, null), key(&prompt, .up));
    try testing.expectEqual(@as(?usize, null), key(&prompt, .up));
    try testing.expectEqual(@as(i32, 9), prompt.number());
    // The answers are still the answers.
    try testing.expectEqual(@as(?usize, 0), key(&prompt, .enter));

    prompt.dismiss();
    try testing.expectEqual(@as(i32, 0), prompt.number());
    // A plain question has no number to move.
    prompt.ask("Save the changes?", &SAVE_OR_NOT);
    try testing.expectEqual(@as(?usize, null), key(&prompt, .up));
    try testing.expectEqual(@as(i32, 0), prompt.number());
}

test "the sheet takes the bottom and leaves the rest" {
    const window = Rect{ .x = 0, .y = 0, .w = 460, .h = 300 };
    const bar = sheet(window);
    try testing.expectEqual(window.bottom(), bar.bottom());
    try testing.expectEqual(bar.y, above(window).bottom());
    try testing.expectEqual(window.w, bar.w);
}

//! A label and what it says, in two columns.
//!
//! What a window uses to state things rather than to ask them: the size of
//! a file, the camera that took a photograph, what this machine is. Three
//! windows drew this row and each set its own label column, so the same
//! sentence sat at three different widths depending on where it was read.
//!
//! The column is a share of the width with a floor, because a narrow pane
//! must not give the whole of itself to labels and a wide one must not
//! strand the values halfway across the screen.

const draw = @import("draw.zig");
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;

/// How wide the labels are in `area`.
pub fn column(area: Rect) i32 {
    return @max(theme.enlarged(80), @min(@divTrunc(area.w, 5), @divTrunc(area.w, 3)));
}

/// How tall one row is, so a caller can say how many will fit before it
/// draws any.
pub fn height() i32 {
    return theme.current().menu_row_height;
}

/// Whether a pane is too narrow to say a label and a value side by side.
/// Under this, a value has so few pixels left that most of them arrive cut
/// in half, which is worse than a taller row.
fn cramped(area: Rect) bool {
    return area.w - column(area) < theme.enlarged(96);
}

/// How tall one row is in `area`, which is two lines where the pane is too
/// narrow to hold them side by side.
pub fn heightIn(area: Rect) i32 {
    return if (cramped(area)) height() + draw.Surface.textHeight() else height();
}

/// One row. Returns where the next one goes.
pub fn one(
    ctx: *widget.Context,
    area: Rect,
    y: i32,
    label: []const u8,
    value: []const u8,
) i32 {
    const t = theme.current();
    const label_w = column(area);

    // An empty label is a value that runs the whole width: a note under the
    // facts rather than another fact.
    if (label.len == 0) {
        ctx.label(.{ .x = area.x, .y = y, .w = area.w, .h = t.control_height }, value);
        return y + height();
    }

    // Side by side where there is room for both, and the label over the
    // value where there is not: a narrow pane would otherwise spend its
    // width on labels and cut every value in half.
    if (cramped(area)) {
        ctx.labelDim(.{ .x = area.x, .y = y, .w = area.w, .h = t.control_height }, label);
        ctx.label(
            .{ .x = area.x, .y = y + draw.Surface.textHeight(), .w = area.w, .h = t.control_height },
            value,
        );
        return y + heightIn(area);
    }

    ctx.labelDim(.{ .x = area.x, .y = y, .w = label_w, .h = t.control_height }, label);
    ctx.label(
        .{ .x = area.x + label_w, .y = y, .w = area.w - label_w, .h = t.control_height },
        value,
    );
    return y + height();
}

/// A row and its value, given together, for a caller that has a list of them
/// rather than a sequence of decisions.
pub const Fact = struct { label: []const u8, value: []const u8 };

/// Every row in order. Returns where the next thing goes.
pub fn all(ctx: *widget.Context, area: Rect, from: i32, list: []const Fact) i32 {
    var y = from;
    for (list) |fact| y = one(ctx, area, y, fact.label, fact.value);
    return y;
}

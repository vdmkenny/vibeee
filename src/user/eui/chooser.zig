//! Choosing a file: the panel, not the window.
//!
//! A list of what is there, a name to type, and two buttons. Every program
//! that opens or saves wants exactly this, so it is written once.
//!
//! It draws into whatever surface it is given and knows nothing about windows
//! or filesystems: the caller passes the entries it found and puts the result
//! wherever it puts things. `proto.FileDialog` is the half that gives it a
//! floating window and fills it from a directory, and it lives there rather
//! than here because a toolkit that could open a window would be a toolkit
//! every program had to link a window server into.

const std = @import("std");
const draw = @import("draw.zig");
const table = @import("table.zig");
const text_mod = @import("text.zig");
const theme = @import("theme.zig");
const widget = @import("widget.zig");

const Rect = draw.Rect;
const Surface = draw.Surface;

/// What the panel is for. Only the wording and which button is the default
/// differ, which is the whole difference between opening and saving.
pub const Purpose = enum {
    open,
    save,

    pub fn verb(self: Purpose) []const u8 {
        return switch (self) {
            .open => "Open",
            .save => "Save",
        };
    }
};

/// One row, as the caller found it.
pub const Entry = struct {
    name: []const u8,
    size: u32 = 0,
    is_dir: bool = false,
};

pub const Outcome = enum {
    /// Still choosing.
    none,
    /// The name in the field is the answer.
    accepted,
    cancelled,
    /// A directory was chosen. The caller re-reads and comes back.
    descend,
};

/// The largest name the field holds. Longer than any path this filesystem can
/// produce, which is what keeps a caller from having to check.
pub const MAX_NAME = 80;

pub const Chooser = struct {
    purpose: Purpose = .open,

    /// The typed name. Storage is here rather than the caller's, because every
    /// caller would give it the same thing.
    name_storage: [MAX_NAME]u8 = @splat(0),
    name: text_mod.Buffer = undefined,
    name_editor: text_mod.Editor = .{},

    list: table.State = .{},
    /// The row a click landed on when it was a directory, so the caller knows
    /// which one to descend into.
    chosen: usize = 0,

    /// Set once, because `name` has to point at `name_storage` and a struct
    /// cannot point at itself before it exists.
    pub fn init(self: *Chooser, purpose: Purpose, initial: []const u8) void {
        self.* = .{ .purpose = purpose };
        self.name = .{ .bytes = &self.name_storage };
        _ = self.name.insert(0, initial[0..@min(initial.len, MAX_NAME)]);
        self.name_editor.cursor = self.name.len;
    }

    pub fn typed(self: *const Chooser) []const u8 {
        return self.name.slice();
    }

    fn setName(self: *Chooser, value: []const u8) void {
        self.name.clear();
        _ = self.name.insert(0, value[0..@min(value.len, MAX_NAME)]);
        self.name_editor = .{ .cursor = self.name.len };
    }
};

const COLUMNS = [_]table.Column{
    .{ .title = "name", .width = 160 },
    .{ .title = "size", .width = 70, .right = true },
};

/// Draw and run the panel. `where` is shown above the list, so a person can
/// see which directory they are in.
pub fn run(
    ctx: *widget.Context,
    area: Rect,
    state: *Chooser,
    where: []const u8,
    entries: []const Entry,
) Outcome {
    const t = theme.current();
    const pad = t.padding;
    const row = t.control_height;

    ctx.label(.{ .x = area.x + pad, .y = area.y + pad, .w = area.w - pad * 2, .h = 16 }, where);

    // The list, then the name, then the buttons, top to bottom: the order
    // someone works through them.
    const buttons_y = area.bottom() - row - pad;
    const name_y = buttons_y - row - 6;
    const list_top = area.y + pad + 20;

    var rows: [MAX_ROWS]table.Row = undefined;
    var sizes: [MAX_ROWS][12]u8 = undefined;
    const shown = fill(entries, &rows, &sizes);

    var outcome = Outcome.none;

    if (ctx.table(
        .{ .x = area.x + pad, .y = list_top, .w = area.w - pad * 2, .h = name_y - list_top - 6 },
        &state.list,
        &COLUMNS,
        rows[0..shown],
    )) |index| {
        if (index < entries.len) {
            state.chosen = index;
            if (entries[index].is_dir) {
                outcome = .descend;
            } else {
                state.setName(entries[index].name);
                outcome = .accepted;
            }
        }
    }

    // A single click fills the field without committing, so the name can be
    // corrected before saving over something.
    if (outcome == .none and state.list.selected < entries.len) {
        const selected = entries[state.list.selected];
        if (!selected.is_dir and ctx.pressedThisPass()) state.setName(selected.name);
    }

    if (text_mod.field(
        ctx,
        .{ .x = area.x + pad, .y = name_y, .w = area.w - pad * 2, .h = row },
        &state.name_editor,
        &state.name,
    )) outcome = .accepted;

    const width: i32 = 76;
    if (ctx.button(
        .{ .x = area.right() - pad - width, .y = buttons_y, .w = width, .h = row },
        state.purpose.verb(),
    )) outcome = .accepted;

    if (ctx.button(
        .{ .x = area.right() - pad - width * 2 - 6, .y = buttons_y, .w = width, .h = row },
        "Cancel",
    )) outcome = .cancelled;

    if (outcome == .accepted and state.typed().len == 0) return .none;
    return outcome;
}

/// As many rows as the list can hold. Matches the listing bound in `ulib.dir`,
/// which is where the entries come from.
pub const MAX_ROWS = 96;

fn fill(entries: []const Entry, rows: []table.Row, sizes: [][12]u8) usize {
    var n: usize = 0;
    for (entries) |entry| {
        if (n >= rows.len) break;

        var size = std.mem.zeroes([12]u8);
        const shown = if (entry.is_dir) blk: {
            @memcpy(size[0..5], "<dir>");
            break :blk size[0..5];
        } else describe(&size, entry.size);
        sizes[n] = size;

        rows[n] = .{ .cells = .{ entry.name, sizes[n][0..shown.len], "", "", "", "" } };
        n += 1;
    }
    return n;
}

/// A size a person can read at a glance rather than a byte count they have to
/// count digits in.
fn describe(buf: []u8, bytes: u32) []const u8 {
    const units = [_][]const u8{ "B", "K", "M" };
    var value: u32 = bytes;
    var unit: usize = 0;
    while (value >= 10240 and unit + 1 < units.len) : (unit += 1) value /= 1024;

    var n: usize = 0;
    var digits: [12]u8 = undefined;
    var d: usize = 0;
    if (value == 0) {
        digits[0] = '0';
        d = 1;
    }
    while (value > 0) : (value /= 10) {
        digits[d] = '0' + @as(u8, @intCast(value % 10));
        d += 1;
    }
    while (d > 0) {
        d -= 1;
        buf[n] = digits[d];
        n += 1;
    }
    const suffix = units[unit];
    @memcpy(buf[n..][0..suffix.len], suffix);
    return buf[0 .. n + suffix.len];
}

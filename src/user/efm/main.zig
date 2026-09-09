//! efm: the file manager, in two panes.
//!
//! Two panes because the operations that matter are between them: copying and
//! moving have a source and a destination, and a manager with one pane makes
//! you name the destination from memory. Here it is the thing you are looking
//! at next to the thing you are looking at.
//!
//! Driven from the keyboard first. Tab changes pane, the arrows walk a
//! listing, Enter opens what is under the cursor, and the function keys along
//! the bottom are the whole interface once you know them: a machine with a
//! touchpad this small is a machine where reaching for the pointer costs more
//! than the keystroke it saves.

const std = @import("std");
const eui = @import("eui");
const proto = @import("proto");
const sys = @import("sys");
const env = @import("ulib").env;
const dir = @import("ulib").dir;
const opening = @import("proto").opening;
const preview = @import("preview.zig");

// The picture decoder is C, and calls the libc by name: the C-callable half
// is imported so its exports are emitted into this binary. One
// implementation in the system, not two.
comptime {
    _ = @import("clibc");
}
const info = @import("ulib").info;
const mounts = @import("lib").mounts;
const paths = @import("ulib").paths;
const str = @import("ulib").str;

const theme = eui.theme;
const Rect = eui.Rect;
const ui = eui.widget;
const Surface = eui.Surface;

/// The frame's context, which is where every control call goes.
const ctx = &proto.app.ctx;

/// One side. Each carries its own name storage, because a listing's entries
/// point into it and two panes read two directories.
const Pane = struct {
    path_buf: [128]u8 = @splat(0),
    path_len: usize = 0,
    /// Name storage the listing's entries point into. Room for every entry
    /// the listing holds at the longest name a volume can carry, so a
    /// directory of long names is not cut short for want of somewhere to
    /// put them.
    names: [dir.NAMES]u8 = undefined,
    listing: dir.Listing = .{},
    /// The table's own memory: which row is selected and how far down it is.
    /// The control keeps it, this only owns it.
    view: eui.table.State = .{},

    fn path(self: *const Pane) []const u8 {
        return self.path_buf[0..self.path_len];
    }

    fn setPath(self: *Pane, value: []const u8) void {
        const n = @min(value.len, self.path_buf.len);
        @memcpy(self.path_buf[0..n], value[0..n]);
        self.path_len = n;
    }

    fn refresh(self: *Pane) void {
        self.listing = .{};
        dir.read(self.path(), &self.names, &self.listing) catch {};
        if (self.view.selected >= self.listing.items().len) {
            self.view.selected = self.listing.items().len -| 1;
        }
    }

    fn current(self: *const Pane) ?dir.Entry {
        const items = self.listing.items();
        if (self.view.selected >= items.len) return null;
        return items[self.view.selected];
    }

    /// The full path of what the cursor is on.
    fn currentPath(self: *const Pane, buf: []u8) ?[]const u8 {
        const entry = self.current() orelse return null;
        return paths.join(self.path(), entry.name, buf);
    }
};

var panes: [2]Pane = @splat(.{});
var active: usize = 0;

fn other() *Pane {
    return &panes[1 - active];
}

fn here() *Pane {
    return &panes[active];
}

/// What the footer is asking for, if anything. A manager that opened a window
/// to ask for a folder's name would be a manager that needs a window manager
/// to rename a file.
const Asking = enum { nothing, folder, confirm_delete };
var asking: Asking = .nothing;

/// The question itself is the toolkit's, so it is the same sheet every other
/// program in this system asks with, and its field takes whole characters:
/// this machine's keyboard is Belgian AZERTY, where a folder called Élève is
/// four keys and six bytes.
var prompt: eui.prompt.Prompt = .{};

const FOLDER_CHOICES = [_]eui.prompt.Choice{
    .{ .label = "Make", .letter = 'm', .weight = .strong },
    .{ .label = "Cancel", .letter = 'c' },
};

const DELETE_CHOICES = [_]eui.prompt.Choice{
    .{ .label = "Delete", .letter = 'd', .weight = .strong },
    .{ .label = "Keep", .letter = 'k' },
};

/// Room for the longest question this asks: the words, and the name in them.
var question_words: [eui.prompt.QUESTION_MAX]u8 = undefined;

/// What just happened, said in the footer until the next thing happens.
var status: []const u8 = "";

/// How often the window looks for a medium that has come or gone.
const MEDIA_TICK_US: usize = 2_000_000;

export fn _start(frame: [*]usize) callconv(.c) noreturn {
    // A directory on the command line is where to start, which is how the
    // launcher says "show me where this lives".
    panes[0].setPath(env.argument(frame) orelse "/home");
    panes[1].setPath("/");
    refreshAll();

    proto.app.run("efm", "Files", 520, 360, .{
        .draw = draw,
        .tick = tick,
        .tick_us = MEDIA_TICK_US,
        .key = key,
        .text = typed,
    });
}

// ---------------------------------------------------------------------------
// What the keys do
// ---------------------------------------------------------------------------

fn key(code: proto.app.KeyCode, mods: proto.app.Modifiers) bool {
    _ = mods;

    // A question in the footer takes the keyboard until it is answered:
    // typing a folder's name into the listing behind it would move the
    // cursor instead.
    if (prompt.isOpen()) {
        if (eui.prompt.key(&prompt, code)) |choice| answered(choice);
        return true;
    }

    switch (code) {
        .tab => {
            // With a preview open there is only one listing, so there is
            // nothing to switch to.
            if (previewing) return true;
            active = 1 - active;
            ctx.damage();
        },
        .f3 => togglePreview(),
        .backspace => leave(),
        .f5 => transfer(.copy),
        .f6 => transfer(.move),
        .f7 => startAsking(.folder),
        .f8 => startAsking(.confirm_delete),
        // Everything else is the listing's: arrows, page keys and Enter are
        // the table's business.
        else => return false,
    }
    return true;
}

/// Whether the right pane is showing what the cursor is on.
var previewing = false;

/// What the cursor is on, or null where the pane is empty.
fn underCursor() ?dir.Entry {
    const pane = here();
    const items = pane.listing.items();
    if (items.len == 0) return null;
    return items[@min(pane.view.selected, items.len - 1)];
}

/// Turn the preview on and off.
///
/// Turning it on moves you to the left pane, because the right one has
/// stopped being somewhere you can be. Turning it off lets the picture go: a
/// decoded photograph is the largest thing this program holds.
fn togglePreview() void {
    previewing = !previewing;
    if (previewing) {
        active = 0;
    } else {
        preview.clear();
    }
    ctx.damage();
}

/// Keep the preview on whatever the cursor is on now.
///
/// Called every pass rather than on every key: the cursor moves by keyboard,
/// by wheel and by click, and one place that notices covers all three. The
/// preview itself does nothing when the file has not changed.
fn followCursor() void {
    if (!previewing) return;
    const entry = underCursor() orelse {
        preview.clear();
        return;
    };
    preview.show(here().path(), entry);
}

fn typed(codepoint: u32) bool {
    if (!prompt.isOpen()) return false;
    // A question with a field takes every character; one with only buttons
    // takes the letters that name them.
    if (!prompt.takesText()) {
        if (eui.prompt.letter(&prompt, codepoint)) |choice| answered(choice);
    }
    return true;
}

/// Open what the cursor is on: a directory is walked into, and anything else
/// is left alone. Running a program from here needs a way to say what it
/// should be opened with, which is a question this does not answer yet.
fn enter() void {
    const pane = here();
    const entry = pane.current() orelse return;
    if (!entry.is_dir) return open(pane, entry);
    // The parent is not a name to join onto the path but the way up.
    if (std.mem.eql(u8, entry.name, dir.PARENT)) return leave();

    var buf: [160]u8 = undefined;
    const target = paths.join(pane.path(), entry.name, &buf);
    pane.setPath(target);
    pane.view = .{};
    pane.refresh();
    ctx.again();
}

/// Open a file with whatever opens its sort of thing, which the launcher
/// does the same way: pressing Enter on a file should do one thing on this
/// machine, not one thing per window.
fn open(pane: *Pane, entry: dir.Entry) void {
    var buf: [160]u8 = undefined;
    const path = paths.join(pane.path(), entry.name, &buf);

    status = switch (opening.start(path)) {
        .opened => "",
        .nobody_opens_it => "Nothing here opens that.",
        .would_not_start => "That would not start.",
    };
    ctx.damage();
}

/// Up one, which is what backspace means everywhere else a path is shown.
fn leave() void {
    const pane = here();
    if (pane.path().len <= 1) return;

    // The parent is a prefix of the path, so the path is cut rather than
    // copied over itself.
    pane.path_len = paths.parent(pane.path()).len;
    pane.view = .{};
    pane.refresh();
    ctx.again();
}

const Transfer = enum { copy, move };

fn transfer(what: Transfer) void {
    const source = here();
    const destination = other();

    var from_buf: [160]u8 = undefined;
    const from = source.currentPath(&from_buf) orelse return;

    const entry = source.current().?;
    if (entry.is_dir) {
        status = "Directories cannot be copied yet.";
        ctx.damage();
        return;
    }

    var to_buf: [160]u8 = undefined;
    // A path cut short names something else: the copy would land somewhere
    // nobody asked for, and the move would unlink the original afterwards.
    const to = paths.joined(destination.path(), entry.name, &to_buf) orelse {
        status = "That name is too long for where it is going.";
        ctx.damage();
        return;
    };

    // The same file on both sides is not a transfer. Copying one onto
    // itself opens the destination for writing, which empties it, and then
    // reads nothing from the source it has just emptied: the file is gone
    // and the report says it was copied. Moving one onto itself ends the
    // same way and then unlinks what is left.
    if (std.mem.eql(u8, from, to)) {
        status = "That is where it already is.";
        ctx.damage();
        return;
    }

    const done = switch (what) {
        .copy => copyFile(from, to),
        // Renaming is the whole operation when both sides are one volume,
        // and a copy followed by a removal when they are not. The kernel
        // says which by refusing the rename.
        .move => renamed(from, to) or (copyFile(from, to) and unlinked(from)),
    };

    status = if (done)
        (if (what == .copy) "Copied." else "Moved.")
    else
        "That did not work.";

    refreshAll();
    ctx.damage();
}

/// One file's bytes, a chunk at a time. The chunk is what the stack can hold
/// on a machine with this much memory, not what a disk would like.
/// Whether the rename took. The kernel refuses one across volumes, which is
/// how a move learns it has to copy and remove instead.
fn renamed(from: []const u8, to: []const u8) bool {
    sys.rename(from, to) catch return false;
    return true;
}

fn unlinked(path: []const u8) bool {
    sys.unlink(path) catch return false;
    return true;
}

fn copyFile(from: []const u8, to: []const u8) bool {
    const source = sys.open(from, .{}) catch return false;
    defer sys.close(source);

    const destination = sys.open(to, .{ .write = true, .create = true, .truncate = true }) catch return false;
    defer sys.close(destination);

    while (true) {
        var chunk: [1024]u8 = undefined;
        const read = sys.read(source, &chunk) catch return false;
        if (read == 0) return true;

        const written = sys.write(destination, chunk[0..read]) catch return false;
        if (written != read) return false;
    }
}

fn startAsking(what: Asking) void {
    const entry = here().current();
    if (what == .confirm_delete and entry == null) return;

    asking = what;
    status = "";
    switch (what) {
        .folder => prompt.askText("New folder", &FOLDER_CHOICES, .{ .hint = "a name" }),
        .confirm_delete => {
            // The name in the question rather than beside it: a question about
            // a file should say which file.
            var words = str.Builder{ .buf = &question_words };
            words.text("Delete ");
            words.text(entry.?.name);
            words.byte('?');
            prompt.ask(words.done(), &DELETE_CHOICES);
        },
        .nothing => {},
    }
    ctx.damage();
}

fn stopAsking() void {
    asking = .nothing;
    prompt.dismiss();
    ctx.damage();
}

/// What the sheet was answered with. The last choice is always the way out.
fn answered(choice: usize) void {
    const words: []const eui.prompt.Choice = switch (asking) {
        .folder => &FOLDER_CHOICES,
        .confirm_delete => &DELETE_CHOICES,
        .nothing => return,
    };
    if (choice == words.len - 1) return stopAsking();
    finishAsking();
}

fn finishAsking() void {
    switch (asking) {
        .folder => {
            var kept: [eui.prompt.TEXT_MAX]u8 = undefined;
            const line = prompt.line();
            @memcpy(kept[0..line.len], line);
            const name = kept[0..line.len];
            if (name.len == 0) return stopAsking();

            var buf: [160]u8 = undefined;
            // Refused rather than cut short: a folder made at a truncated path
            // is a folder somewhere else.
            const target = paths.joined(here().path(), name, &buf) orelse {
                status = "That name is too long for where it would go.";
                return stopAsking();
            };
            status = if (sys.mkdir(target)) |_| "Made." else |_| "That did not work.";
        },
        .confirm_delete => {
            var buf: [160]u8 = undefined;
            const target = here().currentPath(&buf) orelse return stopAsking();
            const entry = here().current().?;

            // Whatever the filesystem will remove. A directory with anything
            // in it is refused there rather than here, which is the right
            // place for the rule: this program does not know what a volume
            // considers empty.
            status = if (unlinked(target))
                (if (entry.is_dir) "Removed." else "Deleted.")
            else
                (if (entry.is_dir) "Only an empty directory can be removed." else "That did not work.");
        },
        .nothing => {},
    }

    stopAsking();
    refreshAll();
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

fn draw() void {
    const surface = ctx.surface;
    const area = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };

    // The volumes above, the keys below, the panes between.
    const parts = eui.chrome.split(area, .{ .top = true, .bottom = true });
    const strip = parts.top;
    const keys = parts.bottom;
    const body = parts.body;

    followCursor();
    drawPlaces(strip);

    const half = @divTrunc(body.w, 2);
    const left = Rect{ .x = 0, .y = body.y, .w = half, .h = body.h };
    const right = Rect{ .x = half, .y = body.y, .w = body.w - half, .h = body.h };

    drawPane(0, left);

    // The other pane is either the second listing or what the first one is
    // pointing at. Both panes on one folder is what a preview replaces: the
    // question a preview answers is about the file under the cursor, and the
    // pane beside it is the only room there is to answer it in.
    if (previewing) {
        preview.draw(ctx, right, underCursor());
    } else {
        drawPane(1, right);
    }

    drawKeys(keys);
}

/// What is mounted, read when something happens rather than while painting:
/// a paint happens whenever the pointer moves, and the mount table changes
/// only when a medium comes or goes, which is one of the moments the panes
/// are read again anyway.
var places: mounts.List = .{};

/// Read what is mounted. Says whether anything changed.
fn readPlaces() bool {
    var buf: [mounts.TEXT]u8 = undefined;
    return places.read(info.ask("mounts", &buf));
}

/// A medium can arrive while the window is open, and nothing tells a
/// program when one does. Looked for seldom, and the window is woken only
/// when the answer is different from last time.
fn tick() bool {
    return readPlaces();
}

/// Everything the window shows that comes from outside it: both panes'
/// listings, and the volumes they sit on.
fn refreshAll() void {
    for (&panes) |*pane| pane.refresh();
    _ = readPlaces();
}

/// The row of volumes, drawn by the toolkit and answered here.
///
/// Pressing one sends the pane you are in there. What the row is for and how
/// it looks belong to whichever window has one; where the pane goes belongs
/// here.
fn drawPlaces(area: Rect) void {
    const hint = [_]eui.keys.Key{.{ .key = "e", .label = "eject" }};
    const pass = eui.places.strip(ctx, area, &places, places.holding(here().path()), &hint);
    if (pass.chose) |index| goTo(places.slice()[index].path());
}

/// Whether a press landed in `area` this pass.
fn pressed(area: Rect) bool {
    return ctx.pressedThisPass() and area.contains(ctx.pointer_x, ctx.pointer_y);
}

fn goTo(where: []const u8) void {
    const pane = here();
    pane.setPath(where);
    pane.view = .{};
    pane.refresh();
    ctx.damage();
}

/// One side, as a table: the control already knows how to scroll a list,
/// keep a selection across a refresh and say which row was activated, and a
/// program that drew its own rows would be a program keeping all of that in
/// step by hand.
fn drawPane(index: usize, area: Rect) void {
    const t = theme.current();
    const pane = &panes[index];
    const items = pane.listing.items();

    // The head says where the pane is and how much is in it. A pane says
    // where it is once, and the table's own header row is where that goes;
    // the count belongs beside it rather than in a status bar shared with
    // the other pane, which could only ever say one of them.
    var counted: [24]u8 = @splat(0);
    var count = str.Builder{ .buf = &counted };
    count.quantity(items.len, "items");
    // A listing that did not fit says so, rather than reporting what it
    // holds as though that were the whole directory.
    if (pane.listing.truncated) count.text(" of more");

    const columns = [_]eui.table.Column{
        .{ .title = pane.path(), .width = theme.enlarged(80), .flex = true },
        .{ .title = count.done(), .width = theme.enlarged(72), .right = true },
    };

    // Which pane you are in is the one thing this window is always saying, so
    // the head of the one you are in is filled rather than merely outlined.
    pane.view.head_accent = index == active;
    pane.view.striped = true;

    var rows: [dir.MAX]eui.table.Row = undefined;
    for (items, 0..) |entry, i| {
        rows[i] = .{
            .cells = .{ entry.name, "", "", "", "", "" },
            // The same reading of what a file is that the preview uses, so
            // a row and the pane beside it cannot disagree about it.
            .icon = preview.Kind.icon(preview.Kind.of(entry)),
        };
        // Spelled into a store that outlives this loop, because a cell is a
        // slice and the table reads it after the row is built.
        if (!entry.is_dir) rows[i].cells[1] = spellSize(entry.size, sizeStore(index, i));
    }

    // The pane you are in has the keyboard, so the arrows walk its listing
    // without anybody having clicked it first.
    if (index == active) ctx.focusAt(area);

    if (ctx.table(area, &pane.view, &columns, rows[0..items.len])) |_| {
        if (index != active) {
            active = index;
            ctx.damage();
        }
        enter();
    }

    // Pressing anywhere in a pane makes it the one you are in, whether or not
    // a row was activated.
    if (ctx.pressedThisPass() and area.contains(ctx.pointer_x, ctx.pointer_y) and index != active) {
        active = index;
        ctx.damage();
    }
    _ = t;
}

/// Where a row's size text lives for the length of a pass. Sizes are spelled
/// per row and a cell is a slice, so the characters have to outlive the loop
/// that made them.
var size_store: [2][dir.MAX][12]u8 = undefined;

fn sizeStore(pane: usize, row: usize) []u8 {
    return &size_store[pane][row];
}

/// A size as a person reads it, which is three digits and a unit.
fn spellSize(bytes: u32, buf: []u8) []const u8 {
    var line = str.Builder{ .buf = buf };
    line.bytes(bytes);
    return line.done();
}

const KEYS = [_]eui.keys.Key{
    .{ .key = "\u{21C6}", .label = "pane" },
    .{ .key = "\u{21B5}", .label = "open" },
    .{ .key = "F3", .label = "preview" },
    .{ .key = "F5", .label = "copy" },
    .{ .key = "F6", .label = "move" },
    .{ .key = "F7", .label = "folder" },
    .{ .key = "F8", .label = "delete" },
};

/// The keys along the bottom, or the question that has taken their place.
fn drawKeys(area: Rect) void {
    if (prompt.isOpen()) {
        if (eui.prompt.run(ctx, area, &prompt)) |choice| answered(choice);
        return;
    }

    // The footer carries what just happened, or how much is in the pane, and
    // both change often enough that it is drawn every pass rather than being
    // guessed at.
    ctx.addDamage(area);

    // What just happened, if anything did. How much is in a pane is said in
    // that pane's own head, where it belongs to the pane it counts.
    eui.keys.bar(ctx.surface, area, &KEYS, status);
}

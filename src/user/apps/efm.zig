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

const eui = @import("eui");
const proto = @import("proto");
const sys = @import("sys");
const dir = @import("ulib").dir;
const info = @import("ulib").info;
const out = @import("ulib").out;
const paths = @import("ulib").paths;
const str = @import("ulib").str;

const theme = eui.theme;
const Rect = eui.Rect;
const ui = eui.widget;
const Surface = eui.Surface;

var connection: proto.Connection = undefined;
var window: u8 = 0;
var ctx: eui.Context = undefined;

var pointer_x: i32 = 0;
var pointer_y: i32 = 0;
var buttons: ui.Buttons = .{};

/// One side. Each carries its own name storage, because a listing's entries
/// point into it and two panes read two directories.
const Pane = struct {
    path_buf: [128]u8 = @splat(0),
    path_len: usize = 0,
    names: [dir.MAX * 12]u8 = undefined,
    listing: dir.Listing = .{},
    selected: usize = 0,
    /// First row on show, so a long directory scrolls rather than being cut.
    top: usize = 0,

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
        if (self.selected >= self.listing.items().len) {
            self.selected = self.listing.items().len -| 1;
        }
        self.top = 0;
    }

    fn current(self: *const Pane) ?dir.Entry {
        const items = self.listing.items();
        if (self.selected >= items.len) return null;
        return items[self.selected];
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
var answer: [64]u8 = @splat(0);
var answer_len: usize = 0;

/// What just happened, said in the footer until the next thing happens.
var status: []const u8 = "";

export fn _start() callconv(.c) noreturn {
    efmMain();
}

fn efmMain() noreturn {
    panes[0].setPath("/home");
    panes[1].setPath("/");
    for (&panes) |*pane| pane.refresh();

    connection = proto.client.Connection.open("efm") catch {
        out.text("efm: no window manager is running\n");
        out.flush();
        sys.exit(1);
    };

    window = connection.createWindow(.{}, 520, 360) catch sys.exit(1);
    connection.setTitle(window, "Files") catch {};

    run();
}

fn run() noreturn {
    while (true) {
        const event = connection.next(1_000_000) orelse continue;

        switch (event.tag) {
            .configure => resize(event.body.configure.w, event.body.configure.h),
            .ptr_motion => {
                pointer_x = event.body.motion.x;
                pointer_y = event.body.motion.y;
                redraw();
            },
            .ptr_button => {
                pointer_x = event.body.button.x;
                pointer_y = event.body.button.y;
                setButton(event.body.button.btn, event.body.button.down != 0);
                if (event.body.button.down != 0) pressed(pointer_x, pointer_y);
                redraw();
            },
            .scroll => {
                scroll(event.body.scroll.dy);
                redraw();
            },
            .key => {
                if (event.body.key.down == 0) continue;
                @import("ulib").log.note("efm", "key");
                key(@enumFromInt(event.body.key.code));
                redraw();
            },
            .text => {
                typed(event.body.text.cp);
                redraw();
            },
            .theme => {
                proto.client.applyTheme(&event.body.theme.name);
                ctx.damageNow();
                redraw();
            },
            .close_req => sys.exit(0),
            else => {},
        }
    }
}

fn setButton(index: u8, down: bool) void {
    switch (index) {
        0 => buttons.left = down,
        1 => buttons.right = down,
        2 => buttons.middle = down,
        else => {},
    }
}

fn resize(w: u16, h: u16) void {
    connection.attach(window, w, h) catch return;
    const surface = connection.surfaceOf(window) orelse return;

    ctx = eui.Context.init(surface.*);
    ctx.damageNow();
    draw();
    connection.map(window) catch {};
}

fn redraw() void {
    const surface = connection.surfaceOf(window) orelse return;
    ctx.surface = surface.*;
    draw();
    if (ctx.pending) draw();
}

// ---------------------------------------------------------------------------
// What the keys do
// ---------------------------------------------------------------------------

fn key(code: ui.KeyCode) void {
    // A question in the footer takes the keyboard until it is answered:
    // typing a folder's name into the listing behind it would move the
    // cursor instead.
    if (asking != .nothing) {
        switch (code) {
            .escape => stopAsking(),
            .enter => finishAsking(),
            .backspace => {
                if (answer_len > 0) answer_len -= 1;
                ctx.damage();
            },
            else => {},
        }
        return;
    }

    switch (code) {
        .tab => {
            active = 1 - active;
            ctx.damage();
        },
        .up => move(-1),
        .down => move(1),
        .page_up => move(-8),
        .page_down => move(8),
        .home => {
            here().selected = 0;
            ctx.damage();
        },
        .end => {
            here().selected = here().listing.items().len -| 1;
            ctx.damage();
        },
        .enter => enter(),
        .backspace => leave(),
        .f5 => transfer(.copy),
        .f6 => transfer(.move),
        .f7 => startAsking(.folder),
        .f8 => startAsking(.confirm_delete),
        else => {},
    }
}

fn typed(codepoint: u32) void {
    if (asking == .nothing or codepoint < ' ' or codepoint >= 0x7F) return;
    if (answer_len == answer.len) return;
    answer[answer_len] = @intCast(codepoint);
    answer_len += 1;
    ctx.damage();
}

fn move(by: i32) void {
    const pane = here();
    const count: i32 = @intCast(pane.listing.items().len);
    if (count == 0) return;

    var at: i32 = @intCast(pane.selected);
    at += by;
    pane.selected = @intCast(@max(0, @min(at, count - 1)));
    ctx.damage();
}

fn scroll(dy: i8) void {
    move(if (dy > 0) 1 else -1);
}

/// Open what the cursor is on: a directory is walked into, and anything else
/// is left alone. Running a program from here needs a way to say what it
/// should be opened with, which is a question this does not answer yet.
fn enter() void {
    const pane = here();
    const entry = pane.current() orelse return;
    if (!entry.is_dir) {
        status = "That is a file.";
        ctx.damage();
        return;
    }

    var buf: [160]u8 = undefined;
    const target = paths.join(pane.path(), entry.name, &buf);
    pane.setPath(target);
    pane.selected = 0;
    pane.refresh();
    ctx.damage();
}

/// Up one, which is what backspace means everywhere else a path is shown.
fn leave() void {
    const pane = here();
    const current = pane.path();
    if (current.len <= 1) return;

    var end = current.len;
    while (end > 1 and current[end - 1] != '/') end -= 1;
    if (end > 1) end -= 1;

    var buf: [128]u8 = undefined;
    const parent = current[0..@max(end, 1)];
    @memcpy(buf[0..parent.len], parent);

    pane.setPath(buf[0..parent.len]);
    pane.selected = 0;
    pane.refresh();
    ctx.damage();
}

const Transfer = enum { copy, move };

fn transfer(what: Transfer) void {
    const source = here();
    const destination = other();

    var from_buf: [160]u8 = undefined;
    const from = source.currentPath(&from_buf) orelse return;

    const entry = source.current().?;
    if (entry.is_dir) {
        status = "Directories are not carried yet.";
        ctx.damage();
        return;
    }

    var to_buf: [160]u8 = undefined;
    const to = paths.join(destination.path(), entry.name, &to_buf);

    const done = switch (what) {
        .copy => copyFile(from, to),
        // Renaming is the whole operation when both sides are one volume,
        // and a copy followed by a removal when they are not. The kernel
        // says which by refusing the rename.
        .move => sys.rename(from, to) >= 0 or (copyFile(from, to) and sys.unlink(from) >= 0),
    };

    status = if (done)
        (if (what == .copy) "Copied." else "Moved.")
    else
        "That did not work.";

    for (&panes) |*pane| pane.refresh();
    ctx.damage();
}

/// One file's bytes, a chunk at a time. The chunk is what the stack can hold
/// on a machine with this much memory, not what a disk would like.
fn copyFile(from: []const u8, to: []const u8) bool {
    const source = sys.open(from, .{});
    if (source < 0) return false;
    defer _ = sys.close(@intCast(source));

    const destination = sys.open(to, .{ .write = true, .create = true, .truncate = true });
    if (destination < 0) return false;
    defer _ = sys.close(@intCast(destination));

    while (true) {
        var chunk: [1024]u8 = undefined;
        const read = sys.read(@intCast(source), &chunk);
        if (read < 0) return false;
        if (read == 0) return true;

        const written = sys.write(@intCast(destination), chunk[0..@intCast(read)]);
        if (written != read) return false;
    }
}

fn startAsking(what: Asking) void {
    if (what == .confirm_delete and here().current() == null) return;
    asking = what;
    answer_len = 0;
    status = "";
    ctx.damage();
}

fn stopAsking() void {
    asking = .nothing;
    answer_len = 0;
    ctx.damage();
}

fn finishAsking() void {
    switch (asking) {
        .folder => {
            const name = answer[0..answer_len];
            if (name.len == 0) return stopAsking();

            var buf: [160]u8 = undefined;
            const target = paths.join(here().path(), name, &buf);
            status = if (sys.mkdir(target) >= 0) "Made." else "That did not work.";
        },
        .confirm_delete => {
            var buf: [160]u8 = undefined;
            const target = here().currentPath(&buf) orelse return stopAsking();
            const entry = here().current().?;

            // Whatever the filesystem will remove. A directory with anything
            // in it is refused there rather than here, which is the right
            // place for the rule: this program does not know what a volume
            // considers empty.
            status = if (sys.unlink(target) >= 0)
                (if (entry.is_dir) "Removed." else "Deleted.")
            else
                (if (entry.is_dir) "It will not go; is it empty?" else "That did not work.");
        },
        .nothing => {},
    }

    stopAsking();
    for (&panes) |*pane| pane.refresh();
}

// ---------------------------------------------------------------------------
// Drawing
// ---------------------------------------------------------------------------

/// The strip along the top: what is mounted, from the kernel's own list.
const VOLUMES_HEIGHT: i32 = 26;

fn draw() void {
    const t = theme.current();
    const surface = ctx.surface;
    const area = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };

    ctx.begin(pointer_x, pointer_y, buttons);
    // Everything here is painted by hand rather than through controls, so
    // nothing registers itself as changed. The manager is told the whole
    // window when the whole window was drawn, or it puts none of it up.
    const whole = ctx.damaged;

    const volumes = Rect{ .x = 0, .y = 0, .w = area.w, .h = theme.enlarged(VOLUMES_HEIGHT) };
    const keys = eui.footer.strip(area);
    const body = Rect{
        .x = 0,
        .y = volumes.bottom(),
        .w = area.w,
        .h = keys.y - volumes.bottom(),
    };

    drawVolumes(volumes);

    const half = @divTrunc(body.w, 2);
    drawPane(0, .{ .x = 0, .y = body.y, .w = half, .h = body.h });
    drawPane(1, .{ .x = half, .y = body.y, .w = body.w - half, .h = body.h });

    drawKeys(keys);

    if (whole) ctx.addDamage(area);
    ctx.end();
    connection.commit(window, ctx.damageList()) catch {};
    _ = t;
}

fn drawVolumes(area: Rect) void {
    const t = theme.current();
    if (!ctx.damaged) return;

    ctx.surface.fill(area, t.surface_pressed);
    ctx.surface.fill(.{ .x = area.x, .y = area.bottom() - 1, .w = area.w, .h = 1 }, t.line);

    var buf: [256]u8 = undefined;
    const mounted = info.ask("mounts", &buf);

    var x = area.x + t.menu_padding;
    var lines = str.lines(mounted);
    while (lines.next()) |line| {
        const text = str.trim(line);
        if (text.len == 0) continue;

        const width = Surface.textWidth(text) + t.menu_padding * 2;
        if (x + width > area.right()) break;

        ctx.surface.clipped(area).text(
            x,
            area.y + @divTrunc(area.h - Surface.textHeight(), 2),
            text,
            t.text,
        );
        x += width;
    }
}

fn rowHeight() i32 {
    return theme.current().menu_row_height;
}

fn drawPane(index: usize, area: Rect) void {
    const t = theme.current();
    const pane = &panes[index];
    const focused = index == active;

    const head = Rect{ .x = area.x, .y = area.y, .w = area.w, .h = theme.enlarged(20) };
    if (ctx.damaged) {
        ctx.surface.fill(head, if (focused) t.accent else t.surface_pressed);
        ctx.surface.clipped(head).text(
            head.x + t.padding,
            head.y + @divTrunc(head.h - Surface.textHeight(), 2),
            pane.path(),
            if (focused) t.accent_text else t.text_dim,
        );
        // A hairline between the panes, so two listings do not read as one.
        if (index == 1) {
            ctx.surface.fill(.{ .x = area.x, .y = area.y, .w = 1, .h = area.h }, t.line);
        }
    }

    const rows = Rect{
        .x = area.x + (if (index == 1) @as(i32, 1) else 0),
        .y = head.bottom(),
        .w = area.w - (if (index == 1) @as(i32, 1) else 0),
        .h = area.bottom() - head.bottom(),
    };
    if (ctx.damaged) ctx.surface.fill(rows, t.surface);

    const height = rowHeight();
    const visible: usize = @intCast(@max(0, @divTrunc(rows.h, height)));
    keepInView(pane, visible);

    const items = pane.listing.items();
    var y = rows.y;
    var row = pane.top;
    while (row < items.len and y + height <= rows.bottom()) : (row += 1) {
        drawRow(pane, items[row], .{ .x = rows.x, .y = y, .w = rows.w, .h = height }, row == pane.selected, focused);
        y += height;
    }
}

/// Scroll so the cursor is on a row that exists on the screen.
fn keepInView(pane: *Pane, visible: usize) void {
    if (visible == 0) return;
    if (pane.selected < pane.top) pane.top = pane.selected;
    if (pane.selected >= pane.top + visible) pane.top = pane.selected - visible + 1;
}

fn drawRow(pane: *const Pane, entry: dir.Entry, area: Rect, selected: bool, focused: bool) void {
    _ = pane;
    const t = theme.current();

    // The cursor in the pane you are not in is still drawn, quieter: it is
    // where a copy would land, and a pane that forgot it would make you look.
    const ground = if (selected and focused) t.accent else if (selected) t.surface_pressed else t.surface;
    const ink = if (selected and focused) t.accent_text else t.text;

    ctx.surface.fill(area, ground);
    const clipped = ctx.surface.clipped(area);

    clipped.icon(
        area.x + t.padding,
        area.y + @divTrunc(area.h - Surface.iconSize(), 2),
        if (entry.is_dir) .folder else .document,
        ink,
    );

    const baseline = area.y + @divTrunc(area.h - Surface.textHeight(), 2);
    clipped.text(area.x + t.padding + Surface.iconSize() + t.padding, baseline, entry.name, ink);

    if (!entry.is_dir) {
        var buf: [16]u8 = undefined;
        const size = spellSize(entry.size, &buf);
        clipped.text(
            area.right() - t.padding - Surface.textWidth(size),
            baseline,
            size,
            if (selected and focused) t.accent_text else t.text_dim,
        );
    }
}

/// A size as a person reads it, which is three digits and a unit.
fn spellSize(bytes: u32, buf: []u8) []const u8 {
    var line = str.Builder{ .buf = buf };
    if (bytes < 1024) {
        line.number(bytes);
        line.byte('B');
    } else if (bytes < 1024 * 1024) {
        line.number(bytes / 1024);
        line.byte('K');
    } else {
        line.number(bytes / (1024 * 1024));
        line.byte('M');
    }
    return line.done();
}

const Key = struct { key: []const u8, label: []const u8 };

const KEYS = [_]Key{
    .{ .key = "Tab", .label = "pane" },
    .{ .key = "Ret", .label = "open" },
    .{ .key = "F5", .label = "copy" },
    .{ .key = "F6", .label = "move" },
    .{ .key = "F7", .label = "folder" },
    .{ .key = "F8", .label = "delete" },
};

/// The keys along the bottom, or the question that has taken their place.
fn drawKeys(area: Rect) void {
    const t = theme.current();

    if (asking != .nothing) return drawQuestion(area);

    if (!ctx.damaged and status.len == 0) return;
    ctx.surface.fill(area, t.bar);
    ctx.surface.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, t.line);

    var x = area.x + t.padding;
    const baseline = area.y + @divTrunc(area.h - Surface.textHeight(), 2);

    for (KEYS) |entry| {
        const chip = Rect{
            .x = x,
            .y = area.y + t.padding,
            .w = Surface.textWidth(entry.key) + t.padding,
            .h = area.h - t.padding * 2,
        };
        const label_w = Surface.textWidth(entry.label);
        if (chip.right() + t.padding + label_w > area.right()) break;

        ctx.surface.fill(chip, t.accent);
        ctx.surface.textCentred(chip, entry.key, t.accent_text);
        ctx.surface.text(chip.right() + t.padding, baseline, entry.label, t.bar_text);

        x = chip.right() + t.padding + label_w + t.menu_padding;
    }

    if (status.len > 0) {
        const width = Surface.textWidth(status);
        if (x + width < area.right()) {
            ctx.surface.text(area.right() - t.menu_padding - width, baseline, status, t.bar_text);
        }
    }
}

/// One line of the footer, borrowed to ask something. A question where the
/// answer will land beats a window that covers what you were looking at.
fn drawQuestion(area: Rect) void {
    const t = theme.current();
    ctx.surface.fill(area, t.bar);
    ctx.surface.fill(.{ .x = area.x, .y = area.y, .w = area.w, .h = 1 }, t.line);

    const baseline = area.y + @divTrunc(area.h - Surface.textHeight(), 2);
    var x = area.x + t.menu_padding;

    const question = switch (asking) {
        .folder => "New folder:",
        .confirm_delete => "Delete, then? Enter to go on, Escape to stop:",
        .nothing => "",
    };
    ctx.surface.text(x, baseline, question, t.bar_text);
    x += Surface.textWidth(question) + t.gap;

    if (asking == .folder) {
        const typed_text = answer[0..answer_len];
        ctx.surface.text(x, baseline, typed_text, t.accent_text);
        ctx.surface.fill(.{
            .x = x + Surface.textWidth(typed_text) + 2,
            .y = baseline,
            .w = 2,
            .h = Surface.textHeight(),
        }, t.accent_text);
    } else {
        var buf: [160]u8 = undefined;
        if (here().currentPath(&buf)) |target| {
            ctx.surface.clipped(area).text(x, baseline, target, t.warning);
        }
    }
}

/// A press moves the cursor, and a press in the pane you are not in moves to
/// that pane first: clicking a row and having the click land on the other
/// side would be the alternative.
fn pressed(x: i32, y: i32) void {
    const surface = ctx.surface;
    const area = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };
    const volumes = theme.enlarged(VOLUMES_HEIGHT);
    const keys = eui.footer.strip(area);
    if (y < volumes or y >= keys.y) return;

    const half = @divTrunc(area.w, 2);
    const which: usize = if (x < half) 0 else 1;
    if (which != active) {
        active = which;
        ctx.damage();
    }

    const pane = &panes[which];
    const head = theme.enlarged(20);
    const first = volumes + head;
    if (y < first) return;

    const row = pane.top + @as(usize, @intCast(@divTrunc(y - first, rowHeight())));
    if (row < pane.listing.items().len) {
        pane.selected = row;
        ctx.damage();
    }
}

//! A file dialog in its own floating window.
//!
//! The window half of `eui.chooser`: it opens a floating window, fills the
//! panel from a real directory, and pumps its own events. Here rather than in
//! the toolkit because opening a window means talking to the manager, and a
//! toolkit that did that would be one every program had to link a client into
//! whether it drew a window or not.
//!
//! A second window rather than a panel inside the first. The manager already
//! floats and centres a window marked as a dialog, so borrowing that is both
//! less code and the behaviour a person expects: the dialog can be moved, and
//! what is behind it stays where it was.

const std = @import("std");
const client = @import("client.zig");
const eui = @import("eui");
const sys = @import("sys");
const ulib = @import("ulib");
const wm = @import("wm.zig");

const chooser = eui.chooser;
const dir = ulib.dir;

pub const Purpose = chooser.Purpose;

pub const Result = enum { pending, chosen, cancelled };

/// The longest directory path the dialog will hold.
const MAX_PATH = 96;

pub const FileDialog = struct {
    window: u8 = 0,
    showing: bool = false,
    result: Result = .pending,

    panel: chooser.Chooser = .{},
    ctx: eui.Context = undefined,

    pointer_x: i32 = 0,
    pointer_y: i32 = 0,
    buttons: eui.widget.Buttons = .{},

    /// The directory being shown, always with a trailing separator so a name
    /// can be appended without deciding whether one is needed.
    path: [MAX_PATH]u8 = @splat(0),
    path_len: usize = 0,

    listing: dir.Listing = .{},
    names: [dir.MAX * 16]u8 = undefined,
    entries: [dir.MAX]chooser.Entry = undefined,
    entry_count: usize = 0,

    /// The full path of what was chosen, valid once `result` is `.chosen`.
    answer: [MAX_PATH + chooser.MAX_NAME]u8 = @splat(0),
    answer_len: usize = 0,

    /// Open the dialog. `start` is the name to put in the field, which for a
    /// save is what the document is already called.
    pub fn show(
        self: *FileDialog,
        connection: *client.Connection,
        purpose: Purpose,
        start: []const u8,
    ) !void {
        if (self.showing) return;

        self.panel.init(purpose, start);
        self.result = .pending;
        self.answer_len = 0;

        if (self.path_len == 0) self.setPath("/");
        self.reload();

        self.window = try connection.createWindow(.{ .dialog = true }, 320, 240);
        try connection.setTitle(self.window, switch (purpose) {
            .open => "Open",
            .save => "Save as",
        });
        self.showing = true;
    }

    pub fn hide(self: *FileDialog, connection: *client.Connection) void {
        if (!self.showing) return;
        connection.destroyWindow(self.window) catch {};
        self.showing = false;
    }

    /// Whether an event belongs to the dialog rather than to the application.
    pub fn owns(self: *const FileDialog, event: wm.Ev) bool {
        return self.showing and event.win == self.window;
    }

    /// The path that was chosen, valid once `result` is `.chosen`.
    pub fn chosen(self: *const FileDialog) []const u8 {
        return self.answer[0..self.answer_len];
    }

    // -----------------------------------------------------------------------
    // The directory
    // -----------------------------------------------------------------------

    fn setPath(self: *FileDialog, value: []const u8) void {
        const n = @min(value.len, MAX_PATH - 1);
        @memcpy(self.path[0..n], value[0..n]);
        self.path_len = n;
        if (self.path_len == 0 or self.path[self.path_len - 1] != '/') {
            self.path[self.path_len] = '/';
            self.path_len += 1;
        }
    }

    fn reload(self: *FileDialog) void {
        self.entry_count = 0;
        dir.read(self.path[0..self.path_len], &self.names, &self.listing) catch {
            self.listing = .{};
            return;
        };

        for (self.listing.items()) |entry| {
            self.entries[self.entry_count] = .{
                .name = entry.name,
                .size = entry.size,
                .is_dir = entry.is_dir,
            };
            self.entry_count += 1;
        }
        self.panel.list = .{};
        self.panel.filled_from = null;
    }

    fn descend(self: *FileDialog) void {
        if (self.panel.chosen >= self.entry_count) return;

        const name = self.entries[self.panel.chosen].name;
        if (std.mem.eql(u8, name, dir.PARENT)) {
            self.ascend();
            return;
        }

        if (self.path_len + name.len + 1 >= MAX_PATH) return;

        @memcpy(self.path[self.path_len..][0..name.len], name);
        self.path_len += name.len;
        self.path[self.path_len] = '/';
        self.path_len += 1;

        self.reload();
    }

    /// Drop the last component, which is what `..` means.
    fn ascend(self: *FileDialog) void {
        // The trailing separator is always there, so the component to remove
        // is what lies between the last two.
        if (self.path_len <= 1) return;

        var at = self.path_len - 1;
        while (at > 0 and self.path[at - 1] != '/') at -= 1;

        self.path_len = at;
        self.reload();
    }

    fn accept(self: *FileDialog) void {
        const name = self.panel.typed();
        var n: usize = 0;

        // An absolute name replaces the directory rather than joining it, so
        // typing a full path does what typing a full path should.
        if (name.len > 0 and name[0] == '/') {
            @memcpy(self.answer[0..name.len], name);
            n = name.len;
        } else {
            @memcpy(self.answer[0..self.path_len], self.path[0..self.path_len]);
            n = self.path_len;
            @memcpy(self.answer[n..][0..name.len], name);
            n += name.len;
        }

        self.answer_len = n;
        self.result = .chosen;
    }

    // -----------------------------------------------------------------------
    // Its own events
    // -----------------------------------------------------------------------

    /// Handle one event for the dialog's window. Returns true once it is
    /// finished, chosen or cancelled, and the caller should hide it.
    pub fn handle(self: *FileDialog, connection: *client.Connection, event: wm.Ev) bool {
        switch (event.tag) {
            .configure => {
                connection.attach(self.window, event.body.configure.w, event.body.configure.h) catch return false;
                const surface = connection.surfaceOf(self.window) orelse return false;
                self.ctx = eui.Context.init(surface.*);
                self.ctx.damageNow();
                self.draw(connection);
                connection.map(self.window) catch {};
                return false;
            },
            .ptr_motion => {
                self.pointer_x = event.body.motion.x;
                self.pointer_y = event.body.motion.y;
            },
            .ptr_button => {
                self.pointer_x = event.body.button.x;
                self.pointer_y = event.body.button.y;
                switch (event.body.button.btn) {
                    0 => self.buttons.left = event.body.button.down != 0,
                    1 => self.buttons.right = event.body.button.down != 0,
                    2 => self.buttons.middle = event.body.button.down != 0,
                    else => {},
                }
            },
            .scroll => self.ctx.postScroll(event.body.scroll.dy),
            .key => {
                if (event.body.key.down == 0) return false;
                // Escape leaves, which is what every dialog does and the first
                // thing anyone tries.
                if (event.body.key.code == @intFromEnum(sys.KeyCode.escape)) {
                    self.result = .cancelled;
                    return true;
                }
                self.ctx.postKey(@intCast(event.body.key.code), @bitCast(event.body.key.mods));
            },
            .text => self.ctx.postText(event.body.text.cp),
            .theme, .look => {
                _ = connection.adoptLook(event);
                self.ctx.damage();
            },
            .close_req => {
                self.result = .cancelled;
                return true;
            },
            .overflow => self.ctx.damage(),
            else => return false,
        }

        self.draw(connection);
        if (self.ctx.pending) self.draw(connection);
        return self.result != .pending;
    }

    fn draw(self: *FileDialog, connection: *client.Connection) void {
        const surface = connection.surfaceOf(self.window) orelse return;
        self.ctx.surface = surface.*;

        const t = eui.theme.current();
        const area = eui.Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };

        self.ctx.begin(self.pointer_x, self.pointer_y, self.buttons);
        if (self.ctx.damaged) surface.fill(area, t.surface);

        switch (chooser.run(
            &self.ctx,
            area,
            &self.panel,
            self.path[0..self.path_len],
            self.entries[0..self.entry_count],
        )) {
            .none => {},
            .descend => {
                self.descend();
                self.ctx.damage();
            },
            .accepted => self.accept(),
            .cancelled => self.result = .cancelled,
        }

        self.ctx.end();
        connection.commit(self.window, self.ctx.damageList()) catch {};
    }
};

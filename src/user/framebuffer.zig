//! A virtual framebuffer: a fixed logical surface, shown wherever there is
//! room for it.
//!
//! A program that draws its own pixels wants a rectangle of a size it chose
//! and does not want to hear about anything else. This gives it that, then
//! puts it on screen: in an ordinary desktop window, where it can be tiled,
//! resized and scaled like any other, or on the bare framebuffer when no
//! desktop is running. The program's own loop is the same either way, so a
//! port is written once rather than twice.
//!
//! The C ABI in libc/vibeee.zig is a thin door onto this type; native Zig
//! programs use it directly.

const display = @import("ulib").display;
const eui = @import("eui");
const heap = @import("ulib").heap;
const proto = @import("proto");
const std = @import("std");
const sys = @import("sys");

pub const Mode = enum { windowed, fullscreen };

pub const Error = error{ InvalidSize, NoMemory, Closed } ||
    proto.client.Error || display.Error;

/// Where the picture goes.
const Shown = union(enum) {
    /// A window on the desktop. The manager decides the surface's size and
    /// says so; the logical framebuffer keeps the size the program chose.
    desktop: struct { connection: proto.client.Connection, id: u8 },
    /// The framebuffer itself, on a machine with no desktop running. Its
    /// keys come from the kernel, there being no manager to send them.
    screen: display.Screen,
};

pub const Window = struct {
    shown: Shown,
    pixels: []u32,
    width: u16,
    height: u16,
    closed: bool = false,

    /// Open a virtual framebuffer with its own fixed logical size.
    ///
    /// The desktop first, because a program started from a desktop belongs in
    /// it. Without one the screen itself, which is how a machine that boots to
    /// a shell still runs the program.
    pub fn open(title: []const u8, width: u16, height: u16, mode: Mode) Error!Window {
        if (width == 0 or height == 0) return error.InvalidSize;
        const count = std.math.mul(usize, width, height) catch return error.InvalidSize;
        const pixels = heap.allocator.alloc(u32, count) catch return error.NoMemory;
        errdefer heap.allocator.free(pixels);
        @memset(pixels, 0);

        var window = Window{
            .shown = try showSomewhere(title, width, height, mode),
            .pixels = pixels,
            .width = width,
            .height = height,
        };
        errdefer window.close();

        if (window.shown == .desktop) try window.waitForSurface();
        return window;
    }

    /// The program's logical framebuffer. Its stride is always `width`.
    pub fn surface(self: *Window) []u32 {
        return self.pixels;
    }

    /// Draw the logical framebuffer where the window is shown.
    ///
    /// It is scaled as large as there is room for, keeping its proportions,
    /// with black where they leave the surface uncovered. The scaling is the
    /// toolkit's own, the same one the picture viewer draws with: a program's
    /// pixels are a picture, and there is no reason for a second scaler.
    pub fn present(self: *Window) Error!void {
        if (self.closed) return error.Closed;
        const onto = self.showsOn() orelse return error.Closed;
        if (onto.width <= 0 or onto.height <= 0) return error.Closed;

        const area = eui.Rect{ .x = 0, .y = 0, .w = onto.width, .h = onto.height };
        const where = eui.thumb.fitAs(area, self.width, self.height, .fill);

        // The picture first and the ground it leaves uncovered after, rather
        // than a clear and a draw over it: the compositor reads this surface
        // while the program is drawing into it, and a clear it caught in the
        // middle is a black band across the picture.
        eui.thumb.paint(
            onto,
            where,
            .{ .pixels = self.pixels, .width = self.width, .height = self.height },
            .up,
        );
        onto.fillAround(area, where, 0);

        switch (self.shown) {
            .desktop => |*on| try on.connection.commit(on.id, &.{area}),
            // The scanout buffer is the screen: drawing into it is showing it.
            .screen => {},
        }
    }

    /// Take the next event, waiting at most `timeout_us` microseconds.
    ///
    /// One shape of event whichever way the window is shown, so a program
    /// reads its keyboard once. Configure events are answered here rather
    /// than passed on: the logical framebuffer keeps its size while the
    /// surface it is shown on is replaced.
    pub fn next(self: *Window, timeout_us: usize) ?proto.wm.Ev {
        return switch (self.shown) {
            .desktop => self.nextFromDesktop(timeout_us),
            .screen => self.nextFromKeyboard(timeout_us),
        };
    }

    pub fn close(self: *Window) void {
        switch (self.shown) {
            .desktop => |*on| on.connection.destroyWindow(on.id) catch {},
            .screen => |*on| on.release(),
        }
        self.closed = true;
        if (self.pixels.len > 0) {
            heap.allocator.free(self.pixels);
            self.pixels = &.{};
        }
    }

    fn showSomewhere(title: []const u8, width: u16, height: u16, mode: Mode) Error!Shown {
        if (proto.client.Connection.open(title)) |opened| {
            var connection = opened;
            const id = try connection.createWindow(
                .{ .fullscreen = mode == .fullscreen },
                width,
                height,
            );
            errdefer connection.destroyWindow(id) catch {};
            try connection.setTitle(id, title);
            return .{ .desktop = .{ .connection = connection, .id = id } };
        } else |_| {
            // Why the screen could not be had is worth keeping: a machine in
            // text mode and a machine whose display is somebody else's are
            // different problems with different answers.
            return .{ .screen = try display.take() };
        }
    }

    /// What to draw into: the window's surface, or the screen.
    fn showsOn(self: *Window) ?eui.Surface {
        return switch (self.shown) {
            .desktop => |*on| (on.connection.surfaceOf(on.id) orelse return null).*,
            .screen => |*on| eui.Surface.init(
                on.pixels,
                on.info.width,
                on.info.height,
                on.info.stride_px,
            ),
        };
    }

    fn nextFromDesktop(self: *Window, timeout_us: usize) ?proto.wm.Ev {
        const on = &self.shown.desktop;
        while (!self.closed) {
            const event = on.connection.next(timeout_us) orelse return null;
            switch (event.tag) {
                .configure => self.configure(event.body.configure.w, event.body.configure.h) catch {
                    self.closed = true;
                    return .{ .tag = .close_req, .win = on.id };
                },
                .theme, .look => _ = on.connection.adoptLook(event),
                .close_req => {
                    self.closed = true;
                    return event;
                },
                else => return event,
            }
        }
        return null;
    }

    /// A key from the kernel, in the shape the desktop would have sent it.
    fn nextFromKeyboard(self: *Window, timeout_us: usize) ?proto.wm.Ev {
        if (self.closed) return null;
        var one: [1]sys.KeyEvent = undefined;
        const taken = sys.keyRead(&one, timeout_us) orelse return null;
        if (taken.len == 0) return null;
        return .{
            .tag = .key,
            .t_us = @truncate(sys.clockMicros()),
            .body = .{ .key = .{
                .code = taken[0].code,
                .down = taken[0].pressed,
                .mods = taken[0].modifiers,
                .codepoint = taken[0].codepoint,
            } },
        };
    }

    fn waitForSurface(self: *Window) Error!void {
        const on = &self.shown.desktop;
        while (true) {
            const event = on.connection.next(sys.FOREVER) orelse return error.Closed;
            switch (event.tag) {
                .configure => return self.configure(event.body.configure.w, event.body.configure.h),
                .theme, .look => _ = on.connection.adoptLook(event),
                .close_req => return error.Closed,
                else => {},
            }
        }
    }

    fn configure(self: *Window, width: u16, height: u16) Error!void {
        const on = &self.shown.desktop;
        try on.connection.attach(on.id, width, height);
        try on.connection.map(on.id);
    }
};

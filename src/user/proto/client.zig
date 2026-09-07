//! The client half of the window protocol.
//!
//! Every application talks to the window manager through this, so the sequence
//! in design/10-gui.md §5.2 is written once rather than in each app: connect,
//! create, attach a surface, draw, commit, map. An app that hand-rolled it
//! would get the order subtly wrong and the bug would look like a server bug.
//!
//! Holds no widgets and draws nothing. It hands back a surface and a stream of
//! events; what goes in the surface is `libeui`'s business and the app's.

const std = @import("std");
const eui = @import("eui");
const lib = @import("lib");
const sys = @import("sys");
const wm = @import("wm.zig");

const limits = lib.limits;
const ring = lib.ring;

pub const Error = error{
    /// No window manager is registered.
    NoServer,
    /// The server speaks a different version of the protocol.
    VersionMismatch,
    Refused,
    OutOfMemory,
    /// No free window slot in this client.
    NoRoom,
};

/// The largest surface a window may be given. A screen's worth on this
/// machine is under a megabyte and a half; the cap is what stops a size
/// the server sent from asking for memory nothing has.
const MAX_SURFACE_BYTES: u64 = 16 * 1024 * 1024;

pub const Window = struct {
    id: u8 = 0,
    /// Where the client draws. Valid until the next `configure` changes the
    /// size, at which point it is replaced.
    surface: eui.Surface = undefined,
    width: u16 = 0,
    height: u16 = 0,
    /// The segment behind the surface, kept so it can be released on resize.
    handle: u32 = 0,
    /// Where that segment is mapped, kept for the same reason: the mapping
    /// holds the segment as much as the handle does, so closing the handle
    /// alone leaves the frames where they are and the window's addresses
    /// spent. A program that resizes for as long as it runs would run out
    /// of both.
    pixels: ?[*]u8 = null,
    used: bool = false,

    /// Let go of the surface: the mapping first, then the handle.
    fn dropSurface(self: *Window) void {
        if (self.pixels) |at| sys.shmUnmap(at);
        if (self.handle != 0) sys.close(self.handle);
        self.pixels = null;
        self.handle = 0;
    }
};

pub const Connection = struct {
    /// How the desktop looks, as last told. Kept here because it arrives in
    /// two records and every window this program has draws in the whole of
    /// it after either.
    look: wm.Appearance = .{},

    channel: u32 = 0,
    generation: u16 = 0,
    screen_w: u16 = 0,
    screen_h: u16 = 0,

    /// Server to client, read without a syscall. A keystroke costing a trap
    /// would be a keystroke costing too much.
    events: ring.Ring = undefined,
    event_signal: u32 = 0,

    windows: [wm.MAX_WINDOWS_PER_CLIENT]Window = @splat(.{}),

    /// Connect and introduce ourselves.
    pub fn open(name: []const u8) Error!Connection {
        const channel = sys.svcConnect(wm.SERVICE) catch return error.NoServer;
        var self = Connection{ .channel = channel };

        var req = wm.Req{ .tag = .hello };
        req.body = .{ .hello = .{ .proto = wm.VERSION, .app_name = @splat(0) } };
        const n = @min(name.len, req.body.hello.app_name.len);
        @memcpy(req.body.hello.app_name[0..n], name[0..n]);

        var reply: sys.Message = .{};
        const message = sys.Message.init(std.mem.asBytes(&req), &.{});
        sys.callMsg(self.channel, &message, &reply) catch return error.Refused;

        const rep: *const wm.Rep = @ptrCast(@alignCast(&reply.data));
        if (rep.status == .bad_version) return error.VersionMismatch;
        if (rep.status != .ok) return error.Refused;

        self.generation = rep.gen;
        self.screen_w = rep.body.hello.screen_w;
        self.screen_h = rep.body.hello.screen_h;
        self.look = rep.body.hello.look;
        applyAppearance(self.look);

        // Three handles come back: the event ring's memory, the event that
        // says there is something in it, and the faces every window draws
        // with, which the manager holds one copy of.
        if (reply.handle_count < 3) return error.Refused;

        const ring_handle = reply.handles[0];
        self.event_signal = reply.handles[1];

        const base = sys.shmMap(ring_handle, .{ .writable = true }) orelse return error.OutOfMemory;
        const header: *volatile ring.Header = @ptrCast(@alignCast(base));
        self.events = ring.Ring.attach(header, base[4096 .. 4096 + wm.EVENT_RING_BYTES]) catch
            return error.Refused;

        // Mapped read-only: the glyphs are the manager's, and a client that
        // could write them would be drawing in every other window too.
        const size = sys.shmSize(reply.handles[2]) orelse return error.Refused;
        const fonts = sys.shmMap(reply.handles[2], .{}) orelse return error.OutOfMemory;
        if (!eui.draw.use(fonts[0..size])) return error.Refused;

        return self;
    }

    /// Ask for a window and a surface to draw into.
    ///
    /// The server decides the geometry: this is a tiling manager, and a client
    /// that picked its own size would be told a different one immediately.
    /// What the client asks for is a minimum, and what it gets is a
    /// `configure` event.
    pub fn createWindow(self: *Connection, placement: wm.Placement, min_w: u16, min_h: u16) Error!u8 {
        var req = wm.Req{ .tag = .create_win };
        req.body = .{ .create = .{
            .placement = placement,
            .min_w = min_w,
            .min_h = min_h,
            .tag_hint = 0,
        } };

        // A slot on this side first: the server's window is a thing that
        // exists once it is made, and one made with nowhere here to record
        // it is a window nothing can name, take down, or draw into, still
        // counting against what this client may have.
        const slot = for (&self.windows) |*w| {
            if (!w.used) break w;
        } else return error.NoRoom;

        const rep = try self.request(&req, &.{});
        if (rep.status != .ok) return error.Refused;

        const id = rep.body.create.win;
        slot.* = .{ .id = id, .used = true };
        return id;
    }

    /// Allocate a surface of `w` by `h` and give the server a handle to it.
    ///
    /// Called on creation and again whenever a `configure` changes the size.
    /// The old segment is released after the new one is attached, so the
    /// server never has a moment with no surface to read.
    /// Map the one clipboard every window shares.
    ///
    /// Mapped once and kept: pasting is then a read of memory the manager
    /// wrote, with no syscall and nobody to wait for. Copying still goes
    /// through the manager, because the length everyone else reads has to be
    /// somebody's word rather than every client's.
    pub fn clipboard(self: *Connection) Error![]u8 {
        if (clip.len > 0) return clip;

        var req = wm.Req{ .tag = .clipboard };
        req.body = .{ .clip = .{ .len = 0 } };

        var handles: [1]u32 = undefined;
        const rep = try self.requestWithHandles(&req, &.{}, &handles);
        if (rep.status != .ok) return error.Refused;

        const mapped = sys.shmMap(handles[0], .{ .writable = true }) orelse
            return error.OutOfMemory;

        clip = @as([*]u8, @ptrCast(mapped))[0..wm.CLIPBOARD_BYTES];
        return clip;
    }

    /// What is on the clipboard now. Empty until something copies.
    pub fn clipboardText(self: *Connection) []const u8 {
        const mapped = self.clipboard() catch return "";
        return wm.clipboardText(mapped);
    }

    /// Put `text` on the clipboard, as much of it as fits.
    pub fn clipboardPut(self: *Connection, text: []const u8) void {
        const mapped = self.clipboard() catch return;
        const room = mapped.len - @sizeOf(wm.ClipHead);
        const n = @min(text.len, room);
        @memcpy(mapped[@sizeOf(wm.ClipHead)..][0..n], text[0..n]);

        var req = wm.Req{ .tag = .clipboard_put };
        req.body = .{ .clip = .{ .len = @intCast(n) } };
        _ = self.request(&req, &.{}) catch {};
    }

    pub fn attach(self: *Connection, id: u8, w: u16, h: u16) Error!void {
        const window = self.find(id) orelse return error.Refused;

        // Stride rounded to 16 pixels: the compositor's blit wants 64-byte
        // alignment, and a client that ignored it would force the slow path on
        // every row.
        //
        // Worked out in sixty-four bits from a width and a height the server
        // sent: a `usize` here is thirty-two, and a size near the top of the
        // sixteen bits they arrive in would wrap to something small, leaving
        // a surface that says it is large backed by a segment that is not.
        const stride: u32 = (@as(u32, w) + 15) & ~@as(u32, 15);
        const bytes = @as(u64, stride) * h * 4;
        if (bytes == 0 or bytes > MAX_SURFACE_BYTES) return error.Refused;

        const handle = sys.shmCreate(@intCast(bytes)) catch return error.OutOfMemory;
        // Nothing half done: what this made is given back on every way out
        // that is not the one where the window takes it.
        var taken = false;
        defer if (!taken) {
            sys.close(@intCast(handle));
        };

        const pixels = sys.shmMap(@intCast(handle), .{ .writable = true }) orelse
            return error.OutOfMemory;
        var mapped = true;
        defer if (!taken and mapped) {
            sys.shmUnmap(pixels);
        };

        var req = wm.Req{ .tag = .attach, .win = id };
        req.body = .{ .attach = .{ .w = w, .h = h, .stride_px = @intCast(stride) } };

        const rep = try self.request(&req, &.{@intCast(handle)});
        if (rep.status != .ok) return error.Refused;

        // The server has the replacement, so the one it replaces goes: the
        // mapping as well as the handle, since either alone keeps the
        // frames.
        window.dropSurface();
        taken = true;
        mapped = false;
        window.handle = @intCast(handle);
        window.pixels = pixels;
        window.width = w;
        window.height = h;
        window.surface = eui.Surface.init(@ptrCast(@alignCast(pixels)), w, h, @intCast(stride));
    }

    /// Tell the server what changed. It reads the surface and composites.
    pub fn commit(self: *Connection, id: u8, damage: []const eui.Rect) Error!void {
        var req = wm.Req{ .tag = .commit, .win = id };

        var rects: [3]wm.Rect = @splat(.{});
        const n = @min(damage.len, rects.len);
        for (damage[0..n], 0..) |r, i| rects[i] = toWire(r);

        // Anything past three merges into a bounding box rather than being
        // dropped: a lost rectangle is a stale patch of screen that nothing
        // will ever repaint.
        if (damage.len > rects.len) {
            var all = damage[rects.len - 1];
            for (damage[rects.len..]) |r| all = all.unite(r);
            rects[rects.len - 1] = toWire(all);
        }

        req.body = .{ .commit = .{ .n = @intCast(if (damage.len > n) rects.len else n), .rects = rects } };
        _ = try self.request(&req, &.{});
    }

    pub fn setTitle(self: *Connection, id: u8, text: []const u8) Error!void {
        var req = wm.Req{ .tag = .set_title, .win = id };
        req.body = .{ .title = .{ .len = 0, .text = @splat(0) } };
        const n = @min(text.len, req.body.title.text.len);
        @memcpy(req.body.title.text[0..n], text[0..n]);
        req.body.title.len = @intCast(n);

        _ = try self.request(&req, &.{});
    }

    pub fn map(self: *Connection, id: u8) Error!void {
        var req = wm.Req{ .tag = .map, .win = id };
        _ = try self.request(&req, &.{});
    }

    /// Take a window down and let go of its slot.
    ///
    /// A dialog is a window that comes and goes, so a client that could only
    /// create them would run out after a few saves.
    pub fn destroyWindow(self: *Connection, id: u8) Error!void {
        var req = wm.Req{ .tag = .destroy_win, .win = id };
        _ = try self.request(&req, &.{});

        if (self.find(id)) |window| {
            window.dropSurface();
            window.* = .{};
        }
    }

    /// Take the next event, or null if there are none waiting.
    /// Take an appearance record if this is one, applying the whole
    /// appearance as now known. True when the event was one of the two and
    /// has been dealt with; the caller redraws.
    ///
    /// Here rather than in each window's loop because a program with a
    /// dialog has two loops, and the folding of two records into one look is
    /// exactly the kind of thing that drifts when written twice.
    pub fn adoptLook(self: *Connection, event: wm.Ev) bool {
        switch (event.tag) {
            .theme => self.look.theme = event.body.theme.name,
            .look => {
                self.look.accent = event.body.look.accent;
                self.look.scale = event.body.look.scale;
            },
            else => return false,
        }
        applyAppearance(self.look);
        return true;
    }

    pub fn poll(self: *Connection) ?wm.Ev {
        // Something dropped is answered first, and as the event that says so:
        // whatever is still in the ring was written after the loss and is
        // only worth acting on once the program has taken stock.
        if (self.events.takeOverflow()) return .{ .tag = .overflow };

        var event: wm.Ev = undefined;
        const n = self.events.read(std.mem.asBytes(&event));
        if (n != @sizeOf(wm.Ev)) return null;
        return event;
    }

    /// Block until an event arrives, then take it.
    pub fn next(self: *Connection, timeout_us: usize) ?wm.Ev {
        return switch (self.nextOrWake(&.{}, timeout_us)) {
            .event => |event| event,
            .woke, .timed_out => null,
        };
    }

    /// What a wait came back with: the manager's next event, the other
    /// handle firing, or neither.
    pub const Next = union(enum) {
        event: wm.Ev,
        /// One of the handles fired, and which one.
        woke: usize,
        timed_out,
    };

    /// How many handles besides the manager's own the wait takes. The
    /// kernel's limit less the one this connection always waits on.
    pub const WAKE_MAX = limits.MAX_WAIT_HANDLES - 1;

    /// The next event, or the other handle's firing, whichever comes first.
    /// A program that is told things by a service waits on the service's
    /// event here rather than asking it on a timer.
    pub fn nextOrWake(self: *Connection, wakes: []const u32, timeout_us: usize) Next {
        if (self.poll()) |event| return .{ .event = event };
        if (wakes.len == 0) {
            sys.eventWait(self.event_signal, timeout_us) catch return .timed_out;
        } else {
            var handles: [WAKE_MAX + 1]u32 = undefined;
            handles[0] = self.event_signal;
            const count = @min(wakes.len, WAKE_MAX);
            @memcpy(handles[1..][0..count], wakes[0..count]);
            const fired = sys.waitMany(handles[0 .. count + 1], timeout_us) catch return .timed_out;
            if (fired > 0) return .{ .woke = @intCast(fired - 1) };
        }
        return if (self.poll()) |event| .{ .event = event } else .timed_out;
    }

    pub fn surfaceOf(self: *Connection, id: u8) ?*eui.Surface {
        const window = self.find(id) orelse return null;
        return &window.surface;
    }

    fn find(self: *Connection, id: u8) ?*Window {
        for (&self.windows) |*w| {
            if (w.used and w.id == id) return w;
        }
        return null;
    }

    fn request(self: *Connection, req: *const wm.Req, handles: []const u32) Error!wm.Rep {
        return self.requestWithHandles(req, handles, &.{});
    }

    /// The same, keeping whatever handles came back. `into` bounds how many
    /// are taken; the rest of the reply is the same either way.
    fn requestWithHandles(
        self: *Connection,
        req: *const wm.Req,
        handles: []const u32,
        into: []u32,
    ) Error!wm.Rep {
        var reply: sys.Message = .{};
        const message = sys.Message.init(std.mem.asBytes(req), handles);
        sys.callMsg(self.channel, &message, &reply) catch return error.Refused;

        // A reply is what it says it holds. Read out of the buffer without
        // asking, a reply that carried nothing read as zeroes, and a status
        // of zero is the one that means it worked: a window created from
        // one is numbered nought, and every later request names a window
        // the server does not have.
        const bytes = reply.bytes();
        if (bytes.len < @sizeOf(wm.Rep)) return error.Refused;

        const got = reply.handleSlice();
        if (got.len < into.len) {
            // Handles the server did send are this process's now, and a
            // caller that is being told the call failed will not close them.
            for (got) |handle| sys.close(handle);
            return error.Refused;
        }
        @memcpy(into, got[0..into.len]);

        return @as(*const wm.Rep, @ptrCast(@alignCast(bytes.ptr))).*;
    }
};

/// The clipboard segment, mapped once per process and kept for the life of
/// it: it is one page, every window wants it, and mapping it per paste would
/// be a syscall for something that never moves.
var clip: []u8 = &.{};

/// Adopt the manager's appearance whole: theme, highlight and size. A desktop
/// where every window picked its own palette would look like several
/// desktops, and one where the bar was drawn at one size and the windows at
/// another would look like a mistake.
///
/// The scale first, because choosing a theme builds it at whatever size was
/// last asked for; the highlight last, because it is applied over the theme.
pub fn applyAppearance(look: wm.Appearance) void {
    eui.theme.setScale(look.scale);
    var n: usize = 0;
    while (n < look.theme.len and look.theme[n] != 0) n += 1;
    if (eui.theme.byName(look.theme[0..n])) |chosen| eui.theme.use(chosen);
    eui.theme.setAccent(look.accent);
}

fn toWire(r: eui.Rect) wm.Rect {
    return .{
        .x = @intCast(@max(@min(r.x, 32767), -32768)),
        .y = @intCast(@max(@min(r.y, 32767), -32768)),
        .w = @intCast(@max(@min(r.w, 65535), 0)),
        .h = @intCast(@max(@min(r.h, 65535), 0)),
    };
}

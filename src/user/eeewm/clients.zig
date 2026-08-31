//! The server half of the window protocol: who is connected, what they own.
//!
//! Policy lives next door in `layout.zig` and `main.zig`. This is the
//! bookkeeping: a table of connected clients, the windows each holds, the
//! surface behind each window, and the ring each client reads its events from.
//!
//! **Clients are identified by the kernel, not by what they claim.** Every
//! request arrives with the caller's process id attested by `recv`, so a
//! client cannot speak for another and the server needs no per-client channel
//! to tell them apart.
//!
//! **A surface is borrowed, never owned.** The client allocates it, the server
//! maps it and reads it. When the client dies its handles close, the segment's
//! last reference goes with them, and the frames come back; the server holds
//! nothing that would keep a dead client's memory alive.

const std = @import("std");
const eui = @import("eui");
const lib = @import("lib");
const proto = @import("proto");
const sys = @import("sys");

const Rect = eui.Rect;

const wm = proto.wm;
const ring = lib.ring;


pub const MAX_CLIENTS = 8;
pub const MAX_WINDOWS = 16;

/// A window as the server sees it: the client that owns it, the surface it
/// draws into, and nothing about where it goes. That is the layout's business.
pub const compose = @import("compose.zig");
pub const Surface = compose.Surface;
pub const Damage = compose.Damage;

pub const Client = struct {
    /// Process id, from the kernel. Zero means the slot is free.
    pid: u32 = 0,
    name: [16]u8 = @splat(0),

    /// Where this client's events go, and what tells it to look.
    events: ring.Ring = undefined,
    events_handle: u32 = 0,
    signal: u32 = 0,
    ready: bool = false,

    pub fn post(self: *Client, event: wm.Ev) void {
        if (!self.ready) return;

        var record = event;
        const bytes = std.mem.asBytes(&record);

        // A full ring means the client is not keeping up. It is told so rather
        // than silently missing events: a client that knows it lost some can
        // redraw, and one that does not will act on a stale idea of the world.
        if (self.events.writable() < bytes.len) {
            var overflow = wm.Ev{ .tag = .overflow };
            _ = self.events.write(std.mem.asBytes(&overflow));
            _ = sys.eventSignal(self.signal);
            return;
        }

        _ = self.events.write(bytes);
        _ = sys.eventSignal(self.signal);
    }
};

pub const Table = struct {
    clients: [MAX_CLIENTS]Client = @splat(.{}),
    /// Server generation, so a client can tell a restarted server from the one
    /// it was talking to.
    generation: u16 = 1,

    pub fn find(self: *Table, pid: u32) ?*Client {
        for (&self.clients) |*c| {
            if (c.pid == pid) return c;
        }
        return null;
    }

    /// Admit a client, giving it an event ring and something to wait on.
    pub fn admit(self: *Table, pid: u32, name: []const u8) ?*Client {
        if (self.find(pid)) |existing| return existing;

        for (&self.clients) |*c| {
            if (c.pid != 0) continue;

            c.* = .{ .pid = pid };
            const n = @min(name.len, c.name.len);
            @memcpy(c.name[0..n], name[0..n]);

            // One page for the header, the rest for events, so both sides
            // agree on the layout without exchanging anything but the segment.
            const bytes = 4096 + wm.EVENT_RING_BYTES;
            const handle = sys.shmCreate(bytes);
            if (handle < 0) {
                c.* = .{};
                return null;
            }

            const base = sys.shmMap(@intCast(handle), .{ .writable = true }) orelse {
                _ = sys.close(@intCast(handle));
                c.* = .{};
                return null;
            };

            const header: *volatile ring.Header = @ptrCast(@alignCast(base));
            c.events = ring.Ring.init(header, base[4096 .. 4096 + wm.EVENT_RING_BYTES]) catch {
                _ = sys.close(@intCast(handle));
                c.* = .{};
                return null;
            };

            const signal = sys.eventCreate();
            if (signal < 0) {
                _ = sys.close(@intCast(handle));
                c.* = .{};
                return null;
            }

            c.events_handle = @intCast(handle);
            c.signal = @intCast(signal);
            c.ready = true;
            return c;
        }
        return null;
    }

    /// Drop a client and everything it held.
    pub fn evict(self: *Table, pid: u32) void {
        const c = self.find(pid) orelse return;

        if (c.events_handle != 0) _ = sys.close(c.events_handle);
        if (c.signal != 0) _ = sys.close(c.signal);
        c.* = .{};
    }
};

/// Map a client's surface into this process so it can be read.
///
/// The handle arrived over the channel and names the same frames the client
/// drew into; mapping it is what makes compositing a copy rather than a
/// message.
pub fn adoptSurface(handle: u32, w: u16, h: u16, stride: u16) ?Surface {
    const pixels = sys.shmMap(handle, .{}) orelse return null;
    return .{
        .pixels = @ptrCast(@alignCast(pixels)),
        .width = w,
        .height = h,
        .stride = stride,
        .handle = handle,
    };
}

/// Put a window's pixels on the screen, confined to `damage`.
///
/// The row-wise copy is the surface's own: the one place that knows how to
/// move pixels moves them for the compositor too, so making it faster makes
/// everything faster. `transparency` is how much of what is behind shows
/// through; zero copies, which is what almost every window wants and the
/// only path with nothing to read back from a framebuffer that is slow to
/// read.
pub fn blit(
    screen: eui.Surface,
    surface: Surface,
    at: eui.Rect,
    damage: eui.Rect,
    transparency: u8,
) void {
    const pixels = surface.pixels orelse return;
    const source = eui.Surface.init(pixels, surface.width, surface.height, surface.stride);
    const limit = at.intersect(damage);

    if (transparency == 0) {
        screen.copyFrom(source, at.x, at.y, limit);
    } else {
        screen.blendFrom(source, at.x, at.y, limit, 256 - @as(u32, transparency));
    }
}

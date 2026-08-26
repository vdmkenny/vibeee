//! The display owner contract.
//!
//! Exactly one process may own the screen at a time. That is the whole point:
//! a compositor and a kernel console both drawing into one framebuffer produce
//! a mess neither can recover from, so ownership is explicit and exclusive.
//!
//! Acquiring detaches the kernel console from the framebuffer. Releasing gives
//! it back, cleared, because there is nothing to restore: the console keeps no
//! scrollback of its own and the pixels belong to whoever drew them last.
//!
//! What is offered depends on the hardware underneath. With the VESA
//! framebuffer stage2 set up there is one scanout buffer, no page flip and no
//! vertical blank signal, so `caps` is empty and a compositor draws straight
//! into the buffer it is shown. The GMA900 driver will offer two buffers and a
//! real vblank, and the same contract describes both, which is why `caps`
//! exists rather than an assumption.
//!
//! `design/10-gui.md` §3.2.

const std = @import("std");
const console = @import("console.zig");
const shm = @import("shm.zig");

pub const Error = error{
    /// Somebody else already owns the display.
    Busy,
    /// There is no framebuffer to hand out.
    NoDisplay,
    OutOfMemory,
};

pub const Format = enum(u8) {
    /// 32 bits per pixel, blue in the low byte, top byte ignored.
    xrgb8888 = 0,
};

pub const Caps = packed struct(u32) {
    /// Buffers can be swapped rather than drawn into directly.
    page_flip: bool = false,
    /// A 64x64 ARGB cursor plane the hardware composites.
    hw_cursor: bool = false,
    /// The vblank signal is real rather than synthesised from a timer.
    real_vblank: bool = false,
    _reserved: u29 = 0,
};

/// What a compositor needs to know before it draws anything.
pub const Info = extern struct {
    width: u16 = 0,
    height: u16 = 0,
    /// Pixels per scanline, which is not the width: a framebuffer is padded to
    /// whatever the hardware finds convenient, and a compositor that assumed
    /// otherwise would shear its output.
    stride_px: u16 = 0,
    format: u8 = @intFromEnum(Format.xrgb8888),
    buffers: u8 = 1,
    caps: u32 = 0,
    /// Bytes of the whole buffer, so a client can size its mapping.
    bytes: u32 = 0,
};

var info: Info = .{};

/// Which adapter was recognised and what would drive it.
///
/// Recorded even when nothing can set a mode on it: on a machine nobody has
/// run this on before, knowing the panel is being driven by what firmware left
/// rather than by a driver is most of the diagnosis.
pub const Adapter = struct {
    /// The backend that fits, or empty when none does.
    backend: []const u8 = "",
    /// What family that backend covers, for a reader without a PCI database.
    family: []const u8 = "",
    /// Whether that backend can actually set a mode yet.
    can_set: bool = false,
};

var adapter: Adapter = .{};

pub fn setAdapter(a: Adapter) void {
    adapter = a;
}

pub fn describeAdapter() Adapter {
    return adapter;
}

/// How to report the adapter's registers, or null when nothing can.
///
/// A function pointer rather than a call into the driver, because the kernel
/// may not reach one: the composition root binds the adapter and supplies
/// this, the same way it supplies the description above.
var reporter: ?*const fn (*std.Io.Writer) void = null;

/// The size a panel runs at, as the adapter reports it.
///
/// Its own small type rather than `modeset.Mode`, because the kernel may not
/// import a driver: the composition root translates.
pub const Panel = struct { width: u16, height: u16 };

var panel_query: ?*const fn () ?Panel = null;

pub fn setPanelQuery(f: *const fn () ?Panel) void {
    panel_query = f;
}

/// What the panel runs at, or null when nothing can say.
pub fn panelMode() ?Panel {
    const f = panel_query orelse return null;
    return f();
}

pub fn setReporter(f: *const fn (*std.Io.Writer) void) void {
    reporter = f;
}

pub fn registerReporter() ?*const fn (*std.Io.Writer) void {
    return reporter;
}
var phys_base: usize = 0;
var owned = false;
var available = false;

/// Record what the display hardware is. Called from the composition root, the
/// only place that knows which driver came up.
pub fn present(base: usize, geometry: Info) void {
    phys_base = base;
    info = geometry;
    available = true;
}

pub fn isAvailable() bool {
    return available;
}

pub fn isOwned() bool {
    return owned;
}

pub fn describe() Info {
    return info;
}

/// Take the display, returning a segment describing the scanout buffer.
///
/// The segment is the ordinary shared-memory object, so the caller maps it with
/// the same call it uses for anything else. It does not own the frames: they
/// belong to the graphics device, and handing them back to the page allocator
/// would be catastrophic in a way that would take a long time to diagnose.
pub fn acquire() Error!*shm.Segment {
    if (!available) return error.NoDisplay;
    if (owned) return error.Busy;

    const segment = shm.wrapPhysical(phys_base, info.bytes) catch |err| {
        return switch (err) {
            error.BadSize => error.NoDisplay,
            else => error.OutOfMemory,
        };
    };

    // The console stops drawing before the new owner starts, not after: an
    // overlap means two writers to the same pixels.
    console.suspendFramebuffer();
    owned = true;
    return segment;
}

pub const ModeError = error{ Busy, Unsupported, Failed, Invalid };

/// What the backend will be asked to do, once one exists.
pub var setMode: ?*const fn (width: u16, height: u16, bpp: u8) ModeError!void = null;

/// Ask the adapter for a mode.
///
/// Refused while somebody owns the display: a compositor holds a buffer of a
/// fixed shape and a mode change underneath it would leave every write landing
/// somewhere else.
pub fn requestMode(width: u16, height: u16, bpp: u8) ModeError!void {
    if (owned) return error.Busy;
    if (width == 0 or height == 0) return error.Invalid;

    const backend = setMode orelse return error.Unsupported;
    try backend(width, height, bpp);
}

/// Hand the display back and return the console to it.
pub fn release() void {
    if (!owned) return;
    owned = false;
    console.resumeFramebuffer();
}

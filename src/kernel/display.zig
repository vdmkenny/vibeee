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
//! framebuffer stage2 set up there is one scanout buffer, no page flip, no
//! pointer plane and no vertical blank signal, so `caps` is empty and a
//! compositor draws everything itself, the pointer included. An adapter with
//! a driver that found more says so through the same field, which is why
//! `caps` exists rather than an assumption: the GMA900 carries the pointer,
//! and a compositor reading that draws one fewer thing.
//!
//! `design/10-gui.md` §3.2.

const std = @import("std");
const console = @import("console.zig");
const rgb = @import("lib").rgb;
const hal = @import("hal.zig");
const sched = @import("sched.zig");
const shm = @import("shm.zig");

pub const Error = error{
    /// Somebody else already owns the display.
    Busy,
    /// There is no framebuffer to hand out.
    NoDisplay,
    OutOfMemory,
};

/// How this display's pixels are laid out. The shape is the protocol's, so
/// what the kernel says and what a compositor reads are one declaration.
pub const Format = @import("lib").syscalls.DisplayFormat;

/// What this display can do beyond being drawn into. The shape is the
/// protocol's, so what the kernel decides and what a compositor reads are one
/// declaration.
pub const Caps = @import("lib").syscalls.DisplayCaps;

/// What a compositor needs to know before it draws anything.
pub const Info = extern struct {
    width: u16 = 0,
    height: u16 = 0,
    /// Pixels per scanline, which is not the width: a framebuffer is padded to
    /// whatever the hardware finds convenient, and a compositor that assumed
    /// otherwise would shear its output.
    stride_px: u16 = 0,
    format: Format = .xrgb8888,
    buffers: u8 = 1,
    caps: Caps = .{},
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
/// The thread that took the display, or nobody. Ownership is the
/// process's rather than the handle's: only the taker's close hands it
/// back, so a copy closing elsewhere means nothing here.
var owner: ?u32 = null;
var available = false;

/// Record what the display hardware is. Called from the composition root, the
/// only place that knows which driver came up.
pub fn present(base: usize, geometry: Info) void {
    phys_base = base;
    info = geometry;
    available = true;

    // The framebuffer wants write-combining: the page tables say cacheable,
    // but the firmware routinely leaves the aperture's memory type at the
    // uncacheable default, and uncached is a store per pixel per bus
    // transaction. Done here because every presenter needs it and none
    // should have to remember.
    if (hal.caps.write_combine and geometry.bytes != 0) {
        const outcome = hal.impl.writeCombine(base, geometry.bytes);
        console.info("video", "write-combining {s}", .{outcome.label()});
    }
}

pub fn isAvailable() bool {
    return available;
}

pub fn isOwned() bool {
    return owner != null;
}

/// What the screen is, as a client is told it.
///
/// The pointer plane is answered from whether one was bound rather than from
/// a bit written when the mode was set: the two are found at different
/// moments and neither should have to wait for the other.
pub fn describe() Info {
    var out = info;
    out.caps.hw_cursor = pointer != null;
    return out;
}

// ---------------------------------------------------------------------------
// The pointer plane
// ---------------------------------------------------------------------------

/// A pointer the display engine carries over the scanout, where the adapter
/// has one.
///
/// Held here rather than reached for, the same way the mode setter and the
/// register reporter are: the kernel may not import a driver, so the
/// composition root hands it what it found. Its own type for the same reason
/// the panel has one.
pub const Pointer = struct {
    /// How many pixels the plane is each way. A picture smaller than this
    /// goes in the corner of one and the rest is left clear.
    side: u16,
    /// Give the plane its picture: `wide` pixels across, alpha in the top
    /// byte, with the point it is placed by at `hot` within it.
    image: *const fn (picture: []const rgb.Blended, wide: u16, hot: Place) Refused!void,
    /// Put it somewhere, or take it off the screen.
    move: *const fn (where: Where) void,

    /// A place on the screen, in pixels from its corner. Signed because a
    /// pointer whose point is near the left or the top edge has its picture
    /// hanging off it.
    pub const Place = struct { x: i32, y: i32 };

    /// Where the pointer is, which is either somewhere or nowhere: a place
    /// and a flag would let the two disagree.
    pub const Where = union(enum) { at: Place, off };

    pub const Refused = error{
        /// A picture the plane will not take: not a whole number of rows, or
        /// larger than the square it reads.
        Refused,
    };
};

var pointer: ?Pointer = null;

pub fn setPointer(p: Pointer) void {
    pointer = p;
}

pub const PointerError = Pointer.Refused || error{
    /// The adapter has no plane, so the pointer is the owner's to draw.
    Unsupported,
    /// Asked for by somebody who does not hold the screen.
    NotOwner,
};

/// Give the plane its picture. The owner's to do: what is drawn over the
/// screen belongs to whoever is drawing the screen.
pub fn pointerImage(picture: []const rgb.Blended, wide: u16, hot: Pointer.Place) PointerError!void {
    const plane = pointer orelse return error.Unsupported;
    try ownerOnly();
    try plane.image(picture, wide, hot);
}

/// Put the pointer somewhere, or take it off the screen. The hot path: one
/// call a movement, and nothing drawn.
pub fn pointerMove(where: Pointer.Where) PointerError!void {
    const plane = pointer orelse return error.Unsupported;
    try ownerOnly();
    plane.move(where);
}

fn ownerOnly() PointerError!void {
    const holder = owner orelse return error.NotOwner;
    const caller = sched.currentThread() orelse return error.NotOwner;
    if (caller.id != holder) return error.NotOwner;
}

/// Take the pointer off the screen, for the moments when nobody owns it: the
/// console has no pointer, and a plane left on would leave one sitting there.
fn hidePointer() void {
    const plane = pointer orelse return;
    plane.move(.off);
}

/// Take the display, returning a segment describing the scanout buffer.
///
/// The segment is the ordinary shared-memory object, so the caller maps it with
/// the same call it uses for anything else. It does not own the frames: they
/// belong to the graphics device, and handing them back to the page allocator
/// would be catastrophic in a way that would take a long time to diagnose.
pub fn acquire() Error!*shm.Segment {
    if (!available) return error.NoDisplay;
    if (owner != null) return error.Busy;
    const taker = sched.currentThread() orelse return error.Busy;

    const segment = shm.wrapPhysical(phys_base, info.bytes, .{}) catch |err| {
        return switch (err) {
            error.BadSize => error.NoDisplay,
            else => error.OutOfMemory,
        };
    };

    // The console stops drawing before the new owner starts, not after: an
    // overlap means two writers to the same pixels.
    console.suspendFramebuffer();
    hidePointer();
    owner = taker.id;
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
    if (owner != null) return error.Busy;
    if (width == 0 or height == 0) return error.Invalid;

    const backend = setMode orelse return error.Unsupported;
    try backend(width, height, bpp);
}

/// Hand the display back and return the console to it. Only the owner's to
/// do: the handle to the screen closes in the process that took it, whether
/// by its own hand or by its end, and nobody else's close is heard.
pub fn release() void {
    const holder = owner orelse return;
    const closing = sched.currentThread() orelse return;
    if (closing.id != holder) return;
    owner = null;
    hidePointer();
    console.resumeFramebuffer();
}

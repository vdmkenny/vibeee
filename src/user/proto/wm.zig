//! The window protocol: what a client and the window manager say to each other.
//!
//! Wire types only. No transport, no policy, no drawing, so both sides compile
//! the same definitions and neither can drift from the other. design/10-gui.md
//! §5.
//!
//! Three channels of communication, each shaped for what it carries:
//!
//!   * a **channel** for control, synchronous request and reply, because every
//!     one of these is a question with an answer and a client that asked to
//!     create a window has nothing to do until it knows the answer;
//!   * an **event ring** the server writes and the client reads, because
//!     events arrive unbidden and a syscall per keystroke is a syscall too
//!     many;
//!   * a **surface** per window, shared memory the client draws into and the
//!     server reads, because copying 1.5 MB through a channel is the thing
//!     this design exists to avoid.
//!
//! Everything here is `extern` and little-endian: it crosses a process
//! boundary between separately compiled programs.


/// Bumped when a change would make an old client misread a new server. The
/// server rejects a mismatch at `hello` rather than failing later in a way
/// that looks like a client bug.
pub const VERSION: u16 = 1;

pub const MAX_WINDOWS_PER_CLIENT = 8;

/// Events the ring holds before the client must have drained it. 16 KiB of
/// 24-byte events, per design §5.
pub const EVENT_RING_BYTES = 16 * 1024;

pub const Rect = extern struct {
    x: i16 = 0,
    y: i16 = 0,
    w: u16 = 0,
    h: u16 = 0,
};

pub const WinFlags = packed struct(u8) {
    /// Floats above the tiles instead of being tiled.
    floating: bool = false,
    /// A dialog: floats, and centres over its parent.
    dialog: bool = false,
    /// Refuses to be closed by the manager.
    no_close: bool = false,
    _reserved: u5 = 0,
};

// ---------------------------------------------------------------------------
// Requests
// ---------------------------------------------------------------------------

pub const ReqTag = enum(u8) {
    hello,
    create_win,
    /// Hand over the surface to draw into. Carries one shm handle.
    attach,
    /// Publish what was drawn. Carries the damaged rectangles.
    commit,
    set_title,
    map,
    unmap,
    destroy_win,
    /// Map the one clipboard every window shares. The reply carries its
    /// segment; reading it afterwards costs no syscall at all.
    clipboard,
    /// Publish what was written into the clipboard. The server is what makes
    /// the length official, so a client cannot make the others read past the
    /// end of it.
    clipboard_put,
    bye,
};

pub const Req = extern struct {
    tag: ReqTag = .hello,
    /// Which of the client's windows, ignored by `hello` and `bye`.
    win: u8 = 0,
    _pad: [2]u8 = @splat(0),

    body: extern union {
        hello: extern struct {
            proto: u16,
            app_name: [16]u8,
        },
        create: extern struct {
            flags: WinFlags,
            min_w: u16,
            min_h: u16,
            tag_hint: u8,
        },
        attach: extern struct {
            w: u16,
            h: u16,
            /// Pixels per scanline, which the client rounds up for its own
            /// blitting convenience and the server must therefore be told.
            stride_px: u16,
        },
        commit: extern struct {
            n: u8,
            _pad: u8 = 0,
            /// Three rectangles, and anything beyond merges into their
            /// bounding box: past a handful the bookkeeping costs more than
            /// the pixels.
            rects: [3]Rect,
        },
        title: extern struct {
            len: u8,
            text: [47]u8,
        },
        clip: extern struct {
            len: u16,
        },
        raw: [56]u8,
    } = .{ .raw = @splat(0) },
};

// ---------------------------------------------------------------------------
// Replies
// ---------------------------------------------------------------------------

pub const Status = enum(i16) {
    ok = 0,
    /// The protocol version does not match.
    bad_version = -1,
    /// No window by that id belongs to this client.
    no_window = -2,
    /// Too many windows, or no room for another client.
    no_room = -3,
    /// The request does not make sense in the window's current state.
    bad_request = -4,
};

pub const Rep = extern struct {
    status: Status = .ok,
    /// The server's generation, bumped every time it restarts. A client seeing
    /// it change knows its windows are gone and it must re-create them.
    gen: u16 = 0,

    body: extern union {
        hello: extern struct {
            screen_w: u16,
            screen_h: u16,
            caps: u32,
            /// The manager's theme, so a client draws in the same palette
            /// rather than its own default. The name rather than the colours:
            /// both sides compile the same presets, and sixteen bytes is
            /// cheaper than a table.
            theme: [16]u8,
        },
        create: extern struct {
            win: u8,
        },
        clip: extern struct {
            /// How much is on the clipboard now.
            len: u16,
            /// How much it can ever hold.
            capacity: u16,
        },
        raw: [8]u8,
    } = .{ .raw = @splat(0) },
};

// ---------------------------------------------------------------------------
// The clipboard
// ---------------------------------------------------------------------------

/// The shared segment's first bytes, written by the server and read by
/// everyone. A client that has mapped it can paste without asking anybody,
/// which is what makes a clipboard feel like one.
pub const ClipHead = extern struct {
    len: u32 = 0,
    /// Bumped on every put, so a client can tell "the same text again" from
    /// "nobody has copied since".
    generation: u32 = 0,
};

/// How much the clipboard holds. A paragraph, not a file: what crosses
/// between windows here is a path, a line of text or a command, and a
/// clipboard sized for a document is a page of memory nobody uses.
pub const CLIPBOARD_BYTES: usize = 4096;

pub fn clipboardText(mapped: []const u8) []const u8 {
    if (mapped.len < @sizeOf(ClipHead)) return "";
    const head: *const ClipHead = @ptrCast(@alignCast(mapped.ptr));
    const room = mapped.len - @sizeOf(ClipHead);
    return mapped[@sizeOf(ClipHead) ..][0..@min(head.len, room)];
}

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

pub const EvTag = enum(u8) {
    /// A raw key, for shortcuts. Carries the keycode, not the character.
    key,
    /// A character, after layout, dead keys and composition. What a text field
    /// wants; `key` is what a shortcut wants, and sending only one of the two
    /// would make the other impossible.
    text,
    ptr_motion,
    ptr_button,
    scroll,
    focus,
    /// The window has a new size and must redraw at it.
    configure,
    close_req,
    /// The window stopped being visible, and painting it is wasted work.
    visibility,
    /// The manager's theme changed; redraw in the new one.
    theme,
    /// Events were dropped. The client should redraw rather than trust its
    /// idea of what it has seen.
    overflow,
};

/// Fixed at 24 bytes so the ring is an array rather than a parse.
pub const Ev = extern struct {
    tag: EvTag = .overflow,
    win: u8 = 0,
    _pad: u16 = 0,
    /// Microseconds since boot, truncated. Enough to order events and measure
    /// a double-click; anything wanting absolute time asks the clock.
    t_us: u32 = 0,

    body: extern union {
        key: extern struct { code: u16, down: u8, mods: u8 },
        text: extern struct { cp: u32 },
        motion: extern struct { x: i16, y: i16 },
        button: extern struct { btn: u8, down: u8, x: i16, y: i16 },
        scroll: extern struct { dy: i8, dx: i8 },
        focus: extern struct { focused: u8 },
        configure: extern struct { w: u16, h: u16 },
        visibility: extern struct { visible: u8 },
        theme: extern struct { name: [16]u8 },
        raw: [16]u8,
    } = .{ .raw = @splat(0) },
};

comptime {
    // The ring's capacity arithmetic assumes it, and a change here that went
    // unnoticed would misalign every event after the first.
    if (@sizeOf(Ev) != 24) @compileError("Ev must stay 24 bytes");
    if (@sizeOf(Req) > 64) @compileError("Req must fit one channel message");
    if (@sizeOf(Rep) > 64) @compileError("Rep must fit one channel message");
}

/// Name the manager registers under, and clients look up.
pub const SERVICE = "gui";

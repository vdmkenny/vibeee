//! The calls this system has and POSIX has no word for.
//!
//! A ported program can open files and allocate memory through the
//! headers it already knows. What it cannot do through them is take the
//! screen or read a key, because neither is a file here: the screen is a
//! shared-memory object a process owns exclusively, and keys arrive as
//! events rather than as bytes on a terminal.
//!
//! So there is one header of our own, and this is what stands behind it.
//! Deliberately small: two things to do with the screen and one with the
//! keyboard, which is the whole of what a program drawing its own pixels
//! needs from a system.

const sys = @import("sys");

/// What the screen is. Laid out to match `syscalls.DisplayInfo` exactly,
/// because the kernel writes one of those into it.
pub const Display = extern struct {
    width: u16 = 0,
    height: u16 = 0,
    /// Pixels per scanline, which is not the width: a framebuffer is
    /// padded to whatever the hardware found convenient, and a program
    /// stepping by width would shear its own picture.
    stride_px: u16 = 0,
    format: u8 = 0,
    buffers: u8 = 1,
    caps: u32 = 0,
    bytes: u32 = 0,
};

comptime {
    if (@sizeOf(Display) != @sizeOf(sys.DisplayInfo)) {
        @compileError("the C display description must match the kernel's");
    }
}

/// The one pixel format this system's framebuffers use: eight bits each
/// of blue, green and red in a little-endian word, with the top eight
/// ignored. A C program can write a pixel as 0x00RRGGBB.
pub const FORMAT_XRGB8888: u8 = 0;

var mapped: ?[*]u8 = null;
var owned: ?u32 = null;

/// Take the screen and map it. Returns the pixels, or null when the
/// screen is already somebody's.
///
/// One process owns the display at a time, by decision: two programs
/// drawing into one framebuffer produce a mess neither can undo.
export fn vb_display_acquire(into: ?*Display) ?[*]u8 {
    if (mapped) |already| return already;

    var info = sys.DisplayInfo{};
    const handle = sys.displayAcquire(&info) catch return null;

    const pixels = sys.shmMap(@intCast(handle), .{ .writable = true }) orelse {
        _ = sys.close(@intCast(handle));
        return null;
    };

    owned = @intCast(handle);
    mapped = pixels;
    if (into) |out| out.* = @bitCast(info);
    return pixels;
}

/// Give it back. The console gets the screen, cleared, which is what a
/// program leaving should leave behind.
export fn vb_display_release() void {
    if (owned) |handle| _ = sys.close(handle);
    owned = null;
    mapped = null;
}

/// One key, as it happened. Both presses and releases arrive: a game
/// holding a direction needs to know when it stopped being held.
pub const Key = extern struct {
    code: u8 = 0,
    pressed: u8 = 0,
    modifiers: u8 = 0,
    _pad: u8 = 0,
    /// What the current layout made of it, or zero for a key that makes
    /// no character. Text comes from here; shortcuts come from `code`.
    codepoint: u32 = 0,
};

comptime {
    if (@sizeOf(Key) != @sizeOf(sys.KeyEvent)) {
        @compileError("the C key event must match the kernel's");
    }
}

/// Read up to `count` keys, waiting at most `timeout_us` microseconds.
/// Zero polls, and 0xFFFFFFFF waits for as long as it takes.
///
/// The first call claims the keyboard: a shell reading lines and a game
/// reading keys cannot both consume the same keystroke. The claim ends
/// when the process does.
export fn vb_key_read(into: ?[*]Key, count: c_int, timeout_us: c_uint) c_int {
    const buffer = into orelse return -1;
    if (count <= 0) return 0;

    const events: [*]sys.KeyEvent = @ptrCast(buffer);
    const taken = sys.keyRead(events[0..@intCast(count)], timeout_us);
    return @intCast(taken.len);
}

// The key numbers a C program uses are generated from `KeyCode` into
// <vibeee-keys.h>, so there is no second list here to keep in step with
// the first.

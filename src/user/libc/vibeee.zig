//! The calls this system has and POSIX has no word for.
//!
//! A ported program can open files and allocate memory through the
//! headers it already knows. What it cannot do through them is take the
//! screen or read a key, because neither is a file here: the screen is a
//! shared-memory object a process owns exclusively, and keys arrive as
//! events rather than as bytes on a terminal.
//!
//! Nor can it make a sound. Audio here is a graph a program joins as a
//! node, which is a better arrangement than a device to open and a worse
//! one to express in a header, so the binding offers the ordinary case:
//! one output, connected to wherever sound goes.
//!
//! So there is one header of our own, and this is what stands behind it.
//! Deliberately small: the screen, the keyboard, and a way to be heard,
//! which is the whole of what a program drawing its own pixels and making
//! its own noise needs from a system.

const std = @import("std");
const audio = @import("lib").audio;
const sys = @import("sys");
const ulib = @import("ulib");

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
/// reading keys cannot both consume the same keystroke. The claim ends when
/// the process does, and a keyboard another program is holding answers -1
/// rather than a share of its keystrokes.
export fn vb_key_read(into: ?[*]Key, count: c_int, timeout_us: c_uint) c_int {
    const buffer = into orelse return -1;
    if (count <= 0) return 0;

    const events: [*]sys.KeyEvent = @ptrCast(buffer);
    const taken = sys.keyRead(events[0..@intCast(count)], timeout_us) orelse return -1;
    return @intCast(taken.len);
}

// The key numbers a C program uses are generated from `KeyCode` into
// <vibeee-keys.h>, so there is no second list here to keep in step with
// the first.

// ---------------------------------------------------------------------------
// Sound
// ---------------------------------------------------------------------------

/// What a stream is: how fast, how many samples make a frame, and how
/// wide a sample is. Fixed by the system rather than chosen per program,
/// so a caller reads it rather than asking for it.
pub const Sound = extern struct {
    rate: u32 = 0,
    channels: u8 = 0,
    bits: u8 = 0,
    _pad: [2]u8 = @splat(0),
};

var speaking: ?ulib.sound.Port = null;

/// Join the graph as a node with one output, connected to wherever sound
/// goes. Answers 0, or -1 when there is no sound service.
///
/// One output per program, because a program that wants two wants the
/// graph itself, and that is a richer thing than a header should pretend
/// to be.
export fn vb_sound_open(name: ?[*:0]const u8, shape: ?*Sound) c_int {
    if (speaking != null) return 0;

    const called = if (name) |given| std.mem.span(given) else "program";
    speaking = ulib.sound.Port.output(called, "out") catch return -1;

    if (shape) |out| {
        const wanted = audio.Shape{};
        out.* = .{
            .rate = wanted.rate.hertz(),
            .channels = wanted.channels,
            .bits = @intCast(wanted.format.bytesPerSample() * 8),
        };
    }
    return 0;
}

/// Hand over frames. Answers how many were taken, which is fewer than
/// asked when the ring is full: a program keeps the rest and offers them
/// again rather than waiting, because a sound loop that blocks is a
/// picture that stops.
export fn vb_sound_write(frames: ?*const anyopaque, count: c_int) c_int {
    const port = &(speaking orelse return -1);
    if (count <= 0) return 0;

    const bytes: [*]const u8 = @ptrCast(frames orelse return -1);
    const width = audio.Shape{};
    const wanted = @as(usize, @intCast(count)) * width.bytesPerFrame();

    const taken = port.write(bytes[0..wanted]);
    return @intCast(taken / width.bytesPerFrame());
}

/// How many frames would be taken right now. What a program mixes to,
/// so it produces exactly what there is room for.
export fn vb_sound_room() c_int {
    const port = &(speaking orelse return -1);
    const width = audio.Shape{};
    return @intCast(port.view.frames.writable() / width.bytesPerFrame());
}

/// Wait until the ring wants more, or until `timeout_us` has passed.
///
/// The one call a sound loop cannot do without. A full ring waits for the
/// engine and never spins: the service signals as each period drains, and
/// a program that polls instead takes the processor the service needs to
/// drain it, which on one core is how a tone comes out full of holes.
export fn vb_sound_wait(timeout_us: c_uint) c_int {
    const port = &(speaking orelse return -1);
    return if (sys.eventWait(port.waitHandle(), timeout_us) < 0) -1 else 0;
}

/// Whether everything handed over has been played.
export fn vb_sound_drained() c_int {
    const port = &(speaking orelse return 1);
    return @intFromBool(port.drained());
}

export fn vb_sound_close() void {
    if (speaking) |port| port.close();
    speaking = null;
}

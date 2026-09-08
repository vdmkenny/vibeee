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
const framebuffer = @import("framebuffer");
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

var held: ?ulib.display.Screen = null;

/// Take the screen and map it. Returns the pixels, or null when the
/// screen is already somebody's.
///
/// One process owns the display at a time, by decision: two programs
/// drawing into one framebuffer produce a mess neither can undo.
export fn vb_display_acquire(into: ?*Display) ?[*]u8 {
    if (held == null) held = ulib.display.take() catch return null;
    const screen = &held.?;
    if (into) |out| out.* = @bitCast(screen.info);
    return @ptrCast(screen.pixels);
}

/// Give it back. The console gets the screen, cleared, which is what a
/// program leaving should leave behind.
export fn vb_display_release() void {
    if (held) |*screen| screen.release();
    held = null;
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

// ---------------------------------------------------------------------------
// Virtual framebuffer window
// ---------------------------------------------------------------------------

/// One C port owns one virtual framebuffer. Native programs use
/// `framebuffer.Window` itself and are not restricted by this C convenience.
var virtual: ?framebuffer.Window = null;

/// Open a fixed logical framebuffer inside the compositor. Unlike
/// `vb_display_acquire`, this neither needs nor takes the physical display.
export fn vb_window_open(
    title: ?[*:0]const u8,
    width: u16,
    height: u16,
    into: ?*Display,
) ?[*]u8 {
    // One per program, so a second call names the window that is open. It
    // is described like the first, and refused when it asks for a shape
    // the open one is not: there is no way to give it one, and handing
    // back a framebuffer of a different size than was asked for is how a
    // port draws off the end of its own pixels.
    if (virtual) |*window| {
        if (window.width != width or window.height != height) return null;
        describe(into, window);
        return @ptrCast(window.surface().ptr);
    }

    const name = if (title) |text| std.mem.span(text) else "program";
    var window = framebuffer.Window.open(name, width, height) catch return null;

    describe(into, &window);
    virtual = window;
    return @ptrCast(window.surface().ptr);
}

/// Fill in what the caller asked to be told about the framebuffer, for a
/// caller that asked to be told.
fn describe(into: ?*Display, window: *const framebuffer.Window) void {
    const out = into orelse return;
    out.* = .{
        .width = window.width,
        .height = window.height,
        .stride_px = window.width,
        .bytes = @intCast(window.pixels.len * @sizeOf(u32)),
    };
}

/// Copy the logical framebuffer into the current compositor surface.
export fn vb_window_present() c_int {
    const window = &(virtual orelse return -1);
    window.present() catch return -1;
    return 0;
}

/// Read input dispatched by the compositor without claiming its physical
/// keyboard. The manager keeps the keycode and the keymap's codepoint in one
/// record, so a port receives one event per press or release.
export fn vb_window_key_read(into: ?[*]Key, count: c_int, timeout_us: c_uint) c_int {
    const window = &(virtual orelse return -1);
    const out = into orelse return -1;
    if (count <= 0) return 0;

    var used: usize = 0;
    while (used < @as(usize, @intCast(count))) {
        const timeout: usize = if (used == 0) timeout_us else 0;
        const event = window.next(timeout) orelse break;
        switch (event.tag) {
            // Spelled out rather than copied: this is the C boundary, where
            // an enum is a byte and a bool is a byte, and the header says so
            // in C's own words.
            .key => out[used] = .{
                .code = @intFromEnum(event.body.key.code),
                .pressed = @intFromBool(event.body.key.pressed),
                .modifiers = @bitCast(event.body.key.mods),
                .codepoint = event.body.key.codepoint,
            },
            .close_req => return if (used == 0) -1 else @intCast(used),
            else => continue,
        }
        used += 1;
    }
    return @intCast(used);
}

export fn vb_window_close() void {
    if (virtual) |*window| window.close();
    virtual = null;
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
    sys.eventWait(port.waitHandle(), timeout_us) catch return -1;
    return 0;
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

// ---------------------------------------------------------------------------
// Mixing several sounds into the one stream
// ---------------------------------------------------------------------------

/// How many sounds a C program may have going at once.
///
/// A budget rather than a limit somebody ran into: a program that makes
/// sounds picks a slot for each and reuses it, and past a dozen or so
/// nobody can pick one out of the others anyway. The bank costs its own
/// size and nothing else, since the samples stay where the caller put them.
const MIX_VOICES = 16;

var bank: audio.Mixer(MIX_VOICES) = .{};

/// Where frames are put together before being handed over.
///
/// One pass fills this much and the pump goes round again, so the size is
/// how much work happens between two checks of the ring rather than a
/// ceiling on anything.
var mixed: [512]i16 = @splat(0);

/// Start a sound in `slot`, at the rate it was recorded.
///
/// `bits` is 8 for unsigned samples with silence at the middle, which is
/// what sounds of that age are stored as, or 16 for signed ones. The
/// samples stay the caller's and are read while the sound plays, so they
/// have to outlive it. Answers 0, or -1 for a slot or a shape this does
/// not have.
export fn vb_mix_start(
    slot: c_int,
    samples: ?*const anyopaque,
    count: c_int,
    rate: c_uint,
    bits: c_int,
    left: u8,
    right: u8,
    looping: c_int,
) c_int {
    if (slot < 0 or slot >= MIX_VOICES or count <= 0) return -1;
    const from: [*]const u8 = @ptrCast(samples orelse return -1);
    const n: usize = @intCast(count);

    const source: audio.Samples = switch (bits) {
        8 => .{ .eight = from[0..n] },
        16 => .{ .sixteen = @as([*]const i16, @ptrCast(@alignCast(from)))[0..n] },
        else => return -1,
    };

    const out = audio.Shape{};
    bank.start(@intCast(slot), .{
        .samples = source,
        .step = audio.stepFor(rate, out.rate.hertz()),
        .left = left,
        .right = right,
        .looping = looping != 0,
    });
    return 0;
}

/// How loud a sound already playing is on each side. A slot that has
/// finished is left alone: a sound that ended is not made louder.
export fn vb_mix_gain(slot: c_int, left: u8, right: u8) void {
    if (slot < 0) return;
    bank.setGain(@intCast(slot), left, right);
}

export fn vb_mix_stop(slot: c_int) void {
    if (slot < 0) return;
    bank.stop(@intCast(slot));
}

export fn vb_mix_stop_all() void {
    bank.stopAll();
}

export fn vb_mix_playing(slot: c_int) c_int {
    if (slot < 0) return 0;
    return @intFromBool(bank.playing(@intCast(slot)));
}

/// The first slot with nothing in it, or -1 when they are all busy.
export fn vb_mix_free() c_int {
    const slot = bank.free() orelse return -1;
    return @intCast(slot);
}

/// Mix what the stream has room for and hand it over.
///
/// Silence counts: a stream that stops being fed runs dry and the next
/// sound starts with a click, so a program with nothing playing still
/// pumps and still keeps the stream moving. Answers the frames written,
/// or -1 without a stream.
export fn vb_mix_pump() c_int {
    const port = &(speaking orelse return -1);
    const shape = audio.Shape{};
    const per_frame = shape.bytesPerFrame();
    const at_once = mixed.len / shape.channels;

    // What there is room for, measured once and then worked through. The
    // service is draining the ring while this runs, so a loop that asked
    // again each time round would keep being told there is room and would
    // never come back: a pump is one pass, and the beat is the caller's.
    var left = port.view.frames.writable() / per_frame;
    var written: usize = 0;
    while (left != 0) {
        // Widened deliberately: `@min` gives back the narrowest type that
        // can hold its answer, and a count of frames multiplied out to
        // samples in that type is a product that does not fit it.
        const frames: usize = @min(left, at_once);
        const wanted = mixed[0 .. frames * shape.channels];
        bank.fill(wanted);

        const taken = port.write(std.mem.sliceAsBytes(wanted)) / per_frame;
        written += taken;
        if (taken < frames) break;
        left -= taken;
    }
    return @intCast(written);
}

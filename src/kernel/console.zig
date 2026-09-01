//! Kernel console: cursor tracking, scrolling, formatting and the boot log.
//!
//! Device-independent. The cell-level work belongs to a backend, either
//! `drv/video/vgatext.zig` or `drv/video/fbcon.zig`, chosen at boot from what
//! the firmware provided. Both present the same cell interface, so nothing
//! here depends on which one is in use.

const std = @import("std");
const klog = @import("klog.zig");
const bootinfo = @import("bootinfo.zig");
const escapes = @import("lib").escapes;
const tty = @import("tty.zig");
const heap = @import("heap.zig");
const style = @import("lib").style;
const fbcon = @import("../drv/video/fbcon.zig");
const vgatext = @import("../drv/video/vgatext.zig");

pub const Color = vgatext.Color;

/// Code points the console draws that are not plain ASCII.
pub const BLOCK_UPPER_HALF: u21 = 0x2580;

/// Map a code point to the VGA text mode's CP437 byte.
///
/// Only the handful the kernel actually draws. Everything else falls back to
/// '?': a visible marker beats a blank, which reads as a bug in whatever
/// produced the text.
fn toCp437(cp: u21) u8 {
    return switch (cp) {
        0x00...0x7F => @intCast(cp),
        BLOCK_UPPER_HALF => 0xDF,
        0x2584 => 0xDC, // lower half block
        0x2588 => 0xDB, // full block
        // Arrows, which is what a prompt and a listing reach for.
        0x2190 => 0x1B,
        0x2191 => 0x18,
        0x2192 => 0x1A,
        0x2193 => 0x19,
        // Box drawing, so a tree looks like a tree in both modes.
        0x2500 => 0xC4,
        0x2502 => 0xB3,
        0x250C => 0xDA,
        0x2510 => 0xBF,
        0x2514 => 0xC0,
        0x2518 => 0xD9,
        0x251C => 0xC3,
        0x2524 => 0xB4,
        else => '?',
    };
}

/// Console geometry. Fixed at 80x25 in text mode, and whatever the framebuffer
/// affords otherwise, so it cannot be a compile-time constant.
var columns: usize = vgatext.WIDTH;
var rows: usize = vgatext.HEIGHT;

pub fn width() usize {
    return columns;
}

pub fn height() usize {
    return rows;
}

/// Switch to the framebuffer if stage2 set a graphics mode.
///
/// Called early, before anything has been drawn: in graphics mode the text
/// buffer at 0xB8000 is not displayed, so output written before the switch
/// would simply vanish.
/// True when the console can address individual pixels.
pub fn hasPixels() bool {
    return fbcon.active();
}

pub const Size = fbcon.Size;

/// Stop drawing to the framebuffer because something else owns it now.
///
/// Output is still accepted and still mirrored to the serial port, so a kernel
/// message during a GUI session is not lost; it simply does not appear over
/// the top of whatever is on screen.
pub fn suspendFramebuffer() void {
    fbcon.setSuspended(true);
}

pub fn resumeFramebuffer() void {
    fbcon.setSuspended(false);
    clear();
}

pub const FbLayout = fbcon.Layout;

/// Where the framebuffer is, or a zero address in text mode.
pub fn framebufferLayout() FbLayout {
    return if (fbcon.active()) fbcon.layout() else .{ .addr = 0, .pitch = 0 };
}

/// Point the console at a framebuffer of a different shape, after a modeset.
pub fn adoptFramebuffer(phys: usize, pitch: usize, px_width: usize, px_height: usize) bool {
    if (!fbcon.active()) return false;
    if (!fbcon.adopt(phys, pitch, px_width, px_height)) return false;
    const dims = fbcon.dimensions();
    columns = dims.columns;
    rows = dims.rows;
    // Where the cursor was, clamped into whatever the new geometry allows: the
    // text it follows is still on the screen.
    moveTo(col, row);
    return true;
}

pub fn pixelSize() Size {
    return if (fbcon.active()) fbcon.pixelSize() else .{ .width = 0, .height = 0 };
}

pub fn cellSize() Size {
    return if (fbcon.active()) fbcon.cellSize() else .{ .width = 8, .height = 16 };
}

/// Fill a pixel rectangle. Does nothing in text mode.
pub fn fillPixelRect(x: usize, y: usize, w: usize, h: usize, colour: Color) void {
    if (fbcon.active()) fbcon.fillRect(x, y, w, h, @intFromEnum(colour));
}

/// Name of the active font, for the boot log.
pub fn fontName() []const u8 {
    return if (fbcon.active()) fbcon.fontName() else "VGA ROM 8x16";
}

pub fn useFramebuffer(bi: *const bootinfo.BootInfo) bool {
    if (!fbcon.init(bi)) return false;
    const dims = fbcon.dimensions();
    columns = dims.columns;
    rows = dims.rows;
    moveTo(0, 0);
    return true;
}

const backend = struct {
    fn putAt(x: usize, y: usize, cp: u21, front: Color, back: Color) void {
        if (fbcon.active()) {
            fbcon.putAt(x, y, cp, @intFromEnum(front), @intFromEnum(back));
        } else {
            vgatext.putAt(x, y, toCp437(cp), front, back);
        }
    }

    fn fill(cp: u21, front: Color, back: Color) void {
        if (fbcon.active()) {
            fbcon.fill(cp, @intFromEnum(front), @intFromEnum(back));
        } else {
            vgatext.fill(toCp437(cp), front, back);
        }
    }

    fn scroll(front: Color, back: Color) void {
        if (fbcon.active()) {
            fbcon.scroll(@intFromEnum(back));
        } else {
            vgatext.scroll(front, back);
        }
    }

    fn setCursor(x: usize, y: usize) void {
        if (fbcon.active()) {
            fbcon.setCursor(x, y, @intFromEnum(fg), @intFromEnum(bg));
        } else {
            vgatext.setCursor(x, y);
        }
    }

    fn showCursor(visible: bool) void {
        if (fbcon.active()) fbcon.showCursor(visible) else vgatext.showCursor(visible);
    }

    /// What is in a cell, for saving the screen before something draws over it.
    fn cellAt(x: usize, y: usize) Saved {
        if (fbcon.active()) {
            const cell = fbcon.cellAt(x, y);
            return .{ .cp = cell.cp, .fg = @enumFromInt(cell.fg), .bg = @enumFromInt(cell.bg) };
        }
        const cell = vgatext.cellAt(x, y);
        return .{ .cp = cell.ch, .fg = cell.fg, .bg = cell.bg };
    }
};

/// Width of the key column in the boot log. Defined once so `field`, `warn`
/// and `fail` cannot drift out of alignment with each other.
const KEY_WIDTH = 8;

var row: usize = 0;
var col: usize = 0;
var fg: Color = .light_grey;
var bg: Color = .black;

/// The debug pulse: what the corner cell currently holds, set from the
/// timer tick and repainted after every console write, so scrolling output
/// can never bury it and its stillness is exactly the arrival of dead ticks.
var pulse_glyph: ?u21 = null;

pub fn setPulse(glyph: u21) void {
    pulse_glyph = glyph;
    repaintPulse();
}

/// The corner cells, redrawn after everything this console draws so a
/// scroll can never bury them. A pulse that survives every line is the one
/// that freezes when interrupts do, and the vector pair beside it stays
/// readable in the photograph of the freeze.
fn repaintPulse() void {
    if (trace_vector) |vector| paintPair(columns - 4, vector, trace_moment);
    if (trace_syscall) |number| paintPair(columns - 7, number, syscall_moment);
    if (trace_pid) |pid| paintPair(columns - 10, pid, .completed);
    const glyph = pulse_glyph orelse return;
    backend.putAt(columns - 1, 0, glyph, .light_grey, .black);
}

// ---------------------------------------------------------------------------
// Interrupt context, and what it may draw
// ---------------------------------------------------------------------------

/// How many interrupt frames are live on this stack. The dispatcher keeps
/// this current; the renderer consults it, because an interrupt that lands
/// inside another context's half-drawn line must not tear the state that
/// line is drawn with.
var interrupt_depth: u32 = 0;

/// Whether some context is mid-render. One writer owns the console state at
/// a time; an interrupt arriving under it keeps the record and skips the
/// pixels rather than interleaving with a half-drawn line.
var render_busy: bool = false;

pub fn interruptEntered(vector: u8) void {
    interrupt_depth += 1;
    if (debug_enabled) traceIrq(vector, .taken);
}

pub fn interruptLeft(vector: u8) void {
    if (debug_enabled) traceIrq(vector, .completed);
    if (interrupt_depth > 0) interrupt_depth -= 1;
}

/// What a rendering entry point may do right now: own the console state,
/// borrow it from an outer frame on this same stack, or leave the pixels
/// alone because someone beneath this interrupt is mid-line.
const Render = enum { own, borrow, skip };

fn renderClaim() Render {
    if (!render_busy) return .own;
    return if (interrupt_depth > 0) .skip else .borrow;
}

/// The panic path draws over whatever was happening, and must never be the
/// thing a gate silences: the machine is done, the report is all there is.
pub fn seizeForPanic() void {
    render_busy = false;
    interrupt_depth = 0;
}

/// The debug boots' interrupt breadcrumb: the last vector taken, painted in
/// two corner cells the moment it is entered and dimmed the moment its
/// dispatch completes. In a photograph of a frozen machine, a bright pair
/// says which handler died; a dim pair says the machine died in ordinary
/// code, and still names the last interrupt that ran.
pub const TraceMoment = enum { taken, completed };

var trace_vector: ?u8 = null;
var trace_moment: TraceMoment = .completed;
var trace_syscall: ?u8 = null;
var syscall_moment: TraceMoment = .completed;
var trace_pid: ?u8 = null;

fn traceIrq(vector: u8, moment: TraceMoment) void {
    trace_vector = vector;
    trace_moment = moment;
    paintPair(columns - 4, vector, moment);
}

/// The last syscall entered, bright while its handler runs. In a frozen
/// photograph: a bright pair is the call that never returned; a dim pair
/// says the process was running its own code, the aperture reads a driver
/// makes in user mode included.
pub fn traceSyscall(number: u8, moment: TraceMoment) void {
    if (!debug_enabled) return;
    trace_syscall = number;
    syscall_moment = moment;
    paintPair(columns - 7, number, moment);
}

/// Which process the scheduler last switched to, so the frozen photograph
/// names who was on the CPU.
pub fn tracePid(pid: u32) void {
    if (!debug_enabled) return;
    const short: u8 = @truncate(pid);
    trace_pid = short;
    paintPair(columns - 10, short, .completed);
}

fn paintPair(at: usize, value: u8, moment: TraceMoment) void {
    if (columns < 10) return;
    const HEX = "0123456789abcdef";
    const ink: Color = if (moment == .taken) .light_red else .dark_grey;
    backend.putAt(at, 0, HEX[(value >> 4) & 0xF], ink, .black);
    backend.putAt(at + 1, 0, HEX[value & 0xF], ink, .black);
}

/// Whether colour reaches the screen at all.
///
/// Turned off by `nocolor` on the kernel command line. Every caller keeps
/// asking for the colours it wants and the console declines to use them, which
/// is the only arrangement where one flag covers the boot log, the panic
/// screen and every program at once.
var colour_enabled = true;

pub fn setColorEnabled(on: bool) void {
    colour_enabled = on;
    if (!on) {
        fg = .light_grey;
        bg = .black;
    }
}

pub fn init() void {
    setColor(.light_grey, .black);
    clear();
}

pub fn setColor(f: Color, b: Color) void {
    if (!colour_enabled) return;
    fg = f;
    bg = b;
}

pub fn clear() void {
    backend.fill(' ', fg, bg);
    moveTo(0, 0);
}

/// Paint the whole screen one colour and home the cursor.
pub fn fill(background: Color, foreground: Color) void {
    setColor(foreground, background);
    clear();
}

pub fn moveTo(x: usize, y: usize) void {
    col = @min(x, columns - 1);
    row = @min(y, rows - 1);
    wrap_pending = false;
    backend.setCursor(col, row);
}

/// Write one cell at an absolute position, bypassing the cursor. Used by the
/// panic screen, which paints a fixed layout rather than a scrolling log.
pub fn putAt(x: usize, y: usize, cp: u21, f: Color, b: Color) void {
    backend.putAt(x, y, cp, f, b);
}

fn newline() void {
    col = 0;
    row += 1;
    if (row >= rows) {
        backend.scroll(fg, bg);
        row = rows - 1;
    }
}

/// The escape sequences this console acts on.
///
/// The grammar is `lib.escapes`, shared with `eterm`, because there are two
/// terminals here and one meaning of `ESC [ 2 J`. What differs is only what
/// each does about it: this draws into a text grid and that draws into a
/// window.
///
/// Enough of the set that a full-screen program can work: colour, moving the
/// cursor, erasing, and hiding the cursor while redrawing. A program writes to
/// its output stream without knowing which terminal is on the other end, which
/// is the whole point of speaking the sequences every terminal already does.
const Escape = struct {
    var reader = escapes.Parser{};

    /// Feed a byte. True when the sequence machinery consumed it, which is
    /// every byte that is not an ordinary character.
    fn take(c: u8) bool {
        const action = reader.next(c) orelse return true;

        switch (action) {
            .print => |cp| {
                draw(@truncate(cp));
                return true;
            },
            .control => return false,
            .csi => |sequence| {
                apply(sequence);
                return true;
            },
            .escape, .osc => return true,
        }
    }

    /// One parsed `CSI`. Parameters default to what the standard says they
    /// default to, which is why `get` takes the fallback rather than the
    /// caller checking for absence.
    fn apply(sequence: escapes.Csi) void {
        if (sequence.private) return privateMode(sequence);

        switch (sequence.final) {
            'm' => {
                var i: usize = 0;
                while (i < @max(sequence.count, 1)) : (i += 1) rendition(sequence.get(i, 0));
            },
            // Rows and columns count from one in the sequence and from nought here.
            'H', 'f' => moveTo(param(sequence, 1) -| 1, param(sequence, 0) -| 1),
            'A' => moveTo(col, row -| param(sequence, 0)),
            'B' => moveTo(col, row + param(sequence, 0)),
            'C' => moveTo(col + param(sequence, 0), row),
            'D' => moveTo(col -| param(sequence, 0), row),
            'J' => eraseDisplay(sequence.get(0, 0)),
            'K' => eraseLine(sequence.get(0, 0)),
            else => {},
        }
    }

    /// The private modes: hiding the cursor, and putting the screen aside.
    fn privateMode(sequence: escapes.Csi) void {
        const on = sequence.final == 'h';

        switch (sequence.get(0, 0)) {
            // How a program stops the cursor flickering across a screen it is
            // in the middle of redrawing.
            25 => backend.showCursor(on),
            // 47 is the older spelling of the same idea and still what some
            // programs send. Both are answered, because a program that asked
            // either way meant the same thing.
            47, 1047, 1049 => if (on) Alternate.enter() else Alternate.leave(),
            // A program managing its own input line asks for raw the same way
            // it asks `eterm`: the terminal's display side telling its input
            // side to step aside, which over the console is the line
            // discipline in `tty`.
            escapes.private_mode.app_line_edit => _ = tty.setMode(if (on) .raw else .cooked),
            else => {},
        }
    }

    /// One parameter as a cell count. Defaulting to one, which is what every
    /// movement and position sequence means by an absent parameter.
    fn param(sequence: escapes.Csi, index: usize) usize {
        return sequence.get(index, 1);
    }

    /// 0 to the end, 1 from the start, 2 the whole thing. The cursor does not
    /// move: a program that meant to move it says so separately, and one that
    /// did not would be surprised to find it had.
    fn eraseDisplay(how: usize) void {
        const from = switch (how) {
            1 => 0,
            2 => 0,
            else => row * columns + col,
        };
        const to = switch (how) {
            1 => row * columns + col + 1,
            else => rows * columns,
        };
        eraseCells(from, to);
    }

    fn eraseLine(how: usize) void {
        const start_of_line = row * columns;
        const from = switch (how) {
            1 => start_of_line,
            2 => start_of_line,
            else => start_of_line + col,
        };
        const to = switch (how) {
            1 => start_of_line + col + 1,
            else => start_of_line + columns,
        };
        eraseCells(from, to);
    }

    fn eraseCells(from: usize, to: usize) void {
        var cell = from;
        while (cell < @min(to, rows * columns)) : (cell += 1) {
            backend.putAt(cell % columns, cell / columns, ' ', fg, bg);
        }
    }

    /// A colour in the sequence's numbering, as one in this console's.
    ///
    /// The two orderings are not the same and never were: a terminal counts
    /// red, green, yellow, blue, and a VGA-descended console counts blue,
    /// green, cyan, red. Reading one as the other turns every colour into a
    /// different one, which is subtle enough to look like a palette choice
    /// rather than a bug.
    fn fromAnsi(index: usize) Color {
        return switch (index) {
            0 => .black,
            1 => .red,
            2 => .green,
            3 => .brown,
            4 => .blue,
            5 => .magenta,
            6 => .cyan,
            else => .light_grey,
        };
    }

    /// One rendition parameter, in the numbering every terminal shares.
    fn rendition(which: usize) void {
        switch (which) {
            0 => setColor(.light_grey, .black),
            1 => setColor(bright(fg), bg),
            7 => setColor(bg, fg),
            30...37 => setColor(fromAnsi(which - 30), bg),
            39 => setColor(.light_grey, bg),
            40...47 => setColor(fg, fromAnsi(which - 40)),
            49 => setColor(fg, .black),
            90...97 => setColor(bright(fromAnsi(which - 90)), bg),
            100...107 => setColor(fg, bright(fromAnsi(which - 100))),
            else => {},
        }
    }

    /// The bright half of the palette is the dim half with one bit set, which
    /// is what makes bold and the 90-series the same operation.
    fn bright(c: Color) Color {
        return @enumFromInt(@intFromEnum(c) | 0x8);
    }
};

/// One cell as it was, for putting back.
const Saved = struct {
    cp: u21,
    fg: Color,
    bg: Color,
};

/// The screen a full-screen program is drawing over.
///
/// `ESC [ ? 1049 h` puts the screen aside and hands over a blank one; the `l`
/// form puts it back. That is what lets an editor take the whole display and
/// leave the shell's scrollback exactly as it was, rather than the shell
/// drawing its next prompt over whatever the editor left behind.
///
/// Allocated when a program asks and given back when it leaves, because most
/// of the time nothing is using it and a screen's worth of cells is not free.
const Alternate = struct {
    var cells: ?[]Saved = null;
    var at_col: usize = 0;
    var at_row: usize = 0;
    var was_fg: Color = .light_grey;
    var was_bg: Color = .black;

    fn enter() void {
        if (cells != null) return;

        const room = heap.allocator.alloc(Saved, columns * rows) catch return;
        for (0..rows) |y| {
            for (0..columns) |x| room[y * columns + x] = backend.cellAt(x, y);
        }

        cells = room;
        at_col = col;
        at_row = row;
        was_fg = fg;
        was_bg = bg;

        clear();
    }

    fn leave() void {
        const room = cells orelse return;
        cells = null;
        defer heap.allocator.free(room);

        for (0..rows) |y| {
            for (0..columns) |x| {
                const cell = room[y * columns + x];
                backend.putAt(x, y, cell.cp, cell.fg, cell.bg);
            }
        }

        setColor(was_fg, was_bg);
        moveTo(at_col, at_row);
    }
};

/// Set when the last column has been written and the line is full, but nothing
/// has yet arrived that needs the next one.
///
/// A terminal wraps late, not eagerly: writing the eightieth character of an
/// eighty-column line leaves the cursor on that character rather than on the
/// next line. Wrapping there instead would scroll the screen for a line that
/// exactly fits, which is why a full-screen program that draws to the last
/// column loses its top line on a console that gets this wrong.
var wrap_pending = false;

/// Put one character where the cursor is and move it along.
///
/// A codepoint rather than a byte: the parser ahead of this assembles UTF-8,
/// so anything past ASCII arrives here whole and truncating it to a byte would
/// draw a different character or none.
fn draw(cp: u21) void {
    if (wrap_pending) {
        newline();
        wrap_pending = false;
    }

    backend.putAt(col, row, cp, fg, bg);

    if (col + 1 >= columns) {
        wrap_pending = true;
    } else {
        col += 1;
    }
}

pub fn putChar(c: u8) void {
    if (mirror) |sink| sink(&[_]u8{c});
    if (Escape.take(c)) return repaintPulse();

    // What is left is a control character the parser passed through, which is
    // the only kind this has an opinion about.
    switch (c) {
        '\n' => {
            wrap_pending = false;
            newline();
        },
        '\r' => {
            wrap_pending = false;
            col = 0;
        },
        // Form feed clears the screen. The traditional meaning, and it saves
        // inventing a syscall for something a terminal has always done with a
        // byte: `clear` in the shell is one write.
        0x0C => clear(),
        '\t' => {
            const next = (col + 8) & ~@as(usize, 7);
            while (col < next and col < columns) : (col += 1) {
                backend.putAt(col, row, ' ', fg, bg);
            }
            if (col >= columns) newline();
        },
        8 => if (col > 0) {
            if (!wrap_pending) col -= 1;
            wrap_pending = false;
            backend.putAt(col, row, ' ', fg, bg);
        },
        else => draw(c),
    }
    repaintPulse();
}

pub fn writeString(s: []const u8) void {
    switch (renderClaim()) {
        .own => {},
        .borrow => {
            for (s) |c| putChar(c);
            backend.setCursor(col, row);
            return;
        },
        // Pixels belong to the interrupted writer; the serial mirror has
        // no shared state to tear and still carries the bytes.
        .skip => {
            if (mirror) |sink| sink(s);
            return;
        },
    }
    render_busy = true;
    defer render_busy = false;
    for (s) |c| putChar(c);
    backend.setCursor(col, row);
}

/// Optional second destination for everything written to the console.
///
/// Registered by the composition root when a serial port is found. The target
/// machine has none, but QEMU and most other hardware do, and having the boot
/// log arrive as text rather than pixels is the difference between reading it
/// and photographing it.
var mirror: ?*const fn ([]const u8) void = null;

pub fn setMirror(sink: *const fn ([]const u8) void) void {
    mirror = sink;
}

// ---------------------------------------------------------------------------
// Formatted output
// ---------------------------------------------------------------------------

/// std.Io.Writer adapter, so kernel code gets the normal `print("{d}", .{x})`
/// machinery.
///
/// The buffer is intentionally empty: every write goes straight through `drain`
/// to the backend. Buffering would mean a panic mid-format loses the last
/// partial line, exactly the line you need on a machine whose only diagnostic
/// is the screen.
var console_writer: std.Io.Writer = .{
    .vtable = &.{ .drain = drain },
    .buffer = &.{},
};

fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
    if (w.end > 0) {
        for (w.buffer[0..w.end]) |c| putChar(c);
        w.end = 0;
    }
    const head = data[0 .. data.len - 1];
    const pattern = data[head.len];

    var written: usize = 0;
    for (head) |bytes| {
        for (bytes) |c| putChar(c);
        written += bytes.len;
    }
    var i: usize = 0;
    while (i < splat) : (i += 1) {
        for (pattern) |c| putChar(c);
    }
    return written + pattern.len * splat;
}

/// Float formatting is never used in the kernel: it is built without x87/SSE
/// (see build.zig), so a float here is a link error rather than a runtime
/// surprise.
pub fn printf(comptime fmt: []const u8, args: anytype) void {
    switch (renderClaim()) {
        .own => {},
        .borrow => {
            console_writer.print(fmt, args) catch {};
            backend.setCursor(col, row);
            return;
        },
        .skip => return,
    }
    render_busy = true;
    defer render_busy = false;
    console_writer.print(fmt, args) catch {};
    backend.setCursor(col, row);
}

// ---------------------------------------------------------------------------
// Boot log
// ---------------------------------------------------------------------------

/// A role in this console's palette. The scheme is `lib.style`'s; this is the
/// half that spells it in the colours a VGA-descended console has.
pub fn colourOf(role: style.Role) Color {
    return switch (role) {
        .key => .light_cyan,
        .value => .light_grey,
        .good => .light_green,
        .warn => .yellow,
        .bad => .light_red,
        .dim => .dark_grey,
        .accent => .light_green,
    };
}

/// One boot-log line: a coloured key column, then the value. Terse by design,
/// this is a system log, not narration.
fn logLine(key: []const u8, role: style.Role, comptime fmt: []const u8, args: anytype) void {
    const key_color = colourOf(role);
    recordLine(key, fmt, args);

    // The record above is the line's real home. Pixels are painted only
    // when no other context is mid-line: an interrupt narrating over a
    // half-drawn line would tear the state both are drawn with. The serial
    // mirror still carries the skipped line; it has no state to tear.
    switch (renderClaim()) {
        .own => {},
        .borrow => {},
        .skip => {
            if (mirror) |sink| {
                var scratch: [256]u8 = undefined;
                sink(composeLine(&scratch, key, fmt, args));
            }
            return;
        },
    }
    const owned = !render_busy;
    render_busy = true;
    defer if (owned) {
        render_busy = false;
    };

    const saved = fg;
    setColor(key_color, bg);
    writeString(key);
    setColor(saved, bg);

    // At least one space, so a key exactly KEY_WIDTH long does not run into
    // its value.
    var n = key.len;
    while (n < KEY_WIDTH) : (n += 1) putChar(' ');
    if (key.len >= KEY_WIDTH) putChar(' ');

    printf(fmt, args);
    putChar('\n');
    backend.setCursor(col, row);
}

/// The two ways a boot line reaches the screen.
///
/// `verbose` shows the narration: one line per component as it comes up. A
/// working system boots quietly by default, and the checks themselves always
/// run; only their success output is suppressed, so a regression still
/// surfaces as a `warn` or `fail` line. Enabled with `verbose` on the kernel
/// command line.
///
/// `debug` is the deeper tier, for chasing a fault: register values, the
/// steps of a shutdown, what a probe read back. Separate because the
/// narration is wanted for itself, and because a debug line is the one kind
/// that is *not* recorded when it is not asked for. Enabled with `debug`.
var verbose = false;
var debug_enabled = false;

pub fn setVerbose(on: bool) void {
    verbose = on;
}

pub fn isVerbose() bool {
    return verbose;
}

pub fn setDebug(on: bool) void {
    debug_enabled = on;
}

pub fn isDebug() bool {
    return debug_enabled;
}

/// Keep a line whether or not it is printed.
///
/// A quiet boot shows almost nothing by design, and the machine should still
/// know what happened. Formatted into a scratch buffer rather than written
/// through the console's writer, which goes to the screen.
fn recordLine(key: []const u8, comptime fmt: []const u8, args: anytype) void {
    var scratch: [256]u8 = undefined;
    klog.append(composeLine(&scratch, key, fmt, args));
}

/// One boot-log line, formatted the way both the record and the mirror
/// carry it: padded key, message, newline.
fn composeLine(buf: []u8, key: []const u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.print("{s}", .{key}) catch {};
    var n = key.len;
    while (n < KEY_WIDTH) : (n += 1) w.print(" ", .{}) catch {};
    w.print(fmt, args) catch {};
    w.print("\n", .{}) catch {};
    return buf[0..w.end];
}

/// A boot-narration line: one component saying what it came to.
///
/// Recorded always, shown only in verbose mode. The line still exists on a
/// quiet boot, in the kernel log, so `log` can say what happened without a
/// reboot: the alternative is booting with `verbose` and hoping the fault
/// repeats.
pub fn info(key: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!verbose) {
        recordLine(key, fmt, args);
        return;
    }
    logLine(key, .key, fmt, args);
}

/// A fault-chasing line: what a register held, which write was about to be
/// made. The one kind that costs nothing when it is off: with `debug` absent
/// from the command line the line is neither shown nor recorded. Dim, so a
/// screen full of chasing reads as background behind the boot's own story.
pub fn debug(key: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (!debug_enabled) return;
    logLine(key, .dim, fmt, args);
}

/// A line worth showing a user regardless of verbosity.
pub fn field(key: []const u8, comptime fmt: []const u8, args: anytype) void {
    logLine(key, .key, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    logLine("warn", .warn, fmt, args);
}

pub fn fail(comptime fmt: []const u8, args: anytype) void {
    logLine("fail", .bad, fmt, args);
}

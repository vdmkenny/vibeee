//! Line discipline: turns key events into lines of text for `read`.
//!
//! Sits between the input core and the read syscall. Editing happens here
//! rather than in each program, so every prompt, the shell, a password field,
//! anything that reads a line, behaves the same way.
//!
//! Two modes. Cooked delivers a line at a time, after Enter, and echoes as it
//! goes: what a program that only wants an answer needs. Raw delivers each
//! keystroke as it happens and echoes nothing, with the keys that produce no
//! character arriving as the escape sequences a terminal sends for them: what
//! a program drawing its own input line needs, because it has to know where
//! the cursor went and the kernel must not draw over it.

const std = @import("std");
const abi = @import("lib").syscalls;
const console = @import("console.zig");
const input = @import("input.zig");

/// Long enough for a command line, short enough that a stuck key cannot eat
/// memory. Input past the limit is refused with a beep rather than silently
/// truncating what the user typed.
const LINE_MAX = 256;

var line: [LINE_MAX]u8 = undefined;
var line_len: usize = 0;

/// Bytes ready to be read, and how far a reader has got through them.
var ready: [LINE_MAX + 1]u8 = undefined;
var ready_len: usize = 0;
var ready_pos: usize = 0;

var echo = true;

pub fn setEcho(on: bool) void {
    echo = on;
}

var mode: abi.TtyMode = .cooked;

/// Choose the mode, returning the one that was in effect.
pub fn setMode(wanted: abi.TtyMode) abi.TtyMode {
    const was = mode;
    mode = wanted;
    // A half-typed line belongs to the mode it was typed in.
    line_len = 0;
    ready_len = 0;
    ready_pos = 0;
    return was;
}

/// What a key with no character of its own sends, which is what every terminal
/// sends for it. Written once here so the kernel and the editors that read it
/// cannot disagree about what an arrow key looks like.
fn sequenceFor(code: input.KeyCode) ?[]const u8 {
    return switch (code) {
        .up => "\x1b[A",
        .down => "\x1b[B",
        .right => "\x1b[C",
        .left => "\x1b[D",
        .home => "\x1b[H",
        .end => "\x1b[F",
        .delete => "\x1b[3~",
        .page_up => "\x1b[5~",
        .page_down => "\x1b[6~",
        else => null,
    };
}

/// Hand a keystroke straight to the reader, as bytes.
fn deliver(bytes: []const u8) void {
    const room = ready.len - ready_len;
    const n = @min(bytes.len, room);
    @memcpy(ready[ready_len..][0..n], bytes[0..n]);
    ready_len += n;
}

fn emit(bytes: []const u8) void {
    if (echo) console.writeString(bytes);
}

/// Consume pending key events into the line buffer.
///
/// Called from the read path rather than from the interrupt handler: the
/// handler should do as little as possible, and echoing to the console from
/// interrupt context would mean the console lock, once there is one, is taken
/// at unpredictable moments.
fn pump() void {
    while (input.poll()) |event| {
        if (!event.pressed) continue;

        // Raw mode has nothing to edit: every keystroke goes straight through,
        // as its character or as the sequence that stands for it.
        if (mode == .raw) {
            if (sequenceFor(event.code)) |seq| {
                deliver(seq);
                continue;
            }
            if (event.codepoint == 0) continue;

            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(event.codepoint, &utf8) catch continue;
            deliver(utf8[0..n]);
            continue;
        }

        // Editing keys that produce no character.
        switch (event.code) {
            .backspace => {
                if (line_len > 0) {
                    // Step back over a whole UTF-8 sequence, not one byte, or
                    // erasing an accented character leaves half of it behind.
                    var back: usize = 1;
                    while (back < line_len and (line[line_len - back] & 0xC0) == 0x80) back += 1;
                    line_len -= back;
                    emit("\x08 \x08");
                }
                continue;
            },
            else => {},
        }

        const cp = event.codepoint;
        if (cp == 0) continue;

        if (cp == '\n' or cp == '\r') {
            line[line_len] = '\n';
            const total = line_len + 1;
            @memcpy(ready[0..total], line[0..total]);
            ready_len = total;
            ready_pos = 0;
            line_len = 0;
            emit("\n");
            continue;
        }

        // Ctrl+C abandons the line, matching what every terminal does.
        if (cp == 3) {
            line_len = 0;
            emit("^C\n");
            ready_len = 0;
            ready_pos = 0;
            continue;
        }

        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &utf8) catch continue;
        if (line_len + n >= LINE_MAX) continue;

        @memcpy(line[line_len..][0..n], utf8[0..n]);
        line_len += n;
        emit(utf8[0..n]);
    }
}

/// True when a complete line is waiting.
pub fn hasLine() bool {
    pump();
    return ready_pos < ready_len;
}

/// Read up to `buf.len` bytes of a completed line.
///
/// Returns 0 when nothing is ready. The caller decides whether to block, since
/// blocking belongs to the scheduler rather than here.
pub fn read(buf: []u8) usize {
    pump();
    if (ready_pos >= ready_len) return 0;

    const available = ready_len - ready_pos;
    const take = @min(available, buf.len);
    @memcpy(buf[0..take], ready[ready_pos..][0..take]);
    ready_pos += take;
    return take;
}

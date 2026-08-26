//! Line discipline: turns key events into lines of text for `read`.
//!
//! Sits between the input core and the read syscall. Editing happens here
//! rather than in each program, so every prompt — the shell, a password field,
//! anything that reads a line — behaves the same way.
//!
//! Canonical mode only: input is delivered a line at a time, after Enter.
//! Raw mode arrives with the terminal emulator, which needs per-keystroke
//! delivery; nothing yet does.

const std = @import("std");
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

fn emit(bytes: []const u8) void {
    if (echo) console.writeString(bytes);
}

/// Consume pending key events into the line buffer.
///
/// Called from the read path rather than from the interrupt handler: the
/// handler should do as little as possible, and echoing to the console from
/// interrupt context would mean the console lock — once there is one — is taken
/// at unpredictable moments.
fn pump() void {
    while (input.poll()) |event| {
        if (!event.pressed) continue;

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

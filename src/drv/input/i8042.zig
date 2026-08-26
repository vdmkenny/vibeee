//! i8042 keyboard controller.
//!
//! Verified present on the target: PS/2 keyboard on IRQ1 and touchpad on IRQ12,
//! through the ENE KB3310 embedded controller acting as the KBC.
//!
//! Scancode **set 1** is decoded, which is what the controller produces with
//! its default translation enabled. Set 2 without translation is arguably
//! cleaner, but switching means talking the keyboard out of a state the BIOS
//! left it in, and getting that wrong on a machine with no serial port means a
//! dead keyboard and no way to see why.

const std = @import("std");
const console = @import("../../kernel/console.zig");
const input = @import("../../kernel/input.zig");
const keymap = @import("../../kernel/keymap.zig");
const idt = @import("../../arch/x86/idt.zig");
const port = @import("../../arch/x86/port.zig");

const DATA = 0x60;
const STATUS = 0x64;
const COMMAND = 0x64;

const ST_OUTPUT_FULL: u8 = 1 << 0;
const ST_INPUT_FULL: u8 = 1 << 1;

const KeyCode = input.KeyCode;

/// Scancode set 1, unprefixed. Index is the make code; break codes are the
/// make code with bit 7 set.
const SET1 = blk: {
    var t: [128]KeyCode = @splat(.none);
    t[0x01] = .escape;
    t[0x02] = .n1;  t[0x03] = .n2;  t[0x04] = .n3;  t[0x05] = .n4;  t[0x06] = .n5;
    t[0x07] = .n6;  t[0x08] = .n7;  t[0x09] = .n8;  t[0x0A] = .n9;  t[0x0B] = .n0;
    t[0x0C] = .minus; t[0x0D] = .equal; t[0x0E] = .backspace; t[0x0F] = .tab;
    t[0x10] = .q; t[0x11] = .w; t[0x12] = .e; t[0x13] = .r; t[0x14] = .t;
    t[0x15] = .y; t[0x16] = .u; t[0x17] = .i; t[0x18] = .o; t[0x19] = .p;
    t[0x1A] = .bracket_left; t[0x1B] = .bracket_right; t[0x1C] = .enter;
    t[0x1D] = .control_left;
    t[0x1E] = .a; t[0x1F] = .s; t[0x20] = .d; t[0x21] = .f; t[0x22] = .g;
    t[0x23] = .h; t[0x24] = .j; t[0x25] = .k; t[0x26] = .l;
    t[0x27] = .semicolon; t[0x28] = .apostrophe; t[0x29] = .grave;
    t[0x2A] = .shift_left; t[0x2B] = .backslash;
    t[0x2C] = .z; t[0x2D] = .x; t[0x2E] = .c; t[0x2F] = .v; t[0x30] = .b;
    t[0x31] = .n; t[0x32] = .m;
    t[0x33] = .comma; t[0x34] = .period; t[0x35] = .slash; t[0x36] = .shift_right;
    t[0x37] = .keypad_asterisk; t[0x38] = .alt_left; t[0x39] = .space;
    t[0x3A] = .caps_lock;
    t[0x3B] = .f1; t[0x3C] = .f2; t[0x3D] = .f3; t[0x3E] = .f4; t[0x3F] = .f5;
    t[0x40] = .f6; t[0x41] = .f7; t[0x42] = .f8; t[0x43] = .f9; t[0x44] = .f10;
    t[0x45] = .num_lock; t[0x46] = .scroll_lock;
    t[0x47] = .kp7; t[0x48] = .kp8; t[0x49] = .kp9; t[0x4A] = .kp_minus;
    t[0x4B] = .kp4; t[0x4C] = .kp5; t[0x4D] = .kp6; t[0x4E] = .kp_plus;
    t[0x4F] = .kp1; t[0x50] = .kp2; t[0x51] = .kp3; t[0x52] = .kp0;
    t[0x53] = .kp_period;
    // The extra key ISO keyboards have beside left shift. AZERTY uses it, so
    // omitting it would lose `< > \` on the target machine's own keyboard.
    t[0x56] = .iso_extra;
    t[0x57] = .f11; t[0x58] = .f12;
    break :blk t;
};

/// Keys that arrive prefixed with 0xE0.
const SET1_EXTENDED = blk: {
    var t: [128]KeyCode = @splat(.none);
    t[0x1C] = .kp_enter;
    t[0x1D] = .control_right;
    t[0x35] = .kp_slash;
    t[0x38] = .alt_right;
    t[0x47] = .home;  t[0x48] = .up;    t[0x49] = .page_up;
    t[0x4B] = .left;  t[0x4D] = .right;
    t[0x4F] = .end;   t[0x50] = .down;  t[0x51] = .page_down;
    t[0x52] = .insert; t[0x53] = .delete;
    t[0x5B] = .super_left; t[0x5C] = .super_right; t[0x5D] = .menu;
    break :blk t;
};

var expecting_extended = false;

/// Called for a key event that no text consumer should see, e.g. the layout
/// switch. Returning true swallows the event.
fn handleHotkey(code: KeyCode, mods: input.Modifiers) bool {
    // Super+Space cycles layouts. Bound by *position* rather than by symbol, so
    // it stays in the same physical place when the layout changes, which is
    // the whole point of a layout-switch key.
    if (code == .space and mods.super) {
        const layout = keymap.cycleLayout();
        keymap.resetCompose();
        console.field("layout", "{s}", .{layout.name});
        return true;
    }
    return false;
}

/// Interrupt handler for IRQ1.
pub fn onKeyboardInterrupt() void {
    // Drain, because the controller may have more than one byte buffered and a
    // single read per interrupt would fall permanently behind under fast typing.
    while (port.inb(STATUS) & ST_OUTPUT_FULL != 0) {
        const byte = port.inb(DATA);

        if (byte == 0xE0) {
            expecting_extended = true;
            continue;
        }
        // 0xE1 introduces the Pause sequence, which is 6 bytes and produces no
        // useful key. Swallowing the prefix alone would misread the rest as
        // ordinary keys, so the whole sequence is skipped by ignoring it here
        // and letting the remaining bytes decode to .none.
        if (byte == 0xE1) continue;

        const released = byte & 0x80 != 0;
        const make = byte & 0x7F;

        const code = if (expecting_extended) SET1_EXTENDED[make] else SET1[make];
        expecting_extended = false;

        if (code == .none) continue;

        input.applyModifier(code, !released);
        const mods = input.modifiers();

        if (!released and handleHotkey(code, mods)) continue;

        var event = input.Event{ .code = code, .pressed = !released, .mods = mods };

        // Only presses produce characters; a release that generated one would
        // double every keystroke.
        if (!released and !code.isModifier()) {
            const out = keymap.translate(code, mods);
            event.codepoint = out.codepoint;
            input.post(event);

            // A failed composition yields two characters: the accent that could
            // not combine, then the key that followed it.
            if (out.extra != 0) {
                input.post(.{ .code = code, .pressed = true, .mods = mods, .codepoint = out.extra });
            }
            continue;
        }

        input.post(event);
    }
}

fn waitForInputClear() void {
    var spins: u32 = 0;
    while (port.inb(STATUS) & ST_INPUT_FULL != 0 and spins < 100_000) : (spins += 1) {}
}

pub fn init() void {
    // Flush anything the BIOS left buffered, so the first real keystroke is not
    // preceded by a stale one.
    var drained: u32 = 0;
    while (port.inb(STATUS) & ST_OUTPUT_FULL != 0 and drained < 32) : (drained += 1) {
        _ = port.inb(DATA);
    }

    // Enable the keyboard's interrupt in the controller's configuration byte.
    // The rest of the byte is left as the BIOS set it: it has already worked out
    // this machine's translation and clock settings, and second-guessing that
    // on hardware with no serial port risks a keyboard that cannot report why
    // it is dead.
    waitForInputClear();
    port.outb(COMMAND, 0x20); // read configuration byte
    var spins: u32 = 0;
    while (port.inb(STATUS) & ST_OUTPUT_FULL == 0 and spins < 100_000) : (spins += 1) {}
    const config = port.inb(DATA);

    waitForInputClear();
    port.outb(COMMAND, 0x60); // write configuration byte
    waitForInputClear();
    port.outb(DATA, config | 0x01); // bit 0: keyboard interrupt enable

    idt.setHandler(idt.IRQ_BASE + 1, onIrq);
    idt.setPicMask(1, false);

    console.debug("kbd", "i8042 ready, layout {s}", .{keymap.current().name});
}

fn onIrq(_: *idt.Frame) void {
    onKeyboardInterrupt();
}

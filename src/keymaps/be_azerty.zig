//! Belgian AZERTY keyboard layout.
//!
//! The physical layout of the target machine's keyboard.
//!
//! Note how much sits behind AltGr: the bracket, brace, at, hash and backslash
//! keys are all third-level, which is why AltGr cannot be treated as optional
//! polish. The number row is unshifted punctuation, so digits need Shift — the
//! defining feature of AZERTY, and what most surprises a QWERTY typist.

const l = @import("layout.zig");

const Layout = l.Layout;
const k = l.k;
const ka = l.ka;
const letter = l.letter;

pub const layout = Layout{
    .name = "Belgian AZERTY",
    .tag = "BE",
    .keys = &.{
        .{ .escape, k(0x1B, 0x1B) },
        .{ .n1, ka('&', '1', '|', 0) },
        .{ .n2, ka(0xE9, '2', '@', 0) }, // é
        .{ .n3, ka('"', '3', '#', 0) },
        .{ .n4, ka('\'', '4', 0, 0) },
        .{ .n5, ka('(', '5', 0, 0) },
        .{ .n6, ka(0xA7, '6', '^', 0) }, // §
        .{ .n7, ka(0xE8, '7', 0, 0) }, // è
        .{ .n8, ka('!', '8', 0, 0) },
        .{ .n9, ka(0xE7, '9', '{', 0) }, // ç
        .{ .n0, ka(0xE0, '0', '}', 0) }, // à
        .{ .minus, ka(')', 0xB0, 0, 0) }, // °
        .{ .equal, ka('-', '_', 0, 0) },
        .{ .backspace, k(8, 8) },

        .{ .tab, k('\t', '\t') },
        // The AZERTY transposition: A and Z swap with Q and W, M moves.
        .{ .q, letter('a', 'A') },
        .{ .w, letter('z', 'Z') },
        .{ .e, ka('e', 'E', 0x20AC, 0) }, // €
        .{ .r, letter('r', 'R') },
        .{ .t, letter('t', 'T') },
        .{ .y, letter('y', 'Y') },
        .{ .u, letter('u', 'U') },
        .{ .i, letter('i', 'I') },
        .{ .o, letter('o', 'O') },
        .{ .p, letter('p', 'P') },
        .{ .bracket_left, .{ .dead_base = .circumflex, .dead_shift = .diaeresis, .levels = .{ .altgr = '[' } } },
        .{ .bracket_right, ka('$', '*', ']', 0) },
        .{ .enter, k('\n', '\n') },

        .{ .a, letter('q', 'Q') },
        .{ .s, letter('s', 'S') },
        .{ .d, letter('d', 'D') },
        .{ .f, letter('f', 'F') },
        .{ .g, letter('g', 'G') },
        .{ .h, letter('h', 'H') },
        .{ .j, letter('j', 'J') },
        .{ .k, letter('k', 'K') },
        .{ .l, letter('l', 'L') },
        .{ .semicolon, letter('m', 'M') },
        .{ .apostrophe, ka(0xF9, '%', 0xB4, 0) }, // ù ´
        .{ .grave, ka(0xB2, 0xB3, 0, 0) }, // ² ³

        // The ISO key beside left shift, which ANSI keyboards do not have.
        .{ .iso_extra, ka('<', '>', '\\', 0) },
        .{ .backslash, ka(0xB5, 0xA3, '`', 0) }, // µ £
        .{ .z, letter('w', 'W') },
        .{ .x, letter('x', 'X') },
        .{ .c, letter('c', 'C') },
        .{ .v, letter('v', 'V') },
        .{ .b, letter('b', 'B') },
        .{ .n, letter('n', 'N') },
        .{ .m, ka(',', '?', 0, 0) },
        .{ .comma, ka(';', '.', 0, 0) },
        .{ .period, ka(':', '/', 0, 0) },
        .{ .slash, ka('=', '+', '~', 0) },
        .{ .space, k(' ', ' ') },
    },
};

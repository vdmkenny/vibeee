//! US-International keyboard layout.
//!
//! The default: what gets touch-typed regardless of what the keycaps say.
//!
//! Differs from plain US in one way that matters — apostrophe, quote, backtick,
//! tilde and circumflex are dead keys that compose with the character after
//! them. Following one with a space produces the literal character, which is
//! the standard escape.

const l = @import("layout.zig");

const Layout = l.Layout;
const k = l.k;
const ka = l.ka;
const letter = l.letter;

pub const layout = Layout{
    .name = "US-International",
    .tag = "US",
    .keys = &.{
        .{ .escape, k(0x1B, 0x1B) },
        .{ .n1, ka('1', '!', 0xA1, 0xB9) }, // ¡ ¹
        .{ .n2, ka('2', '@', 0xB2, 0) },
        .{ .n3, ka('3', '#', 0xB3, 0) },
        .{ .n4, ka('4', '$', 0xA4, 0xA3) }, // ¤ £
        .{ .n5, ka('5', '%', 0x20AC, 0) }, // €
        .{ .n6, .{ .levels = .{ .base = '6', .shift = 0, .altgr = 0xBC }, .dead_shift = .circumflex } },
        .{ .n7, ka('7', '&', 0xBD, 0) },
        .{ .n8, ka('8', '*', 0xBE, 0) },
        .{ .n9, ka('9', '(', 0x2018, 0) },
        .{ .n0, ka('0', ')', 0x2019, 0) },
        .{ .minus, ka('-', '_', 0xA5, 0) },
        .{ .equal, ka('=', '+', 0xD7, 0xF7) },
        .{ .backspace, k(8, 8) },

        .{ .tab, k('\t', '\t') },
        .{ .q, letter('q', 'Q') },
        .{ .w, letter('w', 'W') },
        .{ .e, ka('e', 'E', 0xE9, 0xC9) }, // é É
        .{ .r, letter('r', 'R') },
        .{ .t, letter('t', 'T') },
        .{ .y, ka('y', 'Y', 0xFC, 0xDC) }, // ü Ü
        .{ .u, ka('u', 'U', 0xFA, 0xDA) }, // ú Ú
        .{ .i, ka('i', 'I', 0xED, 0xCD) }, // í Í
        .{ .o, ka('o', 'O', 0xF3, 0xD3) }, // ó Ó
        .{ .p, ka('p', 'P', 0xF6, 0xD6) }, // ö Ö
        .{ .bracket_left, ka('[', '{', 0xAB, 0) },
        .{ .bracket_right, ka(']', '}', 0xBB, 0) },
        .{ .enter, k('\n', '\n') },

        .{ .a, ka('a', 'A', 0xE1, 0xC1) }, // á Á
        .{ .s, ka('s', 'S', 0xDF, 0xA7) }, // ß §
        .{ .d, letter('d', 'D') },
        .{ .f, letter('f', 'F') },
        .{ .g, letter('g', 'G') },
        .{ .h, letter('h', 'H') },
        .{ .j, letter('j', 'J') },
        .{ .k, letter('k', 'K') },
        .{ .l, ka('l', 'L', 0xF8, 0xD8) }, // ø Ø
        .{ .semicolon, ka(';', ':', 0xB6, 0xB0) },
        .{ .apostrophe, .{ .dead_base = .acute, .dead_shift = .diaeresis, .levels = .{ .altgr = 0xB4 } } },
        .{ .grave, .{ .dead_base = .grave, .dead_shift = .tilde } },

        .{ .backslash, ka('\\', '|', 0xAC, 0xA6) },
        .{ .z, ka('z', 'Z', 0xE6, 0xC6) }, // æ Æ
        .{ .x, letter('x', 'X') },
        .{ .c, ka('c', 'C', 0xA9, 0xA2) }, // © ¢
        .{ .v, letter('v', 'V') },
        .{ .b, letter('b', 'B') },
        .{ .n, ka('n', 'N', 0xF1, 0xD1) }, // ñ Ñ
        .{ .m, ka('m', 'M', 0xB5, 0) },
        .{ .comma, ka(',', '<', 0xE7, 0xC7) }, // ç Ç
        .{ .period, ka('.', '>', 0, 0) },
        .{ .slash, ka('/', '?', 0xBF, 0) },
        .{ .space, k(' ', ' ') },
    },
};

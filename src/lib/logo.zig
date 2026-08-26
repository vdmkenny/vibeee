//! The vibeee wordmark, in characters.
//!
//! Shared because both sides draw it: the kernel at the top of the boot log,
//! and `eeefetch` from userspace. It is pure data with no dependencies, which
//! is what lets one copy serve both — the alternative was the same six lines
//! of backslashes maintained in two places, where a one-character difference
//! would be invisible until someone put the two screens side by side.
//!
//! Plain ASCII rather than box-drawing characters: the panic screen and the
//! early boot log run before any font is chosen, and a glyph the VGA ROM font
//! lacks would render as a notdef box.

/// Six lines, each 32 columns, padded so the block is rectangular. Callers can
/// therefore print something to the right of it without measuring.
pub const lines = [_][]const u8{
    "        _ _                     ",
    " __   _(_) |__   ___  ___  ___  ",
    " \\ \\ / / | '_ \\ / _ \\/ _ \\/ _ \\ ",
    "  \\ V /| | |_) |  __/  __/  __/ ",
    "   \\_/ |_|_.__/ \\___|\\___|\\___| ",
    "                                ",
};

pub const width = lines[0].len;
pub const height = lines.len;

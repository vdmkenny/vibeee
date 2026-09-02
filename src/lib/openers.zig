//! Which program opens what.
//!
//! A program says what it is willing to open rather than being named in a
//! table somewhere else: adding one is a row here beside the program, and
//! nothing has to remember to teach the file manager about it. What a file
//! is comes from `kind`, so a program registers for families rather than for
//! a list of suffixes it would have to keep chasing.
//!
//! The choice is a setting, so somebody who wants pictures in something else
//! says so once and every window that opens a picture obeys. The default is
//! the first program that will take the family, which is what a machine with
//! one picture viewer should do without being configured at all.
//!
//! Pure and host-tested: nothing here spawns anything, it only answers who
//! would.

const std = @import("std");
const kind = @import("kind.zig");

/// What a program is willing to open, a bit per family.
///
/// A set rather than a list because that is what it is: asking whether a
/// program takes pictures is one test, and a program that takes two families
/// costs the same as one that takes one.
pub const Opens = packed struct(u16) {
    picture: bool = false,
    text: bool = false,
    audio: bool = false,
    video: bool = false,
    archive: bool = false,
    document: bool = false,
    font: bool = false,
    /// A program, which is opened by being run rather than by being read.
    program: bool = false,
    /// Anything at all, for something that shows bytes whatever they are.
    anything: bool = false,
    _rest: u7 = 0,

    pub fn takes(self: Opens, family: kind.Family) bool {
        if (self.anything) return true;
        return switch (family) {
            .picture => self.picture,
            .text => self.text,
            .audio => self.audio,
            .video => self.video,
            .archive => self.archive,
            .document => self.document,
            .font => self.font,
            .program => self.program,
            // A directory is walked into and bytes with no shape are opened
            // by nothing: neither is a program's business.
            .directory, .system, .data => false,
        };
    }
};

pub const Opener = struct {
    /// What the settings file and the shell call it.
    name: []const u8,
    path: []const u8,
    opens: Opens,
};

/// Every program that will open something, in the order a machine with no
/// settings should prefer them.
pub const table = [_]Opener{
    .{ .name = "eimg", .path = "/bin/eimg", .opens = .{ .picture = true } },
    .{ .name = "pad", .path = "/bin/pad", .opens = .{ .text = true } },
    // Not a system program: the character journal lives under home with the
    // rest of what is somebody's choice, and is there only when it was built.
    // Naming it here is what lets a .hero open from the launcher and the file
    // manager; when it is absent the open fails as any missing program would.
    .{ .name = "hero", .path = "/home/hero", .opens = .{ .document = true } },
};

/// Who would open this family, before anybody has chosen.
pub fn forFamily(family: kind.Family) ?Opener {
    for (table) |opener| {
        if (opener.opens.takes(family)) return opener;
    }
    return null;
}

pub fn byName(name: []const u8) ?Opener {
    for (table) |opener| {
        if (std.mem.eql(u8, opener.name, name)) return opener;
    }
    return null;
}

/// The program to open this family with: the chosen one when it is named and
/// will take it, and otherwise the first that will.
///
/// A choice that names something gone, or something that never opened this
/// family, falls back rather than failing: a settings file written by hand,
/// or one left behind by a build that carried a program this one does not,
/// should leave the machine working.
pub fn chosen(family: kind.Family, preference: []const u8) ?Opener {
    if (preference.len > 0) {
        if (byName(preference)) |named| {
            if (named.opens.takes(family)) return named;
        }
    }
    return forFamily(family);
}

/// Every family a program could be chosen for, which is what a settings pane
/// draws a row per.
pub const CHOOSABLE = [_]kind.Family{
    .picture,
    .text,
    .audio,
    .video,
    .archive,
    .document,
    .font,
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "a set answers for the families it holds and no others" {
    const viewer = Opens{ .picture = true };
    try std.testing.expect(viewer.takes(.picture));
    try std.testing.expect(!viewer.takes(.text));
    try std.testing.expect(!viewer.takes(.directory));

    const both = Opens{ .picture = true, .text = true };
    try std.testing.expect(both.takes(.picture));
    try std.testing.expect(both.takes(.text));

    // Anything means anything a program can be pointed at, which is still
    // not a directory or a shapeless file.
    const shower = Opens{ .anything = true };
    try std.testing.expect(shower.takes(.archive));
    try std.testing.expect(shower.takes(.text));
}

test "the set is a bit per family and fits its word" {
    try std.testing.expectEqual(@as(u16, 1), @as(u16, @bitCast(Opens{ .picture = true })));
    try std.testing.expectEqual(@as(u16, 2), @as(u16, @bitCast(Opens{ .text = true })));
    try std.testing.expectEqual(@as(usize, 2), @sizeOf(Opens));
}

test "a picture opens in the viewer this build carries" {
    const opener = forFamily(.picture) orelse return error.NothingOpensPictures;
    try std.testing.expectEqualStrings("eimg", opener.name);
}

test "text opens in the editor this build carries" {
    const opener = forFamily(.text) orelse return error.NothingOpensText;
    try std.testing.expectEqualStrings("pad", opener.name);
    try std.testing.expectEqualStrings("/bin/pad", opener.path);
}

test "a choice is obeyed, and a choice that cannot be is not" {
    // Named and willing.
    const asked = chosen(.text, "pad") orelse return error.NothingOpensText;
    try std.testing.expectEqualStrings("pad", asked.name);

    // Named, gone: fall back to whoever will take it rather than refuse.
    const missing = chosen(.text, "someone-elses-editor") orelse return error.NothingOpensText;
    try std.testing.expectEqualStrings("pad", missing.name);

    // Named, present, and not willing: the same.
    const unwilling = chosen(.text, "pad") orelse return error.NothingOpensText;
    try std.testing.expectEqualStrings("pad", unwilling.name);

    // Nothing at all opens a family nobody registered for.
    try std.testing.expectEqual(@as(?Opener, null), chosen(.video, ""));
}

test "every name in the table is its own" {
    for (table, 0..) |one, i| {
        for (table[i + 1 ..]) |other| {
            try std.testing.expect(!std.mem.eql(u8, one.name, other.name));
        }
        try std.testing.expect(one.path.len > 0);
    }
}

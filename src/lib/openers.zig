//! Which program opens what.
//!
//! A program says what it is willing to open, in a stanza of its own that
//! is installed with it: nothing here lists the programs a machine has, so
//! adding one is a program and its declaration and no edit to anything
//! else. What a file is comes from `kind`, so a program declares families
//! rather than a list of suffixes it would have to keep chasing.
//!
//! What is here is the policy: given the declarations a machine carries
//! and what its owner prefers, which program opens this file. Reading the
//! declarations is the caller's, since a machine reads them from a disk
//! and a test passes a literal.
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

/// Who would open this family, before anybody has chosen: the first
/// declaration that will take it.
pub fn forFamily(declared: []const Opener, family: kind.Family) ?Opener {
    for (declared) |opener| {
        if (opener.opens.takes(family)) return opener;
    }
    return null;
}

pub fn byName(declared: []const Opener, name: []const u8) ?Opener {
    for (declared) |opener| {
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
pub fn chosen(declared: []const Opener, family: kind.Family, preference: []const u8) ?Opener {
    if (preference.len > 0) {
        if (byName(declared, preference)) |named| {
            if (named.opens.takes(family)) return named;
        }
    }
    return forFamily(declared, family);
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

/// Declarations of the shape a machine's own would have, so the policy is
/// exercised without one.
const machine = [_]Opener{
    .{ .name = "eimg", .path = "/bin/eimg", .opens = .{ .picture = true } },
    .{ .name = "pad", .path = "/bin/pad", .opens = .{ .text = true } },
    .{ .name = "notes", .path = "/home/notes", .opens = .{ .text = true } },
};

test "the first program that will take a family is the one that gets it" {
    const opener = forFamily(&machine, .picture) orelse return error.NothingOpensPictures;
    try std.testing.expectEqualStrings("eimg", opener.name);

    const editor = forFamily(&machine, .text) orelse return error.NothingOpensText;
    try std.testing.expectEqualStrings("pad", editor.name);
    try std.testing.expectEqualStrings("/bin/pad", editor.path);
}

test "a choice is obeyed, and a choice that cannot be is not" {
    // Named and willing, over the one that would have had it.
    const asked = chosen(&machine, .text, "notes") orelse return error.NothingOpensText;
    try std.testing.expectEqualStrings("notes", asked.name);

    // Named, gone: fall back to whoever will take it rather than refuse.
    const missing = chosen(&machine, .text, "someone-elses-editor") orelse
        return error.NothingOpensText;
    try std.testing.expectEqualStrings("pad", missing.name);

    // Named, present, and not willing: the same.
    const unwilling = chosen(&machine, .text, "eimg") orelse return error.NothingOpensText;
    try std.testing.expectEqualStrings("pad", unwilling.name);

    // Nothing at all opens a family nobody declared for.
    try std.testing.expectEqual(@as(?Opener, null), chosen(&machine, .video, ""));
    // And nothing opens anything on a machine that declared nothing.
    try std.testing.expectEqual(@as(?Opener, null), chosen(&.{}, .text, "pad"));
}

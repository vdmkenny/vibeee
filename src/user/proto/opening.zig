//! Opening a file with whatever opens its sort of thing.
//!
//! What a file is comes from its bytes, which anything about to open one can
//! afford to read; which program takes that sort of thing comes from the
//! openers table and the setting over it. Both the file manager and the
//! launcher do this, and doing it twice is how two windows come to disagree
//! about what happens when you press Enter on the same file.

const kind = @import("lib").kind;
const openers = @import("lib").openers;
const paths = @import("ulib").paths;
const file = @import("ulib").file;
const settings = @import("settings.zig");
const sys = @import("sys");

/// What the file is, from its first bytes. A file that cannot be opened or
/// read reads as shapeless, which opens in nothing.
pub fn readKind(path: []const u8) kind.Reading {
    var head: [kind.ENOUGH]u8 = undefined;
    const n = file.readWhole(path, &head) orelse return .{ .kind = .data };
    return kind.fromBytes(head[0..n]);
}

/// Whoever the settings name for this family, or nobody.
pub fn preferred(family: kind.Family) []const u8 {
    const chosen = settings.load("open");
    return switch (family) {
        .picture => chosen.picture.slice(),
        .text => chosen.text.slice(),
        .audio => chosen.audio.slice(),
        .video => chosen.video.slice(),
        .archive => chosen.archive.slice(),
        .document => chosen.document.slice(),
        .font => chosen.font.slice(),
        else => "",
    };
}

/// What happened, so a caller can say so in its own words rather than being
/// handed a sentence written somewhere else.
pub const Outcome = enum {
    opened,
    /// Nothing in this build takes that sort of file.
    nobody_opens_it,
    /// Something does, and it would not start.
    would_not_start,
};

/// Open it. A program is opened by being run, which is what opening a
/// program means; anything else goes to whichever program takes its family.
pub fn start(path: []const u8) Outcome {
    const what = readKind(path);
    if (what.kind == .program) return run(path);

    const family = what.kind.family();
    const opener = openers.chosen(family, preferred(family)) orelse return .nobody_opens_it;
    if (sys.spawnDetached(opener.path, &.{ opener.name, path }) < 0) return .would_not_start;
    return .opened;
}

/// Run a program as itself, with nothing after its name: what a file manager
/// or a launcher can say about how to run something is nothing.
fn run(path: []const u8) Outcome {
    var name: [64]u8 = undefined;
    const leaf = paths.base(path);
    const n = @min(leaf.len, name.len);
    @memcpy(name[0..n], leaf[0..n]);
    if (sys.spawnDetached(path, &.{name[0..n]}) < 0) return .would_not_start;
    return .opened;
}

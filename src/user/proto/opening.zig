//! Opening a file with whatever opens its sort of thing.
//!
//! What a file is comes from its bytes, which anything about to open one can
//! afford to read, and from its name when the bytes say nothing. Which
//! program takes that sort of thing comes from what the programs on this
//! machine declared in `/etc/openers` and from the setting over it. Both the
//! file manager and the launcher do this, and doing it twice is how two
//! windows come to disagree about what happens when you press Enter on the
//! same file.

const config = @import("ulib").config;
const kind = @import("lib").kind;
const limits = @import("lib").limits;
const openers = @import("lib").openers;
const paths = @import("ulib").paths;
const file = @import("ulib").file;
const settings = @import("settings.zig");
const sys = @import("sys");

/// One program's stanza in the manifest. The field names are the keys, so
/// the file and this cannot drift.
const Declared = struct {
    name: []const u8 = "",
    binary: []const u8 = "",
    opens: []const u8 = "",
};

/// The manifest, read once. The declarations borrow this, so it stays.
var manifest: [limits.OPENERS_FILE_MAX]u8 = @splat(0);
var declared: [limits.MAX_OPENERS]openers.Opener = undefined;
var count: usize = 0;
var asked = false;

/// What the programs on this machine said they open.
///
/// Read on the first ask and kept: a file manager opens many files and the
/// answer does not change under it, and a disk read per file would be a
/// disk read for something already known.
pub fn known() []const openers.Opener {
    if (asked) return declared[0..count];
    asked = true;

    var stanzas: [limits.MAX_OPENERS]Declared = @splat(.{});
    const found = config.loadEach("/etc/openers", &stanzas, &manifest);
    for (stanzas[0..found]) |one| {
        if (one.name.len == 0 or one.binary.len == 0) continue;
        declared[count] = .{
            .name = one.name,
            .path = one.binary,
            .opens = config.flags(openers.Opens, one.opens),
        };
        count += 1;
    }
    return declared[0..count];
}

/// What the file is. One that cannot be opened or read is shapeless,
/// which opens in nothing.
pub fn readKind(path: []const u8) kind.Reading {
    var head: [kind.ENOUGH]u8 = undefined;
    const n = file.readWhole(path, &head) orelse return .{ .kind = .data };
    return kind.of(head[0..n], paths.base(path));
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
    const opener = openers.chosen(known(), family, preferred(family)) orelse return .nobody_opens_it;
    _ = sys.spawnDetached(opener.path, &.{ opener.name, path }) catch return .would_not_start;
    return .opened;
}

/// Run a program as itself, with nothing after its name: what a file manager
/// or a launcher can say about how to run something is nothing.
///
/// In the folder it lives in, because that is where a program opened rather
/// than typed keeps whatever it needs beside itself: its data, its save
/// files, the wad a game reads its maps from. Started in the folder whoever
/// opened it happened to be in, a program that reads a file next to itself
/// finds nothing and exits, which reads as the program being broken.
fn run(path: []const u8) Outcome {
    var name: [64]u8 = undefined;
    const leaf = paths.base(path);
    const n = @min(leaf.len, name.len);
    @memcpy(name[0..n], leaf[0..n]);

    const folder = paths.parent(path);
    _ = sys.spawnDetachedIn(path, &.{name[0..n]}, folder) catch return .would_not_start;
    return .opened;
}

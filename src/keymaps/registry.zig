//! Every keyboard layout the system knows about.
//!
//! Adding one is a new file in this directory plus a line in the list below.
//! Nothing else in the system needs to change: the settings schema, the switch
//! hotkey and the status-bar indicator are all built from that list.
//!
//! Order matters only in that the first entry is the default.

const std = @import("std");
const l = @import("layout.zig");

/// Every layout, each with the name it goes by in configuration.
///
/// The one list. `Name` and `all` are both built from it, so a layout cannot
/// be in the tables under one name and in the settings under another, and
/// adding one really is a file and a line.
const shipped = .{
    .{ "us_intl", @import("us_intl.zig").layout },
    .{ "be_azerty", @import("be_azerty.zig").layout },
};

/// The layouts by name, for everything that has to name one without carrying
/// the tables: a settings key, a completion, a dropdown, a syscall argument.
///
/// A tag's value is its layout's index in `all`, which is what lets a choice
/// cross the syscall boundary as a number and arrive meaning the same layout.
pub const Name = blk: {
    var tag_names: [shipped.len][:0]const u8 = undefined;
    for (shipped, 0..) |entry, i| tag_names[i] = entry[0];
    const frozen = tag_names;
    break :blk @Enum(u32, .exhaustive, &frozen, &std.simd.iota(u32, shipped.len));
};

/// The tables themselves, in the order `Name` numbers them.
pub const all = blk: {
    var built: [shipped.len]l.Compiled = undefined;
    for (shipped, 0..) |entry, i| built[i] = l.compile(entry[1]);
    const frozen = built;
    break :blk frozen;
};

/// How many there are, for a caller stepping through them.
pub const count = shipped.len;

/// The two-letter indicators, for a status bar. Taken from the layouts so the
/// bar and the table agree, and held separately so a program that only wants
/// to draw one does not carry the tables to get it.
pub const tags = blk: {
    var built: [count][]const u8 = undefined;
    for (all, 0..) |layout, i| built[i] = layout.tag;
    const frozen = built;
    break :blk frozen;
};

/// The full names, for a list somebody chooses from. Held here for the same
/// reason the tags are: naming a layout should not cost a program the tables.
pub const names = blk: {
    var built: [count][]const u8 = undefined;
    for (all, 0..) |layout, i| built[i] = layout.name;
    const frozen = built;
    break :blk frozen;
};

/// Layout selected when no configuration says otherwise.
pub const default: Name = .us_intl;

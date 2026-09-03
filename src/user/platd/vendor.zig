//! What the machine's own maker offers, and which maker this one is.
//!
//! Every laptop of this age has features the specification does not describe:
//! a panel with no `_BCM`, a radio with no node of its own, a top row that
//! reports through a device only the vendor documents. Each maker answers
//! those the same way, through one device registered under an id of theirs,
//! carrying methods named however they liked.
//!
//! So this is the shape of that answer rather than any one maker's version of
//! it. A vendor is a row: the device, the greeting its firmware expects, what
//! its notification numbers mean, and whichever of the panel and the
//! switchable parts it offers. Everything a maker actually knows lives in its
//! own file and is reachable only through the row, which is what keeps a
//! second maker from being a fifth place to edit.
//!
//! The rest of this service asks here rather than asking a maker. Nothing
//! outside these rows names one.

const std = @import("std");
const asus = @import("vendor/asus.zig");
const lib = @import("lib");
const proto = @import("proto").platform;
const uacpi = @import("uacpi.zig");

/// The panel, where a maker offers one of its own.
pub const Panel = struct {
    find: *const fn () ?*uacpi.Node,
    read: *const fn (node: *uacpi.Node) ?u32,
    write: *const fn (node: *uacpi.Node, level: u32) bool,
    /// The highest level its method takes, which is not discoverable from
    /// the namespace and so is written down per maker.
    levels: u32,
};

/// The switchable parts, where a maker switches any.
pub const Parts = struct {
    find: *const fn (which: proto.Feature, where: ?lib.pci.Location) ?*uacpi.Node,
    read: *const fn (which: proto.Feature, node: *uacpi.Node) ?bool,
    write: *const fn (which: proto.Feature, node: *uacpi.Node, on: bool) bool,
};

pub const Vendor = struct {
    /// What to call it in the log. Which maker claimed the machine is the
    /// first thing worth knowing when one of its features does nothing.
    name: []const u8,
    /// Whether this machine is this maker's.
    ///
    /// The maker's own test, because what counts as recognition is its
    /// knowledge and not this file's. The id its firmware registers is the
    /// strong answer; a unit that registers none and offers a method no
    /// other maker has is the weaker one, and which methods those are is
    /// again the maker's to say.
    claims: *const fn () bool,
    /// Its device, for recognising a notification's sender and for the
    /// greeting. The function may answer null on a unit of this make whose
    /// firmware registers no device, which is why it is not the test above,
    /// and the field itself is absent for a maker with no such device at all.
    node: ?*const fn () ?*uacpi.Node = null,
    /// Say hello, where the firmware expects one before anything else
    /// touches the device. Absent for the makers that expect none.
    greet: ?*const fn () void = null,
    /// What one of its notification numbers means. Not a specification and
    /// not derivable: what a machine sends is only knowable by reading it
    /// off a running one. Absent for a maker whose machines report nothing
    /// of their own.
    press: ?*const fn (value: u64) proto.Hotkey = null,
    panel: ?Panel = null,
    parts: ?Parts = null,

    /// The row for one part in a maker's own table of what it switches, or null
    /// for a part that maker does not switch.
    ///
    /// Generic over the row, because a maker's table carries whatever else that
    /// maker needs beside the part it names. A maker lists what it has and
    /// nothing else: no maker has every part, and a part added to the protocol's
    /// list needs no line from a maker that does not have one.
    pub fn switching(comptime Row: type, table: []const Row, which: proto.Feature) ?Row {
        for (table) |row| {
            if (row.part == which) return row;
        }
        return null;
    }

    /// Check a maker's table at build time.
    ///
    /// Both mistakes it refuses would otherwise appear as a part that
    /// quietly does nothing, on a machine whoever wrote the row may not
    /// have in front of them. A part listed twice leaves the second row
    /// unreachable, with which of the two is live decided by the order they
    /// happen to sit in rather than by anybody. A method spelled as no
    /// firmware could name it never resolves, and a lookup that finds
    /// nothing is indistinguishable from a machine that does not have the
    /// part at all.
    pub fn checkTable(comptime Row: type, comptime table: []const Row) void {
        for (table, 0..) |row, i| {
            for (table[i + 1 ..]) |later| {
                if (row.part == later.part) {
                    @compileError("a maker lists " ++ @tagName(row.part) ++ " twice");
                }
            }
            inline for (std.meta.fields(Row)) |field| {
                if (field.type == [*:0]const u8) checkName(@field(row, field.name));
            }
        }
    }

    /// Refuse a string no firmware could have named a thing.
    ///
    /// A name in the firmware's namespace is four bytes, padded with
    /// underscores, from a fixed alphabet that has no lower case in it and
    /// cannot begin with a digit. Every one of those is a typo this catches
    /// where the machine would otherwise answer by doing nothing.
    pub fn checkName(comptime spelling: [*:0]const u8) void {
        const text = std.mem.span(spelling);
        if (text.len == 0 or text.len > 4) {
            @compileError("`" ++ text ++ "` is not a name of one to four characters");
        }
        for (text, 0..) |c, i| {
            const leads = (c >= 'A' and c <= 'Z') or c == '_';
            const digit = c >= '0' and c <= '9';
            if (!leads and !(i > 0 and digit)) {
                @compileError("`" ++ text ++ "` is not spelled as a firmware name");
            }
        }
    }
};

/// Every maker this build knows.
///
/// Adding one is a file in `vendor/` and a row here, and nothing else: the
/// rest of the service asks this file rather than any maker, so a machine
/// this build has never met becomes a supported one without a line changing
/// outside those two places.
const vendors = [_]Vendor{asus.vendor};

comptime {
    for (vendors, 0..) |maker, i| {
        // A row that offers none of these is one nothing would ever call,
        // which is a maker half written down rather than a maker with
        // nothing to offer.
        if (maker.panel == null and maker.parts == null and
            maker.press == null and maker.greet == null)
        {
            @compileError("maker `" ++ maker.name ++ "` offers nothing");
        }
        for (vendors[i + 1 ..]) |later| {
            if (std.mem.eql(u8, maker.name, later.name)) {
                @compileError("two makers are called `" ++ maker.name ++ "`");
            }
        }
    }
}

/// Whose machine this is, found once. The namespace does not change under a
/// running machine.
///
/// Asked of the firmware rather than of the board's own description of
/// itself. The two answer different questions: what DMI names is who
/// assembled the machine, and what is wanted here is whether the control
/// interface exists to be driven. A unit badged by one maker and carrying
/// another's board answers correctly this way and wrongly the other, and a
/// unit whose firmware ships no vendor device at all is one where the name
/// on the lid is no help. Which machines are broken in which ways is a
/// separate question, and `src/quirks` answers that one from DMI.
pub fn current() ?*const Vendor {
    if (looked) return found;
    looked = true;
    for (&vendors) |*maker| {
        if (maker.claims()) {
            found = maker;
            break;
        }
    }
    return found;
}

var found: ?*const Vendor = null;
var looked = false;

/// The vendor device, for a caller that has to recognise it as a sender.
pub fn node() ?*uacpi.Node {
    const find = (current() orelse return null).node orelse return null;
    return find();
}

pub fn name() []const u8 {
    return (current() orelse return "").name;
}

/// Say hello to whichever maker this is, once, before anything else asks its
/// device for something. Nothing to say on a machine of no maker this build
/// knows, which is most of them.
pub fn greet() void {
    const hello = (current() orelse return).greet orelse return;
    hello();
}

/// What a number from the vendor device means, or `unknown` carrying its own
/// number where nothing here can say. That is how the next machine's
/// numbering gets written down: it arrives named as unknown and says what it
/// actually sent.
pub fn press(value: u64) proto.Hotkey {
    const maker = current() orelse return .unknown;
    const meaning = maker.press orelse return .unknown;
    return meaning(value);
}

pub fn panel() ?Panel {
    return (current() orelse return null).panel;
}

pub fn parts() ?Parts {
    return (current() orelse return null).parts;
}

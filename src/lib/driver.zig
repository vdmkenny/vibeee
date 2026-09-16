//! What the kernel and userspace both have to say about drivers.
//!
//! The boot probe prints a table and `devices` prints the same table later,
//! from the same data. They should agree about what the words mean and what
//! colour each one is, which they cannot do from two separate lists.

const style = @import("style.zig");

/// How sure a driver is that a device is its.
///
/// What decides binding, rather than the order drivers are listed in: an exact
/// vendor and device match beats a class-level guess wherever both apply.
pub const Confidence = enum(u8) {
    /// Not my device.
    no = 0,
    /// Generic class-level match: works, but dumbly.
    weak = 1,
    /// Recognised family; most functionality available.
    strong = 2,
    /// Exact device match, all quirks known.
    exact = 3,

    /// How sure it is, said in colour.
    ///
    /// A weak match is the one worth noticing: it means a driver is running a
    /// device it only half recognises, which is the usual answer when hardware
    /// does less than it should.
    pub fn role(self: Confidence) style.Role {
        return switch (self) {
            .exact => .good,
            .strong => .key,
            .weak => .warn,
            .no => .dim,
        };
    }
};

/// What became of a device once the drivers had their say.
///
/// One vocabulary, so the boot table and the `devices` tool cannot describe
/// the same binding differently. A driver that merely matched is not driving
/// anything: the entry names the device without being able to run it.
pub const State = enum {
    /// A driver took it and it is running.
    driven,
    /// A driver matched but never attached, having none to attach with.
    matched,
    /// A driver tried and failed.
    failed,
    /// Nothing claimed it.
    unclaimed,

    /// The one-character shorthand the boot table puts beside a driver.
    pub fn mark(self: State) []const u8 {
        return switch (self) {
            .driven => " ",
            .matched => "*",
            .failed => "!",
            .unclaimed => " ",
        };
    }

    /// What became of it, said in colour.
    ///
    /// `matched` is the interesting one and is coloured as a warning: a driver
    /// was written for the device and something stopped it running, which is
    /// not the same as nobody having written one.
    pub fn role(self: State) style.Role {
        return switch (self) {
            .driven => .good,
            .matched => .warn,
            .failed => .bad,
            .unclaimed => .dim,
        };
    }
};

// ---------------------------------------------------------------------------
// What each driver answers for
// ---------------------------------------------------------------------------

/// A device a driver serves.
///
/// Two spellings, because a driver knows its devices in one of two ways. A
/// part is a maker's own silicon and is named by its numbers. A family is a
/// register interface a specification fixed rather than a maker did, so one
/// driver covers everyone's, and naming the parts would be naming a list
/// nobody can finish.
pub const Match = union(enum) {
    part: Part,
    family: Family,
    /// A device with no bus presence at all: the keyboard controller, the
    /// timer, the clock. Named rather than matched.
    platform: []const u8,

    pub const Part = struct { vendor: u16, device: u16 };
    pub const Family = struct { class: u8, subclass: u8, interface: ?u8 = null };

    /// Whether this covers a device on the bus, and how sure that is. A part
    /// beats a family wherever both apply, which is what lets a driver
    /// written for one machine's silicon win over the one written for
    /// everybody's.
    pub fn covers(self: Match, dev: Signature) Confidence {
        return switch (self) {
            .part => |p| if (p.vendor == dev.vendor and p.device == dev.device) .exact else .no,
            .family => |f| if (f.class == dev.class and f.subclass == dev.subclass and
                (f.interface == null or f.interface.? == dev.interface)) .strong else .no,
            .platform => .no,
        };
    }

    /// How this is written in a driver's manifest, which is the same grammar
    /// `devspec` reads.
    pub fn write(self: Match, gpa: std.mem.Allocator, w: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
        switch (self) {
            .part => |p| try w.print(gpa, "pci:{x:0>4}:{x:0>4}", .{ p.vendor, p.device }),
            .family => |f| {
                try w.print(gpa, "pci-class:{x:0>2}:{x:0>2}", .{ f.class, f.subclass });
                if (f.interface) |i| try w.print(gpa, ":{x:0>2}", .{i});
            },
            .platform => |name| try w.print(gpa, "platform:{s}", .{name}),
        }
    }
};

/// How a driver's whole list is written in its manifest. Parts of one
/// vendor that stand together share a spec, `pci:8086:1229|1209`, which is
/// what keeps a driver answering for a family of forty parts to a line the
/// device manager has room to keep.
pub fn writeAll(matches: []const Match, gpa: std.mem.Allocator, w: *std.ArrayList(u8)) std.mem.Allocator.Error!void {
    for (matches, 0..) |match, i| {
        if (i > 0) {
            if (sameVendor(matches[i - 1], match)) {
                try w.print(gpa, "|{x:0>4}", .{match.part.device});
                continue;
            }
            try w.appendSlice(gpa, ", ");
        }
        try match.write(gpa, w);
    }
}

fn sameVendor(previous: Match, next: Match) bool {
    if (previous != .part or next != .part) return false;
    return previous.part.vendor == next.part.vendor;
}

/// What a bus says a device is, which is all a match ever looks at.
pub const Signature = struct {
    vendor: u16,
    device: u16,
    class: u8,
    subclass: u8,
    interface: u8,
};

/// How sure the best of `matches` is about `dev`.
pub fn bestOf(matches: []const Match, dev: Signature) Confidence {
    var best: Confidence = .no;
    for (matches) |one| {
        const fit = one.covers(dev);
        if (@intFromEnum(fit) > @intFromEnum(best)) best = fit;
    }
    return best;
}

/// A driver, and the devices it answers for.
///
/// One declaration, because two things act on it and a disagreement between
/// them is a listing that says nobody drives what something is driving, or
/// the reverse: the boot probe, which decides what the device table says, and
/// the manifest that binds a driver living outside the kernel.
pub const Answers = struct {
    name: []const u8,
    /// The service a driver outside the kernel registers under, or nothing
    /// for one the kernel carries itself and writes no manifest for.
    service: ?[]const u8 = null,
    /// One line for the manifest, saying what the driver is.
    says: []const u8 = "",
    matches: []const Match,
};

/// Every driver whose devices both the kernel and a manifest have to agree
/// about. The kernel's own table takes its matches from here by name, and the
/// manifests are written from here, so neither can name a device the other
/// does not.
pub const answers = [_]Answers{
    .{
        .name = "ehci",
        .service = "usb",
        .says = "The high-speed USB host controller, by class rather than by part\nnumber: every EHCI controller answers the same register interface.",
        .matches = &.{.{ .family = .{ .class = 0x0C, .subclass = 0x03, .interface = 0x20 } }},
    },
    .{
        .name = "uhci",
        .service = "usb",
        .says = "The companion controller, by class: full and low speed devices, which\nis what a keyboard or a mouse on a root port turns out to be.",
        .matches = &.{.{ .family = .{ .class = 0x0C, .subclass = 0x03, .interface = 0x00 } }},
    },
    .{
        .name = "ohci",
        .service = "usb",
        .says = "The open host controller, by class: full and low speed USB on AMD,\nSiS, ALi, NVIDIA and OPTi chipsets and on cards.",
        .matches = &.{.{ .family = .{ .class = 0x0C, .subclass = 0x03, .interface = 0x10 } }},
    },
    .{
        .name = "hda",
        .service = "audio",
        .says = "High Definition Audio, by class rather than by part number: the\nregister interface is the specification's and not a maker's, so one\ndriver covers Intel, ATI, nVidia and VIA alike. The part named beside\nit is the one verified on the target, with its ALC662 codec.",
        .matches = &.{
            .{ .part = .{ .vendor = 0x8086, .device = 0x2668 } },
            .{ .family = .{ .class = 0x04, .subclass = 0x03 } },
        },
    },
    .{
        .name = "ac97",
        .service = "audio",
        .says = "AC'97 on the Intel controller line, by part number and not by class:\nsubclass 01 is every audio device that is not HDA, and most of them\nanswer nothing like this. So the controller of each chipset generation\nthat carried AC'97 is named, the first of them being what an emulator\ngives a machine.",
        .matches = &.{
            .{ .part = .{ .vendor = 0x8086, .device = 0x2415 } }, // ICH
            .{ .part = .{ .vendor = 0x8086, .device = 0x2425 } }, // ICH0
            .{ .part = .{ .vendor = 0x8086, .device = 0x2445 } }, // ICH2
            .{ .part = .{ .vendor = 0x8086, .device = 0x2485 } }, // ICH3
            .{ .part = .{ .vendor = 0x8086, .device = 0x24C5 } }, // ICH4
            .{ .part = .{ .vendor = 0x8086, .device = 0x24D5 } }, // ICH5
            .{ .part = .{ .vendor = 0x8086, .device = 0x266E } }, // ICH6
            .{ .part = .{ .vendor = 0x8086, .device = 0x27DE } }, // ICH7
            .{ .part = .{ .vendor = 0x8086, .device = 0x7195 } }, // 440MX
        },
    },
    .{
        .name = "es1370",
        .service = "audio",
        .says = "The Ensoniq AudioPCI ES1370 and its AK4531 codec: the sound card of\nmany machines of the late nineties, and the emulator's `ES1370`.",
        .matches = &.{.{ .part = .{ .vendor = 0x1274, .device = 0x5000 } }},
    },
    .{
        .name = "atl2",
        .service = "net",
        .says = "The Attansic L2 fast ethernet, which is the wired part of the Eee PC\n701 and of a good many machines beside it.",
        .matches = &.{.{ .part = .{ .vendor = 0x1969, .device = 0x2048 } }},
    },
    .{
        .name = "atl1e",
        .service = "net",
        .says = "The Attansic L1E, sold as the Atheros AR8121, AR8113 and AR8114:\nthe wired part of the Eee PC 1000 and of the 901 units that carry\none. The three answer the same number and differ only in how fast\ntheir PHY negotiates.",
        .matches = &.{.{ .part = .{ .vendor = 0x1969, .device = 0x1026 } }},
    },
    .{
        .name = "ar5212",
        .service = "net",
        .says = "The Atheros AR5212 family: the AR2425 in the Eee PC 701, and the\nAR2417.",
        .matches = &.{
            .{ .part = .{ .vendor = 0x168C, .device = 0x001C } },
            .{ .part = .{ .vendor = 0x168C, .device = 0x001D } },
        },
    },
    .{
        .name = "e1000",
        .service = "net",
        .says = "The Intel 8254x gigabit line: the emulator's wired adapter, and the\ncard a good many machines of the era carried. One register interface\nacross the parts named.",
        .matches = &.{
            .{ .part = .{ .vendor = 0x8086, .device = 0x1004 } }, // 82543GC
            .{ .part = .{ .vendor = 0x8086, .device = 0x1008 } }, // 82544GC
            .{ .part = .{ .vendor = 0x8086, .device = 0x100E } }, // 82540EM
            .{ .part = .{ .vendor = 0x8086, .device = 0x100F } }, // 82545EM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1010 } }, // 82546EB
            .{ .part = .{ .vendor = 0x8086, .device = 0x1026 } }, // 82545GM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1027 } }, // 82545GM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1028 } }, // 82545GM
        },
    },
    .{
        .name = "e100",
        .service = "net",
        .says = "Intel PRO/100: the 82557, 82558, 82559, 82550 and 82551, and the\nLAN controller inside ICH2 to ICH7 and NM10. One register interface.",
        .matches = &.{
            .{ .part = .{ .vendor = 0x8086, .device = 0x1029 } }, // 82559
            .{ .part = .{ .vendor = 0x8086, .device = 0x1030 } }, // 82559 InBusiness
            .{ .part = .{ .vendor = 0x8086, .device = 0x1031 } }, // ICH3 VE
            .{ .part = .{ .vendor = 0x8086, .device = 0x1032 } }, // ICH3 VE
            .{ .part = .{ .vendor = 0x8086, .device = 0x1033 } }, // ICH3 VM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1034 } }, // ICH3 VM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1038 } }, // ICH3 VM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1039 } }, // ICH4 VE
            .{ .part = .{ .vendor = 0x8086, .device = 0x103A } }, // ICH4 VE
            .{ .part = .{ .vendor = 0x8086, .device = 0x103B } }, // ICH4 VM
            .{ .part = .{ .vendor = 0x8086, .device = 0x103C } }, // ICH4 VM
            .{ .part = .{ .vendor = 0x8086, .device = 0x103D } }, // ICH4 VE
            .{ .part = .{ .vendor = 0x8086, .device = 0x103E } }, // ICH4 VM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1050 } }, // ICH5 82562EZ
            .{ .part = .{ .vendor = 0x8086, .device = 0x1051 } }, // ICH5
            .{ .part = .{ .vendor = 0x8086, .device = 0x1052 } }, // ICH5 VM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1053 } }, // ICH5 VM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1054 } }, // ICH5 VE
            .{ .part = .{ .vendor = 0x8086, .device = 0x1055 } }, // ICH5 VM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1056 } }, // ICH5 VE
            .{ .part = .{ .vendor = 0x8086, .device = 0x1057 } }, // ICH5
            .{ .part = .{ .vendor = 0x8086, .device = 0x1059 } }, // 82551QM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1064 } }, // ICH6 VE
            .{ .part = .{ .vendor = 0x8086, .device = 0x1065 } }, // ICH6 VE
            .{ .part = .{ .vendor = 0x8086, .device = 0x1066 } }, // ICH6 VM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1067 } }, // ICH6 VM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1068 } }, // ICH6 VE
            .{ .part = .{ .vendor = 0x8086, .device = 0x1069 } }, // ICH6 VM
            .{ .part = .{ .vendor = 0x8086, .device = 0x106A } }, // ICH6 82562G
            .{ .part = .{ .vendor = 0x8086, .device = 0x106B } }, // ICH6 82562G
            .{ .part = .{ .vendor = 0x8086, .device = 0x1091 } }, // ICH7 VE
            .{ .part = .{ .vendor = 0x8086, .device = 0x1092 } }, // ICH7 VE
            .{ .part = .{ .vendor = 0x8086, .device = 0x1093 } }, // ICH7 VM
            .{ .part = .{ .vendor = 0x8086, .device = 0x1094 } }, // ICH7 946GZ
            .{ .part = .{ .vendor = 0x8086, .device = 0x1095 } }, // ICH7 VE
            .{ .part = .{ .vendor = 0x8086, .device = 0x10FE } }, // 82552
            .{ .part = .{ .vendor = 0x8086, .device = 0x1209 } }, // 8255xER, 82551IT
            .{ .part = .{ .vendor = 0x8086, .device = 0x1229 } }, // 82557, 82558, 82559, 82550, 82551
            .{ .part = .{ .vendor = 0x8086, .device = 0x2449 } }, // ICH2
            .{ .part = .{ .vendor = 0x8086, .device = 0x2459 } }, // C-ICH
            .{ .part = .{ .vendor = 0x8086, .device = 0x245D } }, // C-ICH
            .{ .part = .{ .vendor = 0x8086, .device = 0x27DC } }, // ICH7, NM10
        },
    },
    .{
        .name = "rtl8139",
        .service = "net",
        .says = "The RealTek 8139 line: the emulator's other adapter, and the fast\nethernet of a great many machines of the era. Both parts answer one\nregister interface.",
        .matches = &.{
            .{ .part = .{ .vendor = 0x10EC, .device = 0x8139 } },
            .{ .part = .{ .vendor = 0x10EC, .device = 0x8138 } },
        },
    },
};

/// What `name` answers for, refused at compile time where nothing of that
/// name is declared: a table entry naming a driver this does not know would
/// otherwise bind nothing and say nothing about why.
pub fn matchesOf(comptime name: []const u8) []const Match {
    return comptime for (answers) |one| {
        if (std.mem.eql(u8, one.name, name)) break one.matches;
    } else @compileError("no driver named '" ++ name ++ "' says what it answers for");
}

const std = @import("std");
const testing = std.testing;

test "a part beats a family, and a family covers what shares its interface" {
    const hda = matchesOf("hda");
    const target = Signature{ .vendor = 0x8086, .device = 0x2668, .class = 0x04, .subclass = 0x03, .interface = 0 };
    const other = Signature{ .vendor = 0x1002, .device = 0x4383, .class = 0x04, .subclass = 0x03, .interface = 0 };
    const sound_card = Signature{ .vendor = 0x1274, .device = 0x1371, .class = 0x04, .subclass = 0x01, .interface = 0 };

    try testing.expectEqual(Confidence.exact, bestOf(hda, target));
    try testing.expectEqual(Confidence.strong, bestOf(hda, other));
    try testing.expectEqual(Confidence.no, bestOf(hda, sound_card));
}

test "an interface tells the USB controller generations apart" {
    const ehci = matchesOf("ehci");
    const uhci = matchesOf("uhci");
    const ohci = matchesOf("ohci");
    const high = Signature{ .vendor = 0x8086, .device = 0x265C, .class = 0x0C, .subclass = 0x03, .interface = 0x20 };
    const full = Signature{ .vendor = 0x8086, .device = 0x2658, .class = 0x0C, .subclass = 0x03, .interface = 0x00 };
    const open = Signature{ .vendor = 0x1002, .device = 0x4397, .class = 0x0C, .subclass = 0x03, .interface = 0x10 };

    try testing.expectEqual(Confidence.strong, bestOf(ehci, high));
    try testing.expectEqual(Confidence.no, bestOf(ehci, full));
    try testing.expectEqual(Confidence.strong, bestOf(uhci, full));
    try testing.expectEqual(Confidence.no, bestOf(uhci, high));
    try testing.expectEqual(Confidence.no, bestOf(ehci, open));
    try testing.expectEqual(Confidence.no, bestOf(uhci, open));
    try testing.expectEqual(Confidence.strong, bestOf(ohci, open));
    try testing.expectEqual(Confidence.no, bestOf(ohci, full));
    try testing.expectEqual(Confidence.no, bestOf(ohci, high));
}

test "a manifest line names exactly the devices its driver answers for" {
    const pci = @import("pci.zig");
    const gpa = testing.allocator;

    for (answers) |one| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        try writeAll(one.matches, gpa, &line);

        for (one.matches) |match| {
            // Each device named, and the numbers either side of it.
            for ([_]u16{ 0xFFFF, 0, 1 }) |step| {
                const dev: Signature = switch (match) {
                    .part => |p| .{ .vendor = p.vendor, .device = p.device +% step, .class = 0xFF, .subclass = 0xFF, .interface = 0xFF },
                    .family => |f| .{ .vendor = 0xFFFF, .device = 0xFFFF, .class = f.class, .subclass = f.subclass +% @as(u8, @truncate(step)), .interface = f.interface orelse 0x5A },
                    .platform => continue,
                };
                const bus = pci.Signature{ .vendor = dev.vendor, .device = dev.device, .class = dev.class, .subclass = dev.subclass, .interface = dev.interface };
                const said = bus.matchesPart(line.items) or bus.matchesClass(line.items);
                try testing.expectEqual(bestOf(one.matches, dev) != .no, said);
            }
        }
    }
}

const fuzzing = @import("fuzzing.zig");
const Choices = fuzzing.Choices;

/// A driver's list, written as its manifest and read back the way the device
/// manager reads it, names the devices the kernel's table would bind: no
/// more and no fewer. And a line that is not a manifest's at all is read
/// without harm.
fn writeOneManifest(from: Choices) anyerror!void {
    const pci = @import("pci.zig");
    const vendors = [_]u16{ 0x8086, 0x10EC, 0x1274 };

    var matches: [8]Match = undefined;
    const count = from.upTo(matches.len);
    for (matches[0..count]) |*match| {
        match.* = if (from.odds(4)) .{ .family = .{
            .class = @intCast(from.below(3)),
            .subclass = @intCast(from.below(3)),
            .interface = if (from.odds(2)) null else @intCast(from.below(3)),
        } } else .{ .part = .{
            .vendor = vendors[from.below(vendors.len)],
            .device = @intCast(from.below(8)),
        } };
    }

    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(testing.allocator);
    try writeAll(matches[0..count], testing.allocator, &line);

    for (0..16) |_| {
        const dev = Signature{
            .vendor = vendors[from.below(vendors.len)],
            .device = @intCast(from.below(8)),
            .class = @intCast(from.below(3)),
            .subclass = @intCast(from.below(3)),
            .interface = @intCast(from.below(3)),
        };
        const bus = pci.Signature{ .vendor = dev.vendor, .device = dev.device, .class = dev.class, .subclass = dev.subclass, .interface = dev.interface };
        const read = if (bus.matchesPart(line.items)) Confidence.exact else if (bus.matchesClass(line.items)) Confidence.strong else Confidence.no;
        try testing.expectEqual(bestOf(matches[0..count], dev), read);
    }

    const alphabet = "pci-class:0123456789abcdef|, \x00";
    var noise: [48]u8 = undefined;
    for (&noise) |*byte| byte.* = alphabet[from.below(alphabet.len)];
    const bus = pci.Signature{ .vendor = from.int(u16), .device = from.int(u16) };
    _ = bus.matchesPart(noise[0..from.below(noise.len + 1)]);
    _ = bus.matchesClass(noise[0..from.below(noise.len + 1)]);
}

test "fuzz: a manifest line is read back as exactly the devices it was written for" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            return writeOneManifest(.{ .fuzzer = smith });
        }
    };
    try std.testing.fuzz({}, Target.one, .{});
}

test "manifest lines written from random lists" {
    try fuzzing.seeded(writeOneManifest, 0x0D21_7E25, 2000);
}

test "parts of one vendor share a spec, and anything else starts a new one" {
    const gpa = testing.allocator;
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(gpa);
    try writeAll(&.{
        .{ .part = .{ .vendor = 0x8086, .device = 0x1229 } },
        .{ .part = .{ .vendor = 0x8086, .device = 0x1209 } },
        .{ .family = .{ .class = 0x02, .subclass = 0x00 } },
        .{ .part = .{ .vendor = 0x10EC, .device = 0x8139 } },
        .{ .part = .{ .vendor = 0x8086, .device = 0x2449 } },
    }, gpa, &line);
    try testing.expectEqualStrings("pci:8086:1229|1209, pci-class:02:00, pci:10ec:8139, pci:8086:2449", line.items);
}

test "a match writes the line a manifest is read from" {
    const gpa = testing.allocator;
    const said = struct {
        fn of(allocator: std.mem.Allocator, match: Match) ![]u8 {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try match.write(allocator, &out);
            return out.toOwnedSlice(allocator);
        }
    }.of;

    const part = try said(gpa, .{ .part = .{ .vendor = 0x8086, .device = 0x100e } });
    defer gpa.free(part);
    try testing.expectEqualStrings("pci:8086:100e", part);

    const with_interface = try said(gpa, .{ .family = .{ .class = 0x0C, .subclass = 0x03, .interface = 0x20 } });
    defer gpa.free(with_interface);
    try testing.expectEqualStrings("pci-class:0c:03:20", with_interface);

    const without = try said(gpa, .{ .family = .{ .class = 0x04, .subclass = 0x03 } });
    defer gpa.free(without);
    try testing.expectEqualStrings("pci-class:04:03", without);
}

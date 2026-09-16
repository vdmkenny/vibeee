//! `.config` files, in the Linux kernel's format: `CONFIG_NAME=value` lines,
//! `# CONFIG_NAME is not set` for an option that is off, a `CONFIG_NAME_VALUE`
//! line per value of a choice, and comments naming the menus.

const std = @import("std");
const lib = @import("lib");
const options = @import("options.zig");

const Config = options.Config;
const Option = options.Option;
const Value = options.Value;

const PREFIX = "CONFIG_";
const NOT_SET = " is not set";

/// A symbol a `.config` line names: an option, or one value of a choice.
pub const Symbol = struct {
    name: []const u8,
    option: Option,
    /// The value's index, for a choice's symbol.
    choice: ?usize = null,
};

fn upper(comptime s: []const u8) []const u8 {
    return comptime capitals: {
        @setEvalBranchQuota(20_000);
        var out: [s.len]u8 = undefined;
        for (s, &out) |c, *u| u.* = std.ascii.toUpper(c);
        const frozen = out;
        break :capitals &frozen;
    };
}

/// The option's own symbol, `CONFIG_` and its name in capitals.
pub fn symbol(option: Option) []const u8 {
    return switch (option) {
        inline else => |which| comptime PREFIX ++ upper(@tagName(which)),
    };
}

/// Every symbol a `.config` may name.
pub const symbols: []const Symbol = blk: {
    @setEvalBranchQuota(20_000);
    var all: []const Symbol = &.{};
    for (std.enums.values(Option)) |option| {
        if (options.kindOf(option) != .choice) {
            all = all ++ .{Symbol{ .name = symbol(option), .option = option }};
            continue;
        }
        for (options.choices(option), 0..) |one, index| {
            all = all ++ .{Symbol{ .name = symbol(option) ++ "_" ++ upper(one.tag), .option = option, .choice = index }};
        }
    }
    break :blk all;
};

/// The symbol for a choice's value.
pub fn choiceSymbol(option: Option, index: usize) []const u8 {
    for (symbols) |one| {
        if (one.option == option and one.choice == index) return one.name;
    }
    unreachable;
}

fn find(name: []const u8) ?Symbol {
    for (symbols) |one| {
        if (std.mem.eql(u8, one.name, name)) return one;
    }
    return null;
}

/// What one line says.
pub const Line = union(enum) {
    /// Blank, a comment, or a choice's value that is not the chosen one.
    nothing,
    set: struct { option: Option, value: Value },
    /// A symbol this build does not have.
    unknown: []const u8,
    /// Not a line of this format, or a value its option does not take.
    malformed,
};

/// Read one line. A text value is unescaped into `room`.
pub fn parseLine(raw: []const u8, room: *[options.CMDLINE_MAX]u8) Line {
    const line = std.mem.trim(u8, raw, " \t\r");
    if (line.len == 0) return .nothing;

    if (line[0] == '#') {
        const unset = std.mem.trimStart(u8, line[1..], " ");
        if (!std.mem.startsWith(u8, unset, PREFIX) or !std.mem.endsWith(u8, unset, NOT_SET)) return .nothing;
        const name = unset[0 .. unset.len - NOT_SET.len];
        const found = find(name) orelse return .{ .unknown = name };
        if (found.choice != null) return .nothing;
        if (options.kindOf(found.option) != .flag) return .malformed;
        return .{ .set = .{ .option = found.option, .value = .{ .flag = false } } };
    }

    if (!std.mem.startsWith(u8, line, PREFIX)) return .malformed;
    const equals = std.mem.indexOfScalar(u8, line, '=') orelse return .malformed;
    const name = line[0..equals];
    const text = line[equals + 1 ..];
    const found = find(name) orelse return .{ .unknown = name };

    if (found.choice) |index| {
        if (std.mem.eql(u8, text, "y")) return .{ .set = .{ .option = found.option, .value = .{ .choice = index } } };
        return if (std.mem.eql(u8, text, "n")) .nothing else .malformed;
    }
    const value: Value = switch (options.kindOf(found.option)) {
        .flag => .{ .flag = if (std.mem.eql(u8, text, "y")) true else if (std.mem.eql(u8, text, "n")) false else return .malformed },
        .number => .{ .number = std.fmt.parseInt(u32, text, 10) catch return .malformed },
        .text => .{ .text = unquote(text, room) orelse return .malformed },
        .choice => unreachable,
    };
    return .{ .set = .{ .option = found.option, .value = value } };
}

/// A quoted value without its quotes, `\"` and `\\` unescaped.
fn unquote(quoted: []const u8, room: []u8) ?[]const u8 {
    if (quoted.len < 2 or quoted[0] != '"' or quoted[quoted.len - 1] != '"') return null;
    var len: usize = 0;
    var escaped = false;
    for (quoted[1 .. quoted.len - 1]) |c| {
        if (!escaped and c == '\\') {
            escaped = true;
            continue;
        }
        if (!escaped and c == '"') return null;
        escaped = false;
        if (len == room.len) return null;
        room[len] = c;
        len += 1;
    }
    return if (escaped) null else room[0..len];
}

/// A line `read` could not use.
pub const Problem = struct {
    line: usize,
    what: union(enum) {
        unknown: []const u8,
        malformed,
        /// A value its option did not take.
        refused: Option,
    },
};

pub const Problems = lib.Bounded(Problem, 16);

/// A configuration from `.config` text: defaults, then each line in order.
/// Lines that cannot be used are passed over and listed in `problems`, as far
/// as it holds.
pub fn read(text: []const u8, problems: *Problems) Config {
    var config: Config = .{};
    var room: [options.CMDLINE_MAX]u8 = undefined;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        switch (parseLine(line, &room)) {
            .nothing => {},
            .set => |set| if (!options.set(&config, set.option, set.value)) {
                problems.append(.{ .line = number, .what = .{ .refused = set.option } }) catch {};
            },
            .unknown => |name| problems.append(.{ .line = number, .what = .{ .unknown = name } }) catch {},
            .malformed => problems.append(.{ .line = number, .what = .malformed }) catch {},
        }
    }
    return config;
}

pub const Style = enum {
    /// Every offered option, with comments naming the menus.
    full,
    /// Only what differs from the defaults: `make savedefconfig`.
    minimal,
};

/// Write `config` as `.config` text. Options that are not offered are left out.
pub fn write(config: *const Config, style: Style, out: *std.Io.Writer) std.Io.Writer.Error!void {
    if (style == .full) try out.writeAll("#\n# vibeee image configuration, written by make menuconfig\n#\n");
    try writeMenu(config, &options.root, style, out);
}

fn writeMenu(config: *const Config, menu: *const options.Menu, style: Style, out: *std.Io.Writer) std.Io.Writer.Error!void {
    for (menu.entries) |*entry| switch (entry.*) {
        .option => |nested| {
            if (!options.offered(config, nested.option)) continue;
            try writeOption(config, nested.option, style, out);
            try writeMenu(config, &.{ .title = "", .entries = nested.under }, style, out);
        },
        .menu => |*sub| {
            if (sub.toggle) |toggle| {
                if (!options.offered(config, toggle)) continue;
                try writeOption(config, toggle, style, out);
                if (!options.get(config, toggle).flag) continue;
            }
            if (style == .full) try out.print("\n#\n# {s}\n#\n", .{sub.title});
            try writeMenu(config, sub, style, out);
            if (style == .full) try out.print("# end of {s}\n", .{sub.title});
        },
    };
}

fn writeOption(config: *const Config, option: Option, style: Style, out: *std.Io.Writer) std.Io.Writer.Error!void {
    const value = options.get(config, option);
    if (style == .minimal and value.eql(options.get(&.{}, option))) return;
    switch (value) {
        .flag => |on| if (on)
            try out.print("{s}=y\n", .{symbol(option)})
        else
            try out.print("# {s}" ++ NOT_SET ++ "\n", .{symbol(option)}),
        .choice => |chosen| for (options.choices(option), 0..) |_, index| {
            if (index == chosen) {
                try out.print("{s}=y\n", .{choiceSymbol(option, index)});
            } else if (style == .full) {
                try out.print("# {s}" ++ NOT_SET ++ "\n", .{choiceSymbol(option, index)});
            }
        },
        .number => |n| try out.print("{s}={d}\n", .{ symbol(option), n }),
        .text => |bytes| {
            try out.print("{s}=\"", .{symbol(option)});
            for (bytes) |c| {
                if (c == '"' or c == '\\') try out.writeByte('\\');
                try out.writeByte(c);
            }
            try out.writeAll("\"\n");
        },
    }
}

const testing = std.testing;

test "symbols are the option's name in capitals, and a choice has one per value" {
    try testing.expectEqualStrings("CONFIG_NETD", symbol(.netd));
    try testing.expectEqualStrings("CONFIG_HOME_MB", symbol(.home_mb));
    try testing.expectEqualStrings("CONFIG_CPU_PENTIUM_M", choiceSymbol(.cpu, 2));
    try testing.expectEqual(Symbol{ .name = "CONFIG_CPU_VIA_C7", .option = .cpu, .choice = @intFromEnum(options.Processor.via_c7) }, find("CONFIG_CPU_VIA_C7").?);
}

test "each kind of line reads as what it says" {
    var room: [options.CMDLINE_MAX]u8 = undefined;
    const Case = struct { line: []const u8, want: Line };
    const cases = [_]Case{
        .{ .line = "", .want = .nothing },
        .{ .line = "# a comment", .want = .nothing },
        .{ .line = "CONFIG_NETD=y", .want = .{ .set = .{ .option = .netd, .value = .{ .flag = true } } } },
        .{ .line = "CONFIG_NETD=n", .want = .{ .set = .{ .option = .netd, .value = .{ .flag = false } } } },
        .{ .line = "# CONFIG_NETD is not set", .want = .{ .set = .{ .option = .netd, .value = .{ .flag = false } } } },
        .{ .line = "CONFIG_HOME_MB=64", .want = .{ .set = .{ .option = .home_mb, .value = .{ .number = 64 } } } },
        .{ .line = "CONFIG_CPU_ATOM=y", .want = .{ .set = .{ .option = .cpu, .value = .{ .choice = @intFromEnum(options.Processor.atom) } } } },
        .{ .line = "# CONFIG_CPU_ATOM is not set", .want = .nothing },
        .{ .line = "CONFIG_GONE=y", .want = .{ .unknown = "CONFIG_GONE" } },
        .{ .line = "# CONFIG_GONE is not set", .want = .{ .unknown = "CONFIG_GONE" } },
        .{ .line = "CONFIG_NETD=maybe", .want = .malformed },
        .{ .line = "CONFIG_HOME_MB=lots", .want = .malformed },
        .{ .line = "CONFIG_CMDLINE=verbose", .want = .malformed },
        .{ .line = "NETD=y", .want = .malformed },
    };
    for (cases) |case| try testing.expectEqualDeep(case.want, parseLine(case.line, &room));

    switch (parseLine("CONFIG_CMDLINE=\"say \\\"hi\\\" \\\\ bye\"", &room)) {
        .set => |set| try testing.expectEqualStrings("say \"hi\" \\ bye", set.value.text),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Line.malformed, parseLine("CONFIG_CMDLINE=\"open", &room));
    try testing.expectEqual(Line.malformed, parseLine("CONFIG_CMDLINE=\"a\"b\"", &room));
}

test "a configuration written and read back is the same, with and without defaults" {
    var config: Config = .{ .cpu = .atom, .home_mb = 128, .at_boot = true, .hero = true, .logd = false };
    _ = options.set(&config, .cmdline, .{ .text = "verbose \"quoted\"" });

    for ([_]Style{ .full, .minimal }) |style| {
        var room: [8192]u8 = undefined;
        var out: std.Io.Writer = .fixed(&room);
        try write(&config, style, &out);

        var problems: Problems = .{};
        const back = read(out.buffered(), &problems);
        try testing.expectEqual(@as(usize, 0), problems.len);
        try testing.expect(back.eql(&config));
    }
}

test "savedefconfig writes only what differs from the defaults" {
    const config: Config = .{ .cpu = .via_c7, .web = true };
    var room: [1024]u8 = undefined;
    var out: std.Io.Writer = .fixed(&room);
    try write(&config, .minimal, &out);
    try testing.expectEqualStrings("CONFIG_CPU_VIA_C7=y\nCONFIG_WEB=y\n", out.buffered());
}

test "an option that is not offered is not written" {
    const config: Config = .{ .eeewm = false };
    var room: [8192]u8 = undefined;
    var out: std.Io.Writer = .fixed(&room);
    try write(&config, .full, &out);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "# CONFIG_EEEWM is not set\n") != null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "CONFIG_ETERM") == null);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "CONFIG_HERO") == null);
}

test "lines that cannot be used are listed and the rest still apply" {
    var problems: Problems = .{};
    const config = read(
        \\CONFIG_NETD=n
        \\CONFIG_GONE=y
        \\CONFIG_HOME_MB=1
        \\garbage
        \\CONFIG_HERO=y
    , &problems);
    try testing.expect(!config.netd);
    try testing.expect(config.hero);
    try testing.expectEqual(@as(u16, 16), config.home_mb);
    try testing.expectEqual(@as(usize, 3), problems.len);
    try testing.expectEqual(@as(usize, 2), problems.slice()[0].line);
    try testing.expectEqual(@as(usize, 3), problems.slice()[1].line);
    try testing.expectEqual(Option.home_mb, problems.slice()[1].what.refused);
    try testing.expectEqual(@as(usize, 4), problems.slice()[2].line);
}

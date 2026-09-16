//! The options an image is built with: values and defaults, the menu that
//! shows them, their help and what each depends on. The menu editor,
//! `.config` files, presets and the image plan all read this one declaration.
//!
//! An option named after a program puts that program in the image: `netd` is
//! `/bin/netd` and its service, `hero` is `home/bin/hero`.

const std = @import("std");
const lib = @import("lib");
pub const Processor = lib.processor.Processor;

/// The longest boot command line the loader's header holds.
pub const CMDLINE_MAX = 63;

pub const Text = lib.Bounded(u8, CMDLINE_MAX);

/// A size in MiB. Each size option gives its range in `About`.
pub const Size = u16;

pub const Config = struct {
    cpu: Processor = .pentium_m,

    rootfs_mb: Size = 3,
    system_mb: Size = 16,
    cfg_mb: Size = 16,
    home_mb: Size = 16,
    cmdline: Text = .{},
    manual: bool = true,
    certificates: bool = true,
    staged: bool = true,
    greet: bool = true,

    devmgd: bool = true,
    netd: bool = true,
    timed: bool = true,
    sndd: bool = true,
    usbd: bool = true,
    logd: bool = true,
    platd: bool = true,
    cfgd: bool = true,

    eeewm: bool = true,
    at_boot: bool = false,
    eterm: bool = true,
    pad: bool = true,
    efm: bool = true,
    calc: bool = true,
    eimg: bool = true,
    monitor: bool = true,
    settings: bool = true,
    screenshot: bool = true,

    hero: bool = false,
    echat: bool = false,
    eeemod: bool = false,
    roll: bool = false,
    web: bool = false,
    qjs: bool = false,
    doom: bool = false,

    /// Whether two configurations say the same.
    pub fn eql(a: *const Config, b: *const Config) bool {
        inline for (std.meta.fields(Config)) |field| {
            const x = &@field(a, field.name);
            const y = &@field(b, field.name);
            const same = switch (field.type) {
                Text => std.mem.eql(u8, x.slice(), y.slice()),
                else => x.* == y.*,
            };
            if (!same) return false;
        }
        return true;
    }
};

pub const Option = std.meta.FieldEnum(Config);

/// What an option puts in the image when it is on.
pub const Puts = enum {
    /// Nothing by itself: a setting the plan reads.
    setting,
    /// `/bin/<name>`, and its service when `etc/services` declares one.
    program,
    /// `/bin/<name>`, compiled from `examples/<name>.c` against the C library.
    example,
    /// `home/bin/<name>`, built with the image.
    app,
};

pub const Range = struct { min: u32, max: u32 };

pub const About = struct {
    prompt: []const u8,
    help: []const u8,
    /// Options that must be on for this one to be offered, besides the menu
    /// entries it sits under.
    needs: []const Option = &.{},
    puts: Puts = .setting,
    range: ?Range = null,
};

pub fn about(option: Option) About {
    return switch (option) {
        .cpu => .{
            .prompt = "Processor",
            .help = "The processor the image is compiled for. Also sets the model the emulator runs.",
        },
        .rootfs_mb => .{
            .prompt = "Root filesystem size in MiB",
            .help = "The in-memory root filesystem: programs, settings defaults, fonts and the manual. Loaded whole at boot, so larger is slower to start.",
            .range = .{ .min = 1, .max = 12 },
        },
        .system_mb => .{
            .prompt = "System partition size in MiB",
            .help = "Partition 1, where an update writes a new system.",
            .range = .{ .min = 4, .max = 1024 },
        },
        .cfg_mb => .{
            .prompt = "Settings partition size in MiB",
            .help = "Partition 2, mounted at /cfg.",
            .range = .{ .min = 4, .max = 1024 },
        },
        .home_mb => .{
            .prompt = "Home partition size in MiB",
            .help = "Partition 3, mounted at /home. `grow` extends it over the rest of a card after writing the image.",
            .range = .{ .min = 4, .max = 4096 },
        },
        .cmdline => .{
            .prompt = "Boot command line",
            .help = "Written into the loader's header. For example `verbose`, `nofb`, `no.netd`. At most 63 bytes.",
        },
        .manual => .{
            .prompt = "Manual pages",
            .help = "The pages `man` reads, in /doc. Command listings print names alone without them.",
        },
        .certificates => .{
            .prompt = "TLS certificate authorities",
            .help = "/share/ca.store, which TLS connections verify servers against. Included with echat or web whatever this says.",
        },
        .staged => .{
            .prompt = "Copy home/ into /home",
            .help = "Everything staged in home/ on this machine, including extra applications built earlier. Off: only the extra applications selected here.",
        },
        .greet => .{
            .prompt = "C example (greet)",
            .help = "A C program built against the C library, as a check that it links.",
            .puts = .example,
        },
        .devmgd => .{
            .prompt = "Device manager (devmgd)",
            .help = "Matches devices to drivers from /lib/drivers. Every driver service gets its devices from it.",
            .puts = .program,
        },
        .netd => .{
            .prompt = "Networking (netd)",
            .help = "Wired and wireless adapters, IPv4, DHCP, DNS, TCP and UDP.",
            .puts = .program,
        },
        .timed => .{
            .prompt = "Network time (timed)",
            .help = "Sets the clock over SNTP.",
            .puts = .program,
        },
        .sndd => .{
            .prompt = "Sound (sndd)",
            .help = "HD Audio and AC'97 playback, the mixer and the routing graph.",
            .puts = .program,
        },
        .usbd => .{
            .prompt = "USB (usbd)",
            .help = "Host controllers, hubs, keyboards, mice, storage and serial adapters. Booting from an SD card in the Eee PC's reader needs it: /cfg and /home mount through it.",
            .puts = .program,
        },
        .logd => .{
            .prompt = "Kernel log to a USB serial adapter (logd)",
            .help = "Sends the kernel log out of the adapter named in the `log` settings.",
            .puts = .program,
        },
        .platd => .{
            .prompt = "Platform firmware (platd)",
            .help = "ACPI through uACPI: interrupt routing, battery, backlight, power buttons, suspend. Drivers fall back to the PCI interrupt line without it.",
            .puts = .program,
        },
        .cfgd => .{
            .prompt = "Settings service (cfgd)",
            .help = "The only writer of settings. Programs read settings without it but cannot change them.",
            .puts = .program,
        },
        .eeewm => .{
            .prompt = "Desktop (eeewm)",
            .help = "The window manager, the bar and the launcher, with the fonts they draw in.",
            .puts = .program,
        },
        .at_boot => .{
            .prompt = "Start the desktop at boot",
            .help = "Otherwise the system boots to the shell, and `svc start eeewm` starts the desktop. The root filesystem is in memory, so `svc enable` does not outlast a reboot.",
        },
        .eterm => .{ .prompt = "Terminal (eterm)", .help = "A terminal running the shell.", .puts = .program },
        .pad => .{ .prompt = "Text editor (pad)", .help = "A UTF-8 text editor.", .puts = .program },
        .efm => .{ .prompt = "File manager (efm)", .help = "Two panes: copy, move, preview, open.", .puts = .program },
        .calc => .{ .prompt = "Calculator (calc)", .help = "A fixed-point calculator.", .puts = .program },
        .eimg => .{ .prompt = "Picture viewer (eimg)", .help = "PNG, JPEG, BMP and GIF, with EXIF orientation.", .puts = .program },
        .monitor => .{ .prompt = "System monitor (monitor)", .help = "Processes, CPU and memory use.", .puts = .program },
        .settings => .{ .prompt = "Settings (settings)", .help = "Theme, display, input, sound, power and shortcut settings.", .puts = .program },
        .screenshot => .{ .prompt = "Screenshot (screenshot)", .help = "Saves the screen as PNG, from Super+S.", .puts = .program },
        .hero => .{
            .prompt = "Hero character journal",
            .help = "A D&D 2024 character journal.",
            .needs = &.{.eeewm},
            .puts = .app,
        },
        .echat => .{
            .prompt = "echat IRC client",
            .help = "An IRC client.",
            .needs = &.{ .eeewm, .netd },
            .puts = .app,
        },
        .eeemod => .{
            .prompt = "eeemod tracker player",
            .help = "Plays ProTracker and SoundTracker modules.",
            .needs = &.{ .eeewm, .sndd },
            .puts = .app,
        },
        .roll => .{
            .prompt = "Roll contact sheet",
            .help = "A contact sheet of the pictures in a folder.",
            .needs = &.{.eeewm},
            .puts = .app,
        },
        .web => .{
            .prompt = "web browser (experimental)",
            .help = "Fetches, lays out and scripts web pages. Building it fetches an ad blocklist.",
            .needs = &.{ .eeewm, .netd },
            .puts = .app,
        },
        .qjs => .{
            .prompt = "QuickJS shell (qjs)",
            .help = "The QuickJS interpreter at the console.",
            .puts = .app,
        },
        .doom => .{
            .prompt = "Doom",
            .help = "The doomgeneric engine. Building it clones the engine's source; the WAD is not fetched.",
            .needs = &.{ .eeewm, .sndd },
            .puts = .app,
        },
    };
}

/// A menu entry: an option, with the entries offered under it while it is
/// on, or a submenu.
pub const Entry = union(enum) {
    option: Nested,
    menu: Menu,

    pub const Nested = struct {
        option: Option,
        under: []const Entry = &.{},
    };

    pub fn one(option: Option) Entry {
        return .{ .option = .{ .option = option } };
    }

    pub fn nest(option: Option, under: []const Entry) Entry {
        return .{ .option = .{ .option = option, .under = under } };
    }

    pub fn sub(title: []const u8, entries: []const Entry) Entry {
        return .{ .menu = .{ .title = title, .entries = entries } };
    }

    /// A submenu that is also an option: its entries are offered while it is on.
    pub fn gate(option: Option, entries: []const Entry) Entry {
        return .{ .menu = .{ .title = about(option).prompt, .toggle = option, .entries = entries } };
    }
};

pub const Menu = struct {
    title: []const u8,
    toggle: ?Option = null,
    entries: []const Entry,
};

pub const root: Menu = .{
    .title = "vibeee Configuration",
    .entries = &.{
        .one(.cpu),
        .sub("Image", &.{
            .one(.rootfs_mb),
            .one(.system_mb),
            .one(.cfg_mb),
            .one(.home_mb),
            .one(.cmdline),
            .one(.manual),
            .one(.certificates),
            .one(.staged),
            .one(.greet),
        }),
        .sub("Services", &.{
            .nest(.devmgd, &.{
                .nest(.netd, &.{.one(.timed)}),
                .one(.sndd),
                .nest(.usbd, &.{.one(.logd)}),
            }),
            .one(.platd),
            .one(.cfgd),
        }),
        .gate(.eeewm, &.{
            .one(.at_boot),
            .one(.eterm),
            .one(.pad),
            .one(.efm),
            .one(.calc),
            .one(.eimg),
            .one(.monitor),
            .one(.settings),
            .one(.screenshot),
        }),
        .sub("Extra applications", &.{
            .one(.hero),
            .one(.echat),
            .one(.eeemod),
            .one(.roll),
            .one(.web),
            .one(.qjs),
            .one(.doom),
        }),
    },
};

/// Everything an option depends on: the options of the entries and menus it
/// sits under, and its own `needs`. Worked out once from the menu.
const dependencies: [std.meta.fields(Config).len][]const Option = blk: {
    var found: [std.meta.fields(Config).len][]const Option = undefined;
    var placed: [std.meta.fields(Config).len]bool = @splat(false);
    walk(&root, &.{}, &found, &placed);
    for (placed, 0..) |was, index| {
        if (!was) @compileError("option " ++ @tagName(@as(Option, @enumFromInt(index))) ++ " is in no menu");
    }
    break :blk found;
};

fn walk(menu: *const Menu, above: []const Option, found: []([]const Option), placed: []bool) void {
    const inside = if (menu.toggle) |toggle| above ++ .{toggle} else above;
    for (menu.entries) |*entry| switch (entry.*) {
        .option => |nested| {
            const index = @intFromEnum(nested.option);
            if (placed[index]) @compileError("option " ++ @tagName(nested.option) ++ " is in two places");
            placed[index] = true;
            found[index] = inside ++ about(nested.option).needs;
            walk(&.{ .title = "", .entries = nested.under }, inside ++ .{nested.option}, found, placed);
        },
        .menu => |*sub| {
            if (sub.toggle) |toggle| {
                const index = @intFromEnum(toggle);
                if (!placed[index]) {
                    placed[index] = true;
                    found[index] = inside ++ about(toggle).needs;
                }
            }
            walk(sub, inside, found, placed);
        },
    };
}

pub fn dependsOn(option: Option) []const Option {
    return dependencies[@intFromEnum(option)];
}

/// Whether `option` is offered: everything it depends on is on.
pub fn offered(config: *const Config, option: Option) bool {
    for (dependsOn(option)) |needed| {
        if (!get(config, needed).flag) return false;
    }
    return true;
}

/// The configuration as built: an option that is not offered is off. Repeats
/// until nothing changes, so a chain resolves in any field order.
pub fn resolved(config: Config) Config {
    var out = config;
    while (true) {
        var changed = false;
        for (std.enums.values(Option)) |option| {
            const on = switch (get(&out, option)) {
                .flag => |on| on,
                else => continue,
            };
            if (!on or offered(&out, option)) continue;
            _ = set(&out, option, .{ .flag = false });
            changed = true;
        }
        if (!changed) return out;
    }
}

pub const Kind = enum { flag, choice, number, text };

pub const Value = union(Kind) {
    flag: bool,
    /// An index into `choices`.
    choice: usize,
    number: u32,
    text: []const u8,

    /// Whether two values say the same. Text compares by its bytes.
    pub fn eql(a: Value, b: Value) bool {
        return switch (a) {
            .text => |bytes| b == .text and std.mem.eql(u8, bytes, b.text),
            else => std.meta.eql(a, b),
        };
    }
};

pub fn kindOf(option: Option) Kind {
    return switch (option) {
        inline else => |which| comptime kindOfType(@FieldType(Config, @tagName(which))),
    };
}

fn kindOfType(comptime T: type) Kind {
    if (T == Text) return .text;
    return switch (@typeInfo(T)) {
        .bool => .flag,
        .@"enum" => .choice,
        .int => .number,
        else => @compileError("no kind of option is a " ++ @typeName(T)),
    };
}

pub fn get(config: *const Config, option: Option) Value {
    return switch (option) {
        inline else => |which| valueOf(&@field(config, @tagName(which))),
    };
}

fn valueOf(field: anytype) Value {
    const T = @TypeOf(field.*);
    return switch (comptime kindOfType(T)) {
        .flag => .{ .flag = field.* },
        .choice => .{ .choice = std.mem.indexOfScalar(T, std.enums.values(T), field.*).? },
        .number => .{ .number = field.* },
        .text => .{ .text = field.slice() },
    };
}

/// Set an option. False when `value` is not one it takes: another kind, a
/// number outside its range, or text too long or not printable ASCII.
pub fn set(config: *Config, option: Option, value: Value) bool {
    return switch (option) {
        inline else => |which| assign(&@field(config, @tagName(which)), about(which).range, value),
    };
}

fn assign(field: anytype, range: ?Range, value: Value) bool {
    const T = @TypeOf(field.*);
    switch (comptime kindOfType(T)) {
        .flag => field.* = switch (value) {
            .flag => |on| on,
            else => return false,
        },
        .choice => {
            const index = switch (value) {
                .choice => |index| index,
                else => return false,
            };
            const values = std.enums.values(T);
            if (index >= values.len) return false;
            field.* = values[index];
        },
        .number => {
            const n = switch (value) {
                .number => |n| n,
                else => return false,
            };
            const bounds = range.?;
            if (n < bounds.min or n > bounds.max) return false;
            field.* = @intCast(n);
        },
        .text => {
            const bytes = switch (value) {
                .text => |bytes| bytes,
                else => return false,
            };
            if (bytes.len > Text.CAPACITY) return false;
            for (bytes) |byte| {
                if (byte < ' ' or byte > '~') return false;
            }
            _ = field.set(bytes);
        },
    }
    return true;
}

/// A choice option's values: the tag `.config` spells, what the menu calls it
/// and its help.
pub const Choice = struct {
    tag: []const u8,
    prompt: []const u8,
    help: []const u8,
};

pub fn choices(option: Option) []const Choice {
    return switch (option) {
        inline else => |which| comptime blk: {
            const T = @FieldType(Config, @tagName(which));
            if (kindOfType(T) != .choice) break :blk &.{};
            var out: []const Choice = &.{};
            for (std.enums.values(T)) |one| {
                out = out ++ .{Choice{ .tag = @tagName(one), .prompt = one.prompt(), .help = one.help() }};
            }
            break :blk out;
        },
    };
}

const testing = std.testing;

test "every option has one place in the menu" {
    // Checked at compile time; reaching the table is enough.
    try testing.expectEqual(@as(usize, 0), dependsOn(.cpu).len);
}

test "an option depends on what it sits under and on what it names" {
    try testing.expectEqualSlices(Option, &.{.devmgd}, dependsOn(.netd));
    try testing.expectEqualSlices(Option, &.{ .devmgd, .netd }, dependsOn(.timed));
    try testing.expectEqualSlices(Option, &.{.eeewm}, dependsOn(.eterm));
    try testing.expectEqualSlices(Option, &.{ .eeewm, .netd }, dependsOn(.echat));
    try testing.expectEqualSlices(Option, &.{}, dependsOn(.qjs));
}

test "turning an option off takes what depends on it with it" {
    var config: Config = .{ .echat = true };
    config.devmgd = false;
    const built = resolved(config);
    try testing.expect(!built.netd);
    try testing.expect(!built.timed);
    try testing.expect(!built.sndd);
    try testing.expect(!built.echat);
    try testing.expect(built.eeewm);
    try testing.expect(!offered(&config, .timed));
}

test "values are read and written through their option" {
    var config: Config = .{};
    try testing.expect(set(&config, .home_mb, .{ .number = 64 }));
    try testing.expect(!set(&config, .home_mb, .{ .number = 2 }));
    try testing.expect(!set(&config, .home_mb, .{ .flag = true }));
    try testing.expectEqual(@as(u32, 64), get(&config, .home_mb).number);

    try testing.expect(set(&config, .cmdline, .{ .text = "verbose nofb" }));
    try testing.expect(!set(&config, .cmdline, .{ .text = "tab\there" }));
    try testing.expect(!set(&config, .cmdline, .{ .text = "x" ** (CMDLINE_MAX + 1) }));
    try testing.expectEqualStrings("verbose nofb", get(&config, .cmdline).text);

    try testing.expect(set(&config, .cpu, .{ .choice = 1 }));
    try testing.expect(!set(&config, .cpu, .{ .choice = 99 }));
    try testing.expectEqual(Processor.pentium3, config.cpu);
    try testing.expectEqual(@as(usize, 1), get(&config, .cpu).choice);
    try testing.expectEqualStrings("pentium3", choices(.cpu)[1].tag);

    try testing.expect(!config.eql(&.{}));
    config = .{};
    try testing.expect(config.eql(&.{}));
}

//! Named configurations, loaded with `make <name>_defconfig`.
//!
//! Two groups: what goes in the image, for the Eee PC 701, and machines, each
//! the default image compiled for that machine's processor. `make defconfig`
//! is the default: the Eee PC 700 series with everything but the extra
//! applications.

const std = @import("std");
const options = @import("options.zig");

const Config = options.Config;

pub const Group = enum { image, machine };

pub const Preset = enum {
    minimal,
    console,
    full,

    eeepc_701,
    eeepc_900,
    eeepc_901,
    eeepc_1000h,
    eeepc_1005ha,
    aspire_one_zg5,
    aspire_one_d250,
    hp_mini_110,
    hp_2133,
    dell_mini_9,
    dell_mini_10v,
    lenovo_s10,
    msi_wind_u100,
    samsung_nc10,
    samsung_nc20,
    toshiba_nb305,

    pub const About = struct {
        group: Group,
        summary: []const u8,
        config: Config,
    };

    pub fn about(self: Preset) About {
        return switch (self) {
            .minimal => .{
                .group = .image,
                .summary = "The kernel, init, the shell and its tools. No services, and nothing from home/.",
                .config = .{
                    .certificates = false,
                    .staged = false,
                    .greet = false,
                    .devmgd = false,
                    .platd = false,
                    .cfgd = false,
                    .eeewm = false,
                },
            },
            .console => .{
                .group = .image,
                .summary = "Every service and the shell. No desktop, and nothing from home/.",
                .config = .{ .eeewm = false, .staged = false },
            },
            .full => .{
                .group = .image,
                .summary = "The default image with every extra application, starting the desktop at boot.",
                .config = .{
                    .at_boot = true,
                    .hero = true,
                    .echat = true,
                    .eeemod = true,
                    .roll = true,
                    .web = true,
                    .qjs = true,
                    .doom = true,
                },
            },
            .eeepc_701 => machine("ASUS Eee PC 700 and 701 (2G, 4G, 8G): Celeron M 353. The default.", .pentium_m),
            .eeepc_900 => machine("ASUS Eee PC 900: Celeron M 353.", .pentium_m),
            .eeepc_901 => machine("ASUS Eee PC 901: Atom N270.", .atom),
            .eeepc_1000h => machine("ASUS Eee PC 1000H: Atom N270.", .atom),
            .eeepc_1005ha => machine("ASUS Eee PC 1005HA: Atom N280.", .atom),
            .aspire_one_zg5 => machine("Acer Aspire One A110 and A150 (ZG5): Atom N270.", .atom),
            .aspire_one_d250 => machine("Acer Aspire One D250: Atom N270 or N280.", .atom),
            .hp_mini_110 => machine("HP Mini 110: Atom N270, N280 or N450.", .atom),
            .hp_2133 => machine("HP 2133 Mini-Note: VIA C7-M.", .via_c7),
            .dell_mini_9 => machine("Dell Inspiron Mini 9: Atom N270.", .atom),
            .dell_mini_10v => machine("Dell Inspiron Mini 10v: Atom N270 or N280.", .atom),
            .lenovo_s10 => machine("Lenovo IdeaPad S10: Atom N270.", .atom),
            .msi_wind_u100 => machine("MSI Wind U100: Atom N270.", .atom),
            .samsung_nc10 => machine("Samsung NC10: Atom N270.", .atom),
            .samsung_nc20 => machine("Samsung NC20: VIA Nano U2250.", .via_nano),
            .toshiba_nb305 => machine("Toshiba NB305: Atom N450 or N455.", .atom),
        };
    }

    fn machine(summary: []const u8, processor: options.Processor) About {
        return .{ .group = .machine, .summary = summary, .config = .{ .cpu = processor } };
    }
};

const testing = std.testing;

test "the 701 is the default" {
    try testing.expect(Preset.eeepc_701.about().config.eql(&.{}));
}

test "no preset turns on an option whose dependencies it leaves off" {
    for (std.enums.values(Preset)) |preset| {
        const config = preset.about().config;
        for (std.enums.values(options.Option)) |option| {
            const value = options.get(&config, option);
            if (value.eql(options.get(&.{}, option)) or value != .flag or !value.flag) continue;
            try testing.expect(options.offered(&config, option));
        }
    }
}

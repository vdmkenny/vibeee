//! What an image holds, worked out from its configuration: the programs,
//! services, settings files and driver manifests in the root filesystem, the
//! extra applications built into home/, and the variables the Makefile builds
//! with.
//!
//! Files are filtered record by record. A record the configuration leaves as
//! it is is copied byte for byte, so the default configuration reproduces the
//! committed files exactly.

const std = @import("std");
const lib = @import("lib");
const options = @import("options.zig");

const stanzas = lib.stanzas;
const Config = options.Config;
const Option = options.Option;
const Writer = std.Io.Writer;

/// Programs every image has.
const always = [_][]const u8{ "init", "vsh", "tools" };

pub const Plan = struct {
    /// Resolved: an option that is not offered is off.
    config: Config,

    pub fn init(config: Config) Plan {
        return .{ .config = options.resolved(config) };
    }

    /// Whether the image has the program `name`, placed as `puts` says.
    pub fn has(self: *const Plan, puts: options.Puts, name: []const u8) bool {
        if (puts == .program) {
            for (always) |one| {
                if (std.mem.eql(u8, one, name)) return true;
            }
        }
        const option = std.meta.stringToEnum(Option, name) orelse return false;
        return options.about(option).puts == puts and options.get(&self.config, option).flag;
    }

    /// The names of the programs the image has that `puts` places, each after
    /// a space.
    fn writeNames(self: *const Plan, puts: options.Puts, out: *Writer) Writer.Error!void {
        if (puts == .program) {
            for (always) |one| try out.print(" {s}", .{one});
        }
        for (std.enums.values(Option)) |option| {
            if (options.about(option).puts != puts or !options.get(&self.config, option).flag) continue;
            try out.print(" {s}", .{@tagName(option)});
        }
    }

    /// `etc/services`: the records of the services the image has, their
    /// `needs` naming no service it lacks.
    pub fn services(self: *const Plan, text: []const u8, out: *Writer) Writer.Error!void {
        var records = stanzas.records(text);
        while (records.next()) |record| {
            if (stanzas.find(record, "name")) |name| {
                if (!self.has(.program, name)) continue;
            }
            var lines = std.mem.splitScalar(u8, record, '\n');
            while (lines.next()) |line| {
                const wrote = try self.servicesLine(text, line, out);
                if (wrote and lines.peek() != null) try out.writeByte('\n');
            }
        }
    }

    /// One line of a kept record. Returns false for a `needs` line left with
    /// nothing to name, which is dropped.
    fn servicesLine(self: *const Plan, text: []const u8, line: []const u8, out: *Writer) Writer.Error!bool {
        const found = stanzas.pair(line) orelse return copy(line, out);
        if (!std.mem.eql(u8, found.key, "needs")) return copy(line, out);

        var names = std.mem.splitScalar(u8, found.value, ',');
        var missing = false;
        while (names.next()) |name| missing = missing or self.lacksService(text, std.mem.trim(u8, name, " \t"));
        if (!missing) return copy(line, out);

        var kept = false;
        names.reset();
        while (names.next()) |raw| {
            const name = std.mem.trim(u8, raw, " \t");
            if (self.lacksService(text, name)) continue;
            if (!kept) {
                const equals = std.mem.indexOfScalar(u8, line, '=').?;
                const value_at = equals + 1 + std.mem.indexOf(u8, line[equals + 1 ..], found.value).?;
                try out.writeAll(line[0..value_at]);
            } else {
                try out.writeByte(',');
            }
            try out.writeAll(name);
            kept = true;
        }
        return kept;
    }

    /// Whether `name` is a service `text` declares and the image lacks. A
    /// target, which no record declares, is never lacking.
    fn lacksService(self: *const Plan, text: []const u8, name: []const u8) bool {
        var records = stanzas.records(text);
        while (records.next()) |record| {
            const declared = stanzas.find(record, "name") orelse continue;
            if (std.mem.eql(u8, declared, name)) return !self.has(.program, name);
        }
        return false;
    }

    /// `etc/disabled`: the services held down at boot that the image has,
    /// less the desktop when it starts at boot.
    pub fn disabled(self: *const Plan, text: []const u8, out: *Writer) Writer.Error!void {
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const name = std.mem.trim(u8, line, " \t\r");
            const held = name.len > 0 and name[0] != '#';
            const dropped = held and (!self.has(.program, name) or
                (self.config.at_boot and std.mem.eql(u8, name, @tagName(Option.eeewm))));
            if (dropped) continue;
            try out.writeAll(line);
            if (lines.peek() != null) try out.writeByte('\n');
        }
    }

    /// `etc/openers`: the records of programs the image has. A program under
    /// /home/bin is there when it is selected or when home/ is copied whole.
    pub fn openers(self: *const Plan, text: []const u8, out: *Writer) Writer.Error!void {
        var records = stanzas.records(text);
        while (records.next()) |record| {
            if (stanzas.find(record, "binary")) |binary| {
                const kept = if (std.mem.startsWith(u8, binary, "/bin/"))
                    self.has(.program, binary["/bin/".len..])
                else if (std.mem.startsWith(u8, binary, "/home/bin/"))
                    self.config.staged or self.has(.app, binary["/home/bin/".len..])
                else
                    true;
                if (!kept) continue;
            }
            try out.writeAll(record);
        }
    }

    /// Whether a driver manifest goes in: the service it names is one the
    /// image has, or no record of `services_text` provides it.
    pub fn keepsDriver(self: *const Plan, manifest: []const u8, services_text: []const u8) bool {
        const service = stanzas.find(manifest, "service") orelse return true;
        var records = stanzas.records(services_text);
        while (records.next()) |record| {
            const provides = stanzas.find(record, "provides") orelse continue;
            if (!std.mem.eql(u8, provides, service)) continue;
            return self.has(.program, stanzas.find(record, "name") orelse return true);
        }
        return true;
    }

    /// The Makefile's variables. `drivers` are the manifests to copy.
    pub fn makefile(self: *const Plan, drivers: []const []const u8, out: *Writer) Writer.Error!void {
        const config = &self.config;
        try out.writeAll("# The image configuration, written from .config by the image configuration tool.\n");
        try out.print("CONFIG_PROCESSOR := {s}\n", .{@tagName(config.cpu)});
        try out.writeAll("CONFIG_MCPU := ");
        try mcpu(config.cpu, out);
        try out.print("\nQEMU_CPU := {s}\n", .{config.cpu.emulated()});
        try out.print("MANUAL := {s}\n", .{yesNo(config.manual)});
        try out.writeAll("CMDLINE := ");
        for (config.cmdline.slice()) |c| switch (c) {
            '$' => try out.writeAll("$$"),
            '#' => try out.writeAll("\\#"),
            else => try out.writeByte(c),
        };
        try out.print(
            \\
            \\ROOTFS_MB := {d}
            \\PART1_MB := {d}
            \\CFG_MB := {d}
            \\HOME_MB := {d}
            \\
        , .{ config.rootfs_mb, config.system_mb, config.cfg_mb, config.home_mb });

        try out.writeAll("ROOTFS_PROGRAMS :=");
        try self.writeNames(.program, out);
        try out.writeAll("\nROOTFS_EXAMPLES :=");
        try self.writeNames(.example, out);
        try out.writeAll("\nROOTFS_SHARE :=");
        if (config.eeewm) try out.writeAll(" fonts.pack");
        if (config.certificates or config.echat or config.web) try out.writeAll(" ca.store");
        try out.writeAll("\nROOTFS_DRIVERS :=");
        for (drivers) |driver| try out.print(" {s}", .{driver});
        try out.print("\nHOME_STAGED := {s}\nHOME_APPS :=", .{yesNo(config.staged)});
        try self.writeNames(.app, out);
        try out.writeByte('\n');
    }
};

fn copy(line: []const u8, out: *Writer) Writer.Error!bool {
    try out.writeAll(line);
    return true;
}

fn yesNo(on: bool) []const u8 {
    return if (on) "yes" else "no";
}

/// The compiler's `-mcpu` for a processor: its model, and `+` each extension
/// added to the model.
pub fn mcpu(processor: options.Processor, out: *Writer) Writer.Error!void {
    const target = processor.target();
    try out.writeAll(target.model.name);
    for (std.Target.x86.all_features, 0..) |feature, index| {
        if (target.add.isEnabled(@intCast(index))) try out.print("+{s}", .{feature.name});
    }
}

const testing = std.testing;

const SERVICES =
    \\# Services started by init.
    \\
    \\name    = devmgd
    \\provides = devices
    \\
    \\name    = platd
    \\provides = platform
    \\
    \\name    = netd
    \\# The network.
    \\needs   = platd,cfgd, devmgd
    \\provides = net
    \\
    \\name    = eeewm
    \\needs   = platd
    \\
    \\name    = timed
    \\needs   = netd,boot
    \\
;

fn filtered(config: Config, comptime which: enum { services, disabled, openers }, text: []const u8, room: []u8) ![]const u8 {
    var out: Writer = .fixed(room);
    const plan: Plan = .init(config);
    switch (which) {
        .services => try plan.services(text, &out),
        .disabled => try plan.disabled(text, &out),
        .openers => try plan.openers(text, &out),
    }
    return out.buffered();
}

test "the default configuration copies the files it filters unchanged" {
    var room: [2048]u8 = undefined;
    try testing.expectEqualStrings(SERVICES, try filtered(.{}, .services, SERVICES, &room));
    try testing.expectEqualStrings("eeewm\n", try filtered(.{}, .disabled, "eeewm\n", &room));
    const openers = "# Openers.\n\nname = pad\nbinary = /bin/pad\n\nname = hero\nbinary = /home/bin/hero\n";
    try testing.expectEqualStrings(openers, try filtered(.{}, .openers, openers, &room));
}

test "a service the image lacks is dropped, and so is its name from other needs" {
    var room: [2048]u8 = undefined;
    try testing.expectEqualStrings(
        \\# Services started by init.
        \\
        \\name    = devmgd
        \\provides = devices
        \\
        \\name    = netd
        \\# The network.
        \\needs   = cfgd,devmgd
        \\provides = net
        \\
        \\name    = eeewm
        \\
        \\name    = timed
        \\needs   = netd,boot
        \\
    , try filtered(.{ .platd = false }, .services, SERVICES, &room));
}

test "turning a service off drops what depends on it" {
    var room: [2048]u8 = undefined;
    const text = try filtered(.{ .netd = false }, .services, SERVICES, &room);
    try testing.expect(std.mem.indexOf(u8, text, "name    = netd") == null);
    try testing.expect(std.mem.indexOf(u8, text, "name    = timed") == null);
    try testing.expect(std.mem.indexOf(u8, text, "name    = eeewm") != null);
}

test "the desktop is held down at boot unless it starts at boot or is not there" {
    var room: [64]u8 = undefined;
    try testing.expectEqualStrings("", try filtered(.{ .at_boot = true }, .disabled, "eeewm\n", &room));
    try testing.expectEqualStrings("", try filtered(.{ .eeewm = false }, .disabled, "eeewm\n", &room));
    try testing.expectEqualStrings("# held\nlogd\n", try filtered(.{ .eeewm = false }, .disabled, "# held\neeewm\nlogd\n", &room));
}

test "an opener goes with its program" {
    var room: [256]u8 = undefined;
    const openers = "name = pad\nbinary = /bin/pad\n\nname = hero\nbinary = /home/bin/hero\n\nname = x\nbinary = /opt/x\n";
    try testing.expectEqualStrings(
        "name = x\nbinary = /opt/x\n",
        try filtered(.{ .pad = false, .staged = false }, .openers, openers, &room),
    );
    try testing.expectEqualStrings(
        "name = hero\nbinary = /home/bin/hero\n\nname = x\nbinary = /opt/x\n",
        try filtered(.{ .pad = false, .staged = false, .hero = true }, .openers, openers, &room),
    );
}

test "a driver manifest goes with the service that takes its devices" {
    const plan: Plan = .init(.{ .netd = false });
    try testing.expect(!plan.keepsDriver("name = e1000\nservice = net\n", SERVICES));
    try testing.expect(plan.keepsDriver("name = umass\nservice = usb\n", SERVICES));
    try testing.expect(plan.keepsDriver("name = own\nbinary = /bin/own\n", SERVICES));
}

test "the Makefile's variables say what the configuration does" {
    var config: Config = .{ .cpu = .via_c7, .eeewm = false, .hero = true, .web = true };
    _ = options.set(&config, .cmdline, .{ .text = "verbose #1 $x" });
    var room: [2048]u8 = undefined;
    var out: Writer = .fixed(&room);
    const plan: Plan = .init(config);
    try plan.makefile(&.{ "ehci.man", "umass.man" }, &out);
    try testing.expectEqualStrings(
        \\# The image configuration, written from .config by the image configuration tool.
        \\CONFIG_PROCESSOR := via_c7
        \\CONFIG_MCPU := c3_2+sse2+sse3
        \\QEMU_CPU := pentium3,+sse2,+sse3
        \\MANUAL := yes
        \\CMDLINE := verbose \#1 $$x
        \\ROOTFS_MB := 3
        \\PART1_MB := 16
        \\CFG_MB := 16
        \\HOME_MB := 16
        \\ROOTFS_PROGRAMS := init vsh tools devmgd netd timed sndd usbd logd platd cfgd
        \\ROOTFS_EXAMPLES := greet
        \\ROOTFS_SHARE := ca.store
        \\ROOTFS_DRIVERS := ehci.man umass.man
        \\HOME_STAGED := yes
        \\HOME_APPS :=
        \\
    , out.buffered());
}

test "the default image has every system program and no extra application" {
    var room: [2048]u8 = undefined;
    var out: Writer = .fixed(&room);
    const plan: Plan = .init(.{});
    try plan.makefile(&.{}, &out);
    const text = out.buffered();
    try testing.expect(std.mem.indexOf(u8, text, "ROOTFS_PROGRAMS := init vsh tools devmgd netd timed sndd usbd logd platd cfgd eeewm eterm pad efm calc eimg monitor settings screenshot\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "ROOTFS_SHARE := fonts.pack ca.store\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "HOME_APPS :=\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "CONFIG_MCPU := pentium_m\n") != null);
}

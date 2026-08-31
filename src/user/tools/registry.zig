//! The command table: what the multicall binary can do.
//!
//! Its own module because two programs need it and only one of them can own an
//! entry point. The tools binary dispatches on it; the shell completes command
//! names from it, so a command added here is completable without anyone
//! remembering to say so a second time somewhere else.

const manual = @import("manual");
const eeefetch = @import("eeefetch.zig");
const smbios = @import("smbios.zig");
const acpi = @import("acpi.zig");
const backlight = @import("backlight.zig");
const battery = @import("battery.zig");
const cfg = @import("cfg.zig");
const date = @import("date.zig");
const file_tool = @import("file.zig");
const files = @import("files.zig");
const grep = @import("grep.zig");
const hotkeys = @import("hotkeys.zig");
const display_tool = @import("display.zig");
const edit_tool = @import("edit.zig");
const irq_tool = @import("irq.zig");
const devices_tool = @import("devices.zig");
const klog = @import("klog.zig");
const man = @import("man.zig");
const net = @import("net.zig");
const nc = @import("nc.zig");
const ping = @import("ping.zig");
const resolve_tool = @import("resolve.zig");
const tone = @import("tone.zig");
const vol = @import("vol.zig");
const patch = @import("patch.zig");
const driver_tool = @import("driver.zig");
const page = @import("page.zig");
const status = @import("status.zig");
const svc = @import("svc.zig");
const tree = @import("tree.zig");
const usb_tool = @import("usb.zig");
const volumes = @import("volumes.zig");
const out = @import("ulib").out;
const str = @import("ulib").str;

pub const Command = struct {
    name: []const u8,
    summary: []const u8,
    run: *const fn (args: []const []const u8) void,
};

pub const commands = [_]Command{
    .{ .name = "ls", .summary = manual.summaryOf("ls"), .run = &files.ls },
    .{ .name = "cat", .summary = manual.summaryOf("cat"), .run = &files.cat },
    .{ .name = "rm", .summary = manual.summaryOf("rm"), .run = &files.rm },
    .{ .name = "mv", .summary = manual.summaryOf("mv"), .run = &files.mv },
    .{ .name = "hexdump", .summary = manual.summaryOf("hexdump"), .run = &files.hexdump },
    .{ .name = "file", .summary = manual.summaryOf("file"), .run = &file_tool.run },
    .{ .name = "grep", .summary = manual.summaryOf("grep"), .run = &grep.run },
    .{ .name = "free", .summary = manual.summaryOf("free"), .run = &status.free },
    .{ .name = "battery", .summary = manual.summaryOf("battery"), .run = &battery.run },
    .{ .name = "backlight", .summary = manual.summaryOf("backlight"), .run = &backlight.run },
    .{ .name = "hotkeys", .summary = manual.summaryOf("hotkeys"), .run = &hotkeys.run },
    .{ .name = "top", .summary = manual.summaryOf("top"), .run = &status.top },
    .{ .name = "kill", .summary = manual.summaryOf("kill"), .run = &status.kill },
    .{ .name = "irq", .summary = manual.summaryOf("irq"), .run = &irq_tool.irq },
    .{ .name = "devices", .summary = manual.summaryOf("devices"), .run = &devices_tool.devices },
    .{ .name = "acpi", .summary = manual.summaryOf("acpi"), .run = &acpi.run },
    .{ .name = "display", .summary = manual.summaryOf("display"), .run = &display_tool.display },
    .{ .name = "log", .summary = manual.summaryOf("log"), .run = &klog.log },
    .{ .name = "man", .summary = manual.summaryOf("man"), .run = &man.run },
    .{ .name = "net", .summary = manual.summaryOf("net"), .run = &net.run },
    .{ .name = "ping", .summary = manual.summaryOf("ping"), .run = &ping.run },
    .{ .name = "nc", .summary = manual.summaryOf("nc"), .run = &nc.run },
    .{ .name = "resolve", .summary = manual.summaryOf("resolve"), .run = &resolve_tool.run },
    .{ .name = "tone", .summary = manual.summaryOf("tone"), .run = &tone.run },
    .{ .name = "vol", .summary = manual.summaryOf("vol"), .run = &vol.run },
    .{ .name = "usb", .summary = manual.summaryOf("usb"), .run = &usb_tool.run },
    .{ .name = "patch", .summary = manual.summaryOf("patch"), .run = &patch.run },
    .{ .name = "driver", .summary = manual.summaryOf("driver"), .run = &driver_tool.run },
    .{ .name = "commands", .summary = manual.summaryOf("commands"), .run = &listNames },
    .{ .name = "page", .summary = manual.summaryOf("page"), .run = &page.run },
    .{ .name = "edit", .summary = manual.summaryOf("edit"), .run = &edit_tool.run },
    .{ .name = "mkdir", .summary = manual.summaryOf("mkdir"), .run = &files.mkdir },
    .{ .name = "tree", .summary = manual.summaryOf("tree"), .run = &tree.run },
    .{ .name = "cfg", .summary = manual.summaryOf("cfg"), .run = &cfg.run },
    .{ .name = "svc", .summary = manual.summaryOf("svc"), .run = &svc.run },
    .{ .name = "disk", .summary = manual.summaryOf("disk"), .run = &status.disk },
    .{ .name = "mount", .summary = manual.summaryOf("mount"), .run = &volumes.mount },
    .{ .name = "unmount", .summary = manual.summaryOf("unmount"), .run = &volumes.unmount },
    .{ .name = "date", .summary = manual.summaryOf("date"), .run = &date.run },
    .{ .name = "eeefetch", .summary = manual.summaryOf("eeefetch"), .run = &eeefetch.run },
    .{ .name = "smbios", .summary = manual.summaryOf("smbios"), .run = &smbios.run },
};


/// The names alone, for a shell completing a command name. Derived from the
/// table rather than written beside it, so a command added here is completable
/// without anyone remembering to say so a second time.
pub const names = blk: {
    var listed: [commands.len][]const u8 = undefined;
    for (commands, 0..) |c, i| listed[i] = c.name;
    break :blk listed;
};

/// Every name, one per line.
///
/// Exists so the shell can ask what this binary can do instead of holding its
/// own copy of the list. A second list would be a second thing to keep in step,
/// and a shell built into the same image as the tools it completes has no
/// business knowing them at compile time.
fn listNames(_: []const []const u8) void {
    for (commands) |c| {
        out.text(c.name);
        out.byte('\n');
    }
    out.flush();
}

/// The command of that name, or null.
pub fn find(name: []const u8) ?Command {
    for (commands) |c| {
        if (str.eql(c.name, name)) return c;
    }
    return null;
}

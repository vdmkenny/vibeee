//! The command table: what the multicall binary can do.
//!
//! Its own module because two programs need it and only one of them can own an
//! entry point. The tools binary dispatches on it; the shell completes command
//! names from it, so a command added here is completable without anyone
//! remembering to say so a second time somewhere else.

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
const irq_tool = @import("irq.zig");
const devices_tool = @import("devices.zig");
const klog = @import("klog.zig");
const net = @import("net.zig");
const ping = @import("ping.zig");
const page = @import("page.zig");
const status = @import("status.zig");
const svc = @import("svc.zig");
const tree = @import("tree.zig");
const volumes = @import("volumes.zig");
const out = @import("ulib").out;
const str = @import("ulib").str;

pub const Command = struct {
    name: []const u8,
    summary: []const u8,
    run: *const fn (args: []const []const u8) void,
};

pub const commands = [_]Command{
    .{ .name = "ls", .summary = "list a directory", .run = &files.ls },
    .{ .name = "cat", .summary = "print a file", .run = &files.cat },
    .{ .name = "rm", .summary = "remove a file", .run = &files.rm },
    .{ .name = "mv", .summary = "move or rename", .run = &files.mv },
    .{ .name = "hexdump", .summary = "dump a file in hex", .run = &files.hexdump },
    .{ .name = "file", .summary = "what kind of file something is", .run = &file_tool.run },
    .{ .name = "grep", .summary = "print lines matching a pattern", .run = &grep.run },
    .{ .name = "free", .summary = "show memory use", .run = &status.free },
    .{ .name = "battery", .summary = "what the pack is doing, and what it has come to", .run = &battery.run },
    .{ .name = "backlight", .summary = "how bright the panel is, and making it otherwise", .run = &backlight.run },
    .{ .name = "hotkeys", .summary = "the keys that do not arrive as keys", .run = &hotkeys.run },
    .{ .name = "top", .summary = "show threads and load", .run = &status.top },
    .{ .name = "kill", .summary = "end a process by id", .run = &status.kill },
    .{ .name = "irq", .summary = "interrupt lines held outside the kernel", .run = &irq_tool.irq },
    .{ .name = "devices", .summary = "what is on the bus, and what drives it", .run = &devices_tool.devices },
    .{ .name = "acpi", .summary = "what the firmware says this machine has", .run = &acpi.run },
    .{ .name = "display", .summary = "the panel, and asking it for a mode", .run = &display_tool.display },
    .{ .name = "log", .summary = "what the kernel and the services have said", .run = &klog.log },
    .{ .name = "net", .summary = "the network interfaces: status, up/down, dhcp, static", .run = &net.run },
    .{ .name = "ping", .summary = "one echo a second, answered or timed out", .run = &ping.run },
    .{ .name = "commands", .summary = "list command names, one per line", .run = &listNames },
    .{ .name = "page", .summary = "read a file a screen at a time", .run = &page.run },
    .{ .name = "mkdir", .summary = "create a directory", .run = &files.mkdir },
    .{ .name = "tree", .summary = "a directory and everything under it", .run = &tree.run },
    .{ .name = "cfg", .summary = "read and change system settings", .run = &cfg.run },
    .{ .name = "svc", .summary = "what is supposed to be running, and what is", .run = &svc.run },
    .{ .name = "disk", .summary = "list drives and volumes", .run = &status.disk },
    .{ .name = "mount", .summary = "attach a volume at a path", .run = &volumes.mount },
    .{ .name = "unmount", .summary = "detach a volume, flushing it first", .run = &volumes.unmount },
    .{ .name = "date", .summary = "show the wall-clock time", .run = &date.run },
    .{ .name = "eeefetch", .summary = "show system information", .run = &eeefetch.run },
    .{ .name = "smbios", .summary = "decode the firmware DMI tables", .run = &smbios.run },
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

//! free, top and disk, what the machine is doing right now.
//!
//! Written to be read rather than to match Linux. `free` explains its own
//! numbers instead of printing a grid of unlabelled columns; `disk` describes
//! drives and the volumes on them the way macOS `diskutil list` does, rather
//! than making you run three tools and correlate the output yourself.
//!
//! Mirroring Unix exactly is not a goal. Familiar names are worth keeping;
//! cryptic output is not.

const sys = @import("../syscall.zig");
const out = @import("../lib/out.zig");
const info = @import("../lib/info.zig");
const str = @import("../lib/str.zig");



/// A bar is worth more than a percentage at a glance, and costs nothing.
fn bar(used: usize, total: usize, width: usize) void {
    const filled = if (total == 0) 0 else used * width / total;
    out.byte('[');
    var i: usize = 0;
    while (i < width) : (i += 1) out.byte(if (i < filled) '#' else '.');
    out.byte(']');
}

fn mib(bytes: usize) void {
    out.decimal(bytes / (1024 * 1024));
    out.text(" MiB");
}

pub fn free(_: []const []const u8) void {
    const total = info.askNumber("mem.total");
    const available = info.askNumber("mem.free");
    const used = total -| available;

    var buf: [128]u8 = [_]u8{0} ** 128;

    out.text("memory  ");
    bar(used, total, 24);
    out.byte(' ');
    if (total > 0) {
        out.decimal(used * 100 / total);
        out.byte('%');
    }
    out.byte('\n');

    out.text("        ");
    mib(used);
    out.text(" used, ");
    mib(available);
    out.text(" free, ");
    mib(total);
    out.text(" total\n");

    const fitted = info.ask("mem.hardware", &buf);
    if (fitted.len > 0) {
        out.text("fitted  ");
        out.text(fitted);
        out.byte('\n');
    }

    const heap = info.ask("heap", &buf);
    if (heap.len > 0) {
        out.text("kernel  ");
        out.text(heap);
        out.byte('\n');
    }

    out.flush();
}

pub fn top(args: []const []const u8) void {
    // Refreshes a fixed number of times rather than until interrupted: there is
    // no signal to interrupt it with yet, and a program that could not be
    // stopped would be worse than one that stops on its own.
    const rounds = if (args.len > 0) @max(str.toUnsigned(args[0]), 1) else 1;

    var buf: [1024]u8 = [_]u8{0} ** 1024;

    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        const uptime = info.askNumber("uptime");
        const total = info.askNumber("mem.total");
        const available = info.askNumber("mem.free");

        out.text("up ");
        out.decimal(uptime);
        out.text("s   memory ");
        mib(total -| available);
        out.text(" / ");
        mib(total);
        out.byte('\n');
        out.byte('\n');

        out.pad("PID", 6);
        out.pad("STATE", 10);
        out.pad("PRI", 5);
        out.pad("TICKS", 8);
        out.text("NAME\n");

        writeTree(info.ask("threads.list", &buf));

        if (round + 1 < rounds) {
            out.byte('\n');
            out.flush();
            sys.sleepMicros(1_000_000);
        }
    }

    out.flush();
}

/// Rows arrive tab-separated; column widths are decided here so the kernel does
/// not have to know how anything will be displayed.
const MAX_THREADS = 64;

const Row = struct {
    pid: usize = 0,
    parent: usize = 0,
    state: []const u8 = "",
    priority: []const u8 = "",
    ticks: []const u8 = "",
    name: []const u8 = "",
    /// Set once printed, so a parent loop that has gone wrong cannot make this
    /// print the same thread forever.
    shown: bool = false,
};

var rows: [MAX_THREADS]Row = @splat(.{});

/// Print the thread list as a tree.
///
/// Which process started which is most of what anyone looking at this wants to
/// know, whether the shell is init's child, whether a tool is still attached
/// to the shell that ran it, and a flat list makes that guesswork.
fn writeTree(text: []const u8) void {
    var count: usize = 0;

    var lines = str.lines(text);
    while (lines.next()) |line| {
        if (line.len == 0 or count >= MAX_THREADS) continue;
        var it = str.fields(line);
        rows[count] = .{
            .pid = str.toUnsigned(it.next() orelse continue),
            .parent = str.toUnsigned(it.next() orelse continue),
            .state = it.next() orelse "",
            .priority = it.next() orelse "",
            .ticks = it.next() orelse "",
            .name = it.next() orelse "",
        };
        count += 1;
    }

    // Roots first: a thread whose parent is not in the list is one the kernel
    // started itself, and is where a branch of the tree begins.
    for (rows[0..count]) |*row| {
        if (findRow(count, row.parent) == null) writeBranch(count, row, 0);
    }

    // Anything left is in a parent cycle, which should be impossible, but
    // dropping threads silently from the one tool that lists them would hide
    // exactly the bug that caused it.
    for (rows[0..count]) |*row| {
        if (!row.shown) writeBranch(count, row, 0);
    }
}

fn findRow(count: usize, pid: usize) ?*Row {
    for (rows[0..count]) |*row| {
        if (row.pid == pid) return row;
    }
    return null;
}

fn writeBranch(count: usize, row: *Row, depth: usize) void {
    if (row.shown) return;
    row.shown = true;

    out.decimalRight(row.pid, 4);
    out.text("  ");
    out.pad(row.state, 10);
    out.pad(row.priority, 5);
    out.pad(row.ticks, 8);

    var indent: usize = 0;
    while (indent < depth) : (indent += 1) out.text("  ");
    out.text(row.name);
    out.byte('\n');

    for (rows[0..count]) |*child| {
        if (child != row and child.parent == row.pid) writeBranch(count, child, depth + 1);
    }
}

pub fn disk(_: []const []const u8) void {
    var buf: [1024]u8 = [_]u8{0} ** 1024;
    const list = info.ask("disks", &buf);

    if (list.len == 0) {
        out.text("no storage devices\n");
        out.flush();
        return;
    }

    out.text("device       size        mounted\n");

    var listing = str.lines(list);
    while (listing.next()) |row| {
        if (row.len > 0) writeDiskRow(row);
    }
    out.flush();
}

fn writeDiskRow(row: []const u8) void {
    // Indentation marks a volume within the disk above it.
    const stripped = str.stripIndent(row);

    var it = str.fields(stripped.text);
    const name = it.next() orelse return;
    const size = it.next() orelse "";
    const note = it.next() orelse "";

    if (stripped.indented) out.text("  ");
    out.pad(name, if (stripped.indented) 11 else 13);
    out.decimalRight(str.toUnsigned(size) / (1024 * 1024), 6);
    out.text(" MiB   ");
    out.text(note);
    out.byte('\n');
}

/// Services registered with the kernel, from `/svc`.
///
/// The registry is the map of what is running and answerable, so this is the
/// first thing to look at when something that should respond does not.
pub fn services(_: []const []const u8) void {
    var buf: [512]u8 = [_]u8{0} ** 512;
    const n = sys.sysinfo("svc", &buf);

    if (n <= 0) {
        out.text("no services registered\n");
        out.flush();
        return;
    }

    var count: usize = 0;
    var it = str.lines(buf[0..@intCast(n)]);
    while (it.next()) |name| {
        if (name.len == 0) continue;
        out.text("  ");
        out.text(name);
        out.byte('\n');
        count += 1;
    }

    out.decimal(count);
    out.text(if (count == 1) " service\n" else " services\n");
    out.flush();
}

//! free, top and disk, what the machine is doing right now.
//!
//! Written to be read rather than to match Linux. `free` explains its own
//! numbers instead of printing a grid of unlabelled columns; `disk` describes
//! drives and the volumes on them the way macOS `diskutil list` does, rather
//! than making you run three tools and correlate the output yourself.
//!
//! Mirroring Unix exactly is not a goal. Familiar names are worth keeping;
//! cryptic output is not.

const sys = @import("sys");
const out = @import("ulib").out;
const info = @import("ulib").info;
const procs = @import("ulib").procs;
const str = @import("ulib").str;



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

        writeTree(&buf);

        if (round + 1 < rounds) {
            out.byte('\n');
            out.flush();
            sys.sleepMicros(1_000_000);
        }
    }

    out.flush();
}

/// Print the process table as a tree.
///
/// Which process started which is most of what anyone looking at this wants to
/// know: whether the shell is init's child, whether a tool is still attached to
/// the shell that ran it. A flat list makes that guesswork.
fn writeTree(buf: []u8) void {
    const table = procs.read(buf);

    for (table.items()) |p| {
        out.decimalRight(p.pid, 4);
        out.text("  ");
        out.pad(p.state, 10);
        out.padNumber(p.priority, 5);
        out.padNumber(p.ticks, 8);

        for (0..p.depth) |_| out.text("  ");
        out.text(p.name);
        if (p.current) out.text(" *");
        out.byte('\n');
    }
}

/// End a process.
///
/// There are no signals, so there is nothing to choose between: this ends the
/// process. Naming it `kill` anyway because that is what anyone will type.
pub fn kill(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: kill <pid>\n");
        out.flush();
        return;
    }

    for (args) |arg| {
        const pid = str.toUnsigned(arg);
        const result = sys.kill(@intCast(pid));
        if (result < 0) {
            out.text("kill: ");
            out.decimal(pid);
            out.text(if (result == -1) ": not allowed\n" else ": no such process\n");
        }
    }
    out.flush();
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

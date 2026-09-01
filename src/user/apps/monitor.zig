//! Monitor: what the machine is doing and what to stop.
//!
//! The process tree, what each one is costing, and a way to end one that has
//! stopped being useful. Bound to the key the ASUS keyboard already labels for
//! it, Fn+F6, once the platform driver exists to report it.
//!
//! Reads through `sysinfo`, which is the only interface the kernel offers for
//! this and deliberately so: this window is a view, and a view that could not
//! be reproduced by a shell command would be hiding something.

const std = @import("std");
const eui = @import("eui");
const proto = @import("proto");
const sys = @import("sys");
const info = @import("ulib").info;
const out = @import("ulib").out;
const procs = @import("ulib").procs;
const str = @import("ulib").str;

const theme = eui.theme;
const Rect = eui.Rect;

/// The frame's context, which is where every control call goes.
const ctx = &proto.app.ctx;

/// How often the numbers are taken again. Half a second is fast enough to feel
/// live and slow enough that watching it is not itself the load.
const REFRESH_US: u32 = 500_000;

export fn _start() callconv(.c) noreturn {
    sample();
    proto.app.run("monitor", "Monitor", 420, 300, .{
        .draw = draw,
        .tick = tick,
        .tick_us = REFRESH_US,
    });
}

/// The wait timed out, which is the refresh: nothing happened, so the only
/// thing that could have changed is the numbers.
fn tick() bool {
    sample();
    return true;
}

// ---------------------------------------------------------------------------
// The numbers
// ---------------------------------------------------------------------------

var text_buffer: [2048]u8 = @splat(0);
var table: procs.Table = .{};
var list: eui.table.State = .{};

/// Per-row formatted text. The table holds slices, so what they point at has to
/// outlive the pass that built them.
const Cells = struct {
    pid: [8]u8 = @splat(0),
    cpu: [8]u8 = @splat(0),
    memory: [12]u8 = @splat(0),
    uptime: [12]u8 = @splat(0),
    /// Lower-cased when it came off a FAT short name, which is stored in caps
    /// because the format has nowhere to record case.
    name: [16]u8 = @splat(0),
};

var cells: [procs.MAX]Cells = @splat(.{});
var rows: [procs.MAX]eui.table.Row = @splat(.{});
var row_count: usize = 0;

/// Ticks each process had at the previous sample, so the column can show what
/// it is costing now rather than what it has cost since boot. The latter only
/// ever goes up, which makes it useless for spotting what is busy.
var previous_ticks: [procs.MAX]usize = @splat(0);
var previous_pids: [procs.MAX]usize = @splat(0);
var previous_count: usize = 0;

/// What each row's share worked out to, kept because sorting by cpu has to
/// compare the numbers rather than the text: "9%" sorts above "10%".
var shares: [procs.MAX]usize = @splat(0);

/// The numbers behind the columns that hold numbers. A table sorted on the
/// text of its cells would put 9% above 10% and 998B above 4M.
const Numbers = struct { pid: usize = 0, cpu: usize = 0, bytes: usize = 0, uptime: usize = 0 };
var numbers: [procs.MAX]Numbers = @splat(.{});

var uptime: usize = 0;
var mem_total: usize = 0;
var mem_free: usize = 0;

/// What the processor calls itself, asked once: it does not change, and it is
/// the note under the reading that says what is busy.
var cpu_name_buffer: [40]u8 = @splat(0);
var cpu_name: []const u8 = "";

/// The order the design puts them in: what it is, then what it is doing,
/// then what it costs. Sorting is by clicking the heading, which is why the
/// order matters less than it did and the meaning of each column matters
/// more.
const COLUMNS = [_]eui.table.Column{
    .{ .title = "pid", .width = 46 },
    .{ .title = "name", .width = 120, .tree = true, .flex = true },
    .{ .title = "state", .width = 76 },
    .{ .title = "cpu", .width = 52, .right = true },
    .{ .title = "memory", .width = 64, .right = true },
    .{ .title = "uptime", .width = 62, .right = true },
};

/// Which column each field is, for the sort. Named rather than numbered: a
/// column moved in the table above should not silently sort by something
/// else.
const Column = enum(usize) { pid = 0, name = 1, state = 2, cpu = 3, memory = 4, uptime = 5 };

/// What other services say, read here rather than while painting. A paint
/// happens whenever the pointer moves, and these are calls into another
/// process, two of them answered by the firmware through the embedded
/// controller: asking them per motion is felt as a window that lags the
/// hand moving over it.
var pack: ?proto.platform.Battery = null;
var hottest: ?proto.platform.Thermal = null;
var home_used: u8 = 0;
var home_free: usize = 0;
var home_known = false;
var mounts_buffer: [512]u8 = @splat(0);

fn sample() void {
    if (cpu_name.len == 0) cpu_name = info.ask("cpu", &cpu_name_buffer);

    table = procs.read(&text_buffer);
    uptime = info.askNumber("uptime");
    mem_total = info.askNumber("mem.total");
    mem_free = info.askNumber("mem.free");
    pack = proto.platform.battery();
    hottest = proto.platform.hottest();
    readHome();

    // Shares are of what was spent since the last sample, not of the interval:
    // the idle thread's ticks are in the total, so the numbers add up to a
    // hundred and a busy process reads as one.
    var spent: usize = 0;
    for (table.items()) |p| spent += p.ticks -| ticksBefore(p.pid);

    row_count = 0;
    for (table.items()) |p| {
        if (row_count >= rows.len) break;

        // In tenths of a per cent: at half-second samples on one core, whole
        // per cent puts almost every process at zero and says nothing about
        // which of them is the busy one.
        const delta = p.ticks -| ticksBefore(p.pid);
        const share = if (spent == 0) 0 else delta * 1000 / spent;

        var c = &cells[row_count];
        var pid = str.Builder{ .buf = &c.pid };
        pid.number(p.pid);

        var cpu = str.Builder{ .buf = &c.cpu };
        cpu.number(share / 10);
        cpu.byte('.');
        cpu.number(share % 10);
        cpu.byte('%');

        var memory = str.Builder{ .buf = &c.memory };
        memory.bytes(p.bytes);

        var uptime_cell = str.Builder{ .buf = &c.uptime };
        uptime_cell.duration(p.uptime_s);

        rows[row_count] = .{
            .cells = .{ pid.done(), p.name, p.state, cpu.done(), memory.done(), uptime_cell.done() },
            .depth = p.depth,
            .marked = p.current,
        };
        shares[row_count] = share;
        numbers[row_count] = .{
            .pid = p.pid,
            .cpu = share,
            .bytes = p.bytes,
            .uptime = p.uptime_s,
        };
        row_count += 1;
    }

    order();

    previous_count = 0;
    for (table.items()) |p| {
        previous_pids[previous_count] = p.pid;
        previous_ticks[previous_count] = p.ticks;
        previous_count += 1;
    }
}

/// Put the rows in the order the headings ask for.
///
/// Tree order until somebody asks for something else: the tree says which
/// process started which, and that is the more useful default. Sorting flattens
/// it, because a hierarchy ordered by memory is not a hierarchy.
fn order() void {
    const by = list.sort orelse return;

    // Insertion sort: the list is a few dozen rows, it is nearly sorted
    // between refreshes, and it costs nothing but the comparisons.
    var i: usize = 1;
    while (i < row_count) : (i += 1) {
        var j = i;
        while (j > 0 and after(j - 1, j, by)) : (j -= 1) {
            swap(j - 1, j);
        }
    }

    for (rows[0..row_count]) |*row| row.depth = 0;
}

/// Whether row `a` should be listed after row `b`.
fn after(a: usize, b: usize, by: eui.table.Sort) bool {
    const column: Column = @enumFromInt(@min(by.column, @typeInfo(Column).@"enum".fields.len - 1));

    const ordered = switch (column) {
        .pid => numbers[a].pid < numbers[b].pid,
        .cpu => numbers[a].cpu < numbers[b].cpu,
        .memory => numbers[a].bytes < numbers[b].bytes,
        .uptime => numbers[a].uptime < numbers[b].uptime,
        .name, .state => str.before(
            rows[a].cells[@intFromEnum(column)],
            rows[b].cells[@intFromEnum(column)],
        ),
    };

    return if (by.descending) ordered else !ordered and !same(a, b, column);
}

fn same(a: usize, b: usize, column: Column) bool {
    return std.mem.eql(u8, rows[a].cells[@intFromEnum(column)], rows[b].cells[@intFromEnum(column)]);
}

fn swap(a: usize, b: usize) void {
    const row = rows[a];
    rows[a] = rows[b];
    rows[b] = row;

    const n = numbers[a];
    numbers[a] = numbers[b];
    numbers[b] = n;

    const share = shares[a];
    shares[a] = shares[b];
    shares[b] = share;
}

fn ticksBefore(pid: usize) usize {
    for (previous_pids[0..previous_count], previous_ticks[0..previous_count]) |id, ticks| {
        if (id == pid) return ticks;
    }
    return 0;
}

fn selectedPid() ?usize {
    if (list.selected >= table.entries.len) return null;
    return table.items()[list.selected].pid;
}

// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------

/// What just happened, said in the status bar until something else does.
var status: []const u8 = "";

/// End the selected process, and say what came of it.
fn end() void {
    const pid = selectedPid() orelse {
        status = "Nothing selected.";
        ctx.damage();
        return;
    };

    status = switch (sys.kill(@intCast(pid))) {
        0 => "Ended.",
        -1 => "That one cannot be ended.",
        else => "No longer running.",
    };

    sample();
    ctx.damage();
}

fn draw() void {
    const t = theme.current();
    const surface = ctx.surface;
    const area = Rect{ .x = 0, .y = 0, .w = surface.width, .h = surface.height };

    const pad = t.padding;
    const row = t.control_height;
    const parts = eui.chrome.split(area, .{ .bottom = true });

    // What the machine is doing, across the top: the four things somebody
    // opens this window to find out, before the list of what is doing them.
    const gauges = eui.Rect{ .x = 0, .y = 0, .w = area.w, .h = eui.gauge.height() };
    eui.gauge.paint(surface, gauges, readings());
    ctx.addDamage(gauges);

    const buttons_y = parts.body.h - row - pad;
    list.striped = true;
    _ = ctx.table(.{
        .x = pad,
        .y = gauges.bottom() + pad,
        .w = area.w - pad * 2,
        .h = buttons_y - gauges.bottom() - pad * 2,
    }, &list, &COLUMNS, rows[0..row_count]);

    // One button, at the end where a window's actions go. Closing is the
    // manager's business and every window is closed the same way.
    const end_w = eui.footer.buttonWidth("End task");
    if (ctx.button(.{ .x = area.w - pad - end_w, .y = buttons_y, .w = end_w, .h = row }, "End task")) end();

    eui.statusbar.run(ctx, parts.bottom, &.{
        .{ .text = if (status.len > 0) status else processText() },
        .{ .text = temperatureText(), .width = 70, .right = true },
        .{ .text = uptimeText(), .width = 78, .right = true },
    });
}

/// The four readings across the top. Held between passes because the strings
/// they point at have to outlive the call that built them.
var gauge_values: [4][16]u8 = @splat(@splat(0));
var gauge_notes: [4][32]u8 = @splat(@splat(0));
var gauge_rows: [4]eui.gauge.Reading = undefined;

fn readings() []const eui.gauge.Reading {
    var n: usize = 0;

    n += cpuReading(n);
    n += memoryReading(n);
    n += batteryReading(n);
    n += storageReading(n);

    return gauge_rows[0..n];
}

fn cpuReading(at: usize) usize {
    // What is not idle. The idle thread's share is what the scheduler had
    // nothing to do with, so the rest is the load.
    var busy: usize = 100;
    for (rows[0..row_count], shares[0..row_count]) |r, share| {
        if (std.mem.eql(u8, r.cells[@intFromEnum(Column.name)], "idle")) busy = 100 -| (share / 10);
    }

    var value = str.Builder{ .buf = &gauge_values[at] };
    value.number(busy);
    value.byte('%');

    var note = str.Builder{ .buf = &gauge_notes[at] };
    note.text(cpu_name);

    gauge_rows[at] = .{
        .label = "cpu",
        .value = value.done(),
        .percent = @intCast(@min(busy, 100)),
        .note = note.done(),
    };
    return 1;
}

fn memoryReading(at: usize) usize {
    var value = str.Builder{ .buf = &gauge_values[at] };
    value.bytes(mem_total -| mem_free);

    var note = str.Builder{ .buf = &gauge_notes[at] };
    note.text("of ");
    note.bytes(mem_total);

    gauge_rows[at] = .{
        .label = "memory",
        .value = value.done(),
        .percent = memoryPercent(),
        .note = note.done(),
    };
    return 1;
}

fn batteryReading(at: usize) usize {
    const cell = pack orelse return 0;
    if (!cell.isPresent()) return 0;
    const charge = cell.charge() orelse return 0;

    var value = str.Builder{ .buf = &gauge_values[at] };
    value.number(charge);
    value.byte('%');

    // What it is doing, or how long it has left doing it. The time is the
    // more useful of the two and only exists while it is discharging.
    var note = str.Builder{ .buf = &gauge_notes[at] };
    if (cell.runtimeLeft()) |left| {
        note.duration(@as(usize, left.hours) * 3600 + @as(usize, left.minutes) * 60);
        note.text(" left");
    } else {
        note.text(cell.stateLabel());
    }

    gauge_rows[at] = .{
        .label = "battery",
        .value = value.done(),
        .percent = @intCast(@min(charge, 100)),
        .note = note.done(),
        .alarm = .when_empty,
    };
    return 1;
}

const HOME = "/home";

/// How full the volume home is on. The one a person fills up: the root is
/// the system's and a machine of this size has nowhere else to put anything.
fn storageReading(at: usize) usize {
    if (!home_known) return 0;
    return homeGauge(at);
}

/// How full home is, asked of the kernel once a sample rather than once a
/// paint.
fn readHome() void {
    home_known = false;
    var lines = str.lines(info.ask("mounts", &mounts_buffer));
    while (lines.next()) |line| {
        const text = str.trim(line);
        if (!std.mem.startsWith(u8, text, HOME ++ " ")) continue;

        var words: [8][]const u8 = undefined;
        const words_n = str.splitWords(text, &words);
        var free: usize = 0;
        var size: usize = 0;
        for (words[0..words_n]) |word| {
            if (std.mem.startsWith(u8, word, "free=")) free = str.toUnsigned(word["free=".len..]);
            if (std.mem.startsWith(u8, word, "size=")) size = str.toUnsigned(word["size=".len..]);
        }
        if (size == 0) return;

        home_free = free;
        home_used = @intCast(@min((size -| free) * 100 / size, 100));
        home_known = true;
        return;
    }
}

/// The gauge for it, built where every other gauge is built.
fn homeGauge(at: usize) usize {
    var value = str.Builder{ .buf = &gauge_values[at] };
    value.number(home_used);
    value.byte('%');

    var note = str.Builder{ .buf = &gauge_notes[at] };
    note.text(HOME);
    note.text(", ");
    note.bytes(home_free);
    note.text(" free");

    gauge_rows[at] = .{
        .label = "storage",
        .value = value.done(),
        .percent = home_used,
        .note = note.done(),
    };
    return 1;
}

fn thermalReading(at: usize) usize {
    const zone = hottest orelse return 0;
    const degrees = proto.platform.Thermal.degrees(zone.now);

    var value = str.Builder{ .buf = &gauge_values[at] };
    value.number(@intCast(degrees));
    value.text(" C");

    var note = str.Builder{ .buf = &gauge_notes[at] };
    note.text(zone.named());

    // Against the zone's own critical point rather than a number picked
    // here: what is hot depends on the machine, and the firmware says.
    const critical = proto.platform.Thermal.degrees(zone.critical);
    const share = if (critical > 0) @divTrunc(degrees * 100, critical) else 0;

    gauge_rows[at] = .{
        .label = "temperature",
        .value = value.done(),
        .percent = @intCast(@max(@min(share, 100), 0)),
        .note = note.done(),
        // Against the firmware's own critical point, which is what the
        // percentage above is a share of.
        .alarm = .when_full,
    };
    return 1;
}

fn memoryPercent() u8 {
    if (mem_total == 0) return 0;
    return @intCast((mem_total -| mem_free) * 100 / mem_total);
}

var uptime_buffer: [24]u8 = @splat(0);
var process_buffer: [24]u8 = @splat(0);

var temperature_buffer: [16]u8 = @splat(0);

/// The hottest zone, in whole degrees. A machine with no sensor says nothing
/// rather than zero: a monitor claiming absolute cold is worse than one that
/// admits it cannot tell.
fn temperatureText() []const u8 {
    const zone = hottest orelse return "";
    var line = str.Builder{ .buf = &temperature_buffer };
    line.number(@intCast(proto.platform.Thermal.degrees(zone.now)));
    line.text(" C");
    return line.done();
}

fn uptimeText() []const u8 {
    var line = str.Builder{ .buf = &uptime_buffer };
    line.text("up ");
    line.duration(uptime);
    return line.done();
}

fn processText() []const u8 {
    var line = str.Builder{ .buf = &process_buffer };
    const shown = table.entries.len;
    line.quantity(shown, if (shown == 1) "process" else "processes");
    return line.done();
}

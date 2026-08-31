//! Monitor: what the machine is doing and what to stop.
//!
//! The process tree, what each one is costing, and a way to end one that has
//! stopped being useful. Bound to the key the ASUS keyboard already labels for
//! it, Fn+F6, once the platform driver exists to report it.
//!
//! Reads through `sysinfo`, which is the only interface the kernel offers for
//! this and deliberately so: this window is a view, and a view that could not
//! be reproduced by a shell command would be hiding something.

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
    ticks: [12]u8 = @splat(0),
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

var uptime: usize = 0;
var mem_total: usize = 0;
var mem_free: usize = 0;

const COLUMNS = [_]eui.table.Column{
    .{ .title = "pid", .width = 42, .right = true },
    .{ .title = "state", .width = 66 },
    .{ .title = "cpu", .width = 44, .right = true },
    .{ .title = "ticks", .width = 56, .right = true },
    .{ .title = "name", .width = 90, .tree = true },
};

fn sample() void {
    table = procs.read(&text_buffer);
    uptime = info.askNumber("uptime");
    mem_total = info.askNumber("mem.total");
    mem_free = info.askNumber("mem.free");

    // Shares are of what was spent since the last sample, not of the interval:
    // the idle thread's ticks are in the total, so the numbers add up to a
    // hundred and a busy process reads as one.
    var spent: usize = 0;
    for (table.items()) |p| spent += p.ticks -| ticksBefore(p.pid);

    row_count = 0;
    for (table.items()) |p| {
        if (row_count >= rows.len) break;

        const delta = p.ticks -| ticksBefore(p.pid);
        const share = if (spent == 0) 0 else delta * 100 / spent;

        var c = &cells[row_count];
        var pid = str.Builder{ .buf = &c.pid };
        pid.number(p.pid);

        var cpu = str.Builder{ .buf = &c.cpu };
        cpu.number(share);
        cpu.byte('%');

        var ticks = str.Builder{ .buf = &c.ticks };
        ticks.number(p.ticks);

        rows[row_count] = .{
            .cells = .{ pid.done(), p.state, cpu.done(), ticks.done(), p.name, "" },
            .depth = p.depth,
            .marked = p.current,
        };
        row_count += 1;
    }

    previous_count = 0;
    for (table.items()) |p| {
        previous_pids[previous_count] = p.pid;
        previous_ticks[previous_count] = p.ticks;
        previous_count += 1;
    }
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
    const bottom = eui.statusbar.split(area);

    const buttons_y = bottom.body.h - row - pad;
    _ = ctx.table(.{
        .x = pad,
        .y = pad,
        .w = area.w - pad * 2,
        .h = buttons_y - pad * 2,
    }, &list, &COLUMNS, rows[0..row_count]);

    if (ctx.button(.{ .x = pad, .y = buttons_y, .w = 90, .h = row }, "End task")) end();
    if (ctx.button(.{ .x = pad + 94, .y = buttons_y, .w = 76, .h = row }, "Close")) sys.exit(0);

    // The memory bar sits beside the buttons rather than above the table: it
    // is the one number here that reads better as a length than as a figure.
    const bar_x = pad + 178;
    ctx.progress(
        .{ .x = bar_x, .y = buttons_y + @divTrunc(row - 8, 2), .w = area.w - bar_x - pad, .h = 8 },
        memoryPercent(),
    );

    eui.statusbar.run(ctx, bottom.bar, &.{
        .{ .text = status },
        .{ .text = processText(), .width = 92 },
        .{ .text = memoryText(), .width = 118, .right = true },
        .{ .text = uptimeText(), .width = 62, .right = true },
    });

}

fn memoryPercent() u8 {
    if (mem_total == 0) return 0;
    return @intCast((mem_total -| mem_free) * 100 / mem_total);
}

var uptime_buffer: [24]u8 = @splat(0);
var process_buffer: [24]u8 = @splat(0);
var memory_buffer: [40]u8 = @splat(0);

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

fn memoryText() []const u8 {
    var line = str.Builder{ .buf = &memory_buffer };
    line.number((mem_total -| mem_free) / (1024 * 1024));
    line.text(" of ");
    line.quantity(mem_total / (1024 * 1024), "MiB");
    return line.done();
}

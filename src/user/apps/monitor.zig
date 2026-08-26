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

var connection: proto.Connection = undefined;
var window: u8 = 0;
var ctx: eui.Context = undefined;

var pointer_x: i32 = 0;
var pointer_y: i32 = 0;
var buttons: eui.widget.Buttons = .{};

/// How often the numbers are taken again. Half a second is fast enough to feel
/// live and slow enough that watching it is not itself the load.
const REFRESH_US: u32 = 500_000;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ xorl %ebp, %ebp
        \\ call monitorMain
        \\ hlt
    );
}

export fn monitorMain() callconv(.c) noreturn {
    connection = proto.client.Connection.open("monitor") catch {
        out.text("monitor: no window manager is running\n");
        out.flush();
        sys.exit(1);
    };

    window = connection.createWindow(.{}, 420, 300) catch sys.exit(1);
    connection.setTitle(window, "Monitor") catch {};

    sample();
    run();
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
            .cells = .{ pid.done(), p.state, cpu.done(), ticks.done(), str.displayName(&c.name, p.name), "" },
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
    if (list.selected >= table.count) return null;
    return table.items()[list.selected].pid;
}

// ---------------------------------------------------------------------------
// The window
// ---------------------------------------------------------------------------

fn run() noreturn {
    while (true) {
        const event = connection.next(REFRESH_US) orelse {
            // The wait timed out, which is the refresh: nothing happened, so
            // the only thing that could have changed is the numbers.
            sample();
            redraw();
            continue;
        };

        switch (event.tag) {
            .configure => resize(event.body.configure.w, event.body.configure.h),
            .ptr_motion => {
                pointer_x = event.body.motion.x;
                pointer_y = event.body.motion.y;
                redraw();
            },
            .ptr_button => {
                pointer_x = event.body.button.x;
                pointer_y = event.body.button.y;
                setButton(event.body.button.btn, event.body.button.down != 0);
                redraw();
            },
            .scroll => {
                ctx.postScroll(event.body.scroll.dy);
                redraw();
            },
            .key => {
                ctx.postKey(@intCast(event.body.key.code), @bitCast(event.body.key.mods));
                if (event.body.key.down != 0) redraw();
            },
            .theme => {
                proto.client.applyTheme(&event.body.theme.name);
                ctx.damage();
                redraw();
            },
            .close_req => sys.exit(0),
            .overflow => redraw(),
            else => {},
        }
    }
}

fn setButton(index: u8, down: bool) void {
    switch (index) {
        0 => buttons.left = down,
        1 => buttons.right = down,
        2 => buttons.middle = down,
        else => {},
    }
}

fn resize(w: u16, h: u16) void {
    connection.attach(window, w, h) catch return;
    const surface = connection.surfaceOf(window) orelse return;

    ctx = eui.Context.init(surface.*);
    ctx.damageNow();
    draw();
    connection.map(window) catch {};
}

fn redraw() void {
    const surface = connection.surfaceOf(window) orelse return;
    ctx.surface = surface.*;
    draw();
    if (ctx.pending) draw();
}

/// What the last action did. A task manager that refuses silently is one that
/// looks broken.
var status: []const u8 = "";

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

    ctx.begin(pointer_x, pointer_y, buttons);
    if (ctx.damaged) surface.fill(area, t.surface);

    const pad = t.padding;
    const row = t.control_height;

    drawSummary(.{ .x = pad, .y = pad, .w = area.w - pad * 2, .h = 34 });

    const buttons_y = area.h - row - pad;
    const body = Rect{
        .x = pad,
        .y = pad + 40,
        .w = area.w - pad * 2,
        .h = buttons_y - pad * 2 - 40,
    };
    _ = ctx.table(body, &list, &COLUMNS, rows[0..row_count]);

    if (ctx.button(.{ .x = pad, .y = buttons_y, .w = 90, .h = row }, "End task")) end();
    if (ctx.button(.{ .x = pad + 94, .y = buttons_y, .w = 76, .h = row }, "Close")) sys.exit(0);

    ctx.label(
        .{ .x = pad + 180, .y = buttons_y + 4, .w = area.w - pad - 180, .h = 16 },
        status,
    );

    ctx.end();
    connection.commit(window, ctx.damageList()) catch {};
}

/// Uptime, process count and memory, on one line above a bar.
fn drawSummary(area: Rect) void {
    var buf: [96]u8 = @splat(0);
    var line = str.Builder{ .buf = &buf };

    line.text("up ");
    line.quantity(uptime, "s");
    line.text(",  ");
    line.quantity(table.count, if (table.count == 1) "process" else "processes");
    line.text(",  ");
    line.number((mem_total -| mem_free) / (1024 * 1024));
    line.text(" of ");
    line.quantity(mem_total / (1024 * 1024), "MiB");

    ctx.label(.{ .x = area.x, .y = area.y, .w = area.w, .h = 16 }, line.done());

    const used = mem_total -| mem_free;
    const percent: u8 = if (mem_total == 0) 0 else @intCast(used * 100 / mem_total);
    ctx.progress(.{ .x = area.x, .y = area.y + 20, .w = area.w, .h = 8 }, percent);
}

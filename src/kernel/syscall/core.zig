//! Process, thread and time calls: the ones every program uses and none of
//! which belong to a subsystem.

const std = @import("std");
const abi = @import("lib").syscalls;
const clock = @import("../clock.zig");
const console = @import("../console.zig");
const handles = @import("../handle.zig");
const vfs = @import("../vfs.zig");
const ctx = @import("context.zig");
const input = @import("../input.zig");
const sched = @import("../sched.zig");
const shutdown_mod = @import("../shutdown.zig");
const sysinfo = @import("../sysinfo.zig");
const tty = @import("../tty.zig");

const Args = ctx.Args;
const Result = ctx.Result;
const Errno = ctx.Errno;
const userSlice = ctx.userSlice;
const currentHandles = ctx.currentHandles;

pub fn sys_exit(a: Args) Result {
    const status: i32 = @truncate(@as(isize, @bitCast(a.a0)));
    if (sched.currentThread()) |t| {
        console.debug("exit", "{s} (thread {d}) status {d}", .{ t.name(), t.id, status });
    }
    // Never returns: the thread is unlinked and the next one is switched in.
    // The abandoned interrupt frame goes with the dying thread's stack.
    sched.exitWith(status);
}

pub fn sys_write(a: Args) Result {
    const number: u32 = @truncate(a.a0);
    const buf = userSlice(a, a.a1, a.a2) orelse return Errno.fault.value();

    // Before the scheduler starts there is no process and so no handle table,
    // but the boot self-test and early init still write to the console. Their
    // handle numbers mean what they always mean.
    const table = currentHandles() orelse {
        if (number == abi.STDOUT or number == abi.STDERR) return writeConsole(number, buf);
        return Errno.badf.value();
    };

    const h = table.get(number) orelse return Errno.badf.value();
    if (!h.rights.write) return Errno.perm.value();

    return switch (h.kind) {
        .console => writeConsole(number, buf),
        .file => writeFile(&h.data.file, buf),
        else => Errno.badf.value(),
    };
}

fn writeConsole(number: u32, buf: []const u8) Result {
    // Standard error is coloured so a failure stands out in a log that is
    // otherwise the only output this machine has.
    const is_err = number == abi.STDERR;
    if (is_err) console.setColor(.light_red, .black);
    console.writeString(buf);
    if (is_err) console.setColor(.light_grey, .black);
    return @intCast(buf.len);
}

fn writeFile(file: *handles.File, buf: []const u8) Result {
    const at = if (file.append) file.entry.size else file.offset;

    const written = vfs.writeAt(file.mount, &file.entry, at, buf) catch |err| {
        return switch (err) {
            error.ReadOnly => Errno.perm.value(),
            error.NoSpace => Errno.nospace.value(),
            error.IsDirectory => Errno.inval.value(),
            else => Errno.io.value(),
        };
    };

    file.offset = at + written;
    // The directory entry is written back when the handle closes, not here.
    file.dirty = true;
    return @intCast(written);
}

pub fn sys_read(a: Args) Result {
    const buf = userSlice(a, a.a1, a.a2) orelse return Errno.fault.value();
    if (buf.len == 0) return 0;

    const id: u32 = @truncate(a.a0);
    if (id == abi.STDIN) {
        // Block until a line is available. Sleeping rather than spinning
        // matters: a shell waiting at a prompt must not consume the CPU
        // everything else needs, and on a single core it would starve them.
        while (!tty.hasLine()) sched.sleepMicros(10_000);
        return @intCast(tty.read(buf));
    }

    const table = currentHandles() orelse return Errno.badf.value();
    const h = table.get(id) orelse return Errno.badf.value();
    if (h.kind != .file or !h.rights.read) return Errno.badf.value();

    const f = &h.data.file;
    const n = vfs.readAt(f.mount, f.entry, f.offset, buf) catch return Errno.io.value();
    f.offset += n;
    return @intCast(n);
}

pub fn sys_yield(_: Args) Result {
    sched.yield();
    return 0;
}

pub fn sys_sleep_us(a: Args) Result {
    sched.sleepMicros(a.a0);
    return 0;
}

pub fn sys_clock_us(a: Args) Result {
    const out = userSlice(a, a.a0, @sizeOf(u64)) orelse return Errno.fault.value();
    std.mem.writeInt(u64, out[0..8], clock.monotonicMicros(), .little);
    return 0;
}

pub fn sys_realtime_us(a: Args) Result {
    const out = userSlice(a, a.a0, @sizeOf(i64)) orelse return Errno.fault.value();
    if (!clock.valid()) return Errno.inval.value();
    std.mem.writeInt(i64, out[0..8], clock.realtimeMicros(), .little);
    return 0;
}

pub fn sys_getpid(_: Args) Result {
    const t = sched.currentThread() orelse return 0;
    return @intCast(t.id);
}

pub fn sys_log(a: Args) Result {
    const buf = userSlice(a, a.a0, a.a1) orelse return Errno.fault.value();
    if (buf.len == 0 or buf.len > 256) return Errno.inval.value();
    console.field("user", "{s}", .{buf});
    return 0;
}

pub fn sys_shutdown(a: Args) Result {
    const action: shutdown_mod.Action = switch (a.a0) {
        0 => .power_off,
        1 => .reboot,
        2 => .halt,
        else => return Errno.inval.value(),
    };
    shutdown_mod.shutdown(action);
}

pub fn sys_sysinfo(a: Args) Result {
    const key = userSlice(a, a.a0, a.a1) orelse return Errno.fault.value();
    const out = userSlice(a, a.a2, a.a3) orelse return Errno.fault.value();
    if (key.len == 0 or key.len > 64) return Errno.inval.value();

    const n = sysinfo.query(key, out) catch |err| return switch (err) {
        error.UnknownKey => Errno.inval.value(),
        error.NoSpace => Errno.nomem.value(),
    };
    return @intCast(n);
}
pub fn sys_pointer_read(a: Args) Result {
    const out = userSlice(a, a.a0, a.a1) orelse return Errno.fault.value();

    const size = @sizeOf(abi.PointerEvent);
    const capacity = out.len / size;
    if (capacity == 0) return Errno.inval.value();

    const deadline = ctx.deadlineFrom(a.a2);

    // Block until there is something, rather than returning an empty read: a
    // caller that got zero would spin, and the whole point of the queue is
    // that a consumer can sleep between movements.
    while (!input.hasPointerEvents()) {
        input.pointerReady().waitOne(deadline) catch return Errno.timedout.value();
    }

    var written: usize = 0;
    while (written < capacity) : (written += 1) {
        const event = input.pollPointer() orelse break;
        const record = abi.PointerEvent{
            .x = event.x,
            .y = event.y,
            .dx = event.dx,
            .dy = event.dy,
            .wheel = event.wheel,
            .buttons = .{
                .left = event.buttons.left,
                .right = event.buttons.right,
                .middle = event.buttons.middle,
            },
            .buttons_changed = @intFromBool(event.buttons_changed),
        };
        @memcpy(out[written * size ..][0..size], std.mem.asBytes(&record));
    }

    return @intCast(written * size);
}

pub fn sys_key_read(a: Args) Result {
    const out = userSlice(a, a.a0, a.a1) orelse return Errno.fault.value();

    const size = @sizeOf(abi.KeyEvent);
    const capacity = out.len / size;
    if (capacity == 0) return Errno.inval.value();

    // Reading claims the keyboard. Doing it here rather than in a separate
    // call means a process cannot claim the keyboard and then fail to read it,
    // which would leave the shell with no input and no way to say so.
    const self_id = if (sched.currentThread()) |t| t.id else 0;
    input.claimKeys(self_id);

    const deadline = ctx.deadlineFrom(a.a2);

    while (!input.hasKeyEvents()) {
        input.keyReady().waitOne(deadline) catch return Errno.timedout.value();
    }

    var written: usize = 0;
    while (written < capacity) : (written += 1) {
        const event = input.pollKey() orelse break;
        const record = abi.KeyEvent{
            .code = @intFromEnum(event.code),
            .pressed = @intFromBool(event.pressed),
            .modifiers = @bitCast(event.mods),
            .codepoint = event.codepoint,
        };
        @memcpy(out[written * size ..][0..size], std.mem.asBytes(&record));
    }

    return @intCast(written * size);
}

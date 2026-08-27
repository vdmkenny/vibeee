//! vibeee kernel entry.
//!
//! Both boot paths converge here with a BootInfo already built: the SD-card
//! path via boot/stage2, and `qemu -kernel` / GRUB via arch/x86/multiboot.zig.
//! Nothing below this line knows which one ran.

const std = @import("std");
const builtin = @import("builtin");

const bootinfo = @import("bootinfo.zig");
const channel = @import("channel.zig");
const console = @import("console.zig");
const event = @import("event.zig");
const hal = @import("hal.zig");
const lib = @import("lib");
const logo = lib.logo;
const panic_mod = @import("panic.zig");
const panicring = @import("panicring.zig");
const pipe = @import("pipe.zig");
const pmm = @import("pmm.zig");
const heap = @import("heap.zig");
const bcache = @import("bcache.zig");
const sched = @import("sched.zig");
const svc = @import("svc.zig");
const syscall_abi = @import("lib").syscalls;
const platform = @import("../platform.zig");

pub const panic = std.debug.FullPanic(panic_mod.kpanic);

pub const VERSION = "0.1.0-M0";

/// Kernel stack for the boot thread. Threads get their own once the scheduler
/// exists; until then this is also what the TSS esp0 points at.
var kernel_stack: [32 * 1024]u8 align(16) = undefined;

/// The first thing on screen. Drawn before anything can fail, so a machine that
/// dies during bring-up has still said what it was trying to be, which on
/// hardware with no serial port is the difference between a diagnosable failure
/// and a blank panel.
fn banner() void {
    // By role rather than by colour, so the wordmark here and the one
    // `eeefetch` prints later are the same colour because they mean the same
    // thing, not because two files happen to agree.
    console.setColor(console.colourOf(.key), .black);
    for (logo.lines) |line| {
        console.writeString(line);
        console.putChar('\n');
    }

    console.setColor(console.colourOf(.value), .black);
    console.printf("vibeee {s}", .{VERSION});
    console.setColor(console.colourOf(.dim), .black);
    console.printf("  {s}\n\n", .{@tagName(builtin.cpu.arch)});
    console.setColor(console.colourOf(.value), .black);
}

pub fn kmain(bi: *bootinfo.BootInfo) noreturn {
    console.init();

    if (bi.magic != bootinfo.MAGIC or bi.version != bootinfo.VERSION) {
        console.fail("bootinfo mismatch (magic {x}, v{d}); rebuild image", .{ bi.magic, bi.version });
        hal.halt();
    }

    console.setVerbose(lib.cmdline.has(bi.cmdlineSlice(), "verbose"));
    console.setDebug(lib.cmdline.has(bi.cmdlineSlice(), "debug"));
    console.setColorEnabled(!lib.cmdline.has(bi.cmdlineSlice(), "nocolor"));
    platform.earlyConsole();

    // The backend is chosen before anything is drawn: in graphics mode the text
    // buffer is no longer displayed, so anything written first would vanish.
    _ = console.useFramebuffer(bi);

    banner();
    platform.reportVideo();

    // stage2 has no serial port to log to, so it logs to a RAM ring. Replay it
    // only when it has something to say.
    if (bi.log_phys != 0 and bi.log_len != 0) {
        const ptr: [*]const u8 = @ptrFromInt(bi.log_phys);
        console.writeString(ptr[0..@min(bi.log_len, 8192)]);
    }

    hal.initCpu(@intFromPtr(&kernel_stack) + kernel_stack.len);
    // Before the interrupt controller, which has to be told where the
    // controllers are and how the legacy lines reach them.
    platform.readFirmwareTables(bi);
    hal.initInterruptController(platform.interruptRouting());
    hal.initSyscalls();
    hal.initTimer();
    // Everything the tick handler touches is initialised, so interrupts can be
    // taken from here on.
    hal.enableInterrupts();

    const cpu_info = hal.cpuInfo();
    console.info("cpu", "{s}", .{cpu_info.brand});
    // What was armed, not what the CPU advertises: the two differ when the
    // MSRs could not be programmed, and userspace picks from the former.
    console.info("", "{s}{s}", .{
        if (hal.fastSyscallArmed()) "sysenter" else "int80",
        if (cpu_info.freq_scaling) ", freq scaling" else ", fixed clock",
    });

    pmm.init(bi);
    const m = pmm.stats();
    console.info("mem", "{d}M usable, {d}M free, {d} frames", .{
        m.totalBytes() / (1024 * 1024),
        m.freeBytes() / (1024 * 1024),
        m.total_frames,
    });

    // The identity mapping existed only to survive the instant paging came on.
    // Dropping it hands the whole low 3 GiB to user space.
    hal.dropBootIdentityMapping();

    heap.init();
    selfTestHeap();

    reportPreviousPanic();

    console.info("boot", "{s}", .{switch (bi.source) {
        .stage2 => "sd",
        .multiboot => "multiboot",
    }});

    if (bi.rsdp != 0) {
        console.info("acpi", "rsdp {x:0>8}", .{bi.rsdp});
    } else {
        console.warn("no acpi rsdp; battery, hotkeys, backlight unavailable", .{});
    }

    if (bi.cmdline_len > 0) console.info("cmdline", "{s}", .{bi.cmdlineSlice()});

    const h = heap.stats();
    console.debug("heap", "slab ok, {d} frame(s) held", .{h.frames});

    selfTestSyscalls();

    platform.earlyDevices(bi);
    platform.probeHardware(bi);

    if (lib.cmdline.has(bi.cmdlineSlice(), "panictest")) {
        // Paging is on, but nothing unmapped is easy to name; an invalid opcode
        // is the reliable way to exercise the exception path.
        asm volatile ("ud2");
    }

    startThreads();

    // Idle rather than spin: QEMU should not burn a host core, and the real
    // machine should not cook itself.
    while (true) hal.idle();
}

/// Say whether the last boot ended in a fault.
///
/// Shown whatever the verbosity: a machine that crashed and restarted is news
/// even on a quiet boot, and it is the one thing a person needs to be told
/// without having asked. The record goes into the kernel log with it, so the
/// detail is there for `log` after the line has scrolled away.
fn reportPreviousPanic() void {
    var buf: [panicring.CAPACITY]u8 = undefined;
    const previous = panicring.take(&buf) orelse return;

    console.warn("the last boot ended in a fault (panic {d} on this machine)", .{previous.sequence});
    console.field("panic", "{s}", .{previous.text});
}

/// A boot-time sanity check on the allocator. Cheap, and it fails loudly here
/// rather than subtly inside the first driver that allocates.
fn selfTestHeap() void {
    const a = heap.allocator;
    const before = heap.stats();

    const small = a.alloc(u8, 24) catch {
        console.fail("heap: small allocation failed", .{});
        return;
    };
    @memset(small, 0xA5);

    var list: std.ArrayList(u32) = .empty;
    list.appendSlice(a, &.{ 1, 2, 3, 4, 5 }) catch {
        console.fail("heap: ArrayList growth failed", .{});
        return;
    };

    const big = a.alloc(u8, 9000) catch {
        console.fail("heap: multi-frame allocation failed", .{});
        return;
    };
    @memset(big, 0x5A);

    // The allocations must not have disturbed each other.
    const intact = small[0] == 0xA5 and small[23] == 0xA5 and
        big[0] == 0x5A and big[8999] == 0x5A and
        list.items.len == 5 and list.items[4] == 5;

    a.free(big);
    list.deinit(a);
    a.free(small);

    const after = heap.stats();
    if (!intact) {
        console.fail("heap: allocations corrupted each other", .{});
    } else if (after.live_bytes != before.live_bytes) {
        console.fail("heap: leaked {d} bytes", .{after.live_bytes - before.live_bytes});
    }
}

/// Exercise the syscall path from kernel mode, before any user process exists.
/// Confirms the trap gate, the dispatcher, argument passing and error returns
/// all line up.
fn selfTestSyscalls() void {
    // Looked up by name at compile time rather than written as numbers: a
    // renumbered table would make these silently test the wrong calls.
    const SYS_WRITE = syscall_abi.number("write");
    const SYS_CLOCK = syscall_abi.number("clock_us");
    const SYS_UNKNOWN = 9999;

    const text = "";
    const wrote = hal.invokeSyscall(SYS_WRITE, syscall_abi.STDOUT, @intFromPtr(text.ptr), text.len);
    const null_ptr = hal.invokeSyscall(SYS_WRITE, syscall_abi.STDOUT, 0, 8);
    const unknown = hal.invokeSyscall(SYS_UNKNOWN, 0, 0, 0);

    var now: u64 = 0;
    const clock = hal.invokeSyscall(SYS_CLOCK, @intFromPtr(&now), 0, 0);

    const expect_fault = syscall_abi.Errno.fault.value();
    const expect_nosys = syscall_abi.Errno.nosys.value();

    if (wrote != 0 or null_ptr != expect_fault or unknown != expect_nosys or clock != 0) {
        console.fail("syscall abi: write={d} fault={d} nosys={d} clock={d}", .{
            wrote, null_ptr, unknown, clock,
        });
        return;
    }

    console.debug("sys", "{d} calls, abi ok", .{syscall_abi.table.len});

    // Prove the clock advances rather than printing a possibly-frozen counter:
    // a stopped timer is the kind of fault that stays invisible until the
    // scheduler mysteriously never preempts anything.
    const t0 = now;
    var spins: u32 = 0;
    while (hal.monotonicMicros() == t0 and spins < 5_000_000) : (spins += 1) {}
    const t1 = hal.monotonicMicros();
    if (t1 > t0) {
        console.debug("time", "{s}, advancing ({d} us)", .{ hal.timerSourceName(), t1 });
    } else {
        console.fail("time: {s} is not advancing; preemption will not work", .{hal.timerSourceName()});
    }
}

// ---------------------------------------------------------------------------
// Scheduler bring-up
// ---------------------------------------------------------------------------

/// Counters the worker threads bump, so the test can tell interleaving from
/// one thread monopolising the CPU.
var worker_counts: [3]u32 = @splat(0);

/// A deliberately uncooperative thread: it never yields, never sleeps and never
/// blocks. If these interleave, preemption is genuinely working, a cooperative
/// scheduler would show the first one running to completion.
fn spinWorker(index: usize) callconv(.c) void {
    var spins: u32 = 0;
    while (spins < 4_000_000) : (spins += 1) {
        if (spins % 500_000 == 0) {
            worker_counts[index] = @atomicLoad(u32, &worker_counts[index], .monotonic) + 1;
        }
    }
}

/// Reports the outcome once the workers have had time to run, then leaves the
/// system idling.
/// Process 1. Everything else in userspace descends from it.
fn userThread(_: usize) callconv(.c) void {
    platform.enterUserMode("/bin/init", &.{"init"});
}

fn supervisor(_: usize) callconv(.c) void {
    sched.sleepMicros(300_000);

    const c = worker_counts;
    const st = sched.stats();

    // Every worker must have made progress. One worker at zero means it never
    // got the CPU, which is the failure preemption is supposed to prevent.
    const all_ran = c[0] > 0 and c[1] > 0 and c[2] > 0;
    if (all_ran and st.switches > 3) {
        console.debug("sched", "{d} threads, {d} switches, workers {d}/{d}/{d}", .{
            st.threads, st.switches, c[0], c[1], c[2],
        });
    } else {
        console.fail("sched: no preemption (switches={d} workers {d}/{d}/{d})", .{
            st.switches, c[0], c[1], c[2],
        });
    }

    selfTestIpc();
    selfTestPipe();

    // Kernel bring-up is over; the screen belongs to userspace from here.
    //
    // Not cleared in verbose mode: on a machine with no serial port the boot
    // log is only on screen, and wiping it would destroy the diagnostics
    // verbose mode exists to show. On a quiet boot the banner is redrawn after
    // the clear, so the screen userspace inherits still says what it is.
    if (!console.isVerbose()) {
        console.clear();
        banner();
    }

    // Everything the kernel has to say is said before userspace starts.
    //
    // The console belongs to whoever is using it, and from the next line that
    // is the shell. Reporting afterwards scrolled the shell's first prompt off
    // the top, which looked like a machine that had booted to nothing until
    // Enter was pressed and it drew another.
    bcache.report();

    if (console.isVerbose()) {
        console.putChar('\n');
        console.setColor(.light_green, .black);
        console.writeString("kernel ready, starting userspace\n");
        console.setColor(.light_grey, .black);
        console.putChar('\n');
    }

    _ = sched.spawn("init", .normal, userThread, 0, 16384) catch {
        console.fail("sched: cannot spawn user thread", .{});
        return;
    };
}

/// A pipe carries bytes, and reports end of file once its writer is gone.
///
/// Checked at boot because everything that uses one blocks on it: a pipe that
/// silently never becomes readable is a terminal emulator that hangs with no
/// output, which is a much harder thing to read than a failed line here.
fn selfTestPipe() void {
    const p = pipe.create() catch {
        console.fail("pipe: cannot create", .{});
        return;
    };
    // Two references, one per end, which is what `create` hands out.
    defer pipe.release(p, false);

    const sent = "vibeee";
    _ = p.write(sent) catch {
        console.fail("pipe: write failed", .{});
        pipe.release(p, true);
        return;
    };

    var buf: [16]u8 = undefined;
    const n = p.read(&buf) catch {
        console.fail("pipe: read failed", .{});
        pipe.release(p, true);
        return;
    };

    if (!std.mem.eql(u8, buf[0..n], sent)) {
        console.fail("pipe: read back '{s}', not '{s}'", .{ buf[0..n], sent });
        pipe.release(p, true);
        return;
    }

    // Closing the write end has to turn a blocking read into end of file, or
    // every reader of a finished program waits forever.
    pipe.release(p, true);
    const eof = p.read(&buf) catch {
        console.fail("pipe: read after the writer closed failed", .{});
        return;
    };
    if (eof != 0) {
        console.fail("pipe: expected end of file, got {d} bytes", .{eof});
        return;
    }

    console.debug("pipe", "{d} bytes through, end of file on close", .{n});
}

// ---------------------------------------------------------------------------
// IPC self-test
//
// Exercised at boot for the same reason the heap and the clock are: a broken
// blocking primitive does not announce itself, it just makes something later
// hang, and on a machine with no serial port a hang is the least diagnosable
// failure there is. This proves a thread can block and be woken, that a
// registered service can be found by name, and that a call reaches a server
// and its reply comes back.
// ---------------------------------------------------------------------------

const IPC_SERVICE = "echo.test";

var ipc_server_ready: event.Event = .{};

fn ipcServer(_: usize) callconv(.c) void {
    const ch = channel.create() catch return;
    svc.register(IPC_SERVICE, ch) catch {
        channel.release(ch);
        return;
    };
    // Published before anyone is told to look: a client that connects between
    // create and register would get ENOENT and fail a working system.
    ipc_server_ready.signal();

    // One request is all the test needs; a real server loops here forever.
    const got = channel.recv(ch, null) catch {
        svc.unregister(IPC_SERVICE);
        channel.release(ch);
        return;
    };

    var answer: [channel.MAX_PAYLOAD]u8 = undefined;
    const n = got.message.len;
    // Reversed, so a reply that merely echoes the request buffer back by
    // accident is not mistaken for one that made the round trip.
    for (0..n) |i| answer[i] = got.message.data[n - 1 - i];
    channel.reply(ch, got.token, answer[0..n], &.{}) catch {};

    svc.unregister(IPC_SERVICE);
    channel.release(ch);
}

fn selfTestIpc() void {
    // Events first: everything below blocks, and if blocking is broken this is
    // the last line that will ever print.
    var e: event.Event = .{};
    e.signal();
    e.waitOne(null) catch {
        console.fail("ipc: a signalled event did not release its waiter", .{});
        return;
    };

    _ = sched.spawn("echo.test", .normal, ipcServer, 0, 8192) catch {
        console.fail("ipc: cannot spawn the test server", .{});
        return;
    };

    // Blocking, not polling: this is the primitive under test.
    ipc_server_ready.waitOne(sched.deadlineIn(1_000_000)) catch {
        console.fail("ipc: the test server never registered", .{});
        return;
    };

    const ch = svc.lookup(IPC_SERVICE) catch {
        console.fail("ipc: {s} is registered but cannot be found", .{IPC_SERVICE});
        return;
    };
    defer channel.release(ch);

    var reply: channel.Message = .{};
    channel.call(ch, "vibeee", &.{}, &reply, sched.deadlineIn(1_000_000)) catch |err| {
        console.fail("ipc: call failed: {s}", .{@errorName(err)});
        return;
    };

    if (!std.mem.eql(u8, reply.slice(), "eeebiv")) {
        console.fail("ipc: reply was '{s}', expected 'eeebiv'", .{reply.slice()});
        return;
    }

    console.debug("ipc", "channels, events and /svc ok", .{});
}

fn startThreads() void {
    for (0..worker_counts.len) |i| {
        _ = sched.spawn("worker", .normal, spinWorker, i, 8192) catch {
            console.fail("sched: cannot spawn worker {d}", .{i});
            return;
        };
    }
    _ = sched.spawn("supervisor", .interactive, supervisor, 0, 16384) catch {
        console.fail("sched: cannot spawn supervisor", .{});
        return;
    };

    sched.start() catch {
        console.fail("sched: start failed", .{});
        return;
    };
}

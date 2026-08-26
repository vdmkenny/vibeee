//! vibeee kernel entry.
//!
//! Both boot paths converge here with a BootInfo already built: the SD-card
//! path via boot/stage2, and `qemu -kernel` / GRUB via arch/x86/multiboot.zig.
//! Nothing below this line knows which one ran.

const std = @import("std");
const builtin = @import("builtin");

const bootinfo = @import("bootinfo.zig");
const console = @import("console.zig");
const hal = @import("hal.zig");
const panic_mod = @import("panic.zig");
const pmm = @import("pmm.zig");
const heap = @import("heap.zig");
const bcache = @import("bcache.zig");
const sched = @import("sched.zig");
const syscall_abi = @import("syscall_table.zig");
const platform = @import("../platform.zig");

pub const panic = std.debug.FullPanic(panic_mod.kpanic);

pub const VERSION = "0.1.0-M0";

/// Kernel stack for the boot thread. Threads get their own once the scheduler
/// exists; until then this is also what the TSS esp0 points at.
var kernel_stack: [32 * 1024]u8 align(16) = undefined;

pub fn kmain(bi: *bootinfo.BootInfo) noreturn {
    console.init();

    console.setColor(.light_cyan, .black);
    console.printf("vibeee {s}", .{VERSION});
    console.setColor(.dark_grey, .black);
    console.printf("  {s}\n\n", .{@tagName(builtin.cpu.arch)});
    console.setColor(.light_grey, .black);

    if (bi.magic != bootinfo.MAGIC or bi.version != bootinfo.VERSION) {
        console.fail("bootinfo mismatch (magic {x}, v{d}); rebuild image", .{ bi.magic, bi.version });
        hal.halt();
    }

    console.setVerbose(std.mem.indexOf(u8, bi.cmdlineSlice(), "verbose") != null);
    platform.earlyConsole();

    // Before anything is drawn: in graphics mode the text buffer is no longer
    // displayed, so output written first would vanish.
    _ = console.useFramebuffer(bi);
    platform.reportVideo();

    // stage2 has no serial port to log to, so it logs to a RAM ring. Replay it
    // only when it has something to say.
    if (bi.log_phys != 0 and bi.log_len != 0) {
        const ptr: [*]const u8 = @ptrFromInt(bi.log_phys);
        console.writeString(ptr[0..@min(bi.log_len, 8192)]);
    }

    hal.initCpu(@intFromPtr(&kernel_stack) + kernel_stack.len);
    hal.initInterruptController();
    hal.initSyscalls();
    hal.initTimer();
    // Everything the tick handler touches is initialised, so interrupts can be
    // taken from here on.
    hal.enableInterrupts();

    const cpu_info = hal.cpuInfo();
    console.debug("cpu", "{s}", .{cpu_info.brand});
    console.debug("", "{s}{s}", .{
        if (cpu_info.fast_syscall) "sysenter" else "int80",
        if (cpu_info.freq_scaling) ", freq scaling" else ", fixed clock",
    });

    pmm.init(bi);
    const m = pmm.stats();
    console.debug("mem", "{d}M usable, {d}M free, {d} frames", .{
        m.totalBytes() / (1024 * 1024),
        m.freeBytes() / (1024 * 1024),
        m.total_frames,
    });

    // The identity mapping existed only to survive the instant paging came on.
    // Dropping it hands the whole low 3 GiB to user space.
    hal.dropBootIdentityMapping();

    heap.init();
    selfTestHeap();

    console.debug("boot", "{s}", .{switch (bi.source) {
        .stage2 => "sd",
        .multiboot => "multiboot",
    }});

    if (bi.rsdp != 0) {
        console.debug("acpi", "rsdp {x:0>8}", .{bi.rsdp});
    } else {
        console.warn("no acpi rsdp; battery, hotkeys, backlight unavailable", .{});
    }

    if (bi.cmdline_len > 0) console.debug("cmdline", "{s}", .{bi.cmdlineSlice()});

    const h = heap.stats();
    console.debug("heap", "slab ok, {d} frame(s) held", .{h.frames});

    selfTestSyscalls();

    platform.earlyDevices(bi);
    platform.probeHardware(bi);

    if (std.mem.indexOf(u8, bi.cmdlineSlice(), "panictest") != null) {
        // Paging is on, but nothing unmapped is easy to name; an invalid opcode
        // is the reliable way to exercise the exception path.
        asm volatile ("ud2");
    }

    startThreads();

    // Idle rather than spin: QEMU should not burn a host core, and the real
    // machine should not cook itself.
    while (true) hal.idle();
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
    const SYS_WRITE = 1;
    const SYS_CLOCK = 5;
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
/// blocks. If these interleave, preemption is genuinely working — a cooperative
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
fn userThread(_: usize) callconv(.c) void {
    platform.enterUserMode();
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

    // Kernel bring-up is over; the screen belongs to userspace from here.
    //
    // Not cleared in verbose mode: on a machine with no serial port the boot
    // log is only on screen, and wiping it would destroy the diagnostics
    // verbose mode exists to show.
    if (!console.isVerbose()) console.clear();

    _ = sched.spawn("user", .normal, userThread, 0, 16384) catch {
        console.fail("sched: cannot spawn user thread", .{});
        return;
    };
    sched.sleepMicros(200_000);

    bcache.report();

    if (console.isVerbose()) {
        console.putChar('\n');
        console.setColor(.light_green, .black);
        console.writeString("ready\n");
        console.setColor(.light_grey, .black);
    }
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

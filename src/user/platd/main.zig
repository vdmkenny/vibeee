//! platd: the firmware's own account of this machine.
//!
//! Everything the BIOS and the embedded controller still own after boot is
//! described in tables the firmware left behind, and most of that description
//! is bytecode rather than data: which pin turns the radio off, what the
//! battery registers mean, what has to happen before the machine may sleep.
//! None of it can be worked out from outside, and a table of offsets copied
//! from a forum post is a way to turn off a power rail that should have stayed
//! on. So it is interpreted, by [uACPI](../../../third_party/uacpi/).
//!
//! In a process rather than in the kernel, holding the driver capability and
//! nothing else. This is bytecode from a 2007 AMI BIOS whose job is to poke
//! hardware; if it goes wrong it should take a restartable server with it and
//! not the machine.

const glue = @import("glue.zig");
const log = @import("ulib").log;
const out = @import("ulib").out;
const str = @import("ulib").str;
const sys = @import("sys");

/// uACPI's own entry points. The rest of it reaches back through `glue`.
extern fn uacpi_initialize(flags: u64) c_uint;
extern fn uacpi_namespace_load() c_uint;
extern fn uacpi_namespace_initialize() c_uint;
extern fn uacpi_status_to_string(status: c_uint) [*:0]const u8;
extern fn uacpi_prepare_for_sleep_state(state: c_uint) c_uint;
extern fn uacpi_enter_sleep_state(state: c_uint) c_uint;
extern fn uacpi_reboot() c_uint;
extern fn uacpi_finalize_gpe_initialization() c_uint;
extern fn uacpi_context_set_loop_timeout(seconds: u32) void;

/// uACPI numbers the sleep states from S0.
const S5: c_uint = 5;

const OK: c_uint = 0;

comptime {
    // Nothing calls into `glue` from Zig: uACPI links against it. Naming it
    // here is what puts it in the program.
    _ = glue;
}

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ xorl %ebp, %ebp
        \\ call platdMain
        \\ hlt
    );
}

export fn platdMain() callconv(.c) noreturn {
    // Before the firmware is touched, for two reasons. init waits for this
    // name, so the rest of the boot proceeds as soon as it is there. And uACPI
    // takes a handle for every synchronisation object the firmware's tables
    // ask for, so the one handle this service cannot do without is claimed
    // while the table is empty.
    const channel = sys.svcRegister(proto.SERVICE);
    if (channel < 0) {
        log.failed("platd", "cannot register", channel);
        sys.exit(1);
    }

    // A machine whose firmware will not come up is still a machine. Whatever
    // failed here is answered with a refusal rather than with an absent
    // service: the shell, the disk and everything that does not go through the
    // BIOS are unaffected by it and should not be made to wait for it.
    ready = bringUp();
    if (!ready) log.warn("platd", "carrying on without the firmware");

    serve(@intCast(channel));
}

/// Whether the firmware answered at all.
///
/// Everything below goes through an interpreter that may not have started, and
/// calling into one that did not is a fault rather than a refusal.
var ready = false;

/// Two things to listen to: somebody asking, and the firmware saying.
///
/// The system control interrupt is a line the kernel turns into an event, and
/// the handler uACPI installed runs here rather than in interrupt context: an
/// AML method can take milliseconds and there is one thread to run it on.
fn serve(channel: u32) noreturn {
    var sources: [3]u32 = undefined;

    while (true) {
        drain(channel);
        if (glue.sci.attached()) glue.sci.service();

        // What the interrupt queued, and then what the firmware said. Both
        // run here and not in the handler: they are AML, and the handler runs
        // inside the interpreter that would have to be entered.
        work.drain();
        hotkey.apply();

        var count: usize = 1;
        sources[0] = channel;
        if (glue.sci.attached()) {
            sources[count] = glue.sci.event;
            count += 1;
        }
        if (work.event != 0) {
            sources[count] = work.event;
            count += 1;
        }
        _ = sys.waitMany(sources[0..count], sys.FOREVER);
    }
}

fn drain(channel: u32) void {
    while (true) {
        var message = sys.Message{};
        const request = sys.recv(channel, &message, sys.POLL) orelse return;

        // Built as a message rather than a payload, because one of these
        // answers with a handle and the rest would otherwise need a second
        // way out of here.
        var reply = sys.Message{};

        var body = proto.Rep{};
        body.status = answer(&message, &body, &reply);

        @memcpy(reply.data[0..@sizeOf(proto.Rep)], std.mem.asBytes(&body));
        reply.len = @sizeOf(proto.Rep);

        _ = sys.replyMsg(channel, request.token, &reply);
    }
}

fn answer(message: *const sys.Message, body: *proto.Rep, reply: *sys.Message) proto.Status {
    const bytes = message.bytes();
    if (bytes.len < @sizeOf(proto.Req)) return .unknown;

    const request: *const proto.Req = @alignCast(@ptrCast(bytes.ptr));

    // Everything here is the firmware's to answer, so with no firmware there
    // is nothing to say but no.
    if (!ready) return .refused;

    return switch (request.tag) {
        .power_off => powerOff(),
        .reboot => restart(),
        .battery => battery.read(&body.body.battery),
        .device => namespace.describe(request.index, &body.body.device),
        .child => namespace.describeChild(&request.name, request.index, &body.body.device),
        .backlight => backlight.read(&body.body.backlight),
        .backlight_set => backlight.write(request.index, &body.body.backlight),
        .hotkey => hotkey.take(&body.body.press),
        .hotkey_watch => hotkey.subscribe(reply),
    };
}

/// Off, through the firmware's own account of what that means.
///
/// `_PTS` first, which is the BIOS doing its own bookkeeping and the step a
/// hand-written sequence has no way to perform: without it an AMI machine of
/// this age takes the sleep request and ignores it. Then the `_S5_` package,
/// evaluated rather than pattern-matched out of the raw table.
///
/// The kernel is asked to quiesce first, because flushing is the half only it
/// can do and there is no coming back from the half after.
fn powerOff() proto.Status {
    if (sys.quiesce() < 0) return .refused;

    if (uacpi_prepare_for_sleep_state(S5) != OK) return .refused;
    if (uacpi_enter_sleep_state(S5) != OK) return .refused;

    // Reached only if the firmware took the request and did nothing, which is
    // news: it is what the pattern-matched path did every time.
    return .refused;
}

fn restart() proto.Status {
    if (sys.quiesce() < 0) return .refused;
    if (uacpi_reboot() != OK) return .refused;
    return .refused;
}

const backlight = @import("backlight.zig");
const battery = @import("battery.zig");
const ec = @import("ec.zig");
const hotkey = @import("hotkey.zig");
const namespace = @import("namespace.zig");
const uacpi = @import("uacpi.zig");
const work = @import("work.zig");
const proto = @import("proto").platform;
const std = @import("std");

/// Read the tables and make the namespace usable.
///
/// Three steps in the order uACPI asks for them: the tables themselves, the
/// namespace built from them, and then the `_INI` methods that let the
/// firmware set itself up now that somebody is listening.
fn bringUp() bool {
    work.init();

    // A While loop in AML is firmware code with no supervisor. The interpreter
    // aborts one that outlives this bound, so a controller that stops
    // answering costs a refused method rather than the machine.
    uacpi_context_set_loop_timeout(LOOP_TIMEOUT_S);

    if (!step("tables", uacpi_initialize(0))) return false;
    reportGlobalLock();
    if (!step("namespace", uacpi_namespace_load())) return false;

    // Before the namespace is initialised, so `_INI` methods already run with
    // a driven controller. Half of this machine is behind it.
    ec.bind();

    if (!step("devices", uacpi_namespace_initialize())) return false;

    // The general-purpose events, which is what the system control interrupt
    // carries. Finalised before the line is made live, because a handler that
    // has not been told about a GPE cannot clear the one that fired and the
    // interrupt simply arrives again.
    //
    // Left off entirely when there is a controller nobody drives: its event
    // fires with nobody able to drain the query queue behind it, and a line
    // that cannot be quieted is a machine that does nothing else.
    if (ec.present() and !ec.driven()) {
        log.warn("platd", "events stay off; the embedded controller is not driven");
    } else {
        _ = step("events", uacpi_finalize_gpe_initialization());
        ec.listen();
    }

    // Before anything is evaluated, and this is the whole of why it is here.
    // The global lock is held by the firmware and released by it raising the
    // system control interrupt, so a method that takes the lock while nothing
    // is listening waits for a release that cannot arrive and fails after
    // sixty-five thousand attempts that all resolve in microseconds.
    if (glue.sci.arm()) {
        log.note("platd", "system control interrupt live");
    } else {
        log.warn("platd", "no system control interrupt; the global lock cannot be waited on");
    }

    // Only now, because both of these call methods.
    backlight.report();
    hotkey.listen();

    log.note("platd", "firmware ready");
    return true;
}

/// Seconds an AML loop may run before the interpreter gives up on it.
const LOOP_TIMEOUT_S = 5;

/// Say so when the global lock is held at start-up.
///
/// Every method that takes it waits for a release the firmware signals through
/// the system control interrupt, so a lock that is already owned is the reason
/// those methods fail and is not visible from anywhere else.
fn reportGlobalLock() void {
    const value = uacpi.globalLock() orelse {
        log.note("platd", "no global lock; nothing has to wait for one");
        return;
    };

    log.begin("platd", if (value.owned()) .warn else .key);
    out.text("FACS 0x");
    out.hex(value.facs, 8);
    out.text(" global lock 0x");
    out.hex(value.value, 8);
    out.text(if (value.owned()) ", held by the firmware" else ", free");
    log.end();
}

fn step(what: []const u8, status: c_uint) bool {
    if (status == OK) return true;

    log.begin("platd", .bad);
    out.text(what);
    out.text(": ");
    out.text(str.span(uacpi_status_to_string(status)));
    log.end();
    return false;
}

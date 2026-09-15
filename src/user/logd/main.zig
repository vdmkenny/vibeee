//! logd: the machine's own account of itself, out of a serial port.
//!
//! This machine has no serial port of its own. That one fact shapes how it
//! is debugged more than anything else: what it says is read off a
//! photograph of the screen, or out of the record afterwards with `log`,
//! and a fault that takes the screen with it leaves neither. A USB serial
//! adapter gives the machine one, and this is what puts the record down
//! it: everything the kernel and the services say, as they say it, on
//! another machine where it can be scrolled and searched.
//!
//! What it cannot cover is the boot before the bus is up, which is the one
//! part a serial port on the chip would have carried. A machine that dies
//! before `usbd` finds the adapter still says nothing down the wire, and
//! the panic ring is what that leaves behind.
//!
//! Nothing polls and nothing asks twice. The kernel signals an event when
//! the record grows, the settings service signals one when the port is
//! named or renamed, the bus service signals one when a port is offered or
//! taken away, and the port itself signals one when it has room for more.
//!
//! A machine with no port named waits on the settings alone: it is not
//! woken by the record growing, because there would be nowhere to put what
//! it gained. A machine whose named port is not plugged in waits on the
//! ports. Either way the cost of having this running and unused is one
//! blocked process and no wakes at all.

const lib = @import("lib");
const log = @import("ulib").log;
const out = @import("ulib").out;
const proto = @import("proto");
const quit = @import("ulib").quit;
const serial = @import("ulib").serial;
const sys = @import("sys");

const store = proto.settings;

const NAME = "logd";

/// How much of the record to move in one go. A ring's worth is four
/// thousand and ninety-six bytes and this fills it in eight passes, which
/// keeps one pass short enough that a port taken away half way through
/// costs a fraction of a screen.
const CHUNK = 512;

var port: ?serial.Port = null;
/// How far down the record this has got. Kept across a port being taken
/// away and put back, so a reconnected adapter carries on rather than
/// repeating everything.
var cursor: sys.LogCursor = .{};

/// Which port the settings name, read when they change rather than on
/// every pass: a machine narrating a boot would otherwise ask the settings
/// service once a line for an answer that changes about once a year.
var wanted: store.Port = .{};

export fn _start() callconv(.c) noreturn {
    logdMain();
}

fn logdMain() noreturn {
    const grew = sys.logWatch() catch {
        log.fail(NAME, "the record cannot be followed");
        sys.exit(1);
    };
    const changed = store.watch("log") catch 0;
    const stop = quit.event();
    // Taken only when a port is wanted and missing, and given back once
    // one is open: a machine with a console already going has no reason
    // to hear about the table changing.
    var ports: ?serial.Watch = null;
    defer if (ports) |w| w.close();

    named();

    while (true) {
        settle(&ports);
        ship();
        out.flush();

        var sources: [5]u32 = undefined;
        var count: usize = 0;
        if (changed != 0) {
            sources[count] = changed;
            count += 1;
        }
        if (stop != 0) {
            sources[count] = stop;
            count += 1;
        }
        if (port) |*open| {
            // Somewhere to put what the record gains, so the record
            // growing is worth waking for; and room being made on a full
            // port is as much a reason as the record growing.
            sources[count] = grew;
            count += 1;
            sources[count] = open.waitHandle();
            count += 1;
        } else if (ports) |w| {
            sources[count] = w.event;
            count += 1;
        }

        const woke = sys.waitMany(sources[0..count], sys.FOREVER) catch continue;
        if (stop != 0 and sources[woke] == stop) leave();
        if (changed != 0 and sources[woke] == changed) named();
    }
}

/// Read which port the settings name. Only when they say they changed.
fn named() void {
    wanted = store.load("log").console;
}

fn leave() noreturn {
    if (port) |*open| open.close();
    sys.exit(0);
}

/// Match the port that is open to the one the settings name.
///
/// Every call is a comparison of a few bytes. A port is looked for only
/// when one is wanted and none is open, and then only on a pass that the
/// settings or the port table woke: a machine whose adapter is not plugged
/// in asks once when it is told the table changed, and not again.
fn settle(ports: *?serial.Watch) void {
    if (port) |*open| {
        // The adapter went, or somebody else took the port. Either way
        // what is on the other end is not this machine's record any more.
        if (open.ended() or !lib.str.eqlFold(open.info.nameSlice(), wanted.slice())) {
            open.close();
            port = null;
        }
    }

    if (wanted.isEmpty()) {
        // Nothing to carry anything to. The table is not worth hearing
        // about until somebody names a port.
        if (ports.*) |w| {
            w.close();
            ports.* = null;
        }
        return;
    }
    if (port != null) {
        if (ports.*) |w| {
            w.close();
            ports.* = null;
        }
        return;
    }

    if (ports.* == null) ports.* = serial.watch() catch null;

    const which = serial.named(wanted.slice()) catch return;
    port = serial.Port.open(which) catch return;

    log.begin(NAME, .key);
    out.text("the record is going out of ");
    out.text(wanted.slice());
    log.end();
}

/// Everything the record has gained, onto the port.
///
/// A port whose ring is full stops the pass rather than the service: the
/// cursor goes back to where the bytes that did not fit begin, and the
/// port's own event brings this back when there is room. Nothing is lost
/// and nothing waits inside a write.
fn ship() void {
    const open = if (port) |*p| p else return;

    while (true) {
        var chunk: [CHUNK]u8 = undefined;
        const n = sys.logRead(&cursor, &chunk) catch return;
        if (cursor.missed != 0) {
            // Said down the wire rather than only into the record, since
            // the record is the thing that lost it.
            _ = open.write("[the record moved on before this could read it]\r\n");
            cursor.missed = 0;
        }
        if (n == 0) return;

        var sent: usize = 0;
        while (sent < n) {
            const took = open.write(chunk[sent..n]);
            if (took == 0) break;
            sent += took;
        }
        if (sent < n) {
            // Back to where what did not fit begins. The far end is
            // slower than the machine is talkative, which is ordinary at
            // nine thousand six hundred baud.
            cursor.at -= @as(u64, n - sent);
            return;
        }
    }
}

comptime {
    _ = lib;
}

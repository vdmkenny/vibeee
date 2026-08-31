//! timed: what time it is, learned from the network.
//!
//! A netbook of this age has usually lost the battery that kept its clock, so
//! it wakes not knowing the date. Everything dated waits on this: a file's
//! timestamp, a lease's lifetime, and a certificate's validity, which cannot
//! be judged at all by a machine that thinks it is 1970.
//!
//! One question, asked of one server at a time until one answers, then again
//! an hour later. Nothing here polls: the wait is the socket's own event with
//! a deadline, so a machine that has the time costs nothing until the next
//! ask falls due.

const lib = @import("lib");
const proto = @import("proto");
const sys = @import("sys");
const log = @import("ulib").log;
const out = @import("ulib").out;
const sock = @import("ulib").sock;

const ntp = lib.ntp;
const store = proto.settings;

/// How long to wait for one server before trying the next. A public pool
/// answers in well under a second or is not going to.
const REPLY_TIMEOUT_US: usize = 3_000_000;

/// How long to wait before trying again when nobody answered. Shorter than
/// the settled interval, because a machine that does not know the time yet
/// wants it as soon as the network is up.
const RETRY_US: usize = 60_000_000;

var settings: store.Time = .{};

export fn _start() callconv(.c) noreturn {
    timedMain();
}

fn timedMain() noreturn {
    settings = store.load("time");

    // The settings service signals a change, so a server list edited with
    // `cfg` takes effect without a restart.
    const watch = store.watch("time") catch 0;

    while (true) {
        settings = store.load("time");

        const slept = if (settings.ntp) round() else RETRY_US;
        waitAWhile(watch, slept);
    }
}

/// Ask each server in turn until one answers. Returns how long to wait before
/// asking again.
fn round() usize {
    for ([_]store.Host{ settings.server1, settings.server2, settings.server3 }) |server| {
        if (server.isEmpty()) continue;
        if (ask(server.slice())) {
            const minutes: usize = @max(settings.every_minutes, 1);
            return minutes * 60 * 1_000_000;
        }
    }

    log.warn("timed", "no time server answered");
    return RETRY_US;
}

/// One exchange with one server.
fn ask(name: []const u8) bool {
    const address = sock.resolve(name) catch return false;

    const s = sock.Sock.udp(address.addr, ntp.PORT, 0) catch return false;
    defer s.close();

    const question = ntp.Packet.request();
    if (!s.sendDatagram(address.addr, ntp.PORT, question.bytes())) return false;

    var buf: [128]u8 = @splat(0);
    var one: [1]u32 = .{s.waitHandle()};
    if (sys.waitMany(&one, REPLY_TIMEOUT_US) < 0) return false;

    const answer = s.recvDatagram(&buf) orelse return false;
    // Only the server we asked, and only from the port we asked on: an
    // answer from anywhere else is somebody else's, or somebody guessing.
    if (answer.addr != address.addr or answer.port != ntp.PORT) return false;

    const epoch_us = ntp.timeFrom(buf[0..@min(answer.len, buf.len)]) catch |refusal| {
        log.begin("timed", .warn);
        out.text(name);
        out.text(": ");
        out.text(ntp.why(refusal));
        log.end();
        return false;
    };

    if (!sys.setRealtimeMicros(epoch_us, "ntp")) {
        log.warn("timed", "the kernel would not take the time");
        return false;
    }

    say(name, epoch_us);
    return true;
}

fn say(name: []const u8, epoch_us: i64) void {
    const when = lib.civil.fromEpoch(@divFloor(epoch_us, 1_000_000));
    log.begin("timed", .key);
    out.decimal(@intCast(when.year));
    out.byte('-');
    twoDigits(when.month);
    out.byte('-');
    twoDigits(when.day);
    out.byte(' ');
    twoDigits(when.hour);
    out.byte(':');
    twoDigits(when.minute);
    out.byte(':');
    twoDigits(when.second);
    out.text(" UTC from ");
    out.text(name);
    log.end();
}

fn twoDigits(value: anytype) void {
    const n: usize = @intCast(value);
    if (n < 10) out.byte('0');
    out.decimal(n);
}

/// Sleep until the next ask falls due, or until somebody edits the settings.
fn waitAWhile(watch: u32, micros: usize) void {
    var sources: [1]u32 = .{watch};
    if (watch == 0) {
        sys.sleepMicros(@intCast(micros));
        return;
    }
    _ = sys.waitMany(&sources, micros);
}

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
//!
//! Nothing is asked before there is an address to ask from. A name looked up
//! over a network that has not arrived is a question nobody will ever answer,
//! so this waits on the stack's own event and asks the moment a lease lands.

const lib = @import("lib");
const proto = @import("proto");
const sys = @import("sys");
const log = @import("ulib").log;
const out = @import("ulib").out;
const sock = @import("ulib").sock;

const net = proto.net;
const ntp = lib.ntp;
const store = proto.settings;

/// How long to wait for one server before trying the next. A public pool
/// answers in well under a second or is not going to.
const REPLY_TIMEOUT_US: usize = 3_000_000;

/// How long to wait before trying again when nobody answered. Shorter than
/// the settled interval, because a machine that does not know the time yet
/// wants it as soon as the network is up.
const RETRY_US: usize = 60_000_000;

/// How long to wait with no address. The stack's event is what actually wakes
/// this; the deadline only covers the case where netd came up second and
/// there was no event to hold on to yet.
const NO_ADDRESS_US: usize = 15_000_000;

var settings: store.Time = .{};

export fn _start() callconv(.c) noreturn {
    timedMain();
}

fn timedMain() noreturn {
    settings = store.load("time");

    // The settings service signals a change, so a server list edited with
    // `cfg` takes effect without a restart.
    const watch = store.watch("time") catch 0;

    // The stack signals this when an interface gains or loses an address.
    // Taken again while it is missing, because netd may still have been
    // starting when this asked the first time.
    var link: u32 = net.watch() catch 0;

    while (true) {
        settings = store.load("time");
        if (link == 0) link = net.watch() catch 0;

        const slept = if (!settings.ntp)
            RETRY_US
        else if (net.haveAddress())
            round()
        else
            NO_ADDRESS_US;

        waitAWhile(&.{ watch, link }, slept);
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

    const s = sock.Sock.udp(address.addr, ntp.PORT, 0) catch {
        log.warn("timed", "no socket");
        return false;
    };
    defer s.close();

    const question = ntp.Packet.request();
    if (!s.sendDatagram(address.addr, ntp.PORT, question.bytes())) {
        log.warn("timed", "send refused");
        return false;
    }

    // The socket's event carries every piece of news about it, the question
    // leaving among them, so waking is not the same as being answered. Wait
    // until the answer is actually there or the deadline passes.
    var buf: [128]u8 = @splat(0);
    const answer = waitForReply(s, address.addr, &buf) orelse return false;

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

/// The server's answer, or nothing by the deadline.
///
/// A datagram from anywhere else is somebody else's or somebody guessing, so
/// it is dropped and the wait goes on rather than counting as the answer.
fn waitForReply(s: sock.Sock, from: u32, buf: []u8) ?sock.Sock.Datagram {
    var one: [1]u32 = .{s.waitHandle()};
    const deadline = sys.clockMicros() + REPLY_TIMEOUT_US;

    while (true) {
        while (s.recvDatagram(buf)) |answer| {
            if (answer.addr == from and answer.port == ntp.PORT) return answer;
        }

        const now = sys.clockMicros();
        if (now >= deadline) {
            log.warn("timed", "no reply in time");
            return null;
        }
        _ = sys.waitMany(&one, @intCast(deadline - now));
    }
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

/// Sleep until the next ask falls due, or until something worth waking for
/// happens: the settings changed, or an address arrived.
fn waitAWhile(events: []const u32, micros: usize) void {
    var sources: [2]u32 = undefined;
    var count: usize = 0;
    for (events) |handle| {
        if (handle == 0) continue;
        sources[count] = handle;
        count += 1;
    }

    if (count == 0) {
        sys.sleepMicros(@intCast(micros));
        return;
    }
    _ = sys.waitMany(sources[0..count], micros);
}

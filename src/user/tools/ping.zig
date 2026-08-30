//! ping: one echo a second, answered or timed out.
//!
//! Each round is one call to the network service, which holds the reply
//! until the echo comes back or the deadline passes: the blocking is the
//! ping, so this tool is a loop and some arithmetic. The stack answers
//! incoming echoes on its own; this is only the asking half.

const lib = @import("lib");
const net = @import("proto").net;
const out = @import("ulib").out;
const str = @import("ulib").str;
const sys = @import("sys");

const ROUNDS_DEFAULT = 4;
const TIMEOUT_MS = 1000;

pub fn run(args: []const []const u8) void {
    var target: ?u32 = null;
    var rounds: usize = ROUNDS_DEFAULT;

    var at: usize = 0;
    while (at < args.len) : (at += 1) {
        if (str.eql(args[at], "-c") and at + 1 < args.len) {
            at += 1;
            rounds = @max(1, str.toUnsigned(args[at]));
        } else if (lib.ipv4.parse(args[at])) |addr| {
            target = addr;
        }
    }

    const addr = target orelse {
        say("ping: an address, dotted: ping 192.168.178.1 [-c count]\n");
        return;
    };

    var field: [15]u8 = @splat(0);
    out.text("pinging ");
    out.text(lib.ipv4.text(addr, &field));
    out.byte('\n');
    out.flush();

    var answered: usize = 0;
    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        const started = sys.clockMicros();
        var reply = net.Rep{};
        if (net.callWith(.ping, 0, addr, TIMEOUT_MS, &reply)) |_| {
            answered += 1;
            out.text("answer from ");
            out.text(lib.ipv4.text(addr, &field));
            out.text(": seq ");
            out.decimal(round + 1);
            out.text(", ");
            sayMicros(reply.body.rtt_us);
            out.byte('\n');
        } else |err| {
            out.text(switch (err) {
                error.TimedOut => "no answer\n",
                error.NoService => "ping: the network service is not answering\n",
                else => "ping: the service refused; is an interface up?\n",
            });
            if (err == error.NoService) {
                out.flush();
                return;
            }
        }
        out.flush();

        // One echo a second, whatever the round trip cost of this one was.
        if (round + 1 < rounds) {
            const spent = sys.clockMicros() - started;
            if (spent < 1_000_000) sys.sleepMicros(1_000_000 - @as(usize, @intCast(spent)));
        }
    }

    out.decimal(answered);
    out.text(" of ");
    out.decimal(rounds);
    out.text(" answered\n");
    out.flush();
}

fn sayMicros(us: u32) void {
    out.decimal(us / 1000);
    out.byte('.');
    const tenths = (us % 1000) / 100;
    out.decimal(tenths);
    out.text(" ms");
}

fn say(text: []const u8) void {
    out.text(text);
    out.flush();
}

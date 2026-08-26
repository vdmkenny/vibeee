//! ringtest: prove shared memory works between two processes.
//!
//! Everything the IPC design rests on, exercised end to end in one command:
//! a service registers a name, a client finds it, the server hands over a
//! shared-memory segment as a handle in a channel reply, the client maps that
//! handle at its own address and writes into a ring laid out by
//! `lib/ring.zig`, and the server reads the bytes back out of the same frames.
//!
//! It runs as two processes because that is the only way the claim means
//! anything. A single process mapping its own segment proves the allocator
//! works and nothing else: the interesting failures are a handle number that
//! means the wrong thing on the far side, frames freed when the first process
//! exits, and a ring whose indices only agree with themselves.
//!
//! The command re-spawns itself with an argument to get the second process,
//! which is also a small proof that detached spawn and `wait` behave.

const std = @import("std");
const ring = @import("lib").ring;
const sys = @import("sys");
const out = @import("ulib").out;
const str = @import("ulib").str;

const SERVICE = "ring.test";
const SELF = "/TOOLS";

/// One page for the header and one for the payload. Small on purpose: the
/// point is the sharing, not the throughput.
const SEGMENT_BYTES = 8192;
const RING_BYTES = 4096;

const GREETING = "shared memory, two processes, one ring";

pub fn run(args: []const []const u8) void {
    if (args.len > 0 and str.eql(args[0], "client")) {
        client();
        return;
    }
    server();
}

// ---------------------------------------------------------------------------
// Server
// ---------------------------------------------------------------------------

fn server() void {
    const service = sys.svcRegister(SERVICE);
    if (service < 0) {
        fail("cannot register the service");
        return;
    }
    defer _ = sys.close(@intCast(service));

    const segment = sys.shmCreate(SEGMENT_BYTES);
    if (segment < 0) {
        fail("cannot create a segment");
        return;
    }
    defer _ = sys.close(@intCast(segment));

    const base = sys.shmMap(@intCast(segment), .{ .writable = true }) orelse {
        fail("cannot map the segment");
        return;
    };

    // The header goes in the first page and the payload in the second, so the
    // two sides agree on the layout without exchanging anything but the
    // segment itself.
    const header: *volatile ring.Header = @ptrCast(@alignCast(base));
    const data = base[4096 .. 4096 + RING_BYTES];

    const r = ring.Ring.init(header, data) catch {
        fail("bad ring geometry");
        return;
    };

    // Registered and ready before the client exists, so there is no window in
    // which it can connect to a service that cannot answer.
    // argv[0] is the image name and argv[1] is the command: the multicall
    // binary dispatches on the second word, exactly as the shell invokes it.
    const child = sys.spawnDetached(SELF, &.{ "tools", "ringtest", "client" });
    if (child < 0) {
        fail("cannot start the client");
        return;
    }

    // Two calls: "get" collects the segment, "done" says the bytes are there.
    var handled: usize = 0;
    while (handled < 2) : (handled += 1) {
        var msg: sys.Message = .{};
        const request = sys.recv(@intCast(service), &msg, 3_000_000) orelse {
            fail("the client never called");
            return;
        };

        if (str.eql(msg.bytes(), "get")) {
            const reply = sys.Message.init("here", &.{@intCast(segment)});
            _ = sys.replyMsg(@intCast(service), request.token, &reply);
        } else {
            _ = sys.reply(@intCast(service), request.token, "ok");
        }
    }

    // Collected *before* reading, deliberately. Reaping a process destroys its
    // address space, and the frames behind this ring are mapped into it. If
    // teardown freed shared frames instead of merely unmapping them, the bytes
    // below would be gone or overwritten by whatever claimed them next. This
    // ordering is the test.
    _ = sys.wait(@intCast(child), sys.FOREVER);

    var buf: [128]u8 = @splat(0);
    const n = r.read(&buf);

    if (n == GREETING.len and str.eql(buf[0..n], GREETING)) {
        out.text("ringtest: ok, ");
        out.decimal(n);
        out.text(" bytes through shared memory from pid ");
        out.decimal(@intCast(child));
        out.byte('\n');
    } else {
        out.text("ringtest: FAILED, read ");
        out.decimal(n);
        out.text(" bytes: '");
        out.text(buf[0..n]);
        out.text("'\n");
    }
    out.flush();
}

// ---------------------------------------------------------------------------
// Client
// ---------------------------------------------------------------------------

fn client() void {
    const channel = sys.svcConnect(SERVICE);
    if (channel < 0) {
        fail("client: cannot find the service");
        return;
    }
    defer _ = sys.close(@intCast(channel));

    const request = sys.Message.init("get", &.{});
    var reply: sys.Message = .{};

    if (sys.callMsg(@intCast(channel), &request, &reply) < 0) {
        fail("client: the call failed");
        return;
    }
    if (reply.handle_count != 1) {
        fail("client: no segment came back");
        return;
    }

    // A different number from the server's, for the same frames. That
    // translation is the whole point of passing handles rather than integers.
    const segment = reply.handles[0];
    defer _ = sys.close(segment);

    const base = sys.shmMap(segment, .{ .writable = true }) orelse {
        fail("client: cannot map the segment");
        return;
    };

    const header: *volatile ring.Header = @ptrCast(@alignCast(base));
    const data = base[4096 .. 4096 + RING_BYTES];

    // Attach, not init: the server laid the ring out, and re-initialising it
    // here would reset the counters underneath the reader.
    const r = ring.Ring.attach(header, data) catch {
        fail("client: the ring header did not survive the trip");
        return;
    };

    _ = r.write(GREETING);
    _ = sys.call(@intCast(channel), "done", &.{});
}

fn fail(what: []const u8) void {
    out.text("ringtest: ");
    out.text(what);
    out.byte('\n');
    out.flush();
}

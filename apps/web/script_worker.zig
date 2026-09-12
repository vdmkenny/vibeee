//! script_worker: the process a page's scripts run in.
//!
//! The reader spawns this program for each committed navigation, sends it
//! the page as a `start`, and reads what it says back — see
//! `apps/web/script_host.zig`, which is the other end of that. It is the
//! only place a page's scripts run: what this program does with a page is
//! still nothing at all, though — it holds the channel and goes, and the
//! reader reads that as its scripts having stopped.
//!
//! The shape it is being built towards is design/13-script-worker.md. Today
//! the reader holds the network, the page, the layout and the window, and
//! QuickJS, the DOM bridge and lexbor's parse of the page share that address
//! space with them. A fault in any of the last three is not something the
//! engine can turn into a script exception, and reaches the kernel as a
//! fault: the reader dies. Nothing a page sends is worth that.
//!
//! So the three of them move here, and the reader keeps what a page must
//! not be able to lose. What a page can corrupt is then the only thing it
//! can kill, and a dead worker costs a page its scripts and nothing else.
//!
//! What this program is to own, from §4 of the design:
//!   - lexbor's parse of one page's markup,
//!   - the QuickJS runtime and its contexts,
//!   - the DOM bridge and the C glue under it,
//!   - what a script can see: timers, listeners, its `localStorage`.
//!
//! What it is to ask the reader for, rather than hold: fetching, the cookie
//! jar, history and settings. Those outlive the page and outlive this
//! process, and none of them may exist in only one place.
//!
//! Of §5, the messages, the shape is in `worker_proto.zig`, which this
//! program and the reader import alike, and the reader speaks them: what
//! this program does not yet do is listen.

const std = @import("std");
const sys = @import("sys");
const ulib = @import("ulib");

const out = ulib.out;

/// What this program and the reader say to each other, §5 of
/// design/13-script-worker.md: the same module the reader imports, so a
/// message written on one side is a message read on the other. Not spoken
/// yet — see below — but compiled here, which is what keeps the two halves
/// of it one protocol.
const worker_proto = @import("worker_proto");

// The answer this program will give when the reader tells it to stop:
// written and read in the compiler, so the module is as much a part of this
// program as the module is of the reader, and a frame that cannot make the
// round trip fails here rather than on a page.
comptime {
    var into: [worker_proto.HEADER_LEN + 2]u8 = undefined;
    const frame = worker_proto.encode(.{ .stopped = .{ .reason = .asked } }, &into) catch unreachable;
    const stopped = worker_proto.decode(frame) catch unreachable;
    std.debug.assert(stopped.tag() == .stopped);
    std.debug.assert(stopped.stopped.reason == .asked);
    std.debug.assert(stopped.direction() == .from_worker);
}

export fn _start(frame: [*]usize) callconv(.c) noreturn {
    _ = frame;

    // TODO(13): read `start` off the channel the reader hands over — stdin
    // and stdout, in `script_host_sys.zig` — and answer with `page`, per §5.
    // Until then there is no parse and no script: what is proven is the
    // build, the spawn, the frames crossing and the reader's end of them,
    // before any of the work in §9 step 2 moves across.
    //
    // The lifecycle of §6 is the reader's, in `script_host.zig`: one worker
    // per committed navigation, killed on the next, and a worker that dies
    // on start not started again for that page.
    //
    // Said on the stream failures go to, because a worker is not run by a
    // person from a shell and its output is not what it is for.
    out.trouble("script_worker: a stub; the page's scripts do not run in it yet\n");
    out.flush();
    sys.exit(0);
}

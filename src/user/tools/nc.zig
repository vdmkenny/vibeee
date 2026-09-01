//! nc: one conversation with the network, plainly.
//!
//! Connect somewhere or listen once, then carry bytes both ways: standard
//! input toward the peer, the peer onto standard output. Piped input flows
//! as it comes; at the console a line is sent when entered, Ctrl+C leaves,
//! Ctrl+D says nothing more will be typed. The first interactive proof
//! that the rings, the events and the stack compose.
//!
//!   nc <host> <port>       a stream to a host
//!   nc -l <port>           await one stream on a port
//!   nc -u <host> <port>    datagrams instead, each sent line one
//!   nc -u -l <port>        await datagrams; replies go to the last sender

const lib = @import("lib");
const out = @import("ulib").out;
const std = @import("std");
const sock = @import("ulib").sock;
const str = @import("ulib").str;
const sys = @import("sys");

pub fn run(args: []const []const u8) void {
    var listen = false;
    var datagrams = false;
    var positional: [2][]const u8 = undefined;
    var names: usize = 0;

    for (args) |arg| {
        if (std.mem.eql(u8, arg, "-l")) {
            listen = true;
        } else if (std.mem.eql(u8, arg, "-u")) {
            datagrams = true;
        } else if (names < positional.len) {
            positional[names] = arg;
            names += 1;
        }
    }

    // Listening names a port; connecting names a host and then a port.
    const wanted: usize = if (listen) 1 else 2;
    if (names < wanted) {
        say("usage: nc <host> <port> | nc -l <port>; -u for datagrams\n");
        return;
    }
    const port: u16 = @truncate(str.toUnsigned(positional[wanted - 1]));
    if (port == 0) {
        say("nc: that is not a port\n");
        return;
    }
    const addr: u32 = if (listen) 0 else addressOf(positional[0]) orelse return;

    if (datagrams) {
        const s = sock.Sock.udp(addr, port, if (listen) port else 0) catch |err| {
            return sayOpenFailure(err);
        };
        defer s.close();
        converse(&s, true);
        return;
    }

    if (listen) {
        const gate = sock.Listener.listen(port) catch |err| {
            return sayOpenFailure(err);
        };
        defer gate.close();

        // The wait is here rather than inside accept, so Ctrl+C can end a
        // listener nobody ever connects to.
        const stop = sys.watch(.stop);
        var doors: [2]u32 = .{ gate.waitHandle(), if (stop >= 0) @intCast(stop) else gate.waitHandle() };
        const woke = sys.waitMany(doors[0 .. if (stop >= 0) 2 else 1], sys.FOREVER);
        if (woke != 0) return;

        const s = gate.accept() catch |err| {
            return sayOpenFailure(err);
        };
        defer s.close();
        sayPeer("connection from ", s.peer_addr, s.peer_port);
        converse(&s, false);
        return;
    }

    const s = sock.Sock.connect(addr, port) catch |err| {
        return sayOpenFailure(err);
    };
    defer s.close();
    converse(&s, false);
}

/// A host argument to its address, or the failure said in this tool's voice.
fn addressOf(name: []const u8) ?u32 {
    return sock.addressOf(name) catch {
        out.text("nc: ");
        out.text(name);
        out.text(": name not known\n");
        out.flush();
        return null;
    };
}

// ---------------------------------------------------------------------------
// The conversation
// ---------------------------------------------------------------------------

/// Bytes both ways until a side finishes. Input is the console or a pipe;
/// the difference is who is waitable and how much arrives at once.
fn converse(s: *const sock.Sock, datagrams: bool) void {
    // A pipe's read end is waitable; the interactive console is not, and
    // its keystrokes are taken as key events instead. A ready answer
    // consumed the pipe's pending signal, so readiness travels into the
    // loop instead of being waited for again.
    const probe = sys.waitMany(&[_]u32{sys.STDIN}, sys.POLL);
    const console = probe == -@as(isize, @intFromEnum(sys.Errno.badf));

    if (console) {
        converseConsole(s, datagrams);
    } else {
        conversePiped(s, datagrams, probe >= 0);
    }
}

fn conversePiped(s: *const sock.Sock, datagrams: bool, stdin_ready: bool) void {
    const stop = sys.watch(.stop);
    var fed = true;

    if (stdin_ready) {
        if (!feed(s, datagrams)) fed = false;
        if (!pour(s, datagrams)) return;
    }

    while (true) {
        var sources: [3]u32 = .{
            s.waitHandle(),
            if (stop >= 0) @intCast(stop) else s.waitHandle(),
            sys.STDIN,
        };
        // The stop event only when it exists, standard input only while it
        // still feeds; the fixed order keeps the indices meaningful.
        const n: usize = if (fed) 3 else if (stop >= 0) 2 else 1;
        const woke = sys.waitMany(sources[0..n], sys.FOREVER);
        if (woke < 0) continue;

        if (woke == 1 and stop >= 0) return;
        if (woke == 2) {
            if (!feed(s, datagrams)) fed = false;
        }
        if (!pour(s, datagrams)) return;
        if (!fed and finished(s)) return;
    }
}

/// The console conversation: the keyboard is claimed, keystrokes arrive as
/// key events with the layout already applied, and this side does its own
/// echo. Ctrl+C is a key here, not the stop event, because a claimed
/// keyboard bypasses the line discipline entirely.
fn converseConsole(s: *const sock.Sock, datagrams: bool) void {
    const keys = sys.watch(.keys);
    if (keys < 0) {
        say("nc: no keyboard to read\n");
        return;
    }

    // The first read claims the keyboard: from here every key goes to this
    // process and wakes the keys event, instead of feeding the shell's
    // line discipline underneath the conversation.
    var events: [8]sys.KeyEvent = undefined;
    _ = sys.keyRead(&events, sys.POLL);

    var line: [512]u8 = undefined;
    var len: usize = 0;
    var typing = true;

    while (true) {
        var sources: [2]u32 = .{ s.waitHandle(), @intCast(keys) };
        const woke = sys.waitMany(sources[0 .. if (typing) 2 else 1], sys.FOREVER);
        if (woke < 0) continue;

        if (woke == 1) {
            for (sys.keyRead(&events, sys.POLL)) |event| {
                if (event.pressed == 0) continue;
                switch (handleKey(s, datagrams, event, &line, &len)) {
                    .keep_going => {},
                    .no_more_input => typing = false,
                    .leave => return,
                }
            }
        }
        if (!pour(s, datagrams)) return;
        if (!typing and finished(s)) return;
    }
}

const KeyOutcome = enum { keep_going, no_more_input, leave };

/// Where the last datagram came from: an unconnected socket answers there,
/// which is what listening and replying means for datagrams.
var last_sender: ?sock.Sock.Datagram = null;

/// One keystroke into the line, the line to the peer when entered.
fn handleKey(
    s: *const sock.Sock,
    datagrams: bool,
    event: sys.KeyEvent,
    line: *[512]u8,
    len: *usize,
) KeyOutcome {
    const CTRL_C = 3;
    const CTRL_D = 4;

    if (event.code == @intFromEnum(sys.KeyCode.backspace)) {
        if (len.* > 0) {
            len.* -= 1;
            out.text("\x08 \x08");
            out.flush();
        }
        return .keep_going;
    }

    switch (event.codepoint) {
        0 => return .keep_going,
        CTRL_C => return .leave,
        CTRL_D => return .no_more_input,
        '\n', '\r' => {
            out.byte('\n');
            out.flush();
            line[len.*] = '\n';
            const whole = line[0 .. len.* + 1];
            len.* = 0;
            if (datagrams) {
                sendDatagramBack(s, whole);
            } else {
                sendAll(s, whole);
            }
            return .keep_going;
        },
        else => {
            if (event.codepoint < ' ') return .keep_going;
            var utf8: [4]u8 = undefined;
            const cp: u21 = @intCast(event.codepoint & 0x1F_FFFF);
            const n = std.unicode.utf8Encode(cp, &utf8) catch return .keep_going;
            if (len.* + n < line.len - 1) {
                @memcpy(line[len.*..][0..n], utf8[0..n]);
                len.* += n;
                out.text(utf8[0..n]);
                out.flush();
            }
            return .keep_going;
        },
    }
}

/// A datagram to the peer: where the socket is connected, or back to
/// whoever spoke last when it is not.
fn sendDatagramBack(s: *const sock.Sock, bytes: []const u8) void {
    if (s.peer_addr != 0) {
        _ = s.sendDatagram(0, 0, bytes);
        return;
    }
    const back = last_sender orelse {
        say("nc: nobody to answer yet\n");
        return;
    };
    _ = s.sendDatagram(back.addr, back.port, bytes);
}

/// Standard input toward the peer. False when the pipe finished.
fn feed(s: *const sock.Sock, datagrams: bool) bool {
    var buf: [512]u8 = undefined;
    const n = sys.read(sys.STDIN, &buf);
    if (n <= 0) return false;
    const bytes = buf[0..@intCast(n)];
    if (datagrams) {
        sendDatagramBack(s, bytes);
    } else {
        sendAll(s, bytes);
    }
    return true;
}

/// Every byte in, however long the ring takes: the service drains as the
/// stack acknowledges, and the event says when room returned.
fn sendAll(s: *const sock.Sock, bytes: []const u8) void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = s.send(bytes[sent..]);
        sent += n;
        if (n == 0) {
            if (s.state() == .closed) return;
            _ = sys.eventWait(s.waitHandle(), sys.FOREVER);
        }
    }
}

/// The peer onto standard output. False when the conversation is over and
/// nothing remains to read.
fn pour(s: *const sock.Sock, datagrams: bool) bool {
    var buf: [512]u8 = undefined;
    if (datagrams) {
        while (s.recvDatagram(&buf)) |gram| {
            last_sender = gram;
            out.text(buf[0..gram.len]);
            out.flush();
        }
        return true;
    }

    while (true) {
        const n = s.recv(&buf);
        if (n == 0) break;
        out.text(buf[0..n]);
        out.flush();
    }

    switch (s.state()) {
        .closed => {
            sayCause(s.cause());
            return false;
        },
        .peer_closed => return s.view.rx.readable() != 0,
        else => return true,
    }
}

/// Whether everything owed has moved: input finished, tx drained, and the
/// peer no longer sending. Datagrams have no goodbye, so sent is done.
fn finished(s: *const sock.Sock) bool {
    if (!s.flushed()) return false;
    if (s.kind == .udp) return true;
    return switch (s.state()) {
        .peer_closed, .closed => true,
        else => false,
    };
}

fn sayOpenFailure(err: anyerror) void {
    say(switch (err) {
        error.NoService => "nc: the network service is not answering\n",
        error.TimedOut => "nc: nobody answered in time\n",
        else => "nc: refused\n",
    });
}

fn sayCause(cause: @import("proto").socket.Cause) void {
    switch (cause) {
        .refused => say("nc: connection refused\n"),
        .reset => say("nc: connection reset\n"),
        .aborted => say("nc: connection lost\n"),
        else => {},
    }
}

fn sayPeer(what: []const u8, addr: u32, port: u16) void {
    out.text(what);
    var field: [21]u8 = undefined;
    out.text(lib.ipv4.textWithPort(addr, port, &field));
    out.byte('\n');
    out.flush();
}

fn say(text: []const u8) void {
    out.text(text);
    out.flush();
}

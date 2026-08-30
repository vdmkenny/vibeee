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
const sock = @import("ulib").sock;
const str = @import("ulib").str;
const sys = @import("sys");

pub fn run(args: []const []const u8) void {
    var listen = false;
    var datagrams = false;
    var positional: [2][]const u8 = undefined;
    var names: usize = 0;

    for (args) |arg| {
        if (str.eql(arg, "-l")) {
            listen = true;
        } else if (str.eql(arg, "-u")) {
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
    // its keystrokes announce themselves through the keys event instead.
    // A ready answer consumed the pipe's pending signal, so readiness
    // travels into the loop instead of being waited for again.
    const probe = sys.waitMany(&[_]u32{sys.STDIN}, sys.POLL);
    const console = probe == -@as(isize, @intFromEnum(sys.Errno.badf));

    if (console) {
        converseConsole(s, datagrams);
    } else {
        conversePiped(s, datagrams, probe >= 0);
    }
}

fn conversePiped(s: *const sock.Sock, datagrams: bool, stdin_ready: bool) void {
    var fed = true;

    if (stdin_ready) {
        if (!feed(s, datagrams)) fed = false;
        if (!pour(s, datagrams)) return;
    }

    while (true) {
        var sources: [2]u32 = .{ s.waitHandle(), sys.STDIN };
        const n: usize = if (fed) 2 else 1;
        const woke = sys.waitMany(sources[0..n], sys.FOREVER);
        if (woke < 0) continue;

        if (woke == 1) {
            if (!feed(s, datagrams)) fed = false;
        }
        if (!pour(s, datagrams)) return;
        if (!fed and finished(s)) return;
    }
}

fn converseConsole(s: *const sock.Sock, datagrams: bool) void {
    const was = sys.ttyMode(.raw);
    defer _ = sys.ttyMode(was);

    const keys = sys.watch(.keys);
    var sources: [2]u32 = .{ s.waitHandle(), if (keys >= 0) @intCast(keys) else return };
    var line: [512]u8 = undefined;
    var len: usize = 0;
    var swallow: usize = 0;
    var typing = true;

    while (true) {
        const woke = sys.waitMany(sources[0 .. if (typing) 2 else 1], sys.FOREVER);
        if (woke < 0) continue;

        if (woke == 1) {
            var byte: [1]u8 = undefined;
            if (sys.read(sys.STDIN, &byte) > 0) {
                switch (handleKey(s, datagrams, byte[0], &line, &len, &swallow)) {
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

/// One typed byte into the line, the line to the peer when entered.
fn handleKey(
    s: *const sock.Sock,
    datagrams: bool,
    byte: u8,
    line: *[512]u8,
    len: *usize,
    swallow: *usize,
) KeyOutcome {
    const CTRL_C = 0x03;
    const CTRL_D = 0x04;
    const BACKSPACE = 0x08;
    const DELETE = 0x7F;
    const ESCAPE = 0x1B;

    if (swallow.* > 0) {
        swallow.* -= 1;
        return .keep_going;
    }

    switch (byte) {
        CTRL_C => return .leave,
        CTRL_D => return .no_more_input,
        ESCAPE => {
            // An arrow or a function key: the introducer and two more
            // bytes nothing here has a use for.
            swallow.* = 2;
            return .keep_going;
        },
        BACKSPACE, DELETE => {
            if (len.* > 0) {
                len.* -= 1;
                out.text("\x08 \x08");
                out.flush();
            }
            return .keep_going;
        },
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
            if (byte >= ' ' and len.* < line.len - 1) {
                line[len.*] = byte;
                len.* += 1;
                out.byte(byte);
                out.flush();
            }
            return .keep_going;
        },
    }
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

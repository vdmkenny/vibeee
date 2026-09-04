//! A TLS connection, over a socket the network service granted.
//!
//! One implementation for every program that needs one. The protocol itself
//! is `std.crypto.tls`, which ships with the compiler and is the only part of
//! this that must be exactly right; what is here is the two ends of it: bytes
//! to and from a socket underneath, and the authorities to check the server
//! against above.
//!
//! The authorities are read from `/share/ca.store`, decoded at image build
//! from the vendored bundle. A program opens them once and connects as often
//! as it likes.
//!
//! A connection blocks: the handshake is several round trips and there is no
//! way to have half of one. A program that must stay answering while it
//! connects does so on its own account.

const std = @import("std");
const sys = @import("sys");
const lib = @import("lib");

const castore = lib.castore;
const file = @import("file.zig");
const sock = @import("sock.zig");

const Certificate = std.crypto.Certificate;
const tls = std.crypto.tls;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

/// Where the authorities live in the image.
pub const STORE = "/share/ca.store";

/// The most a store may come to. Well past the vendored one, and a bound on
/// what a file is allowed to make this program read.
pub const STORE_MAX = 1 << 20;

/// What one connection holds either side of the cipher.
///
/// Twice the largest record rather than exactly one. The protocol asks its
/// reader to hold a whole record contiguously at any moment, and a buffer of
/// exactly one record cannot do that while it still has the tail of the last
/// one in it: what a server sends in one go is several records, and they do
/// not arrive aligned to anything.
const BUFFER = 2 * tls.max_ciphertext_record_len;

/// How many random bytes a handshake is seeded with, which the caller draws:
/// a connection cannot draw its own and stay a value.
pub const SEED = tls.Client.Options.entropy_len;

pub const Error = error{
    /// The authorities could not be read.
    NoAuthorities,
    /// The server could not be reached at all.
    Unreachable,
    /// The server was reached and the handshake failed: a certificate that
    /// does not check out, a name it was not issued for, a version neither
    /// side speaks.
    Refused,
    /// The clock is not set, so a certificate's dates mean nothing.
    NoClock,
    /// The machine could not offer unpredictable bytes to seal with.
    NoRandomness,
    OutOfMemory,
};

/// The authorities every connection is checked against.
///
/// Read once per program: parsing a hundred and twenty certificates is real
/// work on this machine, and it is the same answer every time.
pub const Roots = struct {
    bundle: Certificate.Bundle = .empty,

    /// Read the store and index it. `now` is seconds since the epoch, which
    /// decides which authorities have expired.
    pub fn open(gpa: std.mem.Allocator, now: i64) Error!Roots {
        var record: [512]u8 = undefined;
        const told = sys.stat(STORE, &record);
        if (told <= 0) return error.NoAuthorities;
        const entry = sys.Dirent.decode(&record, @intCast(told)) orelse return error.NoAuthorities;
        if (entry.size == 0 or entry.size > STORE_MAX) return error.NoAuthorities;

        const bytes = gpa.alloc(u8, entry.size) catch return error.OutOfMemory;
        defer gpa.free(bytes);
        const read = file.readWhole(STORE, bytes) orelse return error.NoAuthorities;
        if (read != entry.size) return error.NoAuthorities;

        const store = castore.read(bytes[0..read]) catch return error.NoAuthorities;

        var roots: Roots = .{};
        errdefer roots.deinit(gpa);
        for (0..store.count()) |index| {
            const der = store.at(index);
            const at: u32 = @intCast(roots.bundle.bytes.items.len);
            roots.bundle.bytes.appendSlice(gpa, der) catch return error.OutOfMemory;
            // An authority this build cannot parse is one it will not vouch
            // for, and one bad certificate is not a reason to trust nothing.
            roots.bundle.parseCert(gpa, at, now) catch {
                roots.bundle.bytes.items.len = at;
            };
        }
        if (roots.bundle.map.count() == 0) return error.NoAuthorities;
        return roots;
    }

    pub fn deinit(self: *Roots, gpa: std.mem.Allocator) void {
        self.bundle.deinit(gpa);
        self.* = .{};
    }

    pub fn count(self: *const Roots) usize {
        return self.bundle.map.count();
    }
};

/// What the protocol called the last handshake that failed. A connection that
/// did not happen has nowhere of its own to say why.
pub var last_failure: []const u8 = "";

/// A connection. Held by pointer for its whole life: the protocol's own
/// reader and writer point back into it.
pub const Stream = struct {
    socket: sock.Sock,
    client: tls.Client,

    /// The ciphertext either way, and the plaintext the protocol hands over.
    from_socket: SocketReader,
    to_socket: SocketWriter,
    input: [BUFFER]u8,
    output: [BUFFER]u8,
    plain_in: [BUFFER]u8,
    plain_out: [BUFFER]u8,

    /// Open a connection to `host` at `addr`. The name is what the
    /// certificate is checked against, so it is the name that was asked for
    /// rather than the address it resolved to.
    pub fn connect(
        gpa: std.mem.Allocator,
        roots: *Roots,
        addr: u32,
        port: u16,
        host: []const u8,
        now: i64,
    ) Error!*Stream {
        if (now <= 0) return error.NoClock;

        // Drawn where the machine keeps its randomness rather than made up
        // here: a handshake seeded from a clock every program can read is a
        // handshake somebody else can follow.
        var seed: [SEED]u8 = undefined;
        sock.random(&seed) catch return error.NoRandomness;

        const self = gpa.create(Stream) catch return error.OutOfMemory;
        errdefer gpa.destroy(self);

        self.socket = sock.Sock.connect(addr, port) catch return error.Unreachable;
        errdefer self.socket.close();

        self.from_socket = .{
            .socket = &self.socket,
            .interface = .{
                .vtable = &SocketReader.vtable,
                .buffer = &self.input,
                .seek = 0,
                .end = 0,
            },
        };
        self.to_socket = .{
            .socket = &self.socket,
            .interface = .{
                .vtable = &SocketWriter.vtable,
                .buffer = &self.output,
                .end = 0,
            },
        };

        self.client = tls.Client.init(&self.from_socket.interface, &self.to_socket.interface, .{
            .host = .{ .explicit = host },
            .ca = .{ .bundle = .{
                .gpa = gpa,
                .io = undefined,
                .lock = undefined,
                .bundle = &roots.bundle,
            } },
            .read_buffer = &self.plain_in,
            .write_buffer = &self.plain_out,
            .entropy = &seed,
            .realtime_now = .{ .nanoseconds = now * std.time.ns_per_s },
        }) catch |err| {
            last_failure = @errorName(err);
            return error.Refused;
        };

        return self;
    }

    /// As much as `into` holds. Zero when the connection is finished.
    pub fn recv(self: *Stream, into: []u8) usize {
        const n = self.client.reader.readSliceShort(into) catch return 0;
        return n;
    }

    /// All of `bytes`, or none: a record half sent is a connection ended.
    pub fn send(self: *Stream, bytes: []const u8) bool {
        self.client.writer.writeAll(bytes) catch return false;
        self.client.writer.flush() catch return false;
        return true;
    }

    /// The handle a wait set listens on for this connection's news.
    pub fn waitHandle(self: *const Stream) u32 {
        return self.socket.waitHandle();
    }

    pub fn close(self: *Stream, gpa: std.mem.Allocator) void {
        self.client.end() catch {};
        self.socket.close();
        gpa.destroy(self);
    }
};

/// The ciphertext arriving, as something the protocol can read.
const SocketReader = struct {
    socket: *const sock.Sock,
    interface: Reader,

    const vtable: Reader.VTable = .{ .stream = stream };

    fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const self: *SocketReader = @fieldParentPtr("interface", r);
        const room = limit.slice(try w.writableSliceGreedy(1));

        // The socket says when there is something; until then this waits,
        // which is what a handshake is: several round trips with nothing to
        // do between them.
        //
        // Once something has arrived, everything else waiting is taken with
        // it. A record can be larger than what one segment carries, and the
        // rest of it is usually already in the ring: handing over a segment
        // at a time would make the reader ask again for what it could have
        // had at once.
        var got: usize = 0;
        while (true) {
            const n = self.socket.recv(room[got..]);
            if (n != 0) {
                got += n;
                if (got < room.len) continue;
            }
            if (got != 0) {
                w.advance(got);
                return got;
            }
            if (self.socket.state() == .closed) return error.EndOfStream;
            if (sys.eventWait(self.socket.waitHandle(), sys.FOREVER) < 0) return error.ReadFailed;
        }
    }
};

/// The ciphertext leaving.
const SocketWriter = struct {
    socket: *const sock.Sock,
    interface: Writer,

    const vtable: Writer.VTable = .{ .drain = drain };

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *SocketWriter = @fieldParentPtr("interface", w);

        // What the interface has buffered goes first, then the caller's own
        // pieces in the order given, then the last of them as many times as
        // asked for. A writer that sent them in any other order would
        // reorder the stream.
        var written = try self.push(w.buffered());
        const pieces = data[0 .. data.len - 1];
        for (pieces) |piece| written += try self.push(piece);
        const pattern = data[data.len - 1];
        for (0..splat) |_| written += try self.push(pattern);

        // The count this returns is what came from `data`; `consume` takes
        // the buffer's own share out of it.
        return w.consume(written);
    }

    /// All of `bytes` into the socket, waiting for room as often as it takes.
    fn push(self: *SocketWriter, bytes: []const u8) Writer.Error!usize {
        var at: usize = 0;
        while (at < bytes.len) {
            const n = self.socket.send(bytes[at..]);
            if (n != 0) {
                at += n;
                continue;
            }
            if (self.socket.state() == .closed) return error.WriteFailed;
            if (sys.eventWait(self.socket.waitHandle(), sys.FOREVER) < 0) return error.WriteFailed;
        }
        return at;
    }
};

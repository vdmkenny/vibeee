//! FILE, and the formatting behind `printf`.
//!
//! A `FILE` is a descriptor, a buffer and where it has got to. The buffer is
//! allocated on first use rather than at `fopen`, so a program that opens
//! files it never reads pays nothing for them, and it is a kilobyte rather
//! than the eight most libraries use: on a machine with 512 MB shared between
//! everything, a program with twenty files open should not be holding 160 KB
//! it has not written to.
//!
//! One formatter, reached through a writer chosen at compile time, so
//! `printf`, `snprintf` and the rest are the same code with a different
//! destination rather than three implementations that drift.

const errno = @import("errno.zig");
const mem = @import("mem.zig");
const unistd = @import("unistd.zig");

pub const BUFSIZ = 1024;
pub const EOF: c_int = -1;

const Buffering = enum(u8) {
    /// Written out when a line ends. What a terminal wants.
    line,
    /// Written out when the buffer fills. What a file wants.
    full,
    /// Written out immediately. What a diagnostic wants, because a program
    /// that crashes should not take its last words with it.
    none,
};

pub const File = extern struct {
    fd: c_int,
    buffer: ?[*]u8,
    /// How much of the buffer is in use, and where reading has got to in it.
    used: usize,
    at: usize,
    capacity: usize,
    buffering: Buffering,
    /// Whether `used` counts bytes waiting to go out or bytes read in. A
    /// stream does one or the other between flushes, never both.
    writing: bool,
    at_end: bool,
    failed: bool,
    /// One character pushed back by `ungetc`, which every parser written in C
    /// expects to be able to do exactly once.
    pushed: c_int,
};

fn blank(fd: c_int, buffering: Buffering) File {
    return .{
        .fd = fd,
        .buffer = null,
        .used = 0,
        .at = 0,
        .capacity = 0,
        .buffering = buffering,
        .writing = false,
        .at_end = false,
        .failed = false,
        .pushed = EOF,
    };
}

var standard_in = blank(0, .line);
var standard_out = blank(1, .line);
var standard_error = blank(2, .none);

pub export var stdin: *File = &standard_in;
pub export var stdout: *File = &standard_out;
pub export var stderr: *File = &standard_error;

/// Every stream this library opened, so `exit` can flush them.
const OPEN_MAX = 16;
var open_files: [OPEN_MAX]?*File = @splat(null);

pub fn flushAll() void {
    _ = fflush(stdout);
    _ = fflush(stderr);
    for (open_files) |entry| {
        if (entry) |stream| _ = fflush(stream);
    }
}

fn ensureBuffer(stream: *File) bool {
    if (stream.buffer != null) return true;
    if (stream.buffering == .none) return false;

    const block = mem.malloc(BUFSIZ) orelse return false;
    stream.buffer = @ptrCast(block);
    stream.capacity = BUFSIZ;
    return true;
}

// ---------------------------------------------------------------------------
// Opening and closing
// ---------------------------------------------------------------------------

/// C's mode string as open flags. Only the letters that change anything: `b`
/// is accepted and ignored because there is no text mode to distinguish it
/// from.
fn modeFlags(mode: [*:0]const u8) ?c_int {
    return switch (mode[0]) {
        'r' => if (hasPlus(mode)) unistd.O_RDWR else unistd.O_RDONLY,
        'w' => unistd.O_CREAT | unistd.O_TRUNC | (if (hasPlus(mode)) unistd.O_RDWR else unistd.O_WRONLY),
        'a' => unistd.O_CREAT | unistd.O_APPEND | (if (hasPlus(mode)) unistd.O_RDWR else unistd.O_WRONLY),
        else => null,
    };
}

fn hasPlus(mode: [*:0]const u8) bool {
    var i: usize = 0;
    while (mode[i] != 0) : (i += 1) {
        if (mode[i] == '+') return true;
    }
    return false;
}

export fn fopen(path: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*File {
    const flags = modeFlags(mode) orelse {
        errno.set(errno.EINVAL);
        return null;
    };

    const fd = unistd.open(path, flags);
    if (fd < 0) return null;

    return adopt(fd);
}

export fn fdopen(fd: c_int, mode: [*:0]const u8) callconv(.c) ?*File {
    _ = mode;
    return adopt(fd);
}

/// Wrap a descriptor in a stream and remember it, so `exit` can flush it.
fn adopt(fd: c_int) ?*File {
    const block = mem.malloc(@sizeOf(File)) orelse {
        _ = unistd.close(fd);
        return null;
    };

    const stream: *File = @alignCast(@ptrCast(block));
    stream.* = blank(fd, if (unistd.isatty(fd) != 0) .line else .full);

    for (&open_files) |*slot| {
        if (slot.* == null) {
            slot.* = stream;
            break;
        }
    }
    return stream;
}

export fn fclose(stream: *File) callconv(.c) c_int {
    const result = fflush(stream);
    _ = unistd.close(stream.fd);

    for (&open_files) |*slot| {
        if (slot.* == stream) slot.* = null;
    }
    if (stream.buffer) |buffer| mem.free(buffer);
    mem.free(stream);
    return result;
}

export fn setvbuf(stream: *File, buffer: ?[*]u8, mode: c_int, size: usize) callconv(.c) c_int {
    _ = buffer;
    _ = size;
    stream.buffering = switch (mode) {
        0 => .full,
        1 => .line,
        else => .none,
    };
    return 0;
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

pub export fn fflush(stream: ?*File) callconv(.c) c_int {
    const target = stream orelse {
        flushAll();
        return 0;
    };
    if (!target.writing or target.used == 0) return 0;

    const buffer = target.buffer orelse return 0;
    const written = unistd.write(target.fd, buffer, target.used);
    target.used = 0;

    if (written < 0) {
        target.failed = true;
        return EOF;
    }
    return 0;
}

fn put(stream: *File, byte: u8) void {
    // A stream that was reading has to forget what it read before it writes:
    // the buffer holds one thing at a time.
    if (!stream.writing) {
        stream.used = 0;
        stream.at = 0;
        stream.writing = true;
    }

    if (stream.buffering == .none or !ensureBuffer(stream)) {
        var one = [_]u8{byte};
        if (unistd.write(stream.fd, &one, 1) < 0) stream.failed = true;
        return;
    }

    const buffer = stream.buffer.?;
    buffer[stream.used] = byte;
    stream.used += 1;

    if (stream.used == stream.capacity or (stream.buffering == .line and byte == '\n')) {
        _ = fflush(stream);
    }
}

pub export fn fputc(byte: c_int, stream: *File) callconv(.c) c_int {
    put(stream, @truncate(@as(c_uint, @bitCast(byte))));
    return if (stream.failed) EOF else byte;
}

export fn putc(byte: c_int, stream: *File) callconv(.c) c_int {
    return fputc(byte, stream);
}

export fn putchar(byte: c_int) callconv(.c) c_int {
    return fputc(byte, stdout);
}

pub export fn fputs(text: [*:0]const u8, stream: *File) callconv(.c) c_int {
    var i: usize = 0;
    while (text[i] != 0) : (i += 1) put(stream, text[i]);
    return if (stream.failed) EOF else 0;
}

/// The one that adds a newline, which is the difference between it and
/// `fputs` and the reason so much C uses it.
export fn puts(text: [*:0]const u8) callconv(.c) c_int {
    _ = fputs(text, stdout);
    put(stdout, '\n');
    return if (stdout.failed) EOF else 0;
}

export fn fwrite(source: [*]const u8, size: usize, count: usize, stream: *File) callconv(.c) usize {
    const total = size * count;
    for (0..total) |i| put(stream, source[i]);
    if (stream.failed or size == 0) return 0;
    return count;
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

fn fill(stream: *File) bool {
    if (!ensureBuffer(stream)) return false;

    const buffer = stream.buffer.?;
    const n = unistd.read(stream.fd, buffer, stream.capacity);
    if (n <= 0) {
        if (n == 0) stream.at_end = true else stream.failed = true;
        return false;
    }

    stream.used = @intCast(n);
    stream.at = 0;
    return true;
}

pub export fn fgetc(stream: *File) callconv(.c) c_int {
    if (stream.pushed != EOF) {
        const back = stream.pushed;
        stream.pushed = EOF;
        return back;
    }

    if (stream.writing) {
        _ = fflush(stream);
        stream.writing = false;
    }

    if (stream.at == stream.used and !fill(stream)) return EOF;

    const byte = stream.buffer.?[stream.at];
    stream.at += 1;
    return byte;
}

export fn getc(stream: *File) callconv(.c) c_int {
    return fgetc(stream);
}

export fn getchar() callconv(.c) c_int {
    return fgetc(stdin);
}

export fn ungetc(byte: c_int, stream: *File) callconv(.c) c_int {
    if (byte == EOF) return EOF;
    stream.pushed = byte;
    stream.at_end = false;
    return byte;
}

export fn fgets(into: [*]u8, size: c_int, stream: *File) callconv(.c) ?[*]u8 {
    if (size <= 0) return null;

    const limit: usize = @intCast(size - 1);
    var n: usize = 0;
    while (n < limit) {
        const byte = fgetc(stream);
        if (byte == EOF) break;

        into[n] = @truncate(@as(c_uint, @bitCast(byte)));
        n += 1;
        if (byte == '\n') break;
    }

    if (n == 0) return null;
    into[n] = 0;
    return into;
}

export fn fread(into: [*]u8, size: usize, count: usize, stream: *File) callconv(.c) usize {
    const total = size * count;
    var n: usize = 0;
    while (n < total) : (n += 1) {
        const byte = fgetc(stream);
        if (byte == EOF) break;
        into[n] = @truncate(@as(c_uint, @bitCast(byte)));
    }
    return if (size == 0) 0 else n / size;
}

// ---------------------------------------------------------------------------
// Position and state
// ---------------------------------------------------------------------------

export fn fseek(stream: *File, offset: c_long, whence: c_int) callconv(.c) c_int {
    _ = fflush(stream);
    stream.at = 0;
    stream.used = 0;
    stream.at_end = false;
    stream.pushed = EOF;

    return if (unistd.lseek(stream.fd, offset, whence) < 0) EOF else 0;
}

export fn ftell(stream: *File) callconv(.c) c_long {
    _ = fflush(stream);
    const at = unistd.lseek(stream.fd, 0, unistd.SEEK_CUR);
    if (at < 0) return -1;

    // What is still in the buffer has been read from the descriptor but not
    // handed to the caller, so the caller is that much behind.
    return at - @as(c_long, @intCast(stream.used - stream.at));
}

export fn rewind(stream: *File) callconv(.c) void {
    _ = fseek(stream, 0, unistd.SEEK_SET);
    stream.failed = false;
}

export fn feof(stream: *File) callconv(.c) c_int {
    return if (stream.at_end) 1 else 0;
}

export fn ferror(stream: *File) callconv(.c) c_int {
    return if (stream.failed) 1 else 0;
}

export fn clearerr(stream: *File) callconv(.c) void {
    stream.failed = false;
    stream.at_end = false;
}

export fn fileno(stream: *File) callconv(.c) c_int {
    return stream.fd;
}

export fn perror(prefix: ?[*:0]const u8) callconv(.c) void {
    if (prefix) |text| {
        _ = fputs(text, stderr);
        _ = fputs(": ", stderr);
    }
    _ = fputs(strerror(__errno()), stderr);
    put(stderr, '\n');
}

extern fn __errno_location() callconv(.c) *c_int;

fn __errno() c_int {
    return __errno_location().*;
}

/// The words the rest of the system already uses for an error, so a C program
/// and a shell tool report the same failure the same way.
///
/// Only the errors this system produces have words. The rest are numbers C
/// code may compare against but nothing here ever sets, and inventing a
/// sentence for one would be describing something that cannot happen.
export fn strerror(code: c_int) callconv(.c) [*:0]const u8 {
    if (code == 0) return "no error";

    // Written into a static rather than returned as a slice: C wants a
    // terminated string and the reasons are Zig slices.
    const text = errno.describe(code) orelse return "unknown error";
    const n = @min(text.len, message.len - 1);
    @memcpy(message[0..n], text[0..n]);
    message[n] = 0;
    return @ptrCast(&message);
}

var message: [48]u8 = @splat(0);

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
const heap = @import("ulib").heap;
const stream_mod = @import("ulib").stream;
const string = @import("string.zig");
const sys = @import("sys");
const unistd = @import("unistd.zig");

const Stream = stream_mod.Stream;

pub const BUFSIZ = 1024;
pub const EOF: c_int = -1;

/// A `FILE`, which C only ever holds a pointer to, so it can be whatever
/// shape suits: a `ulib.stream.Stream` and the two things C asks of a stream
/// that the stream itself has no opinion about.
pub const File = struct {
    stream: Stream,
    /// One character pushed back by `ungetc`, which every parser written in C
    /// expects to be able to do exactly once.
    pushed: c_int = EOF,
    /// Whether this library allocated the buffer, and therefore owes it back.
    owns_buffer: bool = false,
};

fn blank(fd: c_int, buffering: stream_mod.Buffering) File {
    return .{ .stream = Stream.init(@intCast(fd), &.{}, buffering) };
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
        if (entry) |file| _ = fflush(file);
    }
}

/// Give the stream a buffer, on the first use that needs one.
///
/// Lazily, so a program that opens files it never reads pays nothing for them,
/// and a kilobyte rather than the eight most libraries use: on a machine with
/// 512 MB shared between everything, twenty open files should not be 160 KB
/// nobody has written to.
fn ensureBuffer(file: *File) bool {
    if (file.stream.buffer.len > 0) return true;
    if (file.stream.buffering == .none) return false;

    const block: [*]u8 = @ptrCast(heap.alloc(BUFSIZ) orelse return false);
    file.stream.buffer = block[0..BUFSIZ];
    file.owns_buffer = true;
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

/// Take a name away, whether it names a file or an empty directory.
///
/// C's own removal, and the one ported code reaches for. One call does
/// both here, because the kernel decides whether the thing named may go
/// rather than making the caller say which kind it expected.
export fn remove(path: [*:0]const u8) callconv(.c) c_int {
    return @intCast(errno.wrap(sys.unlink(string.spanOf(path))));
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
    const block = heap.alloc(@sizeOf(File)) orelse {
        _ = unistd.close(fd);
        return null;
    };

    const file: *File = @alignCast(@ptrCast(block));
    file.* = blank(fd, if (unistd.isatty(fd) != 0) .line else .full);

    for (&open_files) |*slot| {
        if (slot.* == null) {
            slot.* = file;
            break;
        }
    }
    return file;
}

export fn fclose(file: *File) callconv(.c) c_int {
    const result = fflush(file);
    _ = unistd.close(@intCast(file.stream.handle));

    for (&open_files) |*slot| {
        if (slot.* == file) slot.* = null;
    }
    if (file.owns_buffer) heap.release(file.stream.buffer.ptr);
    heap.release(file);
    return result;
}

export fn setvbuf(file: *File, buffer: ?[*]u8, mode: c_int, size: usize) callconv(.c) c_int {
    _ = buffer;
    _ = size;
    file.stream.buffering = switch (mode) {
        0 => .full,
        1 => .line,
        else => .none,
    };
    return 0;
}

// ---------------------------------------------------------------------------
// Writing
// ---------------------------------------------------------------------------

pub export fn fflush(file: ?*File) callconv(.c) c_int {
    const target = file orelse {
        flushAll();
        return 0;
    };
    target.stream.flush();
    return if (target.stream.failed) EOF else 0;
}

fn put(file: *File, byte: u8) void {
    _ = ensureBuffer(file);
    file.stream.writeByte(byte);
}

pub export fn fputc(byte: c_int, file: *File) callconv(.c) c_int {
    put(file, @truncate(@as(c_uint, @bitCast(byte))));
    return if (file.stream.failed) EOF else byte;
}

export fn putc(byte: c_int, file: *File) callconv(.c) c_int {
    return fputc(byte, file);
}

export fn putchar(byte: c_int) callconv(.c) c_int {
    return fputc(byte, stdout);
}

pub export fn fputs(text: [*:0]const u8, file: *File) callconv(.c) c_int {
    _ = ensureBuffer(file);
    file.stream.write(string.spanOf(text));
    return if (file.stream.failed) EOF else 0;
}

/// The one that adds a newline, which is the difference between it and
/// `fputs` and the reason so much C uses it.
export fn puts(text: [*:0]const u8) callconv(.c) c_int {
    _ = fputs(text, stdout);
    put(stdout, '\n');
    return if (stdout.stream.failed) EOF else 0;
}

export fn fwrite(source: [*]const u8, size: usize, count: usize, file: *File) callconv(.c) usize {
    _ = ensureBuffer(file);
    file.stream.write(source[0 .. size * count]);
    if (file.stream.failed or size == 0) return 0;
    return count;
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

pub export fn fgetc(file: *File) callconv(.c) c_int {
    if (file.pushed != EOF) {
        const back = file.pushed;
        file.pushed = EOF;
        return back;
    }

    _ = ensureBuffer(file);
    return file.stream.readByte() orelse EOF;
}

export fn getc(file: *File) callconv(.c) c_int {
    return fgetc(file);
}

export fn getchar() callconv(.c) c_int {
    return fgetc(stdin);
}

export fn ungetc(byte: c_int, file: *File) callconv(.c) c_int {
    if (byte == EOF) return EOF;
    file.pushed = byte;
    file.stream.at_end = false;
    return byte;
}

export fn fgets(into: [*]u8, size: c_int, file: *File) callconv(.c) ?[*]u8 {
    if (size <= 0) return null;

    const limit: usize = @intCast(size - 1);
    var n: usize = 0;
    while (n < limit) {
        const byte = fgetc(file);
        if (byte == EOF) break;

        into[n] = @truncate(@as(c_uint, @bitCast(byte)));
        n += 1;
        if (byte == '\n') break;
    }

    if (n == 0) return null;
    into[n] = 0;
    return into;
}

/// Read a whole line, growing the caller's buffer to fit it.
///
/// The one function in this library that allocates on the caller's behalf and
/// hands the result back, which is why it takes the buffer and its capacity by
/// pointer: it may replace both. A first call with a null buffer starts from
/// nothing, which is how every program that uses this is written.
export fn getline(into: *?[*]u8, capacity: *usize, file: *File) callconv(.c) isize {
    return getdelim(into, capacity, '\n', file);
}

export fn getdelim(into: *?[*]u8, capacity: *usize, delimiter: c_int, file: *File) callconv(.c) isize {
    var buffer = into.* orelse blk: {
        const start: [*]u8 = @ptrCast(heap.alloc(GETLINE_START) orelse return -1);
        capacity.* = GETLINE_START;
        break :blk start;
    };

    var n: usize = 0;
    while (true) {
        const byte = fgetc(file);
        if (byte == EOF) break;

        // One spare for the terminator, always: a line exactly as long as the
        // buffer still has to end with one.
        if (n + 1 >= capacity.*) {
            const wider = capacity.* * 2;
            buffer = @ptrCast(heap.resize(buffer, wider) orelse return -1);
            capacity.* = wider;
        }

        buffer[n] = @truncate(@as(c_uint, @bitCast(byte)));
        n += 1;
        if (byte == delimiter) break;
    }

    into.* = buffer;
    if (n == 0) return -1;

    buffer[n] = 0;
    return @intCast(n);
}

/// Where a line starts before anything is known about how long it is. Doubling
/// from here means a long line costs a handful of copies rather than one per
/// character.
const GETLINE_START = 128;

export fn fread(into: [*]u8, size: usize, count: usize, file: *File) callconv(.c) usize {
    _ = ensureBuffer(file);
    const n = file.stream.read(into[0 .. size * count]);
    return if (size == 0) 0 else n / size;
}

// ---------------------------------------------------------------------------
// Position and state
// ---------------------------------------------------------------------------

export fn fseek(file: *File, offset: c_long, whence: c_int) callconv(.c) c_int {
    file.stream.flush();

    // A relative seek is relative to where the *caller* is, and that is
    // not where the descriptor is: a buffered read pulled in bytes the
    // caller has not been handed, so the descriptor sits past them. The
    // difference has to come off before the buffer is thrown away, or the
    // seek lands a bufferful too far.
    var wanted = offset;
    if (whence == unistd.SEEK_CUR) wanted -= @intCast(behind(file));

    file.stream.at = 0;
    file.stream.used = 0;
    file.stream.at_end = false;
    file.pushed = EOF;

    return if (unistd.lseek(@intCast(file.stream.handle), wanted, whence) < 0) EOF else 0;
}

/// How far behind the descriptor the caller is: everything read into the
/// buffer and not yet handed over, plus a character pushed back.
fn behind(file: *File) c_long {
    var unread: c_long = @intCast(file.stream.used - file.stream.at);
    if (file.pushed != EOF) unread += 1;
    return unread;
}

export fn ftell(file: *File) callconv(.c) c_long {
    file.stream.flush();

    const at = unistd.lseek(@intCast(file.stream.handle), 0, unistd.SEEK_CUR);
    if (at < 0) return -1;

    // What is still in the buffer has been read from the descriptor but not
    // handed to the caller, so the caller is that much behind.
    return at - behind(file);
}

export fn rewind(file: *File) callconv(.c) void {
    _ = fseek(file, 0, unistd.SEEK_SET);
    file.stream.failed = false;
}

export fn feof(file: *File) callconv(.c) c_int {
    return if (file.stream.at_end) 1 else 0;
}

export fn ferror(file: *File) callconv(.c) c_int {
    return if (file.stream.failed) 1 else 0;
}

export fn clearerr(file: *File) callconv(.c) void {
    file.stream.failed = false;
    file.stream.at_end = false;
}

export fn fileno(file: *File) callconv(.c) c_int {
    return @intCast(file.stream.handle);
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

//! The rest of `stdlib.h`: numbers out of text, and sorting.
//!
//! `malloc` and `exit` are not here. They live with the memory they manage and
//! the process they end, which is where somebody looking for them would think
//! to look, rather than in a file named after the header that happens to
//! declare all three.

const std = @import("std");
const sys = @import("sys");
const errno = @import("errno.zig");
const string = @import("string.zig");
const str = @import("lib").str;

/// Text to a number, C's way: skip the leading space, take a sign, take digits
/// in `base`, and leave `end` pointing at the first character that was not one.
///
/// Base zero means read the prefix: `0x` for sixteen, a leading `0` for eight,
/// anything else for ten. That is what makes `strtol(text, null, 0)` the usual
/// way to accept a number written however somebody felt like writing it.
fn parse(text: [*:0]const u8, end: ?*[*c]u8, base: c_int, comptime T: type) T {
    var i: usize = 0;
    while (isSpace(text[i])) i += 1;

    const negative = text[i] == '-';
    if (text[i] == '-' or text[i] == '+') i += 1;

    var radix: u8 = @intCast(base);
    if (base == 0) {
        if (text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
            radix = 16;
            i += 2;
        } else if (text[i] == '0') {
            radix = 8;
        } else {
            radix = 10;
        }
    } else if (base == 16 and text[i] == '0' and (text[i + 1] == 'x' or text[i + 1] == 'X')) {
        i += 2;
    }

    var value: T = 0;
    var any = false;
    while (digitOf(text[i], radix)) |digit| : (i += 1) {
        any = true;
        value = value *% @as(T, radix) +% @as(T, digit);
    }

    // Nothing was read, so nothing was consumed: `end` goes back to the start,
    // which is how a caller tells "zero" from "not a number".
    if (end) |slot| slot.* = @constCast(@ptrCast(&text[if (any) i else 0]));
    if (!any) return 0;

    return if (negative) 0 -% value else value;
}

fn digitOf(c: u8, radix: u8) ?u8 {
    const value: u8 = switch (c) {
        '0'...'9' => c - '0',
        'a'...'z' => c - 'a' + 10,
        'A'...'Z' => c - 'A' + 10,
        else => return null,
    };
    return if (value < radix) value else null;
}

fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

export fn strtol(text: [*:0]const u8, end: ?*[*c]u8, base: c_int) callconv(.c) c_long {
    return parse(text, end, base, c_long);
}

export fn strtoul(text: [*:0]const u8, end: ?*[*c]u8, base: c_int) callconv(.c) c_ulong {
    return parse(text, end, base, c_ulong);
}

export fn atoi(text: [*:0]const u8) callconv(.c) c_int {
    return @truncate(parse(text, null, 10, c_long));
}

export fn atol(text: [*:0]const u8) callconv(.c) c_long {
    return parse(text, null, 10, c_long);
}

export fn abs(value: c_int) callconv(.c) c_int {
    return if (value < 0) -value else value;
}

export fn labs(value: c_long) callconv(.c) c_long {
    return if (value < 0) -value else value;
}

/// Insertion sort, and named as such rather than hidden behind the C name.
///
/// The array is a byte run of unknown element type, so every swap is a
/// three-way copy through a scratch element and every comparison is an
/// indirect call. That cost dwarfs the algorithm at the sizes a program on
/// this machine sorts, and insertion needs no scratch beyond one element and
/// no recursion at all.
export fn qsort(
    base: [*]u8,
    count: usize,
    size: usize,
    compare: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int,
) callconv(.c) void {
    if (count < 2 or size == 0 or size > SWAP_MAX) return;

    var held: [SWAP_MAX]u8 = undefined;

    var i: usize = 1;
    while (i < count) : (i += 1) {
        @memcpy(held[0..size], base[i * size ..][0..size]);

        var j = i;
        while (j > 0 and compare(base + (j - 1) * size, &held) > 0) : (j -= 1) {
            @memcpy(base[j * size ..][0..size], base[(j - 1) * size ..][0..size]);
        }
        @memcpy(base[j * size ..][0..size], held[0..size]);
    }
}

/// Widest element `qsort` will move. Past it the scratch would have to be
/// allocated, which is a failure mode C's signature has nowhere to report.
const SWAP_MAX = 256;

export fn bsearch(
    key: *const anyopaque,
    base: [*]const u8,
    count: usize,
    size: usize,
    compare: *const fn (?*const anyopaque, ?*const anyopaque) callconv(.c) c_int,
) callconv(.c) ?*const anyopaque {
    var low: usize = 0;
    var high = count;

    while (low < high) {
        const middle = low + (high - low) / 2;
        const at = base + middle * size;

        const order = compare(key, at);
        if (order == 0) return at;
        if (order < 0) high = middle else low = middle + 1;
    }
    return null;
}

export fn rmdir(path: [*:0]const u8) callconv(.c) c_int {
    // Directories are removed by the same call as files; the kernel decides
    // whether the thing named may go.
    return @intCast(errno.wrap(@import("sys").unlink(string.spanOf(path))));
}

// ---------------------------------------------------------------------------
// Numbers out of text, with a point in them
// ---------------------------------------------------------------------------

/// Text to a double, stopping where the number does.
///
/// Finding the end and reading the value are one question asked once:
/// `lib.str` measures how far the number goes, and Zig's own parser turns
/// exactly that much into a value. `end` is left pointing at the first
/// character that was not part of it, which is what makes a caller able
/// to tell "nothing was there" from "zero was there".
export fn strtod(text: [*:0]const u8, end: ?*[*c]u8) callconv(.c) f64 {
    const whole = string.spanOf(text);

    var at: usize = 0;
    while (at < whole.len and isSpace(whole[at])) at += 1;

    const took = str.numberSpan(whole[at..]);
    if (took == 0) {
        if (end) |out| out.* = @constCast(@ptrCast(text));
        return 0;
    }

    if (end) |out| out.* = @constCast(@ptrCast(text + at + took));
    return std.fmt.parseFloat(f64, whole[at..][0..took]) catch 0;
}

export fn strtof(text: [*:0]const u8, end: ?*[*c]u8) callconv(.c) f32 {
    return @floatCast(strtod(text, end));
}

export fn atof(text: [*:0]const u8) callconv(.c) f64 {
    return strtod(text, null);
}

// ---------------------------------------------------------------------------
// Numbers out of nowhere
// ---------------------------------------------------------------------------

/// The largest `rand` returns, which C requires to be at least this and
/// every system sets to exactly it.
pub const RAND_MAX: c_int = 0x7FFF_FFFF;

/// Where the sequence is up to. One at the start, because C says a
/// program that never seeds behaves as though it had seeded with one:
/// the same run twice gives the same numbers, which is what makes a bug
/// in a program that uses them findable.
var seed: u32 = 1;

/// A shift-register generator: three shifts and three exclusive-ors,
/// which is as much as a machine of this size should spend on a number
/// nobody is betting on. Good enough for a game and not for a secret,
/// which is what `rand` has always promised.
export fn rand() callconv(.c) c_int {
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    // The top bit goes, because `rand` answers a non-negative int.
    return @intCast(seed & @as(u32, @intCast(RAND_MAX)));
}

export fn srand(from: c_uint) callconv(.c) void {
    // Never zero: this generator has nowhere to go from there, and a
    // program seeding with the time at the epoch should not get silence.
    seed = if (from == 0) 1 else from;
}

// ---------------------------------------------------------------------------
// Arguments
// ---------------------------------------------------------------------------

/// Where the walk has got to, and what it found. C keeps these in the
/// open because a caller reads them between calls.
pub export var optind: c_int = 1;
pub export var opterr: c_int = 1;
pub export var optopt: c_int = 0;
pub export var optarg: [*c]u8 = null;

/// How far into the current argument the walk is, for the several
/// letters that may be bundled behind one dash.
var within: usize = 1;

/// The next option letter, or -1 when there are no more.
///
/// The plain half of what C offers: single letters, a colon in `spec`
/// meaning the letter takes a value, and everything after the first
/// argument that is not an option left alone.
export fn getopt(argc: c_int, argv: [*c][*c]u8, spec: [*:0]const u8) callconv(.c) c_int {
    optarg = null;

    if (optind >= argc) return -1;
    const arg = argv[@intCast(optind)];
    if (arg == null) return -1;

    const text = string.spanOf(@ptrCast(arg));
    if (text.len < 2 or text[0] != '-') return -1;

    // A lone `--` ends the options and is not one itself.
    if (text.len == 2 and text[1] == '-') {
        optind += 1;
        return -1;
    }

    if (within >= text.len) {
        optind += 1;
        within = 1;
        return getopt(argc, argv, spec);
    }

    const letter = text[within];
    within += 1;

    const wanted = string.spanOf(spec);
    const at = indexOf(wanted, letter) orelse {
        optopt = letter;
        if (within >= text.len) {
            optind += 1;
            within = 1;
        }
        return '?';
    };

    // A colon after the letter means it takes a value: the rest of this
    // argument if there is any, and the next argument if there is not.
    if (at + 1 < wanted.len and wanted[at + 1] == ':') {
        if (within < text.len) {
            optarg = @constCast(@ptrCast(arg + within));
        } else {
            optind += 1;
            if (optind >= argc) {
                optopt = letter;
                within = 1;
                return ':';
            }
            optarg = argv[@intCast(optind)];
        }
        optind += 1;
        within = 1;
        return letter;
    }

    if (within >= text.len) {
        optind += 1;
        within = 1;
    }
    return letter;
}

fn indexOf(text: []const u8, byte: u8) ?usize {
    for (text, 0..) |c, i| {
        if (c == byte) return i;
    }
    return null;
}


/// Run a command through a command processor.
///
/// There is one: the shell, asked to carry out a single line and leave.
/// A null command is the question "is there one at all", and this system
/// can answer yes.
export fn system(command: ?[*:0]const u8) callconv(.c) c_int {
    const line = command orelse return 1;

    const status = sys.spawn(SHELL, &.{ "vsh", "-c", string.spanOf(line) });
    return if (status < 0) -1 else @intCast(status);
}

const SHELL = "/bin/vsh";

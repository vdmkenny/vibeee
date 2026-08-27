//! The rest of `stdlib.h`: numbers out of text, and sorting.
//!
//! `malloc` and `exit` are not here. They live with the memory they manage and
//! the process they end, which is where somebody looking for them would think
//! to look, rather than in a file named after the header that happens to
//! declare all three.

const errno = @import("errno.zig");
const string = @import("string.zig");

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

/// Nothing is handed over yet, so every name is absent rather than empty: a
/// program asking for `HOME` should take its own default, not the empty string.
export fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    _ = name;
    return null;
}

export fn rmdir(path: [*:0]const u8) callconv(.c) c_int {
    // Directories are removed by the same call as files; the kernel decides
    // whether the thing named may go.
    return @intCast(errno.wrap(@import("sys").unlink(string.spanOf(path))));
}

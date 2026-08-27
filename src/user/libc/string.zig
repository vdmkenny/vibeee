//! The string and memory functions, and the character tests.
//!
//! Written here rather than borrowed from `lib.str` because C's contracts are
//! not the same shape: these take pointers and terminators where the Zig side
//! takes slices, and a wrapper for each would be more code than the body.
//!
//! `memcpy` and friends are also what the compiler emits calls to for struct
//! assignment and array initialisation, so a program that never names one
//! still needs them present.

// ---------------------------------------------------------------------------
// Memory
// ---------------------------------------------------------------------------

// `memcpy`, `memmove`, `memset` and `memcmp` are not written here, and the
// first three must not be.
//
// Each of them is what the compiler emits a call to for a struct assignment or
// an array copy, so a definition written in terms of `@memcpy` compiles into a
// call to itself and hangs the first time anything uses it. Zig's compiler-rt,
// bundled into this archive, provides them written the only way they can be.
// `memcmp` is there too and is taken from the same place for the same reason:
// a second copy of a function somebody else has already written correctly is
// a second place for it to be wrong.

export fn memchr(haystack: [*]const u8, value: c_int, n: usize) callconv(.c) ?*const u8 {
    const wanted: u8 = @truncate(@as(c_uint, @bitCast(value)));
    for (haystack[0..n]) |*byte| {
        if (byte.* == wanted) return byte;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Strings
// ---------------------------------------------------------------------------

export fn strlen(s: [*:0]const u8) callconv(.c) usize {
    var n: usize = 0;
    while (s[n] != 0) n += 1;
    return n;
}

export fn strnlen(s: [*]const u8, limit: usize) callconv(.c) usize {
    var n: usize = 0;
    while (n < limit and s[n] != 0) n += 1;
    return n;
}

export fn strcpy(dest: [*]u8, src: [*:0]const u8) callconv(.c) [*]u8 {
    var n: usize = 0;
    while (src[n] != 0) : (n += 1) dest[n] = src[n];
    dest[n] = 0;
    return dest;
}

/// C's own trap, kept faithfully: a source at least `n` long leaves no
/// terminator behind. Ported code depends on the padding as much as the copy.
export fn strncpy(dest: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
    var i: usize = 0;
    while (i < n and src[i] != 0) : (i += 1) dest[i] = src[i];
    while (i < n) : (i += 1) dest[i] = 0;
    return dest;
}

export fn strcat(dest: [*:0]u8, src: [*:0]const u8) callconv(.c) [*]u8 {
    _ = strcpy(@ptrCast(dest + strlen(dest)), src);
    return dest;
}

export fn strncat(dest: [*:0]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
    const at = strlen(dest);
    const take = strnlen(src, n);
    @memcpy(dest[at..][0..take], src[0..take]);
    dest[at + take] = 0;
    return dest;
}

export fn strcmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    var i: usize = 0;
    while (a[i] != 0 and a[i] == b[i]) i += 1;
    return @as(c_int, a[i]) - @as(c_int, b[i]);
}

export fn strncmp(a: [*]const u8, b: [*]const u8, n: usize) callconv(.c) c_int {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        if (a[i] != b[i] or a[i] == 0) return @as(c_int, a[i]) - @as(c_int, b[i]);
    }
    return 0;
}

export fn strcasecmp(a: [*:0]const u8, b: [*:0]const u8) callconv(.c) c_int {
    var i: usize = 0;
    while (a[i] != 0 and lower(a[i]) == lower(b[i])) i += 1;
    return @as(c_int, lower(a[i])) - @as(c_int, lower(b[i]));
}

export fn strchr(s: [*:0]const u8, value: c_int) callconv(.c) ?*const u8 {
    const wanted: u8 = @truncate(@as(c_uint, @bitCast(value)));
    var i: usize = 0;
    // The terminator is a character this finds, which is how `strchr(s, 0)`
    // reaches the end of a string.
    while (true) : (i += 1) {
        if (s[i] == wanted) return &s[i];
        if (s[i] == 0) return null;
    }
}

export fn strrchr(s: [*:0]const u8, value: c_int) callconv(.c) ?*const u8 {
    const wanted: u8 = @truncate(@as(c_uint, @bitCast(value)));
    var found: ?*const u8 = null;
    var i: usize = 0;
    while (true) : (i += 1) {
        if (s[i] == wanted) found = &s[i];
        if (s[i] == 0) return found;
    }
}

export fn strstr(haystack: [*:0]const u8, needle: [*:0]const u8) callconv(.c) ?*const u8 {
    const want = strlen(needle);
    if (want == 0) return &haystack[0];

    const within = strlen(haystack);
    if (want > within) return null;

    for (0..within - want + 1) |i| {
        if (strncmp(@ptrCast(&haystack[i]), @ptrCast(needle), want) == 0) return &haystack[i];
    }
    return null;
}

export fn strdup(s: [*:0]const u8) callconv(.c) ?[*]u8 {
    const n = strlen(s);
    const copy: [*]u8 = @ptrCast(mem.malloc(n + 1) orelse return null);
    @memcpy(copy[0..n], s[0..n]);
    copy[n] = 0;
    return copy;
}

export fn strndup(s: [*]const u8, limit: usize) callconv(.c) ?[*]u8 {
    const n = strnlen(s, limit);
    const copy: [*]u8 = @ptrCast(mem.malloc(n + 1) orelse return null);
    @memcpy(copy[0..n], s[0..n]);
    copy[n] = 0;
    return copy;
}

/// Split on any of `separators`, keeping the place in the caller's own
/// pointer. The reentrant one: `strtok`'s hidden state is a global nobody can
/// see, and two loops using it at once is a bug that looks like data
/// corruption.
export fn strtok_r(text: ?[*:0]u8, separators: [*:0]const u8, save: *?[*:0]u8) callconv(.c) ?[*:0]u8 {
    var at = text orelse (save.* orelse return null);

    while (at[0] != 0 and isSeparator(at[0], separators)) at += 1;
    if (at[0] == 0) {
        save.* = at;
        return null;
    }

    const start = at;
    while (at[0] != 0 and !isSeparator(at[0], separators)) at += 1;
    if (at[0] != 0) {
        at[0] = 0;
        at += 1;
    }
    save.* = at;
    return start;
}

var token_state: ?[*:0]u8 = null;

export fn strtok(text: ?[*:0]u8, separators: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    return strtok_r(text, separators, &token_state);
}

fn isSeparator(c: u8, separators: [*:0]const u8) bool {
    var i: usize = 0;
    while (separators[i] != 0) : (i += 1) {
        if (separators[i] == c) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Character tests
// ---------------------------------------------------------------------------
//
// C only, and deliberately: there is no locale machinery here, so these answer
// for ASCII and leave anything above it alone. UTF-8 text passes through
// unharmed because every byte of a multi-byte sequence has the high bit set
// and none of these claims one.

export fn isalpha(c: c_int) callconv(.c) c_int {
    return yes(isLower(c) or isUpper(c));
}
export fn isdigit(c: c_int) callconv(.c) c_int {
    return yes(c >= '0' and c <= '9');
}
export fn isalnum(c: c_int) callconv(.c) c_int {
    return yes(isalpha(c) != 0 or isdigit(c) != 0);
}
export fn isspace(c: c_int) callconv(.c) c_int {
    return yes(c == ' ' or (c >= '\t' and c <= '\r'));
}
export fn isupper(c: c_int) callconv(.c) c_int {
    return yes(isUpper(c));
}
export fn islower(c: c_int) callconv(.c) c_int {
    return yes(isLower(c));
}
export fn isprint(c: c_int) callconv(.c) c_int {
    return yes(c >= 0x20 and c < 0x7F);
}
export fn isgraph(c: c_int) callconv(.c) c_int {
    return yes(c > 0x20 and c < 0x7F);
}
export fn iscntrl(c: c_int) callconv(.c) c_int {
    return yes(c < 0x20 or c == 0x7F);
}
export fn ispunct(c: c_int) callconv(.c) c_int {
    return yes(isgraph(c) != 0 and isalnum(c) == 0);
}
export fn isxdigit(c: c_int) callconv(.c) c_int {
    return yes(isdigit(c) != 0 or (lowerInt(c) >= 'a' and lowerInt(c) <= 'f'));
}
export fn toupper(c: c_int) callconv(.c) c_int {
    return if (isLower(c)) c - 32 else c;
}
export fn tolower(c: c_int) callconv(.c) c_int {
    return lowerInt(c);
}

fn isLower(c: c_int) bool {
    return c >= 'a' and c <= 'z';
}
fn isUpper(c: c_int) bool {
    return c >= 'A' and c <= 'Z';
}
fn lowerInt(c: c_int) c_int {
    return if (isUpper(c)) c + 32 else c;
}
fn lower(c: u8) u8 {
    return if (c >= 'A' and c <= 'Z') c + 32 else c;
}
fn yes(condition: bool) c_int {
    return if (condition) 1 else 0;
}

const mem = @import("mem.zig");

/// A terminated string as a slice, for the parts of this library that work in
/// Zig terms once they have crossed the boundary.
pub fn spanOf(text: [*:0]const u8) []const u8 {
    return text[0..strlen(text)];
}

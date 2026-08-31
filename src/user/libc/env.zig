//! The environment: what a program was told about where it is.
//!
//! A list of `NAME=value` strings the parent handed over, arriving on the
//! stack after the arguments because that is where C's `main` looks for
//! it. Reading it is a walk; changing it is not, because the list as
//! handed over lives on the stack and cannot grow.
//!
//! So the first change copies the list somewhere it can grow, and every
//! change after that works on the copy. A program that only reads pays
//! nothing for the possibility.

const heap = @import("ulib").heap;
const string = @import("string.zig");

/// The list itself, as C names it. Every program has one, and a program
/// told nothing has one with no entries rather than a null nothing can
/// walk.
pub export var environ: [*c][*c]u8 = @ptrCast(&nothing);

var nothing: [1]?[*:0]u8 = .{null};

/// Whether the list is ours to change. Until something changes it, it is
/// the one the parent built and lives on the stack.
var owned = false;
var entries: [*c][*c]u8 = undefined;
var count: usize = 0;
var room: usize = 0;

/// Take the list the kernel left on the stack. Called before `main`.
pub fn adopt(from: [*c][*c]u8) void {
    environ = from;
    owned = false;
}

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

export fn getenv(name: [*:0]const u8) callconv(.c) ?[*:0]u8 {
    const wanted = string.spanOf(name);
    if (wanted.len == 0) return null;

    const at = find(wanted) orelse return null;
    // The value begins after the name and the sign between them. The
    // entry is one string, so this points into it rather than copying:
    // C promises the answer stays valid until the variable changes.
    const entry: [*:0]u8 = @ptrCast(environ[at]);
    return @ptrCast(entry + wanted.len + 1);
}

/// Whether an entry is `name=` followed by anything.
///
/// The whole name has to match and the next character has to be the
/// sign, so `HOMEBREW` is not `HOME` and `HOM` is not either.
fn names(entry: [*:0]const u8, name: []const u8) bool {
    for (name, 0..) |c, i| {
        if (entry[i] != c) return false;
    }
    return entry[name.len] == '=';
}

// ---------------------------------------------------------------------------
// Changing
// ---------------------------------------------------------------------------

/// How much the list grows by when it runs out of room. Environments are
/// small and are added to a few at a time.
const STEP = 8;

export fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) callconv(.c) c_int {
    // Both strings are measured once, into locals, before anything is
    // decided with them. Measuring one inside the call that uses it reads
    // as the same thing and is not: what arrives is not the string the
    // caller passed.
    const wanted = string.spanOf(name);
    const setting = string.spanOf(value);
    if (wanted.len == 0 or indexOfByte(wanted, '=') != null) return -1;

    // The list is made ours before anything is looked up in it. Finding
    // an index first and taking the list afterwards means the index was
    // into a list that no longer exists, and the write lands somewhere
    // that is nobody's: what looked like an overwrite becomes a second
    // entry with the same name, and the first one goes on answering.
    if (!take()) return -1;

    if (find(wanted)) |at| {
        if (overwrite == 0) return 0;
        entries[at] = join(wanted, setting) orelse return -1;
        return 0;
    }

    const made = join(wanted, setting) orelse return -1;
    return if (append(made)) 0 else -1;
}

/// C's older way in, where the caller's own string becomes the entry.
/// Taken at its word: the string is not copied, so a caller that frees it
/// has removed something from its own environment.
export fn putenv(entry: [*c]u8) callconv(.c) c_int {
    if (entry == null) return -1;
    const text = string.spanOf(@ptrCast(entry));
    const split = indexOfByte(text, '=') orelse return -1;

    if (!take()) return -1;
    if (find(text[0..split])) |at| {
        entries[at] = entry;
        return 0;
    }
    return if (append(entry)) 0 else -1;
}

export fn unsetenv(name: [*:0]const u8) callconv(.c) c_int {
    const wanted = string.spanOf(name);
    if (wanted.len == 0 or indexOfByte(wanted, '=') != null) return -1;

    if (!take()) return -1;
    const at = find(wanted) orelse return 0;

    // The last entry moves into the gap. Order is not something an
    // environment promises, and shifting the rest would be work for a
    // promise nobody made.
    count -= 1;
    entries[at] = entries[count];
    entries[count] = null;
    return 0;
}

/// Where a name sits in the list, if it is there.
fn find(name: []const u8) ?usize {
    var i: usize = 0;
    while (environ[i]) |entry| : (i += 1) {
        if (names(@ptrCast(entry), name)) return i;
    }
    return null;
}

/// Move the list somewhere it can grow.
///
/// The one the parent handed over is on the stack, sized exactly, and
/// shared with nothing: it cannot be extended and must not be written
/// through. So the first change makes a copy, and `environ` points at
/// that from then on.
fn take() bool {
    if (owned) return true;

    var have: usize = 0;
    while (environ[have] != null) have += 1;

    const wanted = have + STEP;
    const block = heap.alloc(@sizeOf(usize) * (wanted + 1)) orelse return false;
    const list: [*c][*c]u8 = @alignCast(@ptrCast(block));

    for (0..have) |i| list[i] = environ[i];
    list[have] = null;

    entries = list;
    count = have;
    room = wanted;
    environ = list;
    owned = true;
    return true;
}

fn append(entry: [*c]u8) bool {
    if (!take()) return false;

    if (count + 1 >= room) {
        const wanted = room + STEP;
        const block = heap.alloc(@sizeOf(usize) * (wanted + 1)) orelse return false;
        const list: [*c][*c]u8 = @alignCast(@ptrCast(block));

        for (0..count) |i| list[i] = entries[i];
        heap.release(@ptrCast(entries));

        entries = list;
        room = wanted;
        environ = list;
    }

    entries[count] = entry;
    count += 1;
    entries[count] = null;
    return true;
}

/// `NAME=value` in one allocation, which is what an entry is.
fn join(name: []const u8, value: []const u8) ?[*c]u8 {
    const block = heap.alloc(name.len + 1 + value.len + 1) orelse return null;
    const made: [*]u8 = @ptrCast(block);

    @memcpy(made[0..name.len], name);
    made[name.len] = '=';
    @memcpy(made[name.len + 1 ..][0..value.len], value);
    made[name.len + 1 + value.len] = 0;
    return @ptrCast(made);
}

fn indexOfByte(text: []const u8, byte: u8) ?usize {
    for (text, 0..) |c, i| {
        if (c == byte) return i;
    }
    return null;
}

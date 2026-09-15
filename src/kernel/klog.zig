//! What the kernel said, kept so someone can read it later.
//!
//! Every message goes here whether or not it was printed. A quiet boot shows
//! almost nothing on screen by design, and the machine still knows what
//! happened; without a record, finding out would mean rebooting with `verbose`
//! and hoping the fault repeats.
//!
//! A ring rather than a growing buffer: this has to work before there is a
//! heap, it must never be the reason a boot fails, and what matters most is
//! always the newest few thousand bytes. When it wraps, the oldest line goes.

const std = @import("std");
const event = @import("event.zig");
const hal = @import("hal.zig");

/// Sixteen kilobytes holds a verbose boot, the services' lines included,
/// with room to spare, and is small enough not to be worth thinking about
/// against 512 MB.
pub const CAPACITY = 16 * 1024;

/// The record itself, apart from the guard around it, so that what it
/// keeps and how it wraps can be checked on the host.
pub const Ring = struct {
    buffer: []u8,
    /// Where the next byte goes.
    head: usize = 0,
    /// Total bytes ever written, so a reader knows whether the ring has
    /// wrapped and how much of it is real.
    written: usize = 0,

    pub fn append(self: *Ring, bytes: []const u8) void {
        for (bytes) |b| {
            self.buffer[self.head] = b;
            self.head = (self.head + 1) % self.buffer.len;
            self.written +|= 1;
        }
    }

    /// How much is currently held.
    pub fn len(self: *const Ring) usize {
        return @min(self.written, self.buffer.len);
    }

    /// Copy the record out, oldest first, and return how many bytes that
    /// was.
    ///
    /// Truncated from the front when the caller's buffer is smaller: the
    /// newest messages are the ones being looked for, and losing the start
    /// of a boot log is better than losing the failure at the end of it.
    pub fn copyOut(self: *const Ring, out: []u8) usize {
        const held = self.len();
        const take = @min(held, out.len);
        if (take == 0) return 0;

        // Where the bytes to copy begin, counting back from the write
        // position.
        const capacity = self.buffer.len;
        const start = (self.head + capacity - take) % capacity;
        const first = @min(take, capacity - start);

        @memcpy(out[0..first], self.buffer[start..][0..first]);
        if (first < take) @memcpy(out[first..take], self.buffer[0 .. take - first]);
        return take;
    }

    /// What a reader that had got as far as `from` has not seen yet.
    pub const Since = struct {
        /// How much was copied out.
        bytes: usize,
        /// How far the reader has got now, to hand back next time.
        next: usize,
        /// How much was written and overwritten before the reader came
        /// back for it. A reader that falls further behind than the ring
        /// is deep loses the middle, and is told so rather than handed a
        /// record with a silent hole in it.
        missed: usize,
    };

    /// Everything written since `from`, oldest first.
    ///
    /// Positions are totals ever written rather than places in the buffer,
    /// so they do not wrap and a reader holds one number. A reader from
    /// the future, which is what a ring that was reset under one looks
    /// like, is taken back to the oldest byte there is rather than being
    /// told the record is empty forever.
    pub fn copyFrom(self: *const Ring, from: usize, out: []u8) Since {
        const first_held = self.written - self.len();
        const start = if (from < first_held) first_held else @min(from, self.written);
        const missed = start -| from;

        const available = self.written - start;
        const take = @min(available, out.len);
        if (take == 0) return .{ .bytes = 0, .next = start, .missed = missed };

        const capacity = self.buffer.len;
        const at = (self.head + capacity - (self.written - start)) % capacity;
        const first = @min(take, capacity - at);

        @memcpy(out[0..first], self.buffer[at..][0..first]);
        if (first < take) @memcpy(out[first..take], self.buffer[0 .. take - first]);
        return .{ .bytes = take, .next = start + take, .missed = missed };
    }
};

var buffer: [CAPACITY]u8 = undefined;
var record: Ring = .{ .buffer = &buffer };

/// Add to the record. Lines come from interrupt context as well as from
/// threads, and two writers on one ring would interleave their bytes, so an
/// append is one step nothing can get inside.
pub fn append(bytes: []const u8) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    record.append(bytes);
    grew();
}

/// Add a line to the record: the bytes and the newline after them in one
/// step, so nothing else's line lands between the two.
pub fn appendLine(bytes: []const u8) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    record.append(bytes);
    record.append("\n");
    grew();
}

/// How much is currently held.
pub fn len() usize {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    return record.len();
}

/// Copy the record out, oldest first, and return how many bytes that was.
pub fn copyOut(out: []u8) usize {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    return record.copyOut(out);
}

/// Where a reader that has seen nothing starts, which is the oldest byte
/// the ring still holds rather than zero: a follower attached to a machine
/// that has been up for a while wants what is there, not a refusal.
pub fn oldest() usize {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    return record.written - record.len();
}

/// Everything written since `from`. See `Ring.copyFrom`.
pub fn copyFrom(from: usize, out: []u8) Ring.Since {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    // Cleared before the copy rather than after it: anything appended
    // while this runs is then announced again, which costs a follower one
    // pass that finds nothing. The other order loses the announcement
    // altogether, which costs it the line.
    announced = false;
    return record.copyFrom(from, out);
}

// ---------------------------------------------------------------------------
// Following it
// ---------------------------------------------------------------------------

/// The one event the machine signals when it has said something.
///
/// One for the machine rather than one per reader: what a follower wants
/// to know is that there is something to read, and that is the same fact
/// whoever is asking.
var follower: ?*event.Event = null;

/// Whether a signal is outstanding. A boot that says a hundred things
/// wakes a follower once per pass rather than a hundred times: the event
/// is a fact about the record, not a count of lines.
var announced = false;

/// Called with interrupts already off, from every path that adds to the
/// record.
fn grew() void {
    if (announced) return;
    const waiting = follower orelse return;
    announced = true;
    waiting.signalLocked();
}

/// The event to wait on, made the first time somebody asks for it. Null
/// only when there is no memory for one.
pub fn watch() ?*event.Event {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);
    if (follower) |waiting| return waiting;
    follower = event.create() catch return null;
    // Whatever is already in the record is something to read, so a
    // follower that has just attached does not wait for the next line.
    announced = true;
    follower.?.signalLocked();
    return follower;
}

test "a short record comes back whole" {
    var space: [64]u8 = undefined;
    var ring = Ring{ .buffer = &space };
    ring.append("hello");
    var out: [16]u8 = undefined;
    try std.testing.expectEqualStrings("hello", out[0..ring.copyOut(&out)]);
}

test "wrapping keeps the newest bytes" {
    var space: [CAPACITY]u8 = undefined;
    var ring = Ring{ .buffer = &space };
    for (0..CAPACITY + 4) |i| ring.append(&.{@as(u8, @intCast('a' + i % 26))});

    var out: [8]u8 = undefined;
    const n = ring.copyOut(&out);
    try std.testing.expectEqual(@as(usize, 8), n);

    // The last eight written, in order.
    var want: [8]u8 = undefined;
    for (0..8) |i| want[i] = @intCast('a' + (CAPACITY + 4 - 8 + i) % 26);
    try std.testing.expectEqualSlices(u8, &want, out[0..n]);
}

test "a buffer smaller than the record keeps the end of it" {
    var space: [64]u8 = undefined;
    var ring = Ring{ .buffer = &space };
    ring.append("abcdefgh");
    var out: [3]u8 = undefined;
    try std.testing.expectEqualStrings("fgh", out[0..ring.copyOut(&out)]);
}

test "a follower is given what it has not seen and told where it got to" {
    var space: [64]u8 = undefined;
    var ring = Ring{ .buffer = &space };
    var out: [64]u8 = undefined;

    // Nothing written is nothing to read, and the position stays put.
    var seen = ring.copyFrom(0, &out);
    try std.testing.expectEqual(@as(usize, 0), seen.bytes);
    try std.testing.expectEqual(@as(usize, 0), seen.next);

    ring.append("first ");
    seen = ring.copyFrom(seen.next, &out);
    try std.testing.expectEqualStrings("first ", out[0..seen.bytes]);
    try std.testing.expectEqual(@as(usize, 0), seen.missed);

    // Only what came after: a follower is not handed the same line twice.
    ring.append("second");
    seen = ring.copyFrom(seen.next, &out);
    try std.testing.expectEqualStrings("second", out[0..seen.bytes]);
    try std.testing.expectEqual(@as(usize, 12), seen.next);

    // And nothing at all when it has caught up.
    seen = ring.copyFrom(seen.next, &out);
    try std.testing.expectEqual(@as(usize, 0), seen.bytes);
    try std.testing.expectEqual(@as(usize, 12), seen.next);
}

test "a follower given less room than there is comes back for the rest" {
    var space: [64]u8 = undefined;
    var ring = Ring{ .buffer = &space };
    ring.append("abcdefghij");

    var out: [4]u8 = undefined;
    var seen = ring.copyFrom(0, &out);
    try std.testing.expectEqualStrings("abcd", out[0..seen.bytes]);
    seen = ring.copyFrom(seen.next, &out);
    try std.testing.expectEqualStrings("efgh", out[0..seen.bytes]);
    seen = ring.copyFrom(seen.next, &out);
    try std.testing.expectEqualStrings("ij", out[0..seen.bytes]);
    try std.testing.expectEqual(@as(usize, 0), seen.missed);
}

test "a follower that falls behind the ring is told what it lost" {
    var space: [8]u8 = undefined;
    var ring = Ring{ .buffer = &space };
    var out: [32]u8 = undefined;

    ring.append("12345678");
    // Twelve bytes written into eight: the first four are gone.
    ring.append("abcd");
    const seen = ring.copyFrom(0, &out);
    try std.testing.expectEqual(@as(usize, 4), seen.missed);
    try std.testing.expectEqualStrings("5678abcd", out[0..seen.bytes]);
    try std.testing.expectEqual(@as(usize, 12), seen.next);
}

test "a position from before the record began is taken to the oldest byte" {
    var space: [8]u8 = undefined;
    var ring = Ring{ .buffer = &space };
    var out: [32]u8 = undefined;
    ring.append("0123456789");

    // A follower holding a position the ring has passed, and one holding
    // a position the ring has not reached, both land somewhere real.
    const behind = ring.copyFrom(0, &out);
    try std.testing.expectEqualStrings("23456789", out[0..behind.bytes]);
    const ahead = ring.copyFrom(99, &out);
    try std.testing.expectEqual(@as(usize, 0), ahead.bytes);
    try std.testing.expectEqual(@as(usize, 10), ahead.next);
}

test "what a follower reads matches what the whole record says" {
    var space: [32]u8 = undefined;
    var ring = Ring{ .buffer = &space };
    var gathered: [32]u8 = undefined;
    var n: usize = 0;
    var at: usize = 0;

    // Written a piece at a time and followed a piece at a time: what the
    // follower ends up with is the tail the ring holds.
    for ([_][]const u8{ "alpha ", "beta ", "gamma ", "delta " }) |piece| {
        ring.append(piece);
        var out: [8]u8 = undefined;
        while (true) {
            const seen = ring.copyFrom(at, &out);
            at = seen.next;
            if (seen.bytes == 0) break;
            @memcpy(gathered[n..][0..seen.bytes], out[0..seen.bytes]);
            n += seen.bytes;
        }
    }

    var whole: [32]u8 = undefined;
    const held = ring.copyOut(&whole);
    try std.testing.expectEqualStrings(whole[0..held], gathered[n - held .. n]);
}

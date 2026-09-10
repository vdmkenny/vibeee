//! Text out of a stream: head, tail, wc, sort.
//!
//! The shell has pipes and redirection, and until these there was almost
//! nothing to put on the far end of one. Each reads the files it is named or
//! standard input when it is named none, so each is at home in the middle of
//! a pipeline.
//!
//! What a line is comes from `ulib.lines` and is not decided again here.

const std = @import("std");
const heap = @import("ulib").heap;
const lines = @import("ulib").lines;
const out = @import("ulib").out;
const str = @import("lib").str;
const sys = @import("sys");

/// Beside the other state rather than on the frame: a reader is kilobytes and
/// the user stack is not many of them. One, because no tool here reads two
/// streams at once.
var reader: lines.Reader = .{};

/// Open each named file in turn, or hand over standard input when none is
/// named, saying so about any that will not open.
fn overEach(tool: []const u8, paths: []const []const u8, ctx: anytype, comptime each: fn (@TypeOf(ctx), []const u8) void) void {
    if (paths.len == 0) {
        reader = lines.Reader.of(sys.STDIN);
        each(ctx, "");
        return;
    }
    for (paths) |path| {
        const handle = sys.open(path, .{}) catch {
            out.fault(tool, path, "cannot open");
            continue;
        };
        defer sys.close(handle);
        reader = lines.Reader.of(handle);
        each(ctx, path);
    }
}

/// How many lines head and tail take when nobody says.
const DEFAULT_LINES = 10;

/// `-n` and its count, or the default. The count is the only option any of
/// these take, so parsing it is this one place.
fn wanted(args: []const []const u8) struct { count: usize, rest: []const []const u8 } {
    if (args.len >= 2 and std.mem.eql(u8, args[0], "-n")) {
        if (str.unsigned(args[1])) |n| return .{ .count = @intCast(n), .rest = args[2..] };
    }
    return .{ .count = DEFAULT_LINES, .rest = args };
}

// ---------------------------------------------------------------------------
// head
// ---------------------------------------------------------------------------

pub fn head(args: []const []const u8) void {
    const asked = wanted(args);
    overEach("head", asked.rest, asked.count, headOne);
    out.flush();
}

fn headOne(count: usize, _: []const u8) void {
    var seen: usize = 0;
    while (seen < count) : (seen += 1) {
        const line = reader.next() orelse break;
        out.text(line);
        out.byte('\n');
    }
}

// ---------------------------------------------------------------------------
// tail
// ---------------------------------------------------------------------------

/// The last lines are kept in a ring the size of what was asked for, so a
/// file of any length costs one pass and the room for its ending. Reading it
/// twice to find where the ending starts would cost a second walk of the
/// whole file for nothing.
const TAIL_MAX = 256;

var ring: [TAIL_MAX][lines.MAX]u8 = undefined;
var ring_len: [TAIL_MAX]usize = undefined;

pub fn tail(args: []const []const u8) void {
    const asked = wanted(args);
    if (asked.count > TAIL_MAX) {
        out.fault("tail", "", "more lines than are kept; ask for fewer");
        out.flush();
        return;
    }
    overEach("tail", asked.rest, asked.count, tailOne);
    out.flush();
}

fn tailOne(count: usize, _: []const u8) void {
    if (count == 0) return;

    var held: usize = 0;
    var at: usize = 0;
    while (reader.next()) |line| {
        const kept = @min(line.len, lines.MAX);
        @memcpy(ring[at][0..kept], line[0..kept]);
        ring_len[at] = kept;
        at = (at + 1) % count;
        held += 1;
    }

    // Where the ending starts: the whole ring when it filled, and the front
    // of it when the stream was shorter than what was asked for.
    const show = @min(held, count);
    const first = if (held < count) 0 else at;
    for (0..show) |i| {
        const slot = (first + i) % count;
        out.text(ring[slot][0..ring_len[slot]]);
        out.byte('\n');
    }
}

// ---------------------------------------------------------------------------
// wc
// ---------------------------------------------------------------------------

const Count = struct {
    lines: usize = 0,
    words: usize = 0,
    bytes: usize = 0,

    fn add(self: *Count, other: Count) void {
        self.lines += other.lines;
        self.words += other.words;
        self.bytes += other.bytes;
    }

    fn write(self: Count, name: []const u8) void {
        out.decimalRight(self.lines, 8);
        out.decimalRight(self.words, 8);
        out.decimalRight(self.bytes, 9);
        if (name.len != 0) {
            out.byte(' ');
            out.text(name);
        }
        out.byte('\n');
    }
};

var total: Count = .{};
var counted_files: usize = 0;

pub fn wc(args: []const []const u8) void {
    total = .{};
    counted_files = 0;
    overEach("wc", args, {}, wcOne);
    // A total only where there was more than one thing to total.
    if (counted_files > 1) total.write("total");
    out.flush();
}

fn wcOne(_: void, name: []const u8) void {
    var count: Count = .{};
    while (reader.next()) |_| {
        count.lines += 1;
        // The line's own length and its own words, not those of the part
        // that fit: a line longer than the reader keeps is still that many
        // bytes of the file, and counting what came back reported a
        // thousand-byte line for every length beyond it.
        //
        // The newline the reader took off is a byte the file had, wherever
        // there was one; the last line of a file that ends without one has
        // no newline to count.
        count.bytes += reader.full + @intFromBool(!reader.spent);
        count.words += reader.words;
    }
    count.write(name);
    total.add(count);
    counted_files += 1;
}

// ---------------------------------------------------------------------------
// sort
// ---------------------------------------------------------------------------

/// Every line at once, which is what sorting is. Held on the heap rather than
/// in a fixed table: a sort that refused a long file would send anybody who
/// met one back to doing it by hand.
pub fn sort(args: []const []const u8) void {
    const gpa = heap.allocator;

    var held: std.ArrayList([]const u8) = .empty;
    defer {
        for (held.items) |line| gpa.free(line);
        held.deinit(gpa);
    }

    overEach("sort", args, &held, sortOne);

    // The library's own sort keeps a cache of five hundred and twelve of
    // whatever it is sorting in its frame. `ulib.dir` cannot afford that for
    // a directory entry; for a slice it is four kilobytes, and nothing here
    // sorts from inside anything else.
    std.mem.sort([]const u8, held.items, {}, lineBefore);

    for (held.items) |line| {
        out.text(line);
        out.byte('\n');
    }
    out.flush();
}

fn sortOne(held: *std.ArrayList([]const u8), _: []const u8) void {
    const gpa = heap.allocator;
    while (reader.next()) |line| {
        const kept = gpa.dupe(u8, line) catch {
            out.fault("sort", "", "not enough memory to hold the whole of it");
            return;
        };
        held.append(gpa, kept) catch {
            gpa.free(kept);
            out.fault("sort", "", "not enough memory to hold the whole of it");
            return;
        };
    }
}

/// Folded, the way a listing sorts: a file whose lines start with capitals
/// should not sort into two groups.
fn lineBefore(_: void, a: []const u8, b: []const u8) bool {
    return str.before(a, b);
}

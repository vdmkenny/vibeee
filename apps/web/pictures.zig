//! A page's pictures: fetched one at a time once its words are on screen,
//! decoded, and kept at the widest they are drawn.
//!
//! One at a time, because the machine has one processor and a picture is a
//! site to reach, a file to take in and a decode: several at once would
//! make each of them later, and the first one latest of all. One after
//! another, they share one connection where the site keeps it open. The page
//! is read while they come, and each takes its place as it arrives, what the
//! page says it shows standing in for it until then.
//!
//! The first asked for is the first at or below the top of the view, so
//! what somebody is looking at arrives first; the rest follow in the page's
//! order.
//!
//! Kept small. A picture is shrunk as it is decoded to the widest a column
//! is drawn, and its file and its full-sized pixels are let go at once. What
//! a page's pictures hold between them is bounded, and a picture past the
//! bound, like one too large to decode, keeps what stands in for it.

const std = @import("std");
const img = @import("img");
const rgb = @import("lib").rgb;
const ulib = @import("ulib");

const fetch_mod = @import("fetch.zig");
const page_mod = @import("page.zig");
const url = @import("url.zig");

const Page = page_mod.Page;

/// The most pixels a picture may have to be decoded at all: four million,
/// which is sixteen megabytes for the moment it takes to shrink them.
const DECODED_MAX = 4 * 1024 * 1024;

/// The most pixels one picture is kept with. A picture many screens tall is
/// kept coarser, and drawn from what is kept.
const KEPT_MAX = 1024 * 1024;

/// The most a page's pictures hold between them once shrunk, in bytes.
const HELD_MAX = 16 * 1024 * 1024;

/// A size in pixels.
pub const Size = struct { w: u16, h: u16 };

pub const State = union(enum) {
    /// Not asked for yet.
    waiting,
    /// On its way.
    coming,
    here: Kept,
    /// Not to be had: nowhere to fetch it from, not found, not a picture this
    /// reader decodes, or more than it holds.
    failed,
};

/// A picture as it is kept.
pub const Kept = struct {
    /// Its pixels, at the size they are kept.
    picture: img.Picture,
    /// Its own size, which a page that gives none lays it out at.
    own: Size,
};

/// What a step came to.
pub const Step = union(enum) {
    /// Waiting on the network, as the fetch says.
    wait: fetch_mod.Wait,
    /// This picture has arrived, or will not: the room it takes has changed.
    settled: u16,
    /// Nothing is on its way, and nothing more is to be asked for.
    idle,
};

pub const Pictures = struct {
    /// One for each of the page's pictures.
    states: []State = &.{},
    /// Whether pictures are fetched at all, which is a setting.
    enabled: bool = true,
    /// Stopped by hand: nothing more is asked for until the next page.
    halted: bool = false,
    /// The widest a picture is drawn, which is what it is shrunk to.
    widest: u16 = 480,
    /// What the pictures that are here hold between them, in bytes.
    held: usize = 0,

    fetch: fetch_mod.Fetch = .{ .wanted = .picture },
    /// Which picture the fetch is for, while it is for one.
    fetching: ?u16 = null,

    /// Take on `page`'s pictures, letting go of the last page's.
    pub fn show(self: *Pictures, gpa: std.mem.Allocator, page: *const Page, widest: u16) void {
        self.forget(gpa);
        self.widest = widest;
        // A page with no room to follow its pictures still reads: they are
        // stood in for, as pictures that will not come are.
        self.states = gpa.alloc(State, page.pictures.items.len) catch &.{};
        for (self.states, page.pictures.items) |*state, picture| {
            state.* = if (picture.source.len == 0) .failed else .waiting;
        }
    }

    /// Let go of every picture, and of the one on its way.
    pub fn forget(self: *Pictures, gpa: std.mem.Allocator) void {
        self.fetch.cancel(gpa);
        for (self.states) |state| switch (state) {
            .here => |kept| gpa.free(kept.picture.pixels),
            .waiting, .coming, .failed => {},
        };
        gpa.free(self.states);
        const enabled = self.enabled;
        const widest = self.widest;
        self.* = .{ .enabled = enabled, .widest = widest };
    }

    /// Put the picture on its way back, to be asked for again later: the
    /// network is wanted for a page.
    pub fn pause(self: *Pictures, gpa: std.mem.Allocator) void {
        const index = self.fetching orelse return;
        self.fetch.cancel(gpa);
        self.fetching = null;
        self.states[index] = .waiting;
    }

    /// Ask for nothing more of this page's pictures.
    pub fn halt(self: *Pictures, gpa: std.mem.Allocator) void {
        self.pause(gpa);
        self.halted = true;
    }

    /// Whether the pictures still to come are being asked for.
    pub fn expected(self: *const Pictures) bool {
        return self.enabled and !self.halted;
    }

    /// Whether a picture is on its way, or one is still to be asked for.
    pub fn busy(self: *const Pictures) bool {
        return self.fetching != null or (self.expected() and self.waitingFrom(0) != null);
    }

    pub fn stateOf(self: *const Pictures, index: u16) State {
        return if (index < self.states.len) self.states[index] else .failed;
    }

    /// How many of the page's pictures are settled, and of how many.
    pub fn tally(self: *const Pictures) struct { settled: usize, total: usize } {
        var settled: usize = 0;
        for (self.states) |state| switch (state) {
            .here, .failed => settled += 1,
            .waiting, .coming => {},
        };
        return .{ .settled = settled, .total = self.states.len };
    }

    /// Take the next step: ask for the next picture, the first still waiting
    /// from `from` on, or take what has arrived of the one on its way.
    pub fn advance(self: *Pictures, gpa: std.mem.Allocator, page: *const Page, from: u16) Step {
        if (self.fetching == null) {
            const next = if (self.expected()) self.waitingFrom(from) orelse self.waitingFrom(0) else null;
            if (next) |index| return self.begin(gpa, page, index);
            // Nothing more to ask for, so a connection kept for the next
            // picture has none to carry.
            self.fetch.cancel(gpa);
            return .idle;
        }
        const wait = self.fetch.advance(gpa);
        if (wait != .over) return .{ .wait = wait };
        return .{ .settled = self.arrive(gpa) };
    }

    /// The first picture still waiting at or after `from`.
    fn waitingFrom(self: *const Pictures, from: usize) ?u16 {
        if (from >= self.states.len) return null;
        for (self.states[from..], from..) |state, index| {
            if (state == .waiting) return @intCast(index);
        }
        return null;
    }

    fn begin(self: *Pictures, gpa: std.mem.Allocator, page: *const Page, index: u16) Step {
        const source = page.string(page.pictures.items[index].source);
        const where = url.parse(source) orelse {
            self.states[index] = .failed;
            return .{ .settled = index };
        };
        if (where.scheme == .file) {
            // A picture on this machine is read in one go, having nobody to
            // wait for.
            const bytes = ulib.file.readAlloc(gpa, where.file(), fetch_mod.PICTURE_MAX) catch {
                self.states[index] = .failed;
                return .{ .settled = index };
            };
            defer gpa.free(bytes);
            self.states[index] = self.take(gpa, bytes);
            return .{ .settled = index };
        }
        self.states[index] = .coming;
        self.fetching = index;
        self.fetch.begin(gpa, source);
        // Reaching the site blocks, so it waits for the next chance, once the
        // pass that says a picture is coming has been drawn.
        return .{ .wait = .none };
    }

    /// The fetch is over: the picture, or the end of trying for it.
    fn arrive(self: *Pictures, gpa: std.mem.Allocator) u16 {
        const index = self.fetching.?;
        self.fetching = null;
        defer self.fetch.release(gpa);
        const answered = self.fetch.state == .done and self.fetch.response.status / 100 == 2;
        self.states[index] = if (answered) self.take(gpa, self.fetch.body.bytes.items) else .failed;
        return index;
    }

    /// A picture from its file, kept at the widest it is drawn.
    fn take(self: *Pictures, gpa: std.mem.Allocator, bytes: []const u8) State {
        const shape = img.shapeOf(bytes) catch return .failed;
        if (@as(usize, shape.width) * shape.height > DECODED_MAX) return .failed;
        const own = Size{ .w = shape.width, .h = shape.height };
        const kept = keptSize(own, self.widest);
        const count = @as(usize, kept.w) * kept.h;
        const weight = count * @sizeOf(rgb.Colour);
        if (self.held + weight > HELD_MAX) return .failed;

        const full = img.decode(bytes) catch return .failed;
        defer full.deinit();
        const pixels = gpa.alloc(rgb.Colour, count) catch return .failed;
        self.held += weight;
        return .{ .here = .{ .picture = img.shrunk(full, kept.w, kept.h, pixels), .own = own } };
    }
};

/// The size a picture is kept at: its own, or no wider than a column is ever
/// drawn, keeping its shape; and coarser again where that would still be
/// more pixels than one picture is kept with.
fn keptSize(own: Size, widest: u16) Size {
    var kept = own;
    if (kept.w > widest) kept = .{ .w = widest, .h = @intCast(@max(@as(u32, own.h) * widest / own.w, 1)) };
    while (@as(usize, kept.w) * kept.h > KEPT_MAX) kept = .{ .w = @max(kept.w / 2, 1), .h = @max(kept.h / 2, 1) };
    return kept;
}

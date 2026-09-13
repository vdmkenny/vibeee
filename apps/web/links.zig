//! Things a page links to that the reader fetches one after another, as a
//! bounded list: its stylesheets, and its scripts.
//!
//! Bounded twice, in how many are fetched and in what those that came may
//! come to between them, so a page that links to everything is read with
//! what it names first.
//!
//! Pure and host-tested.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// A link to fetch: where it is, and the media its link names, which for a
/// stylesheet says which windows it is for and for a script is empty.
pub const Link = struct { address: []const u8, media: []const u8 };

/// At most `max` links, whose fetched bodies may come to `bytes_max` between
/// them.
pub fn Queue(comptime max: usize, comptime bytes_max: usize) type {
    return struct {
        const Self = @This();

        links: std.ArrayList(Link) = .empty,
        /// How many have been handed out to fetch, and what those that came
        /// came to.
        taken: usize = 0,
        spent: usize = 0,

        pub fn deinit(self: *Self, gpa: Allocator) void {
            for (self.links.items) |link| {
                gpa.free(link.address);
                gpa.free(link.media);
            }
            self.links.deinit(gpa);
            self.* = .{};
        }

        /// Keep a link, in the order it was named. Past `max`, it is left
        /// out.
        pub fn add(self: *Self, gpa: Allocator, address: []const u8, media: []const u8) Allocator.Error!void {
            if (self.links.items.len == max) return;
            const kept_address = try gpa.dupe(u8, address);
            errdefer gpa.free(kept_address);
            const kept_media = try gpa.dupe(u8, media);
            errdefer gpa.free(kept_media);
            try self.links.append(gpa, .{ .address = kept_address, .media = kept_media });
        }

        /// The next link to fetch, or nothing once every one has been, or
        /// once those that came have used what they may come to.
        pub fn next(self: *Self) ?Link {
            if (self.taken == self.links.items.len or self.spent >= bytes_max) return null;
            defer self.taken += 1;
            return self.links.items[self.taken];
        }

        /// Count one that came against what they may come to.
        pub fn took(self: *Self, bytes: usize) void {
            self.spent +|= bytes;
        }
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "links are handed out in order, as many as fit, until the budget is spent" {
    var queue: Queue(2, 100) = .{};
    defer queue.deinit(testing.allocator);
    try queue.add(testing.allocator, "https://a.test/one.css", "screen");
    try queue.add(testing.allocator, "https://a.test/two.css", "");
    try queue.add(testing.allocator, "https://a.test/three.css", "");
    try testing.expectEqual(@as(usize, 2), queue.links.items.len);

    const first = queue.next().?;
    try testing.expectEqualStrings("https://a.test/one.css", first.address);
    try testing.expectEqualStrings("screen", first.media);
    queue.took(100);
    try testing.expect(queue.next() == null);
}

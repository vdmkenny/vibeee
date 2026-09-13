//! What a page's scripts put by for the site they are on: `localStorage`, as
//! the reader keeps it while it runs.
//!
//! A site keeps a few words this way: that a notice was seen, which look was
//! chosen. They belong to the site rather than to the page, so they are kept
//! here, outside any page, and handed to each page of the site as it opens.
//! Nothing is written to disk: what is kept lasts as long as the reader does.
//!
//! Bounded twice: how many sites are kept for at once, the site least
//! recently read making room for a new one, and how much each may hold.
//!
//! Pure and host-tested.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// How many sites the reader keeps for at once.
pub const ORIGINS_MAX = 16;

/// The most one site's keys and values come to between them, in bytes.
pub const BUCKET_MAX = 64 * 1024;

/// What one site keeps: keys and their values, in the order they were put.
pub const Bucket = struct {
    entries: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// What the keys and values come to.
    bytes: usize = 0,

    pub fn deinit(self: *Bucket, gpa: Allocator) void {
        self.clear(gpa);
        self.entries.deinit(gpa);
    }

    pub fn get(self: *const Bucket, key: []const u8) ?[]const u8 {
        return self.entries.get(key);
    }

    /// Put `value` under `key`, replacing what was there. False where the
    /// site's room is spent, in which case what was there stays.
    pub fn put(self: *Bucket, gpa: Allocator, key: []const u8, value: []const u8) bool {
        // What the site would hold afterwards: the value in place of the old
        // one, and the key where it is new.
        const old: usize = if (self.entries.get(key)) |kept| kept.len else 0;
        const after = self.bytes - old + value.len + (if (self.entries.contains(key)) @as(usize, 0) else key.len);
        if (after > BUCKET_MAX) return false;
        const kept_value = gpa.dupe(u8, value) catch return false;
        if (self.entries.getPtr(key)) |slot| {
            gpa.free(slot.*);
            slot.* = kept_value;
            self.bytes = after;
            return true;
        }
        const kept_key = gpa.dupe(u8, key) catch {
            gpa.free(kept_value);
            return false;
        };
        self.entries.put(gpa, kept_key, kept_value) catch {
            gpa.free(kept_key);
            gpa.free(kept_value);
            return false;
        };
        self.bytes = after;
        return true;
    }

    pub fn remove(self: *Bucket, gpa: Allocator, key: []const u8) void {
        const gone = self.entries.fetchOrderedRemove(key) orelse return;
        self.bytes -= gone.key.len + gone.value.len;
        gpa.free(gone.key);
        gpa.free(gone.value);
    }

    pub fn clear(self: *Bucket, gpa: Allocator) void {
        for (self.entries.keys(), self.entries.values()) |key, value| {
            gpa.free(key);
            gpa.free(value);
        }
        self.entries.clearRetainingCapacity();
        self.bytes = 0;
    }

    pub fn count(self: *const Bucket) usize {
        return self.entries.count();
    }

    /// The key at `index`, in the order the keys were put.
    pub fn keyAt(self: *const Bucket, index: usize) ?[]const u8 {
        const keys = self.entries.keys();
        return if (index < keys.len) keys[index] else null;
    }
};

/// A site's bucket, and when it was last asked for.
const Kept = struct {
    origin: []const u8,
    bucket: Bucket = .{},
    used: u32 = 0,
};

pub const Storage = struct {
    /// Each site's, where it was made: a page keeps a pointer to its site's
    /// bucket, so a bucket never moves while the site is kept.
    sites: std.ArrayList(*Kept) = .empty,
    /// Counts each asking, so the site least recently asked for is known.
    asked: u32 = 0,

    pub fn deinit(self: *Storage, gpa: Allocator) void {
        for (self.sites.items) |kept| self.drop(gpa, kept);
        self.sites.deinit(gpa);
        self.* = .{};
    }

    /// The bucket for `origin`, made where there is none yet. Where there is
    /// no room for another site's, the site least recently asked for gives
    /// its up. Nothing where the machine has no room for one at all.
    pub fn bucketFor(self: *Storage, gpa: Allocator, origin: []const u8) ?*Bucket {
        self.asked +%= 1;
        for (self.sites.items) |kept| {
            if (std.mem.eql(u8, kept.origin, origin)) {
                kept.used = self.asked;
                return &kept.bucket;
            }
        }
        if (self.sites.items.len == ORIGINS_MAX) self.evict(gpa);
        const kept = gpa.create(Kept) catch return null;
        kept.* = .{ .origin = gpa.dupe(u8, origin) catch {
            gpa.destroy(kept);
            return null;
        }, .used = self.asked };
        self.sites.append(gpa, kept) catch {
            self.drop(gpa, kept);
            return null;
        };
        return &kept.bucket;
    }

    /// Let go of the site least recently asked for.
    fn evict(self: *Storage, gpa: Allocator) void {
        var oldest: usize = 0;
        for (self.sites.items, 0..) |kept, index| {
            if (kept.used < self.sites.items[oldest].used) oldest = index;
        }
        self.drop(gpa, self.sites.swapRemove(oldest));
    }

    fn drop(self: *Storage, gpa: Allocator, kept: *Kept) void {
        _ = self;
        kept.bucket.deinit(gpa);
        gpa.free(kept.origin);
        gpa.destroy(kept);
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "what a site puts by is read back, replaced and taken away" {
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    const site = storage.bucketFor(testing.allocator, "https://a.test").?;
    try testing.expect(site.put(testing.allocator, "seen", "1"));
    try testing.expect(site.put(testing.allocator, "look", "dark"));
    try testing.expectEqualStrings("1", site.get("seen").?);
    try testing.expect(site.put(testing.allocator, "seen", "2"));
    try testing.expectEqualStrings("2", site.get("seen").?);
    try testing.expectEqual(@as(usize, 2), site.count());
    try testing.expectEqualStrings("seen", site.keyAt(0).?);
    try testing.expectEqualStrings("look", site.keyAt(1).?);
    site.remove(testing.allocator, "seen");
    try testing.expect(site.get("seen") == null);
    try testing.expectEqual(@as(usize, 1), site.count());
    site.clear(testing.allocator);
    try testing.expectEqual(@as(usize, 0), site.count());
    try testing.expectEqual(@as(usize, 0), site.bytes);
}

test "each site has its own, and the same site gets the same one again" {
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    const a = storage.bucketFor(testing.allocator, "https://a.test").?;
    try testing.expect(a.put(testing.allocator, "k", "a"));
    const b = storage.bucketFor(testing.allocator, "https://b.test").?;
    try testing.expect(b.get("k") == null);
    try testing.expectEqualStrings("a", storage.bucketFor(testing.allocator, "https://a.test").?.get("k").?);
}

test "a site past its room keeps what it had" {
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    const site = storage.bucketFor(testing.allocator, "https://a.test").?;
    const big = try testing.allocator.alloc(u8, BUCKET_MAX);
    defer testing.allocator.free(big);
    @memset(big, 'x');
    try testing.expect(site.put(testing.allocator, "small", "1"));
    try testing.expect(!site.put(testing.allocator, "big", big));
    try testing.expectEqualStrings("1", site.get("small").?);
}

test "the site least recently asked for makes room for a new one" {
    var storage: Storage = .{};
    defer storage.deinit(testing.allocator);
    var name: [32]u8 = undefined;
    for (0..ORIGINS_MAX) |i| {
        const origin = try std.fmt.bufPrint(&name, "https://{d}.test", .{i});
        try testing.expect(storage.bucketFor(testing.allocator, origin).?.put(testing.allocator, "k", "v"));
    }
    // The first is asked for again, so it is the second that is oldest.
    _ = storage.bucketFor(testing.allocator, "https://0.test");
    _ = storage.bucketFor(testing.allocator, "https://new.test");
    try testing.expectEqual(@as(usize, ORIGINS_MAX), storage.sites.items.len);
    try testing.expectEqualStrings("v", storage.bucketFor(testing.allocator, "https://0.test").?.get("k").?);
    try testing.expect(storage.bucketFor(testing.allocator, "https://1.test").?.get("k") == null);
}

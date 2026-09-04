//! The certificate authorities a TLS connection is checked against.
//!
//! The vendored bundle is PEM: base64 inside markers, with a comment for each
//! authority. Decoding a hundred and twenty of those at every connection is
//! work a 630 MHz core should not repeat, so `make castore` decodes it once
//! and writes what the runtime actually wants, which is the certificates
//! themselves and where each one starts.
//!
//! In `lib` because the generator runs on the host and the reader runs on the
//! machine, and both must agree about the layout or neither works.

const std = @import("std");

pub const MAGIC = "eeecerts";

/// Past the number of authorities any store carries, so a file claiming more
/// is refused before anything is indexed.
pub const CERTS_MAX = 512;

pub const Head = extern struct {
    magic: [8]u8,
    certs: u32,
    bytes: u32,
};

/// Where one certificate sits in the file.
pub const Entry = extern struct {
    at: u32,
    len: u32,
};

comptime {
    if (@sizeOf(Head) != 16) @compileError("certificate store head is not sixteen bytes");
    if (@sizeOf(Entry) != 8) @compileError("certificate store entry is not eight bytes");
}

pub const Error = error{ NotAStore, Corrupt };

/// A store read back: the file's own bytes, with each certificate found.
pub const Store = struct {
    bytes: []const u8,
    /// Unaligned: the table starts wherever the head ends, and a store read
    /// from a mapped file is not there to be re-laid-out.
    entries: []align(1) const Entry,

    /// The certificate at `index`, in DER.
    pub fn at(self: Store, index: usize) []const u8 {
        const entry = self.entries[index];
        return self.bytes[entry.at..][0..entry.len];
    }

    pub fn count(self: Store) usize {
        return self.entries.len;
    }
};

/// Read a store. Every offset is checked against the file it came from: this
/// is a file, and a file is not to be trusted about its own shape.
pub fn read(bytes: []const u8) Error!Store {
    if (bytes.len < @sizeOf(Head)) return error.NotAStore;
    const head: *align(1) const Head = @ptrCast(bytes.ptr);
    if (!std.mem.eql(u8, &head.magic, MAGIC)) return error.NotAStore;
    if (head.bytes != bytes.len) return error.Corrupt;
    if (head.certs == 0 or head.certs > CERTS_MAX) return error.Corrupt;

    const table = @sizeOf(Head) + @as(usize, head.certs) * @sizeOf(Entry);
    if (table > bytes.len) return error.Corrupt;

    // Every certificate follows the one before it, none overlaps, and the
    // last ends inside the file. Bounds alone were not enough: entries that
    // all named the same long stretch would be in bounds and still add up to
    // far more than the file, which a reader sizing itself from the total
    // would then try to hold.
    const entries = std.mem.bytesAsSlice(Entry, bytes[@sizeOf(Head)..table]);
    var next = table;
    for (entries) |entry| {
        if (entry.len == 0 or entry.at != next) return error.Corrupt;
        next = @as(usize, entry.at) + entry.len;
        if (next > bytes.len) return error.Corrupt;
    }
    return .{ .bytes = bytes, .entries = entries };
}

/// How large a store of these certificates comes to.
pub fn sizeOf(certs: []const []const u8) usize {
    var total: usize = @sizeOf(Head) + certs.len * @sizeOf(Entry);
    for (certs) |cert| total += cert.len;
    return total;
}

/// Write a store into `into`, which must be `sizeOf` bytes.
pub fn write(into: []u8, certs: []const []const u8) []const u8 {
    const total = sizeOf(certs);
    std.debug.assert(into.len >= total);

    const head: *align(1) Head = @ptrCast(into.ptr);
    head.* = .{ .magic = MAGIC.*, .certs = @intCast(certs.len), .bytes = @intCast(total) };

    var at: u32 = @intCast(@sizeOf(Head) + certs.len * @sizeOf(Entry));
    for (certs, 0..) |cert, index| {
        const entry: *align(1) Entry = @ptrCast(into.ptr + @sizeOf(Head) + index * @sizeOf(Entry));
        entry.* = .{ .at = at, .len = @intCast(cert.len) };
        @memcpy(into[at..][0..cert.len], cert);
        at += @intCast(cert.len);
    }
    return into[0..total];
}

test "a store holds the certificates it was written from" {
    const certs = [_][]const u8{ "first", "second", "third" };
    const bytes = try std.testing.allocator.alloc(u8, sizeOf(&certs));
    defer std.testing.allocator.free(bytes);

    const written = write(bytes, &certs);
    const store = try read(written);
    try std.testing.expectEqual(certs.len, store.count());
    for (certs, 0..) |wanted, index| {
        try std.testing.expectEqualStrings(wanted, store.at(index));
    }
}

test "anything that is not a store is refused" {
    try std.testing.expectError(error.NotAStore, read(""));
    try std.testing.expectError(error.NotAStore, read("not a store at all"));

    const certs = [_][]const u8{"only"};
    const bytes = try std.testing.allocator.alloc(u8, sizeOf(&certs));
    defer std.testing.allocator.free(bytes);
    const written = @constCast(write(bytes, &certs));

    try std.testing.expectError(error.Corrupt, read(written[0 .. written.len - 1]));

    // An entry pointing past the file, and one pointing into the table it is
    // listed in: both are files to refuse rather than index.
    const entry: *align(1) Entry = @ptrCast(written.ptr + @sizeOf(Head));
    const was = entry.*;
    entry.len = 4096;
    try std.testing.expectError(error.Corrupt, read(written));
    entry.* = .{ .at = 0, .len = 4 };
    try std.testing.expectError(error.Corrupt, read(written));
    entry.* = was;
}

test "certificates that overlap or repeat are refused" {
    const certs = [_][]const u8{ "first", "second" };
    const bytes = try std.testing.allocator.alloc(u8, sizeOf(&certs));
    defer std.testing.allocator.free(bytes);
    const written = @constCast(write(bytes, &certs));
    _ = try read(written);

    // Two entries naming the same stretch: in bounds, and together claiming
    // more than the file holds. A reader that reserved for the total would
    // ask for memory the file does not justify.
    const second: *align(1) Entry = @ptrCast(written.ptr + @sizeOf(Head) + @sizeOf(Entry));
    const first: *align(1) const Entry = @ptrCast(written.ptr + @sizeOf(Head));
    second.* = first.*;
    try std.testing.expectError(error.Corrupt, read(written));

    // A gap between them is refused too: what is skipped is bytes the file
    // says are certificates and nothing reads.
    second.* = .{ .at = first.at + first.len + 1, .len = 1 };
    try std.testing.expectError(error.Corrupt, read(written));
}

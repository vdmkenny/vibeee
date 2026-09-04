//! Decodes the vendored certificate bundle into the store programs read.
//!
//! The bundle is PEM with a comment for each authority. This finds every
//! certificate in it, decodes the base64 once, and writes the certificates
//! themselves, so nothing on the machine has to decode a hundred and twenty
//! of them at every connection.

const std = @import("std");
const castore = @import("lib").castore;

const BEGIN = "-----BEGIN CERTIFICATE-----";
const END = "-----END CERTIFICATE-----";

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: mkcastore <cacert.pem> <out.store>\n", .{});
        return error.Usage;
    }

    const pem = try cwd.readFileAlloc(io, args[1], gpa, .limited(8 << 20));
    defer gpa.free(pem);

    var certs: std.ArrayList([]const u8) = .empty;
    defer {
        for (certs.items) |cert| gpa.free(cert);
        certs.deinit(gpa);
    }

    var at: usize = 0;
    while (std.mem.indexOfPos(u8, pem, at, BEGIN)) |begin| {
        const body = begin + BEGIN.len;
        const end = std.mem.indexOfPos(u8, pem, body, END) orelse return error.NoEndMarker;
        at = end + END.len;

        // The armour is wrapped at seventy-six columns, and the decoder wants
        // it without the line breaks.
        const wrapped = std.mem.trim(u8, pem[body..end], " \t\r\n");
        const packed_len = std.mem.replacementSize(u8, wrapped, "\n", "");
        const tight = try gpa.alloc(u8, packed_len);
        defer gpa.free(tight);
        _ = std.mem.replace(u8, wrapped, "\n", "", tight);
        const clean = std.mem.trim(u8, tight, " \t\r");

        const decoder = std.base64.standard.Decoder;
        const der = try gpa.alloc(u8, try decoder.calcSizeForSlice(clean));
        errdefer gpa.free(der);
        try decoder.decode(der, clean);
        try certs.append(gpa, der);
    }
    if (certs.items.len == 0) return error.NoCertificates;
    if (certs.items.len > castore.CERTS_MAX) return error.TooManyCertificates;

    const bytes = try gpa.alloc(u8, castore.sizeOf(certs.items));
    defer gpa.free(bytes);
    const written = castore.write(bytes, certs.items);

    // Read back what is about to be written, so a store nothing can index is
    // found here rather than on a machine that cannot then reach anything.
    const store = try castore.read(written);
    if (store.count() != certs.items.len) return error.BadStore;

    try cwd.writeFile(io, .{ .sub_path = args[2], .data = written });
    std.debug.print("  certs   {s}, {d} authorities, {d} bytes\n", .{
        args[2],
        store.count(),
        written.len,
    });
}

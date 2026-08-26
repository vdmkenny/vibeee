//! Prints a QR matrix in `qrencode -t ASCII` format, so the encoder can be
//! diffed against libqrencode from a shell script (see `make qr-verify`).
//!
//! Doing the comparison outside Zig keeps the test itself free of subprocess
//! plumbing, and means the same tool works for eyeballing a code by hand.

const std = @import("std");
const qr = @import("kernel/qr.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) {
        std.debug.print("usage: qrdump <payload> <version> <mask>\n", .{});
        return error.Usage;
    }
    const version = try std.fmt.parseInt(u8, args[2], 10);
    const mask = try std.fmt.parseInt(u3, args[3], 10);

    var code: qr.Code = undefined;
    try qr.encodeVersion(args[1], version, mask, &code);

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buf);
    for (0..code.size) |y| {
        for (0..code.size) |x| {
            const c: u8 = if (code.get(x, y)) '#' else ' ';
            try out.interface.writeAll(&.{ c, c });
        }
        try out.interface.writeAll("\n");
    }
    try out.interface.flush();
}

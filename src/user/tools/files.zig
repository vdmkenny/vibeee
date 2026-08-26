//! File utilities: ls, cat, hexdump.
//!
//! Small on purpose. Each is the thin layer over a syscall that a from-scratch
//! system needs before anything else can be investigated from inside it.

const sys = @import("sys");
const out = @import("ulib").out;
const str = @import("ulib").str;
const time = @import("ulib").time;

pub fn ls(args: []const []const u8) void {
    // "." rather than "/": listing the working directory is what `ls` with no
    // argument means, and the kernel resolves "." against it.
    const path = if (args.len > 0) args[0] else ".";

    const handle = sys.open(path, .{ .directory = true });
    if (handle < 0) {
        out.text("ls: ");
        out.text(path);
        out.text(": cannot open\n");
        out.flush();
        return;
    }
    defer _ = sys.close(@intCast(handle));

    // Read once, outside the loop: every row is compared against it, and a
    // listing whose rows disagreed about what "now" is would be worse than one
    // that is a few microseconds stale.
    const now = @divFloor(sys.realtimeMicros() orelse 0, 1_000_000);

    var buf: [512]u8 = [_]u8{0} ** 512;
    var files: usize = 0;
    var total: usize = 0;

    while (true) {
        const n = sys.readdir(@intCast(handle), &buf);
        if (n <= 0) break;
        const count: usize = @intCast(n);

        const entry = sys.Dirent.decode(&buf, count) orelse continue;
        const name = entry.name;
        const is_dir = entry.is_dir;

        // "." and ".." are in every directory and tell the reader nothing;
        // the shell resolves them without being shown them.
        // Hidden the way every listing hides them, `..` included: someone
        // typing `ls` wants what is in the directory, not the way out of it.
        if (name.len > 0 and name[0] == '.') continue;

        // Fixed-width columns first so names, which vary wildly in length, line
        // up on the left where they are read.
        if (is_dir) {
            out.pad("<dir>", 10);
        } else {
            out.decimalRight(entry.size, 9);
            out.byte(' ');
            total += entry.size;
        }

        time.writeListed(entry.mtime, now);
        out.byte(' ');
        out.name(name);
        if (is_dir) out.text("/");
        out.text("\n");
        files += 1;
    }

    out.decimal(files);
    out.text(if (files == 1) " entry, " else " entries, ");
    out.decimal(total);
    out.text(" bytes\n");
    out.flush();
}

pub fn cat(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: cat <file>\n");
        out.flush();
        return;
    }

    for (args) |path| {
        const handle = sys.open(path, .{});
        if (handle < 0) {
            out.text("cat: ");
            out.text(path);
            out.text(": cannot open\n");
            continue;
        }
        defer _ = sys.close(@intCast(handle));

        var buf: [4096]u8 = [_]u8{0} ** 4096;
        while (true) {
            const n = sys.read(@intCast(handle), &buf);
            if (n <= 0) break;
            out.text(buf[0..@intCast(n)]);
        }
    }
    out.flush();
}

pub fn hexdump(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: hexdump <file>\n");
        out.flush();
        return;
    }

    const handle = sys.open(args[0], .{});
    if (handle < 0) {
        out.text("hexdump: ");
        out.text(args[0]);
        out.text(": cannot open\n");
        out.flush();
        return;
    }
    defer _ = sys.close(@intCast(handle));

    var buf: [16]u8 = [_]u8{0} ** 16;
    var offset: usize = 0;

    while (true) {
        const n = sys.read(@intCast(handle), &buf);
        if (n <= 0) break;
        const count: usize = @intCast(n);

        out.hex(offset, 8);
        out.text("  ");

        for (0..16) |i| {
            if (i < count) {
                out.hex(buf[i], 2);
                out.text(" ");
            } else {
                out.text("   ");
            }
            // Split into two groups of eight, which is what makes a column
            // countable at a glance.
            if (i == 7) out.text(" ");
        }

        out.text(" |");
        for (buf[0..count]) |c| {
            // Byte at a time, and never `&[_]u8{c}`: that takes the address of
            // a temporary whose lifetime ends with the expression.
            out.byte(if (c >= 0x20 and c < 0x7F) c else '.');
        }
        out.text("|\n");

        offset += count;
    }
    out.flush();
}

/// rm: remove files.
///
/// No recursion and no directories: removing a directory means checking it is
/// empty and freeing its chain, and `mkdir` does not exist yet to create one.
/// Refusing is better than half-doing it.
pub fn rm(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: rm <file>...\n");
        out.flush();
        return;
    }

    for (args) |path| {
        if (sys.unlink(path) < 0) {
            out.text("rm: ");
            out.name(path);
            out.text(": cannot remove\n");
        }
    }
    out.flush();
}

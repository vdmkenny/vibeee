//! File utilities: ls, cp, mv, rm, mkdir, cat, hexdump.
//!
//! Small on purpose. Each is the thin layer over a syscall that a from-scratch
//! system needs before anything else can be investigated from inside it.

const sys = @import("sys");
const dir = @import("ulib").dir;
const file = @import("ulib").file;
const out = @import("ulib").out;
const paths = @import("ulib").paths;
const time = @import("ulib").time;

pub fn ls(args: []const []const u8) void {
    // "." rather than "/": listing the working directory is what `ls` with no
    // argument means, and the kernel resolves "." against it.
    const path = if (args.len > 0) args[0] else ".";

    const handle = sys.open(path, .{ .directory = true }) catch {
        out.fault("ls", path, "cannot open");
        out.flush();
        return;
    };
    defer sys.close(handle);

    // Read once, outside the loop: every row is compared against it, and a
    // listing whose rows disagreed about what "now" is would be worse than one
    // that is a few microseconds stale.
    const now = @divFloor(sys.realtimeMicros() orelse 0, 1_000_000);

    var buf: [512]u8 = [_]u8{0} ** 512;
    var files: usize = 0;
    var total: usize = 0;

    while (true) {
        const n = sys.readdir(handle, &buf) catch break;
        if (n == 0) break;
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
        out.text(name);
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

/// Several sources and one destination, which is the shape both `mv` and `cp`
/// are given and neither should work out for itself.
const Onto = struct {
    sources: []const []const u8,
    destination: []const u8,
    /// The destination is a directory, so each source keeps its own name
    /// inside it rather than becoming it.
    into: bool,

    /// What was asked for, or nothing once the reason it cannot be has been
    /// said.
    fn of(tool: []const u8, args: []const []const u8) ?Onto {
        if (args.len < 2) {
            out.text("usage: ");
            out.text(tool);
            out.text(" <source>... <destination>\n");
            out.flush();
            return null;
        }

        const destination = args[args.len - 1];
        const sources = args[0 .. args.len - 1];
        const into = dir.isDirectory(destination);

        // Several sources and a destination that is not a directory has no
        // reading: the last one would land on top of the others.
        if (sources.len > 1 and !into) {
            out.fault(tool, destination, "not a directory");
            out.flush();
            return null;
        }
        return .{ .sources = sources, .destination = destination, .into = into };
    }

    /// Where `from` lands. Nothing when the path would be cut short, which
    /// would name something else and put the file somewhere nobody asked for.
    fn target(self: Onto, tool: []const u8, from: []const u8, buf: []u8) ?[]const u8 {
        if (!self.into) return self.destination;
        return paths.joined(self.destination, paths.base(from), buf) orelse {
            out.fault(tool, from, "the path is too long");
            return null;
        };
    }
};

/// Move or rename. Several sources are allowed when the last argument is a
/// directory, which is the only reading of `mv a b c somewhere` that makes
/// sense.
pub fn mv(args: []const []const u8) void {
    const asked = Onto.of("mv", args) orelse return;

    for (asked.sources) |from| {
        var buf: [PATH_MAX]u8 = undefined;
        const to = asked.target("mv", from, &buf) orelse continue;
        sys.rename(from, to) catch out.fault("mv", from, "cannot move");
    }
    out.flush();
}

/// The longest destination a move or a copy builds.
const PATH_MAX = 256;

/// Copy, which is what a move across volumes would have to be and deliberately
/// is not: `mv` renames, and this is the different thing to ask for.
///
/// Files only. Copying a directory means walking it and creating as it goes,
/// and half of that is worse than none.
pub fn cp(args: []const []const u8) void {
    const asked = Onto.of("cp", args) orelse return;

    for (asked.sources) |from| {
        var buf: [PATH_MAX]u8 = undefined;
        const to = asked.target("cp", from, &buf) orelse continue;
        copy(from, to);
    }
    out.flush();
}

fn copy(from: []const u8, to: []const u8) void {
    file.copy(from, to) catch |why| out.fault("cp", from, switch (why) {
        error.Itself => "is the destination",
        error.Directory => "is a directory",
        error.NoFile => "cannot open",
        error.CannotCreate => "cannot create the destination",
        error.Unreadable => "cannot read",
        error.NoSpace => "no space",
    });
}

pub fn cat(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: cat <file>\n");
        out.flush();
        return;
    }

    for (args) |path| {
        const handle = sys.open(path, .{}) catch {
            out.fault("cat", path, "cannot open");
            continue;
        };
        defer sys.close(handle);

        var buf: [4096]u8 = [_]u8{0} ** 4096;
        while (true) {
            const n = sys.read(handle, &buf) catch break;
            if (n == 0) break;
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

    const handle = sys.open(args[0], .{}) catch {
        out.fault("hexdump", args[0], "cannot open");
        out.flush();
        return;
    };
    defer sys.close(handle);

    var buf: [16]u8 = [_]u8{0} ** 16;
    var offset: usize = 0;

    while (true) {
        const n = sys.read(handle, &buf) catch break;
        if (n == 0) break;
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
        sys.unlink(path) catch out.fault("rm", path, "cannot remove");
    }
    out.flush();
}

/// Create a directory.
pub fn mkdir(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: mkdir <path>...\n");
        out.flush();
        return;
    }

    for (args) |path| {
        sys.mkdir(path) catch |why| {
            out.fault("mkdir", path, switch (why) {
                error.Exists => "already exists",
                error.NoSuchFile => "no such parent directory",
                error.NoSpace => "no space",
                error.NotPermitted => "read-only volume",
                else => "cannot create",
            });
        };
    }
    out.flush();
}

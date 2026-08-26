//! Enforces the portability layering rules at build time.
//!
//! design/00-vibeee.md §3 states that `kernel/` must never reach into `arch/`.
//! A rule that is only written down decays: the violation is invisible until
//! someone attempts a port and discovers the HAL was quietly bypassed a dozen
//! times. This runs as part of `zig build`, so breaking the rule breaks the
//! build.
//!
//! Zig's own module system cannot express this particular constraint: the
//! console imports its backend driver, which imports the HAL, which is a module
//! cycle. So the check is structural rather than type-level, but it runs every
//! build, which is what actually matters.

const std = @import("std");

const Rule = struct {
    /// Files under this directory...
    from: []const u8,
    /// ...may not import paths containing this.
    forbid: []const u8,
    /// Except these exact files, each with the reason it is allowed.
    exceptions: []const Exception = &.{},
    why: []const u8,
};

const Exception = struct {
    file: []const u8,
    why: []const u8,
};

const RULES = [_]Rule{
    .{
        .from = "src/kernel",
        .forbid = "arch/",
        .why = "kernel code must reach the architecture only through kernel/hal.zig",
        .exceptions = &.{
            .{
                .file = "src/kernel/hal.zig",
                .why = "the HAL is the designated binding point; that is its whole job",
            },
        },
    },
    .{
        .from = "src/kernel",
        .forbid = "drv/",
        .why = "kernel core must not depend on specific drivers",
        .exceptions = &.{
            .{
                .file = "src/kernel/console.zig",
                .why = "console backend selection; becomes injection when the framebuffer console lands",
            },
        },
    },
    .{
        .from = "src/arch/x86",
        .forbid = "arch/arm",
        .why = "architectures must not depend on each other",
    },
    // `lib/` is compiled into the kernel and into every user program. Anything
    // it reached for would be pulled into both, so it stays pure computation:
    // no state, no hardware, no syscalls.
    .{
        .from = "src/lib",
        .forbid = "kernel/",
        .why = "lib/ is shared by kernel and userspace, so it must not depend on either",
    },
    .{
        .from = "src/lib",
        .forbid = "arch/",
        .why = "lib/ must stay architecture-neutral",
    },
    .{
        .from = "src/lib",
        .forbid = "drv/",
        .why = "lib/ must not depend on drivers",
    },
    .{
        .from = "src/lib",
        .forbid = "user/",
        .why = "lib/ is the shared half; userspace-only code belongs in user/lib/",
    },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    var violations: usize = 0;

    for (RULES) |rule| {
        var dir = cwd.openDir(io, rule.from, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var walker = try dir.walk(gpa);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ rule.from, entry.path });
            defer gpa.free(path);

            const source = dir.readFileAlloc(io, entry.path, gpa, .limited(4 << 20)) catch continue;
            defer gpa.free(source);

            var allowed: ?Exception = null;
            for (rule.exceptions) |e| {
                if (std.mem.eql(u8, e.file, path)) allowed = e;
            }

            var line_no: usize = 0;
            var lines = std.mem.splitScalar(u8, source, '\n');
            while (lines.next()) |line| {
                line_no += 1;
                const at = std.mem.indexOf(u8, line, "@import(\"") orelse continue;
                const rest = line[at + "@import(\"".len ..];
                const close = std.mem.indexOfScalar(u8, rest, '"') orelse continue;
                const target = rest[0..close];
                if (std.mem.indexOf(u8, target, rule.forbid) == null) continue;

                if (allowed != null) continue;

                violations += 1;
                std.debug.print(
                    "{s}:{d}: layering violation: imports \"{s}\"\n    {s}\n",
                    .{ path, line_no, target, rule.why },
                );
            }
        }
    }

    if (violations > 0) {
        std.debug.print("\n{d} layering violation(s); see design/00-vibeee.md §3\n", .{violations});
        return error.LayeringViolation;
    }
}

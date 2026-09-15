//! The engine's face, as a program of this system runs a script: an engine
//! started once, a context opened for each page, a script run in it, and the
//! bounds that keep a page from taking the program with it.
//!
//! QuickJS is reached through the mirror in `quickjs.zig`. A `JSValue` is a
//! shape that depends on how upstream was built, so a program that only runs
//! scripts never takes one apart: a script goes in as bytes, and what comes
//! out is what it said, as text, or the exception it threw.
//!
//! A page is untrusted input, and a script is the part of it that runs. Three
//! bounds keep one inside the program: how much it may hold, how deep it may
//! call, and how long one entry into it may run. Each turns what would be a
//! fault into an exception the script gets and the program reads. What a
//! script says out loud, with `print` or `console.log`, goes wherever the
//! program says.

const std = @import("std");
const qjs = @import("quickjs");

pub const Value = qjs.Value;
pub const Context = qjs.Context;

/// The most a runtime holds, everything a page's scripts make and keep
/// included. Past it an allocation fails and the script gets an exception.
///
/// A mainstream search results page comes to some twenty-five megabytes once
/// its bundle has run, and half as much again once its components have drawn
/// what the page asked for, so this is that with room to work in. A page
/// wanting more than this is not one this machine reads.
pub const MEMORY_MAX = 64 * 1024 * 1024;

/// How deep a script may call, in bytes of this program's stack, counted
/// from where the engine was last entered. A process here has a megabyte of
/// stack at most, and the rest of the program needs the rest of it.
pub const STACK_MAX = 256 * 1024;

/// How long one entry into the engine may run before the script is stopped
/// where it is: one script, one handler, one timer. A page's scripts run
/// between passes of a window, and a person waits for each.
///
/// A mainstream site's main bundle is a megabyte and a half, which this
/// machine takes several seconds to read and run, and a bundle stopped in
/// the middle leaves a page that never draws. So the slice is what such a
/// bundle needs with room over: a script still going after it is one that
/// is not working rather than one that is slow.
pub const SLICE_US: u64 = 10_000_000;

/// The clock the slice is measured on, in microseconds since anything: handed
/// in, this machine's clock being one thing and the host's, where the engine
/// is tested, another.
pub const Clock = *const fn () u64;

/// Where what a script says out loud goes.
pub const Say = *const fn (text: []const u8) void;

/// An engine: the runtime every script hangs off, started once and kept.
///
/// Kept rather than freed: this engine refuses to free a runtime with
/// anything still in it, and a program that is ending has no need to try. A
/// context, made for one page and given back with it, is where the giving
/// back happens.
pub const Machine = struct {
    runtime: *qjs.Runtime,
    clock: Clock,
    say: Say,
    /// When the entry being run must be over, on `clock`.
    deadline: u64 = 0,
    /// Whether the last entry was stopped for running past its slice.
    interrupted: bool = false,

    /// Start an engine, or nothing where the machine has no room for one.
    fn start(clock: Clock, say: Say) ?*Machine {
        const runtime = qjs.newRuntime() orelse return null;
        only = .{ .runtime = runtime, .clock = clock, .say = say };
        qjs.setMemoryLimit(runtime, MEMORY_MAX);
        qjs.setMaxStackSize(runtime, STACK_MAX);
        qjs.setInterruptHandler(runtime, &overdue, &only);
        return &only;
    }

    /// How much of its bound the engine has taken, in bytes: what the pages
    /// open in it come to. Counted by walking everything, so asked for a
    /// report and not on every pass.
    pub fn taken(self: *Machine) usize {
        var usage: qjs.MemoryUsage = undefined;
        qjs.memoryUsage(self.runtime, &usage);
        return @intCast(@max(usage.malloc_size, 0));
    }

    /// Open a context in it, for one page: a script's own world, with every
    /// intrinsic in it and the two ways a script has of saying something.
    pub fn open(self: *Machine) ?*Context {
        const ctx = qjs.newContext(self.runtime) orelse return null;
        const global = qjs.globalOf(ctx);
        defer qjs.free(ctx, global);
        _ = qjs.setStr(ctx, global, "print", qjs.newFunction(ctx, "print", 1, &said));
        const console = qjs.newObject(ctx);
        for ([_][*:0]const u8{ "log", "info", "warn", "error", "debug" }) |name| {
            _ = qjs.setStr(ctx, console, name, qjs.newFunction(ctx, name, 1, &said));
        }
        _ = qjs.setStr(ctx, global, "console", console);
        return ctx;
    }

    /// Close a context, and give back everything it holds.
    pub fn close(self: *Machine, ctx: *Context) void {
        _ = self;
        qjs.freeContext(ctx);
    }

    /// Begin an entry into the engine: the slice starts now, and the stack is
    /// measured from here. Around every script run, handler called and timer
    /// fired, so that each has the whole slice and the whole depth.
    pub fn enter(self: *Machine) void {
        qjs.updateStackTop(self.runtime);
        self.deadline = self.clock() + SLICE_US;
        self.interrupted = false;
    }

    /// Run `source`, called `name`, as a program. What it ended in, or the
    /// exception it threw, which the caller frees either way.
    ///
    /// The engine reads a script's bytes up to a nought after them, so it is
    /// given a copy with one, on its own heap: what a script's source costs
    /// while it is read counts against the script's own bound.
    pub fn run(self: *Machine, ctx: *Context, source: []const u8, name: [*:0]const u8, how: qjs.Eval) Value {
        self.enter();
        const copy: [*]u8 = @ptrCast(qjs.alloc(ctx, source.len + 1) orelse return qjs.throwOutOfMemory(ctx));
        defer qjs.release(ctx, copy);
        @memcpy(copy[0..source.len], source);
        copy[source.len] = 0;
        return qjs.run(ctx, copy, source.len, name, how);
    }

    /// Run what scripts left waiting: the promises they made. Bounded, so a
    /// promise that keeps making promises gives the program its turn back.
    /// True where anything ran.
    pub fn runJobs(self: *Machine) bool {
        var ran = false;
        var left: usize = JOBS_MAX;
        while (left > 0 and qjs.isJobPending(self.runtime) != 0) : (left -= 1) {
            var wanting: ?*Context = null;
            self.enter();
            const status = qjs.executePendingJob(self.runtime, &wanting);
            if (status < 0) {
                if (wanting) |ctx| self.tellError(ctx);
            }
            if (status == 0) break;
            ran = true;
        }
        return ran;
    }

    /// How many promises are kept in one go.
    const JOBS_MAX = 256;

    /// What the engine asks every few thousand steps: whether to go on.
    fn overdue(_: *qjs.Runtime, at: ?*anyopaque) callconv(.c) c_int {
        const self: *Machine = @ptrCast(@alignCast(at orelse return 0));
        if (self.clock() < self.deadline) return 0;
        self.interrupted = true;
        return 1;
    }

    /// Say the exception the context holds, and let it go.
    pub fn tellError(self: *Machine, ctx: *Context) void {
        var buf: [ERROR_MAX]u8 = undefined;
        self.say(errorText(ctx, &buf));
    }

    /// The exception the context holds, as words in `buf`: what it says, and
    /// where it happened where the engine kept that. Letting the exception
    /// go, as reading one does.
    pub fn errorText(ctx: *Context, buf: []u8) []const u8 {
        const exception = qjs.exceptionOf(ctx);
        defer qjs.free(ctx, exception);
        var w: std.Io.Writer = .fixed(buf);
        writeValue(ctx, &w, exception);
        if (qjs.isObject(exception)) {
            const stack = qjs.getStr(ctx, exception, "stack");
            defer qjs.free(ctx, stack);
            if (!qjs.isUndefined(stack)) {
                w.writeAll("\n") catch {};
                writeValue(ctx, &w, stack);
            }
        }
        return w.buffered();
    }

    /// The most an exception's words come to, as they are said.
    pub const ERROR_MAX = 1024;

    /// A value as words, cut to what `w` holds.
    fn writeValue(ctx: *Context, w: *std.Io.Writer, value: Value) void {
        const text = qjs.sliceOf(ctx, value) orelse return;
        defer qjs.freeText(ctx, text.ptr);
        w.writeAll(text[0..@min(text.len, w.buffer.len - w.end)]) catch {};
    }

    /// `print` and `console.log`: each argument as words, a space between,
    /// and a line end, said where the program says.
    fn said(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
        var buf: [LINE_MAX]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        for (argv[0..@intCast(argc)], 0..) |value, i| {
            if (i > 0) w.writeByte(' ') catch break;
            writeValue(ctx, &w, value);
        }
        if (held) |machine| machine.say(w.buffered());
        return qjs.undefinedValue();
    }

    /// The most of a line a script says that is passed on.
    const LINE_MAX = 512;
};

/// The one engine a program has, for the calls the engine makes back with a
/// context and nothing else: a program starts one engine and keeps it.
var only: Machine = undefined;
var held: ?*Machine = null;

/// Start the program's engine, once, and keep it.
pub fn start(clock: Clock, say: Say) ?*Machine {
    if (held) |machine| return machine;
    held = Machine.start(clock, say);
    return held;
}

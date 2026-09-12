//! The engine's face, as a program of this system calls it, and the whole
//! of it. `src/user/js/port/engine.c` is what's behind these calls; `qjs`
//! and `web` are the two programs that make them.
//!
//! QuickJS is reached through `quickjsport/engine.c` rather than directly:
//! a `JSValue` is a struct sixteen bytes wide whose shape depends on how
//! upstream was built, and its helpers are C inline functions, so neither
//! would survive the crossing. What does cross is a script's bytes and its
//! answer as a string, which is what a program running a script wants anyway.
//!
//! `engine.h` says what each call is for; this is the pin, so a signature
//! changed there fails the build here rather than at a call site.

const qjs = @import("quickjs");
/// An engine, which a program starts once and keeps: the runtime every script
/// it runs hangs off.
pub const Machine = qjs.Runtime;

/// A script's own world: a context in that runtime, with every intrinsic in
/// it and the two ways a script has of saying something out loud. One per
/// page, given back when the page goes.
pub const Engine = qjs.Context;

extern fn qjs_start() ?*Machine;
extern fn qjs_open(machine: *Machine) ?*Engine;
extern fn qjs_run(engine: *Engine, source: [*]const u8, len: usize, name: [*]const u8, module: c_int) ?[*:0]u8;
extern fn qjs_tell_error(engine: *Engine) void;
extern fn qjs_loop(engine: *Engine) void;
extern fn qjs_give_back(engine: *Engine, text: [*:0]u8) void;
extern fn qjs_close(engine: *Engine) void;
extern fn qjs_note(what: [*:0]const u8) void;

/// Start an engine. Once, and kept: a runtime is the expensive half, and one
/// that is freed while anything is still in it takes the program with it.
pub fn start() ?*Machine {
    return qjs_start();
}

/// There is no `stop`: see `engine.h`. A program that is ending simply ends.
/// Open a context in `machine`, for one page.
pub fn open(machine: *Machine) ?*Engine {
    return qjs_open(machine);
}

/// Run `source`, called `name`, as a module where it is one and as a script
/// where it is not.
///
/// Answers the value it ended in, as a string to `giveBack`, or nothing:
/// either the script ended in no value, or it threw, which `tellError` says.
pub fn run(engine: *Engine, source: []const u8, name: []const u8, module: bool) ?[*:0]u8 {
    return qjs_run(engine, source.ptr, source.len, name.ptr, @intFromBool(module));
}

/// Say what went wrong with the script just run.
pub fn tellError(engine: *Engine) void {
    qjs_tell_error(engine);
}

/// Run what the script left waiting behind it: the promises it made, the
/// timers it set.
pub fn loop(engine: *Engine) void {
    qjs_loop(engine);
}

/// Give back a string `run` answered with.
pub fn giveBack(engine: *Engine, text: [*:0]u8) void {
    qjs_give_back(engine, text);
}

/// Say that a script reached for something this reader has no answer for, so
/// that a page which stops is a page that has said why.
pub fn note(what: [*:0]const u8) void {
    qjs_note(what);
}

/// Stop one, and give back everything it holds.
pub fn close(engine: *Engine) void {
    qjs_close(engine);
}

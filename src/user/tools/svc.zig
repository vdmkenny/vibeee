//! svc: what is supposed to be running, and what is.
//!
//! Two sources, because they answer different questions. `init` knows what was
//! declared and what became of it, including the service that failed to start
//! and is therefore the one somebody is looking for. `/svc` knows which names
//! are registered, which is what a client would find if it went looking. A
//! service can be up without having registered anything, and a name can be
//! registered by something init never started, so both are shown.

const std = @import("std");
const ink = @import("ulib").ink;
const out = @import("ulib").out;
const service = @import("proto").service;
const str = @import("ulib").str;
const info = @import("ulib").info;

pub fn run(args: []const []const u8) void {
    if (args.len == 0) return list();

    const verb = args[0];
    if (args.len < 2) return usage();

    if (std.mem.eql(u8, verb, "start")) return act(.start, args[1], "started");
    if (std.mem.eql(u8, verb, "stop")) return act(.stop, args[1], "stopped");
    if (std.mem.eql(u8, verb, "restart")) return act(.restart, args[1], "restarted");
    if (std.mem.eql(u8, verb, "enable")) return act(.enable, args[1], "enabled");
    if (std.mem.eql(u8, verb, "disable")) return act(.disable, args[1], "disabled");
    usage();
}

fn list() void {
    out.text("service      state      pid\n");

    var index: u8 = 0;
    while (index < LIMIT) : (index += 1) {
        var reply = service.Rep{};
        service.ask(.list, "", index, &reply) catch break;

        const entry = reply.entry;
        out.pad(entry.named(), 13);

        // The state carries the colour, because the state is the answer: a
        // column of names in one colour tells a reader nothing.
        ink.write(roleOf(entry.state), padded(entry.state.word()));

        if (entry.pid != 0) out.decimal(entry.pid);
        out.byte('\n');
    }

    if (index == 0) out.text("init is not answering\n");
    registered();
    out.flush();
}

/// The `/svc` names, which is the other half of the picture: what a client
/// looking for a service would actually find.
fn registered() void {
    var buf: [512]u8 = @splat(0);
    const names = info.ask("svc", &buf);
    if (names.len == 0) return;

    out.byte('\n');
    ink.write(.dim, "registered   ");

    var it = str.lines(names);
    var first = true;
    while (it.next()) |name| {
        if (name.len == 0) continue;
        if (!first) out.text(", ");
        out.text(name);
        first = false;
    }
    out.byte('\n');
}

fn act(tag: service.Tag, name: []const u8, done: []const u8) void {
    var reply = service.Rep{};

    service.ask(tag, name, 0, &reply) catch |err| {
        // Done, but not remembered. Worth saying rather than reporting either
        // success or failure, because it is both.
        if (err == error.NotKept) {
            out.text(name);
            out.byte(' ');
            out.text(done);
            ink.write(.warn, ", until the next boot: / is memory\n");
            return out.flush();
        }

        out.text("svc: ");
        switch (err) {
            error.NoService => out.text("init is not answering"),
            error.TooLong => out.text("no service has a name that long"),
            error.Unknown => {
                out.text(name);
                out.text(": nothing is called that");
            },
            else => {
                out.text(name);
                out.text(": would not");
            },
        }
        out.byte('\n');
        return out.flush();
    };

    out.text(name);
    out.byte(' ');
    out.text(done);
    out.byte('\n');
    out.flush();
}

fn roleOf(state: service.State) @import("lib").style.Role {
    return switch (state) {
        .up => .good,
        .down => .dim,
        .starting => .dim,
        .stopped => .warn,
        .disabled => .dim,
        .failed => .bad,
    };
}

/// A state word in a fixed column, so it can be coloured whole rather than
/// coloured and padded in two steps that could disagree about the width.
fn padded(word: []const u8) []const u8 {
    var built = str.Builder{ .buf = &column };
    built.text(word);
    while (built.len < 11) built.byte(' ');
    return built.done();
}

var column: [12]u8 = @splat(0);

/// More than any table `init` keeps, so the walk ends because the answers run
/// out rather than because this stopped asking.
const LIMIT = 32;

fn usage() void {
    out.text("usage: svc                 what is declared, and what became of it\n");
    out.text("       svc start <name>    now\n");
    out.text("       svc stop <name>     now\n");
    out.text("       svc restart <name>  stop it and start it again\n");
    out.text("       svc enable <name>   at every boot\n");
    out.text("       svc disable <name>  at none\n");
    out.flush();
}

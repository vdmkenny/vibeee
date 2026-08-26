//! init, process 1, the service supervisor.
//!
//! Starts what `/etc/services` declares, in dependency order, and keeps it
//! running. Everything else in userspace is a descendant of this process.
//!
//! **Not s6, and not for lack of respect.** Daemontools-style supervision
//! assumes fork, signals and Unix sockets, and this system deliberately has
//! none of the three (design/00-vibeee.md §12). What it does have is native
//! `spawn` and `wait`, which is all a supervisor actually needs, and building
//! against them directly gets dependency-aware restart in a few hundred lines
//! rather than bolting it onto a model that fights us.
//!
//! **Reaping is the other half of the job.** When any process dies its
//! children are re-parented onto this one, and a corpse holds its stack and
//! its exit status until someone collects it. init's wait loop is what
//! collects them, so a crashing service cannot leak the memory of everything
//! it started. That is why the loop waits for *any* child rather than for the
//! services it knows about: most of what it reaps, it never started.

const std = @import("std");
const sys = @import("sys");
const out = @import("ulib").out;
const config = @import("ulib").config;
const info = @import("ulib").info;
const str = @import("ulib").str;

const CONFIG_PATH = "/ETC/SERVICES";

/// Enough for the whole service table. Read once and kept, so every string in
/// a `Service` is a slice into it rather than a copy, which is what makes the
/// parser allocation-free.
var config_buf: [4096]u8 = @splat(0);

pub const Restart = enum {
    /// Run once; leave it alone when it exits.
    never,
    /// Restart only if it exited non-zero. The default: a service that exits
    /// cleanly has usually decided it was not needed.
    on_failure,
    /// Restart whatever the status. What a shell wants.
    always,
};

/// One service, and the schema the parser is generated from.
///
/// The field names *are* the manifest keys and the field types *are* the value
/// grammar: `parseInto` walks this with `std.meta.fields`, so adding an option
/// means adding a field here and nothing else. A hand-written key table would
/// be a second place to forget.
pub const Service = struct {
    name: []const u8 = "",
    binary: []const u8 = "",
    /// Comma-separated service names that must be up first.
    needs: []const u8 = "",
    /// The `/svc` name this service registers, if any. Declaring it lets init
    /// wait for the service to be genuinely ready rather than merely started.
    provides: []const u8 = "",
    restart: Restart = .on_failure,
    /// Comma-separated capability names, from `Caps` in the syscall ABI. Empty
    /// leaves the service with everything init has, which is what a service
    /// that predates anyone thinking about this gets.
    caps: []const u8 = "",
};

const MAX_SERVICES = 8;

const State = struct {
    service: Service = .{},
    pid: u32 = 0,
    started_us: u64 = 0,
    /// Consecutive failures that happened too fast to be real work.
    flapping: u32 = 0,
    running: bool = false,
    /// Set when the service has been given up on, so the report is printed
    /// once rather than every time round the loop.
    abandoned: bool = false,
};

var services: [MAX_SERVICES]State = @splat(.{});
var service_count: usize = 0;

/// A service that dies sooner than this after starting is treated as failing to
/// start rather than as having done its job and stopped.
const FLAP_WINDOW_US: u64 = 1_000_000;
const MAX_FLAPS: u32 = 5;

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ xorl %ebp, %ebp
        \\ call initMain
        \\ hlt
    );
}

export fn initMain() callconv(.c) noreturn {
    loadConfig();
    startAll();
    supervise();
}

// ---------------------------------------------------------------------------
// Configuration
// ---------------------------------------------------------------------------

/// Read the service table, falling back to a built-in one.
///
/// The fallback is not a convenience. A machine whose `/etc/services` is
/// missing or corrupt would otherwise boot to a supervisor with nothing to
/// supervise and no way to tell anyone about it; a shell is what makes it
/// repairable from the machine itself.
fn loadConfig() void {
    const handle = sys.open(CONFIG_PATH, .{});
    if (handle < 0) {
        useFallback("no /etc/services");
        return;
    }
    defer _ = sys.close(@intCast(handle));

    const n = sys.read(@intCast(handle), &config_buf);
    if (n <= 0) {
        useFallback("/etc/services is empty");
        return;
    }

    parse(config_buf[0..@intCast(n)]);
    if (service_count == 0) useFallback("/etc/services declares no services");
}

fn useFallback(why: []const u8) void {
    report("init", why);
    services[0] = .{ .service = .{
        .name = "vsh",
        .binary = "/VSH",
        .restart = .always,
    } };
    service_count = 1;
}

/// Parse the service table.
///
/// Stanzas separated by blank lines, `key = value` within one. Comments start
/// with `#` and are ignored wherever they appear, including between the keys
/// of a stanza: a comment explaining the line below it must not be the thing
/// that ends the stanza above it. Deliberately not INI section headers: a
/// stanza's identity is its `name` key, and a `[name]` header would state the
/// same thing twice and let the two disagree.
fn parse(text: []const u8) void {
    var current: Service = .{};
    var dirty = false;

    var lines = str.lines(text);
    while (lines.next()) |raw| {
        const line = str.trim(raw);

        if (line.len > 0 and line[0] == '#') continue;

        if (line.len == 0) {
            if (dirty) {
                commit(current);
                current = .{};
                dirty = false;
            }
            continue;
        }

        const kv = config.pair(line) orelse continue;
        if (config.assign(&current, kv.key, kv.value)) dirty = true;
    }

    if (dirty) commit(current);
}

fn commit(service: Service) void {
    if (service.name.len == 0 or service.binary.len == 0) return;
    if (service_count >= MAX_SERVICES) {
        report(service.name, "service table full, ignoring");
        return;
    }
    services[service_count] = .{ .service = service };
    service_count += 1;
}

// ---------------------------------------------------------------------------
// Starting
// ---------------------------------------------------------------------------

/// Start everything, respecting `needs`.
///
/// Repeated passes rather than a topological sort: with at most eight services
/// the passes are cheaper than the sort, and what is left unstarted at the end
/// *is* the cycle, which makes the error message fall out for free.
fn startAll() void {
    var progress = true;
    while (progress) {
        progress = false;
        for (services[0..service_count]) |*state| {
            if (state.running or state.abandoned) continue;
            if (!dependenciesMet(state.service)) continue;
            start(state);
            progress = true;
        }
    }

    for (services[0..service_count]) |*state| {
        if (!state.running and !state.abandoned) {
            report(state.service.name, "needs a service that never came up");
            state.abandoned = true;
        }
    }
}

fn dependenciesMet(service: Service) bool {
    var needs = str.split(service.needs, ',');
    while (needs.next()) |raw| {
        const name = str.trim(raw);
        if (name.len == 0) continue;

        const dep = lookup(name) orelse {
            report(service.name, "needs a service that is not declared");
            return false;
        };
        if (!dep.running) return false;
    }
    return true;
}

fn lookup(name: []const u8) ?*State {
    for (services[0..service_count]) |*state| {
        if (str.eql(state.service.name, name)) return state;
    }
    return null;
}

/// Turn a manifest's capability list into the set the child gets.
///
/// By name, resolved against the ABI's own field names, so adding a capability
/// needs no change here. An empty list means the service keeps whatever init
/// has: capabilities are intersected at every spawn, so all bits set asks for
/// no reduction rather than for everything.
fn capsFrom(list: []const u8) u32 {
    if (str.trim(list).len == 0) return @bitCast(sys.Caps.all);

    var granted = sys.Caps{};
    var it = str.split(list, ',');
    while (it.next()) |raw| {
        const wanted = str.trim(raw);
        inline for (@typeInfo(sys.Caps).@"struct".fields) |field| {
            if (field.type == bool and str.eql(wanted, field.name)) {
                @field(granted, field.name) = true;
            }
        }
    }
    return @bitCast(granted);
}

fn start(state: *State) void {
    const pid = sys.spawnStreams(state.service.binary, &.{state.service.name}, .{
        .flags = @bitCast(sys.SpawnFlags{ .detached = true }),
        .caps = capsFrom(state.service.caps),
    });
    if (pid < 0) {
        report(state.service.name, "cannot start");
        state.abandoned = true;
        return;
    }

    state.pid = @intCast(pid);
    state.started_us = sys.clockMicros();
    state.running = true;

    // A service that says what it registers is only up once the name is there.
    // Starting a dependant before that would let it connect to a service that
    // exists but has not published itself yet.
    if (state.service.provides.len > 0) waitForService(state.service.provides);
}

/// Wait for a name to appear in `/svc`.
///
/// Polled, because the registry has no change notification yet. It is the one
/// piece of polling in this program and it is bounded, which is the difference
/// between a stopgap and a design decision.
fn waitForService(name: []const u8) void {
    var buf: [512]u8 = @splat(0);
    var waited: u64 = 0;

    while (waited < 2_000_000) : (waited += 20_000) {
        if (info.listContains("svc", name, &buf)) return;
        sys.sleepMicros(20_000);
    }
    report(name, "did not register within two seconds");
}

// ---------------------------------------------------------------------------
// Supervision
// ---------------------------------------------------------------------------

/// Collect dead children forever, restarting the ones that should come back.
///
/// Most of what this reaps is not a service: any process whose parent died is
/// re-parented here, and collecting it is what returns its memory. So the wait
/// is for *any* child, and a pid that matches no service is simply reaped.
fn supervise() noreturn {
    while (true) {
        const exited = sys.wait(0, sys.FOREVER) orelse {
            // ECHILD: nothing left alive and nothing left to collect. With no
            // restartable service there is no way for that to change, so
            // saying so beats spinning on a wait that can only fail.
            report("init", "no children left to supervise");
            idle();
        };

        const state = byPid(exited.pid) orelse continue;
        state.running = false;

        if (shouldRestart(state, exited.status)) {
            start(state);
        } else if (!state.abandoned) {
            state.abandoned = true;
        }
    }
}

fn shouldRestart(state: *State, status: i32) bool {
    const wanted = switch (state.service.restart) {
        .never => false,
        .on_failure => status != 0,
        .always => true,
    };
    if (!wanted) return false;

    // Something that dies immediately, repeatedly, is not going to start no
    // matter how many times it is asked. Restarting it forever would fill the
    // screen and starve everything else of CPU.
    const lifetime = sys.clockMicros() -| state.started_us;
    if (lifetime < FLAP_WINDOW_US) {
        state.flapping += 1;
        if (state.flapping >= MAX_FLAPS) {
            report(state.service.name, "keeps failing to start; giving up");
            state.abandoned = true;
            return false;
        }
        // Back off a little so a persistent failure does not spin.
        sys.sleepMicros(state.flapping * 200_000);
    } else {
        state.flapping = 0;
    }

    return true;
}

fn byPid(pid: u32) ?*State {
    for (services[0..service_count]) |*state| {
        if (state.running and state.pid == pid) return state;
    }
    return null;
}

/// Nothing left to do, and process 1 must not exit. Sleeping rather than
/// spinning: the scheduler takes this thread off the run queues entirely.
fn idle() noreturn {
    while (true) sys.sleepMicros(1_000_000);
}

// ---------------------------------------------------------------------------

fn report(who: []const u8, what: []const u8) void {
    out.text("init: ");
    out.text(who);
    out.text(": ");
    out.text(what);
    out.byte('\n');
    out.flush();
}


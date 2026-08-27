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
const log = @import("ulib").log;
const out = @import("ulib").out;
const config = @import("ulib").config;
const info = @import("ulib").info;
const str = @import("ulib").str;

const CONFIG_PATH = "/etc/services";

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
    /// Somebody asked for it to stop. Distinct from `abandoned`, which is init
    /// giving up: this one is a decision and is not reconsidered on its own.
    held: bool = false,
    /// Whether it should start at all. `held` is for this boot; this is for
    /// every one after it, and is what `/etc/disabled` records.
    enabled: bool = true,
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
    // Read before anything starts, because it decides what does.
    readDisabled();
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
        .binary = "/bin/vsh",
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
        if (config.assign(&current, kv.key, kv.value) == .assigned) dirty = true;
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
            if (state.running or state.abandoned or !state.enabled) continue;
            if (!dependenciesMet(state.service)) continue;
            start(state);
            progress = true;
        }
    }

    for (services[0..service_count]) |*state| {
        if (!state.running and !state.abandoned and state.enabled) {
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
    // Two things to listen to and one call that listens to both. A child
    // exiting and somebody asking about the table are unrelated, arrive
    // whenever they arrive, and neither is worth waking up to check for.
    const children = sys.watch(.children);
    const channel = sys.svcRegister(proto.SERVICE);

    var sources: [2]u32 = undefined;
    var count: usize = 0;
    for ([_]isize{ children, channel }) |handle| {
        if (handle >= 0) {
            sources[count] = @intCast(handle);
            count += 1;
        }
    }

    while (true) {
        collect();
        if (channel >= 0) answerAll(@intCast(channel));

        if (count == 0) {
            report("init", "nothing left to supervise");
            idle();
        }
        _ = sys.waitMany(sources[0..count], sys.FOREVER);
    }
}

/// Reap whatever has died, restarting what should come back.
///
/// Most of what this reaps is not a service: any process whose parent died is
/// re-parented here, and collecting it is what returns its memory. So the wait
/// is for *any* child, and a pid matching no service is simply reaped.
fn collect() void {
    while (sys.wait(0, sys.POLL)) |exited| {
        const state = byPid(exited.pid) orelse continue;
        state.running = false;
        state.pid = 0;

        if (state.held) continue;

        if (shouldRestart(state, exited.status)) {
            start(state);
        } else if (!state.abandoned) {
            state.abandoned = true;
        }
    }
}

fn answerAll(channel: u32) void {
    while (true) {
        var message = sys.Message{};
        const request = sys.recv(channel, &message, sys.POLL) orelse return;

        var reply = proto.Rep{};
        answer(&message, &reply);
        _ = sys.reply(channel, request.token, std.mem.asBytes(&reply));
    }
}

fn answer(message: *const sys.Message, reply: *proto.Rep) void {
    const bytes = message.bytes();
    if (bytes.len < @sizeOf(proto.Req)) {
        reply.result = .failed;
        return;
    }

    const request: *const proto.Req = @alignCast(@ptrCast(bytes.ptr));
    switch (request.tag) {
        .list => describe(request.index, reply),
        .start => reply.result = resume_(request.named()),
        .stop => reply.result = halt(request.named()),
        .enable => reply.result = setEnabled(request.named(), true),
        .disable => reply.result = setEnabled(request.named(), false),
    }
}

/// One service, by position. `ok` goes to zero past the end, which is how a
/// caller walking the table learns where it stops.
fn describe(index: u8, reply: *proto.Rep) void {
    if (index >= service_count) {
        reply.result = .end;
        return;
    }

    const state = &services[index];
    const name = state.service.name;

    reply.entry = .{
        .state = if (state.running)
            .up
        else if (state.held)
            .stopped
        else if (state.abandoned)
            .failed
        else
            .down,
        .pid = state.pid,
        .name_len = @intCast(@min(name.len, proto.NAME_MAX)),
    };
    @memcpy(reply.entry.name[0..reply.entry.name_len], name[0..reply.entry.name_len]);
}

fn resume_(name: []const u8) proto.Result {
    const state = byName(name) orelse return .unknown;
    if (state.running) return .ok;

    // Asking for it clears both the hold and the giving-up: somebody has
    // decided it is worth another try, which is more than init knows.
    state.held = false;
    state.abandoned = false;
    state.flapping = 0;

    start(state);
    return if (state.running) .ok else .failed;
}

fn halt(name: []const u8) proto.Result {
    const state = byName(name) orelse return .unknown;

    // Marked first. The child's death arrives through the same loop, and a
    // hold set afterwards would race with the restart it is meant to prevent.
    state.held = true;
    if (!state.running) return .ok;

    return if (sys.kill(state.pid) >= 0) .ok else .failed;
}

/// Names not to start at the next boot, one per line.
///
/// A file of its own rather than a field in the manifest, because the manifest
/// says what exists and who wrote it wrote comments in it: rewriting it to
/// record a decision would mean re-rendering it and losing them. This is the
/// decision, and it is a list of names.
const DISABLED = "/etc/disabled";

/// Remember, or forget, that a service should not start.
///
/// Says so when the decision will not outlive the boot. The root is memory
/// until there is somewhere persistent to mount over it, so writing here works
/// and is forgotten, and a caller told it worked would be told something
/// misleading.
fn setEnabled(name: []const u8, enabled: bool) proto.Result {
    const state = byName(name) orelse return .unknown;

    state.enabled = enabled;
    if (!enabled) {
        state.held = true;
        if (state.running) _ = sys.kill(state.pid);
    } else {
        state.held = false;
        state.abandoned = false;
        state.flapping = 0;
    }

    if (!writeDisabled()) return .failed;
    return if (volatileRoot()) .not_kept else .ok;
}

/// Write the list out whole, which at this size is simpler than editing it and
/// leaves no half-written state to read back.
fn writeDisabled() bool {
    var text: [512]u8 = @splat(0);
    var body = str.Builder{ .buf = &text };

    for (services[0..service_count]) |*s| {
        if (s.enabled) continue;
        body.text(s.service.name);
        body.byte('\n');
    }

    const handle = sys.open(DISABLED, .{ .write = true, .create = true, .truncate = true });
    if (handle < 0) return false;
    defer _ = sys.close(@intCast(handle));

    const written = body.done();
    return sys.write(@intCast(handle), written) == @as(isize, @intCast(written.len));
}

/// Read it back at start-up, before anything is started.
fn readDisabled() void {
    var text: [512]u8 = @splat(0);

    const handle = sys.open(DISABLED, .{});
    if (handle < 0) return;
    defer _ = sys.close(@intCast(handle));

    const n = sys.read(@intCast(handle), &text);
    if (n <= 0) return;

    var lines = str.lines(text[0..@intCast(n)]);
    while (lines.next()) |line| {
        const name = str.trim(line);
        if (name.len == 0) continue;

        if (byName(name)) |state| {
            state.enabled = false;
            state.held = true;
        }
    }
}

/// Whether what is written to the root is gone at the next boot.
///
/// Asked of the mount table rather than assumed, so that the day there is a
/// persistent volume under `/etc` this starts telling the truth without being
/// edited.
fn volatileRoot() bool {
    var buf: [512]u8 = @splat(0);
    const n = sys.sysinfo("mounts", &buf);
    if (n <= 0) return true;

    var lines = str.lines(buf[0..@intCast(n)]);
    while (lines.next()) |line| {
        if (!str.startsWith(line, "/ on ")) continue;
        return str.contains(line, "volatile");
    }
    return true;
}

fn byName(name: []const u8) ?*State {
    for (services[0..service_count]) |*s| {
        if (str.eql(s.service.name, name)) return s;
    }
    return null;
}

const proto = @import("proto").service;

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
    log.begin("init", .warn);
    out.text(who);
    out.text(": ");
    out.text(what);
    log.end();
}


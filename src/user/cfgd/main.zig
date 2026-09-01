//! cfgd, the one writer of the settings store.
//!
//! Reads do not come here. A domain's file is the store, and this writes it
//! before answering, so anything that wants a setting reads the file and gets
//! the current one. What has to be here is what a file cannot do:
//!
//!   * **one writer**, so two programs saving at the same moment cannot
//!     interleave into one file, which on a filesystem with no atomic anything
//!     is not a theoretical worry;
//!   * **notification**, so the desktop repaints when a shell changes the
//!     theme, which is the visible reason any of this exists;
//!   * **validation**, against a schema fixed at build time, so the store
//!     cannot accumulate a key nobody declared.
//!
//! design/11-userspace.md §8.

const std = @import("std");
const config = @import("ulib").config;
const log = @import("ulib").log;
const out = @import("ulib").out;
const settings = @import("proto").settings;
const str = @import("lib").str;
const sys = @import("sys");

/// One counting event per domain, handed to anyone who asks to watch it.
///
/// Created once and duplicated to each watcher, rather than one per watcher:
/// a signal has to reach everybody watching, and that is what one event with
/// many waiters already means.
var events: [settings.DOMAIN_NAMES.len]u32 = @splat(0);

export fn _start() callconv(.c) noreturn {
    cfgdMain();
}

fn cfgdMain() noreturn {
    for (&events) |*event| {
        const handle = sys.eventCreate();
        if (handle >= 0) event.* = @intCast(handle);
    }

    // What is stored is what the machine should already be doing, and at
    // startup it is not yet: the kernel is on whichever layout it compiled in.
    settings.applyInput();

    const channel = sys.svcRegister(settings.SERVICE);
    if (channel < 0) {
        log.failed("cfgd", "cannot register", channel);
        out.flush();
        sys.exit(1);
    }

    serve(@intCast(channel));
}

fn serve(channel: u32) noreturn {
    while (true) {
        var message = sys.Message{};
        const request = sys.recv(channel, &message, sys.FOREVER) orelse continue;

        var reply = sys.Message{};
        const status = answer(&message, &reply);

        const body = settings.Rep{ .status = status };
        @memcpy(reply.data[0..@sizeOf(settings.Rep)], std.mem.asBytes(&body));
        reply.len = @sizeOf(settings.Rep);

        _ = sys.replyMsg(channel, request.token, &reply);
    }
}

/// What one request asks for, and what it gets.
fn answer(message: *const sys.Message, reply: *sys.Message) settings.Status {
    const bytes = message.bytes();
    if (bytes.len < @sizeOf(settings.Req)) return .bad_value;

    const request: *const settings.Req = @alignCast(@ptrCast(bytes.ptr));
    const asked = request.parts();

    return switch (request.tag) {
        .set => apply(asked.key, asked.value),
        .reset => apply(asked.key, null),
        .watch => subscribe(asked.key, reply),
    };
}

/// Hand back the domain's event, so the caller learns of a change rather than
/// having to ask whether there was one.
fn subscribe(domain: []const u8, reply: *sys.Message) settings.Status {
    const event = eventFor(domain) orelse return .no_such_key;
    if (event == 0) return .failed;

    // Sending retains rather than consumes, so this stays ours and every
    // watcher ends up holding the same event.
    reply.handles[0] = event;
    reply.handle_count = 1;
    return .ok;
}

/// The event standing for a domain, by the domain's position in the schema.
fn eventFor(domain: []const u8) ?u32 {
    inline for (settings.DOMAIN_NAMES, 0..) |name, i| {
        if (std.mem.eql(u8, domain, name)) return events[i];
    }
    return null;
}

/// Give a key a value, or with null put it back to its default.
///
/// The domain is resolved at compile time, which is what lets one body serve
/// every domain: `Domain(name)` is a type, so the load, the check, the write
/// and the default are all the schema's own doing.
fn apply(key: []const u8, value: ?[]const u8) settings.Status {
    const parts = settings.split(key) orelse return .no_such_key;
    const context = .{ .field = parts.field, .value = value };
    return settings.onDomain(settings.Status, parts.domain, context, applyTo) orelse .no_such_key;
}

fn applyTo(comptime domain: []const u8, asked: anytype) settings.Status {
    const field = asked.field;
    const value = asked.value;

    var current = settings.load(domain);

    const outcome = if (value) |text|
        config.assign(&current, field, text)
    else
        reset(&current, field);

    switch (outcome) {
        .assigned => {},
        .no_such_key => return .no_such_key,
        .bad_value => return .bad_value,
    }

    if (!write(settings.pathOf(domain), &current)) return .failed;

    // The kernel holds the keyboard layout, so a change to it is not in effect
    // until somebody says so. Everything else is applied by whoever reads it.
    if (comptime std.mem.eql(u8, domain, "input")) settings.applyInput();

    announce(domain);
    return .ok;
}

/// Put one field back to what the struct says it should be. The defaults live
/// in the type, so a fresh one of those is where to read them from.
fn reset(current: anytype, field: []const u8) config.Outcome {
    const T = @typeInfo(@TypeOf(current)).pointer.child;
    const fresh = T{};

    inline for (std.meta.fields(T)) |declared| {
        if (std.mem.eql(u8, field, declared.name)) {
            @field(current, declared.name) = @field(fresh, declared.name);
            return .assigned;
        }
    }
    return .no_such_key;
}

/// Write the domain out whole: every key, not only what differs from its
/// default, because a file somebody can read and edit is worth more here than
/// a short one and the whole of it is a few hundred bytes.
///
/// Under a new name, then moved over the old one, per design/03-storage-fs.md
/// §6. FAT has no atomic anything, but a rename that replaces a file repoints
/// the record already there in one sector write, so a power cut leaves the
/// settings as they were or as they are meant to be and never half of each.
fn write(to: []const u8, current: anytype) bool {
    var text: [1024]u8 = @splat(0);
    var body = str.Builder{ .buf = &text };
    config.render(current, &body);

    var name: [64]u8 = undefined;
    var staged = str.Builder{ .buf = &name };
    staged.text(to);
    staged.text(".new");

    if (!put(staged.done(), body.done())) return false;
    if (sys.rename(staged.done(), to) < 0) return false;
    // The rename has repointed the name; the drive may still be holding the
    // sector that says so. A setting is acknowledged only once it is on the
    // medium, which is the whole of what makes it a setting rather than a
    // suggestion the next power cut is free to take back.
    return sys.sync();
}

fn put(where: []const u8, body: []const u8) bool {
    const handle = sys.open(where, .{ .write = true, .create = true, .truncate = true });
    if (handle < 0) return false;
    defer _ = sys.close(@intCast(handle));

    return sys.write(@intCast(handle), body) == @as(isize, @intCast(body.len));
}

/// Wake everyone watching this domain.
fn announce(domain: []const u8) void {
    if (eventFor(domain)) |event| {
        if (event != 0) _ = sys.eventSignal(event);
    }
}

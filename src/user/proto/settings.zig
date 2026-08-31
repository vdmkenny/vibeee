//! Settings: the schema, the wire, and the client half.
//!
//! Two programs must be able to change the same setting and see each other do
//! it, which is what a file per program does not give. That is the whole
//! reason `cfgd` exists.
//!
//! **The schema is the structs.** Field names are keys, field types are the
//! value grammar, and field defaults are the defaults. There is no schema
//! language and no table beside the type, because the type already says all
//! three. Everything below is a walk over `std.meta.fields`, so a setting is
//! added by adding a field and appears in the store, the command line, the
//! completer and the settings app at once.
//!
//! **Keys cannot be invented.** `cfg set nothing.here 1` is an error rather
//! than a new key. That is what separates a schema from a registry: the store
//! cannot accumulate what nobody declared, so it cannot rot.
//!
//! **Readers read the file; only writers go through the service.** `cfgd`
//! writes the domain's file before it answers, so a reader sees the change by
//! reading, and the path taken when the service is missing is the same path
//! taken when it is there. A design where settings are reachable only through
//! a running service is one where a failed service cannot be repaired.
//!
//! design/11-userspace.md §8.

const std = @import("std");
const config = @import("ulib").config;
const str = @import("lib").str;
const sys = @import("sys");
const theme = @import("eui").theme;

pub const SERVICE = "cfg";

// ---------------------------------------------------------------------------
// The schema
// ---------------------------------------------------------------------------

/// Declared in `schema.zig`, which knows nothing of this service, and named
/// again here so every caller reaches settings through one file.
pub const schema = @import("schema.zig");

pub const Theme = schema.Theme;
pub const Bar = schema.Bar;
pub const Layout = schema.Layout;
pub const Wm = schema.Wm;
pub const Keymap = schema.Keymap;
pub const Input = schema.Input;
pub const NET_SLOTS = schema.NET_SLOTS;
pub const NetMachine = schema.NetMachine;
pub const NetSlot = schema.NetSlot;
pub const Net = schema.Net;
pub const Time = schema.Time;
pub const Host = schema.Host;
pub const netSlot = schema.netSlot;
pub const netMachine = schema.netMachine;
pub const setNetSlot = schema.setNetSlot;
pub const Domains = schema.Domains;
pub const DOMAIN_NAMES = schema.DOMAIN_NAMES;

comptime {
    if (std.meta.fields(Theme).len != theme.all.len) {
        @compileError("settings.Theme and eui.theme.all disagree about how many themes there are");
    }
    for (std.meta.fields(Theme)) |field| {
        if (theme.byName(field.name) == null) {
            @compileError("settings.Theme names `" ++ field.name ++ "`, which eui has no theme for");
        }
    }
}

/// What a domain is when nobody has said otherwise. In the root
/// filesystem, which is rebuilt from the boot medium at every boot, so it
/// is read-only in the only sense that matters: writing there changes
/// nothing past the next start.
pub fn defaultsOf(comptime domain: []const u8) []const u8 {
    return "/etc/" ++ domain ++ ".cfg";
}

/// Where a domain's choices are kept. A volume of its own on the boot
/// medium, mounted at /cfg, which is what makes a choice outlive the
/// machine being switched off.
///
/// Comptime, because the name is a field name.
pub fn pathOf(comptime domain: []const u8) []const u8 {
    return "/cfg/" ++ domain ++ ".cfg";
}

/// The type behind a domain's name, or null for a name that is not one.
pub fn Domain(comptime domain: []const u8) type {
    for (std.meta.fields(Domains)) |field| {
        if (str.eql(domain, field.name)) return field.type;
    }
    @compileError("no settings domain named `" ++ domain ++ "`");
}

/// Run `body` for the domain called `name`, with the name comptime-known so
/// the body can reach its type, its fields and its defaults. Null when nothing
/// is called that.
///
/// Here rather than in each caller because every one of them was writing the
/// same `inline for` to turn a name into a type, and a domain is this module's
/// to resolve.
pub fn onDomain(comptime T: type, name: []const u8, context: anytype, comptime body: anytype) ?T {
    inline for (DOMAIN_NAMES) |candidate| {
        if (str.eql(name, candidate)) return body(candidate, context);
    }
    return null;
}

/// Split `domain.field`. Null when it is not that shape.
pub fn split(key: []const u8) ?struct { domain: []const u8, field: []const u8 } {
    for (key, 0..) |c, i| {
        if (c != '.') continue;
        if (i == 0 or i + 1 == key.len) return null;
        return .{ .domain = key[0..i], .field = key[i + 1 ..] };
    }
    return null;
}

// ---------------------------------------------------------------------------
// The wire
// ---------------------------------------------------------------------------

/// Key and value share one span because the payload is 64 bytes and splitting
/// it evenly would cap both at half of what either might need.
pub const TEXT_MAX = 60;

pub const Tag = enum(u8) {
    /// Give this key this value.
    set,
    /// Put this key back to its default, which is dropping it from the file.
    reset,
    /// An event handle that fires when anything in this domain changes.
    /// The key names the domain alone.
    watch,
};

pub const Req = extern struct {
    tag: Tag,
    key_len: u8 = 0,
    value_len: u8 = 0,
    _reserved: u8 = 0,
    /// The key, and then the value immediately after it.
    text: [TEXT_MAX]u8 = @splat(0),

    pub fn init(tag: Tag, key: []const u8, value: []const u8) ?Req {
        if (key.len + value.len > TEXT_MAX) return null;

        var self = Req{ .tag = tag, .key_len = @intCast(key.len), .value_len = @intCast(value.len) };
        @memcpy(self.text[0..key.len], key);
        @memcpy(self.text[key.len..][0..value.len], value);
        return self;
    }

    /// The two spans back out, in the shape `config.pair` hands back a parsed
    /// line: this is the same pair, and reading it should look the same.
    pub fn parts(self: *const Req) struct { key: []const u8, value: []const u8 } {
        const split_at = @min(self.key_len, TEXT_MAX);
        const ends_at = @min(split_at + self.value_len, TEXT_MAX);
        return .{ .key = self.text[0..split_at], .value = self.text[split_at..ends_at] };
    }
};

pub const Status = enum(u8) {
    ok,
    /// No domain or field of that name. A typo, not a new setting.
    no_such_key,
    /// The field's type does not accept that value.
    bad_value,
    /// The store could not be written.
    failed,
};

pub const Rep = extern struct {
    status: Status = .ok,
    _reserved: [3]u8 = @splat(0),
};

// ---------------------------------------------------------------------------
// The client half
// ---------------------------------------------------------------------------

pub const Error = error{ NoService, NoSuchKey, BadValue, Failed };

/// A domain, read from its file.
///
/// The file, not the service, because the file is the store: `cfgd` writes it
/// before answering, so reading it is reading the current state, and a program
/// that runs before the service does gets the same answer by the same means.
pub fn load(comptime domain: []const u8) Domain(domain) {
    var value: Domain(domain) = .{};

    // The defaults first, then whatever was chosen on top. A store holding
    // only what somebody changed is still a complete answer, and a machine
    // whose /cfg is missing or empty behaves as it did when it was built
    // rather than as if every setting had been unset.
    var defaults: [schema.FILE_MAX]u8 = @splat(0);
    _ = config.load(defaultsOf(domain), &value, &defaults);

    var chosen: [schema.FILE_MAX]u8 = @splat(0);
    _ = config.load(pathOf(domain), &value, &chosen);
    return value;
}

/// Put the input settings into effect.
///
/// Everything else is applied by whoever reads it: the desktop themes itself.
/// The keyboard layout is the kernel's, so somebody has to hand it over, and
/// doing it here means the one place that knows a setting has changed is the
/// one place that says so.
pub fn applyInput() void {
    _ = sys.setKeymap(load("input").keymap);
}

pub fn set(key: []const u8, value: []const u8) Error!void {
    return ask(.set, key, value);
}

pub fn reset(key: []const u8) Error!void {
    return ask(.reset, key, "");
}

/// An event that fires whenever anything in `domain` changes.
///
/// What makes a change visible without a restart: a watcher already has an
/// event loop, so this joins the handles it was waiting on anyway.
pub fn watch(domain: []const u8) Error!u32 {
    const channel = connect() orelse return error.NoService;
    defer _ = sys.close(channel);

    var reply = sys.Message{};
    try send(channel, .watch, domain, "", &reply);

    const handles = reply.handleSlice();
    if (handles.len == 0) return error.Failed;
    return handles[0];
}

/// Store what differs from what is already stored, and nothing else.
///
/// A whole domain sent field by field would rewrite the file once per field
/// and wake every watcher as many times, for a saving of one thing.
pub fn save(comptime domain: []const u8, value: Domain(domain)) Error!void {
    const stored = load(domain);

    inline for (std.meta.fields(Domain(domain))) |field| {
        if (!std.meta.eql(@field(value, field.name), @field(stored, field.name))) {
            var key_text: [TEXT_MAX]u8 = undefined;
            var key = str.Builder{ .buf = &key_text };
            key.text(domain);
            key.byte('.');
            key.text(field.name);

            var value_text: [TEXT_MAX]u8 = undefined;
            var written = str.Builder{ .buf = &value_text };
            config.format(&written, @field(value, field.name));

            try set(key.done(), written.done());
        }
    }
}

fn ask(tag: Tag, key: []const u8, value: []const u8) Error!void {
    const channel = connect() orelse return error.NoService;
    defer _ = sys.close(channel);

    var reply = sys.Message{};
    return send(channel, tag, key, value, &reply);
}

/// One exchange, and the status turned back into an error. Every request goes
/// through here so the reply is judged in one place.
fn send(channel: u32, tag: Tag, key: []const u8, value: []const u8, reply: *sys.Message) Error!void {
    const request = Req.init(tag, key, value) orelse return error.BadValue;
    const message = sys.Message.init(std.mem.asBytes(&request), &.{});
    if (sys.callMsg(channel, &message, reply) < 0) return error.Failed;

    return switch (statusOf(reply)) {
        .ok => {},
        .no_such_key => error.NoSuchKey,
        .bad_value => error.BadValue,
        .failed => error.Failed,
    };
}

fn connect() ?u32 {
    const channel = sys.svcConnect(SERVICE);
    return if (channel < 0) null else @intCast(channel);
}

fn statusOf(reply: *const sys.Message) Status {
    const bytes = reply.bytes();
    if (bytes.len < @sizeOf(Rep)) return .failed;
    return @as(*const Rep, @alignCast(@ptrCast(bytes.ptr))).status;
}

//! `/svc`, the service registry.
//!
//! A name maps to a channel. That is the whole thing, and it is what makes a
//! restartable server possible: a client holds a name rather than a handle to
//! a particular instance, so when `netd` dies and comes back, reconnecting is
//! a lookup rather than a redesign.
//!
//! Flat and fixed-size. A tree would buy nothing while the whole system has a
//! dozen services, and the fixed array means registration cannot fail for want
//! of memory at the moment a driver is coming up.
//!
//! `design/00-vibeee.md` §6.8.

const std = @import("std");
const channel = @import("channel.zig");
const hal = @import("hal.zig");
const names = @import("lib").services;

pub const Error = error{
    TableFull,
    AlreadyRegistered,
    NotFound,
    BadName,
};

pub const MAX_SERVICES = 16;

/// From `lib`, so the registry's storage and the rule about what a name may be
/// cannot come to disagree about how long one is.
pub const MAX_NAME = names.MAX_NAME;

/// Whether taking this name needs the `service` capability. The list is in
/// `lib` because the kernel must not learn which names are the system's own
/// from the programs it is deciding about.
pub const isReserved = names.isReserved;

const Entry = struct {
    name_buf: [MAX_NAME]u8 = @splat(0),
    name_len: usize = 0,
    ch: ?*channel.Channel = null,

    fn name(self: *const Entry) []const u8 {
        return self.name_buf[0..self.name_len];
    }
};

var table: [MAX_SERVICES]Entry = @splat(.{});

/// Whether an entry still has a server behind it.
///
/// A channel stops serving the moment its serving handle closes, which is what
/// happens when a server exits or crashes. The name outlives that by design so
/// clients keep a stable thing to look up, but a dead entry must not behave
/// like a live one.
fn isLive(e: *const Entry) bool {
    const ch = e.ch orelse return false;
    return ch.serving;
}

/// Release an entry whose server has gone.
fn retire(e: *Entry) void {
    if (e.ch) |ch| channel.release(ch);
    e.ch = null;
    e.name_len = 0;
}

/// Publish `ch` under `name`.
///
/// A name whose server has exited is free to take: otherwise the entry would
/// sit there holding a channel nobody serves, and the restart the registry
/// exists to support would fail with the name already registered. Only a live
/// server blocks a name.
pub fn register(name: []const u8, ch: *channel.Channel) Error!void {
    if (!names.isValidName(name)) return error.BadName;

    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    for (&table) |*e| {
        if (e.ch == null or !std.mem.eql(u8, e.name(), name)) continue;
        if (isLive(e)) return error.AlreadyRegistered;
        retire(e);
    }
    for (&table) |*e| {
        if (e.ch != null) continue;
        @memcpy(e.name_buf[0..name.len], name);
        e.name_len = name.len;
        e.ch = ch;
        channel.retain(ch);
        return;
    }
    return error.TableFull;
}

/// Withdraw a name, so a client that looks it up learns the server is gone
/// rather than connecting to a channel nobody is serving.
pub fn unregister(name: []const u8) void {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    for (&table) |*e| {
        if (e.ch) |ch| {
            if (!std.mem.eql(u8, e.name(), name)) continue;
            e.ch = null;
            e.name_len = 0;
            channel.release(ch);
            return;
        }
    }
}

/// Look a name up, taking a reference on the channel for the caller to hold.
///
/// A name whose server has gone reports NotFound rather than handing back a
/// channel that would fail every call: "the service is not there" is the
/// answer a client can act on, and it is the same answer it will get until the
/// server comes back.
pub fn lookup(name: []const u8) Error!*channel.Channel {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    for (&table) |*e| {
        if (e.ch == null or !std.mem.eql(u8, e.name(), name)) continue;
        if (!isLive(e)) {
            retire(e);
            return error.NotFound;
        }
        channel.retain(e.ch.?);
        return e.ch.?;
    }
    return error.NotFound;
}

/// Every registered name, for `sysinfo` and the eventual `Monitor` app.
///
/// Snapshotted rather than returned as a view of the table, so a caller
/// iterating it cannot be tripped by a service registering or going away
/// mid-walk.
///
/// The names are copied and not pointed at. A slice into the table is still
/// the table: an entry retired and taken by another service rewrites the
/// bytes under whoever is reading them, and the reader sees a name that
/// belongs to neither.
var listed: [MAX_SERVICES][MAX_NAME]u8 = @splat(@splat(0));
var listing: [MAX_SERVICES][]const u8 = @splat(&.{});

pub fn list() []const []const u8 {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    var n: usize = 0;
    for (&table) |*e| {
        if (!isLive(e)) continue;
        const name = e.name();
        @memcpy(listed[n][0..name.len], name);
        listing[n] = listed[n][0..name.len];
        n += 1;
    }
    return listing[0..n];
}

pub fn count() usize {
    const flags = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(flags);

    var n: usize = 0;
    for (&table) |*e| {
        if (isLive(e)) n += 1;
    }
    return n;
}

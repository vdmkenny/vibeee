//! cfg, the command line onto the settings store.
//!
//! Every key, every value and every default comes from the schema in
//! `proto.settings`, so this holds no table of its own: a setting added there
//! is one this lists, sets, validates and completes without a line here
//! changing.

const std = @import("std");
const complete = @import("ulib").complete;
const config = @import("ulib").config;
const ink = @import("ulib").ink;
const out = @import("ulib").out;
const settings = @import("proto").settings;
const str = @import("lib").str;

pub fn run(args: []const []const u8) void {
    if (args.len == 0) return listAll();

    const verb = args[0];
    if (str.eql(verb, "get")) return get(rest(args, 1));
    if (str.eql(verb, "set")) return set(rest(args, 1));
    if (str.eql(verb, "reset")) return reset(rest(args, 1));

    // A bare domain name lists it, because `cfg wm` is what someone types
    // when they want to know what `wm` has.
    inline for (settings.DOMAIN_NAMES) |name| {
        if (str.eql(verb, name)) return listOne(name);
    }

    out.text("usage: cfg [get|set|reset] <domain.key> [value]\n");
    out.text("       cfg [<domain>]\n");
    out.flush();
}

fn rest(args: []const []const u8, from: usize) []const []const u8 {
    return if (args.len > from) args[from..] else &.{};
}

fn listAll() void {
    inline for (settings.DOMAIN_NAMES) |name| listOne(name);
    out.flush();
}

fn listOne(comptime domain: []const u8) void {
    const D = settings.Domain(domain);
    const current = settings.load(domain);
    const fresh = D{};

    inline for (std.meta.fields(D)) |field| {
        var key: [64]u8 = undefined;
        var name = str.Builder{ .buf = &key };
        name.text(domain);
        name.byte('.');
        name.text(field.name);
        out.pad(name.done(), 20);

        var text: [64]u8 = undefined;
        var shown = str.Builder{ .buf = &text };
        config.format(&shown, @field(current, field.name));

        // A value that is still the default is worth telling apart from one
        // somebody chose, because that is the difference `reset` undoes.
        if (std.meta.eql(@field(current, field.name), @field(fresh, field.name))) {
            out.text(shown.done());
        } else {
            ink.bright(.white);
            out.text(shown.done());
            ink.plain();
        }
        out.byte('\n');
    }
    out.flush();
}

fn get(args: []const []const u8) void {
    if (args.len == 0) return usage("get <domain.key>");

    const parts = settings.split(args[0]) orelse return unknown(args[0]);
    const found = settings.onDomain(bool, parts.domain, parts.field, getFrom) orelse false;
    if (!found) unknown(args[0]);
}

fn getFrom(comptime domain: []const u8, field: []const u8) bool {
    const current = settings.load(domain);

    inline for (std.meta.fields(settings.Domain(domain))) |declared| {
        if (str.eql(field, declared.name)) {
            var text: [64]u8 = undefined;
            var shown = str.Builder{ .buf = &text };
            config.format(&shown, @field(current, declared.name));
            out.text(shown.done());
            out.byte('\n');
            out.flush();
            return true;
        }
    }
    return false;
}

fn set(args: []const []const u8) void {
    if (args.len < 2) return usage("set <domain.key> <value>");
    report(args[0], settings.set(args[0], args[1]));
}

fn reset(args: []const []const u8) void {
    if (args.len == 0) return usage("reset <domain.key>");
    report(args[0], settings.reset(args[0]));
}

/// What the service said, in the words of whoever asked.
fn report(key: []const u8, result: settings.Error!void) void {
    result catch |err| {
        out.text("cfg: ");
        switch (err) {
            error.NoService => out.text("the settings service is not running"),
            error.NoSuchKey => {
                out.text(key);
                out.text(": no such setting");
            },
            error.BadValue => {
                out.text(key);
                out.text(": not a value that setting takes");
                offerChoices(key);
            },
            error.Failed => out.text("the store could not be written"),
        }
        out.byte('\n');
        return out.flush();
    };
}

/// Having refused a value, say which ones would have worked. The schema knows,
/// so there is no reason to make somebody go and look.
fn offerChoices(key: []const u8) void {
    const parts = settings.split(key) orelse return;
    _ = settings.onDomain(void, parts.domain, parts.field, sayChoices);
}

fn sayChoices(comptime domain: []const u8, field: []const u8) void {
    inline for (std.meta.fields(settings.Domain(domain))) |declared| {
        if (str.eql(field, declared.name)) {
            const choices = comptime config.choices(settings.Domain(domain), declared.name);
            if (choices.len == 0) return;

            out.text(". one of: ");
            inline for (choices, 0..) |choice, i| {
                if (i > 0) out.text(", ");
                out.text(choice);
            }
            return;
        }
    }
}

/// Offer the keys and then the values for one, so a shell can complete its way
/// into a setting rather than only up to it.
pub fn offer(ctx: complete.Context, into: *complete.Collector) void {
    if (ctx.index == 1) {
        for ([_][]const u8{ "get", "set", "reset" }) |verb| into.offer(verb);
        inline for (settings.DOMAIN_NAMES) |domain| into.offer(domain);
        return;
    }

    if (ctx.index == 2) {
        inline for (settings.DOMAIN_NAMES) |domain| {
            inline for (comptime config.keys(settings.Domain(domain))) |field| {
                var text: [64]u8 = undefined;
                var name = str.Builder{ .buf = &text };
                name.text(domain);
                name.byte('.');
                name.text(field);
                into.offer(name.done());
            }
        }
        return;
    }

    // The value position: only a closed set is worth offering, and only the
    // one belonging to the key already typed.
    if (ctx.index != 3) return;
    const key = wordAt(ctx.line, 2) orelse return;
    const parts = settings.split(key) orelse return;
    _ = settings.onDomain(void, parts.domain, .{ .field = parts.field, .into = into }, offerValues);
}

fn offerValues(comptime domain: []const u8, ctx: anytype) void {
    inline for (std.meta.fields(settings.Domain(domain))) |declared| {
        if (str.eql(ctx.field, declared.name)) {
            inline for (comptime config.choices(settings.Domain(domain), declared.name)) |choice| {
                ctx.into.offer(choice);
            }
            return;
        }
    }
}

/// The nth space-separated word of a line, counting the command as zero.
fn wordAt(line: []const u8, index: usize) ?[]const u8 {
    var seen: usize = 0;
    var at: usize = 0;
    while (at < line.len) {
        while (at < line.len and line[at] == ' ') at += 1;
        const from = at;
        while (at < line.len and line[at] != ' ') at += 1;
        if (at == from) break;
        if (seen == index) return line[from..at];
        seen += 1;
    }
    return null;
}

fn usage(what: []const u8) void {
    out.text("usage: cfg ");
    out.text(what);
    out.byte('\n');
    out.flush();
}

fn unknown(key: []const u8) void {
    out.text("cfg: ");
    out.text(key);
    out.text(": no such setting\n");
    out.flush();
}

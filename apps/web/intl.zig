//! `Intl`: the locale objects ECMA-402 gives a script, which the engine has
//! none of. One locale's conventions stand for every locale a script names:
//! English as the United States writes it, with the clock on UTC. What a
//! script asked for is what `resolvedOptions` reads back, and the formats
//! are the English ones whichever locale it named.
//!
//! Pages reach for these before they show a date, a count or a list, ask
//! what locale they are in, or sort names; a module bundle that finds no
//! `Intl` at all stops while it loads. What is here is what mainstream pages
//! use: the seven constructors, their `format`, `select` and `compare`, the
//! parts a format is made of, and `toLocaleString` on numbers and dates,
//! which read through the same formats.
//!
//! An instance keeps the locale it was made for and its options as two
//! properties a script cannot list, and the methods on its prototype read
//! them back: nothing is kept outside the script's own heap.

const std = @import("std");
const qjs = @import("quickjs");
const civil = @import("lib").civil;

const Context = qjs.Context;
const Value = qjs.Value;

/// The locale every format is written in, and the one a script is told it
/// asked for where it named none.
const LOCALE = "en-US";

/// The one time zone the clock is read in.
const TIME_ZONE = "UTC";

/// The seven constructors, each with a prototype its methods sit on.
const Kind = enum {
    date_time_format,
    number_format,
    plural_rules,
    collator,
    list_format,
    relative_time_format,
    locale,

    fn name(comptime self: Kind) [*:0]const u8 {
        return switch (self) {
            .date_time_format => "DateTimeFormat",
            .number_format => "NumberFormat",
            .plural_rules => "PluralRules",
            .collator => "Collator",
            .list_format => "ListFormat",
            .relative_time_format => "RelativeTimeFormat",
            .locale => "Locale",
        };
    }

    fn methods(comptime self: Kind) []const qjs.ListEntry {
        return switch (self) {
            .date_time_format => &date_methods,
            .number_format => &number_methods,
            .plural_rules => &plural_methods,
            .collator => &collator_methods,
            .list_format => &list_methods,
            .relative_time_format => &relative_methods,
            .locale => &locale_methods,
        };
    }
};

/// Give a context its `Intl`, and the `toLocaleString` calls on numbers and
/// dates that read through it.
pub fn install(ctx: *Context) void {
    const global = qjs.globalOf(ctx);
    defer qjs.free(ctx, global);
    const intl = qjs.newObject(ctx);
    inline for (comptime std.enums.values(Kind)) |kind| {
        const class = qjs.newConstructor(ctx, kind.name(), 0, constructor(kind));
        const proto = qjs.newObject(ctx);
        defer qjs.free(ctx, proto);
        const list = kind.methods();
        _ = qjs.addList(ctx, proto, list.ptr, @intCast(list.len));
        qjs.setConstructor(ctx, class, proto);
        give(ctx, class, "supportedLocalesOf", 1, &jsLocalesOf);
        _ = qjs.setStr(ctx, intl, kind.name(), class);
    }
    give(ctx, intl, "getCanonicalLocales", 1, &jsLocalesOf);
    _ = qjs.setStr(ctx, global, "Intl", intl);

    const number = qjs.getStr(ctx, global, "Number");
    defer qjs.free(ctx, number);
    const number_proto = qjs.getStr(ctx, number, "prototype");
    defer qjs.free(ctx, number_proto);
    give(ctx, number_proto, "toLocaleString", 0, &jsNumberToLocaleString);

    const date = qjs.getStr(ctx, global, "Date");
    defer qjs.free(ctx, date);
    const date_proto = qjs.getStr(ctx, date, "prototype");
    defer qjs.free(ctx, date_proto);
    give(ctx, date_proto, "toLocaleString", 0, dateToLocale(.any, .all));
    give(ctx, date_proto, "toLocaleDateString", 0, dateToLocale(.date, .date));
    give(ctx, date_proto, "toLocaleTimeString", 0, dateToLocale(.time, .time));
}

fn give(ctx: *Context, into: Value, name: [*:0]const u8, arity: u8, impl: qjs.Method) void {
    _ = qjs.setStr(ctx, into, name, qjs.newFunction(ctx, name, arity, impl));
}

fn str(ctx: *Context, text: []const u8) Value {
    return qjs.newStringOf(ctx, text);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

// ---------------------------------------------------------------------------
// Making an instance
// ---------------------------------------------------------------------------

fn constructor(comptime kind: Kind) qjs.Method {
    const S = struct {
        fn call(ctx: *Context, target: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
            return construct(ctx, target, argc, argv, kind);
        }
    };
    return &S.call;
}

/// An instance of `kind`: an object on the constructor's prototype, keeping
/// the locale it was asked for and the options it was given. `target` is
/// what `new` was called on, or nothing where the constructor was called as
/// a function, which the older ones allow.
fn construct(ctx: *Context, target: Value, argc: c_int, argv: [*]const Value, comptime kind: Kind) Value {
    const proto = prototypeOf(ctx, target, kind);
    defer qjs.free(ctx, proto);
    const it = qjs.newObjectProto(ctx, proto);
    if (qjs.isException(it)) return it;
    const tag = if (kind == .locale) tagOf(ctx, argc, argv) else localeOf(ctx, argc, argv);
    if (qjs.isException(tag)) {
        qjs.free(ctx, it);
        return tag;
    }
    _ = qjs.defineStr(ctx, it, "__locale", tag, 0);
    const options = if (argc > 1 and qjs.isObject(argv[1])) qjs.dup(ctx, argv[1]) else qjs.newObject(ctx);
    _ = qjs.defineStr(ctx, it, "__options", options, 0);
    return it;
}

/// The prototype an instance goes on: the one `new` was told, so that a
/// class extending ours gets its own, or the constructor's own otherwise.
fn prototypeOf(ctx: *Context, target: Value, comptime kind: Kind) Value {
    if (qjs.isObject(target)) {
        const told = qjs.getStr(ctx, target, "prototype");
        if (qjs.isObject(told)) return told;
        qjs.free(ctx, told);
    }
    const global = qjs.globalOf(ctx);
    defer qjs.free(ctx, global);
    const intl = qjs.getStr(ctx, global, "Intl");
    defer qjs.free(ctx, intl);
    const class = qjs.getStr(ctx, intl, kind.name());
    defer qjs.free(ctx, class);
    return qjs.getStr(ctx, class, "prototype");
}

/// The locale a constructor was asked for, as a string: the first of a list,
/// a `Locale`'s own tag, or the one locale where none was named.
fn localeOf(ctx: *Context, argc: c_int, argv: [*]const Value) Value {
    if (argc == 0) return str(ctx, LOCALE);
    return firstLocale(ctx, argv[0]);
}

fn firstLocale(ctx: *Context, given: Value) Value {
    if (qjs.isUndefined(given) or qjs.isNull(given)) return str(ctx, LOCALE);
    if (qjs.isArray(ctx, given) != 0) {
        const first = qjs.getAt(ctx, given, 0);
        defer qjs.free(ctx, first);
        if (qjs.isUndefined(first)) return str(ctx, LOCALE);
        return firstLocale(ctx, first);
    }
    if (qjs.isObject(given)) {
        const kept = qjs.getStr(ctx, given, "__locale");
        if (!qjs.isUndefined(kept)) return kept;
        qjs.free(ctx, kept);
    }
    const text = qjs.sliceOf(ctx, given) orelse return str(ctx, LOCALE);
    defer qjs.freeText(ctx, text.ptr);
    return canonical(ctx, text);
}

/// A locale tag with its subtags cased as the standard writes them, or the
/// text as given where it is not a tag.
fn canonical(ctx: *Context, text: []const u8) Value {
    const tag = Tag.parse(text) orelse return str(ctx, text);
    var buf: [TAG_MAX]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    tag.write(&w);
    return str(ctx, w.buffered());
}

/// The tag a `Locale` is made from, which must be one: nothing else stands
/// in for it.
fn tagOf(ctx: *Context, argc: c_int, argv: [*]const Value) Value {
    if (argc == 0 or qjs.isUndefined(argv[0]) or qjs.isNull(argv[0])) return qjs.throwType(ctx, "Incorrect locale information provided");
    if (qjs.isObject(argv[0])) {
        const kept = qjs.getStr(ctx, argv[0], "__locale");
        if (!qjs.isUndefined(kept)) return kept;
        qjs.free(ctx, kept);
    }
    const text = qjs.sliceOf(ctx, argv[0]) orelse return qjs.throwType(ctx, "Incorrect locale information provided");
    defer qjs.freeText(ctx, text.ptr);
    if (Tag.parse(text) == null) return qjs.throwRange(ctx, "Incorrect locale information provided");
    return canonical(ctx, text);
}

/// The most a locale tag comes to with its extensions.
const TAG_MAX = 64;

/// A locale tag taken apart: the language, and the script and region where
/// it names them. What follows those is kept as it came.
const Tag = struct {
    language: []const u8,
    script: ?[]const u8 = null,
    region: ?[]const u8 = null,
    rest: []const u8 = "",

    fn parse(text: []const u8) ?Tag {
        var parts = std.mem.splitAny(u8, text, "-_");
        const language = parts.next() orelse return null;
        if (language.len < 2 or language.len > 8 or !allLetters(language)) return null;
        var tag: Tag = .{ .language = language };
        var next = parts.next();
        if (next) |part| {
            if (part.len == 4 and allLetters(part)) {
                tag.script = part;
                next = parts.next();
            }
        }
        if (next) |part| {
            if ((part.len == 2 and allLetters(part)) or (part.len == 3 and allDigits(part))) {
                tag.region = part;
                next = parts.next();
            }
        }
        if (next) |part| {
            const from = @intFromPtr(part.ptr) - @intFromPtr(text.ptr);
            tag.rest = text[from..];
        }
        return tag;
    }

    /// The tag as the standard cases it: language lowered, script with a
    /// capital, region raised.
    fn write(self: Tag, w: *std.Io.Writer) void {
        var buf: [8]u8 = undefined;
        w.writeAll(std.ascii.lowerString(&buf, self.language)) catch {};
        if (self.script) |script| {
            const cased = std.ascii.lowerString(&buf, script);
            cased[0] = std.ascii.toUpper(cased[0]);
            w.writeByte('-') catch {};
            w.writeAll(cased) catch {};
        }
        if (self.region) |region| {
            w.writeByte('-') catch {};
            w.writeAll(std.ascii.upperString(&buf, region)) catch {};
        }
        if (self.rest.len > 0) {
            w.writeByte('-') catch {};
            w.writeAll(self.rest) catch {};
        }
    }

    /// The language, script and region alone.
    fn writeBase(self: Tag, w: *std.Io.Writer) void {
        var base = self;
        base.rest = "";
        base.write(w);
    }
};

fn allLetters(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}

fn allDigits(text: []const u8) bool {
    for (text) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// ---------------------------------------------------------------------------
// What every kind shares
// ---------------------------------------------------------------------------

/// `supportedLocalesOf` and `getCanonicalLocales`: the locales given, each
/// cased as the standard writes it, as a list. Every locale is supported,
/// since every one is written the same way.
fn jsLocalesOf(ctx: *Context, _: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const out = qjs.newArray(ctx);
    if (argc == 0 or qjs.isUndefined(argv[0])) return out;
    if (qjs.isArray(ctx, argv[0]) != 0) {
        var count: i32 = 0;
        const length = qjs.getStr(ctx, argv[0], "length");
        defer qjs.free(ctx, length);
        _ = qjs.toInt(ctx, &count, length);
        var index: u32 = 0;
        while (index < @as(u32, @intCast(@max(count, 0)))) : (index += 1) {
            const one = qjs.getAt(ctx, argv[0], index);
            defer qjs.free(ctx, one);
            _ = qjs.setAt(ctx, out, index, firstLocale(ctx, one));
        }
        return out;
    }
    _ = qjs.setAt(ctx, out, 0, firstLocale(ctx, argv[0]));
    return out;
}

/// The locale an instance keeps, as a new reference.
fn localeKept(ctx: *Context, this: Value) Value {
    const kept = qjs.getStr(ctx, this, "__locale");
    if (!qjs.isUndefined(kept)) return kept;
    qjs.free(ctx, kept);
    return str(ctx, LOCALE);
}

/// The options an instance keeps, as a new reference; nothing where the
/// call was made on something else.
fn optionsKept(ctx: *Context, this: Value) Value {
    return qjs.getStr(ctx, this, "__options");
}

/// An option's words copied into `buf`, or nothing where it is not set. A
/// boolean reads as its words, which is how `hour12: false` is told apart.
fn optionOf(ctx: *Context, options: Value, name: [*:0]const u8, buf: []u8) ?[]const u8 {
    if (!qjs.isObject(options)) return null;
    const value = qjs.getStr(ctx, options, name);
    defer qjs.free(ctx, value);
    if (qjs.isUndefined(value) or qjs.isNull(value)) return null;
    const text = qjs.sliceOf(ctx, value) orelse return null;
    defer qjs.freeText(ctx, text.ptr);
    const n = @min(text.len, buf.len);
    @memcpy(buf[0..n], text[0..n]);
    return buf[0..n];
}

/// A counted option, held to what the formats can write.
fn optionCount(ctx: *Context, options: Value, name: [*:0]const u8) ?u8 {
    if (!qjs.isObject(options)) return null;
    const value = qjs.getStr(ctx, options, name);
    defer qjs.free(ctx, value);
    if (qjs.isUndefined(value) or qjs.isNull(value)) return null;
    var count: i32 = 0;
    if (qjs.toInt(ctx, &count, value) < 0) return null;
    return @intCast(std.math.clamp(count, 0, PLACES_MAX));
}

/// The most digits a count option may ask for after the point.
const PLACES_MAX = 20;

/// `Object.assign(into, from)`: the options a script gave, copied over the
/// defaults `resolvedOptions` starts from.
fn assign(ctx: *Context, into: Value, from: Value) void {
    if (!qjs.isObject(from)) return;
    const global = qjs.globalOf(ctx);
    defer qjs.free(ctx, global);
    const object = qjs.getStr(ctx, global, "Object");
    defer qjs.free(ctx, object);
    const method = qjs.getStr(ctx, object, "assign");
    defer qjs.free(ctx, method);
    const done = qjs.call(ctx, method, object, 2, &[_]Value{ into, from });
    qjs.free(ctx, done);
}

fn resolvedOptions(comptime kind: Kind) qjs.Method {
    const S = struct {
        fn call(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
            return resolved(ctx, this, kind);
        }
    };
    return &S.call;
}

/// `resolvedOptions`: the locale, the defaults the kind has, and over them
/// whatever the instance was asked for.
fn resolved(ctx: *Context, this: Value, comptime kind: Kind) Value {
    const out = qjs.newObject(ctx);
    _ = qjs.setStr(ctx, out, "locale", localeKept(ctx, this));
    const options = optionsKept(ctx, this);
    defer qjs.free(ctx, options);
    switch (kind) {
        .date_time_format => {
            _ = qjs.setStr(ctx, out, "calendar", str(ctx, "gregory"));
            _ = qjs.setStr(ctx, out, "numberingSystem", str(ctx, "latn"));
            _ = qjs.setStr(ctx, out, "timeZone", str(ctx, TIME_ZONE));
            const style = dateStyleOf(ctx, options, .any, .date);
            if (style.date_style == null and style.time_style == null and style.defaulted) {
                inline for (.{ "year", "month", "day" }) |part| _ = qjs.setStr(ctx, out, part, str(ctx, "numeric"));
            }
        },
        .number_format => {
            _ = qjs.setStr(ctx, out, "numberingSystem", str(ctx, "latn"));
            _ = qjs.setStr(ctx, out, "style", str(ctx, "decimal"));
            _ = qjs.setStr(ctx, out, "minimumIntegerDigits", qjs.newInt(ctx, 1));
            _ = qjs.setStr(ctx, out, "minimumFractionDigits", qjs.newInt(ctx, 0));
            _ = qjs.setStr(ctx, out, "maximumFractionDigits", qjs.newInt(ctx, 3));
            _ = qjs.setStr(ctx, out, "useGrouping", str(ctx, "auto"));
            _ = qjs.setStr(ctx, out, "notation", str(ctx, "standard"));
            _ = qjs.setStr(ctx, out, "signDisplay", str(ctx, "auto"));
            _ = qjs.setStr(ctx, out, "roundingMode", str(ctx, "halfExpand"));
        },
        .plural_rules => {
            _ = qjs.setStr(ctx, out, "type", str(ctx, "cardinal"));
            const categories = qjs.newArray(ctx);
            var ordinal_buf: [16]u8 = undefined;
            const ordinal = if (optionOf(ctx, options, "type", &ordinal_buf)) |text| eql(text, "ordinal") else false;
            const names: []const []const u8 = if (ordinal) &.{ "few", "one", "two", "other" } else &.{ "one", "other" };
            for (names, 0..) |name, i| _ = qjs.setAt(ctx, categories, @intCast(i), str(ctx, name));
            _ = qjs.setStr(ctx, out, "pluralCategories", categories);
        },
        .collator => {
            _ = qjs.setStr(ctx, out, "usage", str(ctx, "sort"));
            _ = qjs.setStr(ctx, out, "sensitivity", str(ctx, "variant"));
            _ = qjs.setStr(ctx, out, "ignorePunctuation", qjs.newBool(ctx, 0));
            _ = qjs.setStr(ctx, out, "collation", str(ctx, "default"));
            _ = qjs.setStr(ctx, out, "numeric", qjs.newBool(ctx, 0));
            _ = qjs.setStr(ctx, out, "caseFirst", str(ctx, "false"));
        },
        .list_format => {
            _ = qjs.setStr(ctx, out, "type", str(ctx, "conjunction"));
            _ = qjs.setStr(ctx, out, "style", str(ctx, "long"));
        },
        .relative_time_format => {
            _ = qjs.setStr(ctx, out, "style", str(ctx, "long"));
            _ = qjs.setStr(ctx, out, "numeric", str(ctx, "always"));
            _ = qjs.setStr(ctx, out, "numberingSystem", str(ctx, "latn"));
        },
        .locale => {},
    }
    assign(ctx, out, options);
    return out;
}

/// The accessor `format` and `compare` are: a function bound to the
/// instance, so that `list.map(formatter.format)` formats with it, made
/// once and kept on the instance.
fn boundTo(comptime name: [*:0]const u8, comptime impl: qjs.Method) qjs.Getter {
    const S = struct {
        fn get(ctx: *Context, this: Value) callconv(.c) Value {
            const kept = qjs.getStr(ctx, this, "__bound");
            if (!qjs.isUndefined(kept)) return kept;
            qjs.free(ctx, kept);
            const plain = qjs.newFunction(ctx, name, 1, impl);
            defer qjs.free(ctx, plain);
            const bind = qjs.getStr(ctx, plain, "bind");
            defer qjs.free(ctx, bind);
            const tied = qjs.call(ctx, bind, plain, 1, &[_]Value{this});
            if (qjs.isException(tied)) return tied;
            _ = qjs.defineStr(ctx, this, "__bound", qjs.dup(ctx, tied), 0);
            return tied;
        }
    };
    return &S.get;
}

/// Where a format's pieces go: the words, and where a `formatToParts` call
/// asked for them, the parts, each an object with its type and its text.
const Sink = struct {
    w: std.Io.Writer,
    parts: ?Parts = null,

    const Parts = struct { ctx: *Context, list: Value, count: u32 = 0 };

    fn put(self: *Sink, kind: []const u8, words: []const u8) void {
        self.w.writeAll(words) catch {};
        if (self.parts) |*parts| {
            const ctx = parts.ctx;
            const part = qjs.newObject(ctx);
            _ = qjs.setStr(ctx, part, "type", str(ctx, kind));
            _ = qjs.setStr(ctx, part, "value", str(ctx, words));
            _ = qjs.setAt(ctx, parts.list, parts.count, part);
            parts.count += 1;
        }
    }

    fn text(self: *const Sink) []const u8 {
        return self.w.buffered();
    }
};

/// The most a formatted date, number or relative time comes to.
const FORMAT_MAX = 512;

/// What a format call gives back: its words, or its parts as a list.
fn finish(ctx: *Context, sink: *const Sink, parts: bool) Value {
    if (parts) return sink.parts.?.list;
    return str(ctx, sink.text());
}

fn sinkFor(ctx: *Context, buf: []u8, parts: bool) Sink {
    var sink: Sink = .{ .w = .fixed(buf) };
    if (parts) sink.parts = .{ .ctx = ctx, .list = qjs.newArray(ctx) };
    return sink;
}

// ---------------------------------------------------------------------------
// Numbers
// ---------------------------------------------------------------------------

const NumberKind = enum { decimal, percent, currency, unit };
const Grouping = enum { auto, always, min2, off };
const Sign = enum { auto, always, except_zero, negative, never };

/// How a number is to be written: the options `NumberFormat` takes, as
/// read from a script's object.
const NumberStyle = struct {
    style: NumberKind = .decimal,
    currency: [3]u8 = "USD".*,
    currency_code: bool = false,
    unit: [UNIT_MAX]u8 = undefined,
    unit_len: u8 = 0,
    min_integer: u8 = 1,
    min_fraction: ?u8 = null,
    max_fraction: ?u8 = null,
    max_significant: ?u8 = null,
    grouping: Grouping = .auto,
    compact: bool = false,
    sign: Sign = .auto,

    const UNIT_MAX = 24;

    fn unitName(self: *const NumberStyle) []const u8 {
        return self.unit[0..self.unit_len];
    }

    /// The places after the point a style writes where it was not told:
    /// three for a plain number, none for a percentage, the currency's own.
    fn places(self: NumberStyle) [2]u8 {
        const most: u8 = switch (self.style) {
            .decimal, .unit => 3,
            .percent => 0,
            .currency => if (eql(&self.currency, "JPY") or eql(&self.currency, "KRW")) 0 else 2,
        };
        const least: u8 = if (self.style == .currency) most else 0;
        var min = self.min_fraction orelse least;
        var max = self.max_fraction orelse @max(most, min);
        if (min > max) {
            if (self.min_fraction != null and self.max_fraction == null) max = min else min = max;
        }
        return .{ min, max };
    }
};

fn numberStyleOf(ctx: *Context, options: Value) NumberStyle {
    var style: NumberStyle = .{};
    var buf: [32]u8 = undefined;
    if (optionOf(ctx, options, "style", &buf)) |text| style.style = std.meta.stringToEnum(NumberKind, text) orelse .decimal;
    if (optionOf(ctx, options, "currency", &buf)) |text| {
        if (text.len == 3) for (text, 0..) |c, i| {
            style.currency[i] = std.ascii.toUpper(c);
        };
    }
    if (optionOf(ctx, options, "currencyDisplay", &buf)) |text| style.currency_code = eql(text, "code") or eql(text, "name");
    if (optionOf(ctx, options, "unit", &style.unit)) |text| style.unit_len = @intCast(text.len);
    if (optionCount(ctx, options, "minimumIntegerDigits")) |n| style.min_integer = @max(n, 1);
    if (optionCount(ctx, options, "minimumFractionDigits")) |n| style.min_fraction = n;
    if (optionCount(ctx, options, "maximumFractionDigits")) |n| style.max_fraction = n;
    if (optionCount(ctx, options, "maximumSignificantDigits")) |n| style.max_significant = @max(n, 1);
    if (optionOf(ctx, options, "useGrouping", &buf)) |text| {
        style.grouping = if (eql(text, "false")) .off else std.meta.stringToEnum(Grouping, text) orelse .auto;
    }
    if (optionOf(ctx, options, "notation", &buf)) |text| style.compact = eql(text, "compact");
    if (optionOf(ctx, options, "signDisplay", &buf)) |text| {
        style.sign = if (eql(text, "always")) .always else if (eql(text, "exceptZero")) .except_zero else if (eql(text, "negative")) .negative else if (eql(text, "never")) .never else .auto;
    }
    return style;
}

/// A number, written as the style says.
fn writeNumber(sink: *Sink, given: f64, style: NumberStyle) void {
    if (std.math.isNan(given)) {
        sink.put("nan", "NaN");
        return;
    }
    var n = given;
    if (style.style == .percent) n *= 100;
    const negative = n < 0 or (n == 0 and std.math.signbit(n));
    const zero = n == 0;
    switch (style.sign) {
        .auto => if (negative) sink.put("minusSign", "-"),
        .always => sink.put(if (negative) "minusSign" else "plusSign", if (negative) "-" else "+"),
        .except_zero => if (!zero) sink.put(if (negative) "minusSign" else "plusSign", if (negative) "-" else "+"),
        .negative => if (negative and !zero) sink.put("minusSign", "-"),
        .never => {},
    }
    if (style.style == .currency) {
        if (style.currency_code) {
            sink.put("currency", &style.currency);
            sink.put("literal", "\u{a0}");
        } else {
            const symbol = currencySymbol(&style.currency);
            sink.put("currency", symbol);
            if (eql(symbol, &style.currency)) sink.put("literal", "\u{a0}");
        }
    }
    var a = @abs(n);
    if (std.math.isInf(a)) {
        sink.put("infinity", "∞");
    } else {
        var suffix: ?[]const u8 = null;
        var places = style.places();
        if (style.compact and a >= 1000) {
            const shift: struct { f64, []const u8 } = if (a >= 1e12) .{ 1e12, "T" } else if (a >= 1e9) .{ 1e9, "B" } else if (a >= 1e6) .{ 1e6, "M" } else .{ 1e3, "K" };
            a /= shift[0];
            suffix = shift[1];
            if (style.max_fraction == null and style.max_significant == null) places = .{ 0, if (a < 10) 1 else 0 };
        }
        writeDigits(sink, a, style, places[0], places[1]);
        if (suffix) |s| sink.put("compact", s);
    }
    switch (style.style) {
        .percent => sink.put("percentSign", "%"),
        .unit => {
            sink.put("literal", " ");
            sink.put("unit", unitSymbol(style.unitName()));
        },
        else => {},
    }
}

/// The sign the currencies pages price in are written with; any other is
/// written as its code.
fn currencySymbol(code: []const u8) []const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "USD", "$" },
        .{ "EUR", "€" },
        .{ "GBP", "£" },
        .{ "JPY", "¥" },
        .{ "CNY", "CN¥" },
        .{ "INR", "₹" },
        .{ "KRW", "₩" },
        .{ "CAD", "CA$" },
        .{ "AUD", "A$" },
        .{ "BRL", "R$" },
        .{ "MXN", "MX$" },
        .{ "ILS", "₪" },
        .{ "NZD", "NZ$" },
        .{ "HKD", "HK$" },
        .{ "TWD", "NT$" },
        .{ "VND", "₫" },
        .{ "XAF", "FCFA" },
        .{ "PHP", "₱" },
    };
    for (table) |row| if (eql(row[0], code)) return row[1];
    return code;
}

/// The short form of the units pages measure in; any other is written as
/// named.
fn unitSymbol(name: []const u8) []const u8 {
    const table = [_]struct { []const u8, []const u8 }{
        .{ "kilometer", "km" },  .{ "meter", "m" },                 .{ "centimeter", "cm" },     .{ "millimeter", "mm" },
        .{ "mile", "mi" },       .{ "foot", "ft" },                 .{ "inch", "in" },           .{ "kilogram", "kg" },
        .{ "gram", "g" },        .{ "pound", "lb" },                .{ "ounce", "oz" },          .{ "liter", "L" },
        .{ "milliliter", "mL" }, .{ "gallon", "gal" },              .{ "byte", "byte" },         .{ "kilobyte", "kB" },
        .{ "megabyte", "MB" },   .{ "gigabyte", "GB" },             .{ "terabyte", "TB" },       .{ "bit", "bit" },
        .{ "kilobit", "kb" },    .{ "megabit", "Mb" },              .{ "second", "sec" },        .{ "minute", "min" },
        .{ "hour", "hr" },       .{ "day", "day" },                 .{ "week", "wk" },           .{ "month", "mth" },
        .{ "year", "yr" },       .{ "millisecond", "ms" },          .{ "percent", "%" },
        .{ "celsius", "°C" },
        .{ "fahrenheit", "°F" },
        .{ "degree", "deg" },    .{ "kilometer-per-hour", "km/h" }, .{ "mile-per-hour", "mph" }, .{ "liter-per-kilometer", "L/km" },
    };
    for (table) |row| if (eql(row[0], name)) return row[1];
    return name;
}

/// The most a double comes to written out in full: the largest has three
/// hundred and nine digits before the point, and the smallest three hundred
/// and twenty-three noughts after it before its own digits.
const DECIMAL_MAX = 360;

/// A number's digits after rounding: the whole part and the fraction.
const Digits = struct { whole: []const u8, fraction: []const u8 };

/// The digits of `a`, rounded to `places` after the point, or where
/// `significant` is given to that many digits in all. The rounding is std's:
/// half away from zero on the shortest decimal that reads back as `a`, which
/// is how the browsers round, so `1.005` to two places is `1.01` whatever
/// the binary value falls short of. Written in `out`, the whole part first.
fn digitsOf(a: f64, places: u8, significant: ?u8, out: *[DECIMAL_MAX]u8) Digits {
    if (significant) |wanted| return significantDigits(a, wanted, out);
    const text = std.fmt.bufPrint(out, "{d:.[1]}", .{ a, @as(usize, places) }) catch return .{ .whole = "0", .fraction = "" };
    const point = std.mem.indexOfScalar(u8, text, '.') orelse return .{ .whole = text, .fraction = "" };
    return .{ .whole = text[0..point], .fraction = text[point + 1 ..] };
}

/// `wanted` digits in all: std writes them in scientific form, one before
/// the point and the rest after it, and the exponent says where the point
/// goes among them.
fn significantDigits(a: f64, wanted: u8, out: *[DECIMAL_MAX]u8) Digits {
    var sci: [48]u8 = undefined;
    const text = std.fmt.bufPrint(&sci, "{e:.[1]}", .{ a, @as(usize, wanted - 1) }) catch return .{ .whole = "0", .fraction = "" };
    const e = std.mem.indexOfScalar(u8, text, 'e') orelse return .{ .whole = "0", .fraction = "" };
    const exponent = std.fmt.parseInt(i32, text[e + 1 ..], 10) catch 0;
    var digits: [PLACES_MAX + 2]u8 = undefined;
    var count: usize = 0;
    for (text[0..e]) |c| {
        if (c == '.') continue;
        digits[count] = c;
        count += 1;
    }
    // The point goes after `exponent + 1` digits: past the last, the whole
    // part is padded with noughts, and before the first, a lone nought has
    // noughts after the point before the digits.
    const at = exponent + 1;
    if (at <= 0) {
        const lead: usize = @intCast(-at);
        out[0] = '0';
        @memset(out[1 .. 1 + lead], '0');
        @memcpy(out[1 + lead .. 1 + lead + count], digits[0..count]);
        return .{ .whole = out[0..1], .fraction = out[1 .. 1 + lead + count] };
    }
    const whole_len: usize = @intCast(at);
    @memcpy(out[0..count], digits[0..count]);
    if (whole_len >= count) {
        @memset(out[count..whole_len], '0');
        return .{ .whole = out[0..whole_len], .fraction = "" };
    }
    return .{ .whole = out[0..whole_len], .fraction = out[whole_len..count] };
}

/// The digits of `a`, grouped and with the places asked for, into the sink.
fn writeDigits(sink: *Sink, a: f64, style: NumberStyle, min_places: u8, max_places: u8) void {
    var raw: [DECIMAL_MAX]u8 = undefined;
    const digits = digitsOf(a, max_places, style.max_significant, &raw);

    var padded: [DECIMAL_MAX + PLACES_MAX + 2]u8 = undefined;
    const pad: usize = if (digits.whole.len < style.min_integer) style.min_integer - digits.whole.len else 0;
    @memset(padded[0..pad], '0');
    @memcpy(padded[pad .. pad + digits.whole.len], digits.whole);
    const whole = padded[0 .. pad + digits.whole.len];
    const grouped = switch (style.grouping) {
        .off => false,
        .min2 => whole.len >= 5,
        .auto, .always => whole.len > 3,
    };
    if (!grouped) {
        sink.put("integer", whole);
    } else {
        const head = if (whole.len % 3 == 0) 3 else whole.len % 3;
        sink.put("integer", whole[0..head]);
        var from = head;
        while (from < whole.len) : (from += 3) {
            sink.put("group", ",");
            sink.put("integer", whole[from .. from + 3]);
        }
    }

    var keep = digits.fraction.len;
    while (keep > min_places and digits.fraction[keep - 1] == '0') keep -= 1;
    if (keep == 0 and min_places == 0) return;
    var fraction: [PLACES_MAX + DECIMAL_MAX]u8 = undefined;
    @memcpy(fraction[0..keep], digits.fraction[0..keep]);
    var len = keep;
    while (len < min_places) : (len += 1) fraction[len] = '0';
    sink.put("decimal", ".");
    sink.put("fraction", fraction[0..len]);
}

fn numberFormat(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value, parts: bool) Value {
    var n: f64 = std.math.nan(f64);
    if (argc > 0 and qjs.toFloat(ctx, &n, argv[0]) < 0) return qjs.exceptionValue();
    const options = optionsKept(ctx, this);
    defer qjs.free(ctx, options);
    var buf: [FORMAT_MAX]u8 = undefined;
    var sink = sinkFor(ctx, &buf, parts);
    writeNumber(&sink, n, numberStyleOf(ctx, options));
    return finish(ctx, &sink, parts);
}

fn jsNumberFormat(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return numberFormat(ctx, this, argc, argv, false);
}

fn jsNumberFormatToParts(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return numberFormat(ctx, this, argc, argv, true);
}

/// `Number.prototype.toLocaleString`: the number, written as a
/// `NumberFormat` with the same locale and options writes it.
fn jsNumberToLocaleString(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    var n: f64 = undefined;
    if (qjs.toFloat(ctx, &n, this) < 0) return qjs.exceptionValue();
    const options = if (argc > 1) argv[1] else qjs.undefinedValue();
    var buf: [FORMAT_MAX]u8 = undefined;
    var sink = sinkFor(ctx, &buf, false);
    writeNumber(&sink, n, numberStyleOf(ctx, options));
    return finish(ctx, &sink, false);
}

const number_methods = [_]qjs.ListEntry{
    .accessor("format", boundTo("format", &jsNumberFormat), null),
    .method("formatToParts", 1, &jsNumberFormatToParts),
    .method("resolvedOptions", 0, resolvedOptions(.number_format)),
};

// ---------------------------------------------------------------------------
// Dates and times
// ---------------------------------------------------------------------------

const Width = enum { long, short, narrow };
const Places = enum { numeric, @"2-digit" };
const MonthForm = enum { numeric, @"2-digit", long, short, narrow };
const StyleWidth = enum { full, long, medium, short };

/// Which parts a caller must have, and which it gets where it names none:
/// `toLocaleDateString` wants a date and gets one, `toLocaleTimeString` the
/// time, `DateTimeFormat` either and gets the date, `toLocaleString` either
/// and gets both.
const Need = enum { any, date, time, all };

/// How a date is to be written: the options `DateTimeFormat` takes, each
/// part with its form where it is shown at all.
const DateStyle = struct {
    date_style: ?StyleWidth = null,
    time_style: ?StyleWidth = null,
    weekday: ?Width = null,
    year: ?Places = null,
    month: ?MonthForm = null,
    day: ?Places = null,
    hour: ?Places = null,
    minute: ?Places = null,
    second: ?Places = null,
    zone: ?Width = null,
    /// The clock runs to twenty-four: `hour12: false`, or an hour cycle
    /// that says so.
    h23: bool = false,
    /// No part was named, so the defaults stand.
    defaulted: bool = false,

    fn hasDate(self: DateStyle) bool {
        return self.weekday != null or self.year != null or self.month != null or self.day != null;
    }

    fn hasTime(self: DateStyle) bool {
        return self.hour != null or self.minute != null or self.second != null;
    }

    /// The month is written out in full, after which the time follows
    /// with `at` rather than a comma.
    fn longMonth(self: DateStyle) bool {
        return if (self.month) |m| m == .long else false;
    }
};

fn dateStyleOf(ctx: *Context, options: Value, required: Need, defaults: Need) DateStyle {
    var style: DateStyle = .{};
    var buf: [32]u8 = undefined;
    if (optionOf(ctx, options, "dateStyle", &buf)) |text| style.date_style = std.meta.stringToEnum(StyleWidth, text);
    if (optionOf(ctx, options, "timeStyle", &buf)) |text| style.time_style = std.meta.stringToEnum(StyleWidth, text);
    if (style.date_style) |width| switch (width) {
        .full => {
            style.weekday = .long;
            style.month = .long;
            style.day = .numeric;
            style.year = .numeric;
        },
        .long => {
            style.month = .long;
            style.day = .numeric;
            style.year = .numeric;
        },
        .medium => {
            style.month = .short;
            style.day = .numeric;
            style.year = .numeric;
        },
        .short => {
            style.month = .numeric;
            style.day = .numeric;
            style.year = .@"2-digit";
        },
    };
    if (style.time_style) |width| {
        style.hour = .numeric;
        style.minute = .@"2-digit";
        if (width != .short) style.second = .@"2-digit";
        if (width == .long) style.zone = .short;
        if (width == .full) style.zone = .long;
    }
    if (style.date_style == null and style.time_style == null) {
        if (optionOf(ctx, options, "weekday", &buf)) |text| style.weekday = std.meta.stringToEnum(Width, text);
        if (optionOf(ctx, options, "year", &buf)) |text| style.year = std.meta.stringToEnum(Places, text);
        if (optionOf(ctx, options, "month", &buf)) |text| style.month = std.meta.stringToEnum(MonthForm, text);
        if (optionOf(ctx, options, "day", &buf)) |text| style.day = std.meta.stringToEnum(Places, text);
        if (optionOf(ctx, options, "hour", &buf)) |text| style.hour = std.meta.stringToEnum(Places, text);
        if (optionOf(ctx, options, "minute", &buf)) |text| style.minute = std.meta.stringToEnum(Places, text);
        if (optionOf(ctx, options, "second", &buf)) |text| style.second = std.meta.stringToEnum(Places, text);
        if (optionOf(ctx, options, "timeZoneName", &buf)) |text| style.zone = std.meta.stringToEnum(Width, text) orelse .short;
        const missing = switch (required) {
            .date => !style.hasDate(),
            .time => !style.hasTime(),
            else => !style.hasDate() and !style.hasTime(),
        };
        if (missing) {
            style.defaulted = true;
            if (defaults == .date or defaults == .all) {
                style.year = .numeric;
                style.month = .numeric;
                style.day = .numeric;
            }
            if (defaults == .time or defaults == .all) {
                style.hour = .numeric;
                style.minute = .numeric;
                style.second = .numeric;
            }
        }
    }
    if (optionOf(ctx, options, "hour12", &buf)) |text| style.h23 = eql(text, "false");
    if (optionOf(ctx, options, "hourCycle", &buf)) |text| {
        if (eql(text, "h23") or eql(text, "h24")) style.h23 = true;
    }
    return style;
}

/// A moment taken apart on the civil calendar, in UTC.
const Moment = struct {
    year: i32,
    month: u8,
    day: u8,
    /// Nought on Sunday.
    weekday: u3,
    hour: u8,
    minute: u8,
    second: u8,
};

const MS_PER_DAY: f64 = 86_400_000;

/// The most a time value may be, either way, as the language bounds it.
const TIME_MAX = 8.64e15;

/// The moment of a time value: the days are split off in floating point,
/// which the value comes in and which needs no wide integer arithmetic,
/// the library's calendar does the days, and what is left over is the time
/// of day.
fn momentOf(ms: f64) Moment {
    const day_count = @floor(ms / MS_PER_DAY);
    const days: i32 = @intFromFloat(day_count);
    const seconds: u32 = @intFromFloat(@floor((ms - day_count * MS_PER_DAY) / std.time.ms_per_s));
    const date = civil.civilFromDays(days);
    return .{
        .year = date.year,
        .month = date.month,
        .day = date.day,
        .weekday = civil.weekdayFromDays(days),
        .hour = @intCast(seconds / 3600),
        .minute = @intCast(seconds % 3600 / 60),
        .second = @intCast(seconds % 60),
    };
}

fn nameOf(names: []const []const u8, index: usize, width: Width) []const u8 {
    const name = names[index];
    return switch (width) {
        .long => name,
        .short => name[0..3],
        .narrow => name[0..1],
    };
}

/// A count as a date writes it: as it is, or to two digits.
fn countText(buf: *[24]u8, n: i32, places: Places) []const u8 {
    return switch (places) {
        .numeric => std.fmt.bufPrint(buf, "{d}", .{n}) catch "",
        .@"2-digit" => std.fmt.bufPrint(buf, "{d:0>2}", .{@as(u32, @intCast(@mod(n, 100)))}) catch "",
    };
}

/// A date, written as the style says.
fn writeDate(sink: *Sink, ms: f64, style: DateStyle) void {
    const c = momentOf(ms);
    const has_date = style.hasDate();
    const has_time = style.hasTime();
    if (has_date) writeDateParts(sink, c, style);
    if (has_date and has_time) sink.put("literal", if (style.longMonth()) " at " else ", ");
    if (has_time) writeTimeParts(sink, c, style);
    if (style.zone) |zone| {
        sink.put("literal", " ");
        sink.put("timeZoneName", if (zone == .long) "Coordinated Universal Time" else TIME_ZONE);
    }
}

/// The date's parts as English orders them: the weekday first with a comma
/// after it, a named month before its day and the year after a comma, a
/// numbered month, day and year with slashes between. A time follows a
/// month written in full with `at`, and anything else with a comma.
fn writeDateParts(sink: *Sink, c: Moment, style: DateStyle) void {
    var day_buf: [24]u8 = undefined;
    var year_buf: [24]u8 = undefined;
    var month_buf: [24]u8 = undefined;
    const day: ?[]const u8 = if (style.day) |places| countText(&day_buf, c.day, places) else null;
    const year: ?[]const u8 = if (style.year) |places| countText(&year_buf, c.year, places) else null;
    if (style.weekday) |width| {
        sink.put("weekday", nameOf(&civil.DAY_NAMES_FULL, c.weekday, width));
        if (style.month != null or day != null or year != null) sink.put("literal", ", ");
    }
    if (style.month) |form| switch (form) {
        .numeric, .@"2-digit" => {
            sink.put("month", countText(&month_buf, c.month, if (form == .@"2-digit") .@"2-digit" else .numeric));
            if (day) |d| {
                sink.put("literal", "/");
                sink.put("day", d);
            }
            if (year) |y| {
                sink.put("literal", "/");
                sink.put("year", y);
            }
        },
        .long, .short, .narrow => {
            sink.put("month", nameOf(&civil.MONTH_NAMES_FULL, c.month - 1, switch (form) {
                .long => .long,
                .short => .short,
                else => .narrow,
            }));
            if (day) |d| {
                sink.put("literal", " ");
                sink.put("day", d);
            }
            if (year) |y| {
                sink.put("literal", if (day != null) ", " else " ");
                sink.put("year", y);
            }
        },
    } else {
        if (day) |d| sink.put("day", d);
        if (year) |y| {
            if (day != null) sink.put("literal", " ");
            sink.put("year", y);
        }
    }
}

/// The time's parts: the hour on a twelve-hour clock with its period after
/// unless the style says twenty-four, minutes and seconds to two digits
/// after a colon.
fn writeTimeParts(sink: *Sink, c: Moment, style: DateStyle) void {
    var hour_buf: [24]u8 = undefined;
    var minute_buf: [24]u8 = undefined;
    var second_buf: [24]u8 = undefined;
    var wrote = false;
    if (style.hour) |places| {
        const shown: i32 = if (style.h23) c.hour else if (c.hour % 12 == 0) 12 else c.hour % 12;
        sink.put("hour", countText(&hour_buf, shown, if (style.h23 or places == .@"2-digit") .@"2-digit" else .numeric));
        wrote = true;
    }
    if (style.minute) |places| {
        if (wrote) sink.put("literal", ":");
        sink.put("minute", countText(&minute_buf, c.minute, if (wrote or places == .@"2-digit") .@"2-digit" else .numeric));
        wrote = true;
    }
    if (style.second) |places| {
        if (wrote) sink.put("literal", ":");
        sink.put("second", countText(&second_buf, c.second, if (wrote or places == .@"2-digit") .@"2-digit" else .numeric));
    }
    if (style.hour != null and !style.h23) {
        sink.put("literal", " ");
        sink.put("dayPeriod", if (c.hour < 12) "AM" else "PM");
    }
}

/// `Date.now()`, for a format asked for no date.
fn now(ctx: *Context) f64 {
    const global = qjs.globalOf(ctx);
    defer qjs.free(ctx, global);
    const date = qjs.getStr(ctx, global, "Date");
    defer qjs.free(ctx, date);
    const method = qjs.getStr(ctx, date, "now");
    defer qjs.free(ctx, method);
    const told = qjs.call(ctx, method, date, 0, null);
    defer qjs.free(ctx, told);
    var t: f64 = 0;
    _ = qjs.toFloat(ctx, &t, told);
    return t;
}

/// The time value an argument gives: a `Date` reads as its own, a number as
/// itself, nothing as now. Not a number, or past what a date holds, is an
/// exception.
fn timeOf(ctx: *Context, argc: c_int, argv: [*]const Value, index: usize) ?f64 {
    if (index >= @as(usize, @intCast(argc)) or qjs.isUndefined(argv[index])) return now(ctx);
    var t: f64 = undefined;
    if (qjs.toFloat(ctx, &t, argv[index]) < 0) return null;
    if (std.math.isNan(t) or @abs(t) > TIME_MAX) {
        _ = qjs.throwRange(ctx, "Invalid time value");
        return null;
    }
    return t;
}

fn dateFormat(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value, parts: bool) Value {
    const t = timeOf(ctx, argc, argv, 0) orelse return qjs.exceptionValue();
    const options = optionsKept(ctx, this);
    defer qjs.free(ctx, options);
    var buf: [FORMAT_MAX]u8 = undefined;
    var sink = sinkFor(ctx, &buf, parts);
    writeDate(&sink, t, dateStyleOf(ctx, options, .any, .date));
    return finish(ctx, &sink, parts);
}

fn jsDateFormat(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return dateFormat(ctx, this, argc, argv, false);
}

fn jsDateFormatToParts(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return dateFormat(ctx, this, argc, argv, true);
}

/// `formatRange`: the two dates, with a dash between.
fn jsDateFormatRange(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const from = timeOf(ctx, argc, argv, 0) orelse return qjs.exceptionValue();
    const to = timeOf(ctx, argc, argv, 1) orelse return qjs.exceptionValue();
    const options = optionsKept(ctx, this);
    defer qjs.free(ctx, options);
    const style = dateStyleOf(ctx, options, .any, .date);
    var buf: [FORMAT_MAX]u8 = undefined;
    var sink = sinkFor(ctx, &buf, false);
    writeDate(&sink, from, style);
    sink.put("literal", " – ");
    writeDate(&sink, to, style);
    return finish(ctx, &sink, false);
}

/// `Date.prototype.toLocaleString` and its date and time halves: the date,
/// written as a `DateTimeFormat` with the same options writes it, with the
/// parts each call wants where none were named. An invalid date reads as
/// the words for one rather than an exception, as those calls do.
fn dateToLocale(comptime required: Need, comptime defaults: Need) qjs.Method {
    const S = struct {
        fn call(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
            var t: f64 = undefined;
            if (qjs.toFloat(ctx, &t, this) < 0) return qjs.exceptionValue();
            if (std.math.isNan(t) or @abs(t) > TIME_MAX) return str(ctx, "Invalid Date");
            const options = if (argc > 1) argv[1] else qjs.undefinedValue();
            var buf: [FORMAT_MAX]u8 = undefined;
            var sink = sinkFor(ctx, &buf, false);
            writeDate(&sink, t, dateStyleOf(ctx, options, required, defaults));
            return finish(ctx, &sink, false);
        }
    };
    return &S.call;
}

const date_methods = [_]qjs.ListEntry{
    .accessor("format", boundTo("format", &jsDateFormat), null),
    .method("formatToParts", 1, &jsDateFormatToParts),
    .method("formatRange", 2, &jsDateFormatRange),
    .method("resolvedOptions", 0, resolvedOptions(.date_time_format)),
};

// ---------------------------------------------------------------------------
// Plural rules
// ---------------------------------------------------------------------------

/// The plural category of `n` in English: one for one alone, and for the
/// ordinals, first, second and third, twenty-first and so on, but not the
/// teens.
fn pluralOf(n: f64, ordinal: bool) []const u8 {
    if (!ordinal) return if (n == 1) "one" else "other";
    if (n != @floor(n) or std.math.isInf(n)) return "other";
    // Only the last two digits say which: taken in floating point, where a
    // count past the integers still has them.
    const teens: u8 = @intFromFloat(@mod(@abs(n), 100));
    const ones = teens % 10;
    if (ones == 1 and teens != 11) return "one";
    if (ones == 2 and teens != 12) return "two";
    if (ones == 3 and teens != 13) return "few";
    return "other";
}

fn jsPluralSelect(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    var n: f64 = std.math.nan(f64);
    if (argc > 0 and qjs.toFloat(ctx, &n, argv[0]) < 0) return qjs.exceptionValue();
    const options = optionsKept(ctx, this);
    defer qjs.free(ctx, options);
    var buf: [16]u8 = undefined;
    const ordinal = if (optionOf(ctx, options, "type", &buf)) |text| eql(text, "ordinal") else false;
    return str(ctx, pluralOf(n, ordinal));
}

const plural_methods = [_]qjs.ListEntry{
    .method("select", 1, &jsPluralSelect),
    .method("resolvedOptions", 0, resolvedOptions(.plural_rules)),
};

// ---------------------------------------------------------------------------
// Collation
// ---------------------------------------------------------------------------

/// How two strings are to be ordered: the options `Collator` takes.
const Collation = struct {
    /// Whether a difference in case alone orders them.
    cased: bool = true,
    /// Runs of digits order by their value.
    numeric: bool = false,
    ignore_punctuation: bool = false,
};

fn collationOf(ctx: *Context, options: Value) Collation {
    var how: Collation = .{};
    var buf: [16]u8 = undefined;
    if (optionOf(ctx, options, "sensitivity", &buf)) |text| how.cased = eql(text, "variant") or eql(text, "case");
    if (optionOf(ctx, options, "numeric", &buf)) |text| how.numeric = eql(text, "true");
    if (optionOf(ctx, options, "ignorePunctuation", &buf)) |text| how.ignore_punctuation = eql(text, "true");
    return how;
}

/// The order of `a` and `b`, as a sort wants it: letters compare without
/// their case first, and only two strings the same but for case are ordered
/// by it, the lower case first, as the dictionaries order them.
fn collate(a: []const u8, b: []const u8, how: Collation) i32 {
    var i: usize = 0;
    var j: usize = 0;
    // The first difference in case alone, kept for the tie.
    var by_case: i32 = 0;
    while (true) {
        if (how.ignore_punctuation) {
            while (i < a.len and ignorable(a[i])) i += 1;
            while (j < b.len and ignorable(b[j])) j += 1;
        }
        if (i == a.len or j == b.len) {
            if (i < a.len) return 1;
            if (j < b.len) return -1;
            break;
        }
        if (how.numeric and std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const run_a = digitRun(a, i);
            const run_b = digitRun(b, j);
            const order = numericOrder(run_a, run_b);
            if (order != 0) return order;
            i += run_a.len;
            j += run_b.len;
            continue;
        }
        const x = std.ascii.toLower(a[i]);
        const y = std.ascii.toLower(b[j]);
        if (x != y) return if (x < y) -1 else 1;
        if (by_case == 0 and a[i] != b[j]) by_case = if (std.ascii.isLower(a[i])) -1 else 1;
        i += 1;
        j += 1;
    }
    return if (how.cased) by_case else 0;
}

/// What a collation told to ignore punctuation passes over: the punctuation,
/// and the spaces with it.
fn ignorable(c: u8) bool {
    return std.ascii.isPunctuation(c) or std.ascii.isWhitespace(c);
}

fn digitRun(text: []const u8, from: usize) []const u8 {
    const end = std.mem.findNonePos(u8, text, from, "0123456789") orelse text.len;
    return text[from..end];
}

/// Two runs of digits by value: the longer once its noughts are off is the
/// greater, and equal lengths compare digit by digit.
fn numericOrder(a: []const u8, b: []const u8) i32 {
    const x = std.mem.trimStart(u8, a, "0");
    const y = std.mem.trimStart(u8, b, "0");
    if (x.len != y.len) return if (x.len < y.len) -1 else 1;
    return switch (std.mem.order(u8, x, y)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

fn jsCollatorCompare(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    const a = if (argc > 0) qjs.sliceOf(ctx, argv[0]) orelse "" else "";
    defer if (a.len > 0) qjs.freeText(ctx, a.ptr);
    const b = if (argc > 1) qjs.sliceOf(ctx, argv[1]) orelse "" else "";
    defer if (b.len > 0) qjs.freeText(ctx, b.ptr);
    const options = optionsKept(ctx, this);
    defer qjs.free(ctx, options);
    return qjs.newInt(ctx, collate(a, b, collationOf(ctx, options)));
}

const collator_methods = [_]qjs.ListEntry{
    .accessor("compare", boundTo("compare", &jsCollatorCompare), null),
    .method("resolvedOptions", 0, resolvedOptions(.collator)),
};

// ---------------------------------------------------------------------------
// Lists
// ---------------------------------------------------------------------------

const ListKind = enum { conjunction, disjunction, unit };

/// What goes between the `index`th item of `count` and the one before it.
fn listJoiner(index: usize, count: usize, kind: ListKind, width: Width) []const u8 {
    const last = index == count - 1;
    if (kind == .unit) return if (width == .narrow) " " else ", ";
    if (!last) return ", ";
    return switch (kind) {
        .conjunction => switch (width) {
            .long => if (count == 2) " and " else ", and ",
            .short => if (count == 2) " & " else ", & ",
            .narrow => ", ",
        },
        .disjunction => if (count == 2) " or " else ", or ",
        .unit => unreachable,
    };
}

fn listFormat(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value, parts: bool) Value {
    const options = optionsKept(ctx, this);
    defer qjs.free(ctx, options);
    var buf: [16]u8 = undefined;
    const kind = if (optionOf(ctx, options, "type", &buf)) |text| std.meta.stringToEnum(ListKind, text) orelse .conjunction else .conjunction;
    const width = if (optionOf(ctx, options, "style", &buf)) |text| std.meta.stringToEnum(Width, text) orelse .long else .long;

    var count: usize = 0;
    var total: usize = 0;
    const list = if (argc > 0) argv[0] else qjs.undefinedValue();
    if (qjs.isObject(list)) {
        var length: i32 = 0;
        const got = qjs.getStr(ctx, list, "length");
        defer qjs.free(ctx, got);
        _ = qjs.toInt(ctx, &length, got);
        count = @intCast(@max(length, 0));
        var index: u32 = 0;
        while (index < count) : (index += 1) {
            const item = qjs.getAt(ctx, list, index);
            defer qjs.free(ctx, item);
            const text = qjs.sliceOf(ctx, item) orelse continue;
            defer qjs.freeText(ctx, text.ptr);
            total += text.len;
        }
    }
    // Room for every item and the longest joiner between each pair.
    const room = total + count * JOINER_MAX + 1;
    const held: [*]u8 = @ptrCast(qjs.alloc(ctx, room) orelse return qjs.throwOutOfMemory(ctx));
    defer qjs.release(ctx, held);
    var sink = sinkFor(ctx, held[0..room], parts);
    var index: u32 = 0;
    while (index < count) : (index += 1) {
        const item = qjs.getAt(ctx, list, index);
        defer qjs.free(ctx, item);
        const text = qjs.sliceOf(ctx, item) orelse "";
        defer if (text.len > 0) qjs.freeText(ctx, text.ptr);
        if (index > 0) sink.put("literal", listJoiner(index, count, kind, width));
        sink.put("element", text);
    }
    return finish(ctx, &sink, parts);
}

/// The longest thing a list puts between two items.
const JOINER_MAX = 6;

fn jsListFormat(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return listFormat(ctx, this, argc, argv, false);
}

fn jsListFormatToParts(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return listFormat(ctx, this, argc, argv, true);
}

const list_methods = [_]qjs.ListEntry{
    .method("format", 1, &jsListFormat),
    .method("formatToParts", 1, &jsListFormatToParts),
    .method("resolvedOptions", 0, resolvedOptions(.list_format)),
};

// ---------------------------------------------------------------------------
// Relative times
// ---------------------------------------------------------------------------

const Unit = enum { second, minute, hour, day, week, month, quarter, year };

/// The unit a name gives, singular or plural.
fn unitOf(text: []const u8) ?Unit {
    const name = if (text.len > 1 and text[text.len - 1] == 's') text[0 .. text.len - 1] else text;
    return std.meta.stringToEnum(Unit, name);
}

/// The unit's word, for one or for many, at the width asked.
fn unitWord(unit: Unit, one: bool, width: Width) []const u8 {
    if (width == .long) return switch (unit) {
        .second => if (one) "second" else "seconds",
        .minute => if (one) "minute" else "minutes",
        .hour => if (one) "hour" else "hours",
        .day => if (one) "day" else "days",
        .week => if (one) "week" else "weeks",
        .month => if (one) "month" else "months",
        .quarter => if (one) "quarter" else "quarters",
        .year => if (one) "year" else "years",
    };
    return switch (unit) {
        .second => "sec.",
        .minute => "min.",
        .hour => "hr.",
        .day => if (one) "day" else "days",
        .week => "wk.",
        .month => "mo.",
        .quarter => if (one) "qtr." else "qtrs.",
        .year => "yr.",
    };
}

/// The word for a unit's neighbours, where the format may say them: today
/// and its neighbours, and last, this and next for the longer units. Nothing
/// for the units that are always counted.
fn nearWord(unit: Unit, value: f64) ?[]const u8 {
    if (value == 0) return switch (unit) {
        .second => "now",
        .minute => "this minute",
        .hour => "this hour",
        .day => "today",
        .week => "this week",
        .month => "this month",
        .quarter => "this quarter",
        .year => "this year",
    };
    if (value == 1) return switch (unit) {
        .day => "tomorrow",
        .week => "next week",
        .month => "next month",
        .quarter => "next quarter",
        .year => "next year",
        else => null,
    };
    if (value == -1) return switch (unit) {
        .day => "yesterday",
        .week => "last week",
        .month => "last month",
        .quarter => "last quarter",
        .year => "last year",
        else => null,
    };
    return null;
}

/// A relative time, written as the style says: `in` before what is to come
/// and `ago` after what has been, or the near word where the format may use
/// one.
fn writeRelative(sink: *Sink, value: f64, unit: Unit, auto: bool, width: Width) void {
    if (auto) {
        if (nearWord(unit, value)) |word| {
            sink.put("literal", word);
            return;
        }
    }
    const negative = value < 0 or (value == 0 and std.math.signbit(value));
    const a = @abs(value);
    if (!negative) sink.put("literal", "in ");
    writeDigits(sink, a, .{}, 0, 3);
    sink.put("literal", " ");
    sink.put("literal", unitWord(unit, a == 1, width));
    if (negative) sink.put("literal", " ago");
}

fn relativeFormat(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value, parts: bool) Value {
    var value: f64 = std.math.nan(f64);
    if (argc > 0 and qjs.toFloat(ctx, &value, argv[0]) < 0) return qjs.exceptionValue();
    if (std.math.isNan(value)) return qjs.throwRange(ctx, "Value need to be finite number for Intl.RelativeTimeFormat.prototype.format()");
    const name = if (argc > 1) qjs.sliceOf(ctx, argv[1]) orelse "" else "";
    defer if (name.len > 0) qjs.freeText(ctx, name.ptr);
    const unit = unitOf(name) orelse return qjs.throwRange(ctx, "Invalid unit argument for format()");
    const options = optionsKept(ctx, this);
    defer qjs.free(ctx, options);
    var buf: [16]u8 = undefined;
    const auto = if (optionOf(ctx, options, "numeric", &buf)) |text| eql(text, "auto") else false;
    const width = if (optionOf(ctx, options, "style", &buf)) |text| std.meta.stringToEnum(Width, text) orelse .long else .long;
    var out: [FORMAT_MAX]u8 = undefined;
    var sink = sinkFor(ctx, &out, parts);
    writeRelative(&sink, value, unit, auto, width);
    return finish(ctx, &sink, parts);
}

fn jsRelativeFormat(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return relativeFormat(ctx, this, argc, argv, false);
}

fn jsRelativeFormatToParts(ctx: *Context, this: Value, argc: c_int, argv: [*]const Value) callconv(.c) Value {
    return relativeFormat(ctx, this, argc, argv, true);
}

const relative_methods = [_]qjs.ListEntry{
    .method("format", 2, &jsRelativeFormat),
    .method("formatToParts", 2, &jsRelativeFormatToParts),
    .method("resolvedOptions", 0, resolvedOptions(.relative_time_format)),
};

// ---------------------------------------------------------------------------
// Locales
// ---------------------------------------------------------------------------

/// The parts of a `Locale` a script reads, each by the number the getter is
/// told.
const LocalePart = enum(i16) { language, script, region, base_name, calendar, numbering_system, hour_cycle, case_first, numeric };

fn jsLocaleGet(ctx: *Context, this: Value, magic: c_int) callconv(.c) Value {
    const part: LocalePart = @enumFromInt(magic);
    const kept = localeKept(ctx, this);
    defer qjs.free(ctx, kept);
    const text = qjs.sliceOf(ctx, kept) orelse return qjs.undefinedValue();
    defer qjs.freeText(ctx, text.ptr);
    const tag = Tag.parse(text) orelse return qjs.undefinedValue();
    switch (part) {
        .language => return str(ctx, tag.language),
        .script => return if (tag.script) |script| str(ctx, script) else qjs.undefinedValue(),
        .region => return if (tag.region) |region| str(ctx, region) else qjs.undefinedValue(),
        .base_name => {
            var buf: [TAG_MAX]u8 = undefined;
            var w: std.Io.Writer = .fixed(&buf);
            tag.writeBase(&w);
            return str(ctx, w.buffered());
        },
        .numeric => {
            const options = optionsKept(ctx, this);
            defer qjs.free(ctx, options);
            var buf: [8]u8 = undefined;
            const yes = if (optionOf(ctx, options, "numeric", &buf)) |value| eql(value, "true") else false;
            return qjs.newBool(ctx, @intFromBool(yes));
        },
        .calendar, .numbering_system, .hour_cycle, .case_first => {
            const options = optionsKept(ctx, this);
            defer qjs.free(ctx, options);
            if (!qjs.isObject(options)) return qjs.undefinedValue();
            return qjs.getStr(ctx, options, switch (part) {
                .calendar => "calendar",
                .numbering_system => "numberingSystem",
                .hour_cycle => "hourCycle",
                else => "caseFirst",
            });
        },
    }
}

fn jsLocaleToString(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    return localeKept(ctx, this);
}

/// `maximize` and `minimize`: a `Locale` with the same tag, there being no
/// table of likely subtags to add or take away.
fn jsLocaleSame(ctx: *Context, this: Value, _: c_int, _: [*]const Value) callconv(.c) Value {
    const kept = localeKept(ctx, this);
    defer qjs.free(ctx, kept);
    const options = optionsKept(ctx, this);
    defer qjs.free(ctx, options);
    return construct(ctx, qjs.undefinedValue(), 2, &[_]Value{ kept, options }, .locale);
}

const locale_methods = [_]qjs.ListEntry{
    .accessorMagic("language", &jsLocaleGet, null, @intFromEnum(LocalePart.language)),
    .accessorMagic("script", &jsLocaleGet, null, @intFromEnum(LocalePart.script)),
    .accessorMagic("region", &jsLocaleGet, null, @intFromEnum(LocalePart.region)),
    .accessorMagic("baseName", &jsLocaleGet, null, @intFromEnum(LocalePart.base_name)),
    .accessorMagic("calendar", &jsLocaleGet, null, @intFromEnum(LocalePart.calendar)),
    .accessorMagic("numberingSystem", &jsLocaleGet, null, @intFromEnum(LocalePart.numbering_system)),
    .accessorMagic("hourCycle", &jsLocaleGet, null, @intFromEnum(LocalePart.hour_cycle)),
    .accessorMagic("caseFirst", &jsLocaleGet, null, @intFromEnum(LocalePart.case_first)),
    .accessorMagic("numeric", &jsLocaleGet, null, @intFromEnum(LocalePart.numeric)),
    .method("toString", 0, &jsLocaleToString),
    .method("toJSON", 0, &jsLocaleToString),
    .method("maximize", 0, &jsLocaleSame),
    .method("minimize", 0, &jsLocaleSame),
};

// ---------------------------------------------------------------------------
// Tests: the formats on their own, without an engine
// ---------------------------------------------------------------------------

const testing = std.testing;

fn formatted(buf: []u8, comptime write: anytype, args: anytype) []const u8 {
    var sink: Sink = .{ .w = .fixed(buf) };
    @call(.auto, write, .{&sink} ++ args);
    return sink.text();
}

test "numbers group their thousands, round half away from zero on the decimal, and keep the places asked" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1,234,567.891", formatted(&buf, writeNumber, .{ 1234567.891, NumberStyle{} }));
    try testing.expectEqualStrings("1.01", formatted(&buf, writeNumber, .{ 1.005, NumberStyle{ .max_fraction = 2 } }));
    try testing.expectEqualStrings("2.5", formatted(&buf, writeNumber, .{ 2.5, NumberStyle{} }));
    try testing.expectEqualStrings("3", formatted(&buf, writeNumber, .{ 2.5, NumberStyle{ .max_fraction = 0 } }));
    try testing.expectEqualStrings("0.333", formatted(&buf, writeNumber, .{ 1.0 / 3.0, NumberStyle{} }));
    try testing.expectEqualStrings("1,000", formatted(&buf, writeNumber, .{ 999.9996, NumberStyle{} }));
    try testing.expectEqualStrings("-12.50", formatted(&buf, writeNumber, .{ -12.5, NumberStyle{ .min_fraction = 2 } }));
    try testing.expectEqualStrings("007", formatted(&buf, writeNumber, .{ 7, NumberStyle{ .min_integer = 3 } }));
    try testing.expectEqualStrings("1234", formatted(&buf, writeNumber, .{ 1234, NumberStyle{ .grouping = .off } }));
    try testing.expectEqualStrings("1234", formatted(&buf, writeNumber, .{ 1234, NumberStyle{ .grouping = .min2 } }));
    try testing.expectEqualStrings("12,345", formatted(&buf, writeNumber, .{ 12345, NumberStyle{ .grouping = .min2 } }));
    try testing.expectEqualStrings("0", formatted(&buf, writeNumber, .{ 0, NumberStyle{} }));
    try testing.expectEqualStrings("NaN", formatted(&buf, writeNumber, .{ std.math.nan(f64), NumberStyle{} }));
    try testing.expectEqualStrings("∞", formatted(&buf, writeNumber, .{ std.math.inf(f64), NumberStyle{} }));
    try testing.expectEqualStrings("+5", formatted(&buf, writeNumber, .{ 5, NumberStyle{ .sign = .always } }));
    try testing.expectEqualStrings("0", formatted(&buf, writeNumber, .{ 0, NumberStyle{ .sign = .except_zero } }));
}

test "numbers as percentages, currencies, units, to significant digits and in compact form" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("12%", formatted(&buf, writeNumber, .{ 0.12, NumberStyle{ .style = .percent } }));
    try testing.expectEqualStrings("12.5%", formatted(&buf, writeNumber, .{ 0.125, NumberStyle{ .style = .percent, .max_fraction = 1 } }));
    try testing.expectEqualStrings("$1,234.50", formatted(&buf, writeNumber, .{ 1234.5, NumberStyle{ .style = .currency } }));
    try testing.expectEqualStrings("€9.99", formatted(&buf, writeNumber, .{ 9.99, NumberStyle{ .style = .currency, .currency = "EUR".* } }));
    try testing.expectEqualStrings("¥1,200", formatted(&buf, writeNumber, .{ 1200, NumberStyle{ .style = .currency, .currency = "JPY".* } }));
    try testing.expectEqualStrings("CHF\u{a0}5.00", formatted(&buf, writeNumber, .{ 5, NumberStyle{ .style = .currency, .currency = "CHF".* } }));
    try testing.expectEqualStrings("USD\u{a0}5.00", formatted(&buf, writeNumber, .{ 5, NumberStyle{ .style = .currency, .currency_code = true } }));
    try testing.expectEqualStrings("1,230", formatted(&buf, writeNumber, .{ 1234, NumberStyle{ .max_significant = 3 } }));
    try testing.expectEqualStrings("0.00123", formatted(&buf, writeNumber, .{ 0.0012345, NumberStyle{ .max_significant = 3 } }));
    try testing.expectEqualStrings("1.2K", formatted(&buf, writeNumber, .{ 1234, NumberStyle{ .compact = true } }));
    try testing.expectEqualStrings("12K", formatted(&buf, writeNumber, .{ 12345, NumberStyle{ .compact = true } }));
    try testing.expectEqualStrings("1.5M", formatted(&buf, writeNumber, .{ 1_500_000, NumberStyle{ .compact = true } }));
    try testing.expectEqualStrings("999", formatted(&buf, writeNumber, .{ 999, NumberStyle{ .compact = true } }));
    var unit = NumberStyle{ .style = .unit };
    @memcpy(unit.unit[0..9], "kilometer");
    unit.unit_len = 9;
    try testing.expectEqualStrings("5 km", formatted(&buf, writeNumber, .{ 5, unit }));
}

test "the moment of a time value, before the epoch as after it" {
    const c = momentOf(1_789_024_000_000);
    try testing.expectEqual(@as(i32, 2026), c.year);
    try testing.expectEqual(@as(u8, 9), c.month);
    try testing.expectEqual(@as(u8, 10), c.day);
    try testing.expectEqual(@as(u3, 4), c.weekday);
    try testing.expectEqual(@as(u8, 7), c.hour);
    try testing.expectEqual(@as(u8, 6), c.minute);
    try testing.expectEqual(@as(u8, 40), c.second);
    const epoch = momentOf(0);
    try testing.expectEqual(@as(i32, 1970), epoch.year);
    try testing.expectEqual(@as(u8, 1), epoch.month);
    try testing.expectEqual(@as(u8, 1), epoch.day);
    try testing.expectEqual(@as(u3, 4), epoch.weekday);
    const before = momentOf(-86_400_000.0 * 366);
    try testing.expectEqual(@as(i32, 1968), before.year);
    try testing.expectEqual(@as(u8, 12), before.month);
    try testing.expectEqual(@as(u8, 31), before.day);
    const leap = momentOf(951_782_400_000);
    try testing.expectEqual(@as(i32, 2000), leap.year);
    try testing.expectEqual(@as(u8, 2), leap.month);
    try testing.expectEqual(@as(u8, 29), leap.day);
}

test "dates are written as English orders their parts, on a twelve-hour clock unless told otherwise" {
    var buf: [96]u8 = undefined;
    const t: f64 = 1_789_024_000_000;
    try testing.expectEqualStrings("9/10/2026", formatted(&buf, writeDate, .{ t, DateStyle{ .year = .numeric, .month = .numeric, .day = .numeric } }));
    try testing.expectEqualStrings("Thursday, September 10, 2026", formatted(&buf, writeDate, .{ t, DateStyle{ .weekday = .long, .year = .numeric, .month = .long, .day = .numeric } }));
    try testing.expectEqualStrings("Sep 10, 2026, 7:06:40 AM", formatted(&buf, writeDate, .{ t, DateStyle{ .year = .numeric, .month = .short, .day = .numeric, .hour = .numeric, .minute = .@"2-digit", .second = .@"2-digit" } }));
    try testing.expectEqualStrings("September 10 at 7 AM", formatted(&buf, writeDate, .{ t, DateStyle{ .month = .long, .day = .numeric, .hour = .numeric } }));
    try testing.expectEqualStrings("09/10/26", formatted(&buf, writeDate, .{ t, DateStyle{ .year = .@"2-digit", .month = .@"2-digit", .day = .@"2-digit" } }));
    try testing.expectEqualStrings("Thu, 9/10/2026", formatted(&buf, writeDate, .{ t, DateStyle{ .weekday = .short, .year = .numeric, .month = .numeric, .day = .numeric } }));
    try testing.expectEqualStrings("September 2026", formatted(&buf, writeDate, .{ t, DateStyle{ .year = .numeric, .month = .long } }));
    try testing.expectEqualStrings("07:06", formatted(&buf, writeDate, .{ t, DateStyle{ .hour = .numeric, .minute = .@"2-digit", .h23 = true } }));
    try testing.expectEqualStrings("12:00 AM", formatted(&buf, writeDate, .{ 0, DateStyle{ .hour = .numeric, .minute = .@"2-digit" } }));
    try testing.expectEqualStrings("12:30 PM", formatted(&buf, writeDate, .{ 45_000_000, DateStyle{ .hour = .numeric, .minute = .@"2-digit" } }));
    try testing.expectEqualStrings("7:06 AM UTC", formatted(&buf, writeDate, .{ t, DateStyle{ .hour = .numeric, .minute = .@"2-digit", .zone = .short } }));
    try testing.expectEqualStrings("Thursday", formatted(&buf, writeDate, .{ t, DateStyle{ .weekday = .long } }));
}

test "plural categories in English, cardinal and ordinal" {
    try testing.expectEqualStrings("one", pluralOf(1, false));
    try testing.expectEqualStrings("other", pluralOf(2, false));
    try testing.expectEqualStrings("other", pluralOf(0, false));
    try testing.expectEqualStrings("other", pluralOf(1.5, false));
    try testing.expectEqualStrings("one", pluralOf(21, true));
    try testing.expectEqualStrings("two", pluralOf(22, true));
    try testing.expectEqualStrings("few", pluralOf(3, true));
    try testing.expectEqualStrings("other", pluralOf(11, true));
    try testing.expectEqualStrings("other", pluralOf(12, true));
    try testing.expectEqualStrings("other", pluralOf(13, true));
    try testing.expectEqualStrings("other", pluralOf(4, true));
}

test "collation orders letters without their case first, and digits by value where asked" {
    try testing.expectEqual(@as(i32, -1), collate("a", "B", .{}));
    try testing.expectEqual(@as(i32, -1), collate("a", "A", .{}));
    try testing.expectEqual(@as(i32, 0), collate("a", "A", .{ .cased = false }));
    try testing.expectEqual(@as(i32, 1), collate("b", "A", .{}));
    try testing.expectEqual(@as(i32, -1), collate("ab", "abc", .{}));
    try testing.expectEqual(@as(i32, 0), collate("same", "same", .{}));
    try testing.expectEqual(@as(i32, 1), collate("item10", "item9", .{ .numeric = true }));
    try testing.expectEqual(@as(i32, -1), collate("item10", "item9", .{}));
    try testing.expectEqual(@as(i32, 0), collate("a-b", "ab", .{ .ignore_punctuation = true }));
}

test "lists are joined as English joins them" {
    var buf: [64]u8 = undefined;
    const S = struct {
        fn write(sink: *Sink, items: []const []const u8, kind: ListKind, width: Width) void {
            for (items, 0..) |item, i| {
                if (i > 0) sink.put("literal", listJoiner(i, items.len, kind, width));
                sink.put("element", item);
            }
        }
    };
    try testing.expectEqualStrings("a, b, and c", formatted(&buf, S.write, .{ &[_][]const u8{ "a", "b", "c" }, ListKind.conjunction, Width.long }));
    try testing.expectEqualStrings("a and b", formatted(&buf, S.write, .{ &[_][]const u8{ "a", "b" }, ListKind.conjunction, Width.long }));
    try testing.expectEqualStrings("a", formatted(&buf, S.write, .{ &[_][]const u8{"a"}, ListKind.conjunction, Width.long }));
    try testing.expectEqualStrings("a, b, or c", formatted(&buf, S.write, .{ &[_][]const u8{ "a", "b", "c" }, ListKind.disjunction, Width.long }));
    try testing.expectEqualStrings("a, b, & c", formatted(&buf, S.write, .{ &[_][]const u8{ "a", "b", "c" }, ListKind.conjunction, Width.short }));
    try testing.expectEqualStrings("a, b, c", formatted(&buf, S.write, .{ &[_][]const u8{ "a", "b", "c" }, ListKind.unit, Width.long }));
    try testing.expectEqualStrings("a b c", formatted(&buf, S.write, .{ &[_][]const u8{ "a", "b", "c" }, ListKind.unit, Width.narrow }));
}

test "relative times count forward and back, or say the near word where the format may" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("in 3 days", formatted(&buf, writeRelative, .{ 3, Unit.day, false, Width.long }));
    try testing.expectEqualStrings("2 hours ago", formatted(&buf, writeRelative, .{ -2, Unit.hour, false, Width.long }));
    try testing.expectEqualStrings("in 1 day", formatted(&buf, writeRelative, .{ 1, Unit.day, false, Width.long }));
    try testing.expectEqualStrings("tomorrow", formatted(&buf, writeRelative, .{ 1, Unit.day, true, Width.long }));
    try testing.expectEqualStrings("yesterday", formatted(&buf, writeRelative, .{ -1, Unit.day, true, Width.long }));
    try testing.expectEqualStrings("now", formatted(&buf, writeRelative, .{ 0, Unit.second, true, Width.long }));
    try testing.expectEqualStrings("1 hour ago", formatted(&buf, writeRelative, .{ -1, Unit.hour, true, Width.long }));
    try testing.expectEqualStrings("in 1,500 years", formatted(&buf, writeRelative, .{ 1500, Unit.year, false, Width.long }));
    try testing.expectEqualStrings("in 3 hr.", formatted(&buf, writeRelative, .{ 3, Unit.hour, false, Width.short }));
    try testing.expectEqualStrings("in 1.5 days", formatted(&buf, writeRelative, .{ 1.5, Unit.day, false, Width.long }));
    try testing.expectEqual(@as(?Unit, .day), unitOf("days"));
    try testing.expectEqual(@as(?Unit, .quarter), unitOf("quarter"));
    try testing.expectEqual(@as(?Unit, null), unitOf("fortnight"));
}

test "a locale tag is taken apart and written with its subtags cased as the standard has them" {
    const tag = Tag.parse("EN-latn-us-u-ca-gregory") orelse return error.NoTag;
    try testing.expectEqualStrings("EN", tag.language);
    try testing.expectEqualStrings("latn", tag.script.?);
    try testing.expectEqualStrings("us", tag.region.?);
    try testing.expectEqualStrings("u-ca-gregory", tag.rest);
    var buf: [TAG_MAX]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    tag.write(&w);
    try testing.expectEqualStrings("en-Latn-US-u-ca-gregory", w.buffered());
    w = .fixed(&buf);
    tag.writeBase(&w);
    try testing.expectEqualStrings("en-Latn-US", w.buffered());
    const plain = Tag.parse("nl_BE") orelse return error.NoTag;
    try testing.expectEqualStrings("BE", plain.region.?);
    try testing.expect(plain.script == null);
    const numbered = Tag.parse("es-419") orelse return error.NoTag;
    try testing.expectEqualStrings("419", numbered.region.?);
    try testing.expect(Tag.parse("") == null);
    try testing.expect(Tag.parse("1") == null);
    try testing.expect(Tag.parse("x") == null);
}

//! QuickJS's C face, mirrored.
//!
//! The engine is C, and the only way into it is its own API: a `JSValue` is a
//! struct sixteen bytes wide whose shape depends on how upstream was built, and
//! its helpers are C inline functions, so none of it can cross into Zig as it
//! stands. What crosses instead is what a script is made of -- bytes in, a
//! string out -- and this file is the vocabulary for the rest.
//!
//! Mirrored rather than generated, and pinned: `port/pin.c` asserts, against
//! the vendored header, every offset and size this file names, so an upstream
//! change and a mirror change each fail the build on their own. Two bugs were
//! found that way: `prop_flags` and `cproto` are single bytes, not ints, and
//! `port/inlines.c` exists because a dozen small helpers are `static inline`
//! upstream and have no symbol at all.
//!
//! Only what the reader's document uses is here. The engine is large; a mirror
//! of all of it would be a second thing to keep in step.

pub const Runtime = opaque {};
pub const Context = opaque {};
pub const Bool = c_int;
pub const ClassId = u32;
pub const Atom = u32;

/// Whether a value is one word or two.
///
/// On a machine with 64-bit pointers -- which is what this reader is tested
/// on -- a value is two words: what it is, and what kind of thing it is.
/// Vibeee has 32-bit pointers, and there upstream folds the two into one
/// 64-bit word, the kind in the top half: it calls that NAN-boxing. Both are
/// mirrored here, and `port/pin.c` pins whichever the machine being built for
/// uses, so the mirror cannot quietly be right for one and wrong for the
/// other.
const wide = @sizeOf(usize) == 8;

/// A value in a script. Laid out by upstream, and never taken apart here.
const ValueWide = extern struct {
    u: extern union {
        i32: i32,
        i64: i64,
        f64: f64,
        ptr: ?*anyopaque,
    },
    tag: i64,
};

/// A value in a script: two words where pointers are wide, one where they are
/// not, as upstream lays it out. See `wide`.
pub const Value = if (wide) ValueWide else u64;

/// A nought of a given kind: the kind alone, in whichever shape the machine
/// being built for uses it in.
fn nothing(comptime kind: Tag) Value {
    return if (wide)
        .{ .u = .{ .i32 = 0 }, .tag = @intFromEnum(kind) }
    else
        @as(u64, @intCast(@intFromEnum(kind))) << 32;
}

/// The tag that says what a value is. Only the ones this mirror builds or
/// asks about are named; the rest are upstream's business.
pub const Tag = enum(i32) {
    big_int = -9,
    big_float = -8,
    symbol = -7,
    string = -6,
    module = -5,
    function_bytecode = -4,
    object = -1,
    int = 0,
    bool_ = 1,
    null_ = 2,
    undefined = 3,
    uninitialized = 4,
    catch_offset = 5,
    exception = 6,
    float64 = 7,
    _,
};

pub fn nullValue() Value {
    return nothing(.null_);
}

pub fn undefinedValue() Value {
    return nothing(.undefined);
}

/// How a C function is called by the engine: as an ordinary function, or to
/// read or write a property.
pub const CProto = enum(u8) {
    generic,
    generic_magic,
    constructor,
    constructor_magic,
    constructor_or_func,
    constructor_or_func_magic,
    f_f,
    f_f_f,
    getter,
    setter,
    getter_magic,
    setter_magic,
    iterator_next,
};

/// What kind of thing a row of a property list names.
pub const Define = enum(u8) {
    cfunc = 0,
    cgetset,
    cgetset_magic,
    prop_string,
    prop_int32,
    prop_int64,
    prop_double,
    prop_undefined,
    object,
    alias,
    prop_atom,
};

/// A row's flags: a single byte upstream, which is all the low flags need.
/// The `HAS_*` bits are the engine's own, given when it defines the property.
pub const Prop = u8;

pub const flags = struct {
    /// What a method gets: writable and configurable, as `JS_CFUNC_DEF` writes it.
    pub const method: Prop = configurable | writable;
    /// What an accessor gets: configurable alone, as `JS_CGETSET_DEF` writes it.
    pub const accessor: Prop = configurable;
    pub const configurable: Prop = 1 << 0;
    pub const writable: Prop = 1 << 1;
    pub const enumerable: Prop = 1 << 2;
};

/// One row of a property list: a method, or a getter and setter, or one of the
/// plain kinds. A tagged union, as upstream's is a union with a tag beside it.
pub const ListEntry = extern struct {
    name: [*:0]const u8,
    prop_flags: Prop,
    def_type: Define,
    magic: i16,
    u: extern union {
        func: extern struct {
            length: u8,
            cproto: u8,
            which: extern union {
                generic: ?*const fn (*Context, Value, c_int, [*]const Value) callconv(.c) Value,
                getter: ?*const fn (*Context, Value) callconv(.c) Value,
                setter: ?*const fn (*Context, Value, Value) callconv(.c) Value,
            },
        },
        getset: extern struct {
            get: ?*const fn (*Context, Value) callconv(.c) Value,
            set: ?*const fn (*Context, Value, Value) callconv(.c) Value,
        },
        str: [*:0]const u8,
        i32_: i32,
        i64_: i64,
        f64_: f64,
    },

    /// A method, as `JS_CFUNC_DEF` would write it.
    pub fn method(
        name: [*:0]const u8,
        arity: u8,
        impl: *const fn (*Context, Value, c_int, [*]const Value) callconv(.c) Value,
    ) ListEntry {
        return .{
            .name = name,
            .prop_flags = flags.method,
            .def_type = .cfunc,
            .magic = 0,
            .u = .{ .func = .{
                .length = arity,
                .cproto = @intFromEnum(CProto.generic),
                .which = .{ .generic = impl },
            } },
        };
    }

    /// A getter, and a setter where it has one, as `JS_CGETSET_DEF` writes it.
    pub fn accessor(
        name: [*:0]const u8,
        get: *const fn (*Context, Value) callconv(.c) Value,
        set: ?*const fn (*Context, Value, Value) callconv(.c) Value,
    ) ListEntry {
        return .{
            .name = name,
            .prop_flags = flags.accessor,
            .def_type = .cgetset,
            .magic = 0,
            .u = .{ .getset = .{ .get = get, .set = set } },
        };
    }
};

pub const ClassDef = extern struct {
    class_name: [*:0]const u8,
    finalizer: ?*const fn (*Runtime, Value) callconv(.c) void,
    gc_mark: ?*const fn (*Runtime, Value, *const fn (*Runtime, Value) callconv(.c) void) callconv(.c) void,
    call: ?*anyopaque,
    exotic: ?*anyopaque,
};

// ---------------------------------------------------------------------------
// What upstream writes as an inline function
//
// These have no symbol: they are `static inline` in the header. They are given
// one by `port/inlines.c`, a dozen one-line wrappers that, with the pin, are
// the only C of ours in the engine's mirror.
// ---------------------------------------------------------------------------

extern fn qjs_dup(ctx: *Context, value: Value) Value;
extern fn qjs_free(ctx: *Context, value: Value) void;
extern fn qjs_text(ctx: *Context, value: Value) ?[*:0]const u8;
extern fn qjs_bool(ctx: *Context, yes: Bool) Value;
extern fn qjs_int(ctx: *Context, value: i32) Value;
extern fn qjs_uint(ctx: *Context, value: u32) Value;
extern fn qjs_is_exception(value: Value) Bool;

pub const dup = qjs_dup;
pub const free = qjs_free;
pub const textOf = qjs_text;
pub const newBool = qjs_bool;
pub const newInt = qjs_int;
pub const newUint = qjs_uint;
pub const isException = qjs_is_exception;

// ---------------------------------------------------------------------------
// The engine's own calls
// ---------------------------------------------------------------------------

extern fn JS_GetRuntime(ctx: *Context) *Runtime;
extern fn JS_SetContextOpaque(ctx: *Context, held: ?*anyopaque) void;
extern fn JS_GetContextOpaque(ctx: *Context) ?*anyopaque;

extern fn JS_GetGlobalObject(ctx: *Context) Value;
extern fn JS_NewObject(ctx: *Context) Value;
extern fn JS_NewObjectClass(ctx: *Context, class_id: c_int) Value;
extern fn JS_NewArray(ctx: *Context) Value;
extern fn JS_NewStringLen(ctx: *Context, text: [*]const u8, len: usize) Value;
extern fn JS_NewPromiseCapability(ctx: *Context, resolvers: *[2]Value) Value;

extern fn JS_NewClassID(id: *ClassId) void;
extern fn JS_NewClass(rt: *Runtime, id: ClassId, def: *const ClassDef) c_int;
extern fn JS_SetOpaque(value: Value, held: ?*anyopaque) void;
extern fn JS_GetOpaque(value: Value, class_id: ClassId) ?*anyopaque;
extern fn JS_NewAtom(ctx: *Context, name: [*:0]const u8) Atom;
extern fn JS_FreeAtom(ctx: *Context, atom: Atom) void;
extern fn JS_DefinePropertyGetSet(ctx: *Context, into: Value, atom: Atom, get: Value, set: Value, flags: c_int) c_int;
extern fn JS_SetPropertyFunctionList(ctx: *Context, into: Value, tab: [*]const ListEntry, len: c_int) c_int;

extern fn JS_GetPropertyStr(ctx: *Context, from: Value, name: [*:0]const u8) Value;
extern fn JS_SetPropertyStr(ctx: *Context, into: Value, name: [*:0]const u8, value: Value) c_int;
extern fn JS_SetPropertyUint32(ctx: *Context, into: Value, at: u32, value: Value) c_int;

extern fn JS_NewCFunction2(
    ctx: *Context,
    call: ?*const anyopaque,
    name: [*:0]const u8,
    arity: c_int,
    cproto: CProto,
    magic: c_int,
) Value;

extern fn JS_Call(ctx: *Context, function: Value, this: Value, argc: c_int, argv: ?[*]const Value) Value;
extern fn JS_Eval(ctx: *Context, source: [*]const u8, len: usize, name: [*:0]const u8, flags: c_int) Value;
extern fn JS_ParseJSON(ctx: *Context, text: [*]const u8, len: usize, name: [*:0]const u8) Value;
extern fn JS_GetException(ctx: *Context) Value;
extern fn JS_FreeCString(ctx: *Context, text: [*:0]const u8) void;
extern fn JS_ToBool(ctx: *Context, value: Value) c_int;
extern fn JS_ToInt32(ctx: *Context, out: *i32, value: Value) c_int;
extern fn JS_IsFunction(ctx: *Context, value: Value) Bool;
extern fn JS_SameValue(ctx: *Context, a: Value, b: Value) Bool;

extern fn js_malloc(ctx: *Context, size: usize) ?*anyopaque;
extern fn js_free(ctx: *Context, held: ?*anyopaque) void;

pub const runtimeOf = JS_GetRuntime;
pub const setHeld = JS_SetContextOpaque;
pub const heldOf = JS_GetContextOpaque;

pub const globalOf = JS_GetGlobalObject;
pub const newObject = JS_NewObject;
pub const newObjectIn = JS_NewObjectClass;
pub const newArray = JS_NewArray;
pub const newString = JS_NewStringLen;
pub const promise = JS_NewPromiseCapability;

pub const newClassId = JS_NewClassID;
pub const newClass = JS_NewClass;
pub const setNode = JS_SetOpaque;
pub const nodeOf = JS_GetOpaque;
pub const addList = JS_SetPropertyFunctionList;

pub const atomOf = JS_NewAtom;
pub const freeAtom = JS_FreeAtom;
/// A property that is read and written through calls of ours, which is how a
/// page's `location =` is taken as an asking to be sent there.
pub const addAccessor = JS_DefinePropertyGetSet;

pub const getStr = JS_GetPropertyStr;
pub const setStr = JS_SetPropertyStr;
pub const setAt = JS_SetPropertyUint32;

pub const function = JS_NewCFunction2;

pub const call = JS_Call;
pub const run = JS_Eval;
pub const parseJson = JS_ParseJSON;
pub const exceptionOf = JS_GetException;
pub const freeText = JS_FreeCString;
pub const truthOf = JS_ToBool;
pub const toInt = JS_ToInt32;
pub const isFunction = JS_IsFunction;
/// Whether two values are the very same thing, which is how a script knows
/// the handler it would take away from the one it put there.
pub const sameAs = JS_SameValue;

pub const alloc = js_malloc;
pub const release = js_free;

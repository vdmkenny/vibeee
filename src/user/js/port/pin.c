/* The proof between QuickJS's C and the Zig mirror in `quickjs.zig`.
 *
 * The mirror hand-writes, in Zig, the shapes QuickJS hands across: a value, a
 * row of a property list, a class, and the numbers the engine names kinds and
 * flags by. This file asserts the same shapes against the vendored header, so
 * an upstream change and a mirror change each fail the build on their own
 * rather than agreeing to disagree until a page does something odd. Two real
 * bugs were caught here: `prop_flags` and `u.func.cproto` are single bytes, so
 * a mirror that made them ints shifted `def_type` and `magic`, and every
 * getter came out as a method.

 * It contains no code: static assertions only.
 */
#include <stddef.h>

#include "quickjs.h"

#if INTPTR_MAX >= INT64_MAX
/* A machine with 64-bit pointers: a value is two words. */
_Static_assert(sizeof(JSValue) == 16, "JSValue is not sixteen bytes");
_Static_assert(offsetof(JSValue, u) == 0, "JSValue.u moved");
_Static_assert(offsetof(JSValue, tag) == 8, "JSValue.tag moved");

_Static_assert(sizeof(JSCFunctionListEntry) == 32, "JSCFunctionListEntry changed size");
_Static_assert(offsetof(JSCFunctionListEntry, name) == 0, "entry.name moved");
_Static_assert(offsetof(JSCFunctionListEntry, prop_flags) == 8, "entry.prop_flags moved");
_Static_assert(offsetof(JSCFunctionListEntry, def_type) == 9, "entry.def_type moved");
_Static_assert(offsetof(JSCFunctionListEntry, magic) == 10, "entry.magic moved");
_Static_assert(offsetof(JSCFunctionListEntry, u) == 16, "entry.u moved");
_Static_assert(offsetof(JSCFunctionListEntry, u.func.length) == 16, "entry.u.func.length moved");
_Static_assert(offsetof(JSCFunctionListEntry, u.func.cproto) == 17, "entry.u.func.cproto moved");
_Static_assert(offsetof(JSCFunctionListEntry, u.func.cfunc) == 24, "entry.u.func.cfunc moved");
_Static_assert(offsetof(JSCFunctionListEntry, u.getset.get) == 16, "entry.u.getset.get moved");
_Static_assert(offsetof(JSCFunctionListEntry, u.getset.set) == 24, "entry.u.getset.set moved");
#else
/* A machine with 32-bit pointers, which is what vibeee is: a value is one
 * word with its kind folded into the top of it. */
_Static_assert(sizeof(JSValue) == 8, "JSValue is not one word");
_Static_assert(sizeof(JSCFunctionListEntry) == 16, "JSCFunctionListEntry changed size");
_Static_assert(offsetof(JSCFunctionListEntry, name) == 0, "entry.name moved");
_Static_assert(offsetof(JSCFunctionListEntry, prop_flags) == 4, "entry.prop_flags moved");
_Static_assert(offsetof(JSCFunctionListEntry, def_type) == 5, "entry.def_type moved");
_Static_assert(offsetof(JSCFunctionListEntry, magic) == 6, "entry.magic moved");
_Static_assert(offsetof(JSCFunctionListEntry, u) == 8, "entry.u moved");
_Static_assert(offsetof(JSCFunctionListEntry, u.func.length) == 8, "entry.u.func.length moved");
_Static_assert(offsetof(JSCFunctionListEntry, u.func.cproto) == 9, "entry.u.func.cproto moved");
_Static_assert(offsetof(JSCFunctionListEntry, u.func.cfunc) == 12, "entry.u.func.cfunc moved");
_Static_assert(offsetof(JSCFunctionListEntry, u.getset.get) == 8, "entry.u.getset.get moved");
_Static_assert(offsetof(JSCFunctionListEntry, u.getset.set) == 12, "entry.u.getset.set moved");
#endif

/* What the mirror calls its kinds, against what the engine calls theirs. */
_Static_assert(JS_DEF_CFUNC == 0, "JS_DEF_CFUNC is not nought");
_Static_assert(JS_DEF_CGETSET == 1, "JS_DEF_CGETSET is not one");
_Static_assert(JS_CFUNC_generic == 0, "JS_CFUNC_generic is not nought");
_Static_assert(JS_CFUNC_getter == 8, "JS_CFUNC_getter moved");
_Static_assert(JS_CFUNC_setter == 9, "JS_CFUNC_setter moved");
_Static_assert(JS_TAG_BOOL == 1, "JS_TAG_BOOL moved");
_Static_assert(JS_TAG_NULL == 2, "JS_TAG_NULL moved");
_Static_assert(JS_TAG_UNDEFINED == 3, "JS_TAG_UNDEFINED moved");
_Static_assert(JS_TAG_EXCEPTION == 6, "JS_TAG_EXCEPTION moved");
_Static_assert((JS_PROP_WRITABLE | JS_PROP_CONFIGURABLE) == 3, "a method's flags are not three");
_Static_assert(JS_PROP_CONFIGURABLE == 1, "an accessor's flags are not one");

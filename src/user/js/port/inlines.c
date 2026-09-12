/* What QuickJS writes as an inline function, given a name to link against.
 *
 * The engine's small helpers -- taking a reference, giving one back, reading a
 * value as text, making a number or a bool -- are `static inline` in its
 * header, so there is nothing for the Zig mirror in `quickjs.zig` to call.
 * They are one line each. This, and the assertions in `pin.c`, are the only C
 * of ours in the mirror: everything that does something is Zig.
 */
#include "quickjs.h"

JSValue qjs_dup(JSContext *ctx, JSValueConst value)
{
    return JS_DupValue(ctx, value);
}

void qjs_free(JSContext *ctx, JSValue value)
{
    JS_FreeValue(ctx, value);
}

const char *qjs_text(JSContext *ctx, JSValueConst value)
{
    return JS_ToCString(ctx, value);
}

JSValue qjs_bool(JSContext *ctx, int yes)
{
    return JS_NewBool(ctx, yes);
}

JSValue qjs_int(JSContext *ctx, int32_t value)
{
    return JS_NewInt32(ctx, value);
}

JSValue qjs_uint(JSContext *ctx, uint32_t value)
{
    return JS_NewUint32(ctx, value);
}

JSValue qjs_float(JSContext *ctx, double value)
{
    return JS_NewFloat64(ctx, value);
}

int qjs_is_exception(JSValue value)
{
    return JS_IsException(value);
}

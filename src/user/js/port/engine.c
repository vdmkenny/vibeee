//! What `engine.h` says, over QuickJS.
//!
//! Nothing here is ours but the calls themselves and what a script is given:
//! how the engine is opened and stopped, how a script is run, and how it
//! says something out loud. Everything else is upstream's.
//!
//! Upstream's own library of helpers is not used, and so is not vendored:
//! what it gives a script is a POSIX this system does not have — shared
//! objects to open, processes to wait for, a poll to block on — and a stub
//! for each would be a promise the machine cannot keep. A script gets the
//! language, `print` and `console.log`, and is told when it asks for more
//! than that, which is the honest state rather than a pretence of POSIX.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "quickjs.h"

#include "engine.h"

/// Where what a script says goes. A reader's stdout is not a console a person
/// is looking at, so the reader gives the engine somewhere better when it
/// starts: the system log, which is where everything else says what it is
/// doing. Left alone, what a script says goes to stdout as it always did.
static void (*say_to)(const char *text) = NULL;

void qjs_set_say(void (*say)(const char *text))
{
    say_to = say;
}

static void say_text(const char *text)
{
    if (say_to)
        say_to(text);
    else
        fputs(text, stdout);
}

/// A value, as words. What `print` and `console.log` say, and what a script
/// is told its script ended in.
static void say(JSContext *ctx, JSValueConst value, const char *after)
{
    const char *text = JS_ToCString(ctx, value);

    if (text) {
        say_text(text);
        JS_FreeCString(ctx, text);
    }
    if (after)
        say_text(after);
}

/// The same for each of a list of arguments, with a space between them, as
/// `console.log` does and as `print` does with one.
static JSValue js_say(JSContext *ctx, JSValueConst this_val,
                      int argc, JSValueConst *argv)
{
    int i;

    for (i = 0; i < argc; i++) {
        if (i)
            fputc(' ', stdout);
        say(ctx, argv[i], NULL);
    }
    fputc('\n', stdout);
    return JS_UNDEFINED;
}

/// Give a script `print` and `console.log`.
///
/// What is handed to `JS_SetPropertyStr` is the engine's from then on: this
/// version takes the value rather than copying it, and a caller that frees
/// what it passed corrupts the heap one object later, which is a long way
/// from the line that did it. Only what `JS_GetGlobalObject` handed out is
/// given back here.
static void add_helpers(JSContext *ctx)
{
    JSValue global, console;

    global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "print",
                      JS_NewCFunction(ctx, js_say, "print", 1));
    console = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, console, "log",
                      JS_NewCFunction(ctx, js_say, "log", 1));
    JS_SetPropertyStr(ctx, console, "info",
                      JS_NewCFunction(ctx, js_say, "info", 1));
    JS_SetPropertyStr(ctx, console, "warn",
                      JS_NewCFunction(ctx, js_say, "warn", 1));
    JS_SetPropertyStr(ctx, console, "error",
                      JS_NewCFunction(ctx, js_say, "error", 1));
    JS_SetPropertyStr(ctx, console, "debug",
                      JS_NewCFunction(ctx, js_say, "debug", 1));
    JS_SetPropertyStr(ctx, global, "console", console);
    JS_FreeValue(ctx, global);
}

struct JSRuntime *qjs_start(void)
{
    return JS_NewRuntime();
}

struct JSContext *qjs_open(struct JSRuntime *rt)
{
    JSContext *ctx;

    if (!rt)
        return NULL;
    ctx = JS_NewContext(rt);
    if (!ctx)
        return NULL;
    add_helpers(ctx);
    return ctx;
}

char *qjs_run(struct JSContext *ctx, const char *source, size_t len,
              const char *name, int module)
{
    JSValue value;
    const char *as_text;
    char *out;
    size_t taken;

    value = JS_Eval(ctx, source, len, name,
                    module ? JS_EVAL_TYPE_MODULE : JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(value)) {
        JS_FreeValue(ctx, value);
        return NULL;
    }
    out = NULL;
    if (!JS_IsUndefined(value)) {
        as_text = JS_ToCString(ctx, value);
        if (as_text) {
            taken = strlen(as_text) + 1;
            out = js_malloc(ctx, taken);
            if (out)
                memcpy(out, as_text, taken);
            JS_FreeCString(ctx, as_text);
        }
    }
    JS_FreeValue(ctx, value);
    return out;
}

void qjs_tell_error(struct JSContext *ctx)
{
    JSValue exception, stack;

    exception = JS_GetException(ctx);
    if (JS_IsObject(exception)) {
        say(ctx, exception, NULL);
        fputc('\n', stdout);
        /* Where it happened, which is most of what is useful about an
           error. Kept only where the engine kept one. */
        stack = JS_GetPropertyStr(ctx, exception, "stack");
        if (!JS_IsUndefined(stack)) {
            say(ctx, stack, NULL);
            fputc('\n', stdout);
        }
        JS_FreeValue(ctx, stack);
    } else if (!JS_IsNull(exception)) {
        say(ctx, exception, "\n");
    }
    JS_FreeValue(ctx, exception);
}

void qjs_loop(struct JSContext *ctx)
{
    JSRuntime *rt = JS_GetRuntime(ctx);
    JSContext *wanting;
    int err;

    /* A promise a script made is kept after the script has been read, which
       is the one thing a program running it must do besides run it. */
    for (;;) {
        err = JS_ExecutePendingJob(rt, &wanting);
        if (err <= 0) {
            if (err < 0)
                qjs_tell_error(wanting);
            break;
        }
    }
}

void qjs_give_back(struct JSContext *ctx, char *text)
{
    js_free(ctx, text);
}

/// Note that a script reached for something this reader has no answer for:
/// `scripts: no getComputedStyle`. A page that stops where it found nothing
/// says nothing about why; this is the half of that a reader can give.
void qjs_note(const char *what)
{
    say_text("scripts: no ");
    say_text(what);
    say_text("\n");
}

void qjs_close(struct JSContext *ctx)
{
    JS_FreeContext(ctx);
}

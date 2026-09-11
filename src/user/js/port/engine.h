//! The engine's face, as a program of this system reaches it.
//!
//! QuickJS hands out its values as a struct sixteen bytes wide, whose shape
//! depends on how upstream was built and whose helpers are C's alone, so
//! nothing of it crosses to Zig: a script goes in as bytes, and what comes
//! out is a string, an error, or nothing. That is also the whole of what a
//! program running a script wants.
//!
//! The pin is `apps/qjs/quickjs.zig`, which declares these calls and nothing
//! else; a signature changed here fails there.

#ifndef VIBEEE_ENGINE_H
#define VIBEEE_ENGINE_H

#include <stddef.h>

struct JSContext;

/// A running engine: a runtime, and a context with every intrinsic in it and
/// the two ways a script has of saying something out loud.
struct JSContext *qjs_open(void);

/// Run `len` bytes of `source` called `name`, as a module or as a script.
/// Answers the value it ended in, as a string the caller gives back with
/// `qjs_give_back`, or nothing for a script that ends in no value, or nothing
/// at all for one that threw: an exception is told by `qjs_tell_error`.
char *qjs_run(struct JSContext *ctx, const char *source, size_t len,
              const char *name, int module);

/// Say what went wrong with the last script, on the program's own output.
void qjs_tell_error(struct JSContext *ctx);

/// Run what the script left waiting: the promises it made.
void qjs_loop(struct JSContext *ctx);

/// Give back a string `qjs_run` answered with.
void qjs_give_back(struct JSContext *ctx, char *text);

/// Stop the engine, and give back everything it holds.
void qjs_close(struct JSContext *ctx);

#endif

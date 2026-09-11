//! A document, as a script sees it.
//!
//! The page's own tree, given to a script in the terms a script expects: an
//! element is an object with an `id`, a `className`, a `style`, children and
//! a `textContent`, and the document is where elements are found and made.
//! The tree behind it is lexbor's, the same one the reader reads the page
//! from, so what a script does to it is what the reader draws next time it
//! reads.
//!
//! A document belongs to one page: the reader gives a script a context per
//! page, so nothing here outlives the tree it points into. `dom_release`
//! gives back what a script left hanging on it.
//!
//! The pin is `apps/web/dom.zig`.

#ifndef VIBEEE_DOM_H
#define VIBEEE_DOM_H

#include <stdbool.h>
#include <stddef.h>

struct JSContext;
struct lxb_dom_document;
struct lxb_dom_node;

/// Give a script the document `document`, whose page came from `address`.
/// A script asking where it is gets `address`; it is copied.
bool dom_bind(struct JSContext *ctx, struct lxb_dom_document *document,
              const char *address, const char *user_agent);

/// Run every script the document carries, in the order they stand, as a
/// browser does once the document has been parsed, then tell it, and
/// everything listening, that the document is ready.
void dom_load(struct JSContext *ctx, struct lxb_dom_document *document);

/// A click on the element at `node`, and on each of its ancestors in turn,
/// as one climbs. True where a listener asked for it to go no further, which
/// is a link not followed.
bool dom_click(struct JSContext *ctx, struct lxb_dom_node *node);

/// What was filled in and sent: the control at `node` changed, as `change`
/// and `input` say.
void dom_changed_at(struct JSContext *ctx, struct lxb_dom_node *node, bool sent);

/// Whether anything a script has done since the last time this was asked has
/// changed the document, and so whether the page reads differently.
bool dom_changed(struct JSContext *ctx);

/// Run what a script left waiting: the promises it made and the timers it
/// set. True where one of them is due soon, for a window that is otherwise
/// idle.
bool dom_loop(struct JSContext *ctx);

/// How long until the next timer is due, in thousandths of a second, or
/// nothing where no timer is waiting.
bool dom_waits(struct JSContext *ctx, unsigned int *in_ms);

/// Give back the document, and everything a script left hanging on it.
void dom_release(struct JSContext *ctx);

#endif

/* The layout proof between lexbor's C and this program's Zig mirror.
 *
 * `lexbor.zig` hand-mirrors the one struct the walk reaches into, a DOM node,
 * with comptime assertions pinning its side of every offset. This file pins
 * the C side of the same offsets against the vendored headers, so a header
 * change and a mirror change each fail the build on their own.
 *
 * Only the fields ahead of `type` are pinned, because only those decide where
 * `type` sits. What follows it is upstream's business.
 *
 * It contains no code: static assertions only.
 */
#include <stddef.h>

#include "lexbor/dom/interfaces/node.h"
#include "lexbor/dom/interfaces/event_target.h"

#define CHECK(name, expr) _Static_assert((expr), name)

/* The head of a node is an event target, and an event target is one pointer.
 * Two would move every field below it, and a walk reading `type` from the
 * wrong offset finds a node kind that was never there. */
CHECK("an event target is one pointer",
      sizeof(lxb_dom_event_target_t) == sizeof(void *));

CHECK("a node begins with its event target",
      offsetof(lxb_dom_node_t, event_target) == 0);

CHECK("local_name follows the event target",
      offsetof(lxb_dom_node_t, local_name) == sizeof(void *));

CHECK("the three names are one word each",
      offsetof(lxb_dom_node_t, ns) - offsetof(lxb_dom_node_t, local_name)
          == 2 * sizeof(uintptr_t));

CHECK("the owning document follows the names",
      offsetof(lxb_dom_node_t, owner_document)
          == offsetof(lxb_dom_node_t, ns) + sizeof(uintptr_t));

CHECK("the five links are in the order the mirror walks them",
      offsetof(lxb_dom_node_t, next) < offsetof(lxb_dom_node_t, prev)
          && offsetof(lxb_dom_node_t, prev) < offsetof(lxb_dom_node_t, parent)
          && offsetof(lxb_dom_node_t, parent) < offsetof(lxb_dom_node_t, first_child)
          && offsetof(lxb_dom_node_t, first_child) < offsetof(lxb_dom_node_t, last_child));

CHECK("the user pointer follows the links",
      offsetof(lxb_dom_node_t, user)
          == offsetof(lxb_dom_node_t, last_child) + sizeof(void *));

CHECK("the node kind follows the user pointer",
      offsetof(lxb_dom_node_t, type)
          == offsetof(lxb_dom_node_t, user) + sizeof(void *));

/* What the mirror says the whole head measures, so a field inserted anywhere
 * above `type` is caught even when the relative order still holds. */
CHECK("the head of a node is eleven words",
      offsetof(lxb_dom_node_t, type) == 11 * sizeof(void *));

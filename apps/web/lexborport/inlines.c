/* What lexbor writes as an inline function, given a name to link against.
 *
 * Walking a tree and reading what a search found are `lxb_inline` in its
 * headers, so there is nothing for the Zig mirror in `lexbor.zig` to call.
 * They are one line each. This is the only C of ours in the lexbor mirror.
 */
#include "lexbor/dom/collection.h"
#include "lexbor/dom/interfaces/document.h"
#include "lexbor/dom/interfaces/element.h"
#include "lexbor/dom/interfaces/node.h"

lxb_dom_node_t *lexbor_first_child(lxb_dom_node_t *node)
{
    return lxb_dom_node_first_child(node);
}

lxb_dom_node_t *lexbor_next(lxb_dom_node_t *node)
{
    return lxb_dom_node_next(node);
}

lxb_dom_node_t *lexbor_prev(lxb_dom_node_t *node)
{
    return lxb_dom_node_prev(node);
}

lxb_dom_node_t *lexbor_parent(lxb_dom_node_t *node)
{
    return lxb_dom_node_parent(node);
}

size_t lexbor_collection_length(lxb_dom_collection_t *collection)
{
    return lxb_dom_collection_length(collection);
}

lxb_dom_element_t *lexbor_collection_element(lxb_dom_collection_t *collection, size_t at)
{
    return lxb_dom_collection_element(collection, at);
}

void *lexbor_destroy_text(lxb_dom_document_t *document, lxb_char_t *text)
{
    return lxb_dom_document_destroy_text(document, text);
}

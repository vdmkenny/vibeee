//! What `dom.h` says, over lexbor and QuickJS.
//!
//! The tree a script is given is the tree the reader reads the page from, so
//! every call here reaches straight into it: an element object holds a pointer
//! to a lexbor node and nothing else, and its methods are lexbor's own calls.
//! Nothing is mirrored or cached, so nothing can fall out of step with the
//! page.
//!
//! Finding an element by a selector is lexbor's own selectors engine, the one
//! the cascade is read with, so `querySelector` and a stylesheet's `a[href]`
//! mean the same thing here as they do there.
//!
//! What a script may be told about the document it is in is kept beside the
//! runtime: the document itself, whether anything has changed it since the
//! reader last looked, and the timers and listeners a script has left behind.
//! A context is made for one page and freed with it.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "lexbor/core/base.h"
#include "lexbor/css/parser.h"
#include "lexbor/css/selectors/selectors.h"
#include "lexbor/dom/collection.h"
#include "lexbor/dom/interfaces/document.h"
#include "lexbor/dom/interfaces/element.h"
#include "lexbor/dom/interfaces/node.h"
#include "lexbor/dom/interfaces/text.h"
#include "lexbor/html/html.h"
#include "lexbor/html/interface.h"
#include "lexbor/html/interfaces/document.h"
#include "lexbor/html/serialize.h"
#include "lexbor/selectors/selectors.h"
#include "lexbor/tag/const.h"

#include "cutils.h"
#include "quickjs.h"
#include "engine.h"

#include "dom.h"

/* ------------------------------------------------------------------ */
/* What a document remembers                                          */
/* ------------------------------------------------------------------ */

typedef struct Watch {
    void *node;
    char *type;
    JSValue handler;
    struct Watch *next;
} Watch;

typedef struct Timer {
    int id;
    JSValue handler;
    unsigned int due;
    unsigned int every;
    struct Timer *next;
} Timer;

/// A cookie a script has written. Kept for the page's own host, and handed to
/// the reader to send. What a site *sets* is not taken yet: the reader reads
/// no `Set-Cookie` out of an answer, so a cookie here is one a script wrote.
typedef struct Crumb {
    char *name, *value, *domain, *path;
    struct Crumb *next;
} Crumb;

/// What a page has put by with `localStorage`, which lasts as long as the
/// page does.
typedef struct Stored {
    char *key, *value;
    struct Stored *next;
} Stored;

typedef struct Document {
    lxb_dom_document_t *tree;
    Crumb *crumbs;
    Stored *stored;
    dom_fetch_f fetch;
    void *fetch_taken;
    char *address;
    lxb_css_memory_t *css_memory;
    lxb_css_parser_t *parser;
    lxb_selectors_t *selectors;
    Watch *watches;
    Timer *timers;
    int next_timer;
    bool changed;
    /// Whether the event being dispatched was asked to go no further.
    bool prevented;
} Document;

static JSClassID node_class, list_class, style_class, event_class;

static JSValue node_of_tree(JSContext *ctx, lxb_dom_node_t *node);
static JSValue style_of(JSContext *ctx, lxb_dom_node_t *node);

static void tell(JSContext *ctx, lxb_dom_node_t *node, const char *type, bool climb);

static Document *held(JSContext *ctx)
{
    return JS_GetRuntimeOpaque(JS_GetRuntime(ctx));
}

static void changed(JSContext *ctx)
{
    Document *doc = held(ctx);

    if (doc)
        doc->changed = true;
}

static lxb_dom_node_t *node_of(JSValueConst value)
{
    return JS_GetOpaque(value, node_class);
}

/* ------------------------------------------------------------------ */
/* Attributes                                                         */
/* ------------------------------------------------------------------ */

static JSValue attr_of(JSContext *ctx, lxb_dom_node_t *node, const char *name)
{
    size_t length = 0;
    const lxb_char_t *value = lxb_dom_element_get_attribute(
        lxb_dom_interface_element(node), (const lxb_char_t *)name, strlen(name), &length);

    if (!value)
        return JS_NULL;
    return JS_NewStringLen(ctx, (const char *)value, length);
}

static void attr_set(JSContext *ctx, lxb_dom_node_t *node, const char *name, const char *value)
{
    lxb_dom_element_set_attribute(lxb_dom_interface_element(node),
                                  (const lxb_char_t *)name, strlen(name),
                                  (const lxb_char_t *)value, strlen(value));
    changed(ctx);
}

static JSValue js_get_attribute(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);
    const char *name;
    JSValue out = JS_NULL;

    if (!node)
        return JS_NULL;
    name = JS_ToCString(ctx, argv[0]);
    if (!name)
        return JS_EXCEPTION;
    out = attr_of(ctx, node, name);
    JS_FreeCString(ctx, name);
    return out;
}

static JSValue js_set_attribute(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);
    const char *name, *value;

    if (!node)
        return JS_UNDEFINED;
    name = JS_ToCString(ctx, argv[0]);
    value = JS_ToCString(ctx, argv[1]);
    if (name && value)
        attr_set(ctx, node, name, value);
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, value);
    return JS_UNDEFINED;
}

static JSValue js_has_attribute(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);
    const char *name;
    bool had = false;

    if (!node)
        return JS_FALSE;
    name = JS_ToCString(ctx, argv[0]);
    if (name) {
        had = lxb_dom_element_has_attribute(lxb_dom_interface_element(node),
                                            (const lxb_char_t *)name, strlen(name));
        JS_FreeCString(ctx, name);
    }
    return JS_NewBool(ctx, had);
}

static JSValue js_remove_attribute(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);
    const char *name;

    if (!node)
        return JS_UNDEFINED;
    name = JS_ToCString(ctx, argv[0]);
    if (name) {
        lxb_dom_element_remove_attribute(lxb_dom_interface_element(node),
                                         (const lxb_char_t *)name, strlen(name));
        changed(ctx);
        JS_FreeCString(ctx, name);
    }
    return JS_UNDEFINED;
}

static JSValue js_toggle_attribute(JSContext *ctx, JSValueConst this_val,
                                   int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);
    const char *name;
    bool had = false;

    if (!node)
        return JS_FALSE;
    name = JS_ToCString(ctx, argv[0]);
    if (!name)
        return JS_FALSE;
    had = lxb_dom_element_has_attribute(lxb_dom_interface_element(node),
                                        (const lxb_char_t *)name, strlen(name));
    if (had) {
        lxb_dom_element_remove_attribute(lxb_dom_interface_element(node),
                                         (const lxb_char_t *)name, strlen(name));
    } else {
        attr_set(ctx, node, name, "");
    }
    JS_FreeCString(ctx, name);
    return JS_NewBool(ctx, !had);
}

/* ------------------------------------------------------------------ */
/* What an element says                                               */
/* ------------------------------------------------------------------ */

static JSValue text_of(JSContext *ctx, lxb_dom_node_t *node)
{
    size_t length = 0;
    lxb_char_t *text = lxb_dom_node_text_content(node, &length);

    if (text && length)
        return JS_NewStringLen(ctx, (const char *)text, length);
    return JS_NewString(ctx, "");
}

static JSValue js_text_content(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);

    if (!node)
        return JS_UNDEFINED;
    return text_of(ctx, node);
}

static JSValue js_set_text_content(JSContext *ctx, JSValueConst this_val, JSValueConst value)
{
    lxb_dom_node_t *node = node_of(this_val);
    const char *text;

    if (!node)
        return JS_UNDEFINED;
    text = JS_ToCString(ctx, value);
    if (text) {
        while (lxb_dom_node_first_child(node))
            lxb_dom_node_remove(lxb_dom_node_first_child(node));
        if (*text) {
            lxb_dom_text_t *leaf = lxb_dom_document_create_text_node(
                node->owner_document, (const lxb_char_t *)text, strlen(text));

            if (leaf)
                lxb_dom_node_append_child(node, lxb_dom_interface_node(leaf));
        }
        changed(ctx);
        JS_FreeCString(ctx, text);
    }
    return JS_UNDEFINED;
}

/// Its markup, as the page wrote it: what a script that reads a page's own
/// words reads.
static JSValue js_inner_html(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);
    lexbor_str_t text = {0};
    JSValue out;

    if (!node)
        return JS_UNDEFINED;
    if (lxb_html_serialize_deep_str(node, &text) != LXB_STATUS_OK)
        return JS_NewString(ctx, "");
    out = JS_NewStringLen(ctx, (const char *)text.data, text.length);
    lexbor_str_destroy(&text, node->owner_document->text, false);
    return out;
}

/// The same, written back: parsed as a fragment of the page and put in its
/// place, which is how a page builds what it says.
static JSValue js_set_inner_html(JSContext *ctx, JSValueConst this_val, JSValueConst value)
{
    lxb_dom_node_t *node = node_of(this_val);
    const char *markup;

    if (!node)
        return JS_UNDEFINED;
    markup = JS_ToCString(ctx, value);
    if (markup) {
        while (lxb_dom_node_first_child(node))
            lxb_dom_node_remove(lxb_dom_node_first_child(node));
        if (*markup) {
            lxb_html_document_t *page = (lxb_html_document_t *)node->owner_document;
            lxb_dom_node_t *into = lxb_html_document_parse_fragment(
                page, lxb_dom_interface_element(node), (const lxb_char_t *)markup,
                strlen(markup));

            while (into && lxb_dom_node_first_child(into)) {
                lxb_dom_node_t *each = lxb_dom_node_first_child(into);

                lxb_dom_node_remove(each);
                lxb_dom_node_append_child(node, each);
            }
        }
        changed(ctx);
        JS_FreeCString(ctx, markup);
    }
    return JS_UNDEFINED;
}

/* ------------------------------------------------------------------ */
/* Its class, and its style                                           */
/* ------------------------------------------------------------------ */

/// The classes an element has, as words.
static void classes_of(JSContext *ctx, lxb_dom_node_t *node, JSValue into)
{
    JSValue named = attr_of(ctx, node, "class");
    const char *text = JS_ToCString(ctx, named);
    uint32_t at = 0;
    size_t start = 0;

    if (!text) {
        JS_FreeValue(ctx, named);
        return;
    }
    for (size_t i = 0; i <= strlen(text); i++) {
        if (text[i] && !strchr(" \t\n\r\f", text[i]))
            continue;
        if (i > start)
            JS_SetPropertyUint32(ctx, into, at++, JS_NewStringLen(ctx, text + start, i - start));
        start = i + 1;
    }
    JS_FreeCString(ctx, text);
    JS_FreeValue(ctx, named);
}

static void classes_set(JSContext *ctx, lxb_dom_node_t *node, JSValue from)
{
    char *text = NULL;
    size_t used = 0;

    for (uint32_t i = 0;; i++) {
        JSValue each = JS_GetPropertyUint32(ctx, from, i);
        const char *word;
        size_t taken;
        char *grown;

        if (JS_IsUndefined(each)) {
            JS_FreeValue(ctx, each);
            break;
        }
        word = JS_ToCString(ctx, each);
        JS_FreeValue(ctx, each);
        if (!word)
            continue;
        taken = strlen(word);
        grown = js_realloc(ctx, text, used + taken + (used ? 1 : 0) + 1);
        if (grown) {
            text = grown;
            if (used) {
                text[used] = ' ';
                used += 1;
            }
            memcpy(text + used, word, taken);
            used += taken;
            text[used] = 0;
        }
        JS_FreeCString(ctx, word);
    }
    if (text)
        attr_set(ctx, node, "class", text);
    js_free(ctx, text);
}

static JSValue js_class_add(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = JS_GetOpaque(this_val, list_class);
    const char *wanted;
    JSValue names;
    uint32_t at = 0;

    if (!node)
        return JS_UNDEFINED;
    names = JS_NewArray(ctx);
    classes_of(ctx, node, names);
    wanted = JS_ToCString(ctx, argv[0]);
    if (wanted) {
        /* Once only: a class it has already is left as it is. */
        for (uint32_t i = 0;; i++) {
            JSValue each = JS_GetPropertyUint32(ctx, names, i);

            if (JS_IsUndefined(each)) {
                JS_FreeValue(ctx, each);
                break;
            }
            if (JS_StrictEq(ctx, each, argv[0])) {
                JS_FreeValue(ctx, each);
                JS_FreeValue(ctx, names);
                JS_FreeCString(ctx, wanted);
                return JS_UNDEFINED;
            }
            JS_FreeValue(ctx, each);
        }
        for (uint32_t i = 0;; i++) {
            JSValue each = JS_GetPropertyUint32(ctx, names, i);

            if (JS_IsUndefined(each)) {
                JS_FreeValue(ctx, each);
                break;
            }
            JS_FreeValue(ctx, each);
            at = i + 1;
        }
        JS_SetPropertyUint32(ctx, names, at, JS_NewString(ctx, wanted));
        JS_FreeCString(ctx, wanted);
    }
    classes_set(ctx, node, names);
    JS_FreeValue(ctx, names);
    return JS_UNDEFINED;
}

static JSValue js_class_remove(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = JS_GetOpaque(this_val, list_class);
    JSValue names, kept;

    if (!node)
        return JS_UNDEFINED;
    names = JS_NewArray(ctx);
    kept = JS_NewArray(ctx);
    classes_of(ctx, node, names);
    for (uint32_t i = 0, at = 0;; i++) {
        JSValue each = JS_GetPropertyUint32(ctx, names, i);

        if (JS_IsUndefined(each)) {
            JS_FreeValue(ctx, each);
            break;
        }
        if (!JS_StrictEq(ctx, each, argv[0]))
            JS_SetPropertyUint32(ctx, kept, at++, JS_DupValue(ctx, each));
        JS_FreeValue(ctx, each);
    }
    classes_set(ctx, node, kept);
    JS_FreeValue(ctx, kept);
    JS_FreeValue(ctx, names);
    return JS_UNDEFINED;
}

static JSValue js_class_has(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = JS_GetOpaque(this_val, list_class);
    JSValue names;
    bool found = false;

    if (!node)
        return JS_FALSE;
    names = JS_NewArray(ctx);
    classes_of(ctx, node, names);
    for (uint32_t i = 0;; i++) {
        JSValue each = JS_GetPropertyUint32(ctx, names, i);

        if (JS_IsUndefined(each)) {
            JS_FreeValue(ctx, each);
            break;
        }
        if (JS_StrictEq(ctx, each, argv[0]))
            found = true;
        JS_FreeValue(ctx, each);
    }
    JS_FreeValue(ctx, names);
    return JS_NewBool(ctx, found);
}

static JSValue js_class_toggle(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv)
{
    JSValue has = js_class_has(ctx, this_val, argc, argv);

    if (JS_ToBool(ctx, has))
        return js_class_remove(ctx, this_val, argc, argv);
    return js_class_add(ctx, this_val, argc, argv);
}

static const JSCFunctionListEntry list_methods[] = {
    JS_CFUNC_DEF("add", 1, js_class_add),
    JS_CFUNC_DEF("remove", 1, js_class_remove),
    JS_CFUNC_DEF("contains", 1, js_class_has),
    JS_CFUNC_DEF("toggle", 1, js_class_toggle),
};

static JSValue js_class_list(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);
    JSValue list;

    if (!node)
        return JS_UNDEFINED;
    list = JS_NewObjectClass(ctx, list_class);
    if (JS_IsException(list))
        return JS_UNDEFINED;
    JS_SetOpaque(list, node);
    JS_SetPropertyFunctionList(ctx, list, list_methods, countof(list_methods));
    classes_of(ctx, node, list);
    return list;
}

/// `element.style`: read and written as the page's own `style` attribute,
/// one declaration at a time.
static JSValue js_style(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);

    if (!node)
        return JS_UNDEFINED;
    return style_of(ctx, node);
}

static JSValue js_style_property(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv)
{
    const char *wanted;

    if (argc < 1)
        return JS_UNDEFINED;
    wanted = JS_ToCString(ctx, argv[0]);
    if (!wanted)
        return JS_UNDEFINED;
    JS_FreeCString(ctx, wanted);
    return JS_UNDEFINED;
}

static JSValue js_style_set(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = JS_GetOpaque(this_val, style_class);
    const char *name, *value;

    if (!node || argc < 2)
        return JS_UNDEFINED;
    name = JS_ToCString(ctx, argv[0]);
    value = JS_ToCString(ctx, argv[1]);
    if (name && value) {
        /* The page's own `style` attribute, with this one added or written
           over. */
        JSValue was = attr_of(ctx, node, "style");
        const char *before = JS_ToCString(ctx, was);
        char *after;

        if (before) {
            after = js_malloc(ctx, strlen(before) + strlen(name) + strlen(value) + 4);
            if (after) {
                sprintf(after, "%s%s%s: %s", before, before[0] ? " " : "", name, value);
                attr_set(ctx, node, "style", after);
                js_free(ctx, after);
            }
            JS_FreeCString(ctx, before);
        }
        JS_FreeValue(ctx, was);
    }
    JS_FreeCString(ctx, name);
    JS_FreeCString(ctx, value);
    return JS_UNDEFINED;
}

static const JSCFunctionListEntry style_methods[] = {
    JS_CFUNC_DEF("setProperty", 2, js_style_set),
    JS_CFUNC_DEF("getPropertyValue", 1, js_style_property),
};

static JSValue style_of(JSContext *ctx, lxb_dom_node_t *node)
{
    JSValue style = JS_NewObjectClass(ctx, style_class);

    if (JS_IsException(style))
        return JS_UNDEFINED;
    JS_SetOpaque(style, node);
    JS_SetPropertyFunctionList(ctx, style, style_methods, countof(style_methods));
    return style;
}

/* ------------------------------------------------------------------ */
/* Changing the tree                                                  */
/* ------------------------------------------------------------------ */

static JSValue js_append_child(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);
    lxb_dom_node_t *child = node_of(argv[0]);

    if (!node || !child)
        return JS_UNDEFINED;
    lxb_dom_node_append_child(node, child);
    changed(ctx);
    return JS_DupValue(ctx, argv[0]);
}

static JSValue js_insert_before(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);
    lxb_dom_node_t *child = node_of(argv[0]);
    lxb_dom_node_t *before = argc > 1 ? node_of(argv[1]) : NULL;

    if (!node || !child)
        return JS_UNDEFINED;
    if (before)
        lxb_dom_node_insert_before(before, child);
    else
        lxb_dom_node_append_child(node, child);
    changed(ctx);
    return JS_DupValue(ctx, argv[0]);
}

static JSValue js_remove_child(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv)
{
    lxb_dom_node_t *child = node_of(argv[0]);

    if (!child)
        return JS_UNDEFINED;
    lxb_dom_node_remove(child);
    changed(ctx);
    return JS_DupValue(ctx, argv[0]);
}

static JSValue js_replace_child(JSContext *ctx, JSValueConst this_val,
                                int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);
    lxb_dom_node_t *made = node_of(argv[0]);
    lxb_dom_node_t *gone = node_of(argv[1]);

    if (!node || !made || !gone)
        return JS_UNDEFINED;
    lxb_dom_node_insert_before(gone, made);
    lxb_dom_node_remove(gone);
    changed(ctx);
    return JS_DupValue(ctx, argv[1]);
}

static JSValue js_remove(JSContext *ctx, JSValueConst this_val,
                         int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);

    if (!node)
        return JS_UNDEFINED;
    lxb_dom_node_remove(node);
    changed(ctx);
    return JS_UNDEFINED;
}

/* ------------------------------------------------------------------ */
/* Finding elements                                                   */
/* ------------------------------------------------------------------ */

/// What a search turned up. Gathered first and made into an array after:
/// the callback lexbor calls is not the place to be building objects.
typedef struct Found {
    lxb_dom_node_t *nodes[256];
    size_t how_many;
} Found;

static lxb_status_t found_one(lxb_dom_node_t *node, lxb_css_selector_specificity_t spec,
                              void *context)
{
    Found *found = context;

    (void)spec;
    if (found->how_many < sizeof(found->nodes) / sizeof(found->nodes[0]))
        found->nodes[found->how_many++] = node;
    return LXB_STATUS_OK;
}

/// What was gathered: an array of elements, or the one element where one was
/// asked for, or nothing where the search found none.
static JSValue gathered(JSContext *ctx, Found *found, bool only_first)
{
    if (!found->how_many)
        return only_first ? JS_NULL : JS_NewArray(ctx);
    if (only_first)
        return node_of_tree(ctx, found->nodes[0]);
    JSValue out = JS_NewArray(ctx);

    for (size_t i = 0; i < found->how_many; i++)
        JS_SetPropertyUint32(ctx, out, (uint32_t)i, node_of_tree(ctx, found->nodes[i]));
    return out;
}

/// A selector a script wrote, as lexbor reads one. Null where it would not
/// parse, which a script sees as nothing found.
static lxb_css_selector_list_t *selector_of(JSContext *ctx, const char *text)
{
    Document *doc = held(ctx);
    lxb_css_selector_list_t *list;

    if (!doc)
        return NULL;
    lxb_css_parser_clean(doc->parser);
    list = lxb_css_selectors_parse(doc->parser, (const lxb_char_t *)text, strlen(text));
    return list;
}

static void selector_gone(JSContext *ctx, lxb_css_selector_list_t *list)
{
    Document *doc = held(ctx);

    if (doc && list)
        lxb_css_selector_list_destroy(list);
}

static JSValue js_query(JSContext *ctx, JSValueConst this_val,
                        int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);
    const char *wanted;
    JSValue out;

    if (!node)
        return JS_NULL;
    wanted = JS_ToCString(ctx, argv[0]);
    if (!wanted)
        return JS_EXCEPTION;
    out = JS_NULL;
    lxb_css_selector_list_t *list = selector_of(ctx, wanted);

    if (list) {
        Document *doc = held(ctx);
        Found found = {0};

        lxb_selectors_find(doc->selectors, node, list, found_one, &found);
        out = gathered(ctx, &found, true);
        selector_gone(ctx, list);
    }
    JS_FreeCString(ctx, wanted);
    return out;
}

static JSValue js_query_all(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);
    const char *wanted;
    JSValue out = JS_NewArray(ctx);

    if (!node)
        return out;
    wanted = JS_ToCString(ctx, argv[0]);
    if (!wanted)
        return JS_EXCEPTION;
    lxb_css_selector_list_t *list = selector_of(ctx, wanted);

    if (list) {
        Document *doc = held(ctx);
        Found found = {0};

        lxb_selectors_find(doc->selectors, node, list, found_one, &found);
        JS_FreeValue(ctx, out);
        out = gathered(ctx, &found, false);
        selector_gone(ctx, list);
    }
    JS_FreeCString(ctx, wanted);
    return out;
}

static JSValue js_matches(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);
    const char *wanted;
    bool it_does = false;

    if (!node)
        return JS_FALSE;
    wanted = JS_ToCString(ctx, argv[0]);
    if (!wanted)
        return JS_EXCEPTION;
    lxb_css_selector_list_t *list = selector_of(ctx, wanted);

    if (list) {
        Document *doc = held(ctx);
        Found found = {0};

        lxb_selectors_match_node(doc->selectors, node, list, found_one, &found);
        it_does = found.how_many > 0;
        selector_gone(ctx, list);
    }
    JS_FreeCString(ctx, wanted);
    return JS_NewBool(ctx, it_does);
}

static JSValue js_closest(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);

    if (!node)
        return JS_NULL;
    for (lxb_dom_node_t *at = node; at; at = lxb_dom_node_parent(at)) {
        JSValue one = node_of_tree(ctx, at);
        JSValue does = js_matches(ctx, one, argc, argv);
        bool yes = JS_ToBool(ctx, does);

        JS_FreeValue(ctx, does);
        if (yes)
            return one;
        JS_FreeValue(ctx, one);
    }
    return JS_NULL;
}

/* ------------------------------------------------------------------ */
/* Events                                                             */
/* ------------------------------------------------------------------ */

static JSValue js_add_listener(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    lxb_dom_node_t *node = node_of(this_val);
    const char *type;
    Watch *watch;

    if (!doc || !node || argc < 2 || !JS_IsFunction(ctx, argv[1]))
        return JS_UNDEFINED;
    type = JS_ToCString(ctx, argv[0]);
    if (!type)
        return JS_UNDEFINED;
    watch = js_malloc(ctx, sizeof(*watch));
    if (watch) {
        size_t taken = strlen(type) + 1;

        watch->node = node;
        watch->type = js_malloc(ctx, taken);
        if (watch->type)
            memcpy(watch->type, type, taken);
        watch->handler = JS_DupValue(ctx, argv[1]);
        watch->next = doc->watches;
        doc->watches = watch;
    }
    JS_FreeCString(ctx, type);
    return JS_UNDEFINED;
}

static JSValue js_prevent(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);

    if (doc)
        doc->prevented = true;
    return JS_UNDEFINED;
}

static const JSCFunctionListEntry event_methods[] = {
    JS_CFUNC_DEF("preventDefault", 0, js_prevent),
};

/// Tell `node`, and each thing it stands inside, that `type` has happened.
static void tell(JSContext *ctx, lxb_dom_node_t *node, const char *type, bool climb)
{
    Document *doc = held(ctx);

    if (!doc)
        return;
    doc->prevented = false;
    for (lxb_dom_node_t *at = node; at; at = climb ? lxb_dom_node_parent(at) : NULL) {
        JSValue event = JS_NewObjectClass(ctx, event_class);
        JSValue target = node_of_tree(ctx, node);
        Watch *watch;

        if (JS_IsException(event)) {
            JS_FreeValue(ctx, target);
            return;
        }
        JS_SetOpaque(event, NULL);
        JS_SetPropertyFunctionList(ctx, event, event_methods, countof(event_methods));
        JS_SetPropertyStr(ctx, event, "type", JS_NewString(ctx, type));
        JS_SetPropertyStr(ctx, event, "target", JS_DupValue(ctx, target));
        for (watch = doc->watches; watch; watch = watch->next) {
            JSValue called;

            if (watch->node != at || strcmp(watch->type, type) != 0)
                continue;
            called = JS_Call(ctx, watch->handler, target, 1, &event);
            if (JS_IsException(called))
                qjs_tell_error(ctx);
            JS_FreeValue(ctx, called);
        }
        JS_FreeValue(ctx, target);
        JS_FreeValue(ctx, event);
    }
}

/* ------------------------------------------------------------------ */
/* An element's own properties                                        */
/* ------------------------------------------------------------------ */

static JSValue js_id(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);

    if (!node)
        return JS_UNDEFINED;
    return attr_of(ctx, node, "id");
}

static JSValue js_set_id(JSContext *ctx, JSValueConst this_val, JSValueConst value)
{
    const char *text;

    if (!node_of(this_val))
        return JS_UNDEFINED;
    text = JS_ToCString(ctx, value);
    if (text) {
        attr_set(ctx, node_of(this_val), "id", text);
        JS_FreeCString(ctx, text);
    }
    return JS_UNDEFINED;
}

static JSValue js_class_name(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);

    if (!node)
        return JS_UNDEFINED;
    return attr_of(ctx, node, "class");
}

static JSValue js_set_class_name(JSContext *ctx, JSValueConst this_val, JSValueConst value)
{
    const char *text;

    if (!node_of(this_val))
        return JS_UNDEFINED;
    text = JS_ToCString(ctx, value);
    if (text) {
        attr_set(ctx, node_of(this_val), "class", text);
        JS_FreeCString(ctx, text);
    }
    return JS_UNDEFINED;
}

static JSValue js_tag_name(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);
    size_t length = 0;
    const lxb_char_t *name;

    if (!node)
        return JS_UNDEFINED;
    name = lxb_dom_element_tag_name(lxb_dom_interface_element(node), &length);
    if (!name)
        return JS_UNDEFINED;
    return JS_NewStringLen(ctx, (const char *)name, length);
}

static JSValue js_parent(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);
    lxb_dom_node_t *above;

    if (!node)
        return JS_NULL;
    above = lxb_dom_node_parent(node);
    if (!above)
        return JS_NULL;
    return node_of_tree(ctx, above);
}

static JSValue js_children(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);
    JSValue out = JS_NewArray(ctx);
    uint32_t at = 0;

    if (!node)
        return out;
    for (lxb_dom_node_t *each = lxb_dom_node_first_child(node); each;
         each = lxb_dom_node_next(each)) {
        if (each->type != LXB_DOM_NODE_TYPE_ELEMENT)
            continue;
        JS_SetPropertyUint32(ctx, out, at++, node_of_tree(ctx, each));
    }
    return out;
}

static JSValue js_child_nodes(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);
    JSValue out = JS_NewArray(ctx);
    uint32_t at = 0;

    if (!node)
        return out;
    for (lxb_dom_node_t *each = lxb_dom_node_first_child(node); each;
         each = lxb_dom_node_next(each)) {
        JS_SetPropertyUint32(ctx, out, at++, node_of_tree(ctx, each));
    }
    return out;
}

static JSValue js_first_child(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);
    lxb_dom_node_t *each;

    if (!node)
        return JS_NULL;
    each = lxb_dom_node_first_child(node);
    if (!each)
        return JS_NULL;
    return node_of_tree(ctx, each);
}

static JSValue js_last_child(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);
    lxb_dom_node_t *each, *last = NULL;

    if (!node)
        return JS_NULL;
    for (each = lxb_dom_node_first_child(node); each; each = lxb_dom_node_next(each))
        last = each;
    if (!last)
        return JS_NULL;
    return node_of_tree(ctx, last);
}

static JSValue js_next_sibling(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);
    lxb_dom_node_t *each;

    if (!node)
        return JS_NULL;
    for (each = lxb_dom_node_next(node); each; each = lxb_dom_node_next(each)) {
        if (each->type == LXB_DOM_NODE_TYPE_ELEMENT)
            return node_of_tree(ctx, each);
    }
    return JS_NULL;
}

static JSValue js_previous_sibling(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);
    lxb_dom_node_t *each;

    if (!node)
        return JS_NULL;
    for (each = lxb_dom_node_prev(node); each; each = lxb_dom_node_prev(each)) {
        if (each->type == LXB_DOM_NODE_TYPE_ELEMENT)
            return node_of_tree(ctx, each);
    }
    return JS_NULL;
}

/// What a control holds, which is the `value` a page reads and writes.
static JSValue js_value(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);

    if (!node)
        return JS_UNDEFINED;
    return attr_of(ctx, node, "value");
}

static JSValue js_set_value(JSContext *ctx, JSValueConst this_val, JSValueConst value)
{
    const char *text;

    if (!node_of(this_val))
        return JS_UNDEFINED;
    text = JS_ToCString(ctx, value);
    if (text) {
        attr_set(ctx, node_of(this_val), "value", text);
        JS_FreeCString(ctx, text);
    }
    return JS_UNDEFINED;
}

static JSValue js_flag(JSContext *ctx, JSValueConst this_val, const char *name)
{
    lxb_dom_node_t *node = node_of(this_val);
    bool set = false;

    if (!node)
        return JS_FALSE;
    set = lxb_dom_element_has_attribute(lxb_dom_interface_element(node),
                                        (const lxb_char_t *)name, strlen(name));
    return JS_NewBool(ctx, set);
}

static JSValue js_set_flag(JSContext *ctx, JSValueConst this_val,
                           JSValueConst value, const char *name)
{
    lxb_dom_node_t *node = node_of(this_val);

    if (!node)
        return JS_UNDEFINED;
    if (JS_ToBool(ctx, value)) {
        attr_set(ctx, node, name, "");
    } else {
        lxb_dom_element_remove_attribute(lxb_dom_interface_element(node),
                                         (const lxb_char_t *)name, strlen(name));
        changed(ctx);
    }
    return JS_UNDEFINED;
}

static JSValue js_checked(JSContext *ctx, JSValueConst this_val)
{
    return js_flag(ctx, this_val, "checked");
}

static JSValue js_set_checked(JSContext *ctx, JSValueConst this_val, JSValueConst value)
{
    return js_set_flag(ctx, this_val, value, "checked");
}

static JSValue js_disabled(JSContext *ctx, JSValueConst this_val)
{
    return js_flag(ctx, this_val, "disabled");
}

static JSValue js_hidden(JSContext *ctx, JSValueConst this_val)
{
    return js_flag(ctx, this_val, "hidden");
}

static JSValue js_set_hidden(JSContext *ctx, JSValueConst this_val, JSValueConst value)
{
    return js_set_flag(ctx, this_val, value, "hidden");
}

static JSValue js_href(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);

    if (!node)
        return JS_NULL;
    return attr_of(ctx, node, "href");
}

static JSValue js_src(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);

    if (!node)
        return JS_NULL;
    return attr_of(ctx, node, "src");
}

static JSValue js_node_type(JSContext *ctx, JSValueConst this_val)
{
    lxb_dom_node_t *node = node_of(this_val);

    if (!node)
        return JS_UNDEFINED;
    return JS_NewInt32(ctx, (int)node->type);
}

/// Nothing at all, for what a page asks that cannot be: given rather than
/// left out, since a script that finds no `getComputedStyle` stops where one
/// that finds an empty one goes on.
static JSValue js_nothing(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv)
{
    return JS_UNDEFINED;
}

/// A size and a place, as nothing: this reader sets a page in one column and
/// keeps no geometry, so where something is, is noughts rather than a guess.
static JSValue js_box(JSContext *ctx, JSValueConst this_val,
                      int argc, JSValueConst *argv)
{
    JSValue box = JS_NewObject(ctx);

    for (const char *const *at = (const char *const []){ "x", "y", "width", "height",
                                                        "top", "left", "right", "bottom",
                                                        NULL };
         *at; at++) {
        JS_SetPropertyStr(ctx, box, *at, JS_NewInt32(ctx, 0));
    }
    return box;
}

/* ------------------------------------------------------------------ */
/* What a page keeps: cookies, and what it puts by for later           */
/* ------------------------------------------------------------------ */

static Crumb *crumb_of(Document *doc, const char *name)
{
    for (Crumb *at = doc->crumbs; at; at = at->next) {
        if (strcmp(at->name, name) == 0)
            return at;
    }
    return NULL;
}

static void crumb_set(JSContext *ctx, Document *doc, const char *name, const char *value)
{
    Crumb *crumb = crumb_of(doc, name);

    if (!crumb) {
        crumb = js_malloc(ctx, sizeof(*crumb));
        if (!crumb)
            return;
        memset(crumb, 0, sizeof(*crumb));
        crumb->name = strdup(name);
        crumb->domain = strdup(doc->address);
        crumb->path = strdup("/");
        crumb->next = doc->crumbs;
        doc->crumbs = crumb;
    }
    js_free(ctx, crumb->value);
    crumb->value = strdup(value ? value : "");
}

static JSValue js_cookie(JSContext *ctx, JSValueConst this_val)
{
    Document *doc = held(ctx);
    size_t length = 0;
    char *text;
    JSValue out;

    if (!doc)
        return JS_NewString(ctx, "");
    for (Crumb *at = doc->crumbs; at; at = at->next)
        length += strlen(at->name) + strlen(at->value) + 3;
    text = js_malloc(ctx, length + 1);
    if (!text)
        return JS_NewString(ctx, "");
    text[0] = 0;
    for (Crumb *at = doc->crumbs; at; at = at->next) {
        strcat(text, at->name);
        strcat(text, "=");
        strcat(text, at->value);
        if (at->next)
            strcat(text, "; ");
    }
    out = JS_NewString(ctx, text);
    js_free(ctx, text);
    return out;
}

static JSValue js_set_cookie(JSContext *ctx, JSValueConst this_val, JSValueConst value)
{
    Document *doc = held(ctx);
    const char *text;

    if (!doc)
        return JS_UNDEFINED;
    text = JS_ToCString(ctx, value);
    if (text) {
        /* `name=value`, and whatever the page wrote after it, which this
           reader does not keep: no path, no domain, no day it ends. */
        const char *equals = strchr(text, '=');
        size_t name_length = equals ? (size_t)(equals - text) : strlen(text);
        char *name = js_malloc(ctx, name_length + 1);

        if (name) {
            memcpy(name, text, name_length);
            name[name_length] = 0;
            crumb_set(ctx, doc, name, equals ? equals + 1 : "");
            js_free(ctx, name);
        }
        changed(ctx);
        JS_FreeCString(ctx, text);
    }
    return JS_UNDEFINED;
}

static Stored *stored_of(Document *doc, const char *key)
{
    for (Stored *at = doc->stored; at; at = at->next) {
        if (strcmp(at->key, key) == 0)
            return at;
    }
    return NULL;
}

static JSValue js_store_get(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    const char *key;
    Stored *found;

    if (!doc)
        return JS_NULL;
    key = JS_ToCString(ctx, argv[0]);
    if (!key)
        return JS_NULL;
    found = stored_of(doc, key);
    JS_FreeCString(ctx, key);
    if (!found)
        return JS_NULL;
    return JS_NewString(ctx, found->value);
}

static JSValue js_store_set(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    const char *key, *value;
    Stored *found;

    if (!doc)
        return JS_UNDEFINED;
    key = JS_ToCString(ctx, argv[0]);
    value = JS_ToCString(ctx, argv[1]);
    if (!key || !value)
        return JS_UNDEFINED;
    found = stored_of(doc, key);
    if (found) {
        js_free(ctx, found->value);
        found->value = strdup(value);
    } else {
        found = js_malloc(ctx, sizeof(*found));
        if (found) {
            found->key = strdup(key);
            found->value = strdup(value);
            found->next = doc->stored;
            doc->stored = found;
        }
    }
    JS_FreeCString(ctx, key);
    JS_FreeCString(ctx, value);
    return JS_UNDEFINED;
}

static const JSCFunctionListEntry store_methods[] = {
    JS_CFUNC_DEF("getItem", 1, js_store_get),
    JS_CFUNC_DEF("setItem", 2, js_store_set),
};

/* ------------------------------------------------------------------ */
/* Asking for a page of your own                                       */
/* ------------------------------------------------------------------ */

static const char *answer_of(JSContext *ctx, JSValueConst this_val)
{
    JSValue body = JS_GetPropertyStr(ctx, this_val, "__body");
    const char *text = JS_ToCString(ctx, body);

    JS_FreeValue(ctx, body);
    return text;
}

static JSValue js_answer_text(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv)
{
    const char *text = answer_of(ctx, this_val);
    JSValue out;

    if (!text)
        return JS_NewString(ctx, "");
    out = JS_NewString(ctx, text);
    JS_FreeCString(ctx, text);
    return out;
}

static JSValue js_answer_json(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv)
{
    const char *text = answer_of(ctx, this_val);
    JSValue out;

    if (!text)
        return JS_UNDEFINED;
    out = JS_ParseJSON(ctx, text, strlen(text), "<fetch>");
    JS_FreeCString(ctx, text);
    return out;
}

static const JSCFunctionListEntry answer_methods[] = {
    JS_CFUNC_DEF("text", 0, js_answer_text),
    JS_CFUNC_DEF("json", 0, js_answer_json),
};

/// `fetch`: ask for a page, and come back with it. The asking is done there
/// and then rather than in the background, the reader having one way in and
/// out of the network and a script's next line often wanting the answer.
static JSValue js_fetch(JSContext *ctx, JSValueConst this_val,
                        int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    JSValue answer, promise, resolved;
    JSValue resolvers[2];
    const char *address;
    char *body;

    if (!doc || !doc->fetch)
        return JS_UNDEFINED;
    address = JS_ToCString(ctx, argv[0]);
    if (!address)
        return JS_EXCEPTION;
    body = doc->fetch(doc->fetch_taken, address);
    JS_FreeCString(ctx, address);

    answer = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, answer, answer_methods, countof(answer_methods));
    JS_SetPropertyStr(ctx, answer, "ok", JS_NewBool(ctx, body != NULL));
    JS_SetPropertyStr(ctx, answer, "status", JS_NewInt32(ctx, body ? 200 : 0));
    JS_SetPropertyStr(ctx, answer, "__body", JS_NewString(ctx, body ? body : ""));
    free(body);

    promise = JS_NewPromiseCapability(ctx, resolvers);
    resolved = JS_Call(ctx, resolvers[0], JS_UNDEFINED, 1, &answer);
    JS_FreeValue(ctx, resolved);
    JS_FreeValue(ctx, resolvers[0]);
    JS_FreeValue(ctx, resolvers[1]);
    JS_FreeValue(ctx, answer);
    return promise;
}

/// `XMLHttpRequest`, for a page that asks the older way: opened, then sent,
/// and the answer is there when `send` comes back, for the reason `fetch` is.
static JSValue js_xhr_open(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv)
{
    const char *address = JS_ToCString(ctx, argv[1]);

    if (!address)
        return JS_UNDEFINED;
    JS_SetPropertyStr(ctx, this_val, "__url", JS_NewString(ctx, address));
    JS_FreeCString(ctx, address);
    JS_SetPropertyStr(ctx, this_val, "readyState", JS_NewInt32(ctx, 1));
    return JS_UNDEFINED;
}

static JSValue js_xhr_send(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    JSValue asked = JS_GetPropertyStr(ctx, this_val, "__url");
    const char *address = JS_ToCString(ctx, asked);
    char *body = NULL;

    JS_FreeValue(ctx, asked);
    if (doc && doc->fetch && address)
        body = doc->fetch(doc->fetch_taken, address);
    JS_FreeCString(ctx, address);

    JS_SetPropertyStr(ctx, this_val, "readyState", JS_NewInt32(ctx, 4));
    JS_SetPropertyStr(ctx, this_val, "status", JS_NewInt32(ctx, body ? 200 : 0));
    JS_SetPropertyStr(ctx, this_val, "responseText", JS_NewString(ctx, body ? body : ""));
    free(body);

    /* What the page asked to be told with, where it asked. */
    for (const char *const *at = (const char *const []){ "onreadystatechange", "onload", NULL };
         *at; at++) {
        JSValue told = JS_GetPropertyStr(ctx, this_val, *at);

        if (JS_IsFunction(ctx, told))
            JS_FreeValue(ctx, JS_Call(ctx, told, this_val, 0, NULL));
        JS_FreeValue(ctx, told);
    }
    return JS_UNDEFINED;
}

static const JSCFunctionListEntry xhr_methods[] = {
    JS_CFUNC_DEF("open", 2, js_xhr_open),
    JS_CFUNC_DEF("send", 0, js_xhr_send),
};

static JSValue js_new_xhr(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv)
{
    JSValue request = JS_NewObject(ctx);

    JS_SetPropertyFunctionList(ctx, request, xhr_methods, countof(xhr_methods));
    JS_SetPropertyStr(ctx, request, "readyState", JS_NewInt32(ctx, 0));
    return request;
}

/* ------------------------------------------------------------------ */
/* What a page asks for and this reader has nothing to say about       */
/* ------------------------------------------------------------------ */

/// The style a page has been given, read as an empty one: what the cascade
/// made of it is not a thing a script can be told here yet.
static JSValue js_computed(JSContext *ctx, JSValueConst this_val,
                           int argc, JSValueConst *argv)
{
    JSValue style = JS_NewObject(ctx);

    JS_SetPropertyStr(ctx, style, "getPropertyValue",
                      JS_NewCFunction(ctx, js_style_property, "getPropertyValue", 1));
    return style;
}

/// An observer: a page may watch for something to happen, and nothing it can
/// watch for ever happens here, so it is given one that watches and is silent.
static JSValue js_watcher(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv)
{
    JSValue watcher = JS_NewObject(ctx);

    for (const char *const *at = (const char *const []){ "observe", "unobserve",
                                                        "disconnect", "takeRecords", NULL };
         *at; at++) {
        JS_SetPropertyStr(ctx, watcher, *at, JS_NewCFunction(ctx, js_nothing, *at, 0));
    }
    return watcher;
}

/// An element clicked by a script, which is the same click as one upon it.
static JSValue js_click(JSContext *ctx, JSValueConst this_val,
                        int argc, JSValueConst *argv)
{
    lxb_dom_node_t *node = node_of(this_val);

    if (node)
        tell(ctx, node, "click", true);
    return JS_UNDEFINED;
}

static const JSCFunctionListEntry node_methods[] = {
    JS_CFUNC_DEF("getAttribute", 1, js_get_attribute),
    JS_CFUNC_DEF("setAttribute", 2, js_set_attribute),
    JS_CFUNC_DEF("hasAttribute", 1, js_has_attribute),
    JS_CFUNC_DEF("removeAttribute", 1, js_remove_attribute),
    JS_CFUNC_DEF("toggleAttribute", 1, js_toggle_attribute),
    JS_CFUNC_DEF("appendChild", 1, js_append_child),
    JS_CFUNC_DEF("insertBefore", 2, js_insert_before),
    JS_CFUNC_DEF("removeChild", 1, js_remove_child),
    JS_CFUNC_DEF("replaceChild", 2, js_replace_child),
    JS_CFUNC_DEF("remove", 0, js_remove),
    JS_CFUNC_DEF("addEventListener", 2, js_add_listener),
    JS_CFUNC_DEF("querySelector", 1, js_query),
    JS_CFUNC_DEF("querySelectorAll", 1, js_query_all),
    JS_CFUNC_DEF("matches", 1, js_matches),
    JS_CFUNC_DEF("closest", 1, js_closest),
    JS_CFUNC_DEF("click", 0, js_click),
    JS_CFUNC_DEF("getBoundingClientRect", 0, js_box),
    JS_CFUNC_DEF("scrollIntoView", 0, js_nothing),
    JS_CFUNC_DEF("focus", 0, js_nothing),
    JS_CFUNC_DEF("blur", 0, js_nothing),
};

static const JSCFunctionListEntry node_gets[] = {
    JS_CGETSET_DEF("textContent", js_text_content, js_set_text_content),
    JS_CGETSET_DEF("innerHTML", js_inner_html, js_set_inner_html),
    JS_CGETSET_DEF("id", js_id, js_set_id),
    JS_CGETSET_DEF("className", js_class_name, js_set_class_name),
    JS_CGETSET_DEF("classList", js_class_list, NULL),
    JS_CGETSET_DEF("style", js_style, NULL),
    JS_CGETSET_DEF("tagName", js_tag_name, NULL),
    JS_CGETSET_DEF("nodeName", js_tag_name, NULL),
    JS_CGETSET_DEF("nodeType", js_node_type, NULL),
    JS_CGETSET_DEF("parentNode", js_parent, NULL),
    JS_CGETSET_DEF("parentElement", js_parent, NULL),
    JS_CGETSET_DEF("children", js_children, NULL),
    JS_CGETSET_DEF("childNodes", js_child_nodes, NULL),
    JS_CGETSET_DEF("firstChild", js_first_child, NULL),
    JS_CGETSET_DEF("lastChild", js_last_child, NULL),
    JS_CGETSET_DEF("firstElementChild", js_first_child, NULL),
    JS_CGETSET_DEF("lastElementChild", js_last_child, NULL),
    JS_CGETSET_DEF("nextElementSibling", js_next_sibling, NULL),
    JS_CGETSET_DEF("previousElementSibling", js_previous_sibling, NULL),
    JS_CGETSET_DEF("value", js_value, js_set_value),
    JS_CGETSET_DEF("checked", js_checked, js_set_checked),
    JS_CGETSET_DEF("disabled", js_disabled, NULL),
    JS_CGETSET_DEF("hidden", js_hidden, js_set_hidden),
    JS_CGETSET_DEF("href", js_href, NULL),
    JS_CGETSET_DEF("src", js_src, NULL),
};

static void nothing_gone(JSRuntime *rt, JSValue value)
{
    (void)rt;
    (void)value;
}

static JSValue node_of_tree(JSContext *ctx, lxb_dom_node_t *node)
{
    JSValue object = JS_NewObjectClass(ctx, node_class);

    if (JS_IsException(object))
        return object;
    JS_SetOpaque(object, node);
    JS_SetPropertyFunctionList(ctx, object, node_methods, countof(node_methods));
    JS_SetPropertyFunctionList(ctx, object, node_gets, countof(node_gets));
    return object;
}

/* ------------------------------------------------------------------ */
/* The document                                                       */
/* ------------------------------------------------------------------ */

static JSValue found_of(JSContext *ctx, lxb_dom_collection_t *found, bool only_first)
{
    size_t how_many = lxb_dom_collection_length(found);

    if (only_first) {
        if (!how_many)
            return JS_NULL;
        return node_of_tree(ctx, lxb_dom_interface_node(lxb_dom_collection_element(found, 0)));
    }
    JSValue out = JS_NewArray(ctx);

    for (size_t i = 0; i < how_many; i++) {
        JS_SetPropertyUint32(ctx, out, (uint32_t)i,
                             node_of_tree(ctx, lxb_dom_interface_node(
                                                   lxb_dom_collection_element(found, i))));
    }
    return out;
}

static JSValue js_get_by_id(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    const char *wanted;
    JSValue out = JS_NULL;
    lxb_dom_collection_t *found;

    if (!doc)
        return JS_NULL;
    wanted = JS_ToCString(ctx, argv[0]);
    if (!wanted)
        return JS_EXCEPTION;
    found = lxb_dom_collection_create(doc->tree);
    if (found && lxb_dom_collection_init(found, 4) == LXB_STATUS_OK &&
        lxb_dom_elements_by_attr(lxb_dom_interface_element(lxb_dom_interface_node(
                                     lxb_dom_document_root(doc->tree))),
                                 found, (const lxb_char_t *)"id", 2,
                                 (const lxb_char_t *)wanted, strlen(wanted),
                                 false) == LXB_STATUS_OK) {
        out = found_of(ctx, found, true);
    }
    if (found)
        lxb_dom_collection_destroy(found, true);
    JS_FreeCString(ctx, wanted);
    return out;
}

static JSValue js_get_by_tag(JSContext *ctx, JSValueConst this_val,
                             int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    const char *wanted;
    JSValue out = JS_NewArray(ctx);
    lxb_dom_collection_t *found;

    if (!doc)
        return out;
    wanted = JS_ToCString(ctx, argv[0]);
    if (!wanted)
        return JS_EXCEPTION;
    found = lxb_dom_collection_create(doc->tree);
    if (found && lxb_dom_collection_init(found, 16) == LXB_STATUS_OK &&
        lxb_dom_elements_by_tag_name(lxb_dom_interface_element(lxb_dom_interface_node(
                                         lxb_dom_document_root(doc->tree))),
                                     found, (const lxb_char_t *)wanted,
                                     strlen(wanted)) == LXB_STATUS_OK) {
        JS_FreeValue(ctx, out);
        out = found_of(ctx, found, false);
    }
    if (found)
        lxb_dom_collection_destroy(found, true);
    JS_FreeCString(ctx, wanted);
    return out;
}

static JSValue js_get_by_class(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    const char *wanted;
    JSValue out = JS_NewArray(ctx);
    lxb_dom_collection_t *found;

    if (!doc)
        return out;
    wanted = JS_ToCString(ctx, argv[0]);
    if (!wanted)
        return JS_EXCEPTION;
    found = lxb_dom_collection_create(doc->tree);
    if (found && lxb_dom_collection_init(found, 16) == LXB_STATUS_OK &&
        lxb_dom_elements_by_class_name(lxb_dom_interface_element(lxb_dom_interface_node(
                                           lxb_dom_document_root(doc->tree))),
                                       found, (const lxb_char_t *)wanted,
                                       strlen(wanted)) == LXB_STATUS_OK) {
        JS_FreeValue(ctx, out);
        out = found_of(ctx, found, false);
    }
    if (found)
        lxb_dom_collection_destroy(found, true);
    JS_FreeCString(ctx, wanted);
    return out;
}

static JSValue js_document_query(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    JSValue root;

    if (!doc)
        return JS_NULL;
    root = node_of_tree(ctx, lxb_dom_interface_node(lxb_dom_document_root(doc->tree)));
    JSValue out = js_query(ctx, root, argc, argv);

    JS_FreeValue(ctx, root);
    return out;
}

static JSValue js_document_query_all(JSContext *ctx, JSValueConst this_val,
                                     int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    JSValue root;

    if (!doc)
        return JS_NewArray(ctx);
    root = node_of_tree(ctx, lxb_dom_interface_node(lxb_dom_document_root(doc->tree)));
    JSValue out = js_query_all(ctx, root, argc, argv);

    JS_FreeValue(ctx, root);
    return out;
}

static JSValue js_create_element(JSContext *ctx, JSValueConst this_val,
                                 int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    lxb_dom_element_t *made;
    const char *tag;
    JSValue out = JS_UNDEFINED;

    if (!doc)
        return JS_UNDEFINED;
    tag = JS_ToCString(ctx, argv[0]);
    if (!tag)
        return JS_EXCEPTION;
    made = lxb_dom_document_create_element(doc->tree, (const lxb_char_t *)tag,
                                           strlen(tag), NULL);
    if (made)
        out = node_of_tree(ctx, lxb_dom_interface_node(made));
    JS_FreeCString(ctx, tag);
    return out;
}

static JSValue js_create_text(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    lxb_dom_text_t *made;
    const char *text;
    JSValue out = JS_UNDEFINED;

    if (!doc)
        return JS_UNDEFINED;
    text = JS_ToCString(ctx, argv[0]);
    if (!text)
        return JS_EXCEPTION;
    made = lxb_dom_document_create_text_node(doc->tree, (const lxb_char_t *)text,
                                             strlen(text));
    if (made)
        out = node_of_tree(ctx, lxb_dom_interface_node(made));
    JS_FreeCString(ctx, text);
    return out;
}

/// The title, which is what the page's own `<title>` element holds. Found
/// rather than asked for: asking the document for one before the parser has
/// settled it is a way to fall over.
static lxb_dom_element_t *title_of(Document *doc)
{
    lxb_dom_collection_t *found;
    lxb_dom_element_t *title = NULL;

    found = lxb_dom_collection_create(doc->tree);
    if (!found || lxb_dom_collection_init(found, 2) != LXB_STATUS_OK)
        return NULL;
    if (lxb_dom_elements_by_tag_name(lxb_dom_interface_element(lxb_dom_interface_node(
                                         lxb_dom_document_root(doc->tree))),
                                     found, (const lxb_char_t *)"title", 5) == LXB_STATUS_OK &&
        lxb_dom_collection_length(found) > 0) {
        title = lxb_dom_collection_element(found, 0);
    }
    lxb_dom_collection_destroy(found, true);
    return title;
}

static JSValue js_title(JSContext *ctx, JSValueConst this_val)
{
    Document *doc = held(ctx);
    lxb_dom_element_t *title;

    if (!doc)
        return JS_UNDEFINED;
    title = title_of(doc);
    if (!title)
        return JS_NewString(ctx, "");
    return text_of(ctx, lxb_dom_interface_node(title));
}

static JSValue js_set_title(JSContext *ctx, JSValueConst this_val, JSValueConst value)
{
    Document *doc = held(ctx);
    lxb_dom_element_t *title;
    const char *text;

    if (!doc)
        return JS_UNDEFINED;
    text = JS_ToCString(ctx, value);
    if (text) {
        title = title_of(doc);
        if (title) {
            lxb_dom_node_text_content_set(lxb_dom_interface_node(title),
                                          (const lxb_char_t *)text, strlen(text));
            changed(ctx);
        }
        JS_FreeCString(ctx, text);
    }
    return JS_UNDEFINED;
}

static JSValue js_root(JSContext *ctx, JSValueConst this_val)
{
    Document *doc = held(ctx);

    if (!doc)
        return JS_NULL;
    return node_of_tree(ctx, lxb_dom_interface_node(lxb_dom_document_root(doc->tree)));
}

static JSValue js_body(JSContext *ctx, JSValueConst this_val)
{
    Document *doc = held(ctx);
    lxb_html_document_t *page = (lxb_html_document_t *)doc->tree;
    lxb_html_body_element_t *body;

    if (!doc)
        return JS_NULL;
    body = lxb_html_document_body_element(page);
    if (!body)
        return JS_NULL;
    return node_of_tree(ctx, lxb_dom_interface_node(body));
}

static JSValue js_head(JSContext *ctx, JSValueConst this_val)
{
    Document *doc = held(ctx);
    lxb_html_document_t *page = (lxb_html_document_t *)doc->tree;
    lxb_html_head_element_t *head;

    if (!doc)
        return JS_NULL;
    head = lxb_html_document_head_element(page);
    if (!head)
        return JS_NULL;
    return node_of_tree(ctx, lxb_dom_interface_node(head));
}

static const JSCFunctionListEntry document_methods[] = {
    JS_CFUNC_DEF("getElementById", 1, js_get_by_id),
    JS_CFUNC_DEF("getElementsByTagName", 1, js_get_by_tag),
    JS_CFUNC_DEF("getElementsByClassName", 1, js_get_by_class),
    JS_CFUNC_DEF("querySelector", 1, js_document_query),
    JS_CFUNC_DEF("querySelectorAll", 1, js_document_query_all),
    JS_CFUNC_DEF("createElement", 1, js_create_element),
    JS_CFUNC_DEF("createTextNode", 1, js_create_text),
    JS_CFUNC_DEF("addEventListener", 2, js_add_listener),
};

static const JSCFunctionListEntry document_gets[] = {
    JS_CGETSET_DEF("title", js_title, js_set_title),
    JS_CGETSET_DEF("cookie", js_cookie, js_set_cookie),
    JS_CGETSET_DEF("documentElement", js_root, NULL),
    JS_CGETSET_DEF("body", js_body, NULL),
    JS_CGETSET_DEF("head", js_head, NULL),
};

/* ------------------------------------------------------------------ */
/* Later, and where it is                                             */
/* ------------------------------------------------------------------ */

/// The clock, in thousandths of a second since the machine was started: 32
/// bits, because this machine does its sums in 32 bits, and a clock that
/// turns over after six weeks is no hardship to a page.
static unsigned int now_ms(void)
{
    struct timespec at;

    if (clock_gettime(CLOCK_MONOTONIC, &at) != 0)
        return 0;
    return (unsigned int)at.tv_sec * 1000u + (unsigned int)(at.tv_nsec / 1000000);
}

static JSValue js_set_timer(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    Timer *timer;
    int after = 0;

    if (!doc || argc < 2 || !JS_IsFunction(ctx, argv[0]))
        return JS_UNDEFINED;
    JS_ToInt32(ctx, &after, argv[1]);
    timer = js_malloc(ctx, sizeof(*timer));
    if (!timer)
        return JS_UNDEFINED;
    timer->id = ++doc->next_timer;
    timer->handler = JS_DupValue(ctx, argv[0]);
    timer->due = now_ms() + (unsigned int)(after > 0 ? after : 0);
    timer->every = 0;
    timer->next = doc->timers;
    doc->timers = timer;
    return JS_NewInt32(ctx, timer->id);
}

static JSValue js_set_interval(JSContext *ctx, JSValueConst this_val,
                               int argc, JSValueConst *argv)
{
    JSValue made = js_set_timer(ctx, this_val, argc, argv);
    Document *doc = held(ctx);
    int after = 0;

    if (doc && doc->timers && !JS_IsException(made)) {
        JS_ToInt32(ctx, &after, argv[1]);
        doc->timers->every = (unsigned int)(after > 0 ? after : 0);
    }
    return made;
}

static JSValue js_clear_timer(JSContext *ctx, JSValueConst this_val,
                              int argc, JSValueConst *argv)
{
    Document *doc = held(ctx);
    Timer **at;
    int wanted = 0;

    if (!doc)
        return JS_UNDEFINED;
    JS_ToInt32(ctx, &wanted, argv[0]);
    for (at = &doc->timers; *at; at = &(*at)->next) {
        Timer *timer = *at;

        if (timer->id != wanted)
            continue;
        *at = timer->next;
        JS_FreeValue(ctx, timer->handler);
        js_free(ctx, timer);
        return JS_UNDEFINED;
    }
    return JS_UNDEFINED;
}

/// Where the page is, as a script asks: the whole address, and the parts of
/// it a page picks apart.
static void bind_where(JSContext *ctx, JSValue into, const char *address)
{
    const char *after = strstr(address, "://");
    const char *path = after ? after + 3 : address;
    const char *slash = path ? strchr(path, '/') : NULL;
    const char *query = strchr(address, '?');
    const char *hash = strchr(address, '#');
    size_t host_length = slash ? (size_t)(slash - path) : strlen(path);

    JS_SetPropertyStr(ctx, into, "href", JS_NewString(ctx, address));
    if (after)
        JS_SetPropertyStr(ctx, into, "protocol",
                          JS_NewStringLen(ctx, address, (size_t)(after - address)));
    if (host_length) {
        JS_SetPropertyStr(ctx, into, "host", JS_NewStringLen(ctx, path, host_length));
        JS_SetPropertyStr(ctx, into, "hostname", JS_NewStringLen(ctx, path, host_length));
    }
    if (slash) {
        size_t length = query ? (size_t)(query - slash) : (hash ? (size_t)(hash - slash) : strlen(slash));

        JS_SetPropertyStr(ctx, into, "pathname", JS_NewStringLen(ctx, slash, length));
    } else {
        JS_SetPropertyStr(ctx, into, "pathname", JS_NewString(ctx, "/"));
    }
    JS_SetPropertyStr(ctx, into, "search", JS_NewString(ctx, query ? query : ""));
    JS_SetPropertyStr(ctx, into, "hash", JS_NewString(ctx, hash ? hash : ""));
    if (after) {
        JS_SetPropertyStr(ctx, into, "origin",
                          JS_NewStringLen(ctx, address,
                                          (size_t)(path - address) + host_length));
    }
}

/* ------------------------------------------------------------------ */
/* Binding, loading, dispatch                                         */
/* ------------------------------------------------------------------ */

bool dom_bind(struct JSContext *ctx, struct lxb_dom_document *document,
              const char *address, const char *user_agent,
              dom_fetch_f fetch, void *fetch_taken)
{
    static const JSClassDef node_kind = { .class_name = "Node", .finalizer = nothing_gone };
    static const JSClassDef list_kind = { .class_name = "ClassList", .finalizer = nothing_gone };
    static const JSClassDef style_kind = { .class_name = "Style", .finalizer = nothing_gone };
    static const JSClassDef event_kind = { .class_name = "Event", .finalizer = nothing_gone };
    JSRuntime *rt = JS_GetRuntime(ctx);
    JSValue global, page, where, who;
    Document *doc;
    size_t taken;

    JS_NewClassID(&node_class);
    JS_NewClass(rt, node_class, &node_kind);
    JS_NewClassID(&list_class);
    JS_NewClass(rt, list_class, &list_kind);
    JS_NewClassID(&style_class);
    JS_NewClass(rt, style_class, &style_kind);
    JS_NewClassID(&event_class);
    JS_NewClass(rt, event_class, &event_kind);

    doc = js_malloc(ctx, sizeof(*doc));
    if (!doc)
        return false;
    memset(doc, 0, sizeof(*doc));
    doc->tree = document;
    doc->fetch = fetch;
    doc->fetch_taken = fetch_taken;
    taken = strlen(address) + 1;
    doc->address = js_malloc(ctx, taken);
    if (doc->address)
        memcpy(doc->address, address, taken);
    /* Lexbor's own selectors engine, for `querySelector` and `matches`: the
       same one the cascade is read with, so a selector means one thing here
       whatever it is written for. */
    doc->css_memory = lxb_css_memory_create();
    doc->parser = lxb_css_parser_create();
    if (doc->parser) {
        lxb_css_parser_init(doc->parser, NULL);
        lxb_css_parser_selectors_init(doc->parser);
    }
    doc->selectors = lxb_selectors_create();
    if (doc->selectors)
        lxb_selectors_init(doc->selectors);
    JS_SetRuntimeOpaque(rt, doc);

    global = JS_GetGlobalObject(ctx);
    page = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, page, document_methods, countof(document_methods));
    JS_SetPropertyFunctionList(ctx, page, document_gets, countof(document_gets));
    JS_SetOpaque(page, NULL);
    JS_SetPropertyStr(ctx, global, "document", page);
    JS_SetPropertyStr(ctx, global, "window", JS_DupValue(ctx, global));

    where = JS_NewObject(ctx);
    bind_where(ctx, where, address);
    JS_SetPropertyStr(ctx, global, "location", where);

    who = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, who, "userAgent", JS_NewString(ctx, user_agent));
    JS_SetPropertyStr(ctx, global, "navigator", who);

    JS_SetPropertyStr(ctx, global, "setTimeout",
                      JS_NewCFunction(ctx, js_set_timer, "setTimeout", 2));
    JS_SetPropertyStr(ctx, global, "setInterval",
                      JS_NewCFunction(ctx, js_set_interval, "setInterval", 2));
    JS_SetPropertyStr(ctx, global, "clearTimeout",
                      JS_NewCFunction(ctx, js_clear_timer, "clearTimeout", 1));
    JS_SetPropertyStr(ctx, global, "clearInterval",
                      JS_NewCFunction(ctx, js_clear_timer, "clearInterval", 1));

    JS_SetPropertyStr(ctx, global, "fetch",
                      JS_NewCFunction(ctx, js_fetch, "fetch", 1));
    JS_SetPropertyStr(ctx, global, "XMLHttpRequest",
                      JS_NewCFunction(ctx, js_new_xhr, "XMLHttpRequest", 0));
    {
        JSValue store = JS_NewObject(ctx);

        JS_SetPropertyFunctionList(ctx, store, store_methods, countof(store_methods));
        JS_SetPropertyStr(ctx, global, "localStorage", store);
        JS_SetPropertyStr(ctx, global, "sessionStorage", JS_DupValue(ctx, store));
    }
    JS_SetPropertyStr(ctx, global, "getComputedStyle",
                      JS_NewCFunction(ctx, js_computed, "getComputedStyle", 1));
    JS_SetPropertyStr(ctx, global, "requestAnimationFrame",
                      JS_NewCFunction(ctx, js_set_timer, "requestAnimationFrame", 1));
    JS_SetPropertyStr(ctx, global, "queueMicrotask",
                      JS_NewCFunction(ctx, js_set_timer, "queueMicrotask", 1));
    for (const char *const *at = (const char *const []){ "MutationObserver",
                                                        "IntersectionObserver",
                                                        "ResizeObserver", NULL };
         *at; at++) {
        JS_SetPropertyStr(ctx, global, *at, JS_NewCFunction(ctx, js_watcher, *at, 0));
    }
    JS_FreeValue(ctx, global);
    return true;
}

void dom_release(struct JSContext *ctx)
{
    Document *doc = held(ctx);

    if (!doc)
        return;
    while (doc->watches) {
        Watch *watch = doc->watches;

        doc->watches = watch->next;
        JS_FreeValue(ctx, watch->handler);
        js_free(ctx, watch->type);
        js_free(ctx, watch);
    }
    while (doc->timers) {
        Timer *timer = doc->timers;

        doc->timers = timer->next;
        JS_FreeValue(ctx, timer->handler);
        js_free(ctx, timer);
    }
    while (doc->crumbs) {
        Crumb *crumb = doc->crumbs;

        doc->crumbs = crumb->next;
        js_free(ctx, crumb->name);
        js_free(ctx, crumb->value);
        js_free(ctx, crumb->domain);
        js_free(ctx, crumb->path);
        js_free(ctx, crumb);
    }
    while (doc->stored) {
        Stored *each = doc->stored;

        doc->stored = each->next;
        js_free(ctx, each->key);
        js_free(ctx, each->value);
        js_free(ctx, each);
    }
    if (doc->selectors)
        lxb_selectors_destroy(doc->selectors, true);
    if (doc->parser) {
        lxb_css_parser_selectors_destroy(doc->parser);
        lxb_css_parser_destroy(doc->parser, true);
    }
    if (doc->css_memory)
        lxb_css_memory_destroy(doc->css_memory, true);
    js_free(ctx, doc->address);
    js_free(ctx, doc);
    JS_SetRuntimeOpaque(JS_GetRuntime(ctx), NULL);
}

void dom_load(struct JSContext *ctx, struct lxb_dom_document *document)
{
    lxb_dom_collection_t *found;

    found = lxb_dom_collection_create(document);
    if (!found || lxb_dom_collection_init(found, 8) != LXB_STATUS_OK)
        return;
    if (lxb_dom_elements_by_tag_name(lxb_dom_interface_element(lxb_dom_interface_node(
                                         lxb_dom_document_root(document))),
                                     found, (const lxb_char_t *)"script", 6) == LXB_STATUS_OK) {
        for (size_t i = 0; i < lxb_dom_collection_length(found); i++) {
            lxb_dom_node_t *node = lxb_dom_interface_node(lxb_dom_collection_element(found, i));
            size_t length = 0;
            lxb_char_t *text;

            /* Only a script written in the page: one that names a file of its
               own is a fetch this reader does not make for it yet. */
            if (lxb_dom_element_get_attribute(lxb_dom_interface_element(node),
                                              (const lxb_char_t *)"src", 3, NULL))
                continue;
            text = lxb_dom_node_text_content(node, &length);
            if (!text || !length)
                continue;
            if (JS_IsException(JS_Eval(ctx, (const char *)text, length, "<script>",
                                       JS_EVAL_TYPE_GLOBAL))) {
                qjs_tell_error(ctx);
                break;
            }
        }
    }
    lxb_dom_collection_destroy(found, true);
    /* The document is ready, which is what a page waits for: first the one
       the parser says, then the one that says everything has come. */
    tell(ctx, lxb_dom_interface_node(lxb_dom_document_root(document)), "DOMContentLoaded", true);
    tell(ctx, lxb_dom_interface_node(lxb_dom_document_root(document)), "load", true);
}

bool dom_click(struct JSContext *ctx, struct lxb_dom_node *node)
{
    Document *doc = held(ctx);

    if (!doc)
        return false;
    tell(ctx, node, "click", true);
    return doc->prevented;
}

void dom_changed_at(struct JSContext *ctx, struct lxb_dom_node *node, bool sent)
{
    tell(ctx, node, "input", false);
    tell(ctx, node, "change", false);
    if (sent)
        tell(ctx, node, "submit", true);
}

bool dom_changed(struct JSContext *ctx)
{
    Document *doc = held(ctx);
    bool was;

    if (!doc)
        return false;
    was = doc->changed;
    doc->changed = false;
    return was;
}

bool dom_loop(struct JSContext *ctx)
{
    Document *doc = held(ctx);
    unsigned int now = now_ms();
    Timer **at;
    bool ran = false;

    qjs_loop(ctx);
    if (!doc)
        return false;
    for (at = &doc->timers; *at;) {
        Timer *timer = *at;

        if (timer->due > now) {
            at = &timer->next;
            continue;
        }
        JSValue called = JS_Call(ctx, timer->handler, JS_UNDEFINED, 0, NULL);

        if (JS_IsException(called))
            qjs_tell_error(ctx);
        JS_FreeValue(ctx, called);
        ran = true;
        if (timer->every) {
            timer->due = now + timer->every;
            at = &timer->next;
            continue;
        }
        *at = timer->next;
        JS_FreeValue(ctx, timer->handler);
        js_free(ctx, timer);
    }
    return ran;
}

char *dom_cookies_for(struct JSContext *ctx, const char *host, const char *path)
{
    Document *doc = held(ctx);
    size_t length = 0;
    char *out;

    (void)path;
    if (!doc || !host)
        return NULL;
    for (Crumb *at = doc->crumbs; at; at = at->next) {
        if (strstr(at->domain, host))
            length += strlen(at->name) + strlen(at->value) + 3;
    }
    if (!length)
        return NULL;
    out = malloc(length + 1);
    if (!out)
        return NULL;
    out[0] = 0;
    for (Crumb *at = doc->crumbs; at; at = at->next) {
        if (!strstr(at->domain, host))
            continue;
        strcat(out, at->name);
        strcat(out, "=");
        strcat(out, at->value);
        if (at->next)
            strcat(out, "; ");
    }
    return out;
}

bool dom_waits(struct JSContext *ctx, unsigned int *in_ms)
{
    Document *doc = held(ctx);
    unsigned int now = now_ms();
    Timer *timer;
    bool any = false;

    if (!doc)
        return false;
    for (timer = doc->timers; timer; timer = timer->next) {
        unsigned int wait = timer->due > now ? timer->due - now : 0;

        if (any && wait >= *in_ms)
            continue;
        *in_ms = wait;
        any = true;
    }
    return any;
}

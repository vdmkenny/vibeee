//! What the document a script sees must do, checked on this machine.
//!
//! QuickJS, lexbor and `dom.c` compiled for the host, a page written here, a
//! script in it, and what the tree reads as afterwards. It is a C file
//! reaching into two vendored trees, which is exactly the part the reader's
//! Zig tests cannot see, and the part every mistake so far was in: a value
//! handed to the wrong kind of call, a callback that gathered nothing, a
//! title asked for before the parser had settled it.
//!
//! Each case is a page, a script, and the value the script ends in, which is
//! what `qjs_run` answers. Keeping the answer in the script rather than
//! reading it back out of the tree is what makes a case one line long, and
//! the tree is checked as a whole in the last few.

#include <stdio.h>
#include <string.h>
#include <time.h>

#include "lexbor/html/html.h"

#include "quickjs.h"
#include "engine.h"
#include "dom.h"

static int failures = 0;
static int checks = 0;
/// One engine for the whole run, a context per page: as a reader has it.
static JSRuntime *machine;

static JSContext *page_of(lxb_html_document_t *page)
{
    JSContext *ctx = qjs_open(machine);

    if (ctx)
        dom_bind(ctx, (lxb_dom_document_t *)page, "https://example.org/", "vibeee-web/1.0 test");
    return ctx;
}

/// Open the engine on `markup`, and run `script` in it. Answers the value the
/// script ended in, which the caller shows and compares, or "(exception)".
static char *run(const char *markup, const char *script)
{
    lxb_html_document_t *page = lxb_html_document_create();
    JSContext *ctx;
    char *out;

    lxb_html_document_parse(page, (lxb_char_t *)markup, strlen(markup));
    ctx = page_of(page);
    dom_load(ctx, (lxb_dom_document_t *)page);
    out = qjs_run(ctx, script, strlen(script), "<script>", 0);
    if (!out)
        out = strdup("(exception)");
    dom_release(ctx);
    qjs_close(ctx);
    lxb_html_document_destroy(page);
    return out;
}

/// Say what a script ended in, and whether that is what it should be.
static void says(const char *what, const char *markup, const char *script, const char *want)
{
    char *got = run(markup, script);

    checks += 1;
    if (got && strcmp(got, want) == 0) {
        printf("  ok   %s\n", what);
        return;
    }
    failures += 1;
    printf("  FAIL %s\n       want \"%s\"\n       got  \"%s\"\n", what, want, got ? got : "(nothing)");
    free(got);
}

/// The tree as it reads after the scripts in `markup` have run.
static char *body_of(const char *markup)
{
    lxb_html_document_t *page = lxb_html_document_create();
    JSContext *ctx;
    lexbor_str_t text = {0};
    char *out;

    lxb_html_document_parse(page, (lxb_char_t *)markup, strlen(markup));
    ctx = page_of(page);
    dom_load(ctx, (lxb_dom_document_t *)page);
    if (lxb_html_document_body_element(page)) {
        lxb_html_serialize_tree_str(
            lxb_dom_interface_node(lxb_html_document_body_element(page)), &text);
    }
    out = text.data ? strndup((const char *)text.data, text.length) : strdup("");
    lexbor_str_destroy(&text, lxb_dom_interface_document(page)->text, false);
    dom_release(ctx);
    qjs_close(ctx);
    lxb_html_document_destroy(page);
    return out;
}

static void reads(const char *what, const char *markup, const char *want)
{
    char *got = body_of(markup);

    checks += 1;
    if (got && strstr(got, want)) {
        printf("  ok   %s\n", what);
        free(got);
        return;
    }
    failures += 1;
    printf("  FAIL %s\n       want it to contain \"%s\"\n       got  \"%s\"\n", what, want,
           got ? got : "(nothing)");
    free(got);
}

static const char *const page =
    "<html><head><title>Before</title></head><body>"
    "<p id=\"one\" class=\"old\">hello</p>"
    "<ul id=\"list\"><li>a</li><li>b</li></ul>"
    "%s"
    "</body></html>";

/// A page with `script` in it.
static char *with(const char *script)
{
    static char markup[4096];

    snprintf(markup, sizeof(markup), page, script);
    return markup;
}

int main(void)
{
    char markup[4096];

    machine = qjs_start();
    if (!machine) {
        printf("dom: the engine would not start\n");
        return 1;
    }
    printf("dom: what a script sees\n");

    says("an element is found by its id", with(""),
         "document.getElementById('one').textContent", "hello");
    says("its tag is named as a tag is", with(""),
         "document.getElementById('one').tagName", "P");
    says("text is written into it", with(""),
         "var e = document.getElementById('one'); e.textContent = 'said'; e.textContent",
         "said");
    says("a class is added", with(""),
         "var e = document.getElementById('one'); e.classList.add('noted'); e.className",
         "old noted");
    says("a class it has is said to be there", with(""),
         "document.getElementById('one').classList.contains('old')", "true");
    says("an attribute is set and read", with(""),
         "var e = document.getElementById('one'); e.setAttribute('lang', 'en'); "
         "e.getAttribute('lang')",
         "en");
    says("an attribute is taken away", with(""),
         "var e = document.getElementById('one'); e.removeAttribute('class'); "
         "e.hasAttribute('class')",
         "false");

    says("every element of a kind is found", with(""),
         "document.getElementsByTagName('li').length", "2");
    says("every element of a class is found", with(""),
         "document.getElementsByClassName('old').length", "1");
    says("a selector finds them all", with(""),
         "document.querySelectorAll('li').length", "2");
    says("a selector finds one", with(""),
         "document.querySelector('#one').textContent", "hello");
    says("a selector finds by class", with(""),
         "document.querySelectorAll('.old').length", "1");
    says("an element says whether it matches", with(""),
         "document.getElementById('one').matches('p.old')", "true");
    says("the nearest ancestor matching is found", with(""),
         "document.getElementById('one').closest('body').tagName", "BODY");

    says("an element is made and put somewhere", with(""),
         "var li = document.createElement('li'); li.textContent = 'c'; "
         "document.getElementById('list').appendChild(li); "
         "document.getElementsByTagName('li').length",
         "3");
    says("an element takes itself away", with(""),
         "var li = document.querySelector('li'); li.remove(); "
         "document.getElementsByTagName('li').length",
         "1");
    says("markup is written and read", with(""),
         "var p = document.createElement('p'); p.innerHTML = '<b>made</b>'; p.innerHTML",
         "<b>made</b>");

    says("the title is read", with(""), "document.title", "Before");
    says("the title is written", with(""),
         "document.title = 'After'; document.title", "After");

    says("the page says where it is", with(""), "location.href", "https://example.org/");
    says("and which part of it", with(""), "location.pathname", "/");
    says("and what the reader is called", with(""),
         "navigator.userAgent", "vibeee-web/1.0 test");

    reads("a script has changed the page",
          with("<script>document.getElementById('one').textContent = 'changed';</script>"),
          "<p id=\"one\" class=\"old\">changed</p>");
    reads("a script has added to the page",
          with("<script>var p = document.createElement('p'); p.textContent = 'new'; "
               "document.body.appendChild(p);</script>"),
          "<p>new</p>");

    /* Timers: what a page leaves waiting runs when the window is idle. */
    snprintf(markup, sizeof(markup),
             "<html><body><p id=\"one\">a</p><script>setTimeout(function () { "
             "document.getElementById('one').textContent = 'later'; }, 10);</script></body></html>");
    {
        lxb_html_document_t *page = lxb_html_document_create();
        JSContext *ctx;
        struct timespec pause = {0, 20000000};

        lxb_html_document_parse(page, (lxb_char_t *)markup, strlen(markup));
        ctx = page_of(page);
        dom_load(ctx, (lxb_dom_document_t *)page);
        nanosleep(&pause, NULL);
        dom_loop(ctx);
        checks += 1;
        if (dom_changed(ctx)) {
            printf("  ok   what a script left waiting ran, and said so\n");
        } else {
            failures += 1;
            printf("  FAIL what a script left waiting ran, and said so\n");
        }
        dom_release(ctx);
        qjs_close(ctx);
        lxb_html_document_destroy(page);
    }

    printf("dom: %d of %d passed\n", checks - failures, checks);
    /* The runtime is left standing: see `engine.h`. */
    (void)machine;
    return failures ? 1 : 0;
}

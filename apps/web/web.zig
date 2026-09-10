//! web: read a page.
//!
//! What is here is the parser working and nothing above it yet: a document
//! goes in, its title and its text come out. The window, the address and the
//! chrome are the next thing, and this file is what proves the ground they
//! will stand on.
//!
//! The parser is lexbor, vendored under `third_party/lexbor` and compiled in
//! the way netd compiles lwIP. What was taken is the HTML and DOM modules and
//! nothing else: this reader sets a page in its own two faces, so a cascade
//! decides nothing, and the character-set tables upstream ships are a
//! megabyte before a page is fetched.
//!
//! Not part of the system. It is built into `home/bin/` and versioned on its
//! own.

const std = @import("std");
const sys = @import("sys");
const ulib = @import("ulib");

const env = ulib.env;
const file = ulib.file;
const heap = ulib.heap;
const out = ulib.out;

const lexbor = @import("lexbor.zig");

// The routines lexbor's C calls by name.
comptime {
    _ = @import("clibc");
}

/// The largest page this will read.
///
/// A page beyond it is refused rather than truncated: half a document parses
/// into a tree that is wrong in ways nothing downstream can see, and a reader
/// that quietly showed you the first half of an article would be worse than
/// one that said it could not.
const PAGE_MAX: usize = 1024 * 1024;

export fn _start(frame: [*]usize) callconv(.c) noreturn {
    const path = env.argument(frame) orelse {
        out.trouble("web: a page to read: web <file.html>\n");
        sys.exit(2);
    };

    const facts = file.factsOf(path) orelse {
        out.fault("web", path, "cannot open");
        sys.exit(1);
    };
    if (facts.size > PAGE_MAX) {
        out.fault("web", path, "larger than this reads");
        sys.exit(1);
    }

    const page = heap.allocator.alloc(u8, facts.size) catch {
        out.fault("web", path, "no room to read it");
        sys.exit(1);
    };
    defer heap.allocator.free(page);

    const got = file.readWhole(path, page) orelse {
        out.fault("web", path, "cannot read");
        sys.exit(1);
    };

    read(page[0..got]);
    sys.exit(0);
}

/// Parse `html` and say what came of it.
fn read(html: []const u8) void {
    const document = lexbor.lxb_html_document_create() orelse {
        out.trouble("web: the parser would not start\n");
        return;
    };
    defer _ = lexbor.lxb_html_document_destroy(document);

    const status = lexbor.lxb_html_document_parse(document, html.ptr, html.len);
    if (!status.worked()) {
        out.trouble("web: this is not a page it can read\n");
        return;
    }

    if (lexbor.titleOf(document)) |title| {
        out.text("title: ");
        out.text(title);
        out.byte('\n');
    }

    // A document's own text content is nothing, by the specification: what
    // is wanted is under it. So the tree is walked.
    walk(lexbor.nodeOf(document));
    out.byte('\n');
    out.flush();
}

/// Put the readable text under `root` on the output, in document order.
///
/// Depth first, following the links the mirror pins. What a script or a
/// stylesheet holds is text in the tree like any other and is not text on a
/// page, so those are stepped over whole.
fn walk(root: *lexbor.Node) void {
    var node: ?*lexbor.Node = root.first_child;
    var depth: usize = 0;

    while (node) |here| {
        var descend = true;

        switch (here.type) {
            .text => if (lexbor.textOf(here)) |text| out.text(text),
            .element => {
                if (lexbor.tagOf(here)) |tag| {
                    if (tag.machineOnly()) descend = false;
                }
            },
            else => {},
        }

        if (descend) {
            if (here.first_child) |child| {
                node = child;
                depth += 1;
                continue;
            }
        }

        // Up and along: the next sibling of the nearest ancestor that has
        // one, stopping where the walk began rather than climbing past it.
        var climbing: *lexbor.Node = here;
        while (true) {
            if (climbing.next) |sibling| {
                node = sibling;
                break;
            }
            if (depth == 0) {
                node = null;
                break;
            }
            climbing = climbing.parent orelse {
                node = null;
                break;
            };
            depth -= 1;
        }
    }
}

//! A page as it came, and what it reads as.
//!
//! What arrived is kept for as long as the page is shown: its markup, where it
//! came from, and the stylesheets it links to as they came. A page is read
//! from these in one place however it arrived: parsed with its cascade, its
//! stylesheets applied for the window it is read for, and its words walked
//! into a `page`. When the window changes size, its stylesheets are asked
//! first whether the page reads any differently in the new one, which is
//! whether one of their media blocks, or the media a link names, answers
//! differently, and only then is it read again.

const std = @import("std");
const charset = @import("charset.zig");
const css = @import("css.zig");
const extract = @import("extract.zig");
const lexbor = @import("lexbor.zig");
const media = @import("media.zig");
const page_mod = @import("page.zig");
const url = @import("url.zig");

const Allocator = std.mem.Allocator;
const Page = page_mod.Page;

/// Why a page's markup could not be read.
pub const Error = error{
    OutOfMemory,
    /// The parser would not take it.
    Unparsable,
};

pub const Source = struct {
    /// The markup, as it arrived.
    bytes: std.ArrayList(u8) = .empty,
    /// Where it came from, which its links and stylesheets are resolved
    /// against.
    base: url.Address = .{},
    /// The encoding the site said it is in, where it said one.
    declared: ?charset.Charset = null,
    /// Whether it is read with its cascade.
    styled: bool = false,
    /// Its stylesheets as they came, in the order the page names them.
    sheets: std.ArrayList(Sheet) = .empty,

    pub const Sheet = struct {
        text: []u8,
        /// The media its link names, empty for every medium.
        media: []u8,
    };

    pub fn deinit(self: *Source, gpa: Allocator) void {
        self.bytes.deinit(gpa);
        for (self.sheets.items) |sheet| {
            gpa.free(sheet.text);
            gpa.free(sheet.media);
        }
        self.sheets.deinit(gpa);
        self.* = .{};
    }

    /// Keep a stylesheet that came, whose text the source takes, linked for
    /// `asked`.
    pub fn keep(self: *Source, gpa: Allocator, text: []u8, asked: []const u8) void {
        const kept = gpa.dupe(u8, asked) catch return gpa.free(text);
        self.sheets.append(gpa, .{ .text = text, .media = kept }) catch {
            gpa.free(text);
            gpa.free(kept);
        };
    }

    /// Whether the page reads alike in windows `a` and `b`.
    pub fn readsAlike(self: *const Source, a: ?media.Screen, b: ?media.Screen) bool {
        if (!self.styled) return true;
        for (self.sheets.items) |sheet| {
            const in_a = media.matches(sheet.media, a);
            if (in_a != media.matches(sheet.media, b)) return false;
            if (in_a and media.outcomes(sheet.text, a) != media.outcomes(sheet.text, b)) return false;
        }
        return true;
    }

    /// The page as it reads in `screen`, into `page`.
    pub fn read(self: *const Source, gpa: Allocator, screen: ?media.Screen, page: *Page) Error!void {
        var tree = try Tree.parse(gpa, self);
        defer tree.close();
        try tree.read(gpa, self, screen, page);
    }
};

/// A page's markup parsed, with its cascade where it is read with one.
pub const Tree = struct {
    document: *lexbor.Document,
    styled: bool,
    /// The encoding the markup turned out to be in, which is the one its
    /// forms answer in.
    encoding: charset.Charset,

    pub fn parse(gpa: Allocator, source: *const Source) Error!Tree {
        // The parser reads UTF-8 and nothing else, and neither does the page.
        const bytes = source.bytes.items;
        const encoding = charset.sniff(source.declared, bytes);
        const text = try charset.utf8Of(gpa, bytes, encoding);
        defer text.deinit(gpa);
        const utf8 = text.bytes();

        const document = lexbor.lxb_html_document_create() orelse return error.OutOfMemory;
        var tree = Tree{ .document = document, .styled = false, .encoding = encoding };
        errdefer tree.close();
        if (source.styled) {
            try check(lexbor.lxb_style_init(document));
            tree.styled = true;
        }
        try check(lexbor.lxb_html_document_parse(document, utf8.ptr, utf8.len));
        return tree;
    }

    pub fn close(self: *Tree) void {
        if (self.styled) lexbor.lxb_style_destroy(self.document);
        _ = lexbor.lxb_html_document_destroy(self.document);
    }

    /// The stylesheets it links to that could be for a window, to fetch.
    pub fn sheets(self: *const Tree, gpa: Allocator, base: url.Url, into: *css.Sheets) Allocator.Error!void {
        if (self.styled) try css.sheetsOf(gpa, self.document, base, into);
    }

    /// Where it names a version of itself for small screens, written into
    /// `buf`.
    pub fn mobile(self: *const Tree, base: url.Url, buf: *[url.ADDRESS_MAX]u8) ?[]const u8 {
        return extract.mobileVersion(self.document, base, buf);
    }

    /// Its words, read into `page` with `source`'s stylesheets applied as
    /// they read in `screen`.
    pub fn read(self: *Tree, gpa: Allocator, source: *const Source, screen: ?media.Screen, page: *Page) Error!void {
        for (source.sheets.items) |sheet| {
            if (media.matches(sheet.media, screen)) css.apply(gpa, self.document, sheet.text, screen);
        }
        const base = url.parse(source.base.slice()) orelse return error.Unparsable;
        page.encoding = self.encoding;
        try extract.extract(gpa, self.document, base, page);
    }
};

fn check(status: lexbor.Status) Error!void {
    return switch (status) {
        .ok => {},
        .no_memory => error.OutOfMemory,
        _ => error.Unparsable,
    };
}

//! Every way the browser can fail to show what was asked for, and what each
//! is called: a heading and a sentence for the page that says so, and the
//! few words a shell line has room for. One table, so that the window and
//! the shell never say two different things about one failure.

const std = @import("std");
const ulib = @import("ulib");

const fetch_mod = @import("fetch.zig");
const form_mod = @import("form.zig");
const source_mod = @import("source.zig");

const file = ulib.file;

/// Why what arrived could not be read as a page.
pub const ReadError = source_mod.Error || error{
    /// It is something other than a page.
    NotAPage,
};

pub const Failure = fetch_mod.Failure || file.AllocError || ReadError || error{
    NotAnAddress,
    /// A form whose answers come to more than this browser sends.
    LongForm,
};

pub const Told = struct { heading: []const u8, detail: []const u8, word: []const u8 };

/// `subject` is what the failure is about: the site, the file, or what was
/// typed. The sentences that name it are written into `buf`.
pub fn told(why: Failure, subject: []const u8, buf: []u8) Told {
    return switch (why) {
        error.NotAnAddress, error.BadAddress => .{
            .heading = "That is not an address",
            .detail = "An address is a site's name, like example.org, a whole address beginning with http:// or https://, or a file on this machine.",
            .word = "not an address",
        },
        error.NoName => .{
            .heading = "Nothing answers to that name",
            .detail = sentence(buf, "{s} is not a name the network knows. It may be misspelt, or this machine may not be connected.", .{subject}),
            .word = "no such name",
        },
        error.Unreachable => .{
            .heading = "The site could not be reached",
            .detail = sentence(buf, "{s} did not answer. It may be down, or not listening where it was asked.", .{subject}),
            .word = "could not reach it",
        },
        error.Refused => .{
            .heading = "No shared way to encrypt this",
            .detail = sentence(buf, "{s} and this browser could not agree on a sealed connection ({s}), so nothing was sent.", .{ subject, ulib.wire.refusal() }),
            .word = "the sealed connection was refused",
        },
        error.NoClock => .{
            .heading = "The clock is not set",
            .detail = "A sealed page cannot be read until it is: a certificate's dates mean nothing without it.",
            .word = "the clock is not set",
        },
        error.NoAuthorities => .{
            .heading = "The certificate authorities could not be read",
            .detail = "They are kept in " ++ ulib.wire.AUTHORITIES ++ ", and a sealed page cannot be checked without them.",
            .word = "the certificate authorities could not be read",
        },
        error.NoRandomness => .{
            .heading = "Not enough randomness yet",
            .detail = "The machine has not gathered enough to seal a connection with. Try again in a moment.",
            .word = "not enough randomness to seal with",
        },
        error.HeadTooLong, error.Malformed => .{
            .heading = "That was not a page",
            .detail = sentence(buf, "{s} answered with something that is not HTTP.", .{subject}),
            .word = "not HTTP",
        },
        error.TooLarge, error.TooBig => .{
            .heading = "This is too large",
            .detail = std.fmt.comptimePrint("It is over {d} MB, which is more than this browser reads.", .{fetch_mod.PAGE_MAX / (1024 * 1024)}),
            .word = "larger than this reads",
        },
        error.Truncated => .{
            .heading = "The page was cut short",
            .detail = "The connection ended before all of it arrived.",
            .word = "cut short",
        },
        error.Unanswered => .{
            .heading = "The site did not answer",
            .detail = sentence(buf, "{s} closed the connection without sending anything back.", .{subject}),
            .word = "closed without answering",
        },
        error.Blocked => .{
            .heading = "This site is kept from",
            .detail = sentence(buf, "{s} is on the browser's blocklist: the sites that serve ads, and those that count and follow the people reading. Ad protection, in the menu at the end of the strip, turns the list off.", .{subject}),
            .word = "on the blocklist",
        },
        error.RedirectLoop => .{
            .heading = "Sent round in circles",
            .detail = sentence(buf, "{s} kept sending the request on somewhere else.", .{subject}),
            .word = "sent round in circles",
        },
        error.Stalled => .{
            .heading = "The site stopped answering",
            .detail = std.fmt.comptimePrint("Nothing arrived for {d} seconds, so the browser gave up waiting.", .{fetch_mod.STALL_US / std.time.us_per_s}),
            .word = "stopped answering",
        },
        error.OutOfMemory => .{
            .heading = "Not enough memory",
            .detail = "This needs more memory than the machine has free.",
            .word = "not enough memory",
        },
        error.NoFile => .{ .heading = "There is no such file", .detail = subject, .word = "no such file" },
        error.Unreadable => .{ .heading = "This file could not be read", .detail = subject, .word = "cannot read it" },
        error.Unparsable => .{
            .heading = "This page could not be read",
            .detail = "The parser would not take it.",
            .word = "the parser would not take it",
        },
        error.NotAPage => .{ .heading = "This is not a page", .detail = subject, .word = "not a page" },
        error.LongForm => .{
            .heading = "This form sends too much",
            .detail = std.fmt.comptimePrint("Its answers come to more than {d} KB, which is more than this browser sends. One that sends a file, or pages of words, is such a form.", .{form_mod.ANSWERS_MAX / 1024}),
            .word = "the form sends too much",
        },
    };
}

/// A sentence naming a subject, in `buf`; the subject alone where the
/// sentence would not fit.
fn sentence(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, fmt, args) catch args[0];
}

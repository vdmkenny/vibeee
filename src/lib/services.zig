//! What the system's own services are called, and what a name may be.
//!
//! In `lib` because both halves need the same answer. The kernel decides who
//! may take a name and must not be told the list by the programs it is
//! deciding about; userspace names the service it is connecting to and would
//! otherwise spell it a second time. One list, and a program that renames a
//! service without the kernel noticing is not something that can happen.
//!
//! A name outside this list is anybody's: a program may publish whatever it
//! likes under its own name, which is what makes a service something an
//! ordinary program can be. Only the names the system's own parts answer to
//! are held back, because a program that took one would be answering questions
//! meant for the settings store or the desktop.
//!
//! Pure and host-tested: what may be registered is a rule, and a rule is a
//! thing to check here rather than on a machine.

const std = @import("std");

/// Longest a name may be. A name appears in log lines, in `etc/services` and
/// in the registry's fixed table, so it is bounded once here.
pub const MAX_NAME = 24;

/// The names the system's own services answer to.
///
/// Taking one of these means being the settings store, or the desktop, or the
/// thing that starts everything else: it is the whole of what a program would
/// need to do to read every setting a machine holds or every key its owner
/// types. Registering one takes the `service` capability, which `etc/services`
/// grants to the programs that are those things.
pub const RESERVED = [_][]const u8{
    "audio",
    "cfg",
    "devices",
    "gui",
    "init",
    "net",
    "platform",
    "usb",
};

/// Whether a name is one of the system's own.
pub fn isReserved(name: []const u8) bool {
    for (RESERVED) |held| {
        if (std.mem.eql(u8, held, name)) return true;
    }
    return false;
}

/// Whether a name can be registered at all, by anybody.
///
/// Lowercase, digits, dot and dash. Restrictive because a service name appears
/// in log lines and config files, and a name that needs quoting is a name that
/// will eventually be quoted wrongly.
pub fn isValidName(name: []const u8) bool {
    if (name.len == 0 or name.len > MAX_NAME) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '.' or c == '-';
        if (!ok) return false;
    }
    return true;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "the system's own names are held back and others are not" {
    for (RESERVED) |held| try testing.expect(isReserved(held));

    // A program's own name is its own business.
    try testing.expect(!isReserved("probe"));
    try testing.expect(!isReserved("my-editor"));
    try testing.expect(!isReserved(""));

    // Whole names only: a name that merely starts with a reserved one, or
    // contains it, is not that service.
    try testing.expect(!isReserved("cfgd"));
    try testing.expect(!isReserved("net-tools"));
    try testing.expect(!isReserved("my-gui"));
}

test "every reserved name is one that could be registered" {
    // A held-back name that nothing could have registered anyway would be a
    // line in the list doing nothing.
    for (RESERVED) |held| try testing.expect(isValidName(held));
}

test "the list is in order and says each name once" {
    // Sorted so a name can be found by eye, and so adding one to the middle
    // rather than the end stays obvious in a diff.
    for (RESERVED[0 .. RESERVED.len - 1], RESERVED[1..]) |before, after| {
        try testing.expect(std.mem.order(u8, before, after) == .lt);
    }
}

test "a name is what it may be spelled with" {
    try testing.expect(isValidName("cfg"));
    try testing.expect(isValidName("my.service-2"));
    try testing.expect(isValidName("a"));

    try testing.expect(!isValidName(""));
    try testing.expect(!isValidName("Cfg"));
    try testing.expect(!isValidName("my service"));
    try testing.expect(!isValidName("my_service"));
    try testing.expect(!isValidName("/cfg"));
    try testing.expect(!isValidName("cfg\x00"));

    // A name that would not fit the registry's own storage.
    try testing.expect(isValidName("a" ** MAX_NAME));
    try testing.expect(!isValidName("a" ** (MAX_NAME + 1)));
}

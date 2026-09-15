//! The parts of the protocol that can be checked without a machine.
//!
//! Most of a protocol is wire types: shapes both sides compile, with
//! nothing to run. What is here is the rest, where the protocol carries
//! the toolkit's geometry and does arithmetic on it. Their own runner,
//! because they reach the toolkit as a module and a file belongs to one
//! module at a time.

test {
    _ = @import("anchors.zig");
    _ = @import("panes.zig");
}

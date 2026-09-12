//! The host document tests, rooted with the reader so they can exercise its
//! extractor after scripts change a parsed tree.

test {
    _ = @import("domtest/main.zig");
}

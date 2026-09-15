//! The host document tests, rooted with the browser so they can exercise its
//! extractor after scripts change a parsed tree.

test {
    _ = @import("domtest/main.zig");
    _ = @import("intl.zig");
}

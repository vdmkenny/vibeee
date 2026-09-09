//! Everything in roll that runs on the host: the sheet. `zig build test-roll`,
//! which `make roll` runs.
//!
//! Which picture is current, what a page holds and what a filter leaves are
//! decisions about a list, so none of them needs a card or a screen to check.

test {
    _ = @import("sheet.zig");
}

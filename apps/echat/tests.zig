//! Everything in echat that runs on the host: the protocol engine and the
//! state the window draws. `zig build test-echat`, which `make echat` runs.

test {
    _ = @import("irc.zig");
    _ = @import("rooms.zig");
    _ = @import("layout.zig");
}

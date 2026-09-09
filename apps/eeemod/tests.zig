//! Everything in eeemod that runs on the host: the file format and the
//! sequencer. `zig build test-eeemod`, which `make eeemod` runs.
//!
//! A module is bytes in and notes out, and a song is those notes on a
//! clock, so neither needs a sound card to be checked.

test {
    _ = @import("module.zig");
    _ = @import("player.zig");
}

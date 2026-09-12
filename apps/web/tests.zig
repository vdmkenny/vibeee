//! The reader's host side: addresses, the protocol, encodings, what a page
//! reads as, and where its words go. Everything here is arithmetic over text,
//! so none of it needs the machine, the parser or a window to be tested.

test {
    _ = @import("url");
    _ = @import("http.zig");
    _ = @import("charset.zig");
    _ = @import("cookie.zig");
    _ = @import("form.zig");
    _ = @import("page.zig");
    _ = @import("layout.zig");
    _ = @import("media.zig");
    _ = @import("css.zig");
    _ = @import("blocklist.zig");
    // What the reader and the worker say to each other, which is arithmetic
    // over bytes and needs no more of the machine than the rest of these.
    _ = @import("worker_proto");
    // Where a page's scripts run, and what becomes of them when the worker
    // holding them dies: the same, with the machine handed in rather than
    // reached for, so that its lifecycle and its faults are tested here.
    _ = @import("script_host.zig");
}

//! The reader's host side: addresses, the protocol, encodings, what a page
//! reads as, and where its words go. Everything here is arithmetic over text,
//! so none of it needs the machine, the parser or a window to be tested.

test {
    _ = @import("url.zig");
    _ = @import("http.zig");
    _ = @import("charset.zig");
    _ = @import("form.zig");
    _ = @import("page.zig");
    _ = @import("layout.zig");
    _ = @import("media.zig");
    _ = @import("css.zig");
}

//! The screen, taken whole.
//!
//! One process owns the framebuffer at a time, by decision: two programs
//! drawing into one scanout buffer produce a mess neither can undo. Taking it
//! is a handle, a mapping and three ways to fail, which is enough steps that
//! every caller doing them itself would get a different one of them wrong.
//!
//! The desktop takes the screen this way, and so does a program running
//! without it. What each does with the pixels is its own; getting to them is
//! the same.

const sys = @import("sys");

pub const Error = sys.DisplayError || error{
    /// Taken, but the scanout buffer would not map.
    Unmappable,
};

/// The screen and how to read it. The pixels are the scanout buffer itself,
/// so a write shows up without anything further being asked.
pub const Screen = struct {
    handle: u32,
    info: sys.DisplayInfo,
    pixels: [*]u32,

    /// Give it back. The console gets the screen, which is what a program
    /// leaving should leave behind.
    pub fn release(self: *Screen) void {
        _ = sys.close(self.handle);
        self.handle = 0;
    }
};

/// Take it, or say which of the three ways it did not work.
pub fn take() Error!Screen {
    var info = sys.DisplayInfo{};
    const handle = try sys.displayAcquire(&info);

    const pixels = sys.shmMap(@intCast(handle), .{ .writable = true }) orelse {
        _ = sys.close(@intCast(handle));
        return error.Unmappable;
    };

    return .{
        .handle = @intCast(handle),
        .info = info,
        .pixels = @ptrCast(@alignCast(pixels)),
    };
}

/// What went wrong, for a program with somewhere to say it.
pub fn reasonFor(err: Error) []const u8 {
    return switch (err) {
        error.NoDisplay => "no framebuffer. The machine booted in text mode; " ++
            "add `fb` to the kernel command line.",
        error.Busy => "something already owns the display.",
        error.OutOfMemory => "not enough memory to take the display.",
        error.Unmappable => "cannot map the scanout buffer.",
    };
}

//! What every PCM controller needs and none of them should write twice.
//!
//! A sound controller is a DMA engine walking a list of period buffers and
//! interrupting as it finishes each. What is true of every DMA engine,
//! getting the memory and waiting for a bit to settle, belongs to
//! `ulib.device` and is re-exported here so a driver reaches for one
//! vocabulary. What is true only of sound stays: slicing a buffer into
//! periods, and turning the hardware's own position into "how many
//! periods finished since you last asked".

const dev = @import("dev.zig");
const device = @import("ulib").device;

/// Where a driver's rings live, and how it waits for hardware: the same
/// two things every device server needs, so the same two implementations.
pub const Dma = device.Dma;
pub const settles = device.settles;

/// One period's bytes inside a buffer of them, indexed by a free-running
/// counter the caller keeps.
pub fn periodAt(frames: anytype, index: u32) []u8 {
    const bytes: [*]u8 = @ptrCast(@volatileCast(frames));
    const slot = index % dev.PERIODS;
    return bytes[slot * dev.periodBytes() ..][0..dev.periodBytes()];
}

/// Fill a buffer of frames with silence, so a first period plays nothing
/// rather than whatever the memory held.
pub fn silence(frames: anytype) void {
    const samples: [*]volatile i16 = @ptrCast(frames);
    const count = @typeInfo(@typeInfo(@TypeOf(frames)).pointer.child).array.len;
    for (0..count) |i| samples[i] = 0;
}

/// How many periods a hardware position counter has passed since it was
/// last asked. Controllers report where they are, not how far they came,
/// so the difference is kept here and the wrap handled once.
pub const Progress = struct {
    /// How many slots the hardware's own index wraps at.
    modulus: u32,
    last: u32 = 0,

    pub fn advance(self: *Progress, index: u32) u8 {
        const now = index % self.modulus;
        const moved = (now + self.modulus - self.last) % self.modulus;
        self.last = now;
        return @intCast(moved);
    }

    pub fn reset(self: *Progress) void {
        self.last = 0;
    }
};

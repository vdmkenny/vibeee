//! What every PCM controller needs and none of them should write twice.
//!
//! A sound controller is a DMA engine walking a list of period buffers and
//! interrupting as it finishes each. The parts that differ between them are
//! register names and bring-up sequences; the parts that do not are here:
//! getting the DMA memory, waiting a bounded time for a bit to settle,
//! slicing a buffer into periods, and turning the hardware's own position
//! into "how many periods finished since you last asked".

const dev = @import("dev.zig");
const log = @import("ulib").log;
const sys = @import("sys");

/// A block of DMA memory, mapped for this process and addressable by the
/// device. One call rather than the four every driver would otherwise
/// write: allocate, check, map, cast.
pub fn Dma(comptime T: type) type {
    return struct {
        const Self = @This();

        at: *volatile T,
        phys: u32,

        /// `tag` names the driver in any failure line, because a driver
        /// that cannot get its rings has to say which driver it was.
        pub fn alloc(tag: []const u8) ?Self {
            var phys: u32 = 0;
            const handle = sys.dmaAlloc(@sizeOf(T), &phys);
            if (handle < 0) {
                log.fail(tag, "cannot allocate DMA memory");
                return null;
            }
            const mapped = sys.shmMap(@intCast(handle), .{ .writable = true }) orelse {
                log.fail(tag, "cannot map DMA memory");
                return null;
            };

            // Every descriptor this system hands a device is a physical
            // address the device reads directly, so an arena the hardware
            // cannot address at all is refused here rather than discovered
            // as silence later.
            if (phys % @alignOf(T) != 0) {
                log.fail(tag, "DMA memory is not aligned for the device");
                return null;
            }
            return .{ .at = @ptrCast(@alignCast(mapped)), .phys = phys };
        }

        /// The physical address of one field, which is what a descriptor
        /// base register wants.
        pub fn physOf(self: Self, comptime field: []const u8) u32 {
            return self.phys + @offsetOf(T, field);
        }
    };
}

/// Wait a bounded time for the hardware to agree. Never unbounded: this
/// runs in a service whose event loop must stay answerable, and a device
/// that has gone away must cost a bounded wait and a refusal.
pub fn settles(attempts: u32, pause_us: u32, context: anytype, comptime ready: fn (@TypeOf(context)) bool) bool {
    var tries: u32 = 0;
    while (tries < attempts) : (tries += 1) {
        if (ready(context)) return true;
        sys.sleepMicros(pause_us);
    }
    return false;
}

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

//! What a driver needs whatever it drives.
//!
//! Every device server here does the same two awkward things: it gets a
//! block of memory the hardware can address, and it waits a bounded time
//! for a bit to settle. Both are easy to write slightly wrong, and both
//! were written twice before this file existed.

const log = @import("log.zig");
const lib = @import("lib");
const sys = @import("sys");

/// A block of DMA memory, mapped for this process and addressable by the
/// device. One call rather than the four every driver would otherwise
/// write: allocate, check, map, cast.
pub fn Dma(comptime T: type) type {
    return struct {
        const Self = @This();

        at: *volatile T,
        phys: lib.Phys,

        /// `tag` names the driver in any failure line, because a driver
        /// that cannot get its rings has to say which driver it was.
        pub fn alloc(tag: []const u8) ?Self {
            var phys: lib.Phys = .none;
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
            if (phys.addr() % @alignOf(T) != 0) {
                log.fail(tag, "DMA memory is not aligned for the device");
                return null;
            }
            return .{ .at = @ptrCast(@alignCast(mapped)), .phys = phys };
        }

        /// The physical address of one field, which is what a descriptor
        /// base register wants.
        pub fn physOf(self: Self, comptime field: []const u8) u32 {
            return self.phys.addr() + @offsetOf(T, field);
        }

        /// The physical address of one element of an array field.
        pub fn physOfIndex(self: Self, comptime field: []const u8, index: usize) u32 {
            const Element = @typeInfo(@FieldType(T, field)).array.child;
            return self.physOf(field) + @as(u32, @intCast(index * @sizeOf(Element)));
        }
    };
}

/// Wait a bounded time for the hardware to agree. Never unbounded: a
/// service's event loop must stay answerable, and a device that has gone
/// away must cost a bounded wait and a refusal rather than the machine.
pub fn settles(
    attempts: u32,
    pause_us: u32,
    context: anytype,
    comptime ready: fn (@TypeOf(context)) bool,
) bool {
    var tries: u32 = 0;
    while (tries < attempts) : (tries += 1) {
        if (ready(context)) return true;
        sys.sleepMicros(pause_us);
    }
    return false;
}

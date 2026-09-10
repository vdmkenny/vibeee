//! Ordering between cached descriptor memory and device ownership changes.
//!
//! The fence itself is the architecture's business and lives in
//! `user/arch/x86/barrier.zig`; the names here are the ring code's
//! vocabulary for the two directions of a handoff.
//!
//! Beside them, the one thing every driver does with device memory: take a
//! run of it, hold it mapped, and give the whole of it back. Held as one
//! value because the two halves are what a driver loses track of -- a
//! handle closed under a live mapping frees nothing, and a mapping is a
//! reference of its own. Four drivers had four versions of that mistake.

const barrier = @import("sys").barrier;
const lib = @import("lib");
const std = @import("std");
const sys = @import("sys");

pub const publish = barrier.publish;
pub const consume = barrier.consume;

/// A run of device memory mapped into this process, and the only thing that
/// holds it.
///
/// `Body` is what the driver laid out in it: a struct of descriptor rings
/// and buffers, whose shape decides the size and the alignment asked for.
/// The arena hands the driver a pointer to that body and keeps the rest --
/// the mapping and the handle -- to itself, so giving it back is one call
/// and forgetting it is not possible without dropping the arena on the
/// floor.
///
/// Acquired and released as a value: `release` leaves it empty, so a
/// second call, or a release after a failed open, does nothing rather than
/// unmapping an address twice.
pub fn Arena(comptime Body: type) type {
    return struct {
        const Self = @This();

        pub const Error = error{
            /// No contiguous run of the size asked for left below 4 GiB.
            NoMemory,
            /// The run does not start where this body needs it to.
            Misaligned,
            /// The run could not be mapped.
            Unmappable,
        };

        /// What the driver laid out, live in device memory.
        at: ?*Body = null,
        /// Where the mapping begins, which is what unmapping is asked with.
        base: ?[*]u8 = null,
        phys: lib.Phys = .none,
        handle: u32 = 0,

        /// Take a run of device memory and zero it: a descriptor left
        /// holding last boot's address is a device that fetches from
        /// wherever it points.
        pub fn acquire() Error!Self {
            var phys: lib.Phys = .none;
            const handle = sys.dmaAlloc(@sizeOf(Body), &phys) catch return error.NoMemory;

            // Checked rather than adjusted: an adjusted physical base
            // without the same shift on the mapping has the CPU and the
            // device each working in a different arena.
            const last: u32 = @intCast(@sizeOf(Body) - 1);
            if (phys.addr() % @alignOf(Body) != 0 or phys.plus(last) == null) {
                sys.close(handle);
                return error.Misaligned;
            }

            const base = sys.shmMap(handle, .{ .writable = true }) orelse {
                sys.close(handle);
                return error.Unmappable;
            };

            const at: *Body = @ptrCast(@alignCast(base));
            at.* = std.mem.zeroes(Body);
            return .{ .at = at, .base = base, .phys = phys, .handle = handle };
        }

        /// Give the run back: unmapped as well as closed.
        ///
        /// The order is the whole point. The device must already have been
        /// told to stop fetching -- that is the driver's `stop`, and no
        /// arena can do it for them -- because a bus master still holding
        /// these addresses writes into whatever gets them next.
        pub fn release(self: *Self) void {
            if (self.base) |base| {
                sys.shmUnmap(base);
                self.base = null;
            }
            if (self.handle != 0) {
                sys.close(self.handle);
                self.handle = 0;
            }
            self.at = null;
            self.phys = .none;
        }

        /// The address a device is given for `offset` bytes into the body,
        /// or none where that would run off the end of what was allocated.
        ///
        /// Bounded by the body and not only by the four gigabytes a device
        /// of this age addresses: an offset past the end names memory this
        /// arena does not hold, and an address handed to a bus master is
        /// not a number to be approximately right about.
        pub fn physOf(self: Self, offset: usize) ?lib.Phys {
            if (offset >= @sizeOf(Body)) return null;
            const last = std.math.cast(u32, offset) orelse return null;
            return self.phys.plus(last);
        }

        /// The body, for a driver that has already checked it is there.
        pub fn body(self: Self) *Body {
            return self.at.?;
        }
    };
}

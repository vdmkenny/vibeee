//! One sound device, driver inside.
//!
//! The shape every PCM driver compiles against, so the service sees the
//! AC'97 and the HDA as one thing: hardware that eats periods of frames
//! and reports each one it finished. The service owns the graph, the
//! rings and the mixing; a driver owns registers, its DMA buffers, and
//! nothing above them.

const audio = @import("lib").audio;
const pci = @import("ulib").pci;

/// The period geometry, one place. Small periods are the latency budget:
/// at forty-eight kilohertz a period is five and a third milliseconds,
/// and the service keeps two in flight, so a sample leaves the machine
/// roughly eleven milliseconds after a program wrote it. Eight periods of
/// hardware ring means a stall costs a skip, never a wedge.
pub const PERIOD_FRAMES = 256;
pub const PERIODS = 8;
pub const QUEUE_AHEAD = 2;
pub const SHAPE = audio.Shape{ .rate = .hz48000, .channels = 2, .format = .s16le };

pub fn periodBytes() usize {
    return PERIOD_FRAMES * SHAPE.bytesPerFrame();
}

pub const Direction = enum(u1) { playback, capture };

/// What one interrupt delivery amounted to: how many periods each engine
/// finished since last asked. The driver has already acknowledged its
/// hardware by the time this returns.
pub const Completions = struct {
    playback: u8 = 0,
    capture: u8 = 0,

    pub fn any(self: Completions) bool {
        return self.playback != 0 or self.capture != 0;
    }
};

pub const PcmOps = struct {
    /// Map registers, reset the codec, allocate DMA. No engines running.
    open: *const fn (loc: pci.Location) bool,
    /// Start one engine at the fixed geometry above. The playback ring is
    /// expected pre-filled `QUEUE_AHEAD` periods deep before this call.
    start: *const fn (dir: Direction) bool,
    stop: *const fn (dir: Direction) void,
    /// Service one interrupt delivery, bounded, acknowledging as it goes.
    irq: *const fn () Completions,
    /// The bytes of one period slot in the driver's own DMA ring.
    period: *const fn (dir: Direction, index: u32) []u8,
    /// Tell the engine how far the service has filled (playback) or made
    /// room (capture): this hardware halts at its last valid descriptor
    /// rather than wrapping, so the index must be walked ahead of it.
    queued: *const fn (dir: Direction, index: u32) void,
    /// The hardware's own output volume, where it has one.
    setMaster: *const fn (volume: audio.Volume) void,
};

/// One driven device, and where the service's bookkeeping about it lives.
pub const PcmDev = struct {
    name: []const u8,
    ops: PcmOps,
    location: pci.Location,
    irq: u32 = 0,
    irq_gsi: ?u32 = null,

    /// The next period the service will fill (playback) or drain
    /// (capture), each free-running over the ring.
    fill: u32 = 0,
    drain: u32 = 0,
    running: [2]bool = .{ false, false },
    /// Consecutive playback periods that mixed pure silence, for stopping
    /// the engine instead of streaming zeroes forever.
    quiet_periods: u32 = 0,
};

//! How interrupts are wired, described independently of who found out.
//!
//! Firmware decides which line a device's interrupt actually arrives on, and
//! how it is signalled. On this machine that comes from an ACPI table; on
//! another it would come from a device tree or a board file. Neither belongs
//! in the architecture code that programs the controller, so the answer is
//! described here and passed in.
//!
//! The vocabulary is a global line number, a polarity and a trigger mode,
//! which is what every controller since the ISA bus has needed to be told.

/// Where a legacy interrupt really lands.
pub const Line = struct {
    /// The number a driver asks for.
    irq: u8,
    /// The global line it arrives on.
    gsi: u32,
    active_low: bool = false,
    level: bool = false,
};

/// One interrupt controller and the range of global lines it owns.
pub const Controller = struct {
    id: u8,
    address: u32,
    gsi_base: u32,
    /// How many inputs it has. Firmware rarely records this, so it is usually
    /// read from the controller itself and filled in afterwards.
    inputs: u32 = 0,
};

/// More than one controller is a server part. Two costs nothing to allow.
pub const MAX_CONTROLLERS = 2;

/// The ISA range is sixteen lines, and firmware overrides at most all of them.
pub const MAX_LINES = 16;

pub const Routing = struct {
    /// Where the per-CPU half of the controller lives, if there is one.
    local_address: u32 = 0,

    controllers: [MAX_CONTROLLERS]Controller = undefined,
    controller_count: usize = 0,

    /// Only the lines firmware said something about. Everything else is
    /// identity mapped, edge triggered and active high.
    lines: [MAX_LINES]Line = undefined,
    line_count: usize = 0,

    pub fn list(self: *const Routing) []const Controller {
        return self.controllers[0..self.controller_count];
    }

    /// What firmware said about a line, or null if it said nothing.
    pub fn describedLine(self: *const Routing, irq: u8) ?Line {
        for (self.lines[0..self.line_count]) |line| {
            if (line.irq == irq) return line;
        }
        return null;
    }

    /// Where a line lands, described or not.
    pub fn resolve(self: *const Routing, irq: u8) Line {
        return self.describedLine(irq) orelse .{ .irq = irq, .gsi = irq };
    }

    pub fn addController(self: *Routing, c: Controller) void {
        if (self.controller_count == MAX_CONTROLLERS) return;
        self.controllers[self.controller_count] = c;
        self.controller_count += 1;
    }

    pub fn addLine(self: *Routing, line: Line) void {
        if (self.line_count == MAX_LINES) return;
        self.lines[self.line_count] = line;
        self.line_count += 1;
    }
};

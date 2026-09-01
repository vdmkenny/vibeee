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

const Bounded = @import("lib").Bounded;

pub const Polarity = enum(u1) { high, low };
pub const Trigger = enum(u1) { edge, level };

/// Where a legacy interrupt really lands.
pub const Line = struct {
    /// The system control interrupt: its controller route is installed at
    /// boot, while the chipset's source gate remains closed until firmware is
    /// ready to service it.
    sci: bool = false,
    /// The number a driver asks for.
    irq: u8,
    /// The global line it arrives on.
    gsi: u32,
    polarity: Polarity = .high,
    trigger: Trigger = .edge,
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
    /// How the PIRQ pins above the legacy sixteen are triggered. Level by
    /// default, which is their electrical truth on PCI and what a machine
    /// with sane firmware wants; the quirk registry flips it to edge for
    /// boards whose firmware traps the completion doorbell.
    pirq_trigger: Trigger = .level,

    /// Where the per-CPU half of the controller lives, if there is one.
    local_address: u32 = 0,

    /// The system control interrupt's number, as the FADT names it. Held
    /// apart from the MADT's electrical description: whichever table says
    /// what, the SCI is the SCI and its unmask is the chipset's gate, not
    /// a controller write.
    sci_gsi: u32 = 0,

    controllers: Bounded(Controller, MAX_CONTROLLERS) = .{},

    /// Only the lines firmware said something about. Everything else is
    /// identity mapped, edge triggered and active high.
    lines: Bounded(Line, MAX_LINES) = .{},

    pub fn list(self: *const Routing) []const Controller {
        return self.controllers.slice();
    }

    /// Say what firmware did not, when another table does: the electrical
    /// form of a line. Added rather than asserted over, because an override
    /// that exists outranks the default this provides.
    pub fn describe(self: *Routing, irq_num: u8, polarity: Polarity, trigger: Trigger) void {
        if (self.describedLine(irq_num) != null) return;
        self.lines.append(.{
            .irq = irq_num,
            .gsi = irq_num,
            .polarity = polarity,
            .trigger = trigger,
        }) catch {};
    }

    /// The system control interrupt: the same description, marked so runtime
    /// activation uses the chipset's SCI_EN source gate rather than rewriting
    /// the interrupt controller.
    pub fn describeSci(self: *Routing, irq_num: u8, polarity: Polarity, trigger: Trigger) void {
        if (self.describedLine(irq_num) != null) return;
        self.lines.append(.{
            .irq = irq_num,
            .gsi = irq_num,
            .polarity = polarity,
            .trigger = trigger,
            .sci = true,
        }) catch {};
    }

    pub fn isSci(self: *const Routing, gsi: u32) bool {
        if (self.sci_gsi != 0 and self.sci_gsi == gsi) return true;
        for (self.lines.slice()) |line| {
            if (line.gsi == gsi and line.sci) return true;
        }
        return false;
    }

    /// Name the system control interrupt, whatever the MADT says about its
    /// electrical form. One number stops its line from ever meeting a
    /// runtime controller write.
    pub fn markSci(self: *Routing, gsi: u32) void {
        self.sci_gsi = gsi;
    }

    /// What firmware said about a line, or null if it said nothing.
    pub fn describedLine(self: *const Routing, irq: u8) ?Line {
        for (self.lines.slice()) |line| {
            if (line.irq == irq) return line;
        }
        return null;
    }

    /// Where a line lands, described or not.
    pub fn resolve(self: *const Routing, irq: u8) Line {
        return self.describedLine(irq) orelse .{ .irq = irq, .gsi = irq };
    }
};

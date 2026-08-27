//! What the kernel and userspace both have to say about drivers.
//!
//! The boot probe prints a table and `devices` prints the same table later,
//! from the same data. They should agree about what the words mean and what
//! colour each one is, which they cannot do from two separate lists.

const style = @import("style.zig");

/// How sure a driver is that a device is its.
///
/// What decides binding, rather than the order drivers are listed in: an exact
/// vendor and device match beats a class-level guess wherever both apply.
pub const Confidence = enum(u8) {
    /// Not my device.
    no = 0,
    /// Generic class-level match: works, but dumbly.
    weak = 1,
    /// Recognised family; most functionality available.
    strong = 2,
    /// Exact device match, all quirks known.
    exact = 3,

    /// How sure it is, said in colour.
    ///
    /// A weak match is the one worth noticing: it means a driver is running a
    /// device it only half recognises, which is the usual answer when hardware
    /// does less than it should.
    pub fn role(self: Confidence) style.Role {
        return switch (self) {
            .exact => .good,
            .strong => .key,
            .weak => .warn,
            .no => .dim,
        };
    }
};

/// What became of a device once the drivers had their say.
///
/// One vocabulary, so the boot table and the `devices` tool cannot describe
/// the same binding differently. A driver that merely matched is not driving
/// anything: the entry names the device without being able to run it.
pub const State = enum {
    /// A driver took it and it is running.
    driven,
    /// A driver matched but never attached, having none to attach with.
    matched,
    /// A driver tried and failed.
    failed,
    /// Nothing claimed it.
    unclaimed,

    /// The one-character shorthand the boot table puts beside a driver.
    pub fn mark(self: State) []const u8 {
        return switch (self) {
            .driven => " ",
            .matched => "*",
            .failed => "!",
            .unclaimed => " ",
        };
    }

    /// What became of it, said in colour.
    ///
    /// `matched` is the interesting one and is coloured as a warning: a driver
    /// was written for the device and something stopped it running, which is
    /// not the same as nobody having written one.
    pub fn role(self: State) style.Role {
        return switch (self) {
            .driven => .good,
            .matched => .warn,
            .failed => .bad,
            .unclaimed => .dim,
        };
    }
};

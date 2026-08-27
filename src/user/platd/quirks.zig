//! What a machine's firmware gets wrong, corrected where the answer is read.
//!
//! One vendor at a time. Each module owns its detection and its corrections,
//! and this file is the funnel every reading passes through on its way to
//! the wire: a reader stays clean of machine knowledge, and a new machine
//! means a new module plus one line in `vendors`, never a change in the
//! reader.
//!
//! A vendor is what its firmware is: these machines share a BIOS vendor and
//! little else, and a quirk about ASUS bytecode belongs with every other
//! fact about ASUS bytecode rather than beside some other vendor's.

const proto = @import("proto").platform;
const asus = @import("asus.zig");

/// The vendors whose machines this build knows about. Each must export
/// `correctBattery(*proto.Battery) void`; a vendor with nothing to correct
/// for a reading exports a no-op, which is how the funnel stays one shape
/// while the knowledge list grows.
const vendors = [_]type{ asus };

/// Correct a battery reading before it is answered, one vendor at a time.
///
/// The detection happens inside each vendor: a correction applies only
/// where its author knows it applies, and a machine nobody has written down
/// yet passes through with its numbers exactly as the firmware gave them.
pub fn battery(into: *proto.Battery) void {
    inline for (vendors) |vendor| vendor.correctBattery(into);
}
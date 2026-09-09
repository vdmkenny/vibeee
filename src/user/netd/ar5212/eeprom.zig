//! The calibration store's port: one sixteen-bit word at a time through
//! four registers, the way the reference reads it. What the words mean is
//! `family`'s, pure and host-tested; this file is only the read.

const family = @import("family.zig");
const pace = @import("pace.zig");
const regs_mod = @import("regs.zig");

const Regs = regs_mod.Regs;

/// The store as `readStore` reads it: a `word` per offset, or null when
/// the store does not answer within the reference's patience.
pub const Port = struct {
    regs: Regs,

    pub fn word(self: Port, offset: u16) ?u16 {
        self.regs.write(.eeprom_address, offset);
        self.regs.put(.eeprom_command, regs_mod.EepromCommand{ .read = true });

        const Answered = struct {
            regs: Regs,

            fn ready(port: @This()) bool {
                const status = port.regs.get(.eeprom_status, regs_mod.EepromStatus);
                return status.read_error or status.read_complete;
            }
        };
        if (!pace.looking(Answered{ .regs = self.regs }, Answered.ready, pace.DEFAULT_MICROS)) return null;
        if (self.regs.get(.eeprom_status, regs_mod.EepromStatus).read_error) return null;
        return @truncate(self.regs.read(.eeprom_data));
    }
};

pub fn read(regs: Regs) family.StoreError!family.Store {
    return family.readStore(Port{ .regs = regs });
}

/// The amplifier's measured curves for a band, or none where the store
/// holds none. Read once and kept, because it is a walk over the whole
/// calibration section and nothing in it changes.
pub fn curves(regs: Regs, store: *const family.Store, mode: family.StoreMode) family.NoCurves!family.CalCurves {
    return family.readCurves(Port{ .regs = regs }, store, mode);
}

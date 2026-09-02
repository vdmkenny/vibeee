//! The calibration store's port: one sixteen-bit word at a time through
//! four registers, the way the reference reads it. What the words mean is
//! `lib.ar5212`'s, pure and host-tested; this file is only the read.

const lib = @import("lib");
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

        var looked: u32 = 0;
        while (looked < pace.DEFAULT_TRIES) : (looked += 1) {
            const status = self.regs.get(.eeprom_status, regs_mod.EepromStatus);
            if (status.read_error) return null;
            if (status.read_complete) return @truncate(self.regs.read(.eeprom_data));
            pace.delay(10);
        }
        return null;
    }
};

pub fn read(regs: Regs) lib.ar5212.StoreError!lib.ar5212.Store {
    return lib.ar5212.readStore(Port{ .regs = regs });
}

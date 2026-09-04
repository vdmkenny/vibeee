//! The RF2425 radio, the single-chip 2.4 GHz part in the AR2425 and the
//! AR2417: its analog banks, its synthesizer, and the tables it is written
//! with. Transcribed from the reference's backend for it.
//!
//! The banks are bit streams the radio's shift register takes eight bits
//! per write. The reference keeps a scratch copy of each, patches the
//! bias fields into the sixth, and writes them out row by row; so does
//! this.

const family = @import("family.zig");
const regs_mod = @import("regs.zig");
const tables = @import("tables.zig");

const Regs = regs_mod.Regs;

/// The scratch copies of the banks, one word per row of each table.
pub const Banks = struct {
    bank1: [tables.rf2425.bank1.len]u32 = @splat(0),
    bank2: [tables.rf2425.bank2.len]u32 = @splat(0),
    bank3: [tables.rf2425.bank3.len]u32 = @splat(0),
    bank6: [tables.rf2425.bank6.len]u32 = @splat(0),
    bank7: [tables.rf2425.bank7.len]u32 = @splat(0),
};

comptime {
    // The AR2417 has its own sixth bank, of the same length, which is what
    // lets one scratch copy serve both.
    if (tables.rf2417.bank6.len != tables.rf2425.bank6.len) {
        @compileError("the AR2417's sixth bank is not the AR2425's size");
    }
}

/// Where in the sixth bank the two bias fields sit, counted from bit one,
/// and how wide they are.
const OB_FIRST_BIT = 193;
const DB_FIRST_BIT = 190;
const BIAS_BITS = 3;

/// Which sixth bank a part is written with.
pub const Part = enum { ar2425, ar2417 };

/// The radio's own initialisation: its mode table, its common table and
/// its gain table, after the family's.
pub fn writeRegs(regs: Regs, mode: tables.Mode, band: tables.Band) void {
    for (tables.rf2425.modes) |row| regs.writeAt(row.register, row.value(mode));
    for (tables.rf2425.common) |row| regs.writeAt(row.register, row.value);
    for (tables.rf2425.gain) |row| regs.writeAt(row.register, row.value(band));
}

/// Tune the synthesizer. Channel fourteen alone spreads its CCK
/// transmissions, which the reference switches on for it and off for
/// every other channel.
pub fn setChannel(regs: Regs, megahertz: u16) bool {
    const word = family.synthWord(megahertz) orelse return false;

    regs.set(.phy_cck_tx_control, regs_mod.PhyCckTxControl, "japan", megahertz == 2484);
    regs.write(.phy_bank_data, word.low());
    regs.write(.phy_synth_high, word.high());
    return true;
}

/// Fill the banks for a mode, patch the bias into the sixth, and write
/// them to the radio. The bias is the store's, from the section for the
/// mode the channel runs in.
pub fn setRfRegs(regs: Regs, banks: *Banks, mode: tables.Mode, part: Part, bias: family.Bias) void {
    for (tables.rf2425.bank1, &banks.bank1) |row, *value| value.* = row.value;
    for (tables.rf2425.bank2, &banks.bank2) |row, *value| value.* = row.value(mode);
    for (tables.rf2425.bank3, &banks.bank3) |row, *value| value.* = row.value(mode);
    for (tables.rf2425.bank6, &banks.bank6) |row, *value| value.* = row.value(mode);
    family.insertBankField(&banks.bank6, bias.ob, BIAS_BITS, OB_FIRST_BIT, 0);
    family.insertBankField(&banks.bank6, bias.db, BIAS_BITS, DB_FIRST_BIT, 0);
    for (tables.rf2425.bank7, &banks.bank7) |row, *value| value.* = row.value(mode);

    for (tables.rf2425.bank1, banks.bank1) |row, value| regs.writeAt(row.register, value);
    for (tables.rf2425.bank2, banks.bank2) |row, value| regs.writeAt(row.register, value);
    for (tables.rf2425.bank3, banks.bank3) |row, value| regs.writeAt(row.register, value);
    switch (part) {
        .ar2425 => for (tables.rf2425.bank6, banks.bank6) |row, value| regs.writeAt(row.register, value),
        .ar2417 => for (tables.rf2417.bank6, banks.bank6) |row, value| regs.writeAt(row.register, value),
    }
    for (tables.rf2425.bank7, banks.bank7) |row, value| regs.writeAt(row.register, value);
}

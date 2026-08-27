//! The PCI configuration ports, owned in one place.
//!
//! The mechanism is one shared index register and one data window, and every
//! access anywhere in the system is a select followed by a transfer: split by
//! an interrupt, or interleaved with another process, the transfer lands on
//! whatever was selected last. So the pair lives here, behind interrupts held
//! off, and the bus driver and the driver syscalls both come through.

const hal = @import("hal.zig");

const CONFIG_ADDRESS: u16 = 0xCF8;
const CONFIG_DATA: u16 = 0xCFC;

/// The address register, as the mechanism lays it out.
pub const Selector = packed struct(u32) {
    _byte: u2 = 0,
    register: u6 = 0,
    function: u3 = 0,
    device: u5 = 0,
    bus: u8 = 0,
    _reserved: u7 = 0,
    enable: bool = true,
};

pub fn read(selector: Selector) u32 {
    const was = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(was);
    hal.outl(CONFIG_ADDRESS, @bitCast(selector));
    return hal.inl(CONFIG_DATA);
}

pub fn write(selector: Selector, value: u32) void {
    const was = hal.saveAndDisableInterrupts();
    defer hal.restoreInterrupts(was);
    hal.outl(CONFIG_ADDRESS, @bitCast(selector));
    hal.outl(CONFIG_DATA, value);
}

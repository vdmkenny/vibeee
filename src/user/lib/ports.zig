//! I/O ports, for a driver that has been granted some.
//!
//! The instructions themselves, with no check that the grant was made: the CPU
//! does that. A process without the port in its bitmap faults on the
//! instruction rather than getting a wrong answer, which is the whole reason
//! the permission lives in hardware.

pub fn in8(port: u16) u8 {
    return asm volatile ("inb %[port], %[value]"
        : [value] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

pub fn in16(port: u16) u16 {
    return asm volatile ("inw %[port], %[value]"
        : [value] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
    );
}

pub fn in32(port: u16) u32 {
    return asm volatile ("inl %[port], %[value]"
        : [value] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
    );
}

pub fn out8(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
    );
}

pub fn out16(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "N{dx}" (port),
    );
}

pub fn out32(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "N{dx}" (port),
    );
}

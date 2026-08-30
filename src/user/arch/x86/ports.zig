//! Port I/O, the other thing only an instruction can do.
//!
//! Reached through the CPU's own permission bitmap: a process holds exactly
//! the ports `ioport_grant` opened for it, and any other access faults. The
//! memory clobbers keep device accesses ordered against the buffers they
//! fill and drain.

pub inline fn in8(port: u16) u8 {
    return asm volatile ("inb %[port], %[value]"
        : [value] "={al}" (-> u8),
        : [port] "N{dx}" (port),
        : .{ .memory = true });
}

pub inline fn in16(port: u16) u16 {
    return asm volatile ("inw %[port], %[value]"
        : [value] "={ax}" (-> u16),
        : [port] "N{dx}" (port),
        : .{ .memory = true });
}

pub inline fn in32(port: u16) u32 {
    return asm volatile ("inl %[port], %[value]"
        : [value] "={eax}" (-> u32),
        : [port] "N{dx}" (port),
        : .{ .memory = true });
}

pub inline fn out8(port: u16, value: u8) void {
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "N{dx}" (port),
        : .{ .memory = true });
}

pub inline fn out16(port: u16, value: u16) void {
    asm volatile ("outw %[value], %[port]"
        :
        : [value] "{ax}" (value),
          [port] "N{dx}" (port),
        : .{ .memory = true });
}

pub inline fn out32(port: u16, value: u32) void {
    asm volatile ("outl %[value], %[port]"
        :
        : [value] "{eax}" (value),
          [port] "N{dx}" (port),
        : .{ .memory = true });
}

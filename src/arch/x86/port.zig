//! x86 port I/O. This file is one of the reasons `arch/` exists: nothing here
//! has any meaning on ARM, and drivers that need it declare `.port_io = true`
//! in their manifest so they are excluded from non-x86 builds at comptime.

pub inline fn outb(port: u16, value: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (value),
          [p] "N{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "N{dx}" (port),
    );
}

pub inline fn outw(port: u16, value: u16) void {
    asm volatile ("outw %[v], %[p]"
        :
        : [v] "{ax}" (value),
          [p] "N{dx}" (port),
    );
}

pub inline fn inw(port: u16) u16 {
    return asm volatile ("inw %[p], %[r]"
        : [r] "={ax}" (-> u16),
        : [p] "N{dx}" (port),
    );
}

pub inline fn outl(port: u16, value: u32) void {
    asm volatile ("outl %[v], %[p]"
        :
        : [v] "{eax}" (value),
          [p] "N{dx}" (port),
    );
}

pub inline fn inl(port: u16) u32 {
    return asm volatile ("inl %[p], %[r]"
        : [r] "={eax}" (-> u32),
        : [p] "N{dx}" (port),
    );
}

/// Write to an unused port to burn ~1 microsecond. Needed between writes to
/// slow legacy hardware (PIC, CMOS) that cannot accept back-to-back commands.
/// Read `buf.len / 2` words from `port` straight into `buf`, one string
/// instruction: what a sector's worth of PIO costs when the CPU is the
/// transfer engine. Whole words only.
pub inline fn insw(port: u16, buf: []u8) void {
    var dst: [*]u8 = undefined;
    var left: usize = undefined;
    asm volatile ("rep insw"
        : [dst] "={edi}" (dst),
          [left] "={ecx}" (left),
        : [port] "{dx}" (port),
          [dst_in] "{edi}" (buf.ptr),
          [count_in] "{ecx}" (buf.len / 2),
        : .{ .memory = true });
}

/// Write `buf.len / 2` words from `buf` to `port`, one string instruction.
pub inline fn outsw(port: u16, buf: []const u8) void {
    var src: [*]const u8 = undefined;
    var left: usize = undefined;
    asm volatile ("rep outsw"
        : [src] "={esi}" (src),
          [left] "={ecx}" (left),
        : [port] "{dx}" (port),
          [src_in] "{esi}" (buf.ptr),
          [count_in] "{ecx}" (buf.len / 2),
        : .{ .memory = true });
}

pub inline fn ioWait() void {
    outb(0x80, 0);
}

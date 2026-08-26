//! IDT and interrupt entry.
//!
//! The 256 entry stubs are generated at comptime rather than written out by
//! hand or emitted from a NASM macro — this is one of the places Zig genuinely
//! beats the C+asm equivalent, since the stub table and the dispatch table are
//! guaranteed to agree by construction.
//!
//! Gate DPLs matter for privilege safety (design/00-vibeee.md §6.7): hardware
//! IRQ and exception gates are DPL 0 so Ring 3 cannot forge them with `int`,
//! and only the syscall vector is DPL 3.

const std = @import("std");
const port = @import("port.zig");
const gdt = @import("gdt.zig");

pub const SYSCALL_VECTOR: u8 = 0x80;
pub const IRQ_BASE: u8 = 32;

/// Register state pushed by the stubs. Field order is the reverse of the push
/// sequence — `interrupt.s`-equivalent logic lives in `stub()` below.
pub const Frame = extern struct {
    // pushed by us
    gs: u32,
    fs: u32,
    es: u32,
    ds: u32,
    edi: u32,
    esi: u32,
    ebp: u32,
    esp_dummy: u32,
    ebx: u32,
    edx: u32,
    ecx: u32,
    eax: u32,
    vector: u32,
    error_code: u32,
    // pushed by the CPU
    eip: u32,
    cs: u32,
    eflags: u32,
    // only present on a privilege change (Ring 3 -> Ring 0)
    user_esp: u32,
    user_ss: u32,
};

pub const Handler = *const fn (*Frame) void;

const GateType = enum(u4) {
    interrupt32 = 0xE, // clears IF on entry
    trap32 = 0xF, // leaves IF alone
};

const Gate = packed struct(u64) {
    offset_low: u16,
    selector: u16,
    zero: u8,
    gate_type: u4,
    storage: u1,
    dpl: u2,
    present: bool,
    offset_high: u16,
};

const Descriptor = extern struct {
    limit: u16 align(1),
    base: u32 align(1),
};

var idt: [256]Gate align(8) = std.mem.zeroes([256]Gate);
var handlers: [256]?Handler = .{null} ** 256;

/// These vectors push an error code themselves; for all others we push a dummy
/// zero so the Frame layout is uniform.
fn pushesErrorCode(comptime vec: u8) bool {
    return switch (vec) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

/// Comptime-generated entry stub for one vector.
fn stub(comptime vec: u8) fn () callconv(.naked) void {
    return struct {
        fn entry() callconv(.naked) void {
            if (comptime !pushesErrorCode(vec)) {
                asm volatile ("pushl $0");
            }
            asm volatile (
                \\ pushl %[v]
                \\ pushal
                \\ pushl %%ds
                \\ pushl %%es
                \\ pushl %%fs
                \\ pushl %%gs
                \\ movw %[kds], %%ax
                \\ movw %%ax, %%ds
                \\ movw %%ax, %%es
                \\ movw %%ax, %%fs
                \\ movw %%ax, %%gs
                \\ pushl %%esp
                \\ call isrDispatch
                \\ addl $4, %%esp
                \\ popl %%gs
                \\ popl %%fs
                \\ popl %%es
                \\ popl %%ds
                \\ popal
                \\ addl $8, %%esp
                \\ iret
                :
                : [v] "i" (@as(u32, vec)),
                  [kds] "i" (gdt.KERNEL_DATA),
            );
        }
    }.entry;
}

export fn isrDispatch(frame: *Frame) callconv(.c) void {
    const vec: u8 = @truncate(frame.vector);
    if (handlers[vec]) |h| {
        h(frame);
    } else if (vec < 32) {
        @import("fault.zig").onException(frame);
    }
    // Acknowledge the PIC for hardware lines. Once the IOAPIC takes over
    // (design §6.6) this becomes a LAPIC EOI instead.
    if (vec >= IRQ_BASE and vec < IRQ_BASE + 16) {
        const irq = vec - IRQ_BASE;
        if (irq >= 8) port.outb(0xA0, 0x20);
        port.outb(0x20, 0x20);
    }

    // Preemption happens here rather than inside the handler: the interrupt
    // controller has been acknowledged, so switching stacks now cannot strand
    // a line un-acknowledged and wedge further interrupts.
    @import("../../kernel/sched.zig").onInterruptExit();
}

fn setGate(vec: u8, handler: *const anyopaque, dpl: u2, gate_type: GateType) void {
    const addr = @intFromPtr(handler);
    idt[vec] = .{
        .offset_low = @truncate(addr & 0xFFFF),
        .selector = gdt.KERNEL_CODE,
        .zero = 0,
        .gate_type = @intFromEnum(gate_type),
        .storage = 0,
        .dpl = dpl,
        .present = true,
        .offset_high = @truncate((addr >> 16) & 0xFFFF),
    };
}

pub fn init() void {
    inline for (0..256) |i| {
        const vec: u8 = @intCast(i);
        // Only the syscall gate is reachable from Ring 3.
        const dpl: u2 = if (vec == SYSCALL_VECTOR) 3 else 0;
        setGate(vec, &stub(vec), dpl, .interrupt32);
    }

    const desc = Descriptor{
        .limit = @sizeOf(@TypeOf(idt)) - 1,
        .base = @intFromPtr(&idt),
    };
    asm volatile ("lidt (%[d])"
        :
        : [d] "r" (&desc),
        : .{ .memory = true });
}

pub fn setHandler(vec: u8, handler: Handler) void {
    handlers[vec] = handler;
}

/// Remap the 8259 PICs away from vectors 0-15, which collide with the CPU
/// exception range. We mask everything afterwards: this machine has an IOAPIC
/// (verified in the MADT) and that is what we actually use — the PICs are
/// remapped only so a stray legacy interrupt cannot masquerade as a fault.
pub fn remapPic() void {
    const PIC1_CMD = 0x20;
    const PIC1_DATA = 0x21;
    const PIC2_CMD = 0xA0;
    const PIC2_DATA = 0xA1;

    port.outb(PIC1_CMD, 0x11); // ICW1: init + ICW4 to follow
    port.ioWait();
    port.outb(PIC2_CMD, 0x11);
    port.ioWait();
    port.outb(PIC1_DATA, IRQ_BASE); // ICW2: vector offsets
    port.ioWait();
    port.outb(PIC2_DATA, IRQ_BASE + 8);
    port.ioWait();
    port.outb(PIC1_DATA, 0x04); // ICW3: slave on IRQ2
    port.ioWait();
    port.outb(PIC2_DATA, 0x02);
    port.ioWait();
    port.outb(PIC1_DATA, 0x01); // ICW4: 8086 mode
    port.ioWait();
    port.outb(PIC2_DATA, 0x01);
    port.ioWait();
}

pub fn maskAllPic() void {
    port.outb(0x21, 0xFF);
    port.outb(0xA1, 0xFF);
}

pub fn setPicMask(irq: u8, masked: bool) void {
    const p: u16 = if (irq < 8) 0x21 else 0xA1;
    const bit: u3 = @truncate(irq & 7);
    var mask = port.inb(p);
    if (masked) {
        mask |= (@as(u8, 1) << bit);
    } else {
        mask &= ~(@as(u8, 1) << bit);
    }
    port.outb(p, mask);
}

//! GDT + TSS. Flat segmentation: paging does the real memory protection work,
//! segments exist only to carry the privilege level.
//!
//! Layout (design/00-vibeee.md §6.7):
//!   0x00 null
//!   0x08 kernel code   DPL 0
//!   0x10 kernel data   DPL 0
//!   0x18 user code     DPL 3
//!   0x20 user data     DPL 3
//!   0x28 TSS
//!
//! One TSS for the machine, the 701 is single-core. Its esp0 is rewritten on
//! every context switch so an interrupt taken in Ring 3 lands on the incoming
//! thread's kernel stack.


pub const KERNEL_CODE: u16 = 0x08;
pub const KERNEL_DATA: u16 = 0x10;
pub const USER_CODE: u16 = 0x18 | 3; // RPL 3
pub const USER_DATA: u16 = 0x20 | 3;
pub const TSS_SEL: u16 = 0x28;

const Entry = packed struct(u64) {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    accessed: bool,
    rw: bool,
    direction: bool,
    executable: bool,
    descriptor_type: bool, // 1 = code/data, 0 = system
    dpl: u2,
    present: bool,
    limit_high: u4,
    available: bool,
    long_mode: bool,
    size_32: bool,
    granularity: bool, // 1 = limit in 4 KiB pages
    base_high: u8,

    fn make(base: u32, limit: u32, dpl: u2, exec: bool, system: bool) Entry {
        return .{
            .limit_low = @truncate(limit & 0xFFFF),
            .base_low = @truncate(base & 0xFFFF),
            .base_mid = @truncate((base >> 16) & 0xFF),
            .accessed = false,
            .rw = true,
            .direction = false,
            .executable = exec,
            .descriptor_type = !system,
            .dpl = dpl,
            .present = true,
            .limit_high = @truncate((limit >> 16) & 0xF),
            .available = false,
            .long_mode = false,
            .size_32 = !system,
            .granularity = !system,
            .base_high = @truncate((base >> 24) & 0xFF),
        };
    }
};

/// 32-bit TSS. We use exactly one field of it, esp0, plus the I/O permission
/// bitmap offset. Hardware task switching is not used; this exists so the CPU
/// knows where to put the stack on a privilege transition, and which ports a
/// driver process may touch.
pub const Tss = extern struct {
    prev_tss: u32 = 0,
    esp0: u32 = 0,
    ss0: u32 = 0,
    esp1: u32 = 0,
    ss1: u32 = 0,
    esp2: u32 = 0,
    ss2: u32 = 0,
    cr3: u32 = 0,
    eip: u32 = 0,
    eflags: u32 = 0,
    eax: u32 = 0,
    ecx: u32 = 0,
    edx: u32 = 0,
    ebx: u32 = 0,
    esp: u32 = 0,
    ebp: u32 = 0,
    esi: u32 = 0,
    edi: u32 = 0,
    es: u32 = 0,
    cs: u32 = 0,
    ss: u32 = 0,
    ds: u32 = 0,
    fs: u32 = 0,
    gs: u32 = 0,
    ldt: u32 = 0,
    trap: u16 = 0,
    iomap_base: u16 = 0,
};

const Descriptor = extern struct {
    limit: u16 align(1),
    base: u32 align(1),
};

var gdt: [6]Entry align(8) = undefined;
var tss: Tss align(16) = .{};

pub fn init(kernel_stack_top: u32) void {
    gdt[0] = @bitCast(@as(u64, 0));
    gdt[1] = Entry.make(0, 0xFFFFF, 0, true, false); // kernel code
    gdt[2] = Entry.make(0, 0xFFFFF, 0, false, false); // kernel data
    gdt[3] = Entry.make(0, 0xFFFFF, 3, true, false); // user code
    gdt[4] = Entry.make(0, 0xFFFFF, 3, false, false); // user data

    tss = .{
        .ss0 = KERNEL_DATA,
        .esp0 = kernel_stack_top,
        // No I/O bitmap yet: point past the TSS limit so every port access from
        // Ring 3 faults. Driver processes get a real bitmap when granted ports.
        .iomap_base = @sizeOf(Tss),
    };

    var tss_entry = Entry.make(@intFromPtr(&tss), @sizeOf(Tss) - 1, 0, true, true);
    tss_entry.accessed = true; // for a TSS descriptor this bit means "busy=0, type=9"
    tss_entry.rw = false;
    tss_entry.direction = false;
    gdt[5] = tss_entry;

    const desc = Descriptor{
        .limit = @sizeOf(@TypeOf(gdt)) - 1,
        .base = @intFromPtr(&gdt),
    };

    asm volatile (
        \\ lgdt (%[d])
        \\ ljmp %[cs], $1f
        \\ 1:
        \\ movw %[ds], %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ movw %%ax, %%fs
        \\ movw %%ax, %%gs
        \\ movw %%ax, %%ss
        :
        : [d] "r" (&desc),
          [cs] "i" (KERNEL_CODE),
          [ds] "i" (KERNEL_DATA),
        : .{ .memory = true, .eax = true });

    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (TSS_SEL),
    );
}

/// Called on every context switch: the incoming thread's kernel stack.
pub fn setKernelStack(esp0: u32) void {
    tss.esp0 = esp0;
}

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

const std = @import("std");
const cpu = @import("cpu.zig");

pub const KERNEL_CODE: u16 = 0x08;
pub const KERNEL_DATA: u16 = 0x10;
pub const USER_CODE: u16 = 0x18 | 3; // RPL 3
pub const USER_DATA: u16 = 0x20 | 3;
pub const TSS_SEL: u16 = 0x28;

/// Which entry that selector names. A selector is a byte offset into the
/// table, and the two are written once here rather than once each.
const TSS_INDEX = TSS_SEL / @sizeOf(Entry);

/// The four bits that describe a segment, which in a system descriptor
/// together name a kind of thing instead. One layout, two readings, which is
/// why they are grouped rather than left loose among the rest.
const Kind = packed struct(u4) {
    accessed: bool = false,
    rw: bool = false,
    direction: bool = false,
    executable: bool = false,

    fn segment(exec: bool) Kind {
        return .{ .rw = true, .executable = exec };
    }

    /// A 32-bit task nobody is running. The processor marks a task busy in
    /// its own descriptor the moment it loads it, and refuses to load one
    /// that already says so.
    const task_free = Kind{ .accessed = true, .executable = true };
};

const Entry = packed struct(u64) {
    limit_low: u16,
    base_low: u16,
    base_mid: u8,
    kind: Kind,
    descriptor_type: bool, // 1 = code/data, 0 = system
    dpl: u2,
    present: bool,
    limit_high: u4,
    available: bool,
    long_mode: bool,
    size_32: bool,
    granularity: bool, // 1 = limit in 4 KiB pages
    base_high: u8,

    fn make(base: u32, limit: u32, dpl: u2, kind: Kind, system: bool) Entry {
        return .{
            .limit_low = @truncate(limit & 0xFFFF),
            .base_low = @truncate(base & 0xFFFF),
            .base_mid = @truncate((base >> 16) & 0xFF),
            .kind = kind,
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

    /// One bit per port, cleared to allow. 65536 ports is 8 KiB.
    ///
    /// One bitmap for the machine rather than one TSS per process: switching
    /// tasks through the CPU's own mechanism is slower than switching stacks,
    /// and everything else here already switches stacks. The cost is that the
    /// bitmap belongs to whichever process last needed it, and is rewritten
    /// when that changes.
    iopb: [IOPB_BYTES]u8 = @splat(0xFF),

    /// The manual requires a byte of all ones after the bitmap: a port access
    /// that straddles the end reads this rather than whatever follows.
    iopb_guard: u8 = 0xFF,
};

pub const IOPB_BYTES = 8192;

/// Where the bitmap sits inside the TSS.
const IOPB_OFFSET: u16 = @offsetOf(Tss, "iopb");

/// What `iomap_base` says when nothing may touch a port. Past the limit, which
/// the CPU reads as "no bitmap", and therefore as deny.
const IOPB_NONE: u16 = 0xFFFF;

var gdt: [6]Entry align(8) = undefined;
var tss: Tss align(16) = .{};

pub fn init(kernel_stack_top: u32) void {
    gdt[0] = @bitCast(@as(u64, 0));
    gdt[1] = Entry.make(0, 0xFFFFF, 0, .segment(true), false); // kernel code
    gdt[2] = Entry.make(0, 0xFFFFF, 0, .segment(false), false); // kernel data
    gdt[3] = Entry.make(0, 0xFFFFF, 3, .segment(true), false); // user code
    gdt[4] = Entry.make(0, 0xFFFFF, 3, .segment(false), false); // user data

    tss = .{
        .ss0 = KERNEL_DATA,
        .esp0 = kernel_stack_top,
        // No I/O bitmap yet: point past the TSS limit so every port access from
        // Ring 3 faults. Driver processes get a real bitmap when granted ports.
        .iomap_base = @sizeOf(Tss),
    };

    gdt[TSS_INDEX] = Entry.make(@intFromPtr(&tss), @sizeOf(Tss) - 1, 0, .task_free, true);

    // Loaded in the same breath as the segment reload below: the far jump has
    // to be the next instruction the CPU runs, so this one cannot be a call.
    const desc = cpu.TableRegister.of(&gdt);

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

    retakeTask();
}

/// Where the table is, as `lgdt` takes it.
///
/// For waking from a suspend to memory: the processor comes back with no
/// descriptor tables at all, and the first instructions that run after it
/// have no stack to be handed anything on. They read this.
pub fn describe() cpu.TableRegister {
    return cpu.TableRegister.of(&gdt);
}

/// Take the task register back.
///
/// Waking clears it, and the descriptor in memory still says the task is
/// busy, which is what `ltr` refuses. Clearing that bit is the whole of the
/// repair: nothing else about the entry changed while the machine was
/// asleep, the memory holding it having been kept alive the whole time.
pub fn retakeTask() void {
    // Said again because the processor is the one that said it was busy, and
    // it no longer remembers doing so: what a machine coming back from a
    // suspend to memory finds in the descriptor is the mark its own last
    // `ltr` left, and the mark is what the next one refuses on.
    gdt[TSS_INDEX].kind = .task_free;
    asm volatile ("ltr %[sel]"
        :
        : [sel] "r" (TSS_SEL),
    );
}

/// Called on every context switch: the incoming thread's kernel stack.
pub fn setKernelStack(esp0: u32) void {
    tss.esp0 = esp0;
}

/// Copy a process's grants into the machine's one bitmap.
///
/// Copied rather than pointed at, because the CPU reads it from inside the
/// TSS. Only when the process holding it changes: a driver server is switched
/// away from and back to constantly, and eight kilobytes on every one of those
/// would cost more than the ports save.
pub fn loadIoBitmap(shadow: *const [IOPB_BYTES]u8) void {
    std.mem.copyForwards(u8, &tss.iopb, shadow);
    @atomicStore(u16, &tss.iomap_base, IOPB_OFFSET, .release);
}

/// Let the bitmap through again, its contents already being this process's.
pub fn enableIoBitmap() void {
    @atomicStore(u16, &tss.iomap_base, IOPB_OFFSET, .release);
}

/// Deny every port. Costs a store: the bitmap is put out of reach rather than
/// filled in, which is what makes a process with no grants pay nothing.
pub fn denyIoPorts() void {
    tss.iomap_base = IOPB_NONE;
}

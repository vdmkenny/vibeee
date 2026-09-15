//! Suspend to memory, from the processor's side.
//!
//! Sleeping is easy: one word written to the chipset and the machine stops.
//! Waking is not. Power comes back to a processor that has been reset, so
//! everything it was holding is gone: no descriptor tables, no paging, no
//! control register bits, no registers, not even protected mode. Memory is
//! all that survived, and the firmware's only contribution is to jump to an
//! address it was given beforehand.
//!
//! So this file is two halves that meet across the gap. Going down, it writes
//! the processor's state into memory, puts the trampoline where the firmware
//! will jump, and remembers where its own stack was. Coming back,
//! `boot/s3wake.asm` gets as far as protected mode with paging on, hands over
//! to the few instructions below that restore the kernel's descriptor table
//! and its stack, and the sleeping call then returns as though it had merely
//! been slow.
//!
//! Around that sits the rest of what the machine forgets: the memory types,
//! the interrupt controllers, the timer, the registers the fast syscall path
//! lives in. Each of those is its own file's to hold and to put back, and the
//! order they are put back in is the one thing they cannot decide among
//! themselves, so it is decided here.
//!
//! The devices are not part of it. What a device holds is its driver's, and
//! the drivers are asked to quiet down and wake up around this call rather
//! than through it.

const std = @import("std");
const cpu = @import("cpu.zig");
const fpu = @import("fpu.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const ioapic = @import("ioapic.zig");
const lapic = @import("lapic.zig");
const mtrr = @import("mtrr.zig");
const nmiwatch = @import("nmiwatch.zig");
const paging = @import("paging.zig");
const pic = @import("pic.zig");
const s3wake = @import("s3wake.zig");
const syscall_arch = @import("syscall_arch.zig");
const timer = @import("timer.zig");

/// What the first instructions after a wake need, and all they can reach.
///
/// Exported, and named as symbols in the assembly below rather than handed in
/// as operands. Both halves of that matter. At the moment the trampoline
/// hands over there is no stack yet and no register worth reading, so an
/// absolute address is the only way to find anything; and a memory operand
/// would not give one, because the compiler answers `"m"` by copying the
/// value somewhere convenient, which on a function with no stack is a stack
/// slot that does not exist.
export var s3_table: cpu.TableRegister = .{ .limit = 0, .base = 0 };
export var s3_stack: u32 = 0;
export var s3_resume: u32 = 0;

/// Where the kernel comes back to.
///
/// Entered from the trampoline in protected mode with paging on, the kernel
/// mapped where it is linked, and nothing else true. Enough instructions to
/// get from the trampoline's flat descriptor table to the kernel's own and
/// back onto the stack the sleeping call left, and then it is Zig again.
fn woken() callconv(.naked) noreturn {
    asm volatile (
        \\ lgdt s3_table
        \\ ljmp %[cs], $1f
        \\ 1:
        \\ movw %[ds], %%ax
        \\ movw %%ax, %%ds
        \\ movw %%ax, %%es
        \\ movw %%ax, %%fs
        \\ movw %%ax, %%gs
        \\ movw %%ax, %%ss
        \\ movl s3_stack, %%esp
        \\ jmp *s3_resume
        :
        : [cs] "i" (gdt.KERNEL_CODE),
          [ds] "i" (gdt.KERNEL_DATA),
    );
}

/// What the processor holds that only memory will keep.
const Held = struct {
    idt: cpu.TableRegister,
    cr0: u32,
    cr4: u32,
    /// Whose address space this was asked for, to be put back afterwards:
    /// sleeping runs in the kernel's own.
    was: paging.AddressSpace,
};

/// The floating-point registers of whoever asked to sleep.
///
/// A thread's are written out when it is switched away from, and the thread
/// that asks for this is not switched away from: it makes a call that takes a
/// few seconds and comes back. Without this those registers would come back
/// as whatever the processor powers up holding.
var floating: fpu.State align(16) = @splat(0);

/// Put the machine to sleep, and put it back together when it wakes.
///
/// `enter` is the write that stops it, which is the chipset's business and
/// therefore somebody else's. It is handed the physical address the firmware
/// must be told to come back to, because that is this file's to know and
/// nobody else's. By the time it is called everything is saved and the
/// trampoline is in place, so the machine may stop between any two of its
/// instructions. It returning at all means the machine refused, and then
/// nothing was lost and nothing needs putting back.
pub fn sleepToMemory(enter: *const fn (wake_at: u32) callconv(.c) void) bool {
    mtrr.stow();
    pic.stow();
    if (ioapic.active()) ioapic.stow();

    if (!sleepProcessor(enter)) return false;

    // The memory types first: everything below reads and writes registers,
    // and until the ranges are back the processor treats the whole machine as
    // uncacheable.
    mtrr.restore();

    // Then the controllers, from the processor outwards: the local unit has
    // to be listening before the one that delivers into it is pointed at
    // anything.
    pic.restore(idt.IRQ_BASE);
    if (ioapic.active()) {
        lapic.arm();
        ioapic.restore();
    }
    if (nmiwatch.isArmed()) lapic.armPerformanceNmi();

    // The three registers the fast syscall path lives in, the running
    // thread's kernel stack among them.
    syscall_arch.init();

    // And the clocks: the interval timer is programmed rather than merely
    // switched on, and the firmware's counter is picked up where it now
    // stands rather than where it was.
    timer.init();
    timer.resync();
    return true;
}

/// The processor's own half: what it holds written out, the trampoline laid
/// where the firmware will jump, the gap, and what it holds put back.
fn sleepProcessor(enter: *const fn (wake_at: u32) callconv(.c) void) bool {
    const held = Held{
        .idt = cpu.storeIdt(),
        .cr0 = cpu.readCr0(),
        .was = .{ .pd_phys = paging.readCr3() },
        .cr4 = cpu.readCr4(),
    };
    s3_table = gdt.describe();
    fpu.save(&floating);

    // The master directory, for two reasons: it is the one the trampoline is
    // handed, and it is the only one the identity mapping goes into. The
    // stack this is running on is in the kernel half, which every address
    // space carries, so the switch changes nothing underfoot.
    const kernel = paging.kernelAddressSpace();
    lay(kernel, held.cr4);
    paging.restoreIdentityMapping();
    kernel.activate();

    const slept = park(enter);

    if (slept) {
        // Back, with the descriptor table and the stack and nothing else.
        cpu.loadIdt(&held.idt);
        gdt.retakeTask();
        // Whole, not bit by bit: waking clears CR0 down to caches off and
        // CR4 down to no extensions, and the trampoline puts back only the
        // two bits it cannot itself run without.
        cpu.writeCr0(held.cr0);
        cpu.writeCr4(held.cr4);
        fpu.restore(&floating);
    }

    paging.dropIdentityMapping();
    held.was.activate();
    return slept;
}

/// Copy the trampoline where the firmware will jump, and fill in the three
/// things it cannot know.
fn lay(space: paging.AddressSpace, cr4: u32) void {
    const page: [*]u8 = @ptrFromInt(paging.physToVirt(s3wake.at));
    @memcpy(page[0..s3wake.code.len], &s3wake.code);

    put(page, .cr3, @intCast(space.pd_phys));
    // As it is now: four-megabyte pages are read as four-kilobyte ones
    // without the size extension, and the first thing that would be fetched
    // through such a misreading is the trampoline itself.
    put(page, .cr4, cr4);
    put(page, .entry, @intFromPtr(&woken));
}

fn put(page: [*]u8, which: s3wake.Patch, value: u32) void {
    std.mem.writeInt(u32, page[@intFromEnum(which)..][0..4], value, .little);
}

/// Where the gap is.
///
/// The registers the calling convention says survive a call are pushed, the
/// stack they are on is remembered, and so is the address to come back to.
/// Then `enter` stops the machine. Waking lands on that address with that
/// stack, which is why what was pushed is still there to pop: the call to
/// `enter` used the same stack, but every byte it touched is below what was
/// saved.
///
/// This is one assembly block rather than a save and a separate sleep
/// because the two cannot be in different frames: a frame returned from is a
/// frame the next call writes over.
fn park(enter: *const fn (wake_at: u32) callconv(.c) void) bool {
    return asm volatile (
        \\ pushl %%ebp
        \\ pushl %%ebx
        \\ pushl %%esi
        \\ pushl %%edi
        \\ movl %%esp, s3_stack
        \\ movl $1f, s3_resume
        \\ pushl %[where]
        \\ call *%[enter]
        \\ addl $4, %%esp
        \\ xorl %%eax, %%eax
        \\ jmp 2f
        \\ 1:
        \\ movl $1, %%eax
        \\ 2:
        \\ popl %%edi
        \\ popl %%esi
        \\ popl %%ebx
        \\ popl %%ebp
        : [slept] "={eax}" (-> bool),
        : [enter] "r" (enter),
          [where] "i" (s3wake.at),
        : .{ .memory = true, .ecx = true, .edx = true, .cc = true });
}

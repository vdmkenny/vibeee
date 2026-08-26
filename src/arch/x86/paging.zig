//! 32-bit paging: two-level, non-PAE.
//!
//! PAE is deliberately not used. Its only benefit on this machine would be NX,
//! since the CPU is 32-bit-physical and cannot address above 4 GiB either way,
//! and the costs are real: 8-byte PTEs, a third level of walk, and a messier
//! story for the eventual ARM port. W^X at the mapping level gets most of the
//! practical protection for free. See design/00-vibeee.md §6.2.
//!
//! The kernel lives in the top gigabyte (0xC0000000+), with all physical memory
//! linearly mapped there using 4 MiB pages. Large pages for the linear map cost
//! no page tables at all and consume 256 TLB entries at most for the whole of
//! RAM, on a core with a small TLB that is a meaningful win over 4 KiB pages.
//! User space gets ordinary 4 KiB pages across the low 3 GiB.

const std = @import("std");

pub const PAGE_SIZE: usize = 4096;
pub const LARGE_PAGE_SIZE: usize = 4 * 1024 * 1024;

/// Virtual base of the kernel half. Must match KERNEL_VMA in linker.ld.
pub const KERNEL_VMA: usize = 0xC000_0000;

/// Where the linear map of physical memory stops and the MMIO window begins.
///
/// The linear map covers 768 MiB of physical memory, which is more than this
/// class of machine can hold. The rest of the kernel half is kept for mapping
/// device apertures, which live at physical addresses far above RAM, a
/// framebuffer at 0xFD000000, for instance, has no linear-map address at all
/// and must be mapped explicitly.
pub const MMIO_BASE: usize = 0xF000_0000;
pub const LINEAR_MAP_BYTES: usize = MMIO_BASE - KERNEL_VMA;

/// How much of the low address space the boot mapping mirrors identically.
/// Needed only for the instant between enabling paging and jumping high;
/// dropped as soon as the kernel is running from its virtual addresses.
const IDENTITY_MIB = 64;

pub const Flags = struct {
    pub const present: u32 = 1 << 0;
    pub const write: u32 = 1 << 1;
    pub const user: u32 = 1 << 2;
    pub const write_through: u32 = 1 << 3;
    pub const cache_disable: u32 = 1 << 4;
    pub const accessed: u32 = 1 << 5;
    pub const dirty: u32 = 1 << 6;
    pub const large: u32 = 1 << 7;
    pub const global: u32 = 1 << 8;
};

/// The boot page directory. Lives in `.bootdata` so it sits at a physical
/// address the pre-paging code can reach: everything else in the kernel is
/// linked high and is unreachable until CR0.PG is set.
export var boot_page_directory: [1024]u32 align(PAGE_SIZE) linksection(".bootdata") =
    [_]u32{0} ** 1024;

/// Build the initial mapping and turn paging on.
///
/// Runs before the kernel is reachable at its link addresses, so it must not
/// call anything outside `.text.boot` or touch anything outside `.bootdata`.
pub fn setupBootPaging() linksection(".text.boot") callconv(.c) void {
    const dir: [*]u32 = @ptrFromInt(@intFromPtr(&boot_page_directory));

    // Identity map, so the instruction after `mov cr0` is still fetchable.
    var i: usize = 0;
    while (i < IDENTITY_MIB / 4) : (i += 1) {
        dir[i] = @as(u32, @intCast(i * LARGE_PAGE_SIZE)) |
            Flags.present | Flags.write | Flags.large;
    }

    // The kernel window: 0xC0000000..0xFFFFFFFF linearly onto physical 0.
    // Mapping the whole gigabyte up front means the linear map never has to be
    // extended later, whatever the machine turns out to have; frames that do
    // not exist simply never get handed out by the allocator.
    const kernel_pde_start = KERNEL_VMA / LARGE_PAGE_SIZE;
    const kernel_pde_end = MMIO_BASE / LARGE_PAGE_SIZE;
    i = 0;
    while (kernel_pde_start + i < kernel_pde_end) : (i += 1) {
        dir[kernel_pde_start + i] = @as(u32, @intCast(i * LARGE_PAGE_SIZE)) |
            Flags.present | Flags.write | Flags.large | Flags.global;
    }

    asm volatile (
    // CR4.PSE enables 4 MiB pages; CR4.PGE enables the global bit, which
    // keeps kernel mappings in the TLB across an address-space switch.
        \\ movl %%cr4, %%eax
        \\ orl $0x90, %%eax
        \\ movl %%eax, %%cr4
        \\ movl %[dir], %%eax
        \\ movl %%eax, %%cr3
        \\ movl %%cr0, %%eax
        \\ orl $0x80000000, %%eax
        \\ movl %%eax, %%cr0
        :
        : [dir] "r" (@intFromPtr(&boot_page_directory)),
        : .{ .eax = true, .memory = true });
}

/// The page directory, reached through the linear map.
///
/// `boot_page_directory` lives in `.bootdata` and its symbol address is
/// therefore *physical*, correct for `setupBootPaging`, which runs before
/// paging, and wrong for everything after, once the identity mapping is gone.
/// Every post-paging access goes through here.
fn pageDirectory() *[1024]u32 {
    return @ptrFromInt(physToVirt(@intFromPtr(&boot_page_directory)));
}

/// Remove the identity mapping. Called once the kernel is executing from its
/// virtual addresses; afterwards the low 3 GiB belongs entirely to user space.
pub fn dropIdentityMapping() void {
    const dir = pageDirectory();
    var i: usize = 0;
    while (i < IDENTITY_MIB / 4) : (i += 1) dir[i] = 0;
    flushAll();
}

pub inline fn flushAll() void {
    asm volatile (
        \\ movl %%cr3, %%eax
        \\ movl %%eax, %%cr3
        ::: .{ .eax = true, .memory = true });
}

pub inline fn invalidatePage(virt: usize) void {
    asm volatile ("invlpg (%[v])"
        :
        : [v] "r" (virt),
        : .{ .memory = true });
}

pub inline fn physToVirt(phys: usize) usize {
    return phys + KERNEL_VMA;
}

/// True when a physical address falls inside the linear map.
///
/// Anything else, device apertures above RAM, needs `mapMmio`, and treating
/// it as linear would silently produce an address in user space.
pub inline fn isLinear(phys: usize) bool {
    return phys < LINEAR_MAP_BYTES;
}

pub inline fn virtToPhys(virt: usize) usize {
    return virt - KERNEL_VMA;
}

/// Index of the first page-directory entry belonging to the kernel.
const KERNEL_PDE_START = KERNEL_VMA / LARGE_PAGE_SIZE;

/// A process address space.
///
/// The kernel half is shared by every address space, the same 4 MiB entries,
/// copied at creation and never changed afterwards, so a syscall needs no CR3
/// switch and the kernel is addressable no matter which process is running.
/// Only the low 3 GiB differs between processes.
pub const AddressSpace = struct {
    /// Physical address of the page directory.
    pd_phys: usize,

    pub const Error = error{OutOfMemory};

    pub fn create() Error!AddressSpace {
        const pmm = @import("../../kernel/pmm.zig");
        const phys = pmm.allocFrame() catch return error.OutOfMemory;

        const dir: *[1024]u32 = @ptrFromInt(physToVirt(phys));
        @memset(dir, 0);

        // Share the kernel half. These entries carry the global flag, so they
        // survive the TLB flush that a CR3 reload would otherwise cause.
        const boot = pageDirectory();
        var i = KERNEL_PDE_START;
        while (i < 1024) : (i += 1) dir[i] = boot[i];

        return .{ .pd_phys = phys };
    }

    /// Release every user page and page table this space owns.
    ///
    /// Kernel entries are shared and must not be touched, which is why the loop
    /// stops at KERNEL_PDE_START.
    pub fn destroy(self: *AddressSpace) void {
        const pmm = @import("../../kernel/pmm.zig");
        const dir: *[1024]u32 = @ptrFromInt(physToVirt(self.pd_phys));

        for (dir[0..KERNEL_PDE_START]) |pde| {
            if (pde & Flags.present == 0) continue;
            const table: *[1024]u32 = @ptrFromInt(physToVirt(pde & 0xFFFF_F000));
            for (table) |pte| {
                if (pte & Flags.present != 0) pmm.freeFrame(pte & 0xFFFF_F000);
            }
            pmm.freeFrame(pde & 0xFFFF_F000);
        }

        pmm.freeFrame(self.pd_phys);
        self.pd_phys = 0;
    }

    /// Map one 4 KiB page into the user half.
    ///
    /// Kernel mappings use 4 MiB pages and never come through here; user
    /// mappings need 4 KiB granularity because a process's code, data and stack
    /// are not megabyte-aligned and must not share protection with each other.
    pub fn map(self: *AddressSpace, virt: usize, phys: usize, writable: bool) Error!void {
        if (virt >= KERNEL_VMA) return error.OutOfMemory;

        const pmm = @import("../../kernel/pmm.zig");
        const dir: *[1024]u32 = @ptrFromInt(physToVirt(self.pd_phys));

        const pd_index = virt >> 22;
        const pt_index = (virt >> 12) & 0x3FF;

        var pde = dir[pd_index];
        if (pde & Flags.present == 0) {
            const table_phys = pmm.allocFrame() catch return error.OutOfMemory;
            const table: *[1024]u32 = @ptrFromInt(physToVirt(table_phys));
            @memset(table, 0);
            pde = @as(u32, @intCast(table_phys)) | Flags.present | Flags.write | Flags.user;
            dir[pd_index] = pde;
        }

        const table: *[1024]u32 = @ptrFromInt(physToVirt(pde & 0xFFFF_F000));
        table[pt_index] = @as(u32, @intCast(phys)) | Flags.present | Flags.user |
            (if (writable) Flags.write else 0);

        if (isActive(self.*)) invalidatePage(virt);
    }

    /// Make this the current address space.
    pub fn activate(self: AddressSpace) void {
        asm volatile ("movl %[pd], %%cr3"
            :
            : [pd] "r" (self.pd_phys),
            : .{ .memory = true });
    }
};

fn isActive(space: AddressSpace) bool {
    return readCr3() == space.pd_phys;
}

pub fn readCr3() usize {
    return asm volatile ("movl %%cr3, %[out]"
        : [out] "=r" (-> usize),
    );
}

/// The address space the kernel booted with, used by kernel-only threads.
pub fn kernelAddressSpace() AddressSpace {
    return .{ .pd_phys = @intFromPtr(&boot_page_directory) };
}

/// Next free virtual address in the MMIO window.
var mmio_next: usize = MMIO_BASE;

pub const MmioError = error{NoAddressSpace};

/// Map a device aperture into the kernel half and return its virtual address.
///
/// Large pages, so no page tables are needed and the mapping costs one
/// directory entry per 4 MiB. Apertures are naturally large and long-lived,
/// a framebuffer is mapped once at boot and never unmapped, so there is
/// nothing to gain from finer granularity and a TLB entry per 4 KiB to lose.
///
/// Mapped cacheable. Correct for a framebuffer, which behaves like memory;
/// registers that must not be cached will need a PAT- or MTRR-based
/// alternative, and the framebuffer itself wants write-combining eventually
/// (design/00-vibeee.md §8).
pub fn mapMmio(phys: usize, len: usize) MmioError!usize {
    const start = std.mem.alignBackward(usize, phys, LARGE_PAGE_SIZE);
    const end = std.mem.alignForward(usize, phys + len, LARGE_PAGE_SIZE);
    const span = end - start;

    if (mmio_next + span > 0xFFFF_FFFF - LARGE_PAGE_SIZE) return error.NoAddressSpace;

    const virt_base = mmio_next;
    const dir = pageDirectory();

    var offset: usize = 0;
    while (offset < span) : (offset += LARGE_PAGE_SIZE) {
        const pde_index = (virt_base + offset) / LARGE_PAGE_SIZE;
        dir[pde_index] = @as(u32, @intCast(start + offset)) |
            Flags.present | Flags.write | Flags.large | Flags.global;
    }

    mmio_next += span;
    flushAll();

    // Return the address of the requested byte, not of the aligned page it
    // happens to start in.
    return virt_base + (phys - start);
}

/// Typed view of a physical address in the linear map.
pub fn physPtr(comptime T: type, phys: usize) T {
    return @ptrFromInt(physToVirt(phys));
}

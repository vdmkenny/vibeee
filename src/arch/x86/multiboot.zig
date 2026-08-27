//! Multiboot 1 header + entry. This is the *development* boot path
//! (`qemu -kernel`, GRUB); the real machine boots through boot/stage1+stage2
//! from the SD card and converges on the same kernel entry.
//!
//! Multiboot 1 rather than 2 because that is what `qemu-system-i386 -kernel`
//! implements, and a one-command boot is the point of this path. GRUB speaks
//! both.

const std = @import("std");
const bootinfo = @import("../../kernel/bootinfo.zig");
const boot = @import("boot.zig");
const paging = @import("paging.zig");

const BOOTLOADER_MAGIC: u32 = 0x2BADB002;

// Multiboot 1 header, written in assembly so it can name linker symbols.
//
// Flags: bit 0 page-aligns modules, bit 1 requests the memory map, and bit 16
// selects the "a.out kludge", the address fields below. The kludge is not
// optional here: QEMU's ELF path loads segments at their *virtual* addresses,
// and this kernel is linked at 0xC0100000, so without it the load lands past
// the end of RAM and the guest triple-faults immediately.
comptime {
    asm (
        \\.section .multiboot,"a",@progbits
        \\.align 4
        \\multiboot_header:
        \\.long 0x1BADB002
        \\.long 0x00010003
        \\.long -(0x1BADB002 + 0x00010003)
        \\.long multiboot_header
        \\.long __kernel_phys_start
        \\.long __load_end_phys
        \\.long __bss_end_phys
        \\.long _start
        // Restore the default section so later global assembly is not silently
        // emitted into `.multiboot`.
        \\.section .text,"ax",@progbits
    );
}

/// Multiboot hands us eax = magic, ebx = info pointer, and no usable stack.
export fn _start() linksection(".text.boot") callconv(.naked) noreturn {
    asm volatile (
        \\ cli
        \\ cld
        \\ movl %[stack_top], %%esp
        \\ xorl %%ebp, %%ebp
        \\ pushl $0
        \\ popfl
        \\ cmpl %[mb_magic], %%eax
        \\ jne 1f
        \\ pushl %%ebx
        \\ pushl %[kind_mb]
        \\ jmp 2f
        \\ 1:
        \\ pushl $0
        \\ pushl %[kind_unknown]
        \\ 2:
        \\ call enterHigherHalfC
        \\ 3: hlt
        \\ jmp 3b
        :
        : [stack_top] "i" (@intFromPtr(&boot.boot_stack) + boot.boot_stack.len),
          [mb_magic] "i" (BOOTLOADER_MAGIC),
          [kind_mb] "i" (@intFromEnum(boot.Handoff.multiboot)),
          [kind_unknown] "i" (@intFromEnum(boot.Handoff.unknown)),
    );
}

/// Thin C-ABI shim so the naked entry stubs can push arguments normally.
export fn enterHigherHalfC(kind: u32, ptr: u32) linksection(".text.boot") callconv(.c) noreturn {
    boot.enterHigherHalf(@enumFromInt(kind), ptr);
}

const MbInfo = extern struct {
    flags: u32,
    mem_lower: u32,
    mem_upper: u32,
    boot_device: u32,
    cmdline: u32,
    mods_count: u32,
    mods_addr: u32,
    syms: [4]u32,
    mmap_length: u32,
    mmap_addr: u32,
};

/// Which of the info structure's fields the loader filled in.
const Provided = packed struct(u32) {
    _0: u2 = 0,
    cmdline: bool = false,
    _3: u3 = 0,
    memory_map: bool = false,
    _rest: u25 = 0,
};

/// One memory-map entry. `size` excludes itself, so advancing means
/// `p += size + 4`, a classic off-by-four if read carelessly.
const MmapEntry = extern struct {
    size: u32,
    base_addr: u64 align(4),
    length: u64 align(4),
    type: u32,
};

/// Translate the bootloader's info block into our BootInfo.
///
/// Runs after paging is on, so every physical address from the bootloader has
/// to be read through the linear map.
pub fn translate(bi: *bootinfo.BootInfo, info_phys: u32) void {
    bi.* = std.mem.zeroes(bootinfo.BootInfo);
    bi.magic = bootinfo.MAGIC;
    bi.version = bootinfo.VERSION;
    bi.source = .multiboot;

    if (info_phys == 0) return;
    const info: *const MbInfo = @ptrFromInt(paging.physToVirt(info_phys));

    const provided: Provided = @bitCast(info.flags);
    if (provided.cmdline and info.cmdline != 0) {
        const str: [*:0]const u8 = @ptrFromInt(paging.physToVirt(info.cmdline));
        const s = std.mem.span(str);
        const n = @min(s.len, bi.cmdline.len - 1);
        @memcpy(bi.cmdline[0..n], s[0..n]);
        bi.cmdline_len = @intCast(n);
    }

    if (provided.memory_map and info.mmap_addr != 0) {
        var p: u32 = info.mmap_addr;
        const end = info.mmap_addr + info.mmap_length;
        while (p + @sizeOf(MmapEntry) <= end and bi.mmap_len < bi.mmap.len) {
            const e: *const MmapEntry = @ptrFromInt(paging.physToVirt(p));
            bi.mmap[bi.mmap_len] = .{
                .base = e.base_addr,
                .len = e.length,
                .kind = bootinfo.MemKind.fromE820(e.type),
            };
            bi.mmap_len += 1;
            p += e.size + 4;
        }
    } else {
        // Coarse fallback. Less accurate, but enough to bring the allocator up
        // and report something truthful.
        bi.mmap[0] = .{ .base = 0, .len = @as(u64, info.mem_lower) * 1024, .kind = .usable };
        bi.mmap[1] = .{ .base = 0x100000, .len = @as(u64, info.mem_upper) * 1024, .kind = .usable };
        bi.mmap_len = 2;
    }

    bi.rsdp = findRsdp() orelse 0;
}

/// Locate the ACPI RSDP the legacy way: the EBDA's first kilobyte, then the
/// BIOS ROM area. On the real machine stage2 does this in real mode and passes
/// the address down.
fn findRsdp() ?u32 {
    const ebda_seg: u16 = @as(*const u16, @ptrFromInt(paging.physToVirt(0x40E))).*;
    if (ebda_seg != 0) {
        const ebda: u32 = @as(u32, ebda_seg) << 4;
        if (scan(ebda, ebda + 1024)) |addr| return addr;
    }
    return scan(0xE0000, 0x100000);
}

fn scan(start: u32, end: u32) ?u32 {
    var p = start;
    while (p + 20 <= end) : (p += 16) { // the RSDP is 16-byte aligned
        const candidate: [*]const u8 = @ptrFromInt(paging.physToVirt(p));
        if (!std.mem.eql(u8, candidate[0..8], "RSD PTR ")) continue;
        // Verify the ACPI 1.0 checksum: the signature alone turns up in
        // unrelated data often enough to matter.
        var sum: u8 = 0;
        for (candidate[0..20]) |b| sum +%= b;
        if (sum == 0) return p;
    }
    return null;
}

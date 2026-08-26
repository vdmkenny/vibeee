//! The one structure every boot path must produce.
//!
//! Two producers exist: boot/stage2 (the SD-card path on real hardware) and
//! arch/x86/multiboot.zig (`qemu -kernel` / GRUB, for development). The kernel
//! proper never learns which one ran.
//!
//! This struct is ABI, shared with NASM/Zig stage2 code — `extern struct`,
//! explicit sizes, no Zig layout assumptions.

const std = @import("std");

pub const MAGIC: u32 = 0x0EEEB007;
pub const VERSION: u16 = 1;

pub const BootSource = enum(u16) {
    /// boot/stage2.asm, the path the real machine takes.
    stage2 = 0,
    /// `qemu -kernel` or GRUB, used for development.
    multiboot = 1,
};

pub const MemKind = enum(u32) {
    usable = 1,
    reserved = 2,
    acpi_reclaim = 3,
    acpi_nvs = 4,
    bad = 5,

    /// E820 and Multiboot2 use the same numbering for the types we care about;
    /// anything unrecognised is treated as reserved, which is the safe default.
    pub fn fromE820(v: u32) MemKind {
        return switch (v) {
            1 => .usable,
            3 => .acpi_reclaim,
            4 => .acpi_nvs,
            5 => .bad,
            else => .reserved,
        };
    }
};

pub const MemRange = extern struct {
    base: u64,
    len: u64,
    kind: MemKind,
    _pad: u32 = 0,
};

/// Physical address 0x6000 on the stage2 path. Fields are append-only; bump
/// VERSION when the layout changes so a stale stage2 fails loudly.
pub const BootInfo = extern struct {
    magic: u32,
    version: u16,
    source: BootSource,

    /// Physical range of the kernel image as loaded.
    kernel_phys: u32 = 0,
    kernel_len: u32 = 0,

    /// Physical range of the compressed rootfs container (0 if none).
    rootfs_phys: u32 = 0,
    rootfs_len: u32 = 0,

    /// Physical address of the ACPI RSDP, 0 if not found.
    rsdp: u32 = 0,

    /// MBR disk signature + partition index we booted from, for remounting the
    /// same medium later through usbd (see design/01-boot.md).
    disk_sig: u32 = 0,
    boot_partition: u8 = 0,
    _pad0: u8 = 0,

    cmdline_len: u16 = 0,
    cmdline: [256]u8 = std.mem.zeroes([256]u8),

    /// stage2's text log, imported into dmesg. This is how early-boot failures
    /// are visible on a machine with no serial port.
    log_len: u32 = 0,
    log_phys: u32 = 0,

    mmap_len: u32 = 0,
    mmap: [32]MemRange = std.mem.zeroes([32]MemRange),

    pub fn cmdlineSlice(self: *const BootInfo) []const u8 {
        return self.cmdline[0..@min(self.cmdline_len, self.cmdline.len)];
    }

    pub fn memoryMap(self: *const BootInfo) []const MemRange {
        return self.mmap[0..@min(self.mmap_len, self.mmap.len)];
    }

    /// Total usable RAM in bytes, for reporting and for sizing the PMM bitmap.
    pub fn usableBytes(self: *const BootInfo) u64 {
        var total: u64 = 0;
        for (self.memoryMap()) |r| {
            if (r.kind == .usable) total += r.len;
        }
        return total;
    }
};

// This struct is written by 16-bit assembly (boot/stage2.asm) using hardcoded
// offsets. Assert them here so a field insertion breaks the build instead of
// silently producing a kernel that misreads its own boot data.
comptime {
    const expect = struct {
        fn at(comptime field: []const u8, comptime offset: usize) void {
            if (@offsetOf(BootInfo, field) != offset) @compileError(
                "BootInfo." ++ field ++ " moved: boot/stage2.asm must be updated to match",
            );
        }
    };
    expect.at("magic", 0);
    expect.at("version", 4);
    expect.at("source", 6);
    expect.at("kernel_phys", 8);
    expect.at("kernel_len", 12);
    expect.at("rsdp", 24);
    expect.at("disk_sig", 28);
    expect.at("boot_partition", 32);
    expect.at("cmdline_len", 34);
    expect.at("cmdline", 36);
    expect.at("log_len", 292);
    expect.at("log_phys", 296);
    expect.at("mmap_len", 300);
    expect.at("mmap", 304);

    if (@sizeOf(MemRange) != 24) @compileError("MemRange size changed; stage2 copy stride is 24");
}

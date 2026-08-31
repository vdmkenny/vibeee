//! Builds the bootable SD-card image.
//!
//! A host tool rather than a pile of `dd` invocations in the Makefile: the
//! layout arithmetic, the stage2 header patching, and the partition table all
//! need to agree with each other, and expressing that agreement once in typed
//! code is what stops them drifting apart. It also means the build needs no
//! root, no loopback mounts, and nothing platform-specific.
//!
//! Layout (see design/01-boot.md):
//!   LBA 0            MBR: stage1 + partition table
//!   LBA 1..63        stage2
//!   LBA 64..8191     kernel flat binary (~4 MiB of room)
//!   LBA 8192..32767  the root filesystem, read flat by stage2
//!   LBA 32768+       the partitions, 4 MiB-aligned for SD erase blocks
//!
//! Three partitions, because a machine that forgets everything at every
//! boot is a demonstration rather than a computer:
//!
//!   P1  boot and system   what an updater writes a new kernel into
//!   P2  /cfg              settings, which is what makes a choice stick
//!   P3  /home             files, which is what makes work stick
//!
//! Their sizes come from the caller, so the build has one place that says
//! how big anything is and this has none.

const std = @import("std");

const SECTOR = 512;
const STAGE2_LBA = 1;
const STAGE2_MAX_SECTORS = 63;
const KERNEL_LBA = 64;
const KERNEL_MAX_SECTORS = 8192 - KERNEL_LBA;

/// The root filesystem, as a plain FAT image loaded into RAM at boot.
///
/// It has to be reachable without a filesystem driver, stage2 reads it as a
/// flat run of sectors, so it lives outside any partition, between the kernel
/// and partition 1.
const ROOTFS_LBA = 8192; // 4 MiB
const ROOTFS_MAX_SECTORS = 32768 - ROOTFS_LBA; // up to 12 MiB

/// Where the partitions begin: everything below is read by sector number
/// alone, because at that point in the boot there is no filesystem driver.
const PART1_LBA = 32768; // 16 MiB

const DEFAULT_IMAGE_MB = 64;
/// What each partition gets when the caller does not say. Mirrored by the
/// build, which is where the sizes are actually decided.
const DEFAULT_PART_MB = [_]usize{ 16, 16, 16 };

const STAGE2_SIGNATURE = "VIBEEE2!";

/// Partition type 0x0C: FAT32 with LBA. Chosen so any other machine can mount
/// the boot partition to update a kernel, the recovery path when a bad flash
/// leaves the Eee unbootable.
const PART_TYPE_FAT32_LBA = 0x0C;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 5) {
        std.debug.print(
            \\usage: mkimage <stage1.bin> <stage2.bin> <kernel.bin> <out.img>
            \\               [size_mb] [cmdline] [rootfs.img] [p1_mb] [cfg_mb] [home_mb]
            \\               [WIDTHxHEIGHT]
            \\
        , .{});
        return error.Usage;
    }

    var part_mb = DEFAULT_PART_MB;
    for (&part_mb, 0..) |*mb, i| {
        if (args.len >= 9 + i) mb.* = try std.fmt.parseInt(usize, args[8 + i], 10);
    }

    const size_mb: usize = if (args.len >= 6)
        try std.fmt.parseInt(usize, args[5], 10)
    else
        DEFAULT_IMAGE_MB;

    const stage1 = try readFile(cwd, io, gpa, args[1]);
    defer gpa.free(stage1);
    const stage2 = try readFile(cwd, io, gpa, args[2]);
    defer gpa.free(stage2);
    const kernel = try readFile(cwd, io, gpa, args[3]);
    defer gpa.free(kernel);

    // Optional: an image built elsewhere (mtools) and packed in whole.
    const rootfs: []u8 = if (args.len >= 8 and args[7].len > 0)
        try readFile(cwd, io, gpa, args[7])
    else
        &.{};
    defer if (rootfs.len > 0) gpa.free(rootfs);

    const rootfs_sectors = divCeil(rootfs.len, SECTOR);
    if (rootfs_sectors > ROOTFS_MAX_SECTORS) {
        std.debug.print(
            "rootfs is {d} KiB; the reserved region holds {d} KiB. Raise PART1_LBA.\n",
            .{ rootfs.len / 1024, ROOTFS_MAX_SECTORS * SECTOR / 1024 },
        );
        return error.RootfsTooLarge;
    }

    // --- size checks, with actionable messages ---------------------------
    if (stage1.len > 440) {
        std.debug.print("stage1 is {d} bytes; must fit in 440 (the MBR code area)\n", .{stage1.len});
        return error.Stage1TooLarge;
    }
    const stage2_sectors = divCeil(stage2.len, SECTOR);
    if (stage2_sectors > STAGE2_MAX_SECTORS) {
        std.debug.print(
            "stage2 is {d} sectors; the reserved gap holds {d}. Move the kernel start LBA.\n",
            .{ stage2_sectors, STAGE2_MAX_SECTORS },
        );
        return error.Stage2TooLarge;
    }
    const kernel_sectors = divCeil(kernel.len, SECTOR);
    if (kernel_sectors > KERNEL_MAX_SECTORS) {
        std.debug.print(
            "kernel is {d} KiB; the reserved region holds {d} KiB. Raise PART1_LBA.\n",
            .{ kernel.len / 1024, KERNEL_MAX_SECTORS * SECTOR / 1024 },
        );
        return error.KernelTooLarge;
    }

    // --- assemble --------------------------------------------------------
    const total_sectors = size_mb * 1024 * 1024 / SECTOR;
    const image = try gpa.alloc(u8, total_sectors * SECTOR);
    defer gpa.free(image);
    @memset(image, 0);

    // MBR: stage1 code, then partition table, then the boot signature.
    @memcpy(image[0..stage1.len], stage1);
    writeMbr(image[0..SECTOR], total_sectors, part_mb);

    // stage2, with its header patched to say where the kernel lives.
    const s2_off = STAGE2_LBA * SECTOR;
    @memcpy(image[s2_off..][0..stage2.len], stage2);
    const cmdline: []const u8 = if (args.len >= 7) args[6] else "";
    const wanted = if (args.len >= 12) parseSize(args[11]) else null;
    try patchStage2(image[s2_off..][0..stage2.len], .{
        .kernel_sectors = kernel_sectors,
        .kernel_bytes = kernel.len,
        .cmdline = cmdline,
        .rootfs_sectors = rootfs_sectors,
        .rootfs_bytes = rootfs.len,
        .want_width = if (wanted) |v| v.w else 0,
        .want_height = if (wanted) |v| v.h else 0,
    });

    @memcpy(image[KERNEL_LBA * SECTOR ..][0..kernel.len], kernel);
    if (rootfs.len > 0) @memcpy(image[ROOTFS_LBA * SECTOR ..][0..rootfs.len], rootfs);

    try cwd.writeFile(io, .{ .sub_path = args[4], .data = image });

    std.debug.print(
        \\vibeee image: {s}
        \\  stage1  {d:>7} B  (LBA 0)
        \\  stage2  {d:>7} B  ({d} sectors at LBA {d})
        \\  kernel  {d:>7} B  ({d} sectors at LBA {d})
        \\  part 1  FAT32 at LBA {d}, {d} MiB   boot and system
        \\  part 2  FAT32 at LBA {d}, {d} MiB   /cfg
        \\  part 3  FAT32 at LBA {d}, {d} MiB   /home
        \\  total   {d} MiB
        \\  rootfs  {d:>7} B  ({d} sectors at LBA {d})
        \\  cmdline "{s}"
        \\
    , .{
        args[4],
        stage1.len,
        stage2.len,
        stage2_sectors,
        STAGE2_LBA,
        kernel.len,
        kernel_sectors,
        KERNEL_LBA,
        PART1_LBA,
        part_mb[0],
        PART1_LBA + part_mb[0] * 1024 * 1024 / SECTOR,
        part_mb[1],
        PART1_LBA + (part_mb[0] + part_mb[1]) * 1024 * 1024 / SECTOR,
        part_mb[2],
        size_mb,
        rootfs.len,
        rootfs_sectors,
        ROOTFS_LBA,
        cmdline,
    });
}

/// Find the stage2 header by signature and fill in the kernel location. Doing
/// this by signature rather than a fixed offset means stage2 can grow a prologue
/// without the tool needing to know.
const CMDLINE_MAX = 63;

const Stage2Fields = struct {
    kernel_sectors: usize,
    kernel_bytes: usize,
    cmdline: []const u8,
    rootfs_sectors: usize,
    rootfs_bytes: usize,
    /// The ceiling on the display mode when the panel will not say what it
    /// is. Zero leaves the loader's own fallback, which is what an image for
    /// an unknown machine wants: the panel is asked first either way.
    want_width: u16 = 0,
    want_height: u16 = 0,
};

fn patchStage2(buf: []u8, fields: Stage2Fields) !void {
    const idx = std.mem.indexOf(u8, buf, STAGE2_SIGNATURE) orelse {
        std.debug.print("stage2 header signature not found, is boot/stage2.asm current?\n", .{});
        return error.MissingStage2Header;
    };
    // Field order matches the header in boot/stage2.asm.
    var p = idx + STAGE2_SIGNATURE.len;

    const put = struct {
        fn u32At(b: []u8, pos: *usize, value: usize) void {
            std.mem.writeInt(u32, b[pos.*..][0..4], @intCast(value), .little);
            pos.* += 4;
        }
    };

    put.u32At(buf, &p, KERNEL_LBA);
    put.u32At(buf, &p, fields.kernel_sectors);
    put.u32At(buf, &p, fields.kernel_bytes);

    if (fields.cmdline.len > CMDLINE_MAX) {
        std.debug.print("cmdline is {d} bytes; the header holds {d}\n", .{ fields.cmdline.len, CMDLINE_MAX });
        return error.CmdlineTooLong;
    }
    @memcpy(buf[p..][0..fields.cmdline.len], fields.cmdline);
    buf[p + fields.cmdline.len] = 0;
    p += CMDLINE_MAX + 1;

    put.u32At(buf, &p, if (fields.rootfs_sectors == 0) 0 else ROOTFS_LBA);
    put.u32At(buf, &p, fields.rootfs_sectors);
    put.u32At(buf, &p, fields.rootfs_bytes);

    std.mem.writeInt(u16, buf[p..][0..2], fields.want_width, .little);
    std.mem.writeInt(u16, buf[p + 2 ..][0..2], fields.want_height, .little);
}

/// A "WIDTHxHEIGHT" argument, or null for the loader's own default.
fn parseSize(text: []const u8) ?struct { w: u16, h: u16 } {
    const x = std.mem.indexOfScalar(u8, text, 'x') orelse return null;
    const w = std.fmt.parseInt(u16, text[0..x], 10) catch return null;
    const h = std.fmt.parseInt(u16, text[x + 1 ..], 10) catch return null;
    if (w == 0 or h == 0) return null;
    return .{ .w = w, .h = h };
}

/// One partition table entry.
fn writeEntry(entry: []u8, kind: u8, bootable: bool, lba: usize, sectors: usize) void {
    @memset(entry, 0);
    if (sectors == 0) return;

    entry[0] = if (bootable) 0x80 else 0x00;
    // CHS fields are left as the "use LBA" sentinel (0xFE FF FF). Nothing in
    // our boot path reads CHS, and inventing plausible geometry for a medium
    // the BIOS translates arbitrarily would be worse than admitting we do not
    // know it.
    entry[1] = 0xFE;
    entry[2] = 0xFF;
    entry[3] = 0xFF;
    entry[4] = kind;
    entry[5] = 0xFE;
    entry[6] = 0xFF;
    entry[7] = 0xFF;
    std.mem.writeInt(u32, entry[8..][0..4], @intCast(lba), .little);
    std.mem.writeInt(u32, entry[12..][0..4], @intCast(sectors), .little);
}

fn writeMbr(mbr: []u8, total_sectors: usize, part_mb: [3]usize) void {
    // Disk signature at 0x1B8. Fixed rather than random so an image build is
    // reproducible; the installer rewrites it per-medium.
    std.mem.writeInt(u32, mbr[0x1B8..][0..4], 0x0EEE_0001, .little);

    // The first partition is the bootable one; the rest carry what has to
    // survive a reboot. A size of zero leaves its entry empty rather than
    // writing a partition of nothing.
    var lba: usize = PART1_LBA;
    for (part_mb, 0..) |mb, i| {
        var sectors = mb * 1024 * 1024 / SECTOR;
        if (lba >= total_sectors) sectors = 0;
        // The last one takes whatever is left rather than running past the
        // end of a medium that turned out smaller than the layout.
        if (sectors != 0 and lba + sectors > total_sectors) sectors = total_sectors - lba;

        writeEntry(mbr[0x1BE + i * 16 ..][0..16], PART_TYPE_FAT32_LBA, i == 0, lba, sectors);
        lba += sectors;
    }
    @memset(mbr[0x1BE + 3 * 16 ..][0..16], 0);

    mbr[510] = 0x55;
    mbr[511] = 0xAA;
}

fn divCeil(n: usize, d: usize) usize {
    return (n + d - 1) / d;
}

fn readFile(
    dir: std.Io.Dir,
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
) ![]u8 {
    return dir.readFileAlloc(io, path, gpa, .limited(16 * 1024 * 1024)) catch |err| {
        std.debug.print("cannot read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
}

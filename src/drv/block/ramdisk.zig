//! Block device over a region of memory.
//!
//! Its purpose is specific: on the target machine the SD card sits behind a USB
//! card reader, so the BIOS can read it in real mode but the kernel cannot
//! reach it at all until a USB stack exists. stage2 therefore copies the root
//! filesystem into RAM before leaving real mode, and this presents that copy as
//! a block device so the ordinary FAT driver can mount it.
//!
//! It is also simply useful: a filesystem in RAM needs no driver working to be
//! mountable, which makes it the right place for a recovery environment.

const block = @import("../../kernel/block.zig");
const console = @import("../../kernel/console.zig");
const hal = @import("../../kernel/hal.zig");

const Disk = struct {
    data: []u8,
    name: [8]u8,
    name_len: usize,
    read_only: bool,

    fn nameSlice(self: *const Disk) []const u8 {
        return self.name[0..self.name_len];
    }
};

var disks: [2]Disk = undefined;
var disk_count: usize = 0;

fn read(ctx: *anyopaque, lba: u64, buf: []u8) block.Error!void {
    const disk: *Disk = @ptrCast(@alignCast(ctx));
    // The device is bounded by memory, so the address always fits a usize; the
    // check keeps a bad LBA from wrapping rather than faulting.
    if (lba > disk.data.len / block.SECTOR_SIZE) return error.OutOfRange;
    const offset: usize = @intCast(lba * block.SECTOR_SIZE);
    if (offset + buf.len > disk.data.len) return error.OutOfRange;
    @memcpy(buf, disk.data[offset..][0..buf.len]);
}

fn write(ctx: *anyopaque, lba: u64, buf: []const u8) block.Error!void {
    const disk: *Disk = @ptrCast(@alignCast(ctx));
    if (disk.read_only) return error.NotSupported;
    if (lba > disk.data.len / block.SECTOR_SIZE) return error.OutOfRange;
    const offset: usize = @intCast(lba * block.SECTOR_SIZE);
    if (offset + buf.len > disk.data.len) return error.OutOfRange;
    @memcpy(disk.data[offset..][0..buf.len], buf);
}

/// Nothing to do: the medium is memory, so a write has already landed by the
/// time it returns. Present so callers need no special case.
fn flush(_: *anyopaque) block.Error!void {}

const ops = block.Ops{ .read = read, .write = write, .flush = flush };

/// Register a memory region as a block device.
///
/// Writable by default: a RAM root that cannot be written to is useless for
/// anything that wants a scratch file, and the contents are discarded at power
/// off regardless.
pub fn register(phys: usize, len: usize, read_only: bool) ?*const block.Device {
    if (disk_count >= disks.len or len < block.SECTOR_SIZE) return null;

    const disk = &disks[disk_count];
    const ptr: [*]u8 = @ptrFromInt(hal.physToVirt(phys));

    disk.* = .{
        .data = ptr[0..len],
        .name = undefined,
        .name_len = 0,
        .read_only = read_only,
    };
    disk.name[0] = 'r';
    disk.name[1] = 'd';
    disk.name[2] = '0' + @as(u8, @intCast(disk_count));
    disk.name_len = 3;
    disk_count += 1;

    const dev = block.Device{
        .name = disk.nameSlice(),
        .ctx = disk,
        .ops = &ops,
        .sectors = len / block.SECTOR_SIZE,
        .read_only = read_only,
        // The whole point of this driver: what is written here lasts until the
        // machine is switched off, and a caller saving a choice should be able
        // to find that out before it appears to have worked.
        .is_volatile = true,
    };

    // Deliberately not wrapped in the block cache: the backing store is already
    // RAM, so a cache would only copy memory to other memory.
    block.register(dev);

    console.info("ramdisk", "{s}: {d} KiB at {x:0>8}{s}", .{
        disk.nameSlice(), len / 1024, phys, if (read_only) ", read-only" else "",
    });

    return block.find(disk.nameSlice());
}

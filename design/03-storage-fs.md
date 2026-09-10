# vibeee 03: Storage & Filesystems

> **Status: partially implemented.**
>
> Built and working: the block layer with partition parsing ([`block.zig`](../src/kernel/block.zig)), the block cache ([`bcache.zig`](../src/kernel/bcache.zig)), FAT12/16/32 with VFAT long names ([`fat.zig`](../src/kernel/fat.zig)), the mount table and longest-prefix path resolution ([`vfs.zig`](../src/kernel/vfs.zig)), reads and writes through ATA PIO ([`drv/block/ata.zig`](../src/drv/block/ata.zig)), removable media through usbd, and the boot ramdisk.
>
> Not yet: bus-master DMA (§3, designed and not built), the page cache, and the request queue of §4. There is no swap and there will not be one.
>
> Where this document and [`00-vibeee.md`](00-vibeee.md) disagree, the master design
> wins: it carries later decisions this document predates.

Status: design v1. Owner: storage subsystem. Targets kernel contracts v0.

## 1. Overview

Storage stack, bottom to top:

```
[in-kernel]  ata ─────────┐
[userspace]  usbd MSC ── ublk bridge ──┤
                                       ├── blockdev core (FIFO queue, merge, MBR scan, partitions)
                                       ├── page/buffer cache (4 KiB, reclaimable)
              ┌────────────────────────┘
              ├── fatfs   (FAT16/32 + VFAT LFN: every volume, every medium)
              └── ramdisk (the root, loaded by the bootloader)
```

**One on-disk filesystem, and it is not ours.** FAT is what the boot path already
has to read, what every other machine can read, and what the card in the reader
arrives formatted as. A filesystem of our own would have to be written, made
crash-safe, and then debugged against a device whose FTL nobody has
characterised, in exchange for advantages this machine never spends: there is no
database here, no sustained small-write load, nothing that a log structure would
rescue. The cost of being unable to read the disk from another computer, on a
machine whose whole recovery story is a card reader, is far higher than the
throughput it would buy.

What FAT costs is accepted rather than papered over: no journal, so a power cut
during a write can lose the file being written. Writes are ordered so the loss
is bounded to that file, and anything the system must not lose is written under
a new name and renamed over the old one.

Rename is not atomic either, but replacing an existing file comes closer than
anything else here: the directory record already carrying that name is
repointed at the new content in a single sector write, rather than being
deleted and rebuilt. The name therefore means the old file or the new one and
never nothing, and the old content is only freed once nothing names it. That
one property is what makes write-then-rename worth doing at all.

Design center: one soldered 4 GB PATA SSD (SM223AC: 28-bit LBA, no READ/WRITE MULTIPLE, UDMA/66, ~30 MB/s seq read, ~20 MB/s seq write, **1–3 MB/s small random writes**, unknown power-loss behavior in the FTL), plus removable SD/USB media. Everything that writes is shaped around two facts: small random writes are ~10× slower than sequential, and the user *will* yank power. Therefore: read-only root, bounded dirty age everywhere, no swap.

## 2. Hardware facts used (with research confidence)

| Fact | Value | Confidence |
|---|---|---|
| IDE function | 00:1f.2, 8086:2653, subsys 1043:82d8, combined/legacy mode | HIGH |
| SSD channel | secondary: cmd 0x170–0x177, ctl 0x376, IRQ 15, BMDMA 0xFFA8 | HIGH (verbatim dmesg) |
| SATA channel | primary: 0x1F0/0x3F6, BMDMA 0xFFA0, IRQ 14, **no ports wired** | HIGH |
| Device | `SILICONMOTION SM223AC`, ATA-4, 7,815,024 sectors (3.73 GiB), blank firmware string | HIGH |
| LBA | 28-bit only, no LBA48; `multi 0` → no READ/WRITE MULTIPLE | HIGH |
| UDMA | device max UDMA/66; cable-detect bits lie (soldered trace), force 80-wire assumption, precedent: mainline `ich_laptop[]` quirk {0x2653,0x1043,0x82D8} | HIGH |
| Performance | seq rd ~30–34 MB/s, seq wr ~20–23 MB/s, 4K wr ~2 MB/s, 0.5K wr ~1.3 MB/s, access 0.5 ms | MEDIUM (screenshot-derived) |
| NAND | 4× 8 Gbit SLC large-block (erase block 128–256 KiB class, page 2 KiB) | HIGH chips / LOW block size (inferred) |
| SM223 internals | wear-leveling/SMART/FLUSH support **unknown** | explicitly LOW → probe at runtime |
| SD reader | internal USB MSC 0951:1606 (ENE UB6225) via usbd; boot medium | HIGH |
| MCFG ECAM | 0xE0000000 (config access for 0x40–0x54 timing regs) | HIGH |
| Mini-PCIe "Flash_con" | inserting a card disables onboard SSD, driver must tolerate empty channel | MEDIUM-HIGH |
| ASUS precedent | ext2 RO root + unionfs overlay, noop elevator, noatime, tmpfs for logs | HIGH |

## 3. In-kernel PATA driver (`drv/block/ata.zig`)

### 3.1 What it is now

The driver is one file. It transfers by PIO and polls for completion. Both
legacy channels are probed, because the emulator and the machine disagree about
where the disk is: QEMU puts `-drive if=ide` on the primary, and the 701's
soldered SSD is secondary master. Each drive found is wrapped in the block
cache and registered, and its partitions scanned.

The transfer path is `rep insw` or `rep outsw`, 256 words per sector, with a
status poll between sectors. Every byte crosses the CPU, which caps the
transfer itself at the 2 to 4 MB/s §3.8 calls rescue speed. The device is
rated for 30 MB/s sequential read and 20 MB/s write (§2), so the transfer runs
about ten times under what the hardware can carry.

Throughput at the top of the filesystem is a separate number and is lower
again: around 450 KB/s, measured as a four megabyte file landing over the
network in nine seconds and the same four megabytes copied on the machine
itself in fifteen. The difference between the two numbers is not in the
transfer and is not addressed here. It is worth measuring once the transfer is
no longer the limit.

The PCI match table in [`drivers.zig`](../src/drivers.zig) attaches the driver
and passes it the matched device, which `attachAta` discards. That parameter is
where the bus-master registers come from.

### 3.2 What DMA changes, and what it does not

The `block.Ops` interface does not change. `read`, `write` and `flush` stay
synchronous calls that return when the data has moved, because that is what
every caller above expects and none of them can use anything else yet: there is
no request queue (§4 is unbuilt) and no page cache. DMA replaces how the bytes
cross, not who waits for them.

PIO stays. It is the rescue path of §3.8's ladder, and the only path on a
controller with no bus-master registers or a drive not running a DMA mode.

### 3.3 Transfers are staged

**A caller's buffer cannot be handed to the controller.** `sys_read` validates
the user's pointer and passes that slice down unchanged, through
`vfs.readAt` into `fat.readAt`, which now hands whole sector runs straight to
the device. The address is therefore a user virtual one: it is mapped in the
current address space only, `hal.virtToPhys` does not apply to it because that
is a subtraction over the kernel's linear window, and its pages need not be
physically adjacent. `sys_write` is the same in the other direction. The
buffers reaching the driver are a mixture of those, block-cache lines, and
kernel stack, and the driver cannot tell them apart.

So a channel that bus-masters owns one staging area in memory it allocated
itself. A read fills the staging area and is copied out; a write is copied in
and then sent. The copy runs at memory speed against a transfer that would
otherwise cost the CPU every byte, so it is a small fraction of what it
replaces. PIO needs none of this and writes straight to the caller's memory:
nothing but the CPU touches it.

Staging also bounds the descriptor table. The staging area is one physically
contiguous run at an address the driver chose, so the table has at most two
entries, and the rule that an entry may not cross a 64 KiB boundary is checked
once at bring-up instead of per request. There is no page pinning, no walk of a
user page table, and no way for a buffer that was valid at the check to be
unmapped before the controller reaches it.

Going zero-copy later is a change to the interface above, not to this driver: it
needs a way for a caller to say "this buffer is already device-addressable",
which is what a page cache would provide and what §4 would carry.

### 3.4 Structure

`Channel` becomes a thing with identity rather than three constants copied into
each drive. DMA gives a channel state that its drives share, and the hardware
enforces that they share it: one command at a time on the channel, whichever
drive it is for.

```zig
const Channel = struct {
    io: u16,
    control: u16,
    name: []const u8,
    /// The bus-master block for this channel, or null while the channel
    /// transfers by PIO: no controller BAR, or nothing on it negotiated a
    /// DMA mode.
    bm: ?Bus = null,
};

/// A channel's bus-master registers and the memory they read.
const Bus = struct {
    ports: u16,
    dma: *Dma,
    dma_phys: u32,
    /// One command at a time, and the caller of the second one waits.
    lock: lock_mod.Lock = .{},
};
```

Drives hold `*Channel`, so `CHANNELS` is a mutable array rather than a `const`
one.

The memory the controller reads is declared as a layout and taken as one
allocation, which is the shape the network drivers already use for their
descriptor rings ([`user/netd/dma.zig`](../src/user/netd/dma.zig)). The kernel
side is simpler because there is no handle and no mapping to hold: physically
contiguous frames from `pmm.allocContiguous`, addressed through the linear
window.

```zig
/// What a channel keeps in memory the controller reads and writes.
///
/// One allocation, so one physical base to derive every address from. The
/// staging area comes first because the allocation is page aligned and that
/// keeps it so.
const Dma = extern struct {
    staging: [STAGING_BYTES]u8,
    /// Two is the most the staging area can need: it is one contiguous run,
    /// and the only thing that can split it is the boundary an entry may not
    /// cross.
    table: [2]Prd,
};

/// One run of memory for the controller to move, as the specification lays
/// it out.
const Prd = packed struct(u64) {
    base: u32,
    /// Bytes, even, and zero means 65536.
    count: u16,
    _: u15 = 0,
    /// Last entry of the table.
    last: bool = false,
};
```

The lock is the channel's own, and does not repeat the block cache's. That one
is per cache, which is per disk; two drives on one channel have a cache each
and one set of task-file registers between them.

Direction is a value, not a pair of near-identical functions. `readSectors` and
`writeSectors` differ in a command byte and in which port helper moves the
data, and adding DMA to that shape would give four bodies where two differences
matter. A union over the direction carries the caller's memory with it, so the
direction and what may be done to that memory cannot disagree:

```zig
/// Which way a transfer moves.
const Direction = enum { in, out };

/// One command's worth of a caller's memory, and which way it moves.
const Chunk = union(Direction) {
    in: []u8,
    out: []const u8,
};

/// How a channel moves bytes.
const Path = enum { dma, pio };

/// The command that starts a transfer, which is the one thing the direction
/// and the path decide together.
fn commandFor(chunk: Chunk, path: Path) Command { ... }
```

One place cuts a request into commands, and one core per path runs them:

```zig
fn transfer(drive: *Drive, lba: u64, whole: Chunk) block.Error!void
fn runDma(drive: *Drive, lba: u64, chunk: Chunk) block.Error!void
fn runPio(drive: *Drive, lba: u64, chunk: Chunk) block.Error!void
```

`readSectors` and `writeSectors` are then one line each, and which core runs is
one branch on `ch.bus`. Staging is inside `runDma`, which is where it belongs:
it is what the controller needs and not what a transfer needs.

### 3.5 Register map

```
CMD  = 0x1F0 primary, 0x170 secondary   // as today
CTL  = 0x3F6 primary, 0x376 secondary   // as today
BM   = BAR4 + 0 primary, BAR4 + 8 secondary
       +0 command (bit0 start, bit3 direction: set for device to memory)
       +2 status  (bit0 active, bit1 error W1C, bit2 interrupt W1C)
       +4 table   (physical address of the descriptor table, dword aligned)
```

BAR4 is read from the matched PCI device as an `lib.pci.IoBar`, not assumed:
§2's 0xFFA0 is where one machine's firmware put it, and the emulated PIIX3 puts
it somewhere else entirely. A BAR that reads as zero, or as a memory window
rather than an I/O one, leaves the channel on PIO.

Enabling bus mastering belongs in [`drv/bus/pci.zig`](../src/drv/bus/pci.zig),
which already owns the other direction: `quiesce` clears `bus_master` for a
function whose driver is going away. Turning it on for a kernel driver is the
same register through the same `lib.pci.Command`, so it goes beside it rather
than in a driver. `user/lib/pci.zig` has `enableIoAndMaster` for the userspace
drivers; the kernel needs its own only because it reaches configuration space
by a different route.

### 3.6 Bring-up additions

`identify` currently reads words 27 to 47 for the model and 60 to 61 for the
capacity. It gains the capability words the mode negotiation needs, gathered
into one value:

```zig
/// What IDENTIFY says the drive can do. This is everything the driver knows
/// about a device, so any decision taken from it can be tested without one.
const Caps = struct {
    dma: bool,          // word 49 bit 8
    multiword: u8,      // word 63, modes supported
    udma: u8,           // word 88, modes supported
    write_cache: bool,  // word 82 bit 5
    flush: bool,        // word 83 bit 12
};

/// The fastest mode both ends can take, and the ladder down from it.
fn modesFor(caps: Caps) []const TransferMode;
```

**A mode is already running before the driver looks.** Firmware negotiates one
to boot from the drive, so word 88 or word 63 reports a selected mode, and a
mode both ends of the cable have agreed needs neither a command nor host timing
to use. The emulated drive reports UDMA5 selected. `Caps.dmaReady` is therefore
the whole of the decision: a drive that reports DMA support and a selected mode
gets a bus-master channel, and anything else transfers by PIO.

Asking for a faster mode than the firmware chose is SET FEATURES 0xEF as §2
records: UDMA4, falling back through UDMA2, MWDMA2 and PIO4 on an error bit,
with word 88 re-read to confirm what was taken. That is what needs the host
timing registers below, and it is worth doing only once there is a machine to
measure it on. It is not built.

**Host timing belongs to the chipset, not to the driver.** Writing these offsets
on the emulated PIIX3 would be writing to whatever that chipset keeps there, so
they go in their own module beside the driver, chosen by the PCI identity the
driver was attached with and doing nothing for a controller it does not
recognise. The emulated one needs nothing: it is not timing a real cable.

For ICH7, through configuration space at bus 0 device 31 function 2, with
device id 2 meaning secondary master (values verified against `ata_piix`
behaviour):

| Offset | Name | Value | Meaning |
|---|---|---|---|
| 0x42 | IDETIM_SEC | `0xA307` | decode enable (15), ISP 2 clk (13:12), RCT 3 clk (9:8), drive 0 PPE, IE, TIME (2:0). DTE stays clear because DMA is timed by the UDMA registers. |
| 0x48 | SDMA_CNT | `\|= 1 << 2` | UDMA enable for device id 2. |
| 0x4A | SDMA_TIM | bits 9:8 = 2 | CT 2, which against a 66 MHz base is UDMA4. |
| 0x54 | IDE_CONFIG | clear `0x1001 << 2`, set bit 2 | 66 MHz base clock for device id 2. Bits 7:4 are the cable report and are not read here. |

**Cable detection belongs to the machine.** IDE_CONFIG bits 7:4 report 40-wire
on the 701 because the trace is soldered, and the drive still has to run at
UDMA/66. That is a fact about one laptop, which is what
[`quirks/`](../src/quirks/) holds and what its registry matches on. Overriding
it unconditionally in the driver would drive a real 40-wire cable at a rate it
cannot carry. Linux carries the same override as `ich_laptop[]` against
{0x2653, 0x1043, 0x82D8}.

### 3.7 Completion

Polled first. The bus-master status register says when the controller is done,
and polling it is the same shape as the status poll the driver already does,
with the difference that the CPU is no longer moving the bytes in between. This
keeps the driver self-contained and, more importantly, keeps it working before
the scheduler exists. Partitions are scanned from `probe.attachAll`, which
`main` reaches at line 161 against `sched.start` at line 511. Interrupts are
already on by then, enabled at line 111, so the completion interrupt would
arrive; what is missing is a thread to block, and `Event.waitOne` has nothing
to put on a queue.

Interrupt completion is the second step and slots in behind one function. The
kernel has what it needs: `hal.claimLegacyIrq`, as the keyboard uses, and
`event.Event.waitOne` with a deadline. It is worth doing because it returns the
CPU to other threads for the duration of a transfer rather than spinning, but
it is not where the speed comes from, and it brings the pre-scheduler case with
it. `irqevent` is not the mechanism: that exists to hand a line to a Ring 3
driver, and this driver is in the kernel.

```zig
/// Wait for the controller to finish, however this channel waits.
fn awaitCompletion(ch: *Channel, deadline_us: u64) block.Error!void
```

### 3.8 Error recovery ladder

Each rung is tried in turn, and a failure moves to the next:

1. Retry the command, at most three times, logging the LBA and the error
   register.
2. Soft reset the channel: pulse SRST in the device control register, hold it
   at least 5 us, clear it, and poll for BSY to fall. Re-issue SET FEATURES,
   because the transfer mode is not guaranteed to survive a reset, reprogram
   the bus-master registers, and retry.
3. Clear `ch.bm` for this drive and fall back to PIO, which is already the
   other half of §3.4's split and needs no separate rescue path.
4. Persistent failure marks the device read-only. `block.Device` already
   carries `read_only` and `retired`, so there is nowhere new to put this.

A controller that never lowers its active bit is the timeout case and enters at
step 2. A reset that cannot clear BSY retires the device.

### 3.9 Budgets

One staging area per channel that has a DMA-capable drive, and none for a
channel that does not: a machine whose disk will only do PIO pays nothing.

`STAGING_BYTES` is 32 KiB, which is 64 sectors. The largest single call the
layers above make is one FAT cluster, and 32 KiB is the largest cluster FAT
presents in practice. A larger request is split into several commands by the
chunking loop, which is needed anyway: the sector count register is eight bits
and caps one command at 128 KiB. On the 701 the cost is 32 KiB pinned for the
one channel that has the SSD, plus sixteen bytes of descriptor table in the
same allocation.

### 3.10 Flush semantics on SM223AC

Runtime-probed, as recorded in §2 (IDENTIFY details unknown, LOW confidence):

- Word 83 bit 12 set: `flush` issues FLUSH CACHE (0xE7), never the LBA48 form,
  with a 30 s deadline. An ABRT answer is downgraded to a no-op, because
  CF-class firmware lies about supporting it.
- Not set: `flush` drains the queue and nothing more. Residual FTL risk is not
  eliminable from the host, which is why nothing that matters is written in
  place (§6, §8).

`flush` follows every write call, which is what makes the block cache's
write-through promise true. It is therefore per command and not per sector, so
how a request is cut into commands (§3.4) decides how often the drive is asked
to commit.

### 3.11 Verification

- **QEMU, every boot.** The emulated PIIX3 implements the same bus-master
  programming model, so `make check-all` exercises the DMA path as a matter of
  course. A `-drive if=ide` boot that mounts, reads and writes is the floor.
- **Both paths, same results.** A build forced to PIO and a build on DMA must
  produce byte-identical files for the same work. The transfer measurements in
  §3.1 are the comparison, and the four megabyte fetch and local copy are the
  two cases to repeat.
- **Unit tests over the capability words.** `modesFor` is a pure function from
  §3.6's `Caps` to a ladder of modes, so every rung of the fallback is testable
  with no hardware, as is the decision to leave `ch.bm` null.
- **Real hardware ladder.** Polled PIO IDENTIFY and a dump of the words first,
  because it settles the flush and write cache unknowns; then a PIO read of the
  MBR; then DMA reads with a throughput check, where roughly 30 MB/s confirms
  UDMA4 and roughly 25 means it fell back to UDMA2; then DMA writes to a
  scratch partition.

### 3.12 Not in this change

The request queue, merging and priority bands of §4. The page cache. Anything
that makes `block.Ops` asynchronous. Zero-copy into caller buffers, which needs
the page cache first. Asking for a faster transfer mode than the firmware
chose, and with it the host timing registers of §3.6 and the cable-detect
quirk: both are for the machine, and neither can be measured until there is one
to measure on.

The primary channel is still probed. §2 records that the 701 wires no ports to
it, so probing it on that machine costs BSY timeouts, and a floating bus can
read 0x7F and look like a drive. It is also where the emulator's disk is, so
skipping it unconditionally would cost every emulated boot. Skipping it on the
701 alone is a machine fact and belongs in `quirks/`, once the timeouts are
measured.

## 4. Block layer

### 4.1 Queueing: FIFO ("noop"), and why

Flash has no seek arm: request cost is dominated by the SM223 FTL's erase behavior, which the host cannot model. Elevator sorting buys nothing (community consensus on this machine was `elevator=noop`, HIGH), costs RAM and code. What *does* pay: **contiguous merge** (back/front) up to the 128 KiB command cap, because per-command overhead is real at 630 MHz, and **two priority bands**: `fg` (synchronous reads, fsync) ahead of `bg` (writeback, GC). Ordering rule: writes are never reordered relative to other writes within a device, which is what makes §6's ordering mean anything, and a `flush` bio is a full barrier: all prior writes complete → FLUSH CACHE → then later bios.

One request in flight per device (single channel, single device; UHCI/EHCI MSC is also one-at-a-time in usbd). No tagging, no NCQ-alike.

### 4.2 Interfaces (Zig)

```zig
pub const BlockError = error{ Io, Timeout, NoDevice, ReadOnly, BadRequest, MediaChanged };

pub const BlockInfo = struct {
    sectors: u64,          // 512-byte sectors
    ssize: u32 = 512,
    model: [40]u8,
    flags: packed struct { removable: bool, has_flush: bool, wcache: bool, degraded_ro: bool },
};

pub const BlockDev = struct {          // contract-v0 BlockDev, sync facade over bios
    ctx: *anyopaque,
    vt: *const VTable,
    pub const VTable = struct {
        read:  *const fn (ctx: *anyopaque, lba: u64, nsect: u32, buf: []u8) BlockError!void,
        write: *const fn (ctx: *anyopaque, lba: u64, nsect: u32, buf: []const u8) BlockError!void,
        flush: *const fn (ctx: *anyopaque) BlockError!void,
        info:  *const fn (ctx: *anyopaque) BlockInfo,
    };
};

pub const BioOp = enum(u8) { read, write, flush };
pub const Bio = struct {
    op: BioOp, prio: enum(u8) { fg, bg }, lba: u64, nsect: u32,
    pages: []CachePageRef,             // 4 KiB frames; PRD built from these
    status: BlockError!void = {},
    on_done: *const fn (*Bio) void,    // runs in driver thread context
};
pub fn blk_submit(dev: DevHandle, bio: *Bio) void;
pub fn blk_register(dev: *BlockDev, name: []const u8) DevHandle;  // also triggers partition scan
pub fn blk_unregister(dev: DevHandle) void;                       // fails in-flight with NoDevice
```

### 4.3 Partition scanning (MBR)

On `blk_register`: read LBA 0; if 0x55AA signature and ≥1 sane entry (start+len ≤ device, nonzero type) → register child devices `<name>p1..p4`; follow one extended-partition chain (types 0x05/0x0F) for camera-formatted SD cards, max 8 logicals. If no MBR but LBA 0 parses as a FAT BPB (jump opcode + sane BPB) → register whole-device as a single FAT candidate ("superfloppy", common on SD). GPT: not supported (legacy BIOS machine; document). Partition devices are offset/limit wrappers over the parent; a wrapper rejects out-of-range and forwards flush to parent.

Recognized types: 0x0B/0x0C/0x06/0x0E/0x04/0x01 (FAT), 0xEF (BootBooster, never touched). Everything else is reported and left alone, because a partition this cannot read belongs to something else that can.

### 4.4 ublk bridge (usbd-provided block devices)

usbd (USB MSC: internal SD reader 0951:1606, USB sticks) registers each LUN via `/svc/ublk`:
channel call `UBLK_ATTACH{name, sectors, ssize, removable}` + hands the kernel one shm handle + two event handles. Kernel wraps it as a BlockDev; VFS mounts it like any disk.

Shm layout (one 4 KiB header page + data area):

```zig
pub const UblkHdr = extern struct {
    magic: u32,                 // 'UBK0'
    sq_tail: u32, sq_head: u32, // kernel produces, usbd consumes
    cq_tail: u32, cq_head: u32, // usbd produces, kernel consumes
    depth: u32,                 // power of two, default 8
    slot_size: u32,             // data slot bytes, default 64 KiB
};
pub const UblkReq = extern struct {
    tag: u16, op: u8 /*0 rd,1 wr,2 flush*/, _r: u8,
    nsect: u32, lba: u64, slot: u32, _pad: u32,
};
pub const UblkCpl = extern struct { tag: u16, status: u16 /*0 ok, errno*/, _pad: u32 };
// After hdr page: depth × UblkReq, depth × UblkCpl, then depth × slot_size data slots.
```

Kernel copies between cache pages and slots (one copy, acceptable: SD path tops out ~20 MB/s; membw budget ~2% during bulk I/O). Events: `sq_doorbell` (kernel→usbd), `cq_doorbell` (usbd→kernel). Timeout 10 s/req → fail bio `Io`. usbd crash or media yank → devmgr restarts usbd → `UBLK_DETACH` semantics: kernel fails outstanding bios `NoDevice`, marks mounts dead (force-unmount, open files fail). Media-change flag from MSC UNIT ATTENTION → `MediaChanged` → unmount + rescan.

## 5. Page cache & memory policy

### 5.1 Cache

Single buffer/page cache, 4 KiB frames, keyed (DevHandle, blkno). API:

```zig
pub fn bread(dev: DevHandle, blkno: u64) BlockError!*CachePage;    // shared-locked, refcounted
pub fn bwrite_begin(dev: DevHandle, blkno: u64) BlockError!*CachePage; // excl lock, marks dirty on end
pub fn brelease(p: *CachePage) void;
pub fn readahead(dev: DevHandle, blkno: u64, n: u32) void;         // best-effort, bg prio
pub fn sync_dev(dev: DevHandle) BlockError!void;                   // writeback + flush barrier
```

- **Size**: floor 4 MiB, soft target grows opportunistically into free RAM, hard cap **96 MiB** (clean pages are reclaimable and don't count against the 48 MiB idle budget; the *idle* resident dirty+pinned share is budgeted at ≤2 MiB).
- Replacement: two-segment CLOCK (probation → protected on second touch), near-LRU2 at O(1), no per-access list surgery (membw is precious).
- Read-ahead: sequential-run detector, up to 128 KiB (one ATA command), fg reads bypass it.
- DMA goes **directly into cache pages** via PRD (zero-copy on the PATA path).

### 5.2 Dirty policy

- Global dirty cap: 4 MiB (beyond → writer throttles by taking writeback work).
- Age limit: dirty page older than 30 s → writeback (5 s for FAT metadata, §7).
- Events forcing global sync: the `sync()` syscall, suspend entry (S3, since the battery may die while asleep), ACPI battery-critical, and clean shutdown.

### 5.3 No swap, and the OOM policy that replaces it

Swap is rejected: (a) backing store small-random-writes at 1–3 MB/s makes paging catastrophically slow; (b) it burns SLC erase cycles on a soldered, non-replaceable disk; (c) 512 MiB against our ≤48 MiB idle budget leaves ~450 MiB headroom, exhaustion is a misbehaving app, not a working-set problem. ASUS shipped this machine swapless (HIGH).

Instead: **commit accounting + kill policy.**
- Anonymous-memory commit limit = RAM − kernel reserve (8 MiB) − pinned driver DMA. `mmap`/`sbrk` beyond limit fail cleanly (ENOMEM), no overcommit, so OOM kill is the backstop, not the norm.
- Pressure order: (1) drop clean cache to floor; (2) emit low-mem event on `/svc/memd` (GUI shows warning, apps may trim); (3) OOM kill: badness = anon RSS × class weight; classes from process manifests: `app` (weight 4) > `service` (2) > `gui` (1) > `core` (never). Supervisor is notified and may restart.

## 6. Persistent storage: FAT32, everywhere

Not a filesystem of our own. See §1: the reasons are the recovery story and the
absence of any workload that would repay one.

Everything that persists is FAT32 on a partition of the medium the machine
booted from, or of any medium plugged into it. One driver (§7) serves the boot
partition, the persistent partition, SD cards and USB sticks alike, so there is
one implementation to make crash-safe rather than three.

The ordering discipline in §7 is what stands in for a journal: data clusters,
then the FAT chain, then the directory entry. A power cut can leak clusters,
which any other machine reclaims, but cannot leave a directory entry pointing at
a chain that was never written. Anything the system must not lose is written
under a temporary name and renamed into place, so the old contents survive until
the new ones are complete.

## 7. FAT16/32 driver (interchange + boot partition)

- Read/write; FAT12 read-only (tiny media edge case). VFAT LFN: read + generate (UCS-2 names ≤255, sequenced 13-char entries, 8.3 alias with `~n` + checksum). Mount by BPB probe (works for superfloppy SD).
- Cluster allocator: next-free rotor (mild wear spreading, good contiguity); FSInfo free-count treated as advisory, recomputed lazily in background, corrected on unmount.
- **Yank mitigation, ordered metadata writes.** Per file operation the block-layer ordering guarantee (§4.1) is used to sequence: (1) data clusters; (2) FAT chain for those clusters (FAT copy 1 then copy 2); (3) directory entry (size/first-cluster/LFN) last. A yank can leak clusters (lost chains, harmless, reclaimed by any chkdsk) but cannot produce a dirent pointing at an unwritten chain, and cannot cross-link (allocation rotor + FAT-before-dirent).
- Dirty flag: set FAT[1] "clean shutdown" bit clear on first write, restore on unmount/sync-idle. On mounting a dirty volume: log warning, expose `dirty` in statfs (GUI shows "check this card on a PC" hint); no online fsck (out of scope, honest).
- Metadata writeback age 5 s (data 30 s); removable media default `sync_meta` mount profile: FAT+dirent flushed at ≤1 s. "Safe remove" in GUI → `sync_dev` + unmount.
- Boot partition: FAT16, 32 MiB, chosen because AMI EZ-Flash reads FAT16 USB media (BIOS-recovery friendliness) and 01-boot's INT 13h loader can navigate FAT16 trivially. If 01-boot prefers raw-sector kernel loading, driver is unaffected.
- Limits honored: no >4 GiB files (EFBIG), 2 TiB volume cap, no exFAT (licensing/scope, document; SDXC cards arrive exFAT-formatted → user reformats FAT32 in our GUI).

## 8. Configuration

Files under `/etc` (§9), on the same FAT32 volume as everything else. Written the
way §6 describes: to a temporary name, then renamed, so a configuration file is
either the old one or the new one and never half of either.

There is no separate configuration filesystem and no separate partition for one.
Config is a handful of small text files; the machinery to commit them atomically
in pairs would be larger than the files it protected.

## 9. The root, the namespace, and the shutdown story

### 9.1 The root is a FAT image in RAM

The bootloader loads a plain FAT image alongside the kernel and hands over its
address; the kernel registers those frames as a ramdisk and mounts it at `/`.
No container format of our own: the same driver that reads the boot partition
reads the root, the image is built with the same host tools that build the boot
partition, and it can be inspected on any machine by anything that reads FAT.

It is not compressed. A compressed image saves RAM at the price of a
decompressor in the boot path and a format only this system understands, and the
root is small enough that the saving is not what decides whether this machine
fits in its memory budget.

The root is rebuilt from the image at every boot. Nothing written to it
survives, which is a property rather than an accident: the system a boot starts
from is the system the image describes, and there is no accumulated state to
explain a machine's behaviour.

### 9.2 The namespace

POSIX names for the things POSIX has, and nothing for the things this system
does differently.

```
/            the boot image, in RAM, rebuilt every boot
├── bin/     every program: init, vsh, tools, eeewm, eterm, pad, ...
├── etc/     configuration                              [persistent when installed]
├── lib/     what the system loads: drivers, and the data programs read
├── tmp/     scratch, in RAM with the root, gone at reboot
├── home/    everything the user keeps                  [persistent when installed]
└── media/   removable volumes, one directory each
```

Every name is at most eight characters, because FAT stores short names in eight
and the tree should read the same on the medium as it does at a prompt.

`/bin` holds what is run by name, whether a person types it or `/etc/services`
names it. `/lib` holds what the system loads without anyone naming it, which is
why `/lib/drivers` is there and not in `/bin`: a driver is selected by matching
hardware, so it has no business in what a shell searches or completes. Each
driver sits beside its manifest, because the pair is one thing.

That line is about who does the invoking, not about privilege. The privilege
split a directory name implies is advisory, which is why there is no `/sbin`;
capabilities decide what a driver may do, and they do not care where it sits.

A subdirectory when there are several files of one kind that something looks up
by name at runtime, and flat until then. `/lib/drivers` has earned one. Keymaps
and fonts are compiled in today and would earn theirs on the day they are loaded
from disk instead.

`/etc` and `/home` are directories in the image until the machine is installed,
and mount points afterwards. A program reads `/etc/services` either way and
never learns which. The image's copies are what a live card boots from, and what
an install seeds the persistent volume with.

**What is deliberately absent, and why:**

| Not here | Because |
|---|---|
| `/dev` | There are no device files. A program reaches hardware through a capability granted at spawn and a handle it is given; `map_device`, `ioport_grant` and `irq_attach` are syscalls, and a name in a directory cannot grant a capability. `devices` reports what is on the bus. |
| `/proc`, `/sys` | `sysinfo` answers what these exist to answer, without a filesystem to serialise it through or a parser on the other end. |
| `/svc` | The service registry is a kernel namespace reached by `svc_register` and `svc_open`, not a path. The `svc` tool lists it. |
| `/usr` | The split exists because a disk filled up in 1974. There is one root here and it is small. |
| `/sbin` | See above: the split it implies is advisory, and capabilities do it for real. |
| `/root`, `/home/<user>` | One person uses this machine. |
| `/opt`, `/srv`, `/boot` | Nothing to put in them. The boot partition is read by the bootloader and never mounted. |
| `/var` | Its contents on a machine like this are panic records, which belong where their owner can find and send them: `/home`. |

### 9.3 Mounts

| Mount | Source | Policy |
|---|---|---|
| `/` | RAM, from the boot image | read-write, but volatile: gone at reboot |
| `/etc`, `/home` | FAT32 partition of the boot medium, when installed | metadata ≤1 s, data ≤5 s |
| `/media/*` | FAT on any removable volume found | metadata ≤1 s; unmounted on "safe remove" |

The kernel attaches the root and whatever it finds under `/media`. Everything
else is userspace's to decide, through `mount` and `unmount`, which need
`Caps.mount`: attaching a volume changes what every path in the system means,
which is a different power from reading a disk and is not one a driver has.

A volume is named rather than addressed. `mount hd0p1 /tmp/card` takes the name
`disk` lists, because the name is what a person can see and a path to a device
is a thing this system does not have.

`/etc/fstab` will say what to attach at boot, read from the image's copy before
anything is mounted over it, so the file that says what to mount is never the
thing waiting to be mounted. Not yet written: nothing persistent exists for it
to describe.

Global events: `sync()` flushes every mount. Shutdown, suspend and
battery-critical force one. Clean shutdown: stop programs, sync, unmount.

**Unclean shutdown**: `/` is immune, being rebuilt from the image. `/etc` and
`/home` lose at most the file being written, by §6's ordering, and never the
file it was replacing.

## 10. Bring-up & test plan

**Host-side (no hardware, continuous):** the fatfs core is pure Zig over the
BlockDev vtable, so it compiles for the host and runs under a test harness. The
harness that matters is a *power-cut fuzzer*: a file-backed BlockDev records
every write, replays a random prefix of them (with 512 B torn tails, and
reordering within what §4.1 allows), then mounts and checks that the volume is
mountable, that files written and synced are present, and that the directory
tree is consistent. Images are cross-checked against Linux `mount` and
`fsck.vfat`, and against a card written by a camera, because interchange is the
reason FAT was chosen and a format only we can read would defeat it.

**QEMU (i440FX `-machine pc`, disk as `-device ide-hd,bus=ide.1,unit=0`):**
PIIX3-IDE is register-compatible for the command block and the BMDMA hot path
(the IRQ15/0x170 path is exercised for real). Differences to seam around:
QEMU's device advertises LBA48 and READ MULTIPLE and ignores the ICH timing
registers, so the driver's `Caps` (§3.6) is populated from IDENTIFY but the
SM223 profile can be **forced** (`quirk_override=sm223`: 28-bit, multi 0,
probe-flush) and the exact production paths run under emulation. Timing-register
writes are write-and-forget, verified only on real hardware. The ublk path is
exercised end to end by a `usb-storage` device under EHCI. Root image load and
handover are fully testable in QEMU.

**Real hardware ladder:** (1) polled PIO IDENTIFY, dump words
47/49/60/61/80/82/83/85/88 to the screen, which closes the LOW-confidence
flush and write-cache unknowns, and is therefore first; (2) PIO read of the MBR;
(3) DMA reads plus a PM-timer throughput check (expect ~30 MB/s sequential,
confirming UDMA4; ~25 means it fell back to UDMA2); (4) DMA writes to a scratch
partition with a block-size sweep, to check the 1-3 MB/s small-write premise
against the device rather than against a review; (5) power-yank torture: a
scripted write load, power pulled a hundred times, `/etc` and `/home` checked
each boot; (6) the Flash_con absence path, if a mini-PCIe card is available.

**Perf acceptance:** sequential write to the persistent volume ≥15 MB/s
sustained; create-plus-sync of a 4 KiB file ≤25 ms; mount ≤0.7 s worst case;
contribution to boot ≤1.0 s (the root is already in RAM; the persistent volume
mounts asynchronously).

## 11. Budgets

**Kernel ELF share (~70 KB of 1.5 MB):** pata 6 + block and partitions 10 +
cache 10 + fatfs 25 + ramdisk 2 + ublk bridge 6 + glue 10 (KB, ReleaseSmall
estimates).
**Root image share:** `mkfs.fat` and the installer, ~40 KB.
**Idle RAM share (of 48 MiB):** the root image ~12 MiB (pinned) + FAT and driver
state ~0.2 MiB + dirty and pinned cache ≤2 MiB ≈ **14.2 MiB pinned**. Clean
cache above that is reclaimable and uncounted.

## 12. Install to a volume

Installing means giving the system somewhere to keep `/etc` and `/home` across
a boot. The target is a partition, and which medium holds it is not something
the rest of the system knows: the remaining space on the SD card the machine
booted from is as valid a target as the internal SSD, and is the safer one on a
machine whose SSD holds something else.

The installer runs from the booted system:

1. Preflight: show the target's model, size and current partition table, and
   require a typed confirmation. Refuse if the target is currently mounted, or
   if it is the medium being booted from and the request is to repartition it
   rather than to use free space on it.
2. Partition, if the target needs it. MBR, 1 MiB-aligned starts, CHS synthesized
   as 255H/63S so an old BIOS's INT 13h sees something sane: p1 `0x0E` FAT16
   32 MiB, **active**, holding the bootloader, kernel and root image; p2 `0x0C`
   FAT32 across the rest. An optional `0xEF` partition at the end is left empty
   for AMI BootBooster, which caches POST into it and takes seconds off the
   boot; the BIOS owns its contents.
3. `mkfs.fat` both, copy the bootloader stages, kernel and root image, and write
   01-boot's 440 B MBR code, preserving the partition table and disk signature.
4. Seed the persistent volume from the root image's `/etc` and `/home`, and
   write `/etc/fstab` naming it by disk signature and partition index rather
   than by enumeration order, so plugging in a second card does not move it.
5. Verify: FLUSH CACHE, then read back and compare CRC32s of the MBR, the boot
   files and the seeded tree. Only then report success.

Failure before the MBR write is a no-op. The MBR is written last, into a staging
sector and verified before being written to LBA 0, so a yank mid-install leaves
either the old table or the new one and never a mixture.

## 13. Risks & open questions

- **SM223 FTL power-loss behavior unknown (LOW).** An FTL that corrupts
  *unrelated* LBAs on a yank defeats any filesystem, ours or FAT's. Mitigated by
  keeping the boot partition read-only in normal operation, by §6's write
  ordering, and by the yank torture in §10. Residual risk is documented, not
  solved.
- **FLUSH CACHE support unknown**, so it is probed at init and falls back to
  draining the queue (§3.10). The real-hardware IDENTIFY dump is bring-up task 1.
- **FAT is not crash-safe and cannot be made so.** The bound on the damage is
  the write ordering in §6, and the bound is one file: the one being written.
  Anything that must not be lost is written under a new name and renamed over
  the old one, which §1 explains is as close to atomic as this gets.
- **A rename cannot span volumes.** Across two it would be a copy and a delete,
  which takes time proportional to the file and fails differently, so it is
  refused rather than done silently under a name that promises otherwise.
- ATTO-derived performance figures are MEDIUM confidence; the acceptance
  thresholds in §10 may need one recalibration pass against the real device.
- Open for 01-boot: the final bootinfo layout, and who owns the 440 B MBR code
  (assumed 01-boot, with the installer embedding it).
- Open for kernel-core: the final VFS vtable. The locking is settled: a
  volume is held by one operation at a time (`vfs.Lock`), since a read of
  the medium can sleep the thread and another's operation on the same
  volume would run in the gap.
- Open for usbd: ublk ring depth and slot-size negotiation, mapping UNIT
  ATTENTION to MediaChanged, and who debounces card insertion.
- Open for the GUI: how safe-remove is offered, where a low-memory warning
  appears, and how a volume that was not unmounted cleanly is reported.

## 14. Phasing

**M1 (boot and survive):** `ata` with PIO and DMA read and write and
reset-retry recovery, block core with MBR parsing, the page cache with a fixed
16 MiB cap and a simple CLOCK, the ramdisk and the root mount, which is the
boot-critical path, and fatfs read-only. Green under QEMU, plus the first
real-hardware IDENTIFY and throughput numbers.

**M2 (a place to keep things):** fatfs write with long names and ordered
metadata, the persistent mount for `/etc` and `/home`, `fstab`, the power-cut
fuzzer in CI, the ublk bridge with the removable-media lifecycle, the adaptive
cache and the out-of-memory policy, and the installer.

**M3 (hardening):** superfloppy and extended-partition edge cases, a paranoid
mode with the write cache off, the performance acceptance sweep, a hundred-cycle
yank torture sign-off, and the BootBooster partition option.

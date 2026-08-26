# vibeee 03: Storage & Filesystems

> **Status: partially implemented.**
>
> Built and working: the block layer with partition parsing ([`block.zig`](../src/kernel/block.zig)), the block cache ([`bcache.zig`](../src/kernel/bcache.zig)), FAT12/16/32 with VFAT long names ([`fat.zig`](../src/kernel/fat.zig)), the mount table and longest-prefix path resolution ([`vfs.zig`](../src/kernel/vfs.zig)), ATA PIO ([`drv/block/ata.zig`](../src/drv/block/ata.zig)) and the boot ramdisk.
>
> Not yet: writes of any kind, the page cache, swap, and mounting removable media (which needs USB first).
>
> Where this document and [`00-vibeee.md`](00-vibeee.md) disagree, the master design
> wins: it carries later decisions this document predates.

Status: design v1. Owner: storage subsystem. Targets kernel contracts v0.

## 1. Overview

Storage stack, bottom to top:

```
[in-kernel]  pata_ich6 ──┐
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

What FAT costs is accepted rather than papered over: no atomic rename, no
journal, so a power cut during a write can lose the file being written. Writes
are ordered so that the loss is bounded to that file, and anything the system
must not lose is written to a new name and renamed into place.

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

## 3. In-kernel PATA driver (`pata_ich6`)

### 3.1 Scope and non-scope

Exactly one channel (secondary), exactly one device (master). We **never touch the primary channel** (0x1F0/IRQ14/0xFFA0): no SATA ports are wired (HIGH), so probing it costs 100s of ms of BSY timeouts and a floating bus can read 0x7F and fake a device. Static config: channel 1, device 0, period. The driver still handles "no device present" gracefully: the Flash_con quirk means a mini-PCIe card in the vacant slot detaches the onboard SSD.

### 3.2 Register map (constants)

```
CMD  = 0x170  // +0 data, +1 err/feat, +2 count, +3 lba0, +4 lba1, +5 lba2, +6 dev, +7 status/cmd
CTL  = 0x376  // read: altstatus; write: devctl (bit1 nIEN, bit2 SRST)
BM   = 0xFFA8 // +0 BMIC (bit0 start, bit3 dir: 1=dev→mem), +2 BMIS (bit0 active, bit1 err W1C,
              //  bit2 irq W1C), +4 BMIDTP (PRD table phys, dword-aligned)
IRQ  = GSI 15 (ISA edge/high via IOAPIC)
PCI cfg (via ECAM bus0 dev31 fn2): 0x42 IDETIM_SEC, 0x44 SIDETIM, 0x48 SDMA_CNT,
  0x4A SDMA_TIM, 0x54 IDE_CONFIG
```

### 3.3 Init sequence

1. PCI: verify VID/DID 8086:2653; set Bus Master + I/O Space in PCICMD; read BAR4, assert it reports 0xFFA0 (else use BAR4 value +8 for secondary, do not hardcode blindly).
2. Presence probe: `outb(CMD+6, 0xA0)`; 400 ns delay (4× altstatus reads); if `inb(CMD+7)` is 0xFF or 0x7F → channel empty → register nothing, mark `ssd_absent` (boot continues from SD; log for the Flash_con case).
3. Soft reset: devctl SRST=1, hold ≥5 µs, clear; poll BSY clear (≤30 s, but bail to `ssd_absent` after 2 s if status stays 0xFF). Check signature (count=1, lba0=1, lba1=0, lba2=0 → PATA).
4. IDENTIFY DEVICE (0xEC): select 0xA0, wait DRDY, issue, poll DRQ, `rep insw` 256 words, nIEN=1 during probe (polled).
   Words consumed: 49 (LBA+DMA caps), 60–61 (LBA28 sector count, expect 7,815,024), 47 (multiple: expect 0 → PIO path is single-sector), 63 (MWDMA), 88 (UDMA supported/active; expect bit 4 = UDMA4), 80/81 (ATA-4), **82 bit5** (write cache supported), **83 bit12** (FLUSH CACHE supported), 83 bit10 (LBA48, expect 0, and we never use LBA48 regardless), 85 bit5 (write cache enabled). All stored in a `Quirks` struct, this is the test seam (§10).
5. SET FEATURES 0xEF: features=0x03, count=0x44 (UDMA4). On error bit: retry 0x42 (UDMA2) → 0x22 (MWDMA2) → 0x0C (PIO4). Re-read word 88 to confirm selection.
6. Host timing (values verified against ata_piix behavior; devid = 2 = secondary master):
   - `IDETIM_SEC(0x42) = 0xA307`, decode enable(15), ISP=2clk(13:12=10), RCT=3clk(9:8=11), drive0 PPE|IE|TIME (bits 2:0). DTE stays 0 (DMA uses UDMA regs).
   - `SDMA_CNT(0x48) |= 1<<2`: UDMA enable, devid 2.
   - `SDMA_TIM(0x4A)`: field bits 9:8 (4·devid) = CT=2 → with 66 MHz base = UDMA4.
   - `IDE_CONFIG(0x54)`: clear (0x1001<<2), set bit 2 (66 MHz base clock devid 2). Bits 7:4 are the cable-report bits, **ignored** (soldered short trace; they read "40-wire" and are wrong; Linux needed the ich_laptop quirk for exactly this).
7. Allocate one static PRD table: 40 entries × 8 B (max transfer 128 KiB in 4 KiB pages = 32 entries + slack), dma_alloc'd, dword-aligned, <4 GB (trivial). Enable IRQ15; devctl nIEN=0.

### 3.4 PRD table format

```zig
pub const Prd = packed struct {
    base: u32,  // phys addr, bit0 must be 0 (word aligned)
    count: u16, // bytes, even; 0 == 65536
    flags: u16, // bit15 = EOT (last entry)
};
// Constraint: each entry's [base, base+count) must not cross a 64 KiB boundary.
// We fill entries from 4 KiB-aligned cache pages → constraint holds by construction.
```

### 3.5 DMA hot path (read shown; write differs in BMIC dir bit and cmd 0xCA)

Per-command limits: **count register is 8-bit: 1–256 sectors (0 == 256) → max 128 KiB/command**; LBA must fit 28 bits (device is 7.8M sectors, always fits).

1. Fill PRD entries from the request's page list; set EOT on last.
2. `outl(BM+4, prd_paddr)`; `outb(BM+2, 0x06)` (clear err+irq); `outb(BM+0, 0x08)` (dir=dev→mem, not started).
3. Select: `outb(CMD+6, 0xE0 | (lba>>24 & 0xF))`; poll BSY&DRQ clear (≤400 ms).
4. `outb(CMD+2, n & 0xFF)`; `outb(CMD+3, lba)`; `outb(CMD+4, lba>>8)`; `outb(CMD+5, lba>>16)`.
5. `outb(CMD+7, 0xC8)` (READ DMA), then `outb(BM+0, 0x09)` (start).
6. Block on irqevent (timeout: read 2 s, write 10 s: FTL erase stalls can be long, flush 30 s).
7. ISR/completion: `bmis = inb(BM+2)`; if bit2 clear → spurious, ignore. `inb(CMD+7)` (acks device IRQ), `outb(BM+0, 0x00)` (stop), `outb(BM+2, 0x06)` (W1C). If BMIS bit1 or status ERR/DF → error path.

### 3.6 Error recovery ladder

1. Retry the command (max 3; log LBA + error reg).
2. Soft reset channel (SRST pulse, wait BSY≤30 s), re-issue SET FEATURES (transfer mode is not guaranteed to survive reset), reprogram BM regs; retry.
3. Drop to polled PIO for this request: READ SECTOR(S) 0x20 / WRITE SECTOR(S) 0x30, **one sector per DRQ block** (multi 0), nIEN=1, `rep insw/outsw` 256 words, status-poll between sectors (~2–4 MB/s, rescue speed).
4. Persistent failure → mark the device degraded read-only; notify the health service; its mounts go read-only.

Timeout hang (BSY stuck): step 2 directly; if reset can't clear BSY in 30 s → device lost (`ssd_absent`), fail all queued bios with `NoDevice`.

### 3.7 Flush semantics on SM223AC

Runtime-probed (research: IDENTIFY details unknown, LOW):
- Word 83 bit12 set → `flush()` issues FLUSH CACHE (0xE7) (never 0xEA, no LBA48), 30 s timeout. An ABRT response is downgraded to no-op (some CF-class firmware lies about support).
- Not set → `flush()` = drain queue (each write already completed only when BSY clears: CF-class controllers ack after data reaches internal buffer/NAND; residual FTL risk is **not eliminable from the host**). We therefore never rely on flush alone for integrity: nothing that matters is written in place (§6, §8).
- Paranoid mount option `wcache=off`: SET FEATURES 0x82 (disable write cache) if word 82 bit5, default off (kills write perf).

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
├── lib/     data that programs read: fonts, driver manifests
├── tmp/     scratch, in RAM with the root, gone at reboot
├── home/    everything the user keeps                  [persistent when installed]
└── media/   removable volumes, one directory each
```

Every name is at most eight characters, because FAT stores short names in eight
and the tree should read the same on the medium as it does at a prompt.

`/bin` holds programs, `/lib` holds what they read. The split is worth having
here for the same reason it is anywhere: `mkimage` can tell what has to be
executable from where it is put, and a program is never confused with its data.

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
| `/sbin` | The privilege split a directory name implies is advisory. Capabilities do it for real, and they do not care where a binary sits. |
| `/root`, `/home/<user>` | One person uses this machine. |
| `/opt`, `/srv`, `/boot` | Nothing to put in them. The boot partition is read by the bootloader and never mounted. |
| `/var` | Its contents on a machine like this are panic records, which belong where their owner can find and send them: `/home`. |

### 9.3 Mounts

| Mount | Source | Policy |
|---|---|---|
| `/` | RAM, from the boot image | read-write, but volatile: gone at reboot |
| `/etc`, `/home` | FAT32 partition of the boot medium, when installed | metadata ≤1 s, data ≤5 s |
| `/media/*` | FAT on any removable volume found | metadata ≤1 s; unmounted on "safe remove" |

Described by `/etc/fstab`, read from the image's copy before anything is
mounted over it, so the file that says what to mount is never the thing waiting
to be mounted.

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
registers, so the driver's `Quirks` struct is populated from IDENTIFY but the
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
  draining the queue (§3.7). The real-hardware IDENTIFY dump is bring-up task 1.
- **FAT is not crash-safe and cannot be made so.** The bound on the damage is
  the write ordering in §6, and the bound is one file: the one being written.
  Anything that must not be lost is written to a new name and renamed over the
  old one.
- ATTO-derived performance figures are MEDIUM confidence; the acceptance
  thresholds in §10 may need one recalibration pass against the real device.
- Open for 01-boot: the final bootinfo layout, and who owns the 440 B MBR code
  (assumed 01-boot, with the installer embedding it).
- Open for kernel-core: the final VFS vtable and vnode locking model.
- Open for usbd: ublk ring depth and slot-size negotiation, mapping UNIT
  ATTENTION to MediaChanged, and who debounces card insertion.
- Open for the GUI: how safe-remove is offered, where a low-memory warning
  appears, and how a volume that was not unmounted cleanly is reported.

## 14. Phasing

**M1 (boot and survive):** `pata_ich6` with PIO and DMA read and write and
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

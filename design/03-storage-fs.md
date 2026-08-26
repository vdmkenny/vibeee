# vibeee 03 — Storage & Filesystems

> **Superseded in part.** The custom `eeefs` design below is **rejected**:
> vibeee uses **FAT32 as its only on-disk filesystem**. See
> [`00-vibeee.md` §7](00-vibeee.md) for the reasoning. The PATA driver, block
> layer, page-cache and FAT sections here still apply; treat everything about
> `eeefs` as a record of an option that was considered and dropped.
>
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
              ├── eeimg   (read-only compressed rootfs, mounted at /)
              ├── eeefs   (log-structured persistent FS, /data)
              ├── fatfs   (FAT16/32 + VFAT LFN, interchange + boot partition)
              ├── cfgfs   (A/B atomic config blobs, /cfg)
              └── ramfs   (/tmp, /dev, /svc — kernel-core owns ramfs; we consume)
```

Design center: one soldered 4 GB PATA SSD (SM223AC: 28-bit LBA, no READ/WRITE MULTIPLE, UDMA/66, ~30 MB/s seq read, ~20 MB/s seq write, **1–3 MB/s small random writes**, unknown power-loss behavior in the FTL), plus removable SD/USB media via usbd. Everything that writes is shaped around two facts: small random writes are ~10× slower than sequential, and the user *will* yank power. Therefore: log-structured /data (all writes sequential), A/B-committed /cfg, read-only /, bounded dirty age everywhere, no swap.

## 2. Hardware facts used (with research confidence)

| Fact | Value | Confidence |
|---|---|---|
| IDE function | 00:1f.2, 8086:2653, subsys 1043:82d8, combined/legacy mode | HIGH |
| SSD channel | secondary: cmd 0x170–0x177, ctl 0x376, IRQ 15, BMDMA 0xFFA8 | HIGH (verbatim dmesg) |
| SATA channel | primary: 0x1F0/0x3F6, BMDMA 0xFFA0, IRQ 14, **no ports wired** | HIGH |
| Device | `SILICONMOTION SM223AC`, ATA-4, 7,815,024 sectors (3.73 GiB), blank firmware string | HIGH |
| LBA | 28-bit only, no LBA48; `multi 0` → no READ/WRITE MULTIPLE | HIGH |
| UDMA | device max UDMA/66; cable-detect bits lie (soldered trace) — force 80-wire assumption, precedent: mainline `ich_laptop[]` quirk {0x2653,0x1043,0x82D8} | HIGH |
| Performance | seq rd ~30–34 MB/s, seq wr ~20–23 MB/s, 4K wr ~2 MB/s, 0.5K wr ~1.3 MB/s, access 0.5 ms | MEDIUM (screenshot-derived) |
| NAND | 4× 8 Gbit SLC large-block (erase block 128–256 KiB class, page 2 KiB) | HIGH chips / LOW block size (inferred) |
| SM223 internals | wear-leveling/SMART/FLUSH support **unknown** | explicitly LOW → probe at runtime |
| SD reader | internal USB MSC 0951:1606 (ENE UB6225) via usbd; boot medium | HIGH |
| MCFG ECAM | 0xE0000000 (config access for 0x40–0x54 timing regs) | HIGH |
| Mini-PCIe "Flash_con" | inserting a card disables onboard SSD — driver must tolerate empty channel | MEDIUM-HIGH |
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

1. PCI: verify VID/DID 8086:2653; set Bus Master + I/O Space in PCICMD; read BAR4, assert it reports 0xFFA0 (else use BAR4 value +8 for secondary — do not hardcode blindly).
2. Presence probe: `outb(CMD+6, 0xA0)`; 400 ns delay (4× altstatus reads); if `inb(CMD+7)` is 0xFF or 0x7F → channel empty → register nothing, mark `ssd_absent` (boot continues from SD; log for the Flash_con case).
3. Soft reset: devctl SRST=1, hold ≥5 µs, clear; poll BSY clear (≤30 s, but bail to `ssd_absent` after 2 s if status stays 0xFF). Check signature (count=1, lba0=1, lba1=0, lba2=0 → PATA).
4. IDENTIFY DEVICE (0xEC): select 0xA0, wait DRDY, issue, poll DRQ, `rep insw` 256 words, nIEN=1 during probe (polled).
   Words consumed: 49 (LBA+DMA caps), 60–61 (LBA28 sector count — expect 7,815,024), 47 (multiple: expect 0 → PIO path is single-sector), 63 (MWDMA), 88 (UDMA supported/active; expect bit 4 = UDMA4), 80/81 (ATA-4), **82 bit5** (write cache supported), **83 bit12** (FLUSH CACHE supported), 83 bit10 (LBA48 — expect 0, and we never use LBA48 regardless), 85 bit5 (write cache enabled). All stored in a `Quirks` struct — this is the test seam (§10).
5. SET FEATURES 0xEF: features=0x03, count=0x44 (UDMA4). On error bit: retry 0x42 (UDMA2) → 0x22 (MWDMA2) → 0x0C (PIO4). Re-read word 88 to confirm selection.
6. Host timing (values verified against ata_piix behavior; devid = 2 = secondary master):
   - `IDETIM_SEC(0x42) = 0xA307` — decode enable(15), ISP=2clk(13:12=10), RCT=3clk(9:8=11), drive0 PPE|IE|TIME (bits 2:0). DTE stays 0 (DMA uses UDMA regs).
   - `SDMA_CNT(0x48) |= 1<<2` — UDMA enable, devid 2.
   - `SDMA_TIM(0x4A)`: field bits 9:8 (4·devid) = CT=2 → with 66 MHz base = UDMA4.
   - `IDE_CONFIG(0x54)`: clear (0x1001<<2), set bit 2 (66 MHz base clock devid 2). Bits 7:4 are the cable-report bits — **ignored** (soldered short trace; they read "40-wire" and are wrong; Linux needed the ich_laptop quirk for exactly this).
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

Per-command limits: **count register is 8-bit: 1–256 sectors (0 == 256) → max 128 KiB/command**; LBA must fit 28 bits (device is 7.8M sectors — always fits).

1. Fill PRD entries from the request's page list; set EOT on last.
2. `outl(BM+4, prd_paddr)`; `outb(BM+2, 0x06)` (clear err+irq); `outb(BM+0, 0x08)` (dir=dev→mem, not started).
3. Select: `outb(CMD+6, 0xE0 | (lba>>24 & 0xF))`; poll BSY&DRQ clear (≤400 ms).
4. `outb(CMD+2, n & 0xFF)`; `outb(CMD+3, lba)`; `outb(CMD+4, lba>>8)`; `outb(CMD+5, lba>>16)`.
5. `outb(CMD+7, 0xC8)` (READ DMA) — then `outb(BM+0, 0x09)` (start).
6. Block on irqevent (timeout: read 2 s, write 10 s — FTL erase stalls can be long, flush 30 s).
7. ISR/completion: `bmis = inb(BM+2)`; if bit2 clear → spurious, ignore. `inb(CMD+7)` (acks device IRQ), `outb(BM+0, 0x00)` (stop), `outb(BM+2, 0x06)` (W1C). If BMIS bit1 or status ERR/DF → error path.

### 3.6 Error recovery ladder

1. Retry the command (max 3; log LBA + error reg).
2. Soft reset channel (SRST pulse, wait BSY≤30 s), re-issue SET FEATURES (transfer mode is not guaranteed to survive reset), reprogram BM regs; retry.
3. Drop to polled PIO for this request: READ SECTOR(S) 0x20 / WRITE SECTOR(S) 0x30, **one sector per DRQ block** (multi 0), nIEN=1, `rep insw/outsw` 256 words, status-poll between sectors (~2–4 MB/s — rescue speed).
4. Persistent failure → mark device degraded read-only; notify /svc/health; EEEFS mounts go RO.

Timeout hang (BSY stuck): step 2 directly; if reset can't clear BSY in 30 s → device lost (`ssd_absent`), fail all queued bios with `NoDevice`.

### 3.7 Flush semantics on SM223AC

Runtime-probed (research: IDENTIFY details unknown, LOW):
- Word 83 bit12 set → `flush()` issues FLUSH CACHE (0xE7) (never 0xEA — no LBA48), 30 s timeout. An ABRT response is downgraded to no-op (some CF-class firmware lies about support).
- Not set → `flush()` = drain queue (each write already completed only when BSY clears — CF-class controllers ack after data reaches internal buffer/NAND; residual FTL risk is **not eliminable from the host**). We therefore never rely on flush alone for integrity — EEEFS/cfgfs are torn-write-safe at 512 B granularity (§6, §8).
- Paranoid mount option `wcache=off`: SET FEATURES 0x82 (disable write cache) if word 82 bit5 — default off (kills write perf).

## 4. Block layer

### 4.1 Queueing: FIFO ("noop"), and why

Flash has no seek arm: request cost is dominated by the SM223 FTL's erase behavior, which the host cannot model. Elevator sorting buys nothing (community consensus on this machine was `elevator=noop`, HIGH), costs RAM and code. What *does* pay: **contiguous merge** (back/front) up to the 128 KiB command cap, because per-command overhead is real at 630 MHz, and **two priority bands**: `fg` (synchronous reads, fsync) ahead of `bg` (writeback, GC). Ordering rule: writes are never reordered relative to other writes within a device (EEEFS commit correctness), and a `flush` bio is a full barrier: all prior writes complete → FLUSH CACHE → then later bios.

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

Recognized types: 0x0B/0x0C/0x06/0x0E/0x04/0x01 (FAT), 0x7F (EEEFS), 0xDA (cfg raw), 0x83 (probe for EEEFS magic, else ignore), 0xEF (BootBooster — never touched).

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

Kernel copies between cache pages and slots (one copy — acceptable: SD path tops out ~20 MB/s; membw budget ~2% during bulk I/O). Events: `sq_doorbell` (kernel→usbd), `cq_doorbell` (usbd→kernel). Timeout 10 s/req → fail bio `Io`. usbd crash or media yank → devmgr restarts usbd → `UBLK_DETACH` semantics: kernel fails outstanding bios `NoDevice`, marks mounts dead (FAT: force-unmount, open files return `EIO`; EEEFS-on-SD: freeze, offer remount+roll-forward on re-attach). Media-change flag from MSC UNIT ATTENTION → `MediaChanged` → unmount + rescan.

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
- Replacement: two-segment CLOCK (probation → protected on second touch) — near-LRU2 at O(1), no per-access list surgery (membw is precious).
- Read-ahead: sequential-run detector, up to 128 KiB (one ATA command), fg reads bypass it.
- DMA goes **directly into cache pages** via PRD (zero-copy on the PATA path).

### 5.2 Dirty policy

- Global dirty cap: 4 MiB (beyond → writer throttles by taking writeback work).
- Age limit: dirty page older than 30 s → writeback (5 s for FAT metadata, §7).
- Note EEEFS dirty data mostly does *not* live here — it lives in the segment buffer (§6.4); the page cache is dirty mainly for FAT and raw-device writes.
- Events forcing global sync: `sync()` syscall, suspend entry (S3 — battery may die while asleep), ACPI battery-critical, EEEFS checkpoint timer, clean shutdown.

### 5.3 No swap — and the OOM policy that replaces it

Swap is rejected: (a) backing store small-random-writes at 1–3 MB/s makes paging catastrophically slow; (b) it burns SLC erase cycles on a soldered, non-replaceable disk; (c) 512 MiB against our ≤48 MiB idle budget leaves ~450 MiB headroom — exhaustion is a misbehaving app, not a working-set problem. ASUS shipped this machine swapless (HIGH).

Instead: **commit accounting + kill policy.**
- Anonymous-memory commit limit = RAM − kernel reserve (8 MiB) − pinned driver DMA. `mmap`/`sbrk` beyond limit fail cleanly (ENOMEM) — no overcommit, so OOM kill is the backstop, not the norm.
- Pressure order: (1) drop clean cache to floor; (2) emit low-mem event on `/svc/memd` (GUI shows warning, apps may trim); (3) OOM kill: badness = anon RSS × class weight; classes from process manifests: `app` (weight 4) > `service` (2) > `gui` (1) > `core` (never). Supervisor is notified and may restart.

## 6. EEEFS — the /data filesystem

### 6.1 Why log-structured (and the honest comparison)

| | FAT32 | ext2-style in-place | **EEEFS (LFS/CoW)** |
|---|---|---|---|
| Write pattern on flash | FAT area = hot spot rewritten on every alloc; small in-place writes | inode/bitmap/dir blocks rewritten in place, small scattered writes | **everything sequential, 256 KiB chunks → device runs at ~20 MB/s, not 1–3** |
| Power-loss | dirent/FAT/data ordering races; classic yank corruption | fsck required; metadata may be inconsistent; journal (ext3) would double small writes | atomic commit units; mount = bounded roll-forward, ≤0.3 s |
| Wear | FAT hot spot punishes the FTL | mild hot spots (bitmaps, inode table) | log rotation spreads writes before the FTL even tries |
| Code cost | ~25 KB (needed anyway for interchange) | ~30 KB + fsck tool | ~40 KB + GC complexity + RAM tables (~0.8 MiB) |
| Risk | none (well-known) | low | **medium: custom format, GC bugs are data-loss bugs** |

Honest call: FAT32-with-write-through would *work* for /data and is our schedule fallback (M1 contingency, §12), and ASUS themselves dodged the problem with a read-only ext2 + overlay. But /data is the one place the OS does sustained small writes (app state, docs, downloads); on this device that's the difference between 2 MB/s + yank roulette and 20 MB/s + atomic commits. EEEFS is recommended; its scope is deliberately small (no journaling *and* no fsck needed — the log is the recovery mechanism).

### 6.2 On-disk layout

All multi-byte fields little-endian. Block = 4 KiB. Segment = 256 KiB (64 blocks) for volumes ≤ 8 GiB, 1 MiB for larger (set at mkfs; multiple of any plausible 128–256 KiB erase block).

```
LBA 0        …reserved (partition-relative block 0 unused; keeps SB off the FAT-boot-sector probe path)
Block 1      Superblock A
Block 2..N   Log area: segment 0 .. segment S-1  (segments are block-aligned runs)
Mid-volume   Superblock B  (block = (S/2)*seg_blocks + 1 — a *different erase block* than SB A)
```

```zig
pub const Superblock = extern struct {           // one 4 KiB block, written as a whole
    magic: u64,                // "EEEFS01\x00"
    uuid: [16]u8,
    generation: u64,           // monotonically increasing checkpoint number
    total_segments: u32, seg_blocks: u32, block_size: u32,
    head_seg: u32, head_blk: u32,   // log head at checkpoint time
    imap_root: BlkAddr, imap_entries: u32,
    sut_root: BlkAddr,         // segment usage table snapshot (in log)
    free_segments: u32, live_blocks: u64,
    root_ino: u32,             // == 1
    clean: u8,                 // 1 = cleanly unmounted (skip roll-forward)
    _pad: [...]u8,
    crc32c: u32,               // over the whole block, field zeroed
};
pub const BlkAddr = u32;       // volume-relative block number; 0 = null. Max vol = 2^32·4KiB = 16 TiB (theoretical)
```

Mount reads both superblocks, picks highest generation with valid CRC. Checkpoint = write SB to the *older* slot (alternating), after flushing the log — the previous checkpoint is never overwritten by its successor.

**Segment structure** — a segment is filled by one or more *commit units*, appended strictly sequentially:

```
[SegHeader | commit unit | commit unit | … | (padding)]
SegHeader (512 B): magic, uuid, seq: u64 (global monotonic segment sequence), crc32c
CommitUnit: [payload blocks…][CommitRec]
CommitRec (512 B): magic, seq: u64, n_blocks: u16, table[ up to 120 ]{ BlkDesc }, crc32c(payloads+rec)
BlkDesc: { kind: u8 (data|inode|imap|dir=data|sut), ino: u32, file_blk: u32 }
```

Torn-write safety: a commit unit is valid only if its CommitRec CRC (covering all payload blocks) checks out — a half-written unit is invisible. 512 B records mean even single-sector torn writes can't fake validity.

**Inode** (one per 4 KiB block slot; 4 inodes/block packed):

```zig
pub const Inode = extern struct {   // 1 KiB
    ino: u32, mode: u16, nlink: u16,
    uid: u16, gid: u16, _r: u32,
    size: u64, mtime_us: u64, ctime_us: u64,
    extents: [24]Extent,            // direct extents
    indirect: BlkAddr,              // block of 512 Extents (files > ~? fragmented)
    crc32c: u32,
};
pub const Extent = extern struct { file_blk: u32, disk_blk: BlkAddr, len: u32 };
```

Max file: 24 + 512 extents; worst-case fully-fragmented = 536 × 4 KiB ≈ 2 MiB, typical (log locality keeps extents long) multi-GiB. Honest limit: files that are both huge *and* pathologically fragmented hit the extent cap → we return `EFBIG`; acceptable for this system (double-indirect deferred to M3 if ever needed).

**Imap**: array of `BlkAddr` (inode number → block holding its latest inode), stored as log blocks of 1024 entries; imap root = radix-1 index block (1024 pointers → 1M inodes theoretical). Default mkfs cap: 16 K inodes (RAM: flat 64 KiB in-core copy). **SUT**: per-segment `{live_blocks: u16, flags: u16}`; snapshot written to log at checkpoint; in-core authoritative.

**Directories** = regular files containing ext2-style records `{ino u32, rec_len u16, name_len u8, dtype u8, name…}`, linear scan. Honest scalability: fine ≤ ~1 000 entries (one 4 KiB block holds ~100 entries; 1 000-entry lookup ≈ 10 block reads, cached ≈ µs); design cap 65 535 entries/dir. No hashing — small system, keep the code small.

### 6.3 Limits

Volume: min 64 MiB (≥ 16 segments free after metadata), max supported 128 GiB (1 MiB segments → 128 K SUT entries = 512 KiB RAM), recommended ≤ 32 GiB. Serves the ~3.7 GiB internal /data and any SD card. Names: 255 bytes, UTF-8, case-sensitive. Hard links: yes (nlink u16). Symlinks: target in inode data. No sparse-file hole tricks beyond extent gaps (reads of gaps return zeros).

### 6.4 Write path & RAM sizing

All writes funnel into the **segment buffer**: 2 × 256 KiB (double buffered; on 1 MiB-segment volumes still 256 KiB units — a segment may contain multiple buffer flushes). Steady state RAM: 512 KiB buffers + 64 KiB imap + ≤512 KiB SUT + ~128 KiB open-inode/dirty-tracking ≈ **≤1.2 MiB**.

Flow: write() → copy into segment buffer (allocating new disk blocks at log head; old blocks' SUT live-count decremented) → buffer full **or** 30 s age **or** fsync → seal commit unit (CRC) → bio chain (≤128 KiB writes, `bg` prio; `fg` for fsync) → on completion, in-core imap/SUT updated. Checkpoint (SB write + imap/SUT snapshot) every 64 committed segments or 30 s of metadata dirt or unmount. FLUSH CACHE before each SB write (if supported).

**fsync(fd)**: seal current commit unit (even partial — padding only to 512 B record boundary, not to segment end), write, flush barrier, return. Cost: ≤256 KiB write ≈ 13 ms + flush. fsync of an untouched file = no-op. `rename()` is a single commit unit (new dir blocks + inodes) → **atomic on power loss** — this is the documented app-visible contract: "write tmp, fsync, rename" is fully safe.

### 6.5 GC / space reclaim

Trigger: free segments < 12% (or explicit `fstrim`-like ioctl). Cleaner (kernel writeback thread, `bg` prio, yields to fg I/O): pick victim = min(live_blocks) segment (greedy; cost-benefit aging deferred — churn on /data is low: docs/config/app-state, browser cache lives in /tmp); read its live blocks (identified via CommitRec tables + imap/inode cross-check), rewrite them at log head as a normal commit unit (kind=data moves carry {ino,file_blk} so recovery is uniform), mark segment free. Write amplification bound: with 12% reserve and low churn, expected WA < 1.5. Worst case (volume 95% full, hot rewrites): WA ~3 — document "keep /data below 90%" and have `df` warn.

### 6.6 Mount-time recovery (roll-forward)

1. Read SB A/B → newest valid. If `clean==1` → done (mount ≈ 3 block reads + imap/SUT load ≈ 50 ms).
2. Else: load imap/SUT snapshot from checkpoint; scan segments from `head_seg` following ascending `seq` in SegHeaders; within each, walk commit units until first invalid CRC; apply BlkDescs (imap updates, SUT deltas). Stop at seq break or clean segment.
3. Bounded: ≤64 segments (checkpoint cadence) × 256 KiB = 16 MiB read ≈ 0.6 s worst case; typical < 150 ms. Then write a fresh checkpoint.
4. Nothing is ever "repaired" — invalid tails are simply ignored; ≤30 s of un-fsynced data is lost, consistency is never lost. No fsck tool exists or is needed; a read-only `eeefsck -n` verifier ships for development.

### 6.7 Wear reasoning

The FTL sees: long sequential 256 KiB-aligned writes marching circularly through LBA space, plus two SB blocks rewritten every ≤30 s of *activity* (idle = zero writes; checkpoint timer is dirty-gated). SB wear: worst case ~2 880 writes/day-of-constant-activity to 2 LBAs — the SM223's FTL remaps physical pages under any LBA (CF-class controllers do at least dynamic wear-leveling), and SLC endurance is ~100 K cycles; margin is >30× even assuming a pathological FTL. The log itself is the best-case input for any FTL.

### 6.8 Public API (Zig)

```zig
pub const eeefs = struct {
    pub fn probe(dev: DevHandle) bool;                       // magic + SB CRC
    pub fn mount(dev: DevHandle, opts: MountOpts) Error!*Fs; // opts: rdonly, wcache_off
    pub fn unmount(fs: *Fs) Error!void;                      // sync + clean checkpoint
    pub fn mkfs(dev: *BlockDev, p: MkfsParams) Error!void;   // p: seg_size, max_inodes, uuid, label
    pub fn statfs(fs: *Fs) StatFs;                           // incl. free_segments, wa_estimate
    // vnode ops table handed to VFS: lookup, create, unlink, rename, read, write,
    // truncate, fsync, readdir, symlink, link, getattr/setattr — signatures follow
    // kernel-core's VFS vtable (consumed contract, §11).
};
```

Core is **pure Zig, no kernel imports** — BlockDev vtable + allocator injected. Same source compiles into the kernel, into host-side tools (mkfs/fsck/fuzzer), and into the installer.

## 7. FAT16/32 driver (interchange + boot partition)

- Read/write; FAT12 read-only (tiny media edge case). VFAT LFN: read + generate (UCS-2 names ≤255, sequenced 13-char entries, 8.3 alias with `~n` + checksum). Mount by BPB probe (works for superfloppy SD).
- Cluster allocator: next-free rotor (mild wear spreading, good contiguity); FSInfo free-count treated as advisory, recomputed lazily in background, corrected on unmount.
- **Yank mitigation — ordered metadata writes.** Per file operation the block-layer ordering guarantee (§4.1) is used to sequence: (1) data clusters; (2) FAT chain for those clusters (FAT copy 1 then copy 2); (3) directory entry (size/first-cluster/LFN) last. A yank can leak clusters (lost chains — harmless, reclaimed by any chkdsk) but cannot produce a dirent pointing at an unwritten chain, and cannot cross-link (allocation rotor + FAT-before-dirent).
- Dirty flag: set FAT[1] "clean shutdown" bit clear on first write, restore on unmount/sync-idle. On mounting a dirty volume: log warning, expose `dirty` in statfs (GUI shows "check this card on a PC" hint); no online fsck (out of scope, honest).
- Metadata writeback age 5 s (data 30 s); removable media default `sync_meta` mount profile: FAT+dirent flushed at ≤1 s. "Safe remove" in GUI → `sync_dev` + unmount.
- Boot partition: FAT16, 32 MiB — chosen because AMI EZ-Flash reads FAT16 USB media (BIOS-recovery friendliness) and 01-boot's INT 13h loader can navigate FAT16 trivially. If 01-boot prefers raw-sector kernel loading, driver is unaffected.
- Limits honored: no >4 GiB files (EFBIG), 2 TiB volume cap, no exFAT (licensing/scope — document; SDXC cards arrive exFAT-formatted → user reformats FAT32 in our GUI).

## 8. cfgfs — /cfg atomic config store

Backing: 4 MiB raw partition (type 0xDA), two 2 MiB slots (different erase-block neighborhoods).

```
Slot: [SlotHdr 512 B | payload ≤ 2 MiB−512 B]
SlotHdr: magic, generation: u64, payload_len: u32, payload_crc32c: u32, hdr_crc32c: u32
Payload: flat serialized tree: [n_entries][{path_len u16, path…, val_len u32, val…}…]  (≤256 KiB budget)
```

Mount: read both headers, pick highest valid generation (payload CRC must also verify — else fall back to other slot), load whole payload to RAM. All reads/writes hit RAM. Commit (explicit `commit()` syscall on the mount, or 5 s debounce after last write, and always on sync/suspend/shutdown): serialize → write *inactive* slot payload → flush → write its 512 B header (single sector = atomic on any sane device) → flush → flip in-core active. A yank at any point leaves the previous generation intact. Presented via VFS as a normal small directory tree (files = values) so tools just use open/read/write.

## 9. Rootfs: `eeimg` read-only image + mount layout + shutdown story

### 9.1 Format decision: compressed block FS, not tree-unpack

Idle budget is 48 MiB *including* RAM-rootfs. Unpacking a 24 MiB tree into ramfs permanently spends 24 MiB + ramfs metadata. Keeping the compressed image (~10–12 MiB at LZ4, ~8–9 at zstd) resident and decompressing on demand costs the image + a reclaimable decompressed-page cache. At 630 MHz, LZ4 decompress runs ≥150 MB/s (a 32 KiB block < 0.25 ms) — on-demand is imperceptible and cold-boot doesn't pay a full-image decompress either. **Recommendation: eeimg compressed-block format; codec = whatever 01-boot picks for the kernel (requirement we impose: ≥100 MB/s decompress at 630 MHz — LZ4 recommended; zstd acceptable if 01-boot needs the ratio for the 48 MiB SD budget, at ~2–3× the CPU).** No XIP in the mapping sense — pages decompress into the ordinary page cache and are evicted/re-decompressed freely, which *is* the RAM win.

Layout (single codec id in SB; all offsets image-relative):

```
[SB 4 KiB: magic "EEIMG01", codec_id, block_size=32 KiB, n_inodes, inode_tab_off,
 dir_tab_off, frag_tab_off, blocklist_off, data_off, image_crc32c]
[inode table]  uncompressed; {mode u16, uid/gid u16, size u32, mtime u32,
               blocklist_idx u32, frag: {frag_blk u32, frag_off u32} }  — 24 B/inode
[dir table]    uncompressed dirent runs (same record format as EEEFS dirs)
[block lists]  u32 offsets of each file's compressed blocks (delta from data_off)
[fragment blocks] files < 8 KiB tail-packed into shared 32 KiB compressed fragments
[data blocks]  each: {u32 clen | compressed 32 KiB block}
```

Small-file packing matters: a rootfs is mostly small files; fragments keep waste near zero. Image built by host-side `mkeeimg` (same Zig code compiled for host).

### 9.2 Handover from 01-boot

Bootloader loads kernel + image into RAM, passes `bootinfo { rootfs_paddr, rootfs_len, rootfs_crc32c }`. Kernel: reserves those frames from the allocator, maps them (WB cacheable), verifies SB magic + (lazily, background) whole-image CRC, mounts as `/`. Zero copies. The image pages are the only permanently pinned storage RAM besides driver state.

### 9.3 Mount table & flush discipline

| Mount | FS | Source | Policy |
|---|---|---|---|
| `/` | eeimg | RAM image | RO, immutable |
| `/tmp`, `/dev`, `/svc` | ramfs (kernel-core's) | RAM | volatile by definition; browser cache/logs live here |
| `/data` | eeefs | SSD p3 (or SD p2 when SD-booted) | writeback ≤30 s, checkpoint ≤30 s; mounted async during GUI start (apps block on `/svc/vfs.data` readiness) |
| `/cfg` | cfgfs | SSD p2 | RAM-backed, A/B commit ≤5 s debounce |
| removable | fatfs (or eeefs) | ublk | metadata ≤1 s, data ≤30 s |

Global events: `sync()` = all mounts flush + barriers. Suspend (S3), battery-critical, shutdown → forced global sync (and cfgfs commit). Battery-critical additionally drops all writeback ages to 5 s. Clean shutdown: kill apps → sync → unmount /data (clean checkpoint, `clean=1`) → cfgfs commit → EC poweroff.

**Unclean shutdown, end to end**: `/` immune (RO RAM) → `/cfg` previous generation survives (≤5 s of config lost) → `/data` roll-forward (≤30 s of un-fsynced data lost, never inconsistent; fsync'd data never lost up to the device's own FTL honesty) → FAT media: possible lost clusters only, dirent/chain ordering prevents dangling metadata → next boot is normal speed (+≤0.6 s roll-forward worst case).

## 10. Bring-up & test plan

**Host-side (no hardware, continuous):** eeefs/fatfs/eeimg/cfgfs cores are pure Zig over the BlockDev vtable → compiled to host tools + test harness. Key harness: *power-cut fuzzer* — file-backed BlockDev that records every write, replays a random prefix (with 512 B torn tails and reordering **within** the rules §4.1 allows), then mounts and checks invariants (mountable, fsync'd data present, tree consistent). Run continuously in CI; this is where LFS bugs die. Also: `eeefsck -n` verifier, mkfs/mount round-trips, FAT images cross-checked against Linux mount + `fsck.vfat` and a real camera.

**QEMU (i440FX `-machine pc`, disk as `-device ide-hd,bus=ide.1,unit=0`):** PIIX3-IDE is register-compatible for the command block + BMDMA hot path (IRQ15/0x170 path exercised for real). Differences to seam around: QEMU's device advertises LBA48 + multiple and ignores ICH timing regs → the driver's `Quirks` struct is populated from IDENTIFY but the SM223 profile can be **forced** (`quirk_override=sm223`: 28-bit, multi 0, probe-flush) so the exact production code paths run under QEMU; timing-reg writes are write-and-forget (verified only on real HW). ublk path: QEMU `usb-storage` device under EHCI exercises usbd+ublk end-to-end. eeimg/boot handover fully testable in QEMU.

**Real hardware ladder:** (1) polled PIO IDENTIFY, dump words 47/49/60/61/80/82/83/85/88 to screen — *closes the LOW-confidence flush/wcache unknowns; do this first and record it*; (2) PIO read MBR; (3) DMA reads + PM-timer throughput check (expect ~30 MB/s seq, confirming UDMA4; ~25 → fell back to UDMA2); (4) DMA writes on a scratch partition + ATTO-style block-size sweep to validate the 1–3 MB/s small-write premise and tune segment size; (5) power-yank torture: scripted write load, pull power ×100, verify /data + /cfg recovery each boot; (6) Flash_con absence path if a mini-PCIe card is available.

**Perf acceptance:** /data seq write ≥15 MB/s sustained; 4 KiB-file create+fsync ≤25 ms; /data mount ≤0.7 s worst case; boot contribution ≤1.0 s total (eeimg mount ~0 + async /data).

## 11. Budgets

**Kernel ELF share (~120 KB of 1.5 MB):** pata 6 + block/partition 10 + cache 10 + eeefs 40 + fatfs 25 + eeimg 8 + cfgfs 4 + ublk bridge 6 + glue 10 (KB, ReleaseSmall estimates).
**Rootfs share:** mkfs.eeefs + eeefsck + mkfs.fat + installer ≈ 150 KB.
**Idle RAM share (of 48 MiB):** compressed rootfs image ~12 MiB (pinned) + eeefs steady state ≤1.2 MiB + cfgfs payload ≤0.3 MiB + FAT/driver state ~0.2 MiB + dirty/pinned cache ≤2 MiB ≈ **15.7 MiB pinned**; clean cache above that is reclaimable and uncounted.
**SD image (48 MiB):** no additional share beyond rootfs contents above.

## 12. Install-to-SSD flow (design)

Installer app (runs from SD-booted system, guided in GUI):
1. Preflight: confirm SSD present (`ssd_absent`?), show model/size, require typed confirmation; refuse if /data-on-SSD is mounted.
2. Partition (writes MBR, 1 MiB-aligned starts, synthesized CHS 255H/63S for old-BIOS INT 13h sanity):
   p1 `0x0E` FAT16 boot 32 MiB (LBA 2048), **active**; p2 `0xDA` cfg 4 MiB; p3 `0x7F` EEEFS to end−8 MiB; p4 `0xEF` 8 MiB empty (optional, checkbox: lets AMI BootBooster cache POST — several seconds off boot; BIOS owns its contents).
3. `mkfs.fat16` p1; copy bootloader stages + kernel + eeimg rootfs image from the running SD; install 01-boot's MBR boot code (440 B, preserving the partition table + disk signature).
4. Init p2: write both cfg slots (gen 0/1) with current /cfg contents. `mkfs.eeefs` p3 (256 KiB segments); optional: copy current /data.
5. Verify: FLUSH CACHE; read back and CRC-compare MBR, boot files, cfg headers, EEEFS SBs. Only then declare success.
6. Reboot without SD; BIOS boots internal SSD (same INT 13h path, drive 0x80).
Failure at any step before MBR write is a no-op; MBR is written *last-but-verified-first* into a staging sector then LBA 0, so a mid-install yank leaves either old or new table, not garbage.

## 13. Risks & open questions

- **SM223 FTL power-loss behavior unknown (LOW).** EEEFS tolerates torn 512 B writes, but an FTL that corrupts *unrelated* LBAs on yank defeats any FS. Mitigations: SB pair far apart, /cfg A/B on a separate partition, yank-torture testing (§10). Residual risk documented, not solved.
- **FLUSH CACHE support unknown** → runtime probe + drain fallback (§3.7). Real-HW IDENTIFY dump is bring-up task #1.
- **Erase-block size inferred** (128–256 KiB). Segment 256 KiB covers the plausible range; the block-size sweep (§10) validates; worst case we double segment size at mkfs — format field already exists.
- **GC correctness** is the highest-severity software risk (data loss). Contained by: pure-core design, power-cut fuzzer in CI, GC lands in M2 behind a "no-GC until 88% full" gate.
- ATTO-derived perf numbers are MEDIUM — acceptance thresholds may need one recalibration pass.
- Open for 01-boot: codec choice (we impose ≥100 MB/s decompress; LZ4 preferred); bootinfo struct final layout; FAT16-vs-raw boot partition (we support both, recommend FAT16); who owns the 440 B MBR code (assumed 01-boot, installer embeds it).
- Open for kernel-core: final VFS vtable + vnode locking model; ramfs ownership (assumed kernel-core); irqevent semantics for in-kernel drivers (we assume direct IRQ registration, not the userspace irq_attach path).
- Open for usbd: ublk ring depth/slot-size negotiation; UNIT ATTENTION → MediaChanged mapping; who debounces SD-card insertion.
- Open for GUI: safe-remove UX; low-mem warning surface; "dirty FAT" hint surface.

## 14. Phasing

**M1 (boot & survive):** pata_ich6 (PIO + DMA read/write, no recovery ladder beyond reset-retry), block core + MBR, page cache (fixed 16 MiB cap, simple CLOCK), eeimg mount (this is the boot-critical path), fatfs read-only, cfgfs full (small + needed for settings), **/data = FAT32 write-through contingency** if EEEFS slips; host-side mkeeimg. QEMU-green + first real-HW IDENTIFY/throughput numbers.
**M2 (real /data):** EEEFS complete minus GC (gated), fsync/rename contracts, roll-forward, power-cut fuzzer in CI, fatfs write + LFN + ordered metadata, ublk bridge + removable media lifecycle, adaptive cache + OOM policy, installer.
**M3 (polish/hardening):** EEEFS GC + fstrim ioctl, eeefsck -n, FAT superfloppy/extended-partition edge cases, wcache=off paranoid mode, perf acceptance sweep, yank-torture ×100 sign-off, BootBooster partition option.

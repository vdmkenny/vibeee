# vibeee Boot Path & SD Image Layout (design/01-boot.md)

> **Status: partially implemented.**
>
> Built and working ([`boot/stage1.asm`](../boot/stage1.asm), [`boot/stage2.asm`](../boot/stage2.asm),
> [`tools/mkimage.zig`](../tools/mkimage.zig)): MBR stage1 loading stage2 over INT 13h EDD;
> stage2 doing A20, E820 capture, RSDP scan, kernel load to 1 MiB through unreal mode, and
> protected-mode handoff via the `BootInfo` struct; a dd-able partitioned image.
>
> Designed but not built: FAT16 boot partition, zstd rootfs container, A/B copies with the
> boot journal and 3-strike fallback, the boot menu, and the recovery TUI. The kernel is
> currently loaded as a flat binary from a fixed LBA run instead.
>
> Where this document and [`00-vibeee.md`](00-vibeee.md) disagree, the master design wins.

Subsystem: boot (stage1 MBR, stage2 loader, boot protocol, SD/SSD image layout, install, recovery, build integration).

## 1. Overview

Two-stage legacy-BIOS boot. Stage1 (≤440 B NASM, lives in the MBR) uses INT 13h EDD to load stage2 from a fixed LBA run in the MBR gap. Stage2 (NASM real-mode core + Zig 32-bit code running in protected mode with real-mode trampolines for BIOS services) enables A20, captures E820 and the RSDP, mounts a read-only FAT16 boot partition, loads the kernel ELF and the zstd-compressed rootfs blob into extended memory in 32 KB bounce-buffer chunks, optionally shows a boot menu (hold SPACE), and enters the kernel in flat 32-bit protected mode with a versioned `BootInfo` handoff struct. The kernel decompresses the rootfs itself.

The system runs from RAM after handoff (boot-to-RAM per locked architecture); the SD card is not touched again until usbd remounts it. The identical loader installs to the internal PATA SSD (BIOS drive abstraction makes stage1/stage2 drive-agnostic; only the image layout tool differs). An A/B file fallback plus a boot-journal sector gives automatic recovery from bad updates; a held key gives manual recovery.

Boot-time budget share: ≤ 4.0 s from stage1 entry to kernel entry (the other ~4 s of the 8 s budget is BIOS POST + kernel/GUI init, out of scope here).

## 2. Hardware facts used (confidence per research reports)

- Legacy AMI BIOS only, no UEFI/GPT; MBR + INT 13h boot [HIGH, core-platform §5].
- USB-HDD boot from the internal ENE UB6225 SD reader (USB MSC 0951:1606 on EHCI) is supported and routine; syslinux/GRUB-style MBR boots work → INT 13h EDD present [MEDIUM-HIGH; EDD *version* not verbatim-confirmed, treat as risk R1].
- Internal SSD: PATA secondary master, `SILICONMOTION SM223AC`, 7,815,024 × 512 B sectors, 28-bit LBA, entire disk < 2^28 sectors, so BIOS EDD covers it fully [HIGH]. Small random writes 1–3 MB/s → keep boot-path writes to one 512 B journal sector [MEDIUM].
- E820 map verbatim (usable 0–0x9FC00, 0x100000–top; ACPI data/NVS near top) [HIGH]; with stock 512 MB, usable top ≈ 0x1F78_0000 (~503 MB, inferred layout) [MEDIUM].
- RSDP observed at 0xFBE60, sig `ACPIAM` [HIGH], we still scan EBDA + 0xE0000–0xFFFFF per spec.
- VBE mode table has NO 800×480 (only 640×480 VESA modes); text mode `VGA+ 80x25` works at POST via panel fitter [HIGH] → boot stays in text mode; kernel does native GMA900 modeset.
- No serial port [HIGH] → all diagnostics on the VGA text screen + a persisted journal sector.
- Xandros/BIOS "Boot Booster" uses an MBR partition of type 0xEF on the SSD; BIOS writes POST cache into it [HIGH] → tolerate, never use (see §8).
- CPU 630 MHz Dothan, SSE2, ~1 GB/s theoretical memory bandwidth [HIGH] → informs compression choice (§6).
- i8042 keyboard live in real mode via INT 16h (EC KB3310 provides KBC function) [HIGH].
- BIOS "OS Installation: [Start/Finished]" advanced option can affect USB device handling during boot [MEDIUM], bring-up note §11.

## 3. Architecture

```
BIOS POST → INT 19h → MBR sector @0x7C00 (stage1, DL=boot drive)
  stage1: EDD check → load stage2 (fixed LBA run) @0x10000 → far jump
    stage2 (rm16 stub): A20, E820, RSDP, GDT, PE=1 → Zig main (pm32)
      Zig: parse MBR → mount FAT16 P1 → read BOOT.CFG
           [SPACE held? → menu: normal/verbose/recovery/backup]
           load KERNEL.ELF → phys 0x100000.. (PT_LOAD, CRC32)
           load ROOTFS.ZST → phys 0x1000000 (CRC32)
           write boot journal (attempt++)
           build BootInfo @0x6000 → mask PICs → jmp kernel entry
kernel: consumes BootInfo, decompresses rootfs → ramfs, later acks journal
```

Stage2 execution model: enter protected mode once, early; all logic is 32-bit Zig (`ReleaseSmall`, `i386-freestanding`); every BIOS service (INT 13h/15h/16h/10h) goes through a NASM PM→RM→PM trampoline. No unreal-mode tricks in the main path (unreal mode is only a fallback idea if trampoline latency ever matters, it does not: one round trip costs ~µs, and we do ~400 of them per boot).

### Memory map during stage2 (all linear/physical)

| Range | Use |
|---|---|
| 0x0000_0500–0x0000_0FFF | scratch (A20 wrap test uses 0x500/0x100500) |
| 0x0000_1000–0x0000_5FFF | stage2 stack (RM and PM share; SS:SP=0:0x5FF0 in RM) |
| 0x0000_6000–0x0000_6FFF | `BootInfo` (handoff, ≤4 KB incl. VBE copy) |
| 0x0000_7000–0x0000_8FFF | stage2 text log ring (8 KB, handed to kernel) |
| 0x0000_7C00–0x0000_7DFF | stage1 (dead after jump; overlap w/ log is fine, log starts after jump) |
| 0x0001_0000–0x0004_FFFF | stage2 code+data+bss (cap 256 KB) |
| 0x0005_0000–0x0005_FFFF | FAT + cluster-run scratch (64 KB) |
| 0x0006_0000–0x0006_7FFF | INT 13h bounce buffer (32 KB, segment 0x6000) |
| 0x0009_F000 | initial kernel ESP (below EBDA @0x9FC00) |
| 0x0010_0000–0x002F_FFFF | kernel PT_LOAD segments (ELF ≤1.5 MB + bss headroom) |
| 0x0100_0000–… | ROOTFS.ZST blob (≤16 MB; top checked against E820) |

Log ring note: stage2 mirrors every screen line into the ring; kernel copies it into its dmesg at boot so early failures are inspectable later (no serial).

## 4. Stage1 (MBR, NASM, ≤440 bytes)

Responsibilities: nothing but "get stage2 into RAM and jump", defensively.

Sequence (register-level):
1. `cli; xor ax,ax; mov ds,ax; mov es,ax; mov ss,ax; mov sp,0x7C00; sti; cld`. Save `DL` (BIOS boot drive) to a fixed slot in the relocated stage1. Relocate self 0x7C00→0x0600 (`rep movsw`, 256 words) and far-jump into the copy, frees 0x7C00 for scratch and is VBR-chainload-safe by convention.
2. EDD presence: `mov ah,0x41; mov bx,0x55AA; int 0x13` → require CF=0, BX=0xAA55, CX bit0 (DAP). Failure → error `E1` (this BIOS is known to support EDD; no CHS fallback is carried: 440 B is better spent on retries, and EDD absence means an unsupported machine).
3. Read stage2 header sector: DAP `{size=0x10, cnt=1, dst=0x0000:0x7C00, lba=STAGE2_LBA_A}` (=1), `ah=0x42; int 0x13`. On CF or bad magic: retry once; then same for backup run `STAGE2_LBA_B` (=1024); then, as a DL quirk fallback, retry the whole sequence once with `DL=0x80` (some BIOSes mis-pass DL for USB-HDD; observed rarely on AMI, cheap insurance). All failed → `E2`.
4. Header (sector 0 of stage2 image): `{magic "EOS2", u16 sectors, u16 flags, u32 crc32_body, u32 entry_off}`. Loop-load `sectors` (≤511) in ≤64-sector DAP calls to 0x1000:0000 upward (INT 13h forbids crossing a 64 KB segment boundary in one transfer on some BIOSes → we advance the DAP *segment* by 0x800 per 64-sector chunk, offset always 0).
5. Jump `0x1000:entry_off` with `DL`=saved drive, `SI`=LBA base actually used (A or B), so stage2 knows which copy it is and where the journal lives relative to it.

Errors print a two-char code (`E1` no-EDD, `E2` load fail) via INT 10h teletype and `hlt`-loop. Stage1 performs no partition-table parsing and no CHS math: EDD is pure LBA, which sidesteps the USB-HDD geometry-translation swamp entirely. The partition table in the same sector is data for stage2/kernel, not for stage1.

CHS fields in the partition table are still filled (255 heads/63 sectors mapping, capped at 1023 cylinders) because AMI BIOSes are known to sanity-check the table when deciding USB-HDD vs USB-FDD emulation; a "sane-looking" table with one active (0x80) partition keeps the BIOS in HDD emulation. Bytes 0x1B8–0x1BB carry a random NT disk signature written at image build; 0x1FE=0x55AA.

## 5. Stage2

### 5.1 Real-mode stub (NASM, runs first)
1. Verify it's fully loaded (CRC32 of body vs header; on mismatch and if running from copy A, reload from copy B via same INT 13h path; from B → fatal `E3`).
2. A20: INT 15h AX=0x2401; verify by wrap test (write 0x55AA@0x500, read 0x100500 with FS segment 0xFFFF trick); fallback KBC (0x64←0xD1, 0x60←0xDF with IBF waits); fallback fast-A20 port 0x92 (read, `or al,2; and al,0xFE`, write). All verified by wrap test; fail → `E4`.
3. E820: loop `EAX=0xE820, EDX='SMAP', ECX=24, ES:DI→BootInfo.e820[i]` until EBX=0/CF; store count (cap 32). If E820 unsupported (won't happen per research), synthesize 2 entries from INT 15h AX=0xE801.
4. VBE capture (diagnostic only): INT 10h AX=0x4F00 with "VBE2" tag into a 512 B slot in BootInfo; set `vbe_present`. Screen stays in text mode 3 (re-set via INT 10h AX=0x0003 to normalize).
5. RSDP scan: EBDA base = `word[0x40E] << 4`, scan first 1 KB, then 0xE0000–0xFFFFF, 16 B steps, sig `"RSD PTR "` + checksum. Store phys (expect 0xFBE60).
6. Load GDT (null, 0x08 code32 flat, 0x10 data32 flat, 0x18 code16, 0x20 data16), `lidt` a zero-limit IDT, set CR0.PE, far jump to Zig entry. Interrupts stay off in PM; trampoline restores the real IVT (`lidt [ivt_0_3ff]`) + `sti` whenever back in RM so BIOS USB/keyboard servicing keeps working.

### 5.2 PM↔RM trampoline (the one hot primitive)
```
pm_to_rm: cli; jmp 0x18:pm16 → load 16-bit data segs → clear CR0.PE
          → jmp 0:rm → SS:SP=0:0x5FF0 → lidt ivt → sti
rm_to_pm: cli → lgdt → set PE → jmp 0x08:pm32 → reload segs, ESP
```
Zig-visible API: `bios_int(int_no: u8, regs: *RmRegs) void` where `RmRegs = extern struct { eax, ebx, ecx, edx, esi, edi, es, ds, eflags: u32 }`. All INT 13h data lands in the bounce buffer (segment 0x6000); Zig memcpys to the ≥1 MB destination while already in PM (no unreal mode needed).

### 5.3 Zig main logic
- Parse the MBR (re-read LBA 0 via `diskRead`) → find P1: first partition entry with type 0x0E (FAT16 LBA), boot flag preferred but not required. Record partition index + start LBA + disk signature.
- FAT16 read-only driver (~300 lines): BPB parse, root-dir 8.3 lookup, FAT chain walk with **contiguous-run coalescing** (mtools/mkfs write files contiguously; a 9 MB rootfs then costs ~290 64-sector reads with zero seek-chatter).
- `BOOT.CFG` (root dir, ≤2 KB, `key=value` lines): `kernel=`, `rootfs=`, `cmdline=`, `kernel_bak=`, `rootfs_bak=`, `menu_timeout=0`, plus per-entry `crc32.kernel=`/`crc32.rootfs=` written by the image builder (defense against FAT-level corruption; the files also carry internal CRCs, both are checked).
- Menu: poll INT 16h AH=0x01 for ~300 ms at entry; SPACE (or `r`) held → menu on VGA text: `1 Normal  2 Verbose  3 Recovery  4 Backup slot`. Verbose appends `verbose=1`, recovery appends `recovery=1` (init in rootfs runs the recovery TUI, §9), backup selects `*_bak` files. No key → boot default instantly (`menu_timeout=0`).
- Kernel load: open kernel file, read ELF32 header + phdrs, for each PT_LOAD copy filesz bytes to `p_paddr` (chunked through bounce buffer), zero to `p_memsz`. Require `p_paddr ∈ [0x100000, 0x400000)`, 4 KB aligned. Entry = `e_entry` translated via phdrs to physical. CRC32 checked over the file image while streaming.
- Rootfs load: stream file to 0x0100_0000, CRC32 of the compressed container checked against both BOOT.CFG and the container header (§6). Verify blob end < min(top-of-usable-E820, kernel-reserved regions).
- On any load/CRC failure of primary files → automatic retry with `*_bak`; both bad → error screen `E5` + journal write + halt (screen shows which file/CRC failed).
- Boot journal (LBA 2040, one 512 B sector, written via EDD AH=0x43 write): `{magic "EEBJ", u32 seq, u8 state(1=attempting), u8 slot, u8 attempts, u8 last_err, u32 crc32}`. Stage2: if `state==attempting && attempts>=3` → force backup slot this boot and show a warning banner. Then `attempts++`, write. Kernel acks (state=0) once core services are up, via its own disk path (PATA if booted from SSD; via usbd when booted from SD, the ack is best-effort and only gates the *auto*-fallback heuristic).
- Handoff: fill BootInfo, `out 0x21,0xFF; out 0xA1,0xFF` (mask PICs), `cli`, jump.

Public Zig signatures (stage2-internal, but stable for testing):
```zig
pub const DiskError = error{ Bios, Bounds, BadMagic, BadCrc };
pub fn diskRead(drive: u8, lba: u64, sectors: u16, dst_phys: u32) DiskError!void;
pub fn diskWrite(drive: u8, lba: u64, src_phys: u32, sectors: u16) DiskError!void; // journal only
pub const Fat16 = struct {
    pub fn mount(drive: u8, part_lba: u32) DiskError!Fat16;
    pub fn open(self: *Fat16, name83: []const u8) DiskError!File; // "KERNEL  ELF"
    pub const File = struct { size: u32,
        pub fn readStream(f: *File, sink: *Sink) DiskError!void }; // sink gets 32K chunks + running CRC
};
pub fn loadElf32(f: *Fat16.File) DiskError!struct { entry_phys: u32, lo: u32, hi: u32 };
pub fn bios_int(int_no: u8, regs: *RmRegs) void; // NASM
```

## 6. Compression decision: zstd for rootfs, uncompressed kernel

The dominant cost is **bytes read through the BIOS→EHCI→SD path**, whose throughput is unmeasured (estimate 2–8 MB/s; measure in M1, risk R2). At 630 MHz Dothan:

| Codec | est. ratio on 24 MB rootfs | bytes read | decode speed est. @630 MHz | decode time | decoder cost |
|---|---|---|---|---|---|
| LZ4 (HC) | ~2.0× → 12 MB | 12 MB | ~250 MB/s | 0.10 s | ~1 KB code, trivial |
| DEFLATE | ~2.4× → 10 MB | 10 MB | ~35 MB/s | 0.7 s | moderate |
| zstd -19 (≤8 MB window) | ~2.7× → 9 MB | 9 MB | ~60 MB/s | 0.4 s | large, but **Zig std ships a freestanding-usable zstd decoder** |

At 3 MB/s BIOS reads, zstd saves ~1.0 s of I/O vs LZ4 and pays ~0.3 s of CPU: net win, and the win grows as the rootfs grows. Decompression happens **in the kernel** (it owns ramfs anyway), so stage2 stays dumb and small; Zig `std.compress.zstd` removes the implementation-complexity argument against zstd. Window capped at 8 MB (transient kernel buffer, freed after unpack). Kernel ELF ships **uncompressed** (≤1.5 MB ≈ 0.4 s read worst-case; compressing it would drag an ELF+decoder step into stage2 for ~0.2 s, revisit in M3 only if hardware measurements demand; an LZ4-block option is reserved via header `flags`).

Rootfs container (outer wrapper around the zstd frame, built by `tools/mkear.zig`):
```
EziHeader = extern struct { magic: u32 = "EZI1", version: u16, flags: u16,
  usize: u32, csize: u32, crc32_c: u32, crc32_u: u32 } // then zstd frame
```
Inner archive "EAR1" (vibeee ARchive): sequence of `{u16 path_len, u16 mode, u32 size, path bytes, pad4, data, pad4}` records; kernel streams it into ramfs. No timestamps/uid (single-user RAM rootfs).

## 7. Boot protocol (handoff contract, kernel-facing)

Registers at kernel entry: `EAX=0x0EEEB007`, `EBX=phys &BootInfo (0x6000)`, `ESP=0x9F000`, `EIP=e_entry(phys)`.
CPU state: CR0.PE=1, PG=0; A20 on; EFLAGS IF=0 DF=0; CS=0x08 (flat 32-bit code, base 0, limit 4 GB), DS=ES=FS=GS=SS=0x10 (flat data); GDTR→stage2 GDT (kernel must load its own before touching stage2 memory); IDTR limit 0 (kernel must not `sti` before its IDT); both PICs fully masked; LAPIC untouched (BIOS default); text mode 3, cursor after last progress line; no BIOS call is valid after entry.

```zig
pub const BOOT_MAGIC_EAX: u32 = 0x0EEEB007;
pub const E820Entry = extern struct { base: u64, len: u64, kind: u32, attrs: u32 };
pub const BootInfo = extern struct {
    magic: u32,              // 0x45454F42 "EEOB"
    version: u16,            // 1; minor-compatible additions only append fields
    size: u16,               // sizeof(BootInfo) actually filled
    flags: u32,              // bit0 verbose, bit1 recovery, bit2 backup_slot,
                             // bit3 auto_fallback_triggered, bit4 booted_from_ssd(hint)
    boot_drive: u8,          // BIOS DL actually used
    boot_part_index: u8,     // MBR slot of P1 (0-based)
    edd_flags: u8, vbe_present: u8,
    disk_sig: u32,           // MBR bytes 0x1B8 of boot disk, kernel/usbd re-identify boot medium by this
    e820_count: u32,
    e820: [32]E820Entry,
    rsdp_phys: u32,
    kernel_phys: u32, kernel_len: u32,
    rootfs_phys: u32, rootfs_len: u32,   // the EZI1 container, verified crc32_c
    cmdline: [256]u8,        // NUL-terminated; BOOT.CFG cmdline + menu-appended flags
    journal_lba: u32,        // where kernel acks (0 = journaling disabled)
    log_phys: u32, log_len: u32, // stage2 text ring (8 KB) for dmesg import
    vbe_info: [512]u8,       // raw VbeInfoBlock copy if vbe_present (diagnostic only)
};
```
Framebuffer state is always "VGA text 80×25 @0xB8000" in v1 (no fb fields; the kernel display driver owns modeset per contract). MBR has no GUIDs, the `disk_sig` u32 + partition index is the boot-medium identity; eeefs superblocks carry their own UUIDs for /data /cfg mounting.

## 8. SD image & partition layout (and SSD variant)

All partitions 4 MB-aligned (8192 sectors) for cheap-SD erase blocks. Shipping image = 48 MB flat file, dd-able.

| Region | LBA | Size | Content |
|---|---|---|---|
| MBR | 0 | 512 B | stage1 + table + disk sig |
| stage2 A | 1–511 | ≤255.5 KB | header+body (cap 256 KB incl. hdr) |
| stage2 B | 1024–1534 | ≤255.5 KB | identical backup copy |
| journal | 2040 | 512 B | boot journal sector |
| reserved | 2048–8191 | 3 MB | future (e.g. splash, second journal) |
| **P1** boot+system | 8192 (4 MB) | 32 MB | FAT16, type 0x0E, active flag |
| **P2** /cfg | 73728 (36 MB) | 8 MB | eeefs (small), type 0x7F |
| **P3** /data | 90112 (44 MB) | 4 MB stub → grown | eeefs, type 0x7F |

P1 contents: `BOOT.CFG`, `KERNEL.ELF`, `ROOTFS.EZI`, `KERNEL.BAK`, `ROOTFS.BAK` (backups = last-known-good, rewritten by the updater after a successful boot of a new version). Budget: 2×1.5 + 2×10 + slack ≈ 23–28 MB → 32 MB fits. Total system image = 44 MB + 4 MB stub ≤ 48 MB budget. First boot (or installer) grows P3 to the whole card and mkfs's it (`/data expand` in recovery TUI; MBR entry rewrite + eeefs mkfs, no data to preserve in the stub).

**P1 = FAT16, decided.** Raw-LBA would shave ~300 lines from stage2, but FAT16 wins on every operational axis: kernel/rootfs updates from any OS (mtools, macOS/Windows/Linux mounts) and from vibeee itself via its in-kernel FAT driver (contract: VFS has FAT); the BIOS EZ-Flash tool reads FAT16 sticks, so the same card can carry `701.ROM` for BIOS recovery; file-level A/B fallback is trivial with files, painful with raw runs. Stage1 never parses FAT, the fixed-LBA stage2 run in the MBR gap keeps stage1 tiny; stage2 (rarely updated, dd-written by the updater with A/B copies) is the only raw-LBA object.

**SSD install (same loader, no rebuild):** identical layout dd'd to the SSD start; P3 sized to the remaining ~3.9 GB (7,815,024 sectors total, all < 2^28: BIOS EDD and later the kernel PATA driver both cover it). Differences handled at run time, not build time: stage1/2 use the BIOS-provided DL (SSD boots as 0x80; SD-as-USB-HDD also usually 0x80 with SSD shifted to 0x81, never hardcoded); kernel tells media apart by `disk_sig`. Installer = recovery-TUI action running under full vibeee booted from SD: raw-writes MBR(+table recomputed)+stage2+P1+P2 via the kernel PATA driver, creates P3, then sets `booted_from_ssd` expectations. **Boot Booster 0xEF coexistence: tolerate, don't use.** A 0xEF partition sits where the machine's history put it rather than in a fixed slot or at the disk end: the target machine carries one as P1, 39 MiB from LBA 63, with an NTFS P2 taking the rest of the disk. The installer therefore reads the table instead of assuming a layout, keeps any 0xEF slot and LBA range untouched, and never reads or writes inside it (BIOS autonomously writes POST cache there). Where no free run is large enough, installing means repartitioning what the user chooses to give up rather than filling a gap. If absent, we do not create one. Our own partitions never use type 0xEF.

## 9. Recovery story

Layered, cheapest first:
1. **Stage2 self-heal:** stage2 copy A CRC-fails → stage1/stub falls back to copy B.
2. **File fallback:** kernel/rootfs CRC or FAT lookup fails → `*_bak` files automatically, banner shown.
3. **Auto slot fallback:** journal `attempts>=3` without kernel ack → stage2 boots backup files without user action (covers "new kernel boots but dies before services").
4. **Manual menu (hold SPACE):** Normal / Verbose (`verbose=1` → kernel chatty console) / Recovery / Backup slot.
5. **Recovery mode** (`recovery=1`): same kernel + same rootfs; init pivots to a keyboard-only TUI (no GUI server) offering: (a) restore KERNEL.ELF/ROOTFS.EZI from .BAK (or from a user-supplied file on another FAT volume), (b) fsck /data and /cfg (eeefs fsck from rootfs), (c) factory reset = re-mkfs /cfg and /data, (d) install/repair SSD (§8), (e) expand /data, (f) show stage2+kernel logs. Because the rootfs is RAM-loaded and verified before entry, recovery works even with a corrupt /data.
6. **Last resort:** any other OS or machine rewrites the FAT16 files or re-dd's the 48 MB image; BIOS EZ-Flash from the same card if the BIOS itself is suspect.

Errors with no serial: every stage2 failure prints code + plain-English line + the file/CRC involved, mirrors it to the log ring, and (best-effort) records `last_err` in the journal sector so the *next* successful boot can display "previous boot failed with E5(rootfs crc)".

## 10. Build & Makefile integration (no root, mtools + dd)

Pinned tools: one Zig stable (e.g. 0.14.x, pin exact in `versions.mk`), NASM, mtools, zstd CLI, GNU Make. Image assembly is pure file operations.

```make
# tools (host, zig run, no cross setup needed)
mkpart:  tools/mkpart.zig    # writes MBR table+sig+CHS-capped entries into image
mkear:   tools/mkear.zig     # rootfs dir -> EAR1 -> zstd -19 --no-check -> EZI1 wrap (+crc32s)
patchhdr: tools/patchhdr.zig # stamps stage2 header: sectors, crc32, entry

stage1.bin: boot/stage1.asm            ; nasm -f bin -o $@ $<  # assert size <= 440
stage2.elf: boot/stage2_rm.asm boot/stage2/*.zig
	zig build-exe -target x86-freestanding -mcpu=i686 -O ReleaseSmall \
	  -T boot/stage2.ld boot/stage2/main.zig boot/stage2_rm.o
stage2.bin: stage2.elf                 ; objcopy -O binary + zig run tools/patchhdr.zig
p1.fat: kernel.elf rootfs.ezi boot.cfg
	mformat -i $@ -C -T 65536 -h 16 -s 63 -c 4 ::   # 32MB FAT16, 2KB clusters
	mcopy -i $@ BOOT.CFG KERNEL.ELF ROOTFS.EZI KERNEL.BAK ROOTFS.BAK ::
vibeee.img: stage1.bin stage2.bin p1.fat p2.eeefs p3stub.eeefs
	truncate -s 48M $@
	zig run tools/mkpart.zig -- $@ --p1 0x0E,8192,65536,active --p2 0x7F,73728,16384 --p3 0x7F,90112,8192
	dd if=stage1.bin of=$@ bs=1 count=440 conv=notrunc
	dd if=stage2.bin of=$@ bs=512 seek=1    conv=notrunc
	dd if=stage2.bin of=$@ bs=512 seek=1024 conv=notrunc
	dd if=p1.fat     of=$@ bs=512 seek=8192 conv=notrunc   # p2/p3 likewise
run:      ; qemu-system-i386 -m 512 -drive file=vibeee.img,format=raw -d guest_errors
run-usb:  ; qemu-system-i386 -m 512 -drive id=sd,file=vibeee.img,if=none,format=raw \
	      -usb -device usb-storage,drive=sd   # SeaBIOS USB-MSC boot ≈ the real SD-reader path
flash:    ; @echo "sudo dd if=vibeee.img of=/dev/rdiskN bs=4M conv=fsync  (user runs manually)"
```
`mkpart.zig` (not sfdisk) keeps the build byte-deterministic and portable (macOS host per env). CRC32 values are stamped into BOOT.CFG by the image rule.

## 11. Bring-up & test plan

QEMU emulates everything this subsystem touches (INT 13h EDD incl. AH=0x43 writes, E820, A20, VBE, USB-MSC boot via SeaBIOS), full parity for boot; the QEMU gaps (GMA900, AR2425) begin *after* handoff and are other subsystems' seams (kernel display falls back per its design when 8086:2592 absent; BootInfo is identical either way).

1. **Unit (host):** FAT16 driver, ELF loader, CRC32, BOOT.CFG parser, EAR/EZI round-trip run as native Zig tests with a RAM-backed `diskRead` mock (the `Sink`/`diskRead` seams exist for exactly this).
2. **QEMU M1 gates:** `make run` boots to a stub kernel that dumps BootInfo and compares against expectations (magic, e820 count, RSDP found, CRCs); `make run-usb` same via USB path; corruption tests: flip bytes in stage2-A / KERNEL.ELF / ROOTFS.EZI on the image → assert fallback chain (B copy, .BAK files, error codes); journal test: kill QEMU before ack 3× → assert auto-backup boot.
3. **Real hardware smoke (early, cheap):** verbose boot prints EDD version, measured read throughput (stage2 times a 4 MB read, this settles R2 and the compression math), E820 map, RSDP addr. Photograph screen (no serial). Test matrix: boot from SD reader (Esc boot menu → USB-HDD entry), boot from SSD after install, BIOS "OS Installation" Start vs Finished, BIOS 0801 vs 1302 if available, with and without an existing Boot Booster 0xEF partition on the SSD.
4. **Regression:** every release image must boot in QEMU (plain+USB) in CI (`timeout 30 make run-headless` with exit-port stub kernel).

## 12. RAM / disk / time budget (this subsystem)

- Disk: stage1 440 B; stage2 2×256 KB; P1 32 MB (files ~23–28 MB incl. backups); gap+journal 4 MB region → system image ≤ 44 MB of the 48 MB cap (4 MB spare in P3 stub).
- RAM at handoff: BootInfo ≤4 KB + log 8 KB + kernel ≤1.5 MB(+bss) + rootfs blob ≤16 MB, blob and stage2 areas are reclaimed by the kernel after unpack (transient zstd window ≤8 MB also freed) → boot path contributes ~0 to the 48 MB idle budget except the unpacked ramfs (≤24 MB, counted against the rootfs budget, not boot's).
- Time (estimates, to be replaced by M1 measurements at est. 3 MB/s BIOS reads): stage1+stub 50 ms; kernel read 0.5 s; rootfs read ~3 s; CRC ~0.1 s; menu poll 0.3 s; total ≈ 3.9 s ≤ 4.0 s share. If measured reads are ≥5 MB/s, drop to ≈2.5 s; if ≤1.5 MB/s, escalate (options: smaller rootfs, zstd -22, kernel-side streaming decompress overlap, see R2).

## 13. Risks & open questions

- **R1 EDD on the internal reader:** settled for reads, the target machine boots from the reader through USB-HDD emulation on BIOS 1302. EDD *write* (AH=0x43, journal) is still assumed, if this AMI BIOS refuses writes to USB-HDD, auto-fallback degrades to manual menu only (journaling disabled via `journal_lba=0`).
- **R2 BIOS USB read throughput unknown** (2–8 MB/s spread makes 1–4 s difference). Measured in M1 verbose boot; compression level and rootfs size budget re-tuned then.
- **R3 DL value under USB-HDD emulation:** assumed 0x80; stage1 carries a one-shot 0x80 retry. Booting from the reader with the SSD present works on the target machine, though nothing in the log says which of the two paths carried it. The SSD-only order stays open until something is installed there.
- **R4 Boot Booster interaction:** BIOS behavior when 0xEF partition absent is "full POST" per prior art; confirm no MBR rewriting by BIOS on the 701 (some AMI Boot Booster implementations touch the 0xEF partition only, expected safe).
- **R5 Zig std zstd decoder freestanding fitness** (allocator + window mgmt) at pinned version: validate in kernel M1; fallback = vendored tiny LZ4 (flags bit in EZI1 header reserves the codec switch without format break).
- **R6 SD reader quirk:** one archived report of a specific SDHC card causing USB resets [MEDIUM, peripherals §9], recommend named-brand SDHC ≤32 GB; stage1 retries mask transients.
- **Open O1:** does the BIOS boot the internal reader with *no* card-change re-enumeration issues after warm reboot? (test).
- **Open O2:** exact BIOS POST time SD vs SSD (affects whether the 8 s budget forces future Boot Booster *use*, currently out of scope by decision).
- **Open O3 (integration):** kernel team to confirm 0x6000 BootInfo address + reclaim rules, and usbd team to confirm journal-ack write path via `disk_sig` match.

## 14. Phasing

- **M1:** stage1, stage2 minimal (no menu/journal): A20+E820+RSDP, FAT16, ELF load, EZI load+CRC, BootInfo handoff; mkear/mkpart/patchhdr tools; full Makefile image; QEMU plain+USB boot green; hardware smoke with throughput measurement (settles R1–R3).
- **M2:** boot menu, verbose/recovery flags, .BAK fallback, journal + auto slot fallback, recovery TUI hooks (`recovery=1` contract with init), SSD installer + Boot Booster tolerance, corruption-injection test suite in CI.
- **M3:** tuning from hardware data (chunk size, zstd level, optional LZ4 kernel compression), /data first-boot expansion polish, previous-boot-failure banner, BIOS-quirk workarounds discovered in the field.

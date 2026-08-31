# vibeee Design 07: USBD: Userspace USB Stack

> Where this document and [`00-vibeee.md`](00-vibeee.md) disagree, the master design wins:
> it carries later decisions this document predates.

Status: implemented through M1, verified end to end in QEMU. Both controllers
run behind one seam: EHCI for high speed, and the UHCI companions that a full or
low speed root port belongs to. On top of them: enumeration, hot-plug, the
bulk-only mass storage class with its SCSI commands, the block-device seam to
the kernel, and boot-protocol HID. A stick is enumerated, mounted under /media,
read and written, and unplugging it takes its mount with it; a keyboard types
and a mouse moves the pointer, on either controller. Hubs are driven, so a keyboard or a disk behind one appears
and disappears like anything else. UVC (§4.2) and suspend and resume (§5.8) are design
for later milestones. Owner: usbd. Depends
on: kernel contracts v0, 05-input (injection), 03-vfs (volume consumer),
platformd (CAMS/ACPI), devmgr (supervision/matching).

**The block-device seam is simpler than the ring below.** §4.1 describes an
SPSC shm ring whose shape was left open pending kernel-core; what exists is a
shared data area with the descriptors passed through ordinary syscalls, which
keeps the property that mattered (the transfer is copied once, and the driver's
DMA lands straight in the kernel's buffer) without a lock-free ring a
four-deep queue does not earn. `src/lib/volume.zig` is the contract.

## 1. Overview

usbd is a single supervised userspace server owning all five ICH6-M USB host controllers:
one EHCI (8086:265c, 00:1d.7) and four UHCI companions (8086:2658/2659/265a/265b, 00:1d.0–.3).
It hosts the USB core (enumeration, hubs, hotplug) and three in-process class drivers:

- **MSC** (bulk-only mass storage / transparent SCSI) → exported to the kernel as **ublk** block devices. This is the system's persistence path: the internal SD reader (0951:1606, ENE UB6225, high-speed) plus external sticks.
- **UVC** (eb1a:2761 webcam, 640×480 YUYV, isochronous) → shm frame ring to camera clients. Phase 3.
- **HID boot protocol** (external keyboards/mice, full/low-speed via UHCI) → injected into the kernel input core. Phase 2.

Design center: **EHCI-only covers 100% of internal devices** (card reader and webcam both enumerate high-speed). UHCI exists solely for *external* FS/LS devices (HID, ancient sticks) and is phased to M2. usbd is single-threaded (event loop over `wait_many`), restartable, and shares one code path for crash-restart and S3 resume: full re-init + re-enumeration + identity-matched ublk reattach.

## 2. Hardware facts used (with research confidence)

| Fact | Source/confidence |
|---|---|
| 4×UHCI (2658/2659/265a/265b) + 1×EHCI (265c), 8 ports total, rev 04 | HIGH (verbatim lspci, both reports) |
| Card reader 0951:1606 ENE UB6225, MSC class 08/06/50 (BOT/SCSI), high-speed on EHCI, observed port 5 | HIGH id/class; MEDIUM port number |
| Webcam eb1a:2761 eMPIA, UVC 1.0, 640×480 YUYV/UYVY 30fps, high-speed, observed port 8 | HIGH id/class/format; MEDIUM port number |
| Webcam BIOS-default-DISABLED; runtime power gate via ASUS010 `CAMG/CAMS` (device drops off bus entirely) | HIGH |
| Possible shared power rail: CAMS toggle may also cut card-reader power (verified on 900, not 701) | MEDIUM caveat, design defends against it |
| 3 external USB-A ports; 5 of 8 root ports wired; external-port→controller mapping unknown | HIGH counts; LOW mapping |
| EHCI IRQ observed GSI 23 (shared with UHCI#1); UHCI on 16/18/19/23 | MEDIUM exact GSIs, read from ACPI/IOAPIC at runtime, never hardcode |
| Legacy BIOS boots us via INT 13h from the internal (USB) SD reader → BIOS SMM legacy-USB emulation is ACTIVE at kernel entry | HIGH (boot design + BIOS report) |
| MCFG ECAM at 0xE0000000; PCI cfg via kernel `pci_cfg_*` | HIGH |
| No IOMMU; DMA is trusted; 32-bit phys space | HIGH |
| Memory bandwidth is scarce (possibly DDR2-140), copies are a first-order cost | MEDIUM (unresolved conflict), budget assumes the low reading |

Runtime-probed, never assumed: HCSPARAMS (N_PORTS/PPC/N_CC), HCCPARAMS (EECP, 64-bit flag, expect 0), GSIs from ACPI PRT, UVC alt-setting table, MSC bMaxLun.

## 3. Architecture

```
                 kernel                                  usbd (this doc)
  VFS ── ublk shm ring ─────────────────────► MSC class ──► SCSI/BOT ──► EHCI HCD ─► 00:1d.7
  input core ◄─ input.inject channel ──────── HID class ──────────────► UHCI HCD ─► 00:1d.0-3
  app  ◄─ cam shm frame ring + channel ────── UVC class ──► iso engine ─► EHCI HCD
  devmgr ◄─ attach/detach events ──────────── USB core (enum, hubs, hotplug, strings)
  platformd ◄─ CAMS set/get channel ────────── power coordination
```

- **Process model:** one process, one event loop. Waitables: 5 irqevents, N ublk SQ doorbell events, service channel(s), timer. No threads, no locks; per-device state machines advanced by completions.
- **HCD seam:** both HCDs implement `HcOps` (vtable) so the USB core is host-controller-agnostic and unit-testable against a mock HC on the build host (QEMU cannot emulate our exact silicon anyway, but EHCI/UHCI are standard, so QEMU parity testing works, §8).
- **Controller phasing:** M1 = EHCI only, `CONFIGFLAG=1`, FS/LS ports released to (dead) companions are simply ignored. M2 = UHCI companions come alive. Justified: both internal devices are HS; external HID is the only consumer of UHCI and is not needed for a usable machine.
- **devmgr contract:** usbd's manifest claims PCI class 0x0C03 prog-if 0x20 (EHCI) and 0x00 (UHCI) with vendor filter 8086, class-code matching (not bare DID) so the same binary drives QEMU's ICH9 EHCI in CI.

### Startup sequencing vs. BIOS legacy USB (boot-to-RAM interlock)

The bootloader used INT 13h (BIOS SMM code driving EHCI) to load kernel+rootfs into RAM. Rules:

1. Kernel and early userspace **never touch USB MMIO/PIO** before usbd claims the devices. Nothing else needs to: boot media is already in RAM.
2. By the time devmgr starts usbd, INT 13h is no longer needed (running from RAM). The SD card is *not* mounted until usbd exports it via ublk.
3. usbd start order: **quiesce all five controllers first** (EHCI handoff §5.1, UHCI legacy-disable §5.6), then init EHCI, then (M2) init UHCIs. Handoff-before-any-init prevents SMM code from racing our schedule programming.
4. BIOS keyboard emulation for *USB* keyboards dies at handoff, irrelevant: internal keyboard is true i8042 PS/2.

## 4. Data structures & interfaces (public)

### 4.1 The block-device seam (usbd ⇄ kernel VFS), one per exported volume

**As built** (`src/lib/volume.zig`, `src/kernel/ublk.zig`, `src/user/usbd/volume.zig`).
The kernel allocates one DMA-able area per volume and hands usbd a handle to map
it, alongside an event to wait on. The area is divided into four slots of 16 KiB;
a request names a slot, and the bytes for that request live there and nowhere
else, so a transfer crosses the boundary once. Descriptors travel through
`volume_attach`, `volume_next`, `volume_done` and `volume_detach` rather than a
ring: at four deep the syscall is a rounding error beside the transfer, and there
is no lock-free correctness argument to get wrong.

The kernel's caller blocks on its own request with a deadline (5 s reads, 15 s
writes) so a server that dies leaves its readers failing rather than waiting.
usbd's event loop waits on the volume's doorbell alongside the controller's
interrupt and its service channel, and drains every posted request when it rings.
Registration runs the partition scan on a thread of its own, because the server
is still inside `volume_attach` when the first sector is wanted and cannot answer
it. A volume that goes takes its mounts with it and its block-layer rows are
reused.

**The original ring design follows**, kept because its flow-control and
media-event semantics still describe what the seam has to do as it grows.

Shared memory allocated by usbd from `dma_alloc` (so the data area is DMA-able → EHCI writes read-data directly into it; the kernel copy into page cache is the only copy). SPSC both directions, event-signaled per contract v0.

```zig
pub const UBLK_MAGIC: u32 = 0x6b6c6275; // "ublk"
pub const UblkOp = enum(u8) { read = 0, write = 1, flush = 2 };
pub const UblkStatus = enum(u8) { ok = 0, io_err = 1, no_medium = 2, timeout = 3, write_protected = 4, aborted = 5 };

pub const UblkSqe = extern struct { // 24 B, kernel→usbd
    tag: u16, op: u8, _r0: u8,
    len_sectors: u32,      // ≤ data_len/512 per request
    lba: u64,              // 512-B sectors
    data_off: u32,         // offset into data area (512-aligned)
    _r1: u32,
};
pub const UblkCqe = extern struct { // 8 B, usbd→kernel
    tag: u16, status: u8, _r0: u8, done_sectors: u32,
};
pub const UblkRing = extern struct {  // page 0 of the shm object
    magic: u32, version: u16, sq_entries: u16,       // sq_entries = cq_entries = 32
    sq_head: u32, sq_tail: u32,                      // kernel produces at tail, usbd consumes at head
    cq_head: u32, cq_tail: u32,
    ssize: u32, sectors: u64,
    flags: u32,                                      // bit0 removable, bit1 read-only
    data_off: u32, data_len: u32,                    // 256 KiB data area follows descriptors
    // sqe[32], cqe[32], then data area
};
```

Registration and media events go over usbd's control channel to the kernel (shape needed from kernel-core, see OPEN):

```zig
// svc "ublk.ctl" (kernel-side listener)
pub const UblkAttach = struct { name: [16]u8, ring_shm: Handle, sq_doorbell: Handle, cq_event: Handle, ident: UblkIdent };
pub const UblkIdent = extern struct { vid: u16, pid: u16, port_path: [8]u8, capacity_sectors: u64, ssize: u32 };
pub const UblkMediaEvent = enum(u8) { media_gone, media_changed, capacity_changed };
```

**Semantics:** flow control = fixed 32-deep SQ; kernel blocks/queues when full. usbd may complete out of order (tags). `flush` maps to SCSI SYNCHRONIZE CACHE(10); devices that stall it complete `ok` (documented cheap-reader behavior). Per-op timeouts are usbd's (read 5 s, write 15 s, flush 15 s: SD internal GC can stall seconds); the kernel only times out on channel death. On media yank: every in-flight and queued op completes `no_medium`, then `media_gone` event; VFS must drop dirty state and mark the mount dead. On usbd death: kernel freezes the mount ≤10 s awaiting a new `UblkAttach` whose `UblkIdent` matches (port_path+vid:pid+capacity); on match it replays incomplete ops (reads/writes are LBA-idempotent); recommend VFS additionally revalidates the FAT volume serial before replay (OPEN).

### 4.2 Camera client API (svc "usb.cam"), phase 3

```zig
pub const CamFourcc = enum(u32) { yuy2 = 0x32595559 }; // 'YUY2'
pub const CamFormat = extern struct { width: u16, height: u16, fourcc: u32, fps: u8, _r: [3]u8 };
pub const CamOpen = struct { fmt: CamFormat };          // reply: { ring_shm: Handle, frame_event: Handle }
pub const CamFrameState = enum(u32) { free, filling, ready, held };
pub const CamFrameHdr = extern struct { state: u32, seq: u32, t_us: u64, bytes: u32, _r: u32 };
// ring_shm layout: CamRingHdr { nbufs:u32 (=3), buf_size:u32 (=614400), fmt: CamFormat }, then nbufs × (CamFrameHdr + buffer)
// protocol: usbd fills a `free` buf → `ready` + signal frame_event; client CAS ready→held, renders, sets held→free.
// If no `free` buf when a frame completes, the frame is dropped (client too slow), never blocks the iso engine.
// channel ops: open, start, stop, close, get_formats() → []CamFormat, get_ctrl/set_ctrl(brightness, etc. VC PU controls, M3+)
```

### 4.3 Hotplug events to devmgr (svc "usb.events")

```zig
pub const UsbSpeed = enum(u8) { low, full, high };
pub const UsbDevInfo = extern struct {
    vid: u16, pid: u16, bcd_dev: u16,
    class: u8, subclass: u8, protocol: u8, speed: u8, _r: u8,
    port_path: [8]u8,        // root port, then hub ports; 0-terminated
    claimed_by: u8,          // enum: none, msc, uvc, hid, hub
    mfr: [32]u8, prod: [64]u8, serial: [32]u8, // UTF-8, NUL-terminated (from string descriptors, langid 0x0409 or first)
};
// events: attach(UsbDevInfo), detach(port_path), plus UblkMediaEvent forwarded for GUI (eject toasts)
```

### 4.4 HID → kernel input core (consumes 05-input)

usbd translates boot-protocol reports into contract `input_event{t_us,type,code,value}` batches and writes them to the input-injection channel defined by 05-input. usbd owns the USB-HID-usage→keycode table (~200 B) and modifier/6-key rollover diffing state per keyboard.

### 4.5 Internal HCD seam (test boundary, not IPC)

```zig
pub const XferKind = enum { control, bulk, interrupt, iso };
pub const XferResult = struct { status: enum { ok, stall, xact_err, babble, timeout, cancelled, no_device }, actual: u32 };
pub const Xfer = struct {
    ep: *Endpoint, kind: XferKind, dir: enum { in, out },
    setup: ?[8]u8,                 // control only
    buf_phys: u32, len: u32,       // all buffers come from dma_alloc regions
    timeout_ms: u32,
    done: *const fn (*Xfer, XferResult) void, ctx: usize,
};
pub const HcOps = struct {
    init: *const fn (*Hc) anyerror!void,
    halt: *const fn (*Hc) void,
    port_count: *const fn (*Hc) u8,
    port_status: *const fn (*Hc, port: u8) PortStatus,        // connect, enabled, change bits
    port_reset: *const fn (*Hc, port: u8) anyerror!UsbSpeed,  // EHCI may return error.ReleasedToCompanion
    port_release: *const fn (*Hc, port: u8) void,             // EHCI: PORTSC.PO=1
    ep_open: *const fn (*Hc, *Endpoint) anyerror!void,        // allocates QH / periodic slot / iso bandwidth
    ep_close: *const fn (*Hc, *Endpoint) void,                // safe unlink (doorbell) + toggle state drop
    submit: *const fn (*Hc, *Xfer) anyerror!void,
    cancel: *const fn (*Hc, *Xfer) void,
    on_irq: *const fn (*Hc) u32,                              // returns handled-status bits; caller acks irqevent
};
```

### 4.6 Kernel user-driver API consumed (contract v0)

`pci_cfg_read/write(bdf,off,w)`, `map_mmio(paddr,len)` (EHCI BAR0, 1 KiB), `ioport_grant(base,len)` (4× UHCI I/O BARs, 32 B each: UHCI is port-I/O), `dma_alloc(len)` → `{vaddr, paddr, contiguous, <4GB}`, `irq_attach(gsi)` → event. **Required irq semantics:** level-triggered shared lines (GSI 23 = EHCI+UHCI#1), kernel masks the GSI on assert and signals every attached event; each driver clears its device's status (write-1-clear USBSTS) then calls `irq_ack(handle)`; kernel unmasks when all attached handles acked. (Contract point, see OPEN.)

## 5. Register-level programming sequences

### 5.1 EHCI BIOS handoff (USBLEGSUP via EECP), first touch of any USB register

```
bdf = 00:1d.7
1. cmd = pci_cfg_read16(bdf, 0x04); pci_cfg_write16(bdf, 0x04, cmd | 0x0006)   // MEM + BusMaster
2. bar0 = pci_cfg_read32(bdf, 0x10) & 0xFFFFFF00; cap = map_mmio(bar0, 0x400)
3. caplen = mmio8[cap+0x00]; op = cap + caplen
   hcs = mmio32[cap+0x04]                  // N_PORTS=hcs[3:0] (expect 8), PPC=hcs[4] (expect 0)
   hcc = mmio32[cap+0x08]; eecp = (hcc >> 8) & 0xFF          // Intel ICH: expect 0x68
4. if eecp >= 0x40:
     assert(pci_cfg_read8(bdf, eecp) == 0x01)                // cap id = legacy support
     pci_cfg_write8(bdf, eecp+3, 0x01)                       // set HC OS Owned (USBLEGSUP bit 24)
     poll ≤1000 ms: (pci_cfg_read8(bdf, eecp+2) & 0x01)==0   // wait BIOS Owned (bit 16) clear
     on timeout: pci_cfg_write32(bdf, eecp, 0x01000100 & ~0x00010000)  // force-clear BIOS bit, keep OS bit
     pci_cfg_write32(bdf, eecp+4, 0)                         // USBLEGCTLSTS = 0: disable ALL legacy SMIs
5. From here BIOS SMM never touches this controller again. INT 13h to USB is dead, by design we no longer need it.
```

### 5.2 EHCI controller init

```
// operational registers at `op`: USBCMD 0x00, USBSTS 0x04, USBINTR 0x08, FRINDEX 0x0C,
// PERIODICLISTBASE 0x14, ASYNCLISTADDR 0x18, CONFIGFLAG 0x40, PORTSC[1..N] 0x44+4*(n-1)
1. Halt: USBCMD &= ~RS(bit0); poll ≤16 ms USBSTS.HCHalted(bit12)==1
2. Reset: USBCMD |= HCRESET(bit1); poll ≤250 ms bit1==0
3. Allocate from dma_alloc (all 32-bit phys):
   - frame list: 4 KiB, 4 KiB-aligned, 1024 entries; every entry → interrupt-skeleton tree (T=1 for empty in M1)
   - async head QH: H-bit=1, horizontal link → itself, overlay halted
   - pools: 64 QH (aligned 64), 256 qTD (aligned 32), 16 iTD (aligned 64, M3)
4. mmio32[op+0x14] = framelist_phys; mmio32[op+0x18] = async_head_phys
5. USBINTR = 0x3F & ~FLR = IAA|HSE|FLR? -> program 0x37: USBINT|USBERRINT|PCD|HSE|IAA (skip frame-list rollover)
6. USBCMD = ITC=8µframes(bits23:16=0x08) | FLS=00(1024) | ASE(bit5)=1 | PSE(bit4)=0(M1..M2)|1(M3) | RS(bit0)=1
7. mmio32[op+0x40] = 1                                   // CONFIGFLAG: route all ports to EHCI
8. if PPC==1: for each port: PORTSC |= PP(bit12)         // ICH6 expected PPC=0 (always powered)
9. wait 20 ms, then scan PORTSC[1..8] for CCS(bit0)      // internal devices are already attached
```

### 5.3 EHCI port state machine (per port, on PCD irq or initial scan)

```
connect (CCS=1, CSC w1c):
  debounce 100 ms; if CCS still 1:
  if PORTSC.LineStatus(bits11:10) == 01b (K-state) → low-speed: PORTSC.PO=1 (bit13); done (companion's problem; ignored in M1)
  else: PORTSC.PR=1(bit8); wait 50 ms; PR=0; poll ≤2 ms PR==0 reads back
        if PED(bit2)==1 → high-speed device → enumerate on EHCI
        else → full-speed → PORTSC.PO=1 → companion (M2) / ignored (M1)
disconnect (CCS=0, CSC): tear down device tree at that port (cancel xfers → no_device; ublk media_gone if MSC)
note: hardware returns PO to EHCI on disconnect; next connect re-runs this routing decision.
overcurrent (OCC): log, clear, disable port until next connect.
```

### 5.4 EHCI async schedule (control + bulk), structures and hot path

```
QH (48 B used, 64 B slots): DW0 QH-link(Typ=01)|T · DW1: RL(31:28)=4|C|MaxPkt(26:16)|H|DTC=1|EPS|EndPt(11:8)|I|DevAddr(6:0)
                            DW2: Mult(31:30)=1|PortNum|HubAddr|C-mask=0|S-mask=0 · DW3 current qTD · DW4.. overlay
qTD (32 B): DW0 next · DW1 altnext · DW2 token: DT(31)|Bytes(30:16 ≤0x5000)|IOC(15)|C_Page|CERR=3|PID(9:8)|Status(7:0)
            DW3..7: 5 page pointers → ≤20 KiB/qTD, we use 16 KiB-aligned chunks
- One QH per open endpoint, linked in the async ring after the H-bit head.
- MSC 64 KiB READ(10): OUT-QH gets 1 qTD (CBW, 31 B); IN-QH gets 4 data qTDs (16 KiB each) + 1 CSW qTD (13 B).
  All queued at once: EHCI NAK-polls IN until the device turns around (BOT ordering is device-enforced).
  Every data qTD's altnext → CSW qTD (short-packet early-out lands on the CSW). IOC only on CSW → 1 irq per 64 KiB.
- Unlink discipline: to close/cancel a QH: unlink from ring → USBCMD.IAAD(bit6)=1 → wait USBSTS.IAA irq → recycle memory.
  qTD memory is never handed back while the QH could still reference it (doorbell rule). Prevents use-after-free DMA.
```

### 5.5 EHCI periodic schedule (M2 skeleton, M3 iso)

```
- Interrupt skeleton: dummy QHs for periods {32,16,8,4,2,1} ms, 63 nodes, tree-linked; frame list entry i →
  leaf (i mod 32). Interrupt QH: S-mask picks 1 µframe; budget tracked per µframe (≤6000 B of 7500, 80% rule).
- Used on EHCI only for HS hub status-change endpoints (M2), tiny (≤2 B, 255 ms poll).
- iTD (UVC, M3): 64 B: DW0 next-link · DW1..8: 8 µframe slots {Status(31:28), Length(27:16), IOC(15), PG(14:12), Off(11:0)}
  · DW9..15: 7 page pointers; page0 low: EndPt|DevAddr; page1 low: Dir|MaxPkt(10:0); page2 low: Mult(1:0)
- UVC bandwidth math: 640×480 YUYV@30 = 614400 B × 30 = 18.43 MB/s ≈ 2304 B/µframe average.
  Alt settings on eb1a:2761 (probed at runtime): need wMaxPacketSize ≥ 0x1400-class, i.e. 2×1024=2048 (16.4 MB/s, too small)
  → select 3×1024 (Mult=3, 3072 B/µframe = 24.58 MB/s peak). Fits the 6000 B/µframe periodic budget with headroom.
- iTD ring: 1 iTD = 1 frame (8 µframes × ≤3072 B = 24576 B slab). Depth 8 (8 ms). Schedule ≥2 frames ahead of FRINDEX;
  on IOC (per iTD) strip 12-B UVC payload headers, copy payload into the current CamFrame buffer, watch FID toggle/EOF
  for frame boundaries, mark `ready` on EOF or size-complete. Header ERR bit → drop frame, resync on next FID toggle.
- Enable/disable PSE only after confirming USBSTS.PSS matches; never modify live frame-list entries except via
  inactive-then-link writes (single 32-bit link-pointer stores are atomic).
```

### 5.6 UHCI companions (M2), legacy disable, init, structures

```
per controller (00:1d.0..3), I/O BAR at cfg 0x20 (32 ports), via ioport_grant:
1. pci_cfg_write16(bdf, 0xC0, 0x8F00)      // LEGSUP: w1c all SMI-trap status, disable kbd/mouse trapping
2. outw(io+0x00, 0x0004); wait 25 ms; outw(io+0x00, 0)   // global reset (some BIOSes need it), then idle
3. outw(io+0x00, 0x0002); poll ≤3 ms bit clears           // HCRESET
4. frame list 4 KiB dma_alloc; all 1024 entries → skeleton QHs: int{32..1} → control-QH → bulk-QH chain
5. outl(io+0x08, framelist_phys); outw(io+0x06, 0)        // FRBASEADD, FRNUM=0
   outb(io+0x0C, 0x40)                                    // SOFMOD default
6. pci_cfg_write16(bdf, 0xC0, 0x2000)                     // LEGSUP: USB PIRQ enable (route real IRQs)
7. outw(io+0x04, 0x000F)                                  // USBINTR: timeout/CRC, resume, IOC, short packet
8. outw(io+0x00, 0x00C1)                                  // USBCMD: MAXP=64 | CF(configured) | RS
ports: PORTSC1/2 at io+0x10/0x12: reset = set bit9 50 ms, clear, 10 ms, set PED(bit2); LS device if bit8.
TD (32 B, 16-aligned): DW0 link(Vf|Q|T) · DW1 status: SPD|C_ERR=3|LS|IOC|Active|errbits|ActLen(10:0)
                       DW2 token: MaxLen(31:21)|DT(19)|EndPt(18:15)|DevAddr(14:8)|PID(7:0) · DW3 buffer
Scope deliberately minimal: control + interrupt-IN only (HID boot kbd 8-B reports @10 ms, mouse 4-B @10 ms).
No UHCI bulk (FS mass storage refused with a devmgr "unsupported" event; USB1.1 sticks are museum pieces).
```

### 5.7 Enumeration state machine (core, speed-independent)

```
Powered →(debounce 100 ms)→ Reset(§5.3/5.6) → Default:
  GET_DESCRIPTOR(device, 8 B) @addr0  // MPS0: HS always 64; FS/LS read bMaxPacketSize0
  SET_ADDRESS(alloc 1..127 bitmap); wait 2 ms → Address:
  GET_DESCRIPTOR(device, 18 B) → vid/pid/class
  GET_DESCRIPTOR(config, 9 B) → wTotalLength (cap 4 KiB: UVC configs are >1 KiB) → full config read
  parse interfaces/endpoints; GET string descriptors (langid table → 0x0409 preferred, else first; UTF-16LE→UTF-8)
  SET_CONFIGURATION(1) → Configured → bind class driver by (class,subclass,proto):
    08/06/50 → MSC · 0E/xx → UVC · 03/01/01|02 → HID boot · 09/00 → hub
  emit devmgr attach event. Any control transfer failing 3× → port reset once → 3× again → give up, log, mark port dead
  until next connect. Enumeration is serialized globally (one device at a time), simple and race-free.
Hubs (M2): external HS hubs on EHCI: read hub descriptor, power ports (SetPortFeature PORT_POWER), poll status-change
  interrupt endpoint, per-port: reset via SetPortFeature PORT_RESET, read speed from port status; HS children fine;
  FS/LS children behind HS hub need split transactions → M3 (interrupt-IN splits only, for HID; C-mask=S-mask<<2 rule).
```

### 5.8 MSC/BOT engine + error ladder

```
CBW(31 B): sig 0x43425355, tag++, dataLen, flags(bit7 dir), LUN, cbLen, CB[16]
CSW(13 B): sig 0x53425355, tag match, residue, status {0 ok, 1 fail, 2 phase error}
SCSI subset: INQUIRY(36) · TEST UNIT READY · REQUEST SENSE(18) · READ CAPACITY(10) · READ(10) · WRITE(10)
             · SYNCHRONIZE CACHE(10) (stall-tolerant) · MODE SENSE(6) page 0x3F for write-protect bit (stall-tolerant)
bMaxLun via class GET_MAX_LUN (0xA1/0xFE); stall ⇒ 1 LUN. UB6225 expected single-LUN.
Media polling (card reader semantics):
  no-media: TEST UNIT READY every 1000 ms; sense 02/3A/00 = still empty
  media-in transition: sense 06/28/00 (UNIT ATTENTION: not-ready→ready) → READ CAPACITY → UblkAttach → devmgr event
  mounted: TUR heartbeat every 2000 ms, ONLY if no I/O in the last 2 s (never compete with streaming)
  any CHECK CONDITION during I/O → REQUEST SENSE: 02/3A ⇒ yank path: fail all queued ublk ops no_medium,
  UblkMediaEvent.media_gone, detach ublk; 06/28 with media still present ⇒ media_changed + re-READ CAPACITY.
Error/retry ladder (per failed transfer, escalate):
  L0 hw retries: CERR=3 in qTD handles transient bus errors
  L1 bulk STALL: CLEAR_FEATURE(ENDPOINT_HALT) + reset our data toggle for that ep, re-read CSW, retry op once
  L2 CSW phase error / garbage: Bulk-Only Reset (0x21/0xFF/wIndex=iface) + clear both halts + toggles, retry op once
  L3 timeout (no CSW within op timeout): cancel qTDs → port reset → re-enumerate (identity match keeps ublk attach) → retry once
  L4 fail op upward: UblkStatus.io_err (or no_medium/timeout as diagnosed). Ladder state is per-device; 3 L3 trips
     in 60 s ⇒ mark device bad, detach, devmgr event (GUI toast).
Request coalescing: adjacent-LBA same-op SQEs merged up to 64 KiB per BOT command (conservative cheap-reader cap;
128 KiB experiment behind a manifest flag). 20 MB/s ⇒ ~320 BOT cmds/s ⇒ ~320 IRQs/s (IOC-on-CSW only).
```

### 5.9 UVC session (M3), power + probe/commit

```
open flow:
1. ask platformd: CAMS get; if 0 → CAMS=1; expect root-port connect within ~500 ms (BIOS "Onboard Camera" must be
   Enabled, if no connect in 2 s, reply error.CameraDisabledInBios with UI-facing message)
2. QUIRK DEFENSE (shared power rail, MEDIUM): any card-reader disconnect within 1 s of a CAMS transition is treated
   as a power-glitch resync, not a yank: ublk enters frozen state (as in usbd-restart) and reattaches by identity
   instead of completing ops no_medium. First real-hw bring-up test decides if the 701 has the 900's shared rail;
   if yes, policy flips to "CAMS latched on while any MSC media is mounted".
3. enumerate → UVC: parse VC/VS descriptors; negotiate: SET_CUR(VS_PROBE, {bFormatIndex/bFrameIndex for 640×480 YUY2,
   dwFrameInterval=333333}) → GET_CUR(VS_PROBE) → accept device-adjusted dwMaxPayloadTransferSize → SET_CUR(VS_COMMIT)
4. SET_INTERFACE(streaming iface, alt with wMaxPacketSize ≥ negotiated payload; expect 3×1024) → start iTD ring (§5.5)
5. stop/close: SET_INTERFACE alt 0, drain iTDs, CAMS=0 after 5 s idle (unless quirk policy latches it on)
```

### 5.10 Suspend/resume & restart (shared path)

```
S3 prepare (platformd broadcast): stop accepting SQEs → drain in-flight (≤2 s, else cancel→aborted) → SYNCHRONIZE CACHE
→ ublk marks frozen → stop schedules (ASE/PSE off, confirm status) → RS=0, HCHalted → ack platformd.
No PORTSC suspend/remote-wake programming: WKCNNT/WKDSCNNT/WKOC stay 0, we never SET_FEATURE(REMOTE_WAKEUP).
Justification: S3 cuts HC state anyway on this platform; wake sources are lid/power via EC/ACPI GPEs (platformd);
USB wake adds BIOS/SMM interaction risk and GPE plumbing for zero user value on this machine.
Resume / crash-restart (same code): claim PCI → restore PCI cmd/BARs from saved copy → §5.1 handoff (BIOS may have
re-run POST paths) → full init → re-enumerate everything → identity-match ublk (§4.1) → unfreeze or 10 s-timeout-fail.
DMA safety across crash: kernel must quarantine the dead usbd's dma_alloc pages until the successor completes HCRESET
on all five controllers (successor reports via ublk.ctl "reset_done"), otherwise a still-running EHCI DMAs into
recycled pages. (Kernel contract addition: OPEN.)
```

## 6. RAM / disk / CPU budget

| Item | Size |
|---|---|
| Binary on disk (ReleaseSmall, target) | ≤ 384 KiB (cap 1.5 MiB; est: core 20K, EHCI 15K, UHCI 8K, MSC 10K, UVC 20K, HID 6K, hub 8K, rt 40K + slack) |
| Resident code+data+stack | ~450 KiB |
| EHCI DMA: frame list 4K + skeleton 3K + 64 QH 4K + 256 qTD 8K | 19 KiB |
| UHCI ×4 (M2): frame list 4K + TD/QH pool 4K each | 32 KiB |
| Per ublk device: ring page + 32 SQE/CQE + 256 KiB data area | 260 KiB (1 idle = card reader; ≤4 total) |
| Enumeration/debug log ring | 16 KiB |
| **Idle total (M2, card reader exported)** | **≈ 780 KiB** |
| UVC active (M3): 8×24 KiB iTD slabs + 16 iTD + 3×600 KiB shm frame ring | +2.0 MiB only while camera open |

CPU at 20 MB/s MSC streaming (630 MHz, low-memory-bandwidth assumption): 320 IRQs/s × ~15 µs (irqevent wake + USBSTS ack + completion walk) ≈ 0.5%; ring/SCSI bookkeeping ≈ 1%; DMA lands in the ublk data area so usbd copies nothing. The kernel's copy to page cache is the dominant cost: 20 MB/s copied at ~300 MB/s effective memcpy ≈ 7% CPU + 40 MB/s of memory bandwidth. Total ≈ 8–9%. If this proves too hot for GUI+audio concurrency, the ublk extension "SQE carries page-cache phys scatter list, usbd DMAs directly" (legit: no IOMMU, DMA already trusted) cuts it to ≈ 2%, proposed, not baseline (OPEN). UVC streaming (M3): 18.4 MB/s header-strip copy ≈ 6–8% CPU + iso bookkeeping ≈ 2%, acceptable for a camera-app foreground use case.

## 7. Bring-up & test plan

**Host unit tests (zig test, no hardware):** USB core + enumeration SM + MSC ladder + UVC parser against a scripted `MockHc` (canned descriptors incl. real dumps of 0951:1606 and eb1a:2761 from Linux `lsusb -v` captures; fault injection: stalls, phase errors, yank-mid-CBW, truncated descriptors).

**QEMU (i686, `-M pc`):** no GMA900/AR2425 emulation matters here: EHCI/UHCI are standard. Configs:
- `-device usb-ehci -device usb-storage,drive=sd0`, async schedule, BOT, ublk end-to-end (kernel mounts FAT via ublk).
- `-device ich9-usb-ehci1,id=ehci -device ich9-usb-uhci1,masterbus=ehci.0,firstport=0 -device ich9-usb-uhci2,masterbus=ehci.0,firstport=2 -device ich9-usb-uhci3,masterbus=ehci.0,firstport=4` + `-device usb-kbd`/`usb-mouse`, port routing (FS device → PO handoff → UHCI), HID path, class-code (not DID) matching proven.
- Hotplug: QMP `device_del/device_add` on usb-storage, yank ladder, media events, remount-by-identity.
- usbd kill -9 during dd-to-SD, restart, DMA quarantine handshake, frozen-mount replay.
- No UVC device model in QEMU → UVC iso engine tested via MockHc timing harness + real hardware only.

**Real 701 hardware:** no serial port; enumeration logger writes the 16 KiB debug ring; dumped (a) on-screen via GUI debug overlay, (b) to /tmp then /data/log/usb.log once ublk mounts, (c) on hard hang: log ring lives at a fixed phys address surviving warm reboot, dumped by the next boot (bootloader flag). Milestone gates: M1 = boot to GUI with /data mounted from SD via ublk, dd throughput ≥ 15 MB/s read / 8 MB/s write, 500× scripted mount/unmount + 50× physical yank torture. M2 = external keyboard+mouse+hub matrix (5 cheap hubs), S3 100-cycle soak with SD I/O across suspend. M3 = 30 min camera streaming, zero frame-ring stalls of GUI, CAMS/card-reader shared-rail probe test (documented result feeds §5.9 policy).

## 8. Risks & open questions

- **BIOS handoff misbehavior** (AMI 2007-era): BIOS may never clear the owned semaphore → we force-take after 1 s and kill SMIs. Residual risk: SMM wedge on force-take. Mitigated by testing on BIOS 1302 + fallback boot flag `usb=late` (delay claim 5 s).
- **Shared CAMS power rail** (MEDIUM, from 900): defended in §5.9; needs the real-hw probe test before M3 ships defaults.
- **GSI sharing** EHCI+UHCI#1 on 23: requires the multi-acker level-IRQ contract (§4.6); if kernel-core rejects it, fallback = usbd attaches once per GSI and demuxes internally (it owns all sharers anyway, cheap).
- **UB6225 quirk surface** unknown (SDHC reset loop reported once): the L0–L4 ladder + per-device quirk flags in manifest (no-SYNC-CACHE, max-transfer-cap) is the containment strategy.
- **kernel copy cost** may force the phys-scatter ublk extension (§6), decide after M1 measurement with audio+GUI load.
- **Split transactions** (FS/LS behind HS hub) are M3 and interrupt-IN only; full FS iso/bulk behind hubs: never (documented limitation).
- **Identity ambiguity on crash-window card swap** (same-capacity card swapped while usbd restarts): mitigated only if VFS revalidates volume serial before replay, needs 03-vfs buy-in.

## 9. Phasing

- **M1 (boots the OS), done:** EHCI (handoff, async and periodic schedules, ports), core enumeration and hot-plug, MSC+BOT with SCSI, volume export of the card reader and external high-speed sticks, and boot-protocol HID for high-speed keyboards and mice. Verified in QEMU: a stick mounts under /media, is read and written, and unplugging it drops the mount; a keyboard types and a mouse moves the pointer. FS/LS ports are parked via PO. The yank ladder and restart-with-identity-reattach are M2.
- **M2 (daily-driver):** S3 suspend and resume; the yank ladder and identity reattach; devmgr string events for the GUI. The UHCI companions are done, with control, bulk and interrupt transfers, which is what a keyboard or mouse on a root port needs.
- **M3 (camera + leftovers):** UVC (CAMS coordination + quirk policy, probe/commit, iTD iso engine, cam shm API), interrupt-IN splits for HID behind HS hubs, optional 128 KiB MSC transfers, optional ublk phys-scatter extension if M1 numbers demand it.

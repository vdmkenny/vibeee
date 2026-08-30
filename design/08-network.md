# vibeee Design 08, netd: Userspace Network Stack + NIC Drivers

> **Status: design only, not implemented.**
> Implemented code is limited to the M0 set listed in [`../README.md`](../README.md).
> Where this document and [`00-vibeee.md`](00-vibeee.md) disagree, the master design wins:
> it carries later decisions this document predates.

Status: v0 design, implementation-ready. Owner: netd subsystem.
Scope: atl2 ethernet driver, AR2425 (ath5k-class) WiFi driver + softMAC + WPA2-PSK supplicant, minimal TCP/IP stack, POSIX-socket IPC bridge, config/status UX, restartability.

## 1. Overview

netd is ONE userspace process (single-threaded event loop) that owns both NICs and the
entire TCP/IP stack. It is a privileged driver server using the user-driver API
(pci_cfg_*, map_mmio, dma_alloc, irq_attach). Apps never see packets; libc's BSD-socket
shim speaks a channel + shm-ring protocol to netd. Rationale for single process / single
thread: 630 MHz single core means threads buy zero parallelism and cost locks; an event
loop over wait_many() gives deterministic, testable behavior and the netstack core stays
a pure library (packets in / packets out) that compiles and fuzzes on the host.

Internal layering (all in one binary):

```
+------------------------------------------------------------------+
| sockd: socket table, per-socket shm rings, /svc/net registry     |
+------------------------------------------------------------------+
| netstack: TCP | UDP | ICMP | DNS-stub | DHCP | ARP | IPv4 | ethv |
+------------------------------------------------------------------+
| wifi ctl: MLME softMAC + supplicant (scan/auth/assoc/4-way/keys) |
+------------------------------------------------------------------+
| NicDriver iface:  atl2  |  ath5k  |  e1000-test (QEMU only)      |
+------------------------------------------------------------------+
| user-driver API: map_mmio, dma_alloc, irq_attach, pci_cfg_*      |
+------------------------------------------------------------------+
```

No IOMMU exists: netd's DMA programming can overwrite any RAM. netd is therefore a
trusted, supervised system service; its manifest grants it exactly BDFs 03:00.0 and
01:00.0 (+ test NIC in QEMU builds). This trust boundary is documented, not mitigated.

## 2. Hardware facts used (with research confidence)

- Attansic L2 at 03:00.0, 1969:2048 rev a0, PCIe x1, 10/100, integrated PHY (HIGH,
  research-peripherals §5). Reference implementations: Linux atl2.c/atlx.h (register map
  verified against torvalds/linux master for this design), FreeBSD ae(4).
- Atheros AR2425 at 01:00.0, 168c:001c rev 01, PCIe, b/g only, MAC srev 0xe2, PHY/RF
  0x70 (RF2425, single-chip), no firmware blobs, per-board cal in card EEPROM (HIGH,
  research-peripherals §4). Register truth source: Linux ath5k reg.h/desc.h (Atheros-
  sanctioned), OpenBSD ar5k, MadWifi OpenHAL (HIGH that these are adequate).
- Fn+F2 = ACPI WLDS power-gates the mini-PCIe slot: true electrical hot-unplug; state
  persists across reboots; hotplug is ACPI Notify on \_SB.PCI0.P0P5/P0P6/P0P7, no native
  PCIe hotplug interrupts (HIGH, research-quirks §3). Reads from a gated device return
  0xFFFFFFFF (HIGH, eeepc-laptop detects absence exactly this way).
- Early ath5k had AR2425 calibration bugs ("gain calibration timeout", resets in noisy
  environments) (MEDIUM-HIGH, research-quirks §6) → calibration failures must be
  non-fatal, retried, and rate-limited.
- Exact GSIs for wifi/ethernet on the 4G are uncertain (research-core UNCERTAINTIES) →
  netd reads Interrupt Line/Pin from PCI config and asks devmgr for the routed GSI; both
  IRQs treated as shareable level-triggered IOAPIC lines. Neither driver uses MSI (atl2
  MSI is known-flaky in Linux; ath5k legacy INTx).
- MCFG ECAM at 0xE0000000 (HIGH), pci_cfg_* presumably backed by it; netd doesn't care.
- Memory bandwidth possibly DDR2-140 (~1.1 GB/s peak, ~350 MB/s practical memcpy)
  (MEDIUM, conflicting) → budget math below uses the pessimistic number.
- QEMU emulates neither atl2 nor AR2425 → test seams in §10.

## 3. Architecture

### 3.1 Event loop

```zig
// One wait set. No threads. Every external stimulus is an event or channel message.
pub const WaitSource = enum { irq_atl2, irq_ath5k, timer_100ms, svc_channel,
                              sock_doorbell, platform_notify, devmgr_notify };
```

- `timer_100ms`: one kernel timer event drives a 100 ms timer wheel (TCP RTO/persist/
  keepalive, DHCP T1/T2, ARP aging, wifi cal ticks, minstrel window, beacon-miss).
  Sub-100ms precision is not needed anywhere in v1 (min RTO clamped to 200 ms).
- IRQ events: `irq_attach(gsi)` → event; handler runs in netd context after wakeup.
  Because lines may be shared, on wake we read the device ISR; if zero → spurious, done.
  (Kernel contract: level IRQ is masked until the driver acks via irq_ack(); see OPEN.)
- Socket doorbells: one event per socket in the app→netd direction; wait_many capacity
  must cover ~256 sockets + fixed sources (see OPEN if wait_many has a cap).

### 3.2 Buffer strategy: pbuf-lite

One dma_alloc arena at startup: **384 KB = 192 pbufs × 2048 B**, physically contiguous,
<4 GB, mapped once. A pbuf's data area is DMA-visible; metadata lives in a parallel
array so devices can never scribble on pointers.

```zig
pub const PBUF_SIZE = 2048;             // 1536 max frame + headroom + slack
pub const PBUF_HEADROOM = 128;          // room to prepend eth/ip/tcp or 802.11+CCMP hdrs
pub const Pbuf = struct {
    // parallel-array metadata; index i maps to arena[i*2048]
    off: u16,      // data start offset within the 2048 slab
    len: u16,      // payload length
    refcnt: u8,    // >1 while on TCP retransmit queue AND in a NIC TX ring
    pool_next: u16,
    pub inline fn data(self: *Pbuf) []u8 { ... }
    pub inline fn paddr(self: *Pbuf) u32 { ... } // arena_paddr + i*2048 + off
};
```

- RX zero-copy for ath5k: RX descriptors point straight at pbuf data areas; a received
  frame enters the stack with no copy. atl2 cannot do this (its RX buffers live inside
  its own descriptor ring, see §4), so atl2 RX pays one fused copy+checksum.
- TX: stack builds headers in pbuf headroom; app payload is copied once from the socket
  shm ring into the pbuf (this copy is mandatory anyway to decouple app memory from DMA).
- Exhaustion policy: RX refill starves first (drop packets, never deadlock TX/ACKs);
  TCP allocates from a reserved sub-pool of 32 pbufs for ACK/ctrl segments.

### 3.3 NicDriver interface (compile-time registry inside netd)

```zig
pub const LinkState = struct { up: bool, mbps: u16, duplex: enum { half, full } };
pub const NicOps = struct {
    probe:  *const fn (bdf: u16) bool,
    init:   *const fn (dev: *NicDev) anyerror!void,   // full HW init from unknown state
    start:  *const fn (dev: *NicDev) anyerror!void,   // RX/TX enable
    stop:   *const fn (dev: *NicDev) void,            // quiesce DMA, mask IRQs
    detach: *const fn (dev: *NicDev) void,            // surprise-removal safe teardown
    tx:     *const fn (dev: *NicDev, p: *Pbuf) TxResult, // takes ownership on Ok
    irq:    *const fn (dev: *NicDev) void,            // called on IRQ event wake
    set_rx_filter: *const fn (dev: *NicDev, f: RxFilter) void,
    link:   *const fn (dev: *NicDev) LinkState,
    stats:  *const fn (dev: *NicDev) *const NicStats,
};
// Driver delivers RX upward:
pub const NicCallbacks = struct {
    rx: *const fn (dev: *NicDev, p: *Pbuf) void,      // stack takes ownership
    tx_done: *const fn (dev: *NicDev) void,           // may kick queued TX
    link_change: *const fn (dev: *NicDev) void,
    dead: *const fn (dev: *NicDev) void,              // surprise removal detected
};
```

The wifi driver additionally implements `WifiOps` (channel set, scan actions, key cache,
rate table, BSS filter) consumed only by the MLME module, the netstack sees wifi as an
ethernet NicDev carrying ethertype frames after 802.11↔802.3 translation in the driver.

### 3.4 Service lifecycle

netd's manifest declares `needs = platd` and `provides = net`; init releases dependents
on the provided name, so these rules are load-bearing:

- `platd` registers its own name only once the firmware is fully settled, and netd
  orders itself behind that name: its routing question is asked of a service already
  in its serve loop. netd's own name doubles as its instance claim, so it is
  registered first; nothing downstream waits on it before the hardware is up.
- First hardware touch only after the dependencies are up. Probe, claim, map, then
  drive; a dependency that cannot answer is a refusal, not a machine that stops.
- The boot line can hold the service down (`nonet`) or start it late under the boot
  watchdog (`netlate`) for one boot, which is how a suspect is isolated without
  touching the image.

## 4. atl2 ethernet driver (1969:2048)

Register map source: Linux atlx.h/atl2.h (offsets below verified from mainline).

### 4.1 Ring scheme (atl2's unusual design)

atl2 has NO scatter-gather descriptor ring. Three regions in ONE dma_alloc block:

- **TXD ring**: a plain byte FIFO (we pick 8 KB, dword-aligned) into which the CPU
  memcpy's `{ tx_pkt_header (4 B: pkt_size:11, ins_vlan:1, vlan:16) + frame bytes }`,
  dword-padded, wrapping at the end. Hardware consumes at its own read pointer; we tell
  it how far we've written via mailbox `REG_MB_TXD_WR_IDX (0x15F0)` = write ptr **>> 2**
  (dword index).
- **TXS ring**: 160 × 4-byte `tx_pkt_status` entries (ok/underrun/collision bits +
  `update` flag), hardware posts one per completed packet.
- **RXD ring**: N × 1536-byte fixed slots, each = `{ rx_pkt_status (12 B incl. update,
  ok, crc, runt, frag, trunc, vlan, pkt_size:11) + packet[1524] }`. Hardware fills
  slots in order; we consume where `status.update == 1`, clear it, and advance mailbox
  `REG_MB_RXD_RD_IDX (0x15F4)`.

Sizing for 512 MB machine: TXD 8 KB + TXS 640 B + RXD 64×1536 = 96 KB → one 106 KB
coherent block (+alignment pad: TXD 8-byte, RXD 128-byte aligned). All below 4 GB and
contiguous per dma_alloc contract; `REG_DESC_BASE_ADDR_HI = 0`.

### 4.2 Init/reset sequence (register-level)

```
1. pci_cfg: set CMD.IO|MEM|MASTER if clear.
2. REG_MASTER_CTRL(0x1400) = MASTER_CTRL_SOFT_RST(1); wait 1 ms.
3. Poll REG_IDLE_STATUS(0x1410) == 0, 1 ms step, ≤10 tries; else fail.
4. Restore the PCIe block defaults: LTSSM_TEST_MODE(0x12FC)=0x6500 and
   PCIE_DLL_TX_CTRL1(0x1104)=0x568, per `atl2_init_pcie`; then mask the four
   error-reporting enables (URE/FEE/NFEE/CEE) in the PCIe capability's Device
   Control, walking the capability list rather than assuming an offset: the L2
   raises phantom unsupported-request/non-fatal reports against DMA traffic,
   and masking them at the capability keeps every interrupt free of noise.
5. Read permanent MAC: try NVM/VPD read (atl2_get_permanent_address path);
   fallback: current REG_MAC_STA_ADDR(0x1488/0x148C) (BIOS/OpROM-set);
   last resort: locally-administered random MAC + loud warning.
6. PHY init: REG_PHY_ENABLE(0x140C)=1; 1 ms.
   MII dbg: write MII_DBG_ADDR(0x1D)=0, read MII_DBG_DATA(0x1E); if bit 0x1000
   (power-save) set, clear it. Write PHY reg 18 = 0x0C00 (link-change INT enable).
   MII_ADVERTISE = 10/100 HD+FD | ASM_DIR | PAUSE.
   MII_BMCR = RESET | ANENABLE | ANRESTART; poll REG_MDIO_CTRL(0x1414)
   !(MDIO_START|MDIO_BUSY), ≤25×1 ms.
   (MDIO access: REG_MDIO_CTRL = data | reg<<16 | MDIO_SUP_PREAMBLE | MDIO_START
    | MDIO_RW(read) | clk_sel<<24; poll ~MDIO_BUSY.)
7. Configure (exact order, per atl2_configure):
   ISR(0x1600)=0xFFFFFFFF; MAC_STA_ADDR; DESC_BASE_ADDR_HI(0x1540)=0;
   TXD_BASE_ADDR_LO(0x1544); TXS_BASE_ADDR_LO(0x154C); RXD_BASE_ADDR_LO(0x1554);
   TXD_MEM_SIZE(0x1548)=8192/4; TXS_MEM_SIZE(0x1550)=160; RXD_BUF_NUM(0x1558)=64;
   MAC_IPG_IFG(0x1484)=defaults; MAC_HALF_DUPLX_CTRL(0x1498)=defaults;
   IRQ_MODU_TIMER_INIT(0x1408)=100 (~200 µs) + MASTER_CTRL.ITIMER_EN;
   CMBDISDMA_TIMER(0x140E)≈100 ms; MTU(0x149C)=1500+14+4(+4);
   TX_CUT_THRESH(0x1590)=0x177; PAUSE_ON_TH/OFF_TH(0x15A8/0x15AA);
   MB_TXD_WR_IDX=0; MB_RXD_RD_IDX=0; DMAR(0x1580)=1; DMAW(0x15A0)=1;
   ISR=0x3FFFFFFF; ISR=0. Read ISR: PHY_LINKDOWN set → treat as link-down, not error.
8. IMR(0x1604) = ISR_TIMER|ISR_TS_UPDATE|ISR_RS_UPDATE|ISR_LINK_CHG|ISR_PHY
   |error bits (DMAR_TO_RST|DMAW_TO_RST|TXF_UR|RXF_OV).
```

### 4.3 Hot paths

TX (`atl2.tx`): check free TXS ≥1 and free TXD bytes ≥ len+4+4; else return .Busy (stack
queues; tx_done kicks). Write 4-byte header at write ptr, memcpy frame (handles wrap in
two memcpys), dword-align advance, clear next TXS `update`, write MB_TXD_WR_IDX = ptr>>2.
Cost @100 Mbit: 12.5 MB/s memcpy into uncached-coherent ring ≈ 4–6% CPU on this memory.

IRQ: read ISR; if 0 → spurious return. Write ISR = status | ISR_DIS_INT (ack+hold);
on DMAR_TO_RST/DMAW_TO_RST → full reinit (§4.2); on PHY/LINK_CHG → clear PHY int (read
PHY reg 19), re-read BMSR twice, on link-up read PHY reg 17 (PSSR) for resolved
speed/duplex, then REG_MAC_CTRL(0x1480) = TX_EN|RX_EN|MACLP_CLK_PHY|ADD_CRC|PAD|BC_EN
|flow-ctl bits |DUPLX(if FD)|speed-mode; on link-down clear RX_EN, flush stack routes.
TS_UPDATE → reap TXS entries (update==1): account, advance txd_read_ptr by
(pkt_size+7)&~3, wrap; wake queued TX. RS_UPDATE → consume RXD slots with update==1:
if ok && 60 ≤ size: fused memcpy+IP-checksum into a fresh pbuf → `cb.rx`; clear update.
Then MB_RXD_RD_IDX = read ptr. Finally write ISR = 0 (re-enable).

The ISR narrates only what ordinary traffic does not explain: RX/TX status updates and
the PHY poll are traffic, and stay quiet; anything else — errors, overruns, link events
— is worth a line.

Interrupt moderation: ITIMER at 200 µs caps IRQ rate at ~5 k/s regardless of pps; with
64 RX slots (96 KB ≈ 7.7 ms of line-rate buffering) this is safe against overrun.

Multicast: v1 programs REG_RX_HASH_TABLE(0x1490,0x1494)=0 and relies on broadcast +
unicast (DHCP/ARP/DNS all work). `set_rx_filter` implements the standard CRC32-high-6-
bits hash when IGMP/mDNS arrives (M3). Promiscuous available for debugging
(MAC_CTRL_PROMIS_EN).

### 4.4 100 Mbit budget math @630 MHz

Full-duplex worst case, 1518 B frames, 8.1 kpps each way:
- RX: ring→pbuf fused copy+cksum 12.5 MB/s ≈ 5%; pbuf→socket-ring copy ≈ 5%;
  TCP/IP per-packet ~1.5 µs ≈ 1.2%; IRQ+reap amortized ≈ 1.5%.
- TX mirror image ≈ 11%. ACK traffic ≈ 3%.
- Total ≈ **28–33% CPU at full duplex saturation**; ~17% for one-direction bulk.
  Leaves headroom for GUI + disk. Memory bandwidth: ~50 MB/s of the ~350 MB/s
  practical, acceptable.

## 5. AR2425 WiFi driver (ath5k-class), honest design

This is the hardest component. Truth sources: ath5k (reg.h, desc.h, reset.c, phy.c,
initvals.c, eeprom.c), OpenBSD ar5k. Exact bitfield encodings below marked (reg.h) are
to be lifted verbatim from ath5k headers at implementation time, this design fixes the
sequences and structures, not every literal.

### 5.1 Probe & identification

```
1. devmgr match 168c:001c → attach. pci_cfg: CMD.MEM|MASTER; map BAR0 (64 KB MMIO).
2. Wake: SLEEP_CTL(0x4004) = SLE_WAKE; poll PCICFG(0x4010).SPWR_DN clear (≤200×50 µs).
3. SREV(0x4020) → expect MAC srev 0xE2 (AR2425 "Swan"); accept 0xE6 (AR2417) too.
4. Warm reset: RESET_CTL(0x4000) = PCU|MAC|DMA|PHY: NEVER set RESET_CTL_PCI on this
   card: warm-resetting the PCI core on PCIe hangs it (ath5k comment, verified).
   Wait, re-wake.
5. PHY_CHIP_ID(0x9818) → expect 0x70; radio = RF2425, single-chip. Anything else →
   refuse politely (log + dead state), do not guess.
```

### 5.2 EEPROM

Card EEPROM via EEPROM_BASE block (0x6000 addr, 0x6004 data, 0x6008 cmd=READ, 0x600C
status poll RD_DONE, per-word). Read: version/misc words (incl. misc5 AES_DIS bit),
MAC address, regdomain, capabilities, and the full 2.4 GHz calibration set (per-channel
power curves, pier data, noise-floor thresholds, antenna gains) using the ath5k v3/v4/v5
EEPROM parser logic for the version found. Cache parsed cal in RAM (~4 KB). EEPROM
checksum failure → hard-fail attach (cal garbage would make the radio useless/illegal).

### 5.3 Reset/channel-set pipeline (ath5k_hw_reset ordering, adopted)

```
reset(channel, mode=11g):
 1. save LED/GPIO state; 2. nic_wakeup (§5.1 steps 2–4 + PLL:
    PHY_PLL(0x987C) = 44 MHz value for 2 GHz | mode bits; 300 µs settle);
 3. PHY access enable: write PHY(0) shift reg;
 4. write mode initvals (ar5212 + RF2425 tables from initvals.c, ~700 register writes,
    embedded in .rodata ≈ 12 KB);
 5. core clock/timing regs for 11b/g; 6. tweak initvals (ADC, DCU buffering);
 7. commit EEPROM settings (per-channel TX power tables, antenna, NF thresholds);
 8. PCU init: STA_ID0/1(0x8000/4)=MAC, BSSID regs, RX filter, beacon timers off;
 9. RF bank programming for target channel (RF2425 banks from rfbuffer.h; channel →
    synth programming via ath5k_hw_channel), then PHY activation: PHY_ACT(0x981C)=ENABLE;
10. AGC + noise-floor calibration: PHY_AGCCTL(0x9860) |= CAL|NF; poll completion.
    ** AR2425 REALITY: early ath5k saw gain-cal timeouts and NF-cal failures on this
    exact chip. Policy: cal timeout = WARNING, keep last-good NF, retry at next 10 s
    periodic cal tick; 3 consecutive failures → full reset(channel). Never busy-loop
    >20 ms total in cal polls. **
11. IMR: RXOK|RXEOL|RXORN|TXOK|TXERR|TXURN|MIB|BMISS|FATAL (PIMR 0x00A0, IER 0x0024=1).
```

Periodic (10 s timer): I/Q cal + NF cal on current channel (short cal, non-blocking
poll across ticks). Full gain_F recalibration only on channel change.

### 5.4 DMA rings

5212-style descriptors in one dma_alloc block (uncached): 64 TX + 40 RX descriptors
× 32 B ≈ 3.3 KB. RX buffers = pbufs (zero-copy into stack).

```zig
pub const Ath5kDesc = extern struct { // AR5212 layout (desc.h)
    ds_link: u32,  // paddr of next desc; RX last desc self-links (never runs dry;
                   // must handle the resulting possible stale-final-frame, as ath5k does)
    ds_data: u32,  // paddr of buffer (pbuf data)
    ctl0: u32, ctl1: u32,          // TX: frame len, hdr len, rate series 0, flags
    u: extern union {
        tx: extern struct { ctl2: u32, ctl3: u32,  // multi-rate-retry series 1..3 + tries
                            status0: u32, status1: u32 },
        rx: extern struct { status0: u32, status1: u32 }, // len, rate, RSSI, ts, done,
    },                                                    // crc/phy/decrypt-err bits
};
```

TX: single data queue (QCU 0) in v1; mgmt frames share it with rate forced to 1 Mb.
Enqueue: fill desc (frame type, len, rate series from minstrel, RTS if len>RTS_THRESH,
key-cache index if encrypted), link into chain, TXDP(0x0800)=head if idle, then
QCU_TXE(0x0840)=1<<0. TXOK/TXERR IRQ reaps status: success/retry-count feed minstrel.
RX: RXDP(0x000C)=ring head; CR(0x0008)=RXE. On RXOK: walk done descriptors, replace
pbuf, translate 802.11 → 802.3 header (strip QoS/addr3 handling, LLC/SNAP), drop dups
(seq cache), pass EAPOL (0x888E) to supplicant, rest to `cb.rx`.

### 5.5 softMAC / MLME state machine

Hardware does: ACK generation, per-descriptor retries (MRR), CRC, CCMP/TKIP/WEP crypto
via key cache, dup detection assist. Software does everything else:

```
IDLE → SCAN → AUTH → ASSOC → (open? RUN : EAPOL) → RUN
                                    ↑ 4-way handshake
RUN --beacon-miss/deauth--> AUTH (fast rejoin, 2 attempts) → SCAN
any --kill-switch--> DEAD;  DEAD --replug--> IDLE (auto-rejoin last)
```

- Scan: for each channel 1..13 (ETSI default; intersect with EEPROM regdomain):
  reset-light channel switch, passive listen 60 ms collecting beacons; active scan
  additionally sends probe-req and waits 30 ms. Full scan ≈ 1.2 s. Results table:
  32 × {bssid, ssid[32], chan, rssi_ewma, caps, rsn_parsed}.
- Auth: open-system (algorithm 0) 2-frame exchange, 100 ms timeout, 3 tries.
- Assoc: assoc-req with rates + RSN IE (WPA2-PSK CCMP only in v1, no WPA1/TKIP; TKIP
  is a config-error message, stated limitation); parse AID.
- Beacon tracking: on beacon RX from our BSS, stamp last_beacon. Software beacon-miss:
  no beacon for 8 × beacon-interval (checked on 100 ms tick) → count BMISS IRQ as
  corroboration → fast-rejoin then rescan. (HW BMISS used only as a hint; software
  timer is authoritative, simpler than programming sleep/beacon timers.)
- Power save: OFF in v1 (STA_ID1 PWR_SV clear, sleep clock untouched). Stated.

### 5.6 WPA2-PSK supplicant + CCMP

- PSK → PMK: PBKDF2-HMAC-SHA1(passphrase, ssid, 4096, 32). ≈30 k SHA1 compressions →
  ~150–300 ms at 630 MHz, done once per config change; **PMK cached in /cfg** so joins
  skip it.
- 4-way handshake in netd: EAPOL-Key frames over the data path; PRF-SHA1 → PTK
  (KCK/KEK/TK); validate MIC; unwrap GTK (AES key-unwrap); msg 4; install keys.
- Key install, hardware CCMP: AR2425 qualifies (srev 0xE2 ≥ AR5212_V4) unless EEPROM
  misc5 AES_DIS is set (checked at attach; sets `hw_ccmp` capability). Key cache at
  0x8800: 128 entries × 8 words {key[5 words interleaved 32/16/32/16/32], keytype
  (TYPE_CCM per reg.h), mac0, mac1}. PTK → entry matching peer MAC (index from MAC
  hash per 5212 rules); GTK → entry = key-idx (1..3), group flag. TX descriptors carry
  the key index; RX status flags decrypt-ok/err.
- Software CCMP fallback (if AES_DIS or key-cache misbehavior on this early silicon):
  table-based AES-128 (no AES-NI on Dothan): ~60 cycles/byte for CCM's two passes →
  at real-world 20 Mbit (2.5 MB/s) ≈ 24% CPU. Usable, ugly, shipped as fallback with a
  status-bar indicator. Decision: implement SW CCMP anyway, it is also the unit-test
  oracle for the HW path (RFC 3610 / IEEE test vectors).

### 5.7 Rate control: minstrel-lite (specified)

Rates: {1,2,5.5,11} CCK + {6,9,12,18,24,36,48,54} OFDM. Per rate keep
`ewma_prob` (α=0.25, updated from TX status success/retries) and
`tput = rate × ewma_prob / airtime`. Every 100 ms pick: best_tput, second_tput,
best_prob, lowest(1 Mb). MRR series = [best, second, best_prob, 1 Mb] with tries
[2,2,2,3]. 10% of frames sample a random non-best rate in series slot 0. No per-packet
malloc; 12×16 B table. This is ~150 lines and captures most of minstrel's benefit.

### 5.8 Kill-switch: surprise removal & replug

- Sources: platformd forwards ACPI ATKD events 0x10/0x11 and P0P5/6/7 Notifies; devmgr
  rescans bus 1 (vendor-ID probe) and sends attach/detach to netd.
- Detection without notification (belt & braces): every IRQ entry and every poll loop
  reads a known register; 0xFFFFFFFF → `dead` path. All register poll loops are bounded
  (≤ N iterations with budgeted delays), never wait on a gated device.
- `dead` path: mark NicDev DEAD (all ops become no-ops), abandon in-flight descriptors
  (device is powered off, it cannot DMA; memory is simply reclaimed), free pbufs,
  fail wifi state machine → sockets bound to wifi addresses get ECONNRESET/ENETDOWN,
  status event {link: down, reason: killswitch}.
- Replug: devmgr attach → full probe→init→reset pipeline from power-on state (nothing
  is assumed retained) → auto-rejoin last network from /cfg.
- If the user toggles Fn+F2 OFF then reboots into another OS: not our problem; our own
  boot always attempts WLDS(1) via platformd if wifi is configured on (documented,
  because this bit persists and confuses other OSes).

## 6. TCP/IP stack

- **ARP**: 64-entry cache, 60 s reachable / 5 s probe; queue ≤3 packets per unresolved
  entry. **IPv4**: single address per NIC, /cfg static or DHCP; no forwarding, no
  fragmentation reassembly beyond 4 fragments/8 KB (DF set on TCP; PMTU via ICMP
  frag-needed). **ICMP**: echo reply, echo request (ping tool), errors consumed by TCP.
- **No IPv6 in v1** (stated; addr structures sized to allow later addition).
- **DHCP client**: DISCOVER/OFFER/REQUEST/ACK, options 1,3,6,15,51,54; T1/T2 renew;
  per-NIC lease state in RAM, last-good lease hint in /cfg for fast re-acquire.
- **DNS stub**: A queries only, 2 configured servers (DHCP opt 6 or /cfg), 32-entry
  positive cache honoring TTL (cap 1 h), 5 s timeout ×2 retries. Exposed as a `resolve`
  op, not port 53 proxying.
- **UDP**: trivial; per-socket record ring.
- **TCP**: **NewReno + fast retransmit/recovery. Window scaling (wscale=2, 128 KB max
  advertised, default rcvbuf 32 KB) and RFC 7323 timestamps (RTT sampling + PAWS) are
  IN. SACK is DEFERRED to M3**: justification: LAN BDP ≈ 12 KB needs nothing; WAN over
  100 ms × 20 Mbit ≈ 250 KB BDP is beyond our per-socket buffer budget anyway, so SACK's
  benefit (loss recovery on big windows) is mostly unreachable; NewReno + timestamps is
  ~1/3 the state-machine surface. We DO parse and ignore SACK-permitted (and advertise
  nothing) so adding it later is a local change. Delayed ACK 40 ms/2-MSS; Nagle on by
  default (TCP_NODELAY supported); RTO per RFC 6298, min 200 ms; keepalive opt-in.
  MSS 1460; no ECN v1.
- Checksums in software, always fused into the mandatory copy (copy-and-checksum loop,
  SSE2 unrolled): the data is touched exactly once for both purposes.
- Socket table: 256 global, 64 per process. TCB ≈ 256 B + rings.

## 7. Socket IPC bridge (the libc contract)

### 7.1 Objects

Per process: one **control channel** to /svc/net (call/reply ≤64 B + ≤4 handles).
Per socket: one **shm object** (default 40 KB TCP: 4 KB ctrl+slack, 16 KB tx ring,
16 KB rx ring; 20 KB UDP) + two events: `ev_app` (netd→app: data/space/state) and
`ev_netd` (app→netd doorbell). netd allocates all three and returns handles in the
reply (3 handles ≤ 4 limit). **Decision: per-socket rings, not per-process**: SPSC
matches the kernel ring contract, isolates flow control per connection, and 40 KB ×
tens of sockets fits RAM; a shared per-process ring would need MPSC muxing and
head-of-line blocking handling for zero measured benefit at this scale.

```zig
pub const SockCtrl = extern struct { // first 64 B of socket shm
    tx_head: u32, tx_tail: u32,   // app produces at head; netd consumes at tail
    rx_head: u32, rx_tail: u32,   // netd produces; app consumes
    state: u32,       // ESTABLISHED/FIN_WAIT/CLOSED/... mirrored for cheap poll
    so_error: i32,    // ECONNRESET etc.
    flags: u32,       // NETD_WRITABLE, NETD_READABLE, OOB pending (unused v1)
    rcv_wnd_hint: u32 // netd updates; app ignores
};
```

TCP rings are byte streams. UDP rx/tx rings carry records:
`{len:u16, family:u16, addr:u32, port:u16, _pad:u16, data[len], pad to 8}`.

### 7.2 Control ops (channel message, packed, op:u8 first)

```
sock_create{domain,type,proto} -> {sock_id} + handles{shm, ev_app, ev_netd}
bind{sock_id, addr, port}                     -> errno
connect{sock_id, addr, port}                  -> errno (async: EINPROGRESS; completion
                                                  via ev_app + SockCtrl.state)
listen{sock_id, backlog}                      -> errno
accept{sock_id}            -> {new_sock_id, peer} + handles{shm, ev_app, ev_netd}
                              (EAGAIN if none pending; readiness via listener's ev_app)
close{sock_id} / shutdown{sock_id, how}       -> errno (graceful FIN; linger ≤ 5 s)
set_opt/get_opt{sock_id, opt, val}            -> errno   (NODELAY, KEEPALIVE, RCVBUF≤64K)
getsockname/getpeername{sock_id}              -> {addr, port}
resolve{name[≤48]}                            -> {n, addr[4]}  (DNS stub)
```

Blocking recv in libc: loop { consume rx ring; empty → wait(ev_app) }. Blocking send:
loop { produce into tx ring; full → wait(ev_app) }; after producing, signal ev_netd
(netd batches: doorbell coalescing, it drains all ready rings per wakeup).
poll()/select(): wait_many over the ev_app handles of member sockets + timeout; after
wake, readiness is read lock-free from each SockCtrl (state/flags/ring counters).
**One event per socket, not a completion ring**, decision: completion rings shine with
thousands of sockets; at ≤64/process, wait_many over events reuses the kernel primitive
with zero new protocol.

Bulk TCP path cost: app→ring copy (app side), ring→pbuf copy+cksum (netd), DMA. Two
copies + DMA total, the practical minimum without page-flipping games that this MMU
budget doesn't want.

### 7.3 Death semantics (documented contract)

netd crash → kernel invalidates its channels/handles → app's wait returns
HANDLE_DEAD → libc marks all sockets ECONNRESET (SIGPIPE-less; error on next op),
reconnects lazily to /svc/net (supervisor restarts netd, which re-registers). No
transparent socket resurrection: TCP state is gone; apps see what a router reboot
looks like. DNS cache, DHCP leases re-form automatically.

## 8. Config, UX, status

- `/cfg/net/ifcfg`, text: per-NIC `dhcp` | `static addr/mask gw dns`.
- `/cfg/net/wifi.conf`, list of known networks: `{ssid, sec: open|wpa2, pmk(hex),
  passphrase?, priority, autojoin}`. **Decision: NOT encrypted at rest in v1.** Honest
  reasoning: single-user machine, no TPM/keystore, any key would live in the same flash
  next to the data → encryption here is theater. Mitigations that are real: store
  derived PMK instead of the passphrase where the user permits (passphrase kept only if
  they want it visible), file readable only by netd+cfgtool (VFS perms), and the fact
  that /cfg is on the user's own SD. Revisit if a user-passphrase-derived /cfg vault
  ever exists (OPEN for the storage subsystem).
- Wifi picker API (GUI): `wifi_scan` (starts async scan; completion via status event),
  `wifi_scan_get{idx} -> {bssid,ssid,chan,rssi,sec}` (one 64 B reply per BSS, ≤32),
  `wifi_join{ssid, cred}`, `wifi_forget{ssid}`, `wifi_status -> {state,ssid,rssi,ip}`.
- Status events: subscriber calls `status_subscribe` passing an event handle + a small
  shm (4 KB, 64-record ring of `{t_us, kind: link|ip|rssi|scan_done|killswitch,
  a:u32, b:u32}`); netd is producer. Status bar shows link/SSID/RSSI/IP from this; RSSI
  event rate-limited to 1/2 s.

## 9. RAM / disk budget

| Item | Size |
|---|---|
| netd binary (rootfs, ReleaseSmall) | ≤ 900 KB target / 1.5 MB cap (ath5k code+initvals ≈ 250 KB, atl2 ≈ 30 KB, stack ≈ 150 KB, supplicant+crypto ≈ 80 KB, sockd ≈ 60 KB, rt+tables rest) |
| pbuf arena (dma) | 384 KB |
| atl2 rings (dma) | 106 KB |
| ath5k descriptors (dma) | 4 KB (buffers come from pbuf arena) |
| socket shm (64 sockets worst) | 2.5 MB cap (typical: 10 sockets ≈ 400 KB) |
| tables (ARP/DNS/scan/TCB/minstrel) | < 96 KB |
| **Idle RAM share** | **≈ 1.6 MB** (fits inside the 48 MB system idle budget) |
| Busy RAM share | ≤ 4 MB (enforced by socket cap) |

## 10. Bring-up & test plan

QEMU emulates neither atl2 nor AR2425 → three seams:

1. **Host-native stack tests**: netstack + supplicant + minstrel are pure Zig libraries
   (no syscalls; time and NIC injected). Unit/fuzz on the dev machine: TCP state
   machine against packetdrill-style scripts, handshake against captured
   hostapd/wpa_supplicant EAPOL pcaps, CCMP against RFC 3610 vectors, DHCP/DNS against
   pcap fixtures. This is where correctness lives.
2. **QEMU integration**: `e1000` test driver (~700 lines) behind NicOps, compiled only
   with `-Dtest-nic`; boots full vibeee in QEMU, runs DHCP against QEMU's slirp,
   iperf-lite against host. Proves the event loop, IPC bridge, IRQ path, dma_alloc
   usage, everything except the two real drivers.
3. **Hardware checklist** (in order): atl2 probe/MAC read → link IRQ → ping →
   DHCP → 24 h iperf soak (watch DMAR_TO_RST resets) || ath5k: probe/srev/EEPROM dump
   tool first (read-only milestone), → channel set + passive scan sees beacons → open
   auth/assoc → DHCP over wifi → WPA2 join → kill-switch torture: 100 × Fn+F2 toggle
   during iperf, zero crashes/leaks (pbuf census after each cycle) → cal-failure
   injection (force AGCCTL timeout path).
   Debug transport with no serial port: netlog ring is drained to on-screen console
   overlay AND, once ethernet is up, via UDP syslog, atl2 therefore comes up first.

## 11. Risks & open questions

- **ath5k cal on AR2425** (known-bad early silicon/driver combo): mitigated by
  non-fatal cal policy + periodic retry; residual risk of poor sensitivity → M3 tuning
  against ath5k fix history (commits fixing AR2425 NF/gain).
- **Key-cache CCMP on this exact card**: capability check + SW fallback removes the
  cliff; risk becomes performance, not function.
- **atl2 MAC address source**: NVM read path is thinly documented; fallback chain
  (BIOS-set register, random LAA) bounds the damage.
- **Shared level IRQ semantics**: need kernel contract for mask/ack ordering on shared
  GSIs (both NICs may share lines with USB): OPEN with kernel-core.
- **wait_many fan-out**: 64+ handles per waiter must be supported or netd needs an
  internal event-mux: OPEN with kernel-core.
- **DMA with no IOMMU**: netd bugs can corrupt any RAM. Accepted per architecture;
  descriptor writes are asserted-bounded in debug builds.
- **Regdomain**: EEPROM regdomain trusted if it maps to a known set; else ETSI 1–13.
  TX power caps from EEPROM cal always enforced.

## 12. Phasing

- **M1**: pbuf core, netstack (ARP/IPv4/ICMP/UDP/TCP-NewReno/DHCP/DNS), sockd IPC +
  libc shim, atl2 driver, e1000 test driver, status events, host-native test rigs,
  UDP syslog. Exit: DHCP+ping+TCP bulk on real ethernet; QEMU CI green.
- **M2**: ath5k bring-up (probe→EEPROM→scan→open join), then WPA2-PSK (supplicant, HW
  CCMP + SW fallback), kill-switch handling, /cfg persistence + auto-rejoin, wifi
  picker + status APIs. Exit: WPA2 join survives 100 kill-switch cycles.
- **M3**: minstrel-lite tuning on air, SACK, background scan while associated,
  multicast filter/mDNS-lite, PMTU polish, cal-quality tuning, CPU profiling to hold
  the §4.4 budget.

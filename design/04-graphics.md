# vibeee Graphics Driver — GMA 900 / 910GML (design/04-graphics.md)

> **Status: design only — not implemented.**
> Implemented code is limited to the M0 set listed in [`../README.md`](../README.md).
> Where this document and [`00-vibeee.md`](00-vibeee.md) disagree, the master design wins:
> it carries later decisions this document predates.

Status: implementation-ready design. Register offsets/bits verified against Linux v3.4
`drivers/gpu/drm/i915/i915_reg.h` and `drivers/char/agp/{intel-gtt.c,intel-agp.h}` (gen3 paths)
unless marked otherwise.

## 1. Overview

In-kernel display driver stack with one narrow contract (`DisplayDev`) and three backends:

- **gma900** — the real driver: native LVDS modeset of the 800×480 panel on pipe B, framebuffers
  in stolen memory, WC via MTRR, vblank IRQ, optional VGA-out on pipe A, HW cursor, S3
  save/restore, optional gen3 blitter module (M3).
- **bochsfb** — QEMU test backend (Bochs dispi ports): 800×480×32 **with real flipping** so the GUI
  server's full code path (including flip) runs in QEMU, where GMA 900 cannot be emulated.
- **vesafb** — safety-mode backend: 640×480×32 VBE mode set by the bootloader in real mode;
  no flip, no S3 resume.

The GUI server is the single owner of `/dev/fb0`. Kernel console (kcon) renders text on the same
surface until the GUI claims it, and owns the panic path forever.

## 2. Hardware facts used (with research confidence)

| Fact | Value | Confidence |
|---|---|---|
| IGD | 00:02.0, 8086:2592, rev 04; 00:02.1 (8086:2792) is a stub function, ignored | HIGH |
| Aperture | 256 MB @ 0xd0000000 (GMADR) | HIGH (verbatim dmesg) |
| Stolen memory | 7932 KB at top of DRAM | HIGH |
| Panel | 7" 800×480 single-channel LVDS, 18-bit (6bpc) + dithering, likely no EDID | MEDIUM-HIGH |
| Known-good modeline | 29.58 MHz: 800 816 896 992 / 480 481 484 497 -HSync +VSync | HIGH |
| VBE has no 800×480 | 640×480 modes 0x101/0x111/0x112 only | HIGH |
| LVDS on pipe B (gen3 mobile convention) | driver-enforced | MEDIUM |
| Gen3 LVDS PLL limits | refclk 96 MHz, VCO 1.4–2.8 GHz, n 1–6, m 70–120, m1 8–18, m2 3–11, p1 1–8, p2 14/7 | HIGH (i915 `intel_limits_i9xx_lvds`) |
| No PAT (hidden on Pentium M), MTRR present, 8 variable MTRRs | cpuinfo flags | HIGH |
| DDR2 bandwidth weak; possibly DDR2-140 at stock | | MEDIUM (unresolved conflict) |
| Backlight control = ACPI PBLG/PBLS 0–15 via ASUS010; physical PWM source unknown | | HIGH / LOW |
| S3 under VESA needs VBE_POST+VBE_MODE (s2ram whitelist) → native driver must self-restore | | HIGH |
| Fn+F5 = ATKD notify 0x30–0x32 (KEY_SWITCHVIDEOMODE) | | HIGH |
| No serial port → on-screen/persistent-RAM debugging only | | HIGH |

Correction to the task brief: **BLC_PWM_CTL2 (0x61250) is 965+ only** (`i915_reg.h` comment).
Gen3 has a single `BLC_PWM_CTL` at 0x61254.

## 3. Architecture

```
             GUI server (single owner)          kcon (kernel text console)
                 | /dev/fb0 ioctls + WC mmap        | direct calls
                 v                                  v
  +--------------------------------------------------------------+
  |  display core: /dev/fb0, ownership, vblank event, ioctls     |
  |  DisplayDev vtable registry (compile-time Zig array)         |
  +-------------------+-------------------+----------------------+
  |   gma900          |   bochsfb (QEMU)  |   vesafb (safety)    |
  |  MMIO/GTT/DPLL/   |  dispi 0x1CE/0x1CF|  VBE LFB from        |
  |  LVDS/ADPA/IRQ    |  Y_OFFSET flip    |  bootloader          |
  +-------------------+-------------------+----------------------+
```

Probe order: `gma900` (PCI 8086:2592 present and `display=` not overriding) → `bochsfb`
(PCI 1234:1111) → `vesafb` (BootInfo carries a VBE mode). Kernel cmdline `display=vesa`
forces safety mode (also reachable via boot-menu hold-key handled by the bootloader).

Rendering model (the recommendation of §6): GUI composites into a **WB shadow buffer in system
RAM**, then streams damage rects into the **front buffer in stolen memory** through the WC
aperture with SSE2 non-temporal stores, starting each burst on the vblank event. Flip
(two stolen surfaces + DSPBADDR arm) is supported and reserved for full-screen clients.

## 4. PCI discovery, BARs, stolen memory, GTT

### 4.1 Discovery
- Match VID:DID 8086:2592 at 00:02.0 via ECAM (0xE0000000) or CF8/CFC. Ignore 00:02.1.
- Set PCI COMMAND |= MEM_ENABLE|BUS_MASTER.
- BAR map on gen3 (verified, `intel-agp.h`): **BAR0 (cfg 0x10) = MMADR** MMIO, 512 KB;
  **BAR2 (cfg 0x18) = GMADR** aperture, 256 MB (expect 0xd0000000); **BAR3 (cfg 0x1C) =
  GTTADR**, 256 KB (65536 PTEs × 4 B = full 256 MB aperture). BAR1 is a legacy I/O window; unused.
- **BSM** (Base of Stolen Memory): config dword **0x5C of device 00:02.0** → physical base of the
  7932 KB stolen region (top of DRAM minus stolen/ACPI; read, never compute).
- **GGC/GMCH_CTRL** (config 0x52 of device 00:00.0): verify GMS field = 8 MB class
  (`I855_GMCH_GMS_STOLEN_8M`, 0x3<<4); warn if different and trust BSM+E820.
- IGD IRQ: INTA# via ACPI `_PRT`; expect GSI 16 level-low. No MSI on gen3. `irq_attach(16)`.

### 4.2 Stolen memory as framebuffer storage — decision
**Use stolen for all scanout surfaces.** Justification:
- It is already reserved (absent from E820-usable): costs 0 bytes of our 48 MB idle-RAM budget;
  GTT-mapped main-memory pages would burn 3–5 MB of the 512 MB and add allocator complexity.
- Bandwidth is identical: stolen *is* DDR2 DRAM behind the same GMCH arbiter; there is no
  performance argument for main-memory pages on this machine.
- Contiguity is guaranteed; the 915GM **cursor requires a physical address**
  (i915 `cursor_needs_physical`), which stolen trivially provides.
GTT-mapped main memory remains the mechanism for *future* non-scanout use (none planned ≤ M3).

Stolen layout (7932 KB = 0x7BF000):

| offset | size | use |
|---|---|---|
| 0x000000 | 0x180000 | FB0 front, 800×480 XRGB8888, stride 3200 |
| 0x180000 | 0x180000 | FB1 back (flip clients) |
| 0x300000 | 0x1E0000 | FB2 VGA/clone 800×600 surface (M2, allocated lazily) |
| 0x4E0000 | 0x4000 | HW cursor, 64×64 ARGB (physical addr = BSM+0x4E0000) |
| 0x4E4000 | 0x4000 | blitter ring (M3) |
| 0x4E8000 | 0x1000 | GTT scratch page target |
| rest | ~2.9 MB | free |

### 4.3 GTT programming
Gen3 PTE format (verified `intel-gtt.c i810/i9xx_write_entry`): `pte = phys_page | 1`
(bit0 = valid; no cache bits used — unsnooped). Entry *i* maps aperture offset `i*4096`.
- Do **not** relocate the GTT. Read `PGETBL_CTL` (MMIO 0x2020), assert bit0=1 (BIOS enabled it).
- Write PTEs **only through the GTTADR BAR** (BAR3) — that path maintains GTT TLB coherency.
- Sequence: for i in 0..1982: `gtt[i] = (bsm + i*4096) | 1`; for i in 1983..65535:
  `gtt[i] = (bsm + 0x4E8000) | 1` (scratch — makes speculative WC reads of unbacked aperture
  harmless); posting `readl` of `gtt[65535]`.
- Full rewrite takes <2 ms; it is deterministic, so S3 resume regenerates instead of saving.

## 5. Write-combining without PAT — MTRR plan

PAT is hidden on this CPU (HIGH); MTRR is the only WC mechanism. MAXPHYADDR = 32.
0xd0000000 is 256 MB-aligned → **one variable MTRR covers the whole aperture**.

Sequence (Intel SDM 12.11.7.2):
1. `cli`; save CR4; clear CR4.PGE (flush TLB); set CR0.CD=1 (CR0.NW=0); `wbinvd`.
2. `IA32_MTRR_DEF_TYPE` (0x2FF): clear E (bit 11).
3. Scan pairs 0x200+2n, n<VCNT (read `IA32_MTRRCAP` 0xFE; expect VCNT=8): free ⇔ PHYSMASK.V(bit 11)=0.
   Log the BIOS map on first boot (expected: ≤3 pairs for 0–512 MB WB).
4. Free pair k: `PHYSBASEk = 0xD0000001` (base | type WC=1); `PHYSMASKk = 0xF0000800`
   (~(256M−1) over bits 31:12 | V).
5. `wbinvd`; set DEF_TYPE.E; CR0.CD=0; restore CR4; flush TLB; `sti`.

Aperture PTEs (kernel and GUI-server mappings) use PCD=0/PWT=0 so the MTRR type (WC) is effective.
CPU never touches stolen through its direct (WB) physical range — all access via aperture — so no
cache-coherency hazard with the unsnooped display fetch.

**Fallback if all 8 pairs are in use** (not expected; treated as a logged degraded mode):
run the aperture UC (no MTRR). Damage copies switch to 16-byte `movaps` bursts; full frame worst
case ~30–60 ms. GUI stays functional; budget non-compliant; a boot warning is shown. There is no
smaller-region trick that saves a slot (any WC still needs one pair), and overlapping an existing
WB pair is architecturally UC — never done.

## 6. Framebuffer strategy: flip vs damage copies — decision

Numbers: one frame = 1.536 MB. Scanout alone eats 92 MB/s of a realistic ~400–700 MB/s achievable
DDR2 bandwidth (possibly less if the DDR2-140 reading is real). WC **reads** by the CPU are
uncached (~5–20 MB/s) — the front buffer is effectively write-only for the CPU.

- Pure double-buffer flip forces full-frame redraw/copy every update (compositor would need to
  reconstruct the whole back buffer or read the front — impossible cheaply over WC).
- Damage copies from a WB shadow cost `2×rect bytes` of bandwidth (read shadow + write WC) and are
  tiny for tiling-WM workloads (cursor, one window's text line, a bar clock).
- Full-damage frame: compose in cache-friendly shadow, then one 1.5 MB NT-store sweep ≈ 2.2–3.8 ms
  at 400–700 MB/s — inside the 8 ms budget. Started at vblank, the top-down copy outruns the
  beam (16.7 ms/frame) → no visible tear.

**Recommendation: single front buffer + GUI-side WB shadow + damage rects, copies scheduled on the
vblank event (default path). Flip retained** (FB0/FB1 + DSPBADDR arm) for full-screen surfaces
(video, games) where full-frame redraw is inherent. Both are in the ioctl API from M1; the GUI
server uses damage mode.

Vblank: `PIPEBSTAT` (0x71024) bit 17 = vblank interrupt enable, bit 1 = status (W1C);
IIR bit 4 = `I915_DISPLAY_PIPE_B_EVENT_INTERRUPT` (pipe A: bit 6). IER/IIR/IMR/HWSTAM at
0x20A0/0x20A4/0x20A8/0x2098. DSPBADDR is double-buffered in hardware and latches at vblank —
that is the flip mechanism (write + wait for next vblank IRQ = flip done).

## 7. Data structures & interfaces (Zig)

```zig
pub const Rect = extern struct { x: i16, y: i16, w: u16, h: u16 };
pub const PixFmt = enum(u8) { xrgb8888 };
pub const Mode = extern struct {
    pixclk_khz: u32,
    hact: u16, hss: u16, hse: u16, htot: u16,
    vact: u16, vss: u16, vse: u16, vtot: u16,
    flags: u8, // bit0 NHSYNC, bit1 NVSYNC
};
pub const SurfaceDesc = extern struct {
    ap_off: u32, stride: u32, width: u16, height: u16, fmt: PixFmt, // ap_off == GTT offset
};
pub const Caps = packed struct(u32) {
    flip: bool, vblank_irq: bool, hw_cursor: bool, vga_out: bool,
    can_resume: bool, blit: bool, _pad: u26 = 0,
};
pub const OutputCfg = enum(u8) { lvds_only, vga_only, clone_letterbox, blank };
pub const VgaStatus = enum(u8) { absent, present, unknown };
pub const PanicFb = struct { base: [*]volatile u32, stride_px: u32, w: u16, h: u16 };
pub const DispError = error{ NoHw, ModesetFailed, Busy, Unsupported, Timeout };

pub const DisplayDev = struct {
    name: [:0]const u8,
    caps: Caps,
    vt: *const VTable,
    pub const VTable = struct {
        probe: *const fn (*DisplayDev) bool,
        init: *const fn (*DisplayDev) DispError!void, // takeover + native modeset
        surfaces: *const fn (*DisplayDev) []const SurfaceDesc,
        map_surface: *const fn (*DisplayDev, idx: u8, as: *mm.AddrSpace) DispError!usize, // WC map
        flip: *const fn (*DisplayDev, idx: u8) DispError!void, // arms DSPBADDR; vblank completes
        damage: *const fn (*DisplayDev, rects: []const Rect) void, // hint; no-op on gma900
        vblank_event: *const fn (*DisplayDev) *sched.Event,
        set_output: *const fn (*DisplayDev, cfg: OutputCfg) DispError!void,
        detect_vga: *const fn (*DisplayDev) VgaStatus, // GMBUS DDC probe, ~15 ms
        cursor_set: *const fn (*DisplayDev, img: ?*const [64 * 64]u32) DispError!void,
        cursor_move: *const fn (*DisplayDev, x: i16, y: i16) void,
        suspend0: *const fn (*DisplayDev) void,
        resume0: *const fn (*DisplayDev) DispError!void,
        panic_fb: *const fn (*DisplayDev) PanicFb, // no locks, no alloc, polling only
    };
};
// Compile-time registry (locked architecture: in-kernel drivers are comptime registries)
pub const display_drivers = [_]*DisplayDev{ &gma900.dev, &bochsfb.dev, &vesafb.dev };
```

`/dev/fb0` ioctls (single-open; channel payload ≤64 B per contract):
`FBIO_GET_INFO` → {caps, surfaces[]}; `FBIO_MAP{idx}` → maps surface WC into caller;
`FBIO_DAMAGE{n≤6, rects[6]}` (GUI coalesces; >6 → multiple calls);
`FBIO_FLIP{idx}`; `FBIO_GET_VBLANK` → event handle; `FBIO_SET_OUTPUT{cfg}`;
`FBIO_DETECT_VGA`; `FBIO_CURSOR_SET{shm}` (16 KB shm handle); `FBIO_CURSOR_MOVE{x,y}`.
Backlight is **not** here — it belongs to the platform service (ACPI PBLS). See §13.

## 8. Register-level programming sequences (gma900)

Register base = MMADR (BAR0). `posting_read(r)` after state-changing writes.

### 8.1 DPLL_B divider search for 29.58 MHz — math
Gen3 equations: `m = 5*(m1+2) + (m2+2)`; `vco = 96_000 * m / (n+2)` kHz; `dot = vco / (p1*p2)`;
LVDS single-channel, dot < 112 MHz ⇒ **p2 = 14**. Constraints: vco 1.4–2.8 GHz, n 1–6, m 70–120,
m1 8–18, m2 3–11, p1 1–8.

Exhaustive search (`for p1, n, m1, m2 — minimize |dot−29580|`), leading candidates:

| p1 | n | m1 | m2 | m | VCO (MHz) | dot (kHz) | err |
|---|---|---|---|---|---|---|---|
| **5** | **3** | **18** | **6** | **108** | **2073.60** | **29622.9** | **+42.9 (+0.145%)** |
| 4 | 3 | 14 | 4 | 86 | 1651.20 | 29485.7 | −94.3 (−0.319%) |
| 6 | 2 | 17 | 7 | 104 | 2496.00 | 29714.3 | +134.3 |
| 4 | 3 | 14 | 5 | 87 | 1670.40 | 29828.6 | +248.6 |

**Chosen: n=3, m1=18, m2=6, p1=5, p2=14 → 29.6229 MHz**, refresh = 29.6229e6/(992×497) =
**60.08 Hz**. Well inside LVDS panel tolerance.
- `FPB0 = FPB1 = (n<<16)|(m1<<8)|m2 = 0x00031206` (FPB0=0x06048, FPB1=0x0604C).
- `DPLL_B (0x06018) = VCO_ENABLE(1<<31) | VGA_MODE_DIS(1<<28) | DPLLB_MODE_LVDS(2<<26) |`
  `P2_DIV_14(0<<24) | P1field((1<<(5-1))<<16) | REF_DREFCLK(0<<13) = 0x98100000`.

### 8.2 Takeover from BIOS text mode + LVDS modeset (full sequence)
Boot state: VBIOS drives the panel (VGA text upscaled by the panel fitter). "Fast takeover":
panel power stays ON (pixel-clock gap < 150 ms is fine; this is what every S3 cycle does).

```
 0. PCI enable; map BARs; read BSM/GGC; program GTT (§4.3); MTRR WC (§5).
 1. Disable VGA plane: outb(0x3C4,0x01); outb(0x3C5, inb|0x20)  (SR01 screen off);
    udelay(100); write VGACNTRL (0x71400) = VGA_DISP_DISABLE (1<<31).
 2. Read LVDS (0x61180); note BIOS pipe (bit30). Disable in order:
    a. DSPBCNTR (0x71180) &= ~(1<<31); write DSPBADDR (0x71184) to flush; wait 1 vblank
       (poll PIPEBSTAT bit1 after W1C).                     [also plane A path if BIOS used pipe A]
    b. PIPEBCONF (0x71008) = 0; poll PIPEBDSL (0x71000) until frozen (≤50 ms) — gen3 has no
       pipe-off status bit.
    c. DPLL_B &= ~(1<<31).      (LVDS port bit stays as-is — panel stays powered.)
 3. FPB0 = FPB1 = 0x00031206.
 4. LVDS (0x61180) = PORT_EN(1<<31) | PIPEB_SELECT(1<<30) | A0A2_CLKA_POWER_UP(3<<8)
       | HSYNC_POLARITY(1<<20)            // modeline is -HSync; +VSync ⇒ bit21 clear
       ;  A3/B0B3/CLKB pairs stay DOWN    // 18-bit single-channel
    (LVDS pin pair must be powered BEFORE DPLL enable — i9xx erratum honored by i915.)
 5. DPLL_B = 0x98100000; posting read; udelay(150); rewrite; udelay(150); rewrite; udelay(150).
    (Triple-write warm-up per i9xx_crtc code.)
 6. Pipe B timings (raw values, (end-1)<<16 | (start-1)):
       HTOTAL_B 0x61000 = 0x03DF031F     // 992 total, 800 active
       HBLANK_B 0x61004 = 0x03DF031F     // blank = active-end..total
       HSYNC_B  0x61008 = 0x037F032F     // 816..896
       VTOTAL_B 0x6100C = 0x01F001DF     // 497 total, 480 active
       VBLANK_B 0x61010 = 0x01F001DF
       VSYNC_B  0x61014 = 0x01E301E0     // 481..484
       PIPEBSRC 0x6101C = 0x031F01DF     // (w-1)<<16 | (h-1)
 7. PFIT_CONTROL (0x61230) = PANEL_8TO6_DITHER_ENABLE (1<<3)   // no PFIT_ENABLE: native mode.
    (Gen3 dither bit lives in PFIT and applies with the fitter bypassed; if bring-up shows
     banding, plan B: PFIT_ENABLE with 1:1 ratios — gen3 fitter is hardwired to the LVDS pipe.)
 8. DSPBSTRIDE (0x71188) = 3200; DSPBADDR = 0 (FB0 GTT offset);
    DSPBCNTR = DISPPLANE_32BPP_NO_ALPHA(0x6<<26) | SEL_PIPE_B(1<<24)   // not yet enabled
 9. PIPEBCONF = PIPECONF_ENABLE (1<<31); posting read; wait 1 vblank.
10. DSPBCNTR |= (1<<31); rewrite DSPBADDR (latches plane config).
11. Panel power check: PP_STATUS (0x61200) — expect PP_ON(1<<31) still set and PP_READY(1<<30)
    now set. If panel was powered down: PP_CONTROL (0x61204) |= POWER_TARGET_ON(1<<0); poll
    PP_ON ≤ 300 ms (BIOS-programmed PP_ON_DELAYS 0x61208 / PP_OFF_DELAYS 0x6120C /
    PP_DIVISOR 0x61210 are captured at boot and never changed).
12. IRQ: PIPEBSTAT = (1<<17); HWSTAM = 0xFFFFFFFF; IMR = ~bit4; IER = bit4 (pipe B event).
```

IRQ handler (hot path): `iir = IIR; if (iir & 1<<4) { st = PIPEBSTAT; PIPEBSTAT = st; // W1C
IIR = iir; event_signal(vblank); if (flip_armed) flip_done(); }`.

Teardown (output-off / suspend): reverse — backlight 0 via platform svc → PP_CONTROL off +
poll PP_ON clear → plane off (+flush, 1 vblank) → pipe off (DSL freeze) → DPLL off → LVDS
PORT_EN off. Panic-proofing: `modeset_state: enum {stable, in_progress}` is set around
steps 2–11.

### 8.3 VGA output (pipe A / DPLL_A / ADPA) — M2
800×600@60 (VESA: 40.000 MHz, 800 840 968 1056 / 600 601 605 628 +H +V), DAC p2=10 (dot<200 MHz):
search result **n=3, m1=17, m2=7, p1=5 → m=104, VCO=1996.8 MHz, dot=39.936 MHz (−0.16%)**.
- `FPA0 = FPA1 = 0x00031107` (0x06040/0x06044).
- `DPLL_A (0x06014) = (1<<31)|(1<<28)|DPLLB_MODE_DAC_SERIAL(1<<26)|(0<<24)|((1<<4)<<16) = 0x94100000`.
- Pipe A timings (0x60000 block, same field packing): HTOTAL_A=0x041F031F, HBLANK_A=0x041F031F,
  HSYNC_A=0x03C70347, VTOTAL_A=0x02730257, VBLANK_A=0x02730257, VSYNC_A=0x025C0258,
  PIPEASRC=0x031F0257 (800×600).
- `ADPA (0x61100) = DAC_ENABLE(1<<31) | pipeA(0<<30) | VSYNC_ACTIVE_HIGH(1<<4) |`
  `HSYNC_ACTIVE_HIGH(1<<3) = 0x80000018`.
- **Clone-letterbox**: plane A scans the SAME FB0 surface: DSPASTRIDE=3200,
  DSPAPOS (0x7018C) = (60<<16)|0, DSPASIZE (0x70190) = (479<<16)|799, DSPAADDR=0,
  DSPACNTR = (1<<31)|(0x6<<26)|SEL_PIPE_A. Gen2/3 primary planes support POS/SIZE (used by
  i9xx_update_plane); flagged for HW validation (risk R4) — fallback is a separate 800×600
  surface (FB2) with compositor-drawn black bars.
- **Hotplug: the 915GM has NO CRT hotplug interrupt** (PORT_HOTPLUG_EN/STAT CRT bits are
  945+/g4x; i915 gates them on `I915_HAS_HOTPLUG`). Detection = on-demand GMBUS DDC probe:
  GMBUS0 (0x5100) = pin 2 (VGADDC) | 100 kHz; read 128 B EDID at addr 0x50 via GMBUS1..3;
  NAK/SATOER ⇒ absent. Run only on `FBIO_DETECT_VGA` / Fn+F5 — never polled.
- **Fn+F5 policy**: platform svc translates ATKD 0x30–0x32 into `KEY_SWITCHVIDEOMODE` on the
  input stream; the GUI server calls `FBIO_SET_OUTPUT` cycling lvds → clone → vga (skipping
  states when detect says absent). The ACPI `SDSP` method is **never called** (SMM/VBIOS path
  would fight the native modeset).
- VGA-only mode: choose from a small built-in table (640×480, 800×600, 1024×768) filtered by
  probed EDID; the GUI keeps rendering 800×480 letterboxed (v1 simplification).

### 8.4 HW cursor — M2
915GM cursor base is a **physical** address (not GTT): CURBCNTR (0x700C0) =
CURSOR_MODE_64_ARGB_AX | MCURSOR_PIPE_B(1<<28); CURBBASE (0x700C4) = BSM+0x4E0000;
CURBPOS (0x700C8) = y<<16|x (sign bits for negative). Saves the compositor a damage rect per
mouse move — significant at our bandwidth.

### 8.5 Gen3 blitter (M3, optional) — the honest call
Ring: 16 KB in stolen; PRB0_START (0x2038) = ring GTT offset; PRB0_HEAD/TAIL = 0;
PRB0_CTL (0x203C) = ((16K/4K − 1) << 12) | 1 (valid). Commands (from i915/xf86-video-intel,
graphics addresses = aperture offsets):
- Fill: `XY_COLOR_BLT = (2<<29)|(0x50<<22)|4 | (1<<21)|(1<<20)`; BR13 = stride | 0xF0<<16 (PATCOPY)
  | 0x3<<24 (32bpp); DW2 = y1<<16|x1; DW3 = y2<<16|x2; DW4 = dst offset; DW5 = ARGB color.
- Copy: `XY_SRC_COPY_BLT = (2<<29)|(0x53<<22)|6 | (1<<21)|(1<<20)`; BR13 (rop 0xCC); dst rect;
  dst offset; DW5 = src y1<<16|x1; DW6 = src stride; DW7 = src offset.
- Completion: advance TAIL, poll HEAD==TAIL (no status page in v1); MI_FLUSH before dependent
  CPU access.
**Verdict:** both engines hit the same DDR2 wall, so the blitter does not raise throughput; SSE2
NT-store fills/copies from the WB shadow already meet the 8 ms budget. The blitter's one real win
is **aperture→aperture copies** (window drag, scrolling) where the CPU alternative means WC
*reads* (~5–20 MB/s, catastrophic) — but our shadow-redraw model never reads the front buffer.
**Recommendation: do not build it for M1/M2; keep this section as the M3 module spec, gated on
profiling showing compositor time > 8 ms.** Coherency note if built: sources must be in stolen
(unsnooped engine); never point it at WB system RAM without clflush discipline.

### 8.6 VBT parse (optional refinement, M2)
Scan shadowed VBIOS 0xC0000–0xCFFFF for `"$VBT"`; header → bdb_offset; iterate BDB blocks;
block 40 (LFP options, panel_type) + block 42 (LFP data, 18-byte DTD). Sanity window: pixclk
25–35 MHz, hact=800, vact=480. If valid and different from the hardcoded modeline, log both and
prefer VBT. The hardcoded verified modeline remains the default and the fallback.

## 9. Console & panic rendering

- **Pre-modeset**: boot log goes to BIOS VGA text (0xB8000, works via panel fitter) + a RAM ring.
- **kcon**: 8×16 embedded font (4 KB), 100×30 cells on 800×480; replays the RAM ring after
  modeset; releases the surface when the GUI opens /dev/fb0 (keeps a 6 KB text backing store —
  scroll is a redraw from the store, never a front-buffer read/blit).
- **Panic path** (`panic_fb()`, callable from any context, polling-only):
  - state==stable: return current front surface (kernel's own WC mapping); panic renderer also
    force-writes DSPBADDR=FB0 in case a flip left FB1 on screen.
  - state==in_progress: re-run §8.2 steps 3–10 from the cached last-good mode with PIT-based
    delays, bounded 500 ms; check PIPEBCONF read-back. On failure: write the panic record to the
    pstore RAM region (fixed phys addr, survives warm reboot; shown by next boot's console) and
    hard-blink the panel via PP_CONTROL toggle at 1 Hz so the user knows it died (no serial port).
  - vesafb/bochsfb: surface is always valid; trivial.

## 10. Suspend/resume (S3) — never re-POST the VBIOS

Strategy: **do not restore registers blindly — re-run the modeset** from cached `DisplayState`
{mode, output cfg, surface table, cursor}. Only BIOS-owned values captured once at boot are
restored beforehand: PP_ON_DELAYS, PP_OFF_DELAYS, PP_DIVISOR, BLC_PWM_CTL (0x61254), DSPARB
(0x70030), FW_BLC/FW_BLC2/FW_BLC_SELF (0x20D8/0x20DC/0x20E0). GTT is regenerated (§4.3); MTRRs
are restored by the generic CPU resume code; PCI COMMAND/BARs by generic PCI resume.

Order vs ACPI S3 — suspend: GUI freeze → `suspend0()` (teardown §8.2-reverse, IRQ masked) →
platform svc `_PTS`/S3. Resume: wake vector → CPU/MTRR/APIC/timers → PCI restore →
**display `resume0()` early** (so panic/console works for the rest of resume) → restore aux regs →
full modeset → signal GUI → GUI full-damage redraw (stolen survives S3 in self-refresh, but we
don't rely on it). vesafb: `caps.can_resume=false` → platform svc refuses S3 in safety mode
(the s2ram VBE_POST requirement is exactly what we cannot do from protected mode).

## 11. VESA 640×480 fallback driver (vesafb) + QEMU seam (bochsfb)

- Bootloader (NASM, real mode): if safety mode or `display=vesa`: INT 10h AX=4F01 for mode
  0x112; require 32bpp direct color + LFB; AX=4F02 BX=0x4112; store
  `VbeFb{phys, pitch, w=640, h=480, bpp=32}` in BootInfo. On real HW the LFB is the same GMADR
  aperture → same single-MTRR WC plan; in QEMU it is BAR0 of the emulated VGA.
- vesafb DisplayDev: one surface; `caps = {flip:false, vblank_irq:false, hw_cursor:false,
  vga_out:false, can_resume:false}`; vblank event synthesized by a 16.67 ms kernel timer
  (unsynced tearing accepted in safety mode); damage = direct NT-store copies. GUI must letterbox
  its 800×480 layout or relayout to 640×480 (GUI server reads surface dims — contract point).
- bochsfb (QEMU only): Bochs dispi index/data ports 0x1CE/0x1CF: XRES=800, YRES=480, BPP=32,
  VIRT_HEIGHT=960, ENABLE=0x41 (enabled|LFB); flip = Y_OFFSET register write on the synthetic
  vblank tick; `caps.flip=true`. This exercises the GUI's flip and damage paths at native
  resolution in CI, which gma900 cannot (no QEMU emulation).

## 12. RAM / disk budget

| item | cost |
|---|---|
| Kernel ELF text+rodata: gma900 ~26 KB (modeset 8, GTT/MTRR 3, IRQ 1, VGA+GMBUS 5, S3 3, VBT 2, cursor 1, misc 3) | |
| vesafb ~2 KB, bochsfb ~1.5 KB, kcon+font ~7 KB, panic ~2 KB, core+ioctl ~4 KB | **≈ 43 KB** of 1.5 MB kernel |
| Runtime kernel RAM: state+cached mode ~2 KB, S3 aux snapshot ~0.3 KB, pstore 8 KB, kcon store 6 KB, mappings/page tables ~4 KB | **< 24 KB** |
| Stolen (outside the 48 MB budget): FB0+FB1 3 MB, FB2 1.9 MB (lazy), cursor+ring+scratch 36 KB | 7932 KB available |
| GUI-server side (their budget, flagged): 1.5 MB WB shadow | |
| Bandwidth: scanout 92 MB/s constant; damage copies 2×bytes; full-frame sweep ≈ 3 ms | design constraint: no 60 fps full-frame clients except via flip |

Boot time: takeover+modeset ≤ 250 ms (fast takeover, no panel power cycle) — fits ≤8 s budget.

## 13. Backlight policy

- **Owner: platform service**, via ACPI `PBLS`/`PBLG` (0–15) on ASUS010 — the only verified path.
  Fn+F3/F4 are applied autonomously by EC/BIOS; platform svc just tracks 0x20–0x2F notifies.
- Display driver never touches backlight in normal operation. Cooperation contract: on
  `set_output(blank)`/suspend the display core notifies platform svc → PBLS 0 (and restore),
  ordered before pipe-off (no lit garbage) — because the physical PWM source is unverified (LOW),
  we do not assume PP power-off kills the backlight.
- Experiment hook (M3, off by default): `gfx.blc` debug ioctl to read/write BLC_PWM_CTL 0x61254
  (duty 15:0, freq 31:16) to establish whether the GMCH PWM pin is wired. BLC_PWM_CTL2 does not
  exist on gen3 (965+ only).

## 14. Bring-up & test plan

QEMU cannot emulate GMA900 → three test seams:
1. **Unit (host)**: `Gma900Hw` is generic over a comptime `Mmio` interface; a recorder Mmio
   captures (offset, value, delay) traces; golden-trace tests assert sequence invariants
   (LVDS-before-DPLL, triple DPLL write, plane-after-pipe, W1C handling, teardown order).
   Divider search is a pure function — table-driven tests incl. the two modelines above.
2. **QEMU**: bochsfb runs the full GUI at 800×480 with flips; vesafb path tested with
   `-device VGA` + bootloader VBE path. IRQ plumbing tested via bochsfb's timer event.
3. **Real HW (SD boot-to-RAM, iterate by reflash)**:
   - Stage 1: no modeset; dump BIOS state (BSM, GGC, PGETBL_CTL, DPLL/pipe/LVDS/PP regs, MTRR
     map) to VGA text + /data file. Validates discovery on real silicon.
   - Stage 2: GTT+MTRR only; CPU-write test pattern through aperture while BIOS mode still up
     (writes land in stolen — verify by reading back via aperture after WC flush, `sfence`).
   - Stage 3: modeset with test screen: color gradient (dither/banding check), 1-px border
     (timing/geometry check), corner markers. Failure diagnosis by photo; on hang, pstore log
     is read on next boot.
   - Stage 4: vblank counter on screen (60.08 Hz vs PM-timer cross-check); tear bar test for
     vblank-scheduled damage copies; flip flip-flop test.
   - Stage 5: S3 loop (100 cycles scripted), Fn+F5 cycle with/without monitor, panic injection
     mid-modeset (test hook) to exercise §9 recovery.

## 15. Risks & open questions

- **R1**: Which pipe the VBIOS uses for LVDS at boot (A or B) — takeover handles both
  (reads LVDS bit30); if BIOS used pipe A we also clear plane A/pipe A.
- **R2**: PANEL_8TO6_DITHER_ENABLE effectiveness without PFIT_ENABLE on gen3 — plan B: 1:1 fitter.
- **R3**: PP_* block behavior on 915GM as documented (offsets verified from i915 which uses them
  on gen3 mobile; MEDIUM-HIGH). Fast takeover mostly avoids it.
- **R4**: DSPAPOS/DSPASIZE letterbox clone untested combination — fallback FB2 surface.
- **R5**: MTRR pair exhaustion (unexpected; degraded UC mode exists but misses frame budget).
- **R6**: FIFO underruns (flicker) under combined audio+USB+scanout DDR2 load — M2 watermark
  programming per i9xx formula (FW_BLC/DSPARB) if observed; FW_BLC_SELF kept disabled.
- **R7**: No serial: worst-case hangs diagnosed only via pstore-on-warm-reboot + photos.
- **R8**: If real DRAM is DDR2-140, full-frame sweep ≈ 6–8 ms — still inside budget but tight;
  damage discipline in the GUI is mandatory (flagged to GUI team).
- **Open**: exact GSI for IGD INTA (expect 16 — confirm from _PRT); whether AMI VBIOS carries a
  $VBT (optional); EDID-less panel variance across 701 units (HannStar vs AUO — same modeline
  believed fine, VBT cross-check mitigates).

## 16. Phasing

- **M1**: gma900 core: discovery, GTT, MTRR WC, LVDS modeset (§8.2), vblank IRQ+event, single
  FB + damage ioctls, flip mechanism, kcon + panic path, vesafb + bochsfb, unit/QEMU harness.
- **M2**: S3 suspend/resume, HW cursor, VGA out + clone letterbox + DDC detect + Fn+F5 policy,
  VBT parse, watermark tuning (if needed), 100-cycle S3 soak.
- **M3 (optional, profiling-gated)**: blitter module (§8.5), BLC_PWM_CTL experiment, VGA-only
  arbitrary external modes.

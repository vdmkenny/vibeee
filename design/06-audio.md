# vibeee Design 06: SNDD: Userspace Audio Server (ICH6 HDA + ALC662)

> **Status: design only, not implemented.**
> Implemented code is limited to the M0 set listed in [`../README.md`](../README.md).
> Where this document and [`00-vibeee.md`](00-vibeee.md) disagree, the master design wins:
> it carries later decisions this document predates.

Status: design v1. Owner: audio subsystem. Targets kernel contracts v0.

## 1. Overview

sndd is a supervised userspace driver server owning the Intel HDA controller at PCI
00:1b.0 (8086:2668) and the Realtek ALC662 codec behind it. It provides:

- One hardware playback path (48 kHz S16LE stereo, 20 ms periods) and one hardware
  capture path (48 kHz S16LE mono-or-stereo), each on a dedicated HDA stream engine.
- A software mixer: N client playback streams (shm SPSC rings) mixed into the single
  hardware stream; softvol per client; master volume/mute in codec hardware (free).
- Jack-detect policy: HP insert auto-mutes speakers; e-mic insert auto-switches
  capture source. State pushed to subscribers (status bar).
- A control surface consumed by the GUI (volume hotkeys, mixer app, status bar).
- Cold re-init on crash/restart and on resume from S3.

Design center: this machine plays one thing at a time plus UI feedback sounds. The
mixer is deliberately minimal, fixed 48 kHz S16LE pipeline, linear resampling for
44.1 k-family rates, no effects, no per-stream formats beyond mono/stereo S16LE.
Everything else is rejected at open_stream() and the client library converts.

## 2. Hardware facts used (with research confidence)

| Fact | Value | Confidence |
|---|---|---|
| Controller | ICH6 HDA, PCI 00:1b.0, 8086:2668, rev 04 | HIGH (lspci, both reports) |
| Controller streams | 4 ISS + 4 OSS, 0 BSS (ICH6 GCAP) | HIGH (ICH6 datasheet class) |
| Codec | Realtek ALC662 rev1, HDA VID/DID 0x10EC0662, SSID 1043:82a1 | HIGH (kernel quirk 291702f0) |
| Codec link address | assumed 0, single codec | LOW, enumerate STATESTS, do not hardcode |
| Speakers | pin NID 0x14, amp mute | HIGH |
| HP jack | pin NID 0x1b, presence detect wired, unsol capable | HIGH |
| e-mic jack | pin NID 0x18, presence detect wired | HIGH |
| i-mic | pin NID 0x19 | HIGH |
| Front DAC | NID 0x02 | HIGH |
| Input mixer / capsrc | 0x0b loopback mixer; ADC mux/capsrc NIDs 0x22/0x23; e-mic idx 0, i-mic idx 1 | HIGH |
| ADCs | 0x09 (primary, mux 0x22), 0x08 secondary | MEDIUM (patch_realtek structure; verify via F00 walk at init) |
| No S/PDIF wired | analog only | HIGH |
| Shipped-OS gotcha | ALSA "Capture Switch" defaulted OFF on Xandros | HIGH |
| Hotkeys | ACPI ASUS010 notify 0x13 mute / 0x14 vol- / 0x15 vol+ (Fn+F7/8/9); NOT i8042 scancodes | HIGH |
| HDA interrupt GSI | NOT verbatim-confirmed for 701 4G (research uncertainty; ICH6 INTA→PIRQ, expect 16–23, likely shared with UHCI) | LOW, obtain from ACPI _PRT via devmgr, verify at runtime |
| MMIO BAR0 | BIOS-assigned; 16 KB region | HIGH (HDA spec class) |
| S3 | works; full device re-init required after resume | HIGH |
| CPU | 630 MHz, SSE2, no SSE3; ~1 GB/s theoretical mem BW | HIGH |

## 3. Architecture

```
 clients (GUI sounds, media player, games via libaudio)         status bar
   |  open_stream -> {shm ring, event}                              |
   v                                                                v
 +-------------------------------- sndd ----------------------------------+
 | control thread (chan /svc/audio):  open/close, volumes, jack state,    |
 |   subscriptions, stats, pm.suspend/resume from platform svc           |
 | mix thread (RT, period-driven by HDA IOC irqevent):                    |
 |   drain client rings -> resample -> softvol -> saturating mix ->       |
 |   write next period into HW playback ring; capture: HW ring -> clients |
 | irq path: INTSTS -> SDSTS ack (period done) | RIRB (verb resp/unsol)   |
 +--------------------------------------------------------------------+---+
   | map_mmio(BAR0) | dma_alloc (CORB/RIRB/posbuf, BDLs, PCM rings)   |
   | irq_attach(gsi from devmgr/_PRT) | pci_cfg_read/write(00:1b.0)   |
   v                                                                  v
 ICH6 HDA controller == HDA link ==> ALC662: DAC 0x02 -> mix 0x0c -> 0x14/0x1b
                                     pins 0x18/0x19 -> capsrc 0x22 -> ADC 0x09
```

Threads (2): control thread (IPC server, non-RT) and mix thread (RT, woken by the
stream irqevent). Unsolicited responses are handled on the control thread (RIRB
interrupt forwards via an internal event), jack policy has no RT deadline.

Startup: devmgr matches PCI 8086:2668 against /drivers/sndd.manifest, spawns sndd
with grants {pci_cfg(00:1b.0), map_mmio(BAR0), ioport: none, dma_alloc, irq_attach
(gsi from ACPI _PRT)}. sndd inits hardware, then registers "audio" in /svc.
Not on the boot critical path; ready ≈150 ms after spawn.

### 3.1 Period/format policy

- Hardware runs fixed 48000 Hz, S16LE, 2ch, period 960 frames = 3840 B = 20 ms.
  50 wakeups/s is the right trade at 630 MHz: 5 ms periods would 4x IPC/IRQ
  overhead for latency nobody needs on this device. 48k (not 44.1k) because it is
  the HDA base rate, integer-divides to 16k/8k voice rates, and modern content is 48k.
- Client playback rates accepted: 8000, 11025, 16000, 22050, 24000, 32000, 44100,
  48000; mono or stereo S16LE only. Non-48k resampled by linear interpolation
  (arithmetic in §6: ≤0.2% CPU per stream, cheap enough to accept, rejecting 44.1k
  would just push a worse resampler into every client).
- Capture: 48 kHz native; 16 kHz decimated (x3 averaging) offered for voice (M2).
- End-to-end latency (playback): client ring ≤2 periods queued + 1 period mix-ahead
  + 2 periods HW ring fill + ~1 ms FIFO ≈ typical 45 ms, worst 65 ms. Capture ≈ 25 ms.

## 4. Data structures & interfaces (Zig)

### 4.1 Client wire protocol (channel /svc/audio; ≤64 B inline, ≤4 handles)

```zig
pub const Op = enum(u16) {
    open_stream, close_stream, set_stream_vol, pause_stream, flush_stream,
    get_master, set_master, set_master_mute, set_capture_gain, set_capture_source,
    get_jack_state, subscribe, get_stats, pm_quiesce, pm_resume, // last two: platform svc only
};

pub const Dir = enum(u8) { playback, capture };
pub const Fmt = enum(u8) { s16le };

pub const OpenStreamReq = extern struct {
    op: Op = .open_stream,
    dir: Dir, channels: u8,          // 1 or 2
    fmt: Fmt = .s16le, _pad: u8 = 0,
    rate: u32,                        // from accepted set
    ring_frames: u32,                 // 0 => default 2048; power of two, 960..8192
    name: [16]u8,                     // for stats/mixer UI
};
pub const OpenStreamRep = extern struct {
    status: i32, stream_id: u32,
    ring_bytes: u32,                  // size of granted shm
    // handles granted with reply: [0]=shm ring, [1]=event (sndd->client:
    //   playback "space freed / xrun", capture "data available / xrun")
};

pub const SetVolReq   = extern struct { op: Op, stream_id: u32, vol: u8 };  // 0..100 softvol
pub const MasterReq   = extern struct { op: Op, vol: u8, mute: u8 };         // vol 0..100
pub const JackState   = extern struct { hp_present: u8, emic_present: u8,
                                        active_out: u8, active_in: u8 };     // 0=speaker/imic 1=hp/emic
pub const SubscribeReq = extern struct { op: Op };  // handle[0] = client event; on any
    // mixer/jack change sndd signals it; client re-queries get_jack_state/get_master.
pub const Stats = extern struct { hw_underruns: u32, client_underruns: u32,
                                  periods: u64, active_streams: u8, cpu_permille: u16 };
```

### 4.2 Shared-memory PCM ring (SPSC, per kernel contract)

```zig
pub const RING_MAGIC = 0x44554145; // "EAUD"
pub const RingHdr = extern struct {
    magic: u32, version: u16, channels: u8, _r0: u8,
    rate: u32, frame_cap: u32,               // power of two
    wr: u32 align(64),                        // producer index (frames, free-running)
    rd: u32 align(64),                        // consumer index
    xruns: u32, flags: u32,                   // bit0: xrun latched (consumer sets, producer clears)
    // PCM at byte offset 128: [frame_cap][channels]i16
};
// Playback: client=producer, sndd=consumer. Capture: reversed.
// Indices free-running u32, monotonic, masked by (frame_cap-1); SeqCst not needed:
// release-store own index, acquire-load peer index (single 32-bit aligned stores are
// atomic on i686).
```

Default ring 2048 frames stereo = 8 KB PCM + 128 B header → 12 KB shm (3 pages).

### 4.3 libaudio client API (ships with libeui)

```zig
pub const Stream = struct {
    pub fn open(o: OpenOpts) Error!Stream;          // connects /svc/audio, grants ring
    pub fn write(s: *Stream, frames: []const i16) usize;   // non-blocking, returns consumed
    pub fn writeAll(s: *Stream, frames: []const i16) Error!void; // blocks on event
    pub fn read(s: *Stream, frames: []i16) usize;   // capture
    pub fn setVol(s: *Stream, v: u8) void;
    pub fn close(s: *Stream) void;
};
// Reconnect policy: on channel-closed error, libaudio retries connect to /svc/audio
// with 100 ms/250 ms/500 ms/1 s backoff (8 tries), reopens the stream with the same
// params, and resumes producing. Ring contents are lost (glitch, not error).
// UI feedback sounds simply drop on failure; media players surface an error after
// the 8th failed retry.
```

### 4.4 Internal controller structures

```zig
const Hda = struct {
    regs: [*]volatile u8,               // BAR0 mapping (16 KB)
    n_iss: u4, n_oss: u4,               // from GCAP
    cad: u4,                            // codec address from STATESTS (expect 0)
    corb: [*]volatile u32, corb_n: u16, // 256 entries
    rirb: [*]volatile u64, rirb_n: u16, rirb_rp: u16,
    posbuf: [*]volatile u32,            // 8 streams * 8 B
    use_posbuf: bool,                   // runtime-validated, else LPIB
    play: StreamEng, cap: StreamEng,
    fn rd32(h: *Hda, off: u32) u32; fn wr32(h: *Hda, off: u32, v: u32) void; // + 8/16
    fn cmd(h: *Hda, nid: u8, verb: u32, payload: u32) !u32;  // CORB/RIRB, §5.3
};
const BdlEntry = extern struct { addr: u64, len: u32, ioc: u32 }; // 16 B, ioc bit0
const StreamEng = struct {
    sd_off: u32,      // 0x80 + idx*0x20 (capture: idx 0 -> 0x80; playback: idx n_iss -> 0x100)
    tag: u4,          // playback 1, capture 2
    int_bit: u5,      // INTCTL/INTSTS bit = global stream index
    bdl: []BdlEntry,  // 4 entries (1 period each), 128 B aligned, in DMA page
    buf: DmaRegion,   // 4 * 3840 B, physically contiguous (<16 KB: single dma_alloc)
    hw_period: u32,   // 3840
};
```

DMA layout, one dma_alloc(4096) page: CORB @0 (1 KB), RIRB @0x400 (2 KB),
posbuf @0xC00 (64 B, 128-aligned), play BDL @0xD00, cap BDL @0xE00. Plus two
dma_alloc(16384) PCM buffers. All <4 GB per contract; upper BDL/base words = 0.

### 4.5 devmgr manifest

```
/drivers/sndd.manifest:
  name=sndd  bin=/drivers/sndd
  match pci vid=8086 did=2668
  caps = pci_cfg, map_mmio, dma_alloc, irq_attach
  svc  = audio
  restart = always, backoff 250ms, max 5/min
```

## 5. Register-level programming sequences

HDA spec 1.0a register offsets (BAR0-relative): GCAP 0x00, GCTL 0x08, WAKEEN 0x0C,
STATESTS 0x0E, INTCTL 0x20, INTSTS 0x24, WALCLK 0x30, SSYNC 0x38, CORBLBASE 0x40,
CORBUBASE 0x44, CORBWP 0x48, CORBRP 0x4A, CORBCTL 0x4C, CORBSIZE 0x4E, RIRBLBASE
0x50, RIRBUBASE 0x54, RIRBWP 0x58, RINTCNT 0x5A, RIRBCTL 0x5C, RIRBSTS 0x5D,
RIRBSIZE 0x5E, ICOI 0x60, ICII 0x64, ICIS 0x68, DPLBASE 0x70, DPUBASE 0x74.
Stream descriptor n at 0x80+n*0x20: CTL 0x00(24-bit), STS 0x03, LPIB 0x04, CBL 0x08,
LVI 0x0C, FIFOS 0x10, FMT 0x12, BDLPL 0x18, BDLPU 0x1C.

### 5.1 PCI + controller bring-up

1. pci_cfg: COMMAND |= MEM_EN|BUS_MASTER (bits 1,2). Read BAR0, map_mmio(bar0, 16K).
2. TCSEL (pci cfg 0x44) &= ~0x07, force traffic class 0 (standard Intel HDA errata
   step; wrong TC breaks snooping/interrupt delivery).
3. Link reset: GCTL.CRST(bit0)=0; poll ≤10 ms until reads 0. GCTL=1 (CRST deassert,
   also UNSOL accept bit8 set later); poll ≤10 ms until reads 1. Wait 1 ms
   (spec: ≥521 µs for codecs to self-enumerate).
4. Read STATESTS[2:0]: bitmask of present codecs. Expect bit0 → cad=0; take lowest
   set bit otherwise (covers the LOW-confidence address assumption). None set →
   repeat reset up to 3x → fail("no codec").
5. GCAP: record n_iss (bits 11:8), n_oss (bits 15:12). ICH6 expects 4/4; assert ≥1/≥1.
6. Set GCTL.UNSOL (bit8)=1.

### 5.2 CORB/RIRB init (in the dma_alloc ring page)

1. CORBCTL.CORBRUN=0; poll clear. RIRBCTL.RIRBDMAEN=0.
2. CORBSIZE: verify 256-entry cap (bits 7:4), write size sel 0b10 (256). Same RIRBSIZE.
3. CORBLBASE=pa(corb), CORBUBASE=0. CORBWP=0. CORBRP: write bit15 (RST), poll bit15==1,
   write 0, poll bit15==0 (spec dance).
4. RIRBLBASE=pa(rirb), RIRBUBASE=0. RIRBWP: write bit15 (self-clearing reset).
   rirb_rp=0. RINTCNT=1 (interrupt per response, cheap at our verb rates, needed
   for prompt unsolicited delivery).
5. RIRBCTL = RINTCTL(bit0) | RIRBDMAEN(bit1). CORBCTL = CORBRUN(bit1).
6. INTCTL = GIE(bit31) | CIE(bit30); stream bits added at stream start.

### 5.3 Verb transport: cmd(), timeout, retry, fallbacks

```
cmd(nid, verb, payload):
  next = (corb_wp + 1) & 255
  corb[next] = (cad<<28)|(nid<<20)|encode(verb,payload)   // 12-bit verb: verb<<8|pay8
                                                          // 4-bit verb (0x2xx,0x3xx set fmt/amp): verb<<16|pay16
  CORBWP = next
  wait rirb event, deadline 10 ms:
    on RIRBSTS.RINTFL: ack (write 1); drain rirb[rirb_rp+1 .. RIRBWP]:
      entry = {resp:u32, ext:u32}; if ext bit4 (unsol) -> queue to unsol handler
      else -> this is our response, return resp
  timeout: retry once (re-send verb).
  2nd timeout: switch to immediate-cmd fallback for this and all further verbs:
      poll ICIS.ICB==0; ICOI=cmd; ICIS=ICB|IRV; poll IRV; read ICII.
  If immediate mode also times out 3x: declare codec dead -> full 5.1 re-init;
  after 3 full re-inits, exit(1) and let the supervisor restart/quarantine us.
```

The 10 ms deadline uses the irqevent when the GSI works; if no RIRB interrupt is ever
seen during init (unverified GSI: LOW confidence), sndd logs it and permanently
falls back to 1 ms-tick polling of RIRBSTS/SDSTS (timer event). Audio still works,
period pacing then derives from the posbuf/LPIB poll. This is the GSI-uncertainty
seam: correctness never depends on the interrupt line being right.

### 5.4 Codec identification & graph verification

1. `cmd(0x00, F00, 0x00)` → VID/DID. 0x10EC0662 → ALC662 table. Vendor 0x1AF4
   (QEMU hda-duplex) or anything else → generic mini-parser (§8): walk F00 param
   0x04 (sub-node count) from AFG, find first out-pin↔DAC and in-pin↔ADC paths.
2. AFG NID: from root sub-node walk; expect 0x01 (function group type param 0x05 == 1).
3. For ALC662: verify widget types of 0x02 (DAC), 0x14/0x1b/0x18/0x19 (pins), 0x0c
   (mixer), 0x22 (capsrc), 0x09 (ADC) via F00 param 0x09 (widget caps). Mismatch →
   log + fall back to generic parser (defensive; expected never on this machine).
4. Read amp caps: DAC out amp F00 param 0x12 on 0x02 (fields: offset[6:0],
   nsteps[14:8], stepsize[22:16] in 0.25 dB units, mute[31]) → build the UI→step
   volume map at runtime (no hardcoded step counts). Pin 0x18/0x19 input amp caps
   (param 0x0D) → mic boost steps.

### 5.5 ALC662 output path init (exact verbs; cad prefix implied)

```
0x01 0x705 0x00      # AFG -> D0; wait 10 ms (Realtek analog settle)
0x01 0x7FF 0x00      # (optional M2: function reset before replay-on-resume)
0x02 0x705 0x00      # DAC D0
0x02 0x2   0x0011    # converter format: 48k, 16-bit, 2ch (base48k|div1|mult1|BITS16|CHAN2)
0x02 0x706 0x10      # stream tag 1, channel 0
0x02 0x3   0xB000|vol_steps   # out amp L+R, unmute, gain = master map (§7)
0x0c 0x3   0x7000    # mixer 0x0c: unmute input idx0 (DAC 0x02 path), gain 0
0x0c 0x3   0x7180    # mixer 0x0c: MUTE input idx1 (0x0b loopback, no analog mic bleed)
# speakers:
0x14 0xF02 …         # read conn list; find index of 0x0c -> ci14 (do not assume 0)
0x14 0x701 ci14      # connection select -> mixer 0x0c
0x14 0x707 0x40      # pin ctl: OUT enable
0x14 0xF00p0x0C      # pin caps; if EAPD capable (bit16):
0x14 0x70C 0x02      #   EAPD on (speaker amp enable: Eee speakers typically need it)
0x14 0x3   0xB000    # pin out amp: unmute L+R
# headphone:
0x1b 0xF02/0x701 ci1b
0x1b 0x707 0xC0      # pin ctl: HP drive + OUT enable
0x1b 0x70C 0x02      # EAPD if capable
0x1b 0x3   0xB000
0x1b 0x708 0x81      # unsolicited enable, tag 1 (HP jack)
# initial jack reconcile:
0x1b 0xF09 0x00      # pin sense; bit31 presence -> if present: 0x14 0x3 0xB080 (mute spk)
```

### 5.6 ALC662 capture path init (default: present but OFF, see §7 policy)

```
0x18 0x707 0x24      # e-mic pin: IN enable | VREF 80% (electret bias)
0x18 0x708 0x82      # unsolicited enable, tag 2 (mic jack)
0x19 0x707 0x24      # i-mic pin: IN | VREF 80%
0x18 0x3   0x7000|boost   # input (boost) amp: default +1 step for i-mic/e-mic (tunable)
0x19 0x3   0x7000|boost
0x22 0x3   0x7180    # capsrc mixer: mute idx0 (e-mic) …
0x22 0x3   0x7100|0x80 # … and idx1 (i-mic): ALL muted until a capture stream opens
0x09 0x705 0x03      # ADC D3 until first capture open
# on capture open: 0x09 0x705 0x00; 0x09 0x2 0x0011; 0x09 0x706 0x20 (tag 2);
#   0x09 0x3 0x7000|capgain (ADC input amp = "Capture Volume");
#   unmute exactly one 0x22 index: e-mic present ? idx0 : idx1 (sense 0x18 0xF09)
```

This encodes the shipped-OS lesson deliberately: the *global* default is capture
silent (privacy + power), but opening a capture stream auto-enables the full path,
no hidden "Capture Switch OFF" trap for applications.

### 5.7 Stream start (playback engine; capture symmetric)

```
1. SD_CTL.SRST=1; poll set; SRST=0; poll clear.            # engine reset
2. SD_CTL byte2 = tag<<4 (stream number 1).                # bits 23:20
3. SD_CBL  = 4*3840 = 15360. SD_LVI = 3.                   # 4 BDL entries
4. BDL[i] = { pa(buf)+i*3840, 3840, ioc=1 } i=0..3;        # IOC every period
   SD_BDLPL = pa(bdl), SD_BDLPU = 0.
5. SD_FMT = 0x0011.                                        # matches converter fmt
6. DPLBASE = pa(posbuf) | 1 (once, at init); DPUBASE = 0.
7. Pre-fill periods 0,1 with mixed audio (or silence), wr_pos=2.
8. INTCTL |= 1<<int_bit; SD_CTL |= RUN|IOCE|FEIE|DEIE.
9. On each IOC irq: ack SDSTS (write BCIS|FIFOE|DESE = 0x1C), mix-fill the period
   just freed, wr_pos++. Position check: posbuf[stream] (validate: nonzero and
   advancing within the first 2 periods, else use_posbuf=false and read LPIB,
   ICH6's posbuf is expected to work; LPIB is the runtime-verified fallback,
   period-granular accuracy is all we need).
Stop: SD_CTL.RUN=0; poll SDSTS FIFO idle ≤ 1 period; INTCTL &= ~(1<<int_bit); SRST dance.
```

SSYNC is not used: playback and capture start independently; nothing requires
sample-locked start on this machine.

### 5.8 Interrupt service (mix thread wait loop)

```
wait_many(irqevent, timer(25 ms watchdog), quit_event):
  INTSTS = rd32(0x24)
  if INTSTS & (1<<play.int_bit): ack play SDSTS; mix next period; signal client events
  if INTSTS & (1<<cap.int_bit):  ack cap SDSTS; copy period into capture rings
  if INTSTS & CIS: drain RIRB (responses -> cmd() waiter; unsol -> control thread queue)
  # Shared level-triggered line safety (GSI may be shared with UHCI): if INTSTS==0,
  # it was not ours -> return from handler without acks; never spin.
  watchdog tick: if RUN set and position unchanged since last tick -> recover:
    stop stream, SRST, re-prime silence, start; hw_underruns++;
    >3 recoveries/60 s -> full controller re-init (§5.1).
```

### 5.9 Unsolicited response handling (control thread)

Unsol resp: tag = resp[31:26]. Debounce 100 ms (Realtek fires on both edges + bounce),
then `0x1b/0x18 0xF09 0x00` re-read sense (bit31 = present):

- tag 1 (HP): present → `0x14 0x3 0xB080` (mute speakers); absent → `0xB000` unless
  master-muted. Update JackState, signal subscribers.
- tag 2 (e-mic): if a capture stream is open, switch capsrc 0x22 mutes (unmute idx0
  ↔ idx1); else just record state. Signal subscribers.

### 5.10 Power / suspend / resume / teardown

- Idle (no open streams 10 s): stop engines (already stopped), `0x02/0x09 0x705 3`,
  `0x01 0x705 3` (AFG D3). Controller stays out of reset; RIRB keeps running.
  Jack unsol in D3 is not trusted: on wake (any open_stream or pm event) sndd
  re-polls both senses and reconciles (missed-event-proof). Wake: AFG D0, 10 ms
  settle, widget D0s, replay amp/pinctl state from the shadow mixer state (§7).
- pm.suspend (call from platform svc on /svc/audio, must ack ≤200 ms): stop streams
  (clients keep producing into rings; rings simply fill), save mixer/jack shadow
  state, codec AFG→D3, GCTL.CRST=0 (link reset held through S3).
- pm.resume (platform svc calls after kernel restored PCI config): full §5.1–5.7
  re-init (identical to cold path, one code path, idempotent), restore shadow
  state, restart streams that were running, re-poll jack sense. Glitch ≤1 period.
- Teardown/exit: streams stop, codec D3, CRST=0, unmap. Supervisor restart then
  always finds the device in a known (reset) state, but never RELIES on that (§8).

## 6. Mixing engine

Per 20 ms period (960 frames): for each active playback stream: read ≤960 output
frames worth from its ring (rate-converting), apply softvol, accumulate; saturate;
store to the just-freed HW period.

- Softvol+mix (SSE2, 48k stereo): pmulhw against Q15 gain (vol table §7), paddsw
  saturating accumulate. 1920 samples/period = 240 XMM iterations ≈ 2.5 k cycles
  per stream-period → 0.02% CPU per stream at 630 MHz.
- Linear resampler (44.1k→48k etc.): 32.32 fixed-point phase accumulator, scalar
  (~24 cycles/out frame incl. loads) → 23 k cycles/period ≈ 0.18% CPU per stream.
  Quality (-70 dB-ish images) is fine for these speakers; NOT acceptable: reject-
  and-force-client-side, which duplicates worse code in every app.
- Mono→stereo: duplicate during the same pass (free).
- Capture fan-out: memcpy per client + optional 3:1 decimate (16k voice): <0.05%.
- Overhead: 50 wakeups/s × ~15 k cycles (syscall + cache) ≈ 0.12%.
- Totals: typical (1×48k + 1×44.1k stream) ≈ 0.4%; ceiling budget 3% CPU with 8
  streams; memory traffic ≈ 1.5 MB/s worst case, noise vs ~1 GB/s.

Client underrun: ring empty at mix time → contribute silence, hdr.xruns++, set
xrun flag, signal client event; stats via get_stats. Never stall the HW stream for
a slow client. HW underrun handling in §5.8.

Scheduling ask (kernel contract addition needed): mix thread requests an RT-ish
class: `sched_set(.audio_rt)` = strictly above GUI/normal classes, wake→run ≤5 ms
guaranteed, implicit budget ~3 ms/20 ms (protects the system from a runaway sndd).
Fallback if M1 kernel lacks it: highest nice + 4-period HW ring (80 ms) instead of
mix-ahead=1, trading latency for safety.

## 7. Controls surface & policy

- Volume model: UI 0–100. 0 = mute; 1..100 maps linear-in-dB over [-49.5 dB, 0 dB]
  (0.5 dB/point), quantized to DAC 0x02 amp steps using runtime amp caps
  (step_size from caps; steps_down = round(att_db / step_db)). Master vol/mute live
  in codec hardware (DAC amp + pin mutes), zero CPU, survives in shadow state for
  replay. Per-client softvol is the same curve in Q15.
- Who calls sndd for hotkeys: ACPI notify 0x13/0x14/0x15 → platform svc → kernel
  input core → single GUI event stream (per contract). The GUI volume applet calls
  set_master/set_master_mute (steps of 5) and draws the OSD. Rationale: one policy
  point, OSD needs the GUI anyway, sndd stays policy-free. If the GUI is dead,
  volume keys are dead, acceptable (audio clients are GUI apps here).
- Defaults at first boot: master 60, unmuted; capture path muted/D3 (auto-enabled
  by open, §5.6); mic boost +1 step. Persisted to /cfg/sndd.conf (tiny key=value,
  written ≤ once per change with 2 s debounce: SSD-write hygiene).
- Jack state: JackState via get_jack_state; subscribers (status bar) get event
  signals on change (subscribe op grants an event handle; ≤8 subscribers).
- Capture source: auto (jack-driven) by default; set_capture_source can pin
  e-mic/i-mic explicitly (auto restored on next boot unless configured).

## 8. Restartability

- Supervisor (devmgr) restarts sndd on crash (backoff 250 ms, max 5/min, then
  quarantine + notify GUI "audio unavailable").
- Re-init is the cold path: §5.1 CRST handles any half-programmed controller state
  (link reset also resets stream engines; codec loses all verbs, full replay).
  DMA pages from the dead instance are freed by handle death; in-flight DMA stops
  at CRST. No IOMMU: the window between crash and restart CRST is documented
  trusted-DMA exposure (bounded: engines only write inside their old BDL ring).
- Clients: channel death → libaudio reconnect protocol (§4.3). /svc re-registration
  is last in sndd init, so reconnectors never see a half-alive server.
- State: mixer/jack shadow state reloaded from /cfg/sndd.conf; jack sense re-polled;
  worst case a restart forgets ≤2 s of un-debounced volume tweaks.

## 9. RAM / disk budget

| Item | Size |
|---|---|
| Binary (/drivers/sndd, ReleaseSmall) | ≤ 640 KB target (cap 1 MB) |
| .bss/.data + heap steady | ≤ 256 KB |
| Stacks (control 32 KB + mix 32 KB) | 64 KB |
| DMA: ring page 4 KB + 2×16 KB PCM | 36 KB |
| Client shm rings (8 × 12 KB) | 96 KB |
| Mix scratch (S32 accum + resample) | 16 KB |
| Steady-state total | ≈ 1.1 MB typ, hard cap 4 MB |

Boot-image share: sndd binary + manifest ≤ 0.7 MB of the 24 MB rootfs.

## 10. Bring-up & test plan

QEMU (M1 dev loop): `-device intel-hda -device hda-duplex -audiodev wav,...`.
QEMU's intel-hda advertises exactly 8086:2668, controller code (reset, CORB/RIRB,
streams, BDL, posbuf, IRQ) gets full parity coverage. The codec is NOT an ALC662:
hda-duplex is a Red Hat (0x1AF4) codec with a trivial graph, that is the designed
test seam: codec-table selection by VID (§5.4) routes QEMU to the generic
mini-parser, so mixer/ring/latency logic is testable in CI while the ALC662 table
is validated only on hardware. QEMU tests: tone generator client → wav capture and
FFT-check 440 Hz purity/gaps; 44.1k resample continuity (phase-continuous sweep);
8-client mix saturation; kill -9 during playback → restart <1 s, client resumes;
underrun injection (SIGSTOP the tone client); pm_quiesce/resume cycle; verb
timeout path (QEMU `-device intel-hda` with no codec → immediate-cmd/poll fallback
and clean failure).

Real hardware (needs display or netd log console, no serial): staged bring-up
binary logs to screen/ramlog. Order: (1) PCI probe, BAR map, CRST, STATESTS shows
codec present; (2) verb F00 VID == 0x10EC0662; (3) speaker tone via polling (no
IRQ dependency); (4) confirm actual GSI: enable interrupts, count IOC irqs vs
posbuf progress, record the true GSI in the platform notes for devmgr; (5) jack
matrix: {insert, remove} × {HP, e-mic} × {idle, playing, capturing, codec-D3-idle}
→ expected mute/switch behavior + status bar event, incl. the D3 re-poll-on-wake
path; (6) Fn+F7/8/9 end-to-end through GUI; (7) S3 suspend/resume ×20 loop with
playback across it; (8) 2 h playback soak: zero hw_underruns while dragging GUI
windows; (9) restart-storm: kill sndd 10× during playback+capture.

## 11. Risks & open questions

- **HDA GSI unverified** (research explicitly lists it): mitigated by _PRT-sourced
  GSI from devmgr + runtime verification + permanent polling fallback (§5.3, §5.8).
  Needs one real-hw session to pin (likely 16–23, possibly shared with UHCI,
  irqevent contract must permit shared level-triggered attach; flagged to kernel-core).
- **Codec address assumed 0** (LOW): handled: STATESTS-driven, any address works.
- **ALC662 conn-list indices** (0x0c position in pin lists, capsrc idx mapping):
  research gives e-mic=0/i-mic=1 (HIGH) but pin-side indices are read at runtime
  (F02) rather than assumed. Residual risk: capsrc 0x22 could be selector-style
  rather than mute-matrix-style on this silicon rev, init reads widget caps
  (mux vs mixer) and uses 0x701 conn-select instead of amp mutes if it's a mux.
- **EAPD presence** on 0x14/0x1b uncertain: probed via pin caps; if speakers are
  silent with everything unmuted on first hw bring-up, EAPD/GPIO is suspect
  (some ASUS boards use codec GPIO1 for the speaker amp, fallback experiment:
  set GPIO data/dir/enable bits via verbs 0x715/0x716/0x717).
- **posbuf reliability on ICH6**: dual-path with LPIB fallback, runtime-selected.
- **RT scheduling class** doesn't exist in kernel contracts v0, requested (§6).
  Fallback (larger HW ring) designed but costs latency.
- **Power-button chirp / boot sound**: none planned (saves boot path work).
- Open: does platform svc or GUI own the *policy* of hotkey repeat-rate for volume?
  (Assumed GUI.) Open: /cfg write arbitration (single writer per file assumed).
- Open: capture privacy indicator, status bar should show a mic-active dot; sndd
  exposes active_streams in Stats + event on capture open/close (cheap, included).

## 12. Phasing

- **M1 (boots + beeps)**: controller bring-up, verb transport incl. fallbacks,
  ALC662 output path, single 48k playback stream, polling-tolerant IRQ path, master
  volume/mute ops, QEMU parity suite, real-hw GSI confirmation. No capture, no
  resampling (48k-only clients; GUI sounds ship as 48k), no jack-detect (speakers
  always on).
- **M2 (daily-drive)**: mixer with N clients + softvol, linear resampler, jack-detect
  auto-mute + status bar events, capture path + auto-source-switch, hotkey binding
  via GUI, /cfg persistence, idle D3, pm suspend/resume, restart protocol +
  libaudio reconnect, RT class adoption.
- **M3 (polish)**: 16k decimated capture for voice, per-client mixer UI surface,
  stats/cpu_permille reporting, capture privacy indicator, soak/underrun tuning,
  optional codec GPIO amp handling if hw bring-up demanded it.

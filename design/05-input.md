# vibeee Input Stack Design (05-input)

> **Status: partially implemented.**
>
> Built and working: the i8042 driver ([`drv/input/i8042.zig`](../src/drv/input/i8042.zig)) with scancode set 1 decoding, the kernel input core ([`input.zig`](../src/kernel/input.zig)), and keymaps compiled from one file per layout ([`src/keymaps/`](../src/keymaps/)): US-International and Belgian AZERTY, with dead-key composition and `Super+Space` to switch.
>
> Not yet: the touchpad probe ladder, `/dev/input`, and the ATKD hotkeys.
>
> Where this document and [`00-vibeee.md`](00-vibeee.md) disagree, the master design
> wins: it carries later decisions this document predates.

Status: implementation-ready design. Target: ASUS Eee PC 701 4G only.
Scope: i8042 controller, PS/2 keyboard (set-2 decode, keycodes), touchpad
(Synaptics/Elantech/bare-PS/2 probe ladder), kernel input core + /dev/input,
ACPI hotkey injection, USB HID injection from usbd, and the layered keymap
system (US-International default + Belgian AZERTY, dead keys, AltGr, compose).

## 1. Overview

Split of responsibilities (follows the locked hybrid architecture):

- **Kernel (in-kernel drivers)**: i8042 controller, keyboard scancode→keycode
  decode, touchpad protocol decode + gesture reduction to REL events, input
  core (per-reader queues, timestamping, merged `/dev/input` stream), ACPI
  hotkey→event bridge (fed by the in-kernel ACPI/EC platform code).
- **GUI server (userspace, single `/dev/input` reader)**: the **keymap engine**
  (`libkeymap`, a plain static library), keycode+modifiers → symbol → dead-key
  /compose state machine → UTF-8 text; layout switching (Super+Space), key
  repeat synthesis, status-bar layout/lock indicators, LED control via ioctl.
- **usbd (userspace)**: HID report parsing; injects keycode/REL events into the
  kernel input core through a privileged injector handle. External keyboards
  therefore pass through the *same* keymap engine, layouts apply equally.

Kernel delivers **keycodes, never symbols**. All layout knowledge lives in one
place, in userspace, in data tables generated at build time from readable
`.kmap` source files.

## 2. Hardware facts used (research citations)

| Fact | Source / confidence |
|---|---|
| i8042 function provided by ENE KB3310 EC on LPC; ports 0x60/0x64, IRQ1 (kbd) / IRQ12 (aux) | core-platform §8, peripherals §7 [HIGH] |
| 80-key keyboard, "AT set 2", no bring-up quirks reported | peripherals §7, quirks §8 [HIGH] |
| Fn navigation combos emit ordinary scancodes; media/system Fn combos arrive as ACPI Notify on ASUS010/ATKD, NOT scancodes | peripherals §7, quirks §1 [HIGH/MEDIUM-HIGH] |
| Fn+F11 = NumLock overlay (user manual) | quirks §1 [HIGH]; overlay mechanism (EC-side remap vs not) UNVERIFIED, designed for both |
| Touchpad: Synaptics on some 701 4G units (dmesg "SynPS/2"), Elantech ("ETPS/2", v1 fw EF013 class) on others, probe both | peripherals §6 [HIGH/LOW-MEDIUM], quirks §8 [MEDIUM-HIGH] |
| Elantech v1: detect F5,E6,E6,E6,E9 → 3C 03 C8/00; fw<0x020030 or ==0x020600 ⇒ v1; reg_10=0x16, reg_11=0x8f; 4-byte packets, X 32–544, Y 32–352; EF013/EF019 discard first 2 reports | Linux elantech.c/h v6.6 + kernel docs (verified via WebFetch this session) |
| ATKD hotkey codes 0x10/0x11 wifi, 0x12 prog1, 0x13/14/15 mute/vol-, vol+, 0x16 disp-off, 0x20–0x2f brightness (fw already applied), 0x30–0x32 display switch, 0x50/0x51 AC | quirks §1 [HIGH] |
| Fn+F1 sleep arrives as ACPI SLPB, not ATKD | quirks §1 [MEDIUM] |
| No dedicated keyboard lock LEDs on chassis (LEDs: power/battery/disk/wifi) | quirks §9 [MEDIUM]: 0xED still sent, harmless |
| Timestamps must not use TSC (halts in C3); use kernel monotonic (PM timer/HPET) | core-platform §6 [HIGH] |
| IOAPIC GSI 1 and 12 for i8042 | core-platform §6 [HIGH] |
| User types QWERTY on Belgian-keycap hardware → US-Intl default, BE-AZERTY selectable | design brief (locked) |

## 3. Architecture

```
 EC(KB3310 i8042) --IRQ1/IRQ12--> [i8042 drv] --bytes--> [kbd set2 decoder] --keycodes--+
                                        |                [tp protocol+gesture] --REL----+
 ACPI SCI -> platform svc (kernel) --ATKD codes--> [hotkey bridge] --EV_HOTKEY/EV_SW---+--> [input core]
 usbd (user) --input_inject()---------------------------------------------------------+       |
                                                                                   /dev/input (single stream)
                                                                                              |
                                                                                        GUI server
                                                                              [libkeymap: mods->sym->dead/compose]
                                                                              [repeat synth] [Super+Space switch]
                                                                                              |
                                                                            window events {keycode,mods,sym,text}
                                                                                              |
                                                                                        libeui apps
```

## 4. Kernel input core

### 4.1 Event model (contract v0 `input_event`, 16 B)

```zig
pub const InputEvent = extern struct { t_us: u64, type: u16, code: u16, value: i32 };

pub const EV_SYN: u16 = 0;      // code: SYN_REPORT=0, SYN_DROPPED=3
pub const EV_KEY: u16 = 1;      // code: keycode (Linux input-event-codes numbering)
                                //       or BTN_LEFT=0x110, BTN_RIGHT=0x111, BTN_MIDDLE=0x112
                                // value: 0=release, 1=press          (no value=2: repeat is GUI-side)
pub const EV_REL: u16 = 2;      // code: REL_X=0, REL_Y=1, REL_WHEEL=8, REL_HWHEEL=6; value: delta
pub const EV_SW:  u16 = 5;      // code: SW_LID=0; value: 1=closed
pub const EV_HOTKEY: u16 = 6;   // code: HK_*; value: aux data (e.g. brightness level) or 1
pub const EV_DEVICE: u16 = 7;   // code: device id; emitted when the source device changes in-stream
```

Keycode space = Linux `input-event-codes.h` numeric values (KEY_A=30, …,
KEY_102ND=86, KEY_LEFTMETA=125). Rationale: lets us lift the battle-tested
set-2 and HID-usage translation tables verbatim, and existing tooling/docs
apply. Only the subset present on this machine + common external HID is
compiled in (codes < 768).

### 4.2 Structures and API

```zig
pub const DeviceClass = enum(u8) { keyboard, pointer, hotkey, switches };
pub const InputDeviceDesc = extern struct {
    name: [32]u8, class: DeviceClass, bus: enum(u8){ ps2, acpi, usb },
    vendor: u16, product: u16,
};

// in-kernel producer API
pub fn registerDevice(desc: *const InputDeviceDesc) DeviceId;
pub fn post(dev: DeviceId, type_: u16, code: u16, value: i32) void; // stamps t_us = monotonic_us()
pub fn postSyn(dev: DeviceId) void;                                 // SYN_REPORT batch terminator

// reader side: /dev/input is a file handle (VFS char device) + waitable event
// read(): returns whole events only (multiples of 16 B), non-blocking; pair with wait on the handle's event
pub const InputIoctl = enum(u32) {
    get_key_state,   // out: [96]u8 bitmap of currently-down keycodes (authoritative, for SYN_DROPPED resync)
    set_leds,        // in: u8 {bit0 scroll, bit1 num, bit2 caps} -> i8042 kbd 0xED
    get_devices,     // out: []InputDeviceDesc + ids
    set_tp_conf,     // in: TouchpadConf (tap, edge scroll, divisors): GUI pushes /cfg values at start
    dump_raw,        // debug builds: tee raw i8042 byte stream (test seam, §12)
};
```

### 4.3 Queues, timestamps, overflow

- Per-reader ring: **512 events × 16 B = 8 KB**, allocated at open. Expected
  readers: GUI server (always) + at most one debug client.
- Timestamp: `monotonic_us()` (PM-timer/HPET-backed kernel clock: TSC is
  unsafe in C3, core-platform §6) captured **in the ISR**, before decode, so
  queue latency doesn't skew inter-key timing used by tap detection and repeat.
- Overflow policy: ring full ⇒ clear the ring, enqueue
  `{EV_SYN, SYN_DROPPED}`. Reader must then `get_key_state` and reconcile:
  synthesize releases for keys no longer down, presses for new ones. Pointer
  deltas and hotkeys lost in the window are accepted losses. Rationale: a
  partially dropped stream can wedge a key "down" forever; a forced resync
  cannot. 512 entries ≈ several seconds of worst-case typing+pointer traffic,
  so drops occur only if the GUI stalls.
- Key-state bitmap is maintained in the core (on every EV_KEY), not in drivers,
  so it covers PS/2 and injected USB events uniformly. It also dedupes: a make
  for an already-down key (PS/2 typematic) is **discarded** (see §6.4).

## 5. i8042 driver

### 5.1 Design points

- **Translation OFF, scancode set 2.** Justification: (1) set 2 is the
  keyboard's power-on default, zero mode-set commands, fewest failure modes on
  the KB3310's i8042 emulation; (2) unambiguous break protocol (`F0` prefix)
  instead of set-1 bit-7, one clean decode table; (3) the AUX port is never
  translated, so with translation on we'd maintain *two* scancode dialects and
  trust the KBC to keep them straight while bytes from both ports interleave,
  known-buggy territory on EC-based controllers; (4) translation is a lossy
  extra mapping we would immediately invert anyway.
- **No MUX.** Active-multiplexing discovery (0xD3 version dance) is skipped
  entirely: exactly one AUX device exists on this machine, and MUX probing is a
  classic way to confuse EC keyboard controllers.
- Init runs **polled** (IRQs not yet unmasked); runtime commands go through a
  serialized command engine fed response bytes by the ISR (libps2 style).

### 5.2 Register-level init sequence

Ports: 0x60 data, 0x64 status/command. Status bits: OBF=bit0, IBF=bit1,
AUX=bit5 (byte in 0x60 came from AUX). All writes wait `IBF==0` (poll every
50 µs, timeout 20 ms); all expected reads wait `OBF==1` (same poll, timeout
noted per step).

```
 1. Drain: while OBF: inb(0x60)                      (max 16 iterations)
 2. outb(0x64,0xAD); outb(0x64,0xA7)                 disable kbd + aux ports
 3. Drain again (disabling can push a byte)
 4. outb(0x64,0x20); ccb = read60()                  read command byte
 5. outb(0x64,0xAA); expect 0x55                     controller self-test (timeout 500 ms: EC may be slow)
    NOTE: self-test resets some controllers -> ccb is rewritten in step 8 regardless
 6. outb(0x64,0xAB); expect 0x00                     kbd interface test (nonzero: log, continue, kbd may still work)
 7. outb(0x64,0xA9); expect 0x00                     aux interface test (nonzero: mark no-touchpad, skip §7)
 8. ccb = (ccb | 0x01|0x02|0x04) & ~(0x40|0x10|0x20) enable IRQ1+IRQ12+sysflag; clear XLATE, port disables
    outb(0x64,0x60); outb(0x60,ccb)
 9. outb(0x64,0xAE); outb(0x64,0xA8)                 enable both ports
10. Keyboard: send 0xFF -> expect 0xFA then 0xAA     reset+BAT (timeout 700 ms for BAT)
11. Keyboard config:
      F0 02            select scancode set 2 (explicit, though it is the default)
      F0 00 -> read    verify: response 0x02 means set 2 untranslated. If 0x41 appears,
                       XLATE is stuck on (EC quirk) -> rewrite ccb, re-verify, else fall back
                       to a set-1 decode table (compile-time present, runtime-selected; see Risks)
      ED 00            LEDs off (harmless if none fitted)
      F3 7F            typematic: 1 s delay, 2 cps (slowest, repeats are suppressed anyway, §6.4)
      F4               enable scanning
12. AUX (all AUX bytes via outb(0x64,0xD4) prefix): probe ladder, §7.
13. Unmask IOAPIC GSI1 + GSI12 (edge, active-high ISA), attach ISR; switch command engine to IRQ mode.
```

Device-command engine: every device byte expects `0xFA` (ACK); on `0xFE`
(resend) retry ≤3; on `0xFC` mark device failed and schedule re-probe. Retries
exhausted ⇒ watchdog path.

### 5.3 ISR (shared logic for IRQ1/IRQ12)

```
status = inb(0x64); while (status & OBF):
    byte = inb(0x60); from_aux = status & 0x20     // attribute by STATUS BIT, never by IRQ number
    t = monotonic_us()
    if cmd_engine.in_flight(port): cmd_engine.feed(port, byte)   // 0xFA/0xFE/response bytes
    else if from_aux: tp.feed(byte, t) else kbd.feed(byte, t)
    status = inb(0x64)
```

### 5.4 Watchdog & reset tolerance (no hotplug, but EC glitches happen)

- **Wedge detection**: (a) IBF stuck >100 ms on any write; (b) command
  timeouts twice in a row; (c) >16 consecutive protocol-invalid bytes from the
  keyboard stream. Any of these ⇒ `i8042_reinit()`: full §5.2 sequence, then
  restore soft state (LEDs from GUI-held lock state, typematic, touchpad mode).
  Bounded: 3 reinit attempts / 10 s, then mark port dead + log (machine still
  usable via USB keyboard through usbd).
- **Spontaneous 0xAA** in the keyboard stream (outside a commanded reset, with
  no F0 pending): keyboard/EC rebooted (brownout) ⇒ silently re-run step 11.
- **Spontaneous 0xAA 0x00** on AUX: touchpad announced itself after reset ⇒
  re-run the probe ladder (§7). This also covers resume from S3.
- **Suspend/resume**: on S3 entry, send 0xAD/0xA7 and mask GSIs; on resume run
  the full init. Keymap/lock state lives in the GUI server and survives; kernel
  replays LED state via the stored last `set_leds` value.
- No periodic polling in steady state, the watchdog is purely event-driven
  (a periodic prod would generate constant EC traffic for nothing).

## 6. Keyboard driver (set-2 decode)

### 6.1 Decode state machine

States: `base`, `e0`, `f0`, `e0_f0`, `e1_seq(n)`. Rules:

- `F0` ⇒ break prefix; `E0` ⇒ extended; `E1` ⇒ Pause sequence
  (`E1 14 77` make / `E1 F0 14 F0 77` break) matched literally, emits
  KEY_PAUSE.
- **Fake shifts dropped**: `E0 12` / `E0 F0 12` and `E0 59` / `E0 F0 59`
  (emitted by some firmware around PrtSc/nav keys) are swallowed in the `e0`
  states.
- Valid make codes are ≤ 0x84 (0x83 = F7 is the famous outlier; table sized
  0x90). Any other non-prefix byte ≥ 0x85 (that isn't FA/FE/FC/AA/EE handled
  by the command engine / watchdog) ⇒ clear prefix state, count as invalid
  (feeds watchdog rule (c)).

### 6.2 Scancode→keycode tables (generated; authoritative content)

Base table (set 2, no prefix), full list compiled from this map:

```
76 ESC   05 F1  06 F2  04 F3  0C F4  03 F5  0B F6  83 F7  0A F8  01 F9  09 F10  78 F11  07 F12
0E GRAVE 16 1   1E 2   26 3   25 4   2E 5   36 6   3D 7   3E 8   46 9   45 0    4E MINUS 55 EQUAL 66 BKSP
0D TAB   15 Q   1D W   24 E   2D R   2C T   35 Y   3C U   43 I   44 O   4D P    54 LBRACE 5B RBRACE 5D BACKSLASH
58 CAPS  1C A   1B S   23 D   2B F   34 G   33 H   3B J   42 K   4B L   4C SEMI 52 APOS   5A ENTER
12 LSHIFT 61 102ND 1A Z 22 X  21 C   2A V   32 B   31 N   3A M   41 COMMA 49 DOT 4A SLASH 59 RSHIFT
14 LCTRL 11 LALT 29 SPACE
77 NUMLOCK 7E SCROLLLOCK
6C KP7  75 KP8  7D KP9  7B KPMINUS  6B KP4  73 KP5  74 KP6  79 KPPLUS
69 KP1  72 KP2  7A KP3  70 KP0  71 KPDOT  7C KPASTERISK
```

E0 table:

```
E0 11 RALT   E0 14 RCTRL  E0 1F LMETA  E0 27 RMETA  E0 2F COMPOSE(menu)
E0 75 UP     E0 72 DOWN   E0 6B LEFT   E0 74 RIGHT
E0 6C HOME   E0 69 END    E0 7D PGUP   E0 7A PGDN   E0 70 INSERT  E0 71 DELETE
E0 5A KPENTER  E0 4A KPSLASH  E0 12/E0 7C PRTSC(pair -> KEY_SYSRQ)
```

The 701's 80-key board reaches HOME/END/PGUP/PGDN/INS/DEL through Fn+arrow/
punctuation combos, but per research these arrive as the ordinary E0 codes
above, no special handling. The Belgian-keycap unit is an ISO board: scancode
`0x61` (KEY_102ND, the `<>` key left of Z) is expected present; the table
carries it either way.

### 6.3 Fn+F11 NumLock overlay

Fn+F11 emits set-2 `0x77` (NumLock). Two possible EC behaviors, both handled:

- **Hypothesis A (typical EC design)**: the EC latches its own overlay flag
  and, while active, the 7 8 9 0 U I O P J K L ; M keys emit *numpad*
  scancodes (KP7/KP8/… codes above). Our decoder passes KP keycodes through;
  the keymap engine resolves them by its NumLock state (digit vs nav symbol).
- **Hypothesis B**: EC only sends 0x77 and never remaps; overlay keys keep
  their letter codes. Then Fn+F11 just toggles the (indicator-only) NumLock
  state; no wrong characters ever appear. Optionally (config
  `soft_numlock_overlay=on`) the keymap engine applies the overlay itself:
  when NumLock is on, keycodes U/I/O/J/K/L/M/7/8/9/0 map to KP equivalents
  before layout lookup.

An M1 hardware test logs raw scancodes with the overlay active to pick the
truth (see §12); the design works unmodified under both.

### 6.4 Key repeat: GUI-side (decision)

**Repeat is synthesized in the GUI server**, post-translation. Kernel drops
PS/2 typematic repeats (make for an already-down key, §4.3) and sets the
slowest hardware rate as belt-and-braces. Why GUI-side: (1) USB HID keyboards
do not auto-repeat, the host must synthesize, so *some* software repeater
must exist; having exactly one, covering PS/2+USB+all layouts identically, is
the simplest correct design; (2) repeat policy is a UI preference
(delay/rate from `/cfg/input.conf`, no kernel round-trip); (3) what repeats is
the *translated* symbol, dead keys, modifiers, and lock keys must not repeat,
which only the keymap engine knows. Defaults: 400 ms delay, 25 Hz. Repeat is
cancelled by release, focus change, or layout switch.

### 6.5 LEDs

GUI server owns lock state (Caps/Num) → `ioctl(set_leds)` → kernel sends
`ED xx`. The chassis likely has no kbd LEDs (quirks §9): the *real* indicator
is the GUI status bar (§10.7); 0xED is still sent for external USB keyboards…
which usbd handles via HID SetReport, the GUI issues the same abstract
"locks changed" to usbd over its control channel (OPEN item for usbd design).

## 7. Touchpad

### 7.1 Probe ladder (all bytes via 0xD4 prefix; ACK handling per §5.2)

```
0. FF -> FA, AA, 00                       reset; remember "default PS/2 mouse present"
1. SYNAPTICS identify: E8 00 E8 00 E8 00 E8 00, E9 -> r[3]
     r[1]==0x47 ?  minor=r[0], major=r[2]&0x0F  -> Synaptics (§7.2)
2. ELANTECH knock:   F5, E6, E6, E6, E9 -> r[3]
     r == {3C, 03, C8} or {3C, 03, 00}  -> Elantech (§7.3)
3. BARE PS/2 fallback: IntelliMouse probe F3 C8, F3 64, F3 50, F2 -> id
     id==0x03 ? 4-byte wheel packets : 3-byte; then E8 02, F3 64, F4   (§7.4)
```

Query/sliced encoding (both vendors use it): to "send" query byte X:
`E8 (X>>6)&3, E8 (X>>4)&3, E8 (X>>2)&3, E8 X&3` then the trigger command
(`E9` = read 3-byte response; Elantech register ops differ, below).

### 7.2 Synaptics absolute mode

Init:
```
caps    : sliced(0x02), E9 -> capExtended=r[0]&0x80, capPalm/capMultiFinger bits in r[2]
modelID : sliced(0x03), E9                       (logged only)
mode set: sliced(0xC1), F3 14                    mode 0xC1 = Absolute|HighRate(80pps)|W-mode
          (0xC0 if W unsupported per caps)
enable  : F4
```
6-byte packet (W-mode):
```
b0: 1  0  W3 W2 0 W1 R  L        b3: 1  1  Y12 X12 0 W0 R  L
b1: Y11..Y8 X11..X8              b4: X7..X0
b2: Z7..Z0                       b5: Y7..Y0
x = b3.4<<12 | (b1&0x0F)<<8 | b4     y = b3.5<<12 | (b1>>4)<<8 | b5   (Y origin BOTTOM, invert)
z = b2                                w = (b0&0x30)>>2 | (b0&0x04)>>1 | (b3&0x04)>>2
```
Sync rule: `(b0 & 0xC8) == 0x80` and `(b3 & 0xC8) == 0xC0`; violation ⇒ drop
bytes until a valid b0 pattern (resync), count for watchdog. Typical ranges
X 1472–5472, Y 1408–4448 (defaults; refined via extended queries when
capExtended). Interpretation: Z≥25 finger down; W 4–7 normal finger, **W≥10 ⇒
palm** (suppress until release); W=0/1 ⇒ 2/3 fingers (v1 GUI ignores).

### 7.3 Elantech v1 (verified against Linux elantech.c v6.6)

```
fw ver : sliced(0x01), E9 -> fw = r[0]<<16|r[1]<<8|r[2];  v1 iff fw < 0x020030 or fw == 0x020600
reg wr : sliced(0x11), sliced(reg), sliced(val), E6      (E6 = commit)
init   : reg[0x10] = 0x16   (absolute mode | disable dyn-res | smart-edge-drag)
         reg[0x11] = 0x8f   (native 4-byte packets | parity check | vert scroll area)
enable : F4
```
4-byte packet (fw 1.x/2.x era, EF013 class):
```
b0: D U p1 p2 1 p3 R L      (fw>=0x020000: p1=bit4, p2=bit5, swapped vs older)
b1: f 0 th tw x9 x8 y9 y8   f=finger, tw/th=2/3-finger
b2: x7..x0                  X range 32..544
b3: y7..y0                  Y range 32..352 (origin bottom, invert)
```
Parity: p1..p3 = odd parity of b1..b3; mismatch ⇒ drop packet, resync.
Quirk (EF013/EF019): after finger-down, **discard the first 2 position
reports** (firmware bug). D/U rocker bits ⇒ REL_WHEEL ±1.

### 7.4 Bare PS/2 fallback

Standard 3-byte (or 4-byte IntelliMouse) relative packets: b0 sync bit3=1,
overflow bits dropped; passes straight to REL events. This path also serves
QEMU.

### 7.5 Gesture layer (kernel, shared; output = REL pointer + scroll)

Both absolute protocols reduce to `AbsSample{x,y,z_or_f,w,buttons}` then:

- **Motion**: `REL_X/REL_Y = (pos - prev) / divisor` (Synaptics 8, Elantech 2,
  normalizes the ~10× range difference), simple 2-tap smoothing; no delta on
  the first sample of a touch.
- **Tap-to-click**: touch duration <150 ms ∧ total motion <20 abs units ⇒
  BTN_LEFT press, release synthesized 30 ms later. (Tap-drag: M3.)
- **Edge scroll**: touch beginning in the right 13% band ⇒ motion becomes
  REL_WHEEL (1 tick / 30 units of Y); bottom band ⇒ REL_HWHEEL (default off).
- **Palm rejection**: Synaptics W≥10 (or Z≥200 with W≥8) ⇒ ignore touch until
  release. Elantech v1 has no width: substitute a jump filter (>120 units
  between consecutive samples ⇒ drop sample), basics only.
- Physical buttons pass through as BTN_LEFT/BTN_RIGHT.
- All thresholds live in `TouchpadConf`, pushed by GUI via `set_tp_conf` from
  `/cfg/input.conf` (`tap_to_click`, `edge_scroll`, `accel_div`, …).

## 8. ACPI hotkey integration

The in-kernel ACPI/EC platform code handles the SCI, runs `_Qxx`/Notify
handling, and calls `input.post()` on a registered `hotkey0` device.
Mapping table (ATKD code → event):

| ATKD | Event posted | Notes |
|---|---|---|
| 0x10, 0x11 | EV_HOTKEY HK_WIFI (value 1/0) | GUI orchestrates: notify netd detach → platform WLDS, slot power-gates! |
| 0x12 | EV_HOTKEY HK_PROG1 | Fn+F6 "Task Manager" → GUI task switcher |
| 0x13 / 0x14 / 0x15 | EV_HOTKEY HK_MUTE / HK_VOL_DOWN / HK_VOL_UP | GUI → sndd mixer + OSD |
| 0x16 | EV_HOTKEY HK_DISPLAY_OFF | GUI blanks via display ioctl |
| 0x20–0x2f | EV_HOTKEY HK_BRIGHTNESS, value = code&0x0F (0–15) | firmware already applied; OSD only |
| 0x30–0x32 | EV_HOTKEY HK_DISPLAY_SWITCH, value = code&0x0F | Fn+F5 LCD/VGA: GUI → display driver |
| 0x50 / 0x51 | not posted | AC plug/unplug → power mgmt path, not input |
| ACPI SLPB | EV_HOTKEY HK_SLEEP | Fn+F1 |
| ACPI LID | EV_SW SW_LID value 0/1 | |

`HK_*` are u16 codes in our own namespace (`HK_WIFI=1 … HK_SLEEP=8`).
Unknown ATKD codes are posted as `HK_UNKNOWN` with value=code (forward compat,
and the M1 hardware survey uses it).

## 9. USB HID injection (usbd → input core)

```zig
// privileged (driver-server) syscalls
pub fn input_publish(desc: *const InputDeviceDesc) InputInjectorHandle; // class keyboard|pointer
pub fn input_inject(h: InputInjectorHandle, evs: []const InputEvent) usize;
pub fn input_unpublish(h: InputInjectorHandle) void;                    // device unplugged
```

Rules enforced by the kernel: `t_us==0` ⇒ kernel stamps (usbd normally passes
0; a nonzero past stamp ≤ now is kept for latency-accurate HID interrupt
timing); EV types whitelisted per device class; keycodes <768; rate limit 4096
events/s per injector (excess dropped + counted). usbd translates HID boot
protocol / report descriptors: usage page 0x07 → Linux keycode via the
standard 256-entry table (same numeric space as §4.1, table shared in
`libinputdefs`), usage page 0x09 buttons → BTN_*, X/Y/wheel → REL_*. usbd
maintains per-device key state and emits only transitions (so no repeat
suppression needed kernel-side). On unpublish, the input core synthesizes
releases for that device's held keys. Because injection is keycode-level, the
GUI keymap engine treats external keyboards identically, **layouts apply
equally**, satisfying the requirement with zero extra code.

## 10. Keymap system

### 10.1 Layers and placement

```
scancode --(kernel, fixed table §6.2)--> keycode
keycode + modifier/lock state --(layout table)--> symbol (char | dead(d) | func)
symbol --(dead-key/compose state machine)--> committed text (UTF-8) + key events
```

**The symbol and compose layers run in the GUI server** (via `libkeymap`, a
freestanding static library also linked by tests and the emergency console).
Why not libeui/per-app: dead-key and lock state are *global, singular* state,
per-app copies desynchronize (half-composed `´` in one window, stale layout in
another), the layout-switch hotkey and the status-bar indicator are
compositor-level concerns, and focus changes must atomically cancel pending
dead state. Why not kernel: tables+Unicode+compose have no business in ring 0,
and userspace restart/reload of layouts is free. Apps receive finished events:

```zig
pub const KeyEvent = extern struct {   // GUI-server -> app window event
    keycode: u16, mods: u16,           // raw level: games/shortcuts
    sym: u32,                          // resolved symbol (KeySym encoding §10.3)
    text: [8]u8, text_len: u8,         // committed UTF-8 (0 if none, e.g. dead key pressed)
    pressed: bool, repeat: bool,
};
```

### 10.2 Modifier model

`mods` bits: SHIFT=1, CTRL=2, ALT=4, ALTGR=8, SUPER=16; locks CAPS=256,
NUM=512. RightAlt (KEY_RIGHTALT) *is* AltGr in both shipped layouts (flag in
layout header). Level = `(altgr?2:0) + (shift_eff?1:0)` → 4 levels: base,
shift, altgr, shift+altgr. `shift_eff = shift XOR (caps && key.flags.alpha)`.
NumLock resolves KP keycodes (digit vs nav) before layout lookup: KP handling
is layout-independent engine logic.

### 10.3 KeySym encoding & compiled tables

```zig
pub const KeySym = u32;                 // 0 = none/transparent
// kind = sym >> 24:  1 = char (bits 20:0 Unicode codepoint)
//                    2 = dead (low byte = DeadId)
//                    3 = func (low 16 bits = keycode it mirrors: F1, Left, …)
pub const DeadId = enum(u8) { acute, grave, circumflex, diaeresis, tilde, cedilla };

pub const Layout = struct {
    name: []const u8, display: []const u8,   // "us_intl", "US-Intl"
    right_alt_is_altgr: bool,
    syms: [256][4]KeySym,                    // [keycode][level]
    flags: [256]u8,                          // bit0 alpha (capslockable)
    dead: []const DeadEntry,                 // sorted by (dead, base), binary search
};
pub const DeadEntry = struct { dead: DeadId, base: u21, out: u21 };
pub const ComposeEntry = struct { seq: [4]u21, len: u8, out: u21 };  // global, shared, sorted

pub const Engine = struct {
    layouts: []const *const Layout, active: u8,
    mods: u16, pending_dead: ?DeadId, compose_buf: [4]u21, compose_len: u8,
    pub fn feed(self: *Engine, keycode: u16, pressed: bool) FeedResult;
    pub fn switchLayout(self: *Engine, idx: u8) void;   // clears pending state
    pub fn reset(self: *Engine) void;                   // focus change
};
pub const FeedResult = struct { ev: KeyEvent, locks_changed: bool };
```

### 10.4 Dead-key / compose state machine

```
            +--------------------- any: Esc / focus change / layout switch -> discard, IDLE
            v
  [IDLE] --sym==dead(d)--------> [DEAD d]
  [IDLE] --sym==ComposeKey-----> [COMPOSE seq=[]]
  [IDLE] --char c--------------> emit c
  [DEAD d] --char c, (d,c) in dead table--> emit combined; IDLE
  [DEAD d] --space-------------> emit spacing accent of d (´ ` ^ ¨ ~ ¸); IDLE
  [DEAD d] --dead(d) again-----> emit spacing accent; IDLE
  [DEAD d] --dead(e)≠d---------> emit spacing(d); goto DEAD e
  [DEAD d] --char c, no entry--> emit spacing(d) THEN c; IDLE      (xkb-compatible fallback)
  [DEAD d] --func/modifier-----> stay (modifiers don't break composition)
  [COMPOSE seq] --char c, seq+c prefix of table--> COMPOSE seq+c
  [COMPOSE seq] --char c, seq+c complete--------> emit result; IDLE
  [COMPOSE seq] --char c, no prefix-------------> discard silently; IDLE
```

Dead keys and modifiers produce a `KeyEvent` with `text_len=0` (apps still see
the keypress for shortcut purposes; `sym` marks it dead). ComposeKey default
binding: the Menu key (`E0 2F`) and Shift+AltGr; configurable.

### 10.5 Source format (`.kmap`) and build pipeline

`tools/kmapc.zig` (host build, run by Make) parses `.kmap` → generates
`gen/keymap_<name>.zig` const tables; `zig test` validates round-trips.
Adding a layout = drop a file in `keymaps/`, add one line to the Makefile
list. A versioned binary format (`.kmc`) is reserved for future runtime
loading; v1 compiles layouts in (2 layouts ≈ 10 KB, not worth a loader).

Format: `#` comments; `key <KEYCODE> : L1 L2 L3 L4` (levels base/shift/altgr/
shift+altgr; `--` = transparent/none); symbols are literal UTF-8 chars,
`U+XXXX`, named specials (`space`, `nbsp`), `dead(<id>)`, or `fn(<KEY>)`;
`alpha` flag marks capslockable keys.

**US-International** (excerpt, `keymaps/us_intl.kmap`), dead keys + AltGr,
covering é ü ñ €:

```
layout us_intl  display "US-Intl"  altgr right_alt
key A     alpha : a A á Á
key E     alpha : e E é É          # AltGr+e = é
key Y     alpha : y Y ü Ü          # AltGr+y = ü
key N     alpha : n N ñ Ñ          # AltGr+n = ñ
key 5           : 5 % U+20AC --    # AltGr+5 = €
key APOSTROPHE  : dead(acute) dead(diaeresis) ' "
key GRAVE       : dead(grave) dead(tilde) ` ~
key 6           : 6 dead(circumflex) -- --
key COMMA alpha : , < ç Ç
deadkey acute      { a á  e é  i í  o ó  u ú  y ý  c ć  space ' }
deadkey diaeresis  { a ä  e ë  i ï  o ö  u ü  y ÿ  space " }    # "+u = ü
deadkey tilde      { n ñ  a ã  o õ  space ~ }                   # ~+n = ñ
deadkey grave      { a à  e è  i ì  o ò  u ù  space ` }
deadkey circumflex { a â  e ê  i î  o ô  u û  space ^ }
```

**Belgian AZERTY** (excerpt, `keymaps/be.kmap`), keycodes are *positional*
(US names); AltGr row covers @ # [ ]:

```
layout be  display "BE"  altgr right_alt
key Q     alpha : a A -- --        # physical top-left letter key
key A     alpha : q Q -- --
key W     alpha : z Z -- --
key Z     alpha : w W -- --
key SEMICOLON alpha : m M -- --
key M           : , ? -- --
key COMMA       : ; . -- --
key DOT         : : / -- --
key SLASH       : = + ~ --
key 1           : & 1 | --
key 2           : é 2 @ --         # AltGr+é = @
key 3           : " 3 # --         # AltGr+" = #
key 4           : ' 4 -- --
key 9           : ç 9 { --
key 0           : à 0 } --
key MINUS       : ) ° -- --
key EQUAL       : - _ -- --
key LBRACE      : dead(circumflex) dead(diaeresis) [ --   # AltGr+^ = [
key RBRACE      : $ * ] --                                 # AltGr+$ = ]
key APOSTROPHE  : ù % dead(acute) --
key BACKSLASH   : µ £ dead(grave) --
key GRAVE       : ² ³ -- --
key 102ND       : < > \ --
key E     alpha : e E U+20AC --    # AltGr+e = €
deadkey circumflex { a â  e ê  i î  o ô  u û  space ^ }
deadkey diaeresis  { a ä  e ë  i ï  o ö  u ü  space " }
# acute/grave tables shared via: include "deadkeys_latin.kmapi"
```

Shared compose table `keymaps/compose.kmap`: `compose o e : œ`,
`compose e = : €`, `compose s s : ß`, … (~200 entries shipped).

### 10.6 Runtime switching

- Hotkey **Super+Space** intercepted by the GUI server *before* app dispatch:
  cycles `layouts[]`, calls `Engine.switchLayout` (clears dead/compose state,
  cancels repeat), fires an internal `LayoutChanged{idx,name}` notification.
- Default from `/cfg/input.conf` (`layout=us_intl`, `layouts=us_intl,be`).
- **Status-bar hook**: the GUI status bar subscribes to `LayoutChanged` +
  `LocksChanged` and renders "US"/"BE" + caps/num glyphs; external clients can
  query current layout via the GUI server's `/svc/gui.input` control channel
  (`get_layout`, `set_layout(idx)`, also how a settings app switches).

## 11. RAM / disk budget (subsystem share)

| Item | Disk (in parent budget) | RAM |
|---|---|---|
| Kernel: i8042+kbd decode+tables | ~6 KB (kernel ELF) | ~1 KB state |
| Kernel: touchpad (2 protocols + gestures) | ~7 KB | ~0.5 KB |
| Kernel: input core + hotkey bridge | ~4 KB | 2 readers × 8 KB ring + 0.5 KB = ~17 KB |
| GUI: libkeymap engine | ~8 KB (GUI ELF) | ~0.3 KB state |
| GUI: 2 layout tables + dead + compose | ~14 KB | (tables in .rodata, counted once) |
| usbd: HID usage tables (shared libinputdefs) | ~2 KB |, |
| **Total** | **~41 KB** | **~20 KB** |

Well inside budgets (kernel ≤1.5 MB ELF, GUI ≤2.5 MB, idle RAM ≤48 MB).
Event bandwidth worst case (typematic burst + touchpad 80 pps): <10 KB/s,
memory-bandwidth irrelevant.

## 12. Bring-up & test plan

**Host unit tests (no target needed)**, the bulk of correctness:
- `libkeymap` is target-independent: `zig test` corpus, table-driven
  `(keycode,mods,press)* → expected KeyEvents`. Mandatory cases:
  dead-acute+e→é, dead-diaeresis+u→ü, dead-tilde+n→ñ, AltGr+5→€ (US-Intl);
  AltGr on 2/3/LBRACE/RBRACE→@ # [ ] (BE); dead+space→spacing accent;
  dead+q(no entry)→"´q"; dead+dead same/different; dead state killed by
  focus-reset and by Super+Space; caps vs shift on alpha and non-alpha
  (BE `é` key with caps must NOT give É, caps only affects `alpha` keys
  and shift gives 2); NumLock overlay both hypotheses; compose oe→œ; repeat
  suppression of modifiers/dead keys; SYN_DROPPED resync reconciliation.
- i8042 driver compiled against a comptime-injected port-I/O vtable
  (`Io{inb,outb}`): a scripted KBC model replays init happy path, self-test
  timeout, 0xFE resend storms, stuck IBF (watchdog fires), spontaneous 0xAA,
  translation-stuck (F0 00 returns 0x41) fallback.
- Touchpad decoders fed recorded byte corpora (see hardware seam below):
  sync-loss injection, Elantech parity failures, EF013 first-2-report bug,
  palm/tap/edge-scroll golden traces.

**QEMU** (`qemu-system-i386 -M pc`): i8042 emulation is good, validates the
full init dance with translation off, set-2 decode, IRQ routing via IOAPIC,
dual-port interleave, bare-PS/2 pointer path (QEMU mouse), /dev/input
delivery, GUI translation end-to-end (QEMU sends set-2 codes for host keys).
QEMU **cannot** exercise: Synaptics/Elantech absolute mode, the KB3310's
timing quirks, ATKD hotkeys, Fn overlay. Those need the seams:
- `ioctl(dump_raw)` (debug builds): tees raw i8042 bytes + timestamps to a
  file → collect corpora on real HW (touchpad packets, Fn+F11 scancodes,
  fake-shift patterns), replay in host tests forever after.
- `HK_UNKNOWN` passthrough → hotkey survey tool logs every ATKD code while
  pressing each Fn combo once.

**Real-hardware M1 checklist**: (1) init dance completes, log ccb before/
after; (2) F0 00 returns 0x02 (translation truly off on KB3310); (3) Fn+F11
scancode capture → resolve overlay hypothesis; (4) touchpad identity (0x47 vs
3C 03 C8), settles the Synaptics/Elantech uncertainty for this unit; (5) ATKD
code sweep; (6) 30-min soak typing+pointer with queue-depth/invalid-byte/
resync counters exported via a debugfs-style stats ioctl.

## 13. Risks & open questions

1. **Fn+F11 overlay mechanism unverified** (EC remap vs plain NumLock). Both
   handled (§6.3); only the soft-overlay default flips after M1 measurement.
2. **KB3310 may refuse translation-off or self-test oddly.** Mitigations:
   verify via `F0 00`; compile-time set-1 fallback table selected at runtime;
   watchdog reinit. Low residual risk.
3. **Touchpad vendor split** (research conflict): probe ladder makes it moot,
   but per-unit gesture tuning (ranges/thresholds) differs; defaults chosen
   per protocol, tunable via `/cfg`.
4. **Elantech variants other than v1** on late units: detection reports fw
   version; v2+ falls back to bare PS/2 (still a working pointer) in v1 of the
   OS; extend later if such a unit appears.
5. **LED path for USB keyboards** requires a GUI→usbd control op, interface
   to be pinned in usbd's design (locks-changed broadcast).
6. **Wifi hotkey ordering**: HK_WIFI → netd quiesce → WLDS power-gate needs a
   defined sequence with netd/platform (the slot hot-unplugs, quirks §3);
   input stack only delivers the event.
7. **Per-device layouts** (internal BE keycaps + external US keyboard
   simultaneously) not in v1, single global layout; EV_DEVICE markers exist,
   so the engine could key off device id later without protocol changes.
8. **Key ghosting/matrix limits** of the 18×8 EC matrix are unknown; nothing
   to design around, but the soak test logs anomalies.

## 14. Phasing

- **M1**: i8042 init + watchdog, set-2 decode + full keycode table, bare-PS/2
  pointer, input core + /dev/input + overflow/resync, libkeymap engine with
  US-Intl (dead keys + AltGr complete), GUI-side repeat, kmapc + host test
  corpus, QEMU green, real-HW checklist run (scancode/ATKD/touchpad-ID
  captures).
- **M2**: Synaptics + Elantech v1 absolute mode with tap/edge-scroll/palm,
  BE-AZERTY layout, Super+Space switching + status-bar indicator + /svc
  control channel, ACPI hotkey bridge with full mapping table, LED/lock
  plumbing, compose key + shared compose table, `/cfg/input.conf` plumbing.
- **M3**: USB HID injection via usbd (+ locks broadcast), tap-and-drag,
  suspend/resume hardening (S3 reinit path on real HW), corpora-driven
  regression suite frozen, optional `.kmc` runtime layout loading if a third
  layout materializes.

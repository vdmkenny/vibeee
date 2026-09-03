# 10: GUI: eeewm display server/compositor + libeui toolkit

> **Status: partially implemented.**
>
> Built and working: the tiling model ([`user/eeewm/layout.zig`](../src/user/eeewm/layout.zig)) with 4 tags, tall, wide and monocle, per-tag layout and mfact, floating exceptions and focus-follows-click; the status bar with tag pips, layout glyph, title and clock; keycode bindings; and `libeui` ([`user/eui/`](../src/user/eui/)) with a swappable theme, damage-driven painting and keyboard focus.
>
> Also built: the client protocol of §5 (control channel, per-client event ring, per-window shm surface), the launcher and session menu, and configuration from `/etc/eeewm.cfg`.
>
> Departures from this document, both deliberate: desktops are created on demand and shown as a taskbar of named tabs rather than four numbered pips, because a number says nothing about what is behind it; and clients are identified by the process id the kernel attests on `recv` rather than by the listener/accept semantics §5 assumed, which do not exist.
>
> Not yet: page flipping, vblank pacing and the hardware cursor, all of which need the GMA900 driver and are advertised through `DisplayInfo.caps`. No SSE2 blit kernels. Commit damage rectangles are carried but not yet honoured per window.
> Where this document and [`00-vibeee.md`](00-vibeee.md) disagree, the master design wins:
> it carries later decisions this document predates.

Status: design v1. Depends on: 04-graphics (display owner contract), 05-input (event stream),
06-platform/platformd (battery/temp/brightness/sleep), netd, sndd, usbd, 07-userspace (spawn, libc).
Cross-subsystem assumptions are tagged **[ASSUME→NN]** and repeated in "Open questions".

## 1. Overview

eeewm is a single userspace process that is simultaneously the display server, compositor, tiling
window manager, status bar, notification/OSD daemon, screen locker, and keymap engine. Clients are
libeui apps that render into their own shm surfaces (XRGB8888) and send damage; eeewm blits damaged
tiles to the framebuffer with SSE2, paced by the kernel vblank event. There is no drawing protocol:
the wire protocol is "here is my pixel buffer, these rects changed". This keeps the server ~dumb,
makes clients testable off-target (pure software rendering), and matches the machine: 630 MHz, no
GPU acceleration worth using on GMA 900 for 2D tile blits, ~1 GB/s theoretical memory bandwidth.

libeui is a comctl-style retained-mode widget library statically linked into each app. It owns
layout, painting, focus, text rendering (bitmap fonts), and the client side of the eeewm protocol.

Everything is keyboard-first at 800×480; the mouse/touchpad is supported but never required.

## 2. Hardware facts used (with research confidence)

| Fact | Use here | Confidence |
|---|---|---|
| 800×480@60.01 Hz LVDS panel, modeline 29.58 MHz | fixed logical resolution; 16.66 ms frame | HIGH |
| Panel is 6-bit+FRC (18-bit LVDS, dithered) | theme palette on exact 6-bit levels; no gradients | MEDIUM |
| 7" diagonal at 800×480 → ~133 DPI | metrics: 13 px UI font, 24 px controls | HIGH (arithmetic) |
| GMA 900, ~7932 KB stolen memory | room for 2 scanout buffers (2×1.47 MB) + cursor | HIGH |
| No HW accel assumptions; gen3 has a 64×64 ARGB HW cursor plane | optional hw-cursor fast path via 04-graphics caps | MEDIUM |
| SSE2 present, no SSE3; CLFLUSH; 64 B lines; 512 KB L2 | movntdq compositor kernels; 64 B damage alignment | HIGH |
| DRAM possibly DDR2-140 at stock (conflict vs DDR2-400) | budget with ~400 MB/s effective streaming; measure in M1 | conflict noted, LOW-MEDIUM |
| ACPI hotkey codes 0x10..0x2f/0x30 (ATKD) | hotkey policy table (volume/brightness/wifi OSD) | HIGH |
| Brightness PBLG/PBLS 0–15, EC applies Fn keys itself | OSD only shows level; platformd owns setting | HIGH |
| Battery reports percent mislabeled mAh | bar shows % directly; platformd normalizes | HIGH |
| Touchpad Synaptics OR Elantech (unresolved) | GUI uses only normalized rel motion + buttons + optional 2-finger scroll from 05-input | conflict noted |
| Keyboard: 80-key i8042, physical BE-AZERTY caps, Fn handled by EC | keycode-based WM bindings; US-Intl default map | HIGH |
| TSC halts in C3; PM timer/HPET are the stable clocks | eeewm uses kernel monotonic time only [ASSUME→01-core] | HIGH |

eeewm touches **no hardware registers directly**. All hardware access is via the 04-graphics owner
contract, 05-input event stream, and service IPC. The "register-level" section below therefore
covers the CPU-level hot paths (SSE2/WC discipline), which on this machine are the hardware.

## 3. Architecture

### 3.1 Process & privilege
- `eeewm` runs as a supervised userspace server (same supervision class as netd/sndd/usbd),
  registered in /svc as `"gui"`. It is the ONE display owner (04-graphics contract).
- It needs no pci/mmio/ioport grants, only: display-owner handle, input stream handle, channels
  to platformd/netd/sndd, /svc registration, timer, spawn (for the launcher's exec requests it
  proxies nothing, apps spawn apps; eeewm spawns only `erun` and the crash-toast helper).

### 3.2 Display path (contract with 04-graphics)
```zig
// Provided by 04-graphics to the single owner (shape assumed, [ASSUME→04]):
pub const DisplayInfo = extern struct {
    width: u16, height: u16, stride_px: u16, format: u8, // 0 = XRGB8888
    nbufs: u8,           // 1 or 2 scanout buffers in stolen memory
    caps: u32,           // bit0 = page flip, bit1 = hw cursor 64x64 ARGB, bit2 = vblank event is real (not synthesized)
};
pub const Display = struct {
    pub fn acquire() !Display;                       // fails if another owner exists
    pub fn info(self: *Display) DisplayInfo;
    pub fn mapBuffer(self: *Display, idx: u8) ![]align(4096) u32; // WC mapping of scanout buffer
    pub fn vblankEvent(self: *Display) Handle;       // signaled every vertical blank (60 Hz)
    pub fn flip(self: *Display, idx: u8, damage: []const Rect) !void; // latches at next vblank
    pub fn setCursor(self: *Display, argb: ?*const [64*64]u32, hot_x: u8, hot_y: u8) !void; // cap bit1
    pub fn moveCursor(self: *Display, x: i16, y: i16) !void;
};
```
- **Double-buffered flip preferred** (nbufs=2, 2×1.47 MB in the ~7.9 MB stolen pool). eeewm keeps a
  2-frame damage history per buffer ("buffer age") and composites `union(new_damage, damage the
  target buffer missed)`, no copy-forward blits.
- **Single-buffer fallback** (QEMU seam or if 04 lands minimal): composite straight into the front
  buffer immediately after the vblank event; small damage finishes inside blanking, large damage may
  tear for one frame. Accepted, documented.
- Cursor: HW cursor plane when cap bit1 (real GMA 900, zero damage cost). SW sprite fallback:
  16×16 1-bit+mask sprite, save-under of the 16×16 fb region kept in RAM, restore+redraw as two
  extra damage rects per motion frame (≤2 KB traffic). Cursor hidden after 1.5 s without pointer
  events or on any key-down; shown on motion.

### 3.3 Scene model & compositing
- Scene = ordered list per tag: tiled windows (opaque, non-overlapping by construction), floating
  windows (dialogs, launcher), then server-drawn overlay layer: bar, toasts/OSD, lock screen, DND
  cursor. Tiled+floating content is **opaque XRGB, no blending**. Only the overlay layer blends
  (constant-alpha or per-pixel), and blending always reads RAM sources (client shm / server scratch),
  **never the WC framebuffer** (WC reads are uncached, ~10× slow).
- Composite pass (per frame, only if damage pending): walk damage rects → for each, blit from the
  topmost source covering it (tiling makes overlap resolution trivial: point-in-tile), overlay
  regions re-blended in a RAM scratch strip then NT-copied out. `sfence`, then `flip()`.
- Damage rects: per-client ≤4 per commit; server coalesces into a global list, caps at 16 rects,
  falls back to bounding box, x/width aligned to 16 px (64 B), full WC write-combine bursts, and
  16 B-aligned `movntdq`.

### 3.4 Frame loop (single thread)
```
loop: wait_many(vblank_evt, input_evt, listen_ch, client_chs[...], feed_evts[...], timer_evt)
  input   → translate (keymap engine) → hotkey table → dispatch to focused client ring / WM action
  client  → protocol call (commit/create/...), commit blits are deferred to next vblank slot
  feeds   → update bar model, mark bar damage
  timer   → clock tick (60 s), toast expiry, idle-threshold checks, cursor hide
  vblank  → if damage: composite + flip (see 3.3); update per-buffer damage age
```
Commits reply immediately after the server has *copied nothing*, the reply is sent after the
composite that consumes the commit (max one frame, ≤16.7 ms). This throttles clients to the display
rate for free (SPSC: client may not draw into a committed region until the reply). One in-flight
commit per window.

## 4. Tiling model & UX

### 4.1 Workspaces (tags): **4**
dwm-style tags (a window holds a tag bitmask; view = one tag in v1). Four, not nine, because:
(a) every mapped client keeps its ~1.5 MB surface + 2–6 MB heap alive regardless of visibility,
9 tags invites ~9+ resident apps ≈ 30–60 MB, blowing the 48 MB idle budget; 4 tags × ~2 clients
≈ 8 clients worst case ≈ 10–12 MB surfaces, workable; (b) at 800×480 more than ~8 windows is not a
real workflow; (c) bar real estate: 4 tag pips cost 56 px. Mod+1..4 / Mod+Shift+1..4.

### 4.2 Layouts
- **tall** (default): master left (mfact 0.58 of width), stack right, vertical splits.
- **wide**: master top (mfact 0.55 of height), stack bottom, horizontal splits, for terminal+doc.
- **monocle**: focused window fullscreen-under-bar; bar shows `[n/m]`.
- **floating exception**: windows created with `dialog`/`floating` flags (file pickers, PSK entry,
  launcher) float centered (dialogs: centered over parent), always above tiled, focus-preferring.
  No general floating layout mode in v1.
- nmaster fixed at 1. mfact adjustable 0.20–0.80 in 0.05 steps.

### 4.3 Metrics at 133 DPI (800×480 is precious)
- **Gaps: none.** Borders: 1 px unfocused (#A8A498), 2 px focused (#2864A4) drawn inside the tile.
- Bar: 22 px tall, top. Usable tiling area: 800×458.
- Minimum tile: 200×100; layout refuses to split below it (extra windows stack into a tabbed
  "overflow" strip in v2; v1: they still split, user's problem, documented).

### 4.4 Status bar (server-drawn, RAM-backed 800×22 strip)
`[1][2][3][4] |T|  win-title …            US 51% ▂▄▆ eth √ 48°C ♪72 12:34`
Segments: tags (occupied/urgent/current pips) · layout glyph (T/W/M) · focused title (truncated,
ellipsis) · keymap indicator **US↔BE** · battery % (+charging glyph, red <10%) · wifi RSSI bars +
SSID-or-eth-link · CPU temp · volume (mute = struck) · clock HH:MM. Left-click on tag = view;
click layout glyph = cycle; click volume = mute toggle. Updates: see status feeds (§5.5).

### 4.5 Key bindings: **by keycode** (physical position), not by symbol
Decision: the WM grab table matches raw keycodes from 05-input (Linux-style KEY_* codes), before
keymap translation. Rationale: (1) chords are positional muscle memory; they must not move when the
user flips US-Intl↔AZERTY, including the layout-toggle chord itself, which must be identical in
both layouts; (2) symbol matching would interact with dead keys (Mod+' on US-Intl is a dead key,
translation must not fire for grabbed chords); (3) grabs are resolved before translation anyway, so
keycode matching is the layering-clean choice. Config names keys by their **QWERTY legend**
(`"mod+m"` = the physical key that is M on QWERTY), documented prominently since the keycaps are
AZERTY. Accelerators inside apps (Alt+F for &File) are symbol-based, that is libeui's business
(§6.5), not the grab table's.

Mod = **Super** (the 701 has a Windows key; Alt is left for apps). Defaults (dwm-flavored):
| Chord | Action | | Chord | Action |
|---|---|---|---|---|
| Mod+Enter | spawn eTerm | | Mod+j / Mod+k | focus next/prev |
| Mod+p | launcher (erun) | | Mod+h / Mod+l | mfact −/+ |
| Mod+t / Mod+w / Mod+m | layout tall/wide/monocle | | Mod+Shift+Enter | zoom to master |
| Mod+1..4, Mod+Shift+1..4 | view / move-to tag | | Mod+Tab | previous tag |
| Mod+Shift+c | close request | | Mod+Shift+k | kill client |
| Mod+Space | **keymap toggle US↔BE** | | Mod+f | toggle floating on focused |
| Mod+s, PrtSc | screenshot | | Mod+Shift+l | lock screen |
| Mod+Shift+q | quit session (confirm dialog) | | F1 (in-app) | libeui command palette |

### 4.6 ATKD/ACPI hotkey policy (input core delivers these as KEY_* events [ASSUME→05])
| Event (research §1 codes) | eeewm action |
|---|---|
| KEY_MUTE / VOLUMEDOWN / VOLUMEUP (0x13/0x14/0x15) | sndd mixer call; OSD slider |
| brightness notify 0x20–0x2f → KEY_BRIGHTNESS* + level via platformd feed | OSD only (EC already applied) |
| KEY_WLAN (0x10/0x11) | toast "WiFi on/off" (netd+platformd handle the hot-unplug) |
| KEY_PROG1 (0x12, Fn+F6) | open erun |
| KEY_DISPLAY_OFF (0x16, Fn+F5) | ask platformd: backlight 0 / restore on any input |
| KEY_SLEEP (Fn+F1), lid | platformd owns suspend; it calls eeewm `prepare_sleep` first (§9.2) |

### 4.7 Touchpad
Focus-follows-**click** (not hover, tiny screen, accidental hovers). Left click focuses + passes
click through. Scroll events (2-finger or edge, whichever 05-input yields) → wheel events to the
window under the pointer. Mod+drag on the master/stack split line adjusts mfact. Mod+drag moves
floating windows. No other gestures in v1.

## 5. Protocol (eeewm ↔ clients)

Transport: one control **channel** per client (sync call/reply, ≤64 B + ≤4 handles) + one
server→client **event ring** (shm SPSC, 16 KB = 682×24 B events, event-handle signaled) + one shm
**surface** per window. Discovery: `/svc` lookup `"gui"` → listener → accept [ASSUME→01: listener/
accept semantics].

### 5.1 Wire types (Zig, all extern, little-endian, exactly ≤64 B)
```zig
pub const Rect = extern struct { x: i16, y: i16, w: u16, h: u16 };

pub const ReqTag = enum(u8) { hello, create_win, attach, commit, set_title, map, unmap,
                              destroy_win, close_ack, set_cmds, bye };
pub const WinFlags = packed struct(u8) { floating: bool, dialog: bool, no_close: bool, _pad: u5 };

pub const Req = extern struct {
    tag: ReqTag, win: u8, _pad: [2]u8,
    body: extern union {
        hello:  extern struct { proto: u16, pid: u32, app_name: [16]u8 },
        create: extern struct { flags: WinFlags, parent: u8, min_w: u16, min_h: u16, tag_hint: u8 },
        attach: extern struct { w: u16, h: u16, stride_px: u16 }, // +1 shm handle
        commit: extern struct { n: u8, rects: [3]Rect },          // 4th rect via bounding merge
        title:  extern struct { len: u8, utf8: [47]u8 },
    },
};
pub const Rep = extern struct {
    status: i16, gen: u16, // gen = server generation, bumps on server restart
    body: extern union {
        hello:  extern struct { caps: u32, screen_w: u16, screen_h: u16 }, // + event-ring shm + event handle (2 handles)
        create: extern struct { win: u8 },
        commit: extern struct { serial: u32 }, // reply sent after composite consumed it
    },
};

pub const EvTag = enum(u8) { key, text, ptr_motion, ptr_button, scroll, focus, configure,
                             close_req, visibility, keymap_changed, ring_overflow };
pub const Ev = extern struct { // 24 bytes fixed
    tag: EvTag, win: u8, _pad: u16, t_us_lo: u32, // truncated timestamp; full time via clock API
    body: extern union {
        key:    extern struct { code: u16, down: u8, mods: u8 },  // raw, for shortcuts
        text:   extern struct { cp: u32 },                        // post-layout/dead-key/compose
        ptrm:   extern struct { x: i16, y: i16 },                 // window-local
        ptrb:   extern struct { btn: u8, down: u8, x: i16, y: i16 },
        scroll: extern struct { dy: i8, dx: i8 },
        conf:   extern struct { w: u16, h: u16, focused_border: u8 },
        vis:    extern struct { visible: u8 },                    // 0 → client SHOULD stop painting
        keymap: extern struct { layout: u8 },                     // 0=US-Intl 1=BE
    },
};
```

### 5.2 Window lifecycle
1. connect → `hello` → reply carries generation, screen size, event ring (2 handles).
2. `create_win{flags,min}` → `win` id. Server decides geometry, emits `configure{w,h}` on the ring.
3. client allocates shm w×h×4 (stride rounded to 16 px), sends `attach` (+shm handle), draws
   full content, `commit{full rect}`, then `map`.
4. resize (layout change): server emits `configure` → client reallocs if size differs, `attach`es
   the new shm (server swaps atomically at next composite, old shm released), full commit.
   Tile sizes change only on layout/tag operations, so realloc churn is rare.
5. close: server sends `close_req` → well-behaved client saves + `destroy_win` (or `close_ack` to
   veto with a dialog). `Mod+Shift+k` / 2 s timeout → server drops window, asks supervisor to kill
   the pid from `hello`.
6. client crash: channel HUP → server unmaps its windows, releases handles, refocuses, toasts
   "app crashed" with relaunch hint.

### 5.3 Server crash / reconnect handshake
Supervisor restarts eeewm; kernel display owner handle is released on process death so re-acquire
succeeds [ASSUME→04]. Clients discover death via channel HUP or `gen` mismatch, then: retry /svc
lookup with 100 ms→2 s backoff; on connect send `hello` (new gen) and **re-run 5.2 steps 2–4 for
every window they had** (client is the source of truth: libeui keeps the widget tree and surface;
re-attach reuses the existing shm handle, surfaces survive because the client owns them). Server
restores tag assignment from `tag_hint` (clients cache their last tag from `configure`… tag is
carried in `visibility`/`configure`?, no: server includes current tag in `create` reply? Kept
simple: client caches last known tag told to it via `keymap`-style info event `taginfo`, v1:
`tag_hint` on create is best-effort; after a server crash windows may regroup on tag 1. Accepted.)
Focus/layout/mfact reset to defaults on restart. Restart target: <500 ms to first frame.

### 5.4 Notifications (server-side)
`/svc "notify"`: `notify{slot: enum(u8){toast, osd}, urgency, timeout_ms, title[24], body[32]}`,
pure inline, no client surface. Toasts: top-right, max 3, 280×48 each, per-pixel-alpha rounded
card. OSD (volume/brightness): bottom-center 240×36 slider card, replaces previous. Rendered from
theme + bitmap font by the server itself.

### 5.5 Status feeds (bar data; also usable by any client, e.g. esettings)
Push-free seqlock mailboxes: subscriber passes a 4 KB shm + an event; publisher writes a 64 B
record and signals. Reader: `seq` double-read (retry on odd/changed). One page holds all records.
```zig
pub const FeedId = enum(u8) { battery, thermal, backlight, net, mixer, storage };
pub const FeedRec = extern struct { seq: u32, id: u8, len: u8, _p: u16, data: [56]u8 };
// battery: pct u8, ac u8, charging u8 | thermal: cpu_c u8, fan_rpm u16, fan_mode u8
// backlight: level u8 (0-15) | net: kind u8(none/eth/wifi), rssi i8, ssid [28]u8
// mixer: vol u8 (0-100), mute u8 | storage: mask of mounted vols + change counter
```
`platformd` publishes battery (10 s), thermal (5 s), backlight (on change); `netd` net (5 s / on
change); `sndd` mixer (on change); `usbd` storage (on change). Contract: publishers rate-limit;
eeewm never polls. Clock is eeewm-local (60 s timer aligned to the minute).

## 6. libeui

### 6.1 Linking: **static** (v1 decision, with numbers)
libeui compiled ReleaseSmall: est. ~220 KB full (widgets+layout+theme+text+protocol), but Zig
dead-code elimination means real apps pay 90–180 KB each. 6 core apps → ~0.8 MB duplicated in the
24 MB rootfs (3.3%) and, with all 6 resident, ~0.8 MB extra RAM. A dynamic loader would save ≤1 MB
at the cost of a userspace ld.so, PLT/GOT overhead on a 512 KB-L2 CPU, and version-skew failure
modes during the driver-drop-in story. Not worth it at this app count; revisit in M3 if the app set
exceeds ~12 (numbers to be re-validated with 07-userspace once its libc sizes land). Font files are
NOT linked in, mmap'd from RAM-rootfs read-only, pages shared across processes [ASSUME→02-mm:
ramfs mmap shares physical pages; if not, +90 KB/app, still acceptable].

### 6.2 Core model
Retained widget tree; two-pass layout (measure → arrange); dirty-flag repaint into the window's shm
surface; damage accumulation per widget bounding rect; `commit` on loop idle. Single-threaded.
```zig
pub const Size = struct { w: u16, h: u16 };
pub const Constraints = struct { min: Size, max: Size };
pub const Widget = struct {
    vtable: *const VTable, rect: Rect, flags: Flags, parent: ?*Widget,
    pub const VTable = struct {
        measure: *const fn (*Widget, Constraints) Size,
        arrange: *const fn (*Widget, Rect) void,
        paint:   *const fn (*Widget, *Painter) void,
        event:   *const fn (*Widget, *const Ev) bool,   // true = consumed
    };
};
pub const App = struct {
    pub fn init(gpa: std.mem.Allocator, name: []const u8) !*App; // connects, handshake, reconnect logic inside
    pub fn newWindow(self: *App, opts: WinOpts) !*Win;
    pub fn run(self: *App) !void;  // wait_many loop: ring event, timers, user fds
    pub fn addTimer(self: *App, ms: u32, cb: TimerCb) TimerId;
};
pub const Win = struct {
    root: *Widget, focus: ?*Widget, cmds: CommandSet, surface: Surface,
    pub fn requestClose(self: *Win) void;
    pub fn invalidate(self: *Win, r: Rect) void;
};
pub const Painter = struct { // pure software, operates on Surface{px,w,h,stride_px}
    pub fn fill(p: *Painter, r: Rect, argb: u32) void;
    pub fn hline/vline/rectOutline(...) void;
    pub fn text(p: *Painter, f: FontId, x: i32, y: i32, fg: u32, bg: ?u32, s: []const u8) i32;
    pub fn blit(p: *Painter, src: *const Surface, sr: Rect, dx: i32, dy: i32) void;
};
```
Containers: `Box` (h/v, per-child flex weight + fixed), `Grid` (n-col, row-major), `Scroll`
(vertical only, owns a `Scrollbar`). Controls v1: `Label`, `Button`, `Check`, `Radio`, `TextInput`
(single-line: horizontal scroll, selection, clipboard via eeewm CLIP service, server-held single
buffer ≤64 KB), `TextArea` (multi-line: line array of []u8, gap-buffer per focused line, soft-wrap
off by default), `ListView` (virtualized: `count()`, `rowAt(i)` callbacks, only visible rows
painted, mandatory for /files listing on 512 MB), `Scrollbar`, `Tabs`, `Progress`, `Slider`,
`Palette` (menu-as-command-palette), `Dialog`, `Toast` (thin client-side wrapper that calls the
notify service).

### 6.3 Command palette instead of menus
Apps register a `CommandSet`: `{id: u16, title: []const u8, accel: ?Accel, when: enum}`.
F1 opens the in-app `Palette` (floating child window 460×280): text input + fuzzy subsequence
match + virtualized list, Enter executes, shows accels for learnability. The same widget powers
erun (global launcher). This replaces menu bars entirely, saves 20+ px of chrome and fits
keyboard-first.

### 6.4 Text input & division of labor with 05-input
Locked split: **05-input delivers raw keycodes + key state only. eeewm owns the layout engine**
(US-Intl and BE-AZERTY tables, Shift/AltGr/dead keys/Compose) and delivers to clients BOTH `key`
(raw, for shortcuts) and `text` (final UTF-32 codepoint, NFC-precomposed) events. libeui text
widgets consume ONLY `text` events for content and `key` for editing/navigation (arrows, Home,
C-w…). Dead-key/compose state therefore lives in exactly one place, is consistent across apps, and
the bar can render pending dead-key state (small ´ indicator). Keymap tables:
`keycode → {base, shift, altgr, shift_altgr}: u21|DeadId`; dead table `DeadId×u21→u21` (~180
entries); compose table (Menu key = Compose, ~140 common Latin sequences). Layout files are data
(`/cfg/keymaps/*.ekm`), switchable at runtime; `keymap_changed` event lets apps update hints.

### 6.5 Focus & accelerators
Tab/Shift+Tab = tree-order focus ring (skips disabled/invisible); arrows move within Radio/List;
Enter = default button, Esc = cancel/close-dialog. Accelerators are **symbol-based** (Alt+letter,
letter compared against the translated codepoint, case-folded) because they are mnemonic to the
*label text* ("&Fichier" vs "&File" can differ per app locale), the opposite choice from WM chords,
deliberately.

### 6.6 Theme (one built-in, tuned for 6-bit+FRC TN)
Philosophy: **flat, light, warm-gray, zero gradients**. Every token has R,G,B ≡ 0 (mod 4), i.e.
exact 6-bit levels → large fills never engage FRC temporal dithering (no shimmer), and banding is
impossible because nothing is a ramp. Light theme because TN vertical gamma shift mangles dark
themes worst. Selected tokens:
```
bg #E8E4E0  surface #F4F0EC  text #181818  text_dim #545048  border #A8A498
accent #2864A4  accent_text #FCFCFC  sel_bg #2864A4  sel_text #FCFCFC
ok #208030  warn #A06010  err #A02020  focus_ring #2864A4 (1px dotted)
bar_bg #20242C  bar_text #D8D4CC  urgent #A02020
```
Metrics (133 DPI): base unit 4 px; control height 24; list row 18; menu/palette row 20; padding
6h/4v; scrollbar 10 wide (touchpad target); checkbox 12×12; slider track 4; corner radius 4 on
what is pressed or typed into (buttons, toggles, swatches, joined choice rows, text fields);
square everywhere else (checkboxes, indicators, sample tiles, panes, panels, windows). A joined
row keeps the corners between its own segments square and rounds only the outside, which is
what makes one of them chosen rather than several adjacent buttons. All widgets integer-pixel;
no subpixel positioning.

### 6.7 Icons: carried by the program, fallen back to by the shell

**A program carries its own icon, in its own binary.** Not in a directory the
shell owns, not in a manifest beside it, and not in a table the window manager
has to be taught: an application that cannot look like itself without the
shell being changed is one that nobody can install. The picture travels with
the thing it depicts, so copying the binary copies the icon and deleting it
takes the icon with it.

The shape follows what `eui.icon` already draws: one-bit rows and a size, in
the form the surface's blitter takes. What is needed on top is where to put it
and how to find it, which is a named section in the ELF the loader already
parses. A program with no such section has no icon, which is the ordinary case
and not an error.

**The shell falls back rather than refusing.** A program with no icon of its
own is drawn with one of the shell's, chosen by what the program is: the
category it was launched from, or failing that a plain one that means "a
program". So the launcher never has a row with a hole in it, and an icon is
something a program may have rather than something it must supply before it
can be listed.

Two things this rules out on purpose. An icon *theme*, because a set of
pictures that overrides what programs carry is a second source of truth and
the machine has one screen to argue about. And icons at more than one size:
the interface scale doubles a bitmap by whole pixels, so a program supplies
one picture and it is drawn at whatever the interface is set to, like every
other picture in the system.

## 7. Fonts & text rendering

**Decision: packed bitmap fonts ("EFNT"), no TTF rasterizer in v1.** Honest hinting argument: an
stb_truetype-class rasterizer does no bytecode hinting; at 10–16 px on a 133 DPI 6-bit panel,
unhinted AA text is fuzzy and gray-banded, and a real hinting engine (FreeType-scale) is far outside
footprint. Hand-hinted bitmaps are simply better here, and they delete the entire rasterizer,
glyph-cache, and blending cost: 1bpp glyphs blit as fg/bg writes (no read-modify-write, no AA).
Limits stated: no AA, no subpixel, no shaping, no combining marks (NFC precomposed only, from §6.4),
LTR only, missing glyph → U+FFFD box. Faces (4 files, ~90 KB total):
- `sans-13` + `sans-13b` (proportional, ascent 10/descent 3), all UI text, bar.
- `mono-8x14` (Terminus-derived), terminal/editor default: 100×32 cells under the bar.
- `mono-8x16`, terminal "large" option: 100×28 cells.
Coverage per face: ASCII, Latin-1 Supplement, Latin Extended-A, € U+20AC, U+FFFD, arrows/UI glyphs
(U+2190–U+21FF subset), box drawing + blocks (U+2500–U+259F, mono faces only) ≈ 560 glyphs.
Fully covers US-Intl and BE-AZERTY dead-key/compose output.
EFNT: `{magic, h, ascent, nglyph}` + sorted cp→glyph table (binary search) + `{w, advance,
bearing_x/y, off}` + 1bpp rows. Rendering is **client-side in libeui** (server renders only bar/
toasts/lock with the same code); no server round-trip per glyph, no glyph cache needed (bitmaps ARE
the cache). Text draw hot path: per glyph row, expand 1bpp→32bpp via 4-bit LUT (16 entries × 4 px
writes), ~0.15 µs/glyph estimated; a full 100×32 terminal repaint ≈ 3200 glyphs ≈ 0.5 ms + memory.

## 8. Core apps

| App | Binary est. | Purpose / design |
|---|---|---|
| eterm | 260 KB | Terminal. Grid of `{cp: u21, attr: u11}` packed u32; per-line dirty bits; scrollback 500 lines (~0.4 MB). Font mono-8x14. Escape subset (extended VT100, xterm-16color-compatible; see §16): C0 BEL BS HT LF CR SO/SI; ESC 7/8/c/D/E/M, ESC ( B, ESC ( 0 (DEC graphics→box glyphs); CSI: CUU/CUD/CUF/CUB (A–D), CNL/CPL (E/F), CHA (G), CUP/HVP (H/f), ED (J), EL (K), IL/DL (L/M), DCH (P), ICH (@), SU/SD (S/T), ECH (X), REP (b), DA (c→"?6c"), VPA (d), TBC (g), SM/RM (h/l: 4 insert, 20 LNM), DECSET/DECRST (?7 wrap, ?25 cursor, ?1049 altscreen, ?2004 bracketed paste; mouse ?1000/1006 = M3), SGR (m: 0/1/4/7/22/24/27, 30–37/39, 40–47/49, 90–97/100–107; 38/48;5;n accepted → nearest-16 map), DSR (n: 5, 6/CPR), DECSTBM (r); OSC 0/2 title (BEL/ST). Child I/O: spawn(shell) with a pipe pair. **No pty.** A Unix pty is a byte channel plus termios plus a line discipline plus signals plus process groups; we have no signals and no process groups, and `vsh` does its own line editing (11-userspace §257), so canonical mode and echo have no customer. Pipes plus stdio binding at spawn plus a resize notification is the whole requirement, and pipes are needed for `\|` regardless. |
| efm | 300 KB | File manager, dual-pane (2×396 px, ListView each). Tab = switch pane, Enter open (spawn by extension map in /cfg/open.map), F5 copy / F6 move / F7 mkdir / F8 delete(→trash /data/.trash) / e = eject. Subscribes `storage` feed; volumes header shows /data, /mnt/sd, /mnt/usb*; eject = usbd channel call `eject(volid)` (flush+offline) then toast. Copy runs in-process with progress dialog (files are small; no threads, chunked via timer callbacks). |
| eedit | 340 KB | Editor on TextArea + line-array buffer. Syntax highlight: line-based lexers (comptime-registered per-language tables: keyword set, comment/string delimiters), per-line entry state (in_comment/in_string) cached, re-lex from edited line until state converges; spans feed TextArea attrs. v1: zig, c, sh, ini, md. Find (Ctrl+F palette-style), goto-line, LF only, UTF-8 only. |
| eimg | 320 KB | Viewer: **BMP + PNG in v1** (PNG via Zig std flate + unfilter, ~25 KB code); **JPEG baseline-only in M3** (+~55 KB, no progressive, honest: a 3 MP JPEG decodes in ~2–4 s at 630 MHz; done in idle-chunks with progress). Decode with stride-downscale to ≤1600×960 to cap RAM (≤6 MB pixels); fit/100%/zoom ×2, pan arrows. |
| esettings | 320 KB | Tabs: **Network** (every interface, wired and wireless in one pane: enabled, DHCP or a claimed address, and for a radio the networks heard from `wifi_scan` with the key asked on a masked field), **Input** (layout US↔BE radio + test field + compose on/off), **Display** (brightness Slider 0–15 → platformd `PBLS`; idle-dim timeouts), **Audio** (volume/mute + capture toggle → sndd), **Power/Thermal** (battery %, temp, fan RPM, fan mode auto/manual with the 90 °C warning from research §2), **About**. Every control writes /cfg via platformd config API [ASSUME→06]. |
| erun | 180 KB | Launcher, spawned by eeewm on Mod+p: floating 460×280 Palette over current tag. Sources: /apps/*.manifest (name, exec, keywords), open windows (switch-to), verbs ("lock", "sleep", "layout be", "brightness 8"). Fuzzy subsequence, top 8, Enter = spawn/switch, Esc = close. Cold-start target <300 ms. |

Notification daemon behavior is inside eeewm (§5.4), no separate process.

## 9. Screenshot, lock, idle

### 9.1 Screenshot (Mod+s / PrtSc)
Server re-composites the current scene into a RAM buffer (never reads WC fb; ~3 MB traffic ≈8 ms),
then deflate-PNG-encodes async in idle timer slices (~300 ms total) to
`/data/shots/eee-YYYYMMDD-HHMMSS.png`, toast on completion. M1 fallback: raw BMP write (instant).

### 9.2 Screen lock
In-server (an external locker process could crash and unlock, in-server lock state survives
everything except an eeewm crash, and on restart eeewm relocks if `/run/locked` flag exists).
Lock = input dispatch suspended (except lock prompt), scene replaced by lock surface (clock +
masked TextInput), full-frame 50%-dim of last scene as background (one-time ~10 ms blend).
Passphrase: PBKDF2-SHA256, ~120 ms at 630 MHz (std.crypto), verify against `/cfg/lock.hash`.
Triggers: Mod+Shift+l, pre-suspend hook. platformd calls `gui.prepare_sleep()` → eeewm locks,
completes one composite, replies → platformd proceeds to S3 (04-graphics re-inits GPU on resume;
eeewm just full-damages on the resume event) [ASSUME→04/06 resume ordering].

### 9.3 Idle dimming
eeewm owns the idle clock (it sees all input): thresholds (default dim 60 s → backlight 3;
blank 5 min → backlight 0; lock+blank 15 min, all /cfg-tunable). At each threshold eeewm calls
platformd `set_backlight(level, .idle)`; any input → `set_backlight(restore, .activity)`.
platformd arbitrates against manual Fn changes (EC applied) via its backlight feed.

## 10. Hot-path sequences (CPU register level)

### 10.1 SSE2 tile blit, RAM→WC framebuffer (the compositor kernel)
Preconditions: dst 16 B aligned (stride ×16 px, damage x aligned to 16 px), src stride ×16 px.
```asm
; per row: n = width_px/16 iterations (64 B = one WC buffer / cache line per iter)
.row:  movdqa  xmm0, [esi]        ; client surface: cached RAM reads
       movdqa  xmm1, [esi+16]
       movdqa  xmm2, [esi+32]
       movdqa  xmm3, [esi+48]
       movntdq [edi],    xmm0     ; NT stores: no RFO read of fb line, fills WC buffer
       movntdq [edi+16], xmm1     ;   exactly, single 64 B burst per iteration
       movntdq [edi+32], xmm2
       movntdq [edi+48], xmm3
       add esi,64 ; add edi,64 ; dec ecx ; jnz .row
; after ALL damage rects:  sfence   ; order NT stores before flip() ioctl
```
Zig: `asm volatile` block or `@memcpy` replaced by a hand `blitRowNT(dst, src, n)`; ReleaseSmall
must not auto-vectorize differently, kernel isolated in one .zig file with tests.
Why NT: classic `movdqa` stores to WC are fine too, but NT also wins for RAM→RAM scratch composits
(avoids polluting the 512 KB L2 with pixels). Never `rep movsb` to WC (partial-line evictions).

### 10.2 Overlay blend (toasts/OSD/lock dim): RAM only
SRC-over, per-pixel a8: unpack `punpcklbw` to 16-bit, `pmullw` by (a, 255−a), `paddw`, `psrlw 8`,
`packuswb`; 8 px/iter. Constant-alpha dim uses `pmulhuw` by (alpha<<8). Output rows then go through
10.1 to the fb. Blending never reads the WC mapping.

### 10.3 1bpp glyph expand
Per glyph row byte: two 4-bit LUT lookups → each yields prebuilt 4×u32 fg/bg pattern (LUT rebuilt
on color change, 16×16 B = 256 B, L1-resident), `movdqu` store to surface. Bg==null variant masks
writes (read-modify only for transparent-label case, used on bar only).

### 10.4 Damage math
All damage rects: `x0 &= ~15; w = (w + (x-x0) + 15) & ~15` (16 px = 64 B). Vertical unaligned is
free. Global coalesce: insert-merge if overlap/adjacent, cap 16 rects else bounding box.

## 11. Frame budget arithmetic (630 MHz, budget bandwidth ~400 MB/s effective streaming)

Baseline numbers (to be re-measured in M1 on real DRAM, see risk R1):
| Scenario | Traffic | Est. time |
|---|---|---|
| Full-frame composite (tag switch, monocle switch) | read 1.47 + NT write 1.47 = 2.94 MB | **~7.4 ms** ✓ ≤8 ms budget |
| Terminal one line (800×14) | 44 KB×2 | ~0.22 ms |
| Terminal full scroll (client memmove 1.4 MB + redraw line + composite full surface tile ~2.9 MB) | ~4.4 MB | ~11 ms → ~45–60 fps scroll, worst common case, acceptable |
| Toast appear (280×48: recomposite under + blend + write) | ~160 KB | ~0.5 ms |
| SW cursor move (2×16×16 restore+draw) | ~4 KB | ~0.02 ms (HW cursor: 0) |
| Bar clock tick (60×22 segment) | ~11 KB | ~0.05 ms |
| Screenshot recomposite | 2.94 MB | ~8 ms + async PNG ~300 ms CPU |
CPU side is negligible next to memory (SSE2 copy ≈ 5 B/cycle theoretical vs ~0.63 B/cycle
delivered by DRAM). Vblank pacing coalesces damage; commit-throttling stops runaway clients. If M1
measurement shows DDR2-140 reality (~250 MB/s effective), full-frame ≈ 12 ms: still one frame at
60 Hz misses → degrade policy: tag switches allowed to take 2 frames (33 ms, imperceptible), steady-
state damage stays small. Budget survives.

## 12. RAM & disk budgets

RAM (idle-to-GUI scenario: eeewm + eterm mapped, feeds live):
| Item | Size |
|---|---|
| eeewm text+rodata | 0.40 MB |
| eeewm heap: bar strip 70 KB, OSD/toast scratch 160 KB, scene+damage+keymaps ~120 KB, fonts (mmap, shared) 90 KB, cursor stores | ~0.5 MB |
| eterm: text 0.26 + surface 1.43 + grid/scrollback 0.5 + heap 0.3 | ~2.5 MB |
| **GUI idle total** | **~3.5 MB** (share of 48 MB idle budget; declared cap 6 MB) |
| Scanout: 2×1.47 MB + HW cursor | in 7.9 MB stolen pool, NOT system-RAM budget |
| Per additional client | surface (≤1.47 MB, tile-sized usually 0.6–0.9) + ring 16 KB + app heap 1–4 MB |
| Worst case 8 clients on 4 tags | ~10 MB surfaces + ~15 MB heaps, fits 512 MB with headroom |
| Transients | screenshot 1.5 MB, eimg decode ≤6 MB |

Disk (rootfs share): eeewm 0.40 MB + fonts 0.09 + keymaps/theme/cfg 0.02 → **server+libeui 0.51 MB
≤ 2.5 MB budget** ✓ (libeui exists only inside app binaries). Apps: eterm 0.26 + efm 0.30 + eedit
0.34 + eimg 0.32 + esettings 0.32 + erun 0.18 = **1.72 MB**. GUI grand total ≈ **2.3 MB** of the
24 MB rootfs.

## 13. Bring-up & test plan

QEMU cannot emulate GMA900, the display seam is the 04-graphics owner API itself:
1. **Host-native unit tier** (any machine, `zig test`): Painter/widgets/layout render into plain
   RAM `Surface`s → CRC + golden-PNG comparison; EFNT round-trip; keymap engine table tests
   (every US-Intl/BE dead-key+compose sequence enumerated); terminal parser vs recorded vttest/
   typescript corpora + 10⁶-case fuzz (random bytes must never crash/hang); damage coalescer
   property tests; protocol codec round-trip + malformed-message fuzz (truncated, bad tags, huge
   rects, server must drop client, not die).
2. **QEMU integration tier**: kernel display driver has a `bochs-display` backend at 800×480
   (arbitrary-res capable) with a **synthesized 60 Hz timer vblank** (caps bit2=0) and single
   buffer, exercises the fallback path. PS/2 kbd/mouse via QEMU; scripted input via monitor
   `sendkey`; `screendump` golden images per milestone scene (bar, 3-window tall, dialog, palette,
   lock). Client/server crash drills: `kill -9` loops on apps and on eeewm; assert reconnect <2 s,
   no handle leaks (kernel handle-count probe).
3. **Real-hardware tier**: M1 ships `fbbench` (runs before eeewm): measures cached copy, NT copy,
   WC write, WC read bandwidth + full-frame blit time; results logged to /data, **this settles the
   DDR2-140 question and recalibrates §11**. Then: tearing inspection (single vs flip), FRC shimmer
   check of theme fills (photograph panel), HW cursor path, real vblank pacing, AZERTY on the
   physical keycaps, touchpad probe outcome (Synaptics vs Elantech affects 05-input only, but
   verify scroll events), 60-minute soak with toast storm + terminal scroll while playing audio
   (sndd underrun counter must stay 0, validates our memory-bandwidth discipline).

## 14. Risks & open questions

R1 **DRAM bandwidth unknown** (DDR2-140 vs 400 conflict, core-platform §3): full-frame budget 7.4 ms
   could be ~12 ms. Mitigation: fbbench in M1; degrade policy §11; damage discipline everywhere.
R2 **04-graphics scope**: needs double-buffer flip + WC mapping + (optional) HW cursor + resume
   re-init. Fallback single-buffer path designed, but tearing on tag switch will be visible.
R3 **Commit-throttle deadlock class**: client blocked in commit while server blocked sending to a
   full event ring of the same client → server never blocks on rings (drop+`ring_overflow` event).
R4 **ramfs mmap page sharing** for fonts unverified with 02-mm; worst case +90 KB/app.
R5 **Panel FRC behavior** for mod-4 palette is theory-driven (6-bit claim is MEDIUM); verify on
   hardware, adjust palette if shimmer persists.
R6 **Server-crash tag amnesia** (§5.3) accepted for v1; could persist WM state to /run later.

OPEN (for integration; also listed in return summary): /svc listener/accept shape; timer API;
05-input raw-keycode-only agreement + hotkey KEY_* mapping; **pty question resolved: no pty, a
pipe pair and stdio binding at spawn, see §10.4**; platformd
config-write API for esettings; clipboard service final home (eeewm-held buffer proposed);
prepare_sleep/resume ordering with platformd and 04-graphics.

## 15. Phasing

- **M1 (boots to usable shell)**: eeewm core loop, tall+monocle, 1 tag visible logic but 4 wired,
  bar (clock/battery/temp via feeds; static US indicator), keycode grabs, US-Intl keymap only
  (translation engine complete, one table), SW cursor, single-buffer + flip paths, reconnect
  skeleton, notify/OSD minimal. libeui: Surface/Painter/EFNT/Label/Button/ListView/TextInput-single/
  Box. Apps: eterm (core escapes, no altscreen), erun. fbbench. QEMU tier green.
- **M2 (daily-drivable)**: wide layout, floating dialogs, full 4-tag UX, **BE-AZERTY + dead keys +
  compose + Mod+Space switch + bar indicator**, touchpad polish (scroll, mfact drag), full bar
  (net/volume/layout), esettings (wifi+input+display+audio), efm, eedit, screenshot(PNG), lock,
  idle dimming, crash-of-server drill complete, TextArea/Tabs/Slider/Progress/Palette-in-app,
  eterm altscreen+bracketed-paste, golden-image CI.
- **M3 (comfort)**: eimg (+JPEG baseline), terminal mouse reporting (?1000/?1006), overflow-strip
  layout for >per-tag window caps, theme verification pass on panel (R5), dynamic-linking
  re-evaluation with real binary sizes, WM-state persistence across server restart (R6), HW-cursor
  and buffer-age micro-optimizations validated by fbbench numbers.

## 16. eTerm: terminal compatibility

### 16.1 Target: extended VT100

Not strict VT100, which has no colour and none of the line-editing sequences, and not a full
xterm either. The target is VT100 plus the extensions that are universal in practice: the
VT220 editing set, ANSI colour, and the few private modes every terminal has implemented for
thirty years. A program written against any of these works; a program reaching past them
degrades rather than breaks.

**C0**: `BEL` `BS` `HT` `LF` `VT` `FF` `CR`, `SO`/`SI` charset shifts.

**ESC**: `7`/`8` (DECSC/DECRC save and restore cursor), `c` (RIS reset), `D` (IND), `E` (NEL),
`M` (RI reverse index), `H` (HTS set tab), `( B` and `( 0` (ASCII and DEC graphics, the latter
mapped to our box-drawing glyphs).

**CSI, cursor**: `A`–`D` (CUU/CUD/CUF/CUB), `E`/`F` (CNL/CPL), `G` (CHA), `H` and `f`
(CUP/HVP), `d` (VPA).

**CSI, editing**: `J` (ED), `K` (EL), `L` (IL), `M` (DL), `P` (DCH), `@` (ICH), `X` (ECH),
`S`/`T` (SU/SD), `b` (REP), `g` (TBC).

**CSI, modes**: `h`/`l` for `4` (IRM insert) and `20` (LNM); DECSET/DECRST for `?1` (DECCKM
application cursor keys), `?7` (DECAWM autowrap), `?25` (DECTCEM cursor visibility), `?1049`
and the older `?47`/`?1047` (alternate screen).

**CSI, colour and attributes**: `SGR` 0, 1 bold, 2 dim, 4 underline, 5 blink, 7 reverse, 22,
24, 25, 27, 30–37 and 39, 40–47 and 49, and the aixterm brights 90–97 and 100–107. Colour is
itself an extension: VT100 has none. `38`/`48;5;n` is accepted and mapped to the nearest of
the sixteen rather than ignored, so a program using 256 colours renders in approximately the
right ones instead of leaving escape text on screen.

**CSI, reports**: `DSR` `5` and `6` (CPR), `DA` (`c`, answered `?1;2c`), `DECSTBM` (`r`).

**OSC**: `0` and `2` for the window title, terminated by BEL or ST.

That set covers `kilo` several times over. `kilo` alone needs only `ED`, `EL`, `CUP`, the four
cursor movements, `DSR`/`CPR` to discover the window size by driving the cursor to 999,999 and
asking where it landed, `?25`, and `SGR` 0/1/7 with the base sixteen colours.

### 16.2 Input encoding

The output subset is only half of running a foreign program: an application discovers the
keyboard through what arrives on its input, and a terminal with a perfect screen and wrong
arrow keys is a broken terminal. `DECCKM` is in v1 precisely because of this table, it costs
one flag, and getting it wrong looks like our bug when it is not.

| Key | Normal | Application cursor mode (DECCKM) |
|---|---|---|
| Up/Down/Right/Left | `CSI A/B/C/D` | `SS3 A/B/C/D` |
| Home/End | `CSI H` / `CSI F` | `SS3 H` / `SS3 F` |
| Insert/Delete/PgUp/PgDn | `CSI 2~` / `CSI 3~` / `CSI 5~` / `CSI 6~` | same |
| F1–F4 | `SS3 P/Q/R/S` | same |
| F5–F12 | `CSI 15~ 17~ 18~ 19~ 20~ 21~ 23~ 24~` | same |
| Modified | `CSI 1;mX`, m = 1 + (shift 1, alt 2, ctrl 4) | same |
| Ctrl+letter | the C0 control, `Ctrl+A` = 0x01 | same |
| Alt+key | `ESC` then the key | same |
| Enter / Tab / Backspace | `CR` / `HT` / `DEL` (0x7F) | same |

### 16.2a Line discipline: where it ended up

The plan above puts line editing in `vsh` (11-userspace §257), which would leave the terminal
passing keys straight through. `vsh` does not do that yet: it reads whole lines and relies on
the kernel console to assemble them, which works on the console and produces nothing at all
over a pipe.

So eTerm assembles lines itself, echoing as it goes and handling backspace, `Ctrl+U` and
`Ctrl+C`, and sends a line when Enter is pressed. It stops doing so on the alternate screen,
which is what a full-window program switches to and therefore needs no mode of our own: a
program that wants raw keys already asks for the screen it needs them on.

Moving the editing into `vsh` is still the right end state, and it is what gives history and
completion on the console as well as in a window. Until then the terminal owns it, and a
program on the main screen that wants raw input has no way to ask.

### 16.3 Deferred

Genuinely optional, and each one is a program degrading rather than failing:

- **Mouse reporting** (`?1000`, `?1006`). Nothing needs a mouse in a terminal here yet.
- **Bracketed paste** (`?2004`). There is no clipboard to paste from.
- **`DECSCUSR`** (`CSI Sp q`), cursor shape. Parsed and discarded so it does not land as text.
- **`DA2`** (`CSI >c`), secondary device attributes. Answering is one fixed string; worth adding
  the moment something is seen waiting on it.
- **Truecolour** `SGR 38;2;r;g;b`. Accepted and reduced to the 256-colour cube rather than to
  the nearest sixteen: the cube costs no more per cell, since a cell already carries an index.
- **Scrollback.** The buffer is sized for it and nothing writes to it yet, so what leaves the
  top of the screen is gone.

### 16.4 `TERM`

Only matters to programs that read terminfo, which `kilo` does not. The target is
`xterm-16color`: a private `eeeterm` entry is a name nobody has in their database, which falls
back to something crippled, so being compatible with a common one is cheaper than being
unique. Where we differ, we differ by not implementing something rather than by implementing
it differently.

### 16.5 The honest limit: Latin-1, not UTF-8

The font subset is Latin-1 plus box drawing, so a program emitting UTF-8 gets its multi-byte
sequences rendered as separate glyphs. That is a font problem rather than a terminal problem,
and it is deferred with that understood.

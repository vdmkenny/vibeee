# 09: Platform / ACPI / Power subsystem (vibeee)

> **Status: partly built.** `platd` runs uACPI in userspace and holds the driver capability
> and nothing else. Built: table load and namespace bring-up, the SCI, `_PTS`/`_S5_` power off
> and reboot, `_BIF`/`_BST` battery, backlight through `_BCM` or the vendor's `PBLS`, the
> embedded controller as an EmbeddedControl region handler with query draining, and the
> hotkeys of §6.6 as a queue anyone may watch. Not built: thermal and fan, S3, the radio and
> camera gates, and the overclock module. There is no `powerd`: what §6.6 calls policy has
> nowhere to live until there is a session to have a policy about.
>
> **§4 is superseded.** It decides to write a minimal AML interpreter. That decision was
> taken when there was no C toolchain here and no third-party interpreter small enough to
> consider; both have changed, and `platd` uses [uACPI](../third_party/uacpi/) instead. The
> reasoning in §4 for *why an interpreter is needed at all* still stands and is worth
> reading: it is the argument against a hardcoded EC register map, and it has not weakened.
> What no longer holds is the conclusion that we had to write one.
>
> §4.1's scope list is now a description of what uACPI already covers rather than a
> specification to build against.
> Where this document and [`00-vibeee.md`](00-vibeee.md) disagree, the master design wins:
> it carries later decisions this document predates.

Status: design v1. Owner: platform. Scope: ACPI tables, minimal AML interpreter, EC (ENE KB3310), SCI/GPE,
battery/AC, thermal/fan, ATKD hotkeys, radio/camera power gates, S3/S5/reboot, RTC/time, optional FSB overclock
module, i801 SMBus driver. In-kernel service `platform` + small userspace policy daemon `powerd`.

## 1. Overview

The platform subsystem is the kernel's authority on "everything the BIOS/EC still owns after boot": ACPI events
(SCI), the embedded controller, battery/thermal state, the ASUS ATKD hotkey device, sleep states, and wall-clock
time. It is **two-tier by construction**:

- **Tier 1 (preferred): a minimal in-kernel AML interpreter** evaluates the DSDT's methods (ASUS010/ATKD
  feature methods, `_Qxx` EC query handlers, `_BIF/_BST`, `_PTS/_WAK`, `_S3/_S5` packages).
- **Tier 2 (degraded): a hardcoded direct-EC map** (verified register offsets from research) plus ICH6-datasheet
  constants. Every Tier-1 feature has a defined Tier-2 fallback or a defined "feature absent" behavior. The
  system must boot to GUI with the interpreter completely disabled (`platform.aml=off` boot flag).

Userspace `powerd` (supervised, restartable, ~privilege: platform channel only, no MMIO/ioport) holds *policy*:
battery thresholds, lid/power-button actions, fan curves, suspend orchestration ordering, and hosts the
expert-only overclock module. All *mechanism* (port I/O, AML, S3 entry) is in-kernel.

## 2. Hardware facts used (with research confidence)

| Fact | Value | Confidence |
|---|---|---|
| RSDP | 0xFBE60; AMI `ACPIAM`; tables RSDT/FACP/DSDT(0x5F61 B)/FACS/APIC/MCFG; **no HPET table** | HIGH (core §5) |
| ACPI PM base | 0x800 (PM1a evt 0x800/en 0x802, PM1 cnt 0x804, **PM timer 0x808**, ICH6 GPE0 0x828/0x82C) | HIGH base+timer; GPE offsets ICH6-datasheet-standard, verify from FADT |
| SCI | IRQ9, MADT override GSI9 level/high | HIGH (core §6) |
| MCFG ECAM | 0xE0000000, buses 0–255 | HIGH |
| HPET | 0xFED00000, 3 timers, must force-enable via LPC(00:1f.0) cfg 0xF0 → RCBA+0x3404 | HIGH |
| TSC | halts in C3; LAPIC timer stops in C3 (arch) | HIGH / MEDIUM |
| EC | ENE KB3310, ACPI EC 0x62/0x66; temp 0x51, fan PWM 0x63, tach 0x66/0x67, manual bit 0xD3 bit1; Index-IO 0x380–0x384; GPIO pin 0x66 (VID) = XRAM 0xFC2C bit 6 | HIGH (quirks §2) |
| ATKD | HID `ASUS010`, `\_SB.ATKD`; INIT/CMSG; get/set pairs WLDG/WLDS, CAMG/CAMS, PBLG/PBLS(0–15), SDSP, LIDG; CM_ASL bit map | HIGH |
| Hotkey notify codes | 0x10/0x11 wlan, 0x12 PROG1, 0x13 mute, 0x14/0x15 vol, 0x16 dpy-off, 0x20–0x2F brightness (low nibble = level), 0x30–0x32 dpy-switch, 0x37 tpd (later models), 0x50/0x51 AC plug/unplug | HIGH codes / MEDIUM key pairing |
| _Qxx → Notify(ATKD) delivery | standard ASUS pattern | MEDIUM (inferred, design tolerates variance) |
| Battery bug | _BIF design_cap=5200 mAh & 8400 mV real, but last_full/remaining/warn/low/granularity are **percent** (gran=52) | HIGH (quirks §5.1) |
| CFVS | implemented in DSDT, **hard-hangs the 701**, never call | HIGH |
| acpi_osi | later BIOSes gate ASUS010 exposure on `_OSI("Linux")` | MEDIUM-HIGH |
| Wifi kill | WLDS power-gates the mini-PCIe slot; device at 01:00.0 (168c:001c) hot-unplugs; **EC keeps state across reboots**; Notify on \_SB.PCI0.P0P5/P0P6/P0P7; no native PCIe hotplug interrupts | HIGH |
| Camera | CAMS gates USB power of eb1a:2761; BIOS default disabled; possible shared rail with SD reader (unverified on 701) | HIGH / MEDIUM caveat |
| S3 | works; VESA path needed VBE_POST, irrelevant for us (kernel owns modeset and re-programs GMA900) | HIGH |
| Thermal | TZ00 crit 88 °C, passive 85 °C; EC-manual fan mode lets CPU run to 90 °C forced shutdown | MEDIUM / HIGH warning |
| PLL | ICS9LPR426A @ SMBus 0x69 via i801 (8086:266a); 32-byte block cmd 0; byte[12]=N, byte[11]&0x3F=M; stock N=70,M=24; step 70→85→100; block op ≈150 ms | HIGH access path / LOW full register map |
| Fn+F1 sleep | likely fixed/control-method sleep button (SLPB), not ATKD code | MEDIUM, handle both |

## 3. Architecture

```
                 kernel                                userspace
 ┌───────────────────────────────────────┐   ┌───────────────────────────┐
 │ acpi_tables ── aml (Tier1) ── nsdb    │   │ powerd (policy)           │
 │      │            │                   │   │  - thresholds, lid action │
 │ sci/gpe ──► ec ──► platform core ◄────┼───┼─ /svc/platform channel    │
 │ (IRQ9)      │      │  │  │  │         │   │  - fan-curve module (opt) │
 │             │   battery pm  hotkeys ──┼─► │  - overclock module (opt) │
 │             │      │   (S3/S5)  │     │   └───────────────────────────┘
 │          smbus     │            ▼     │   GUI reads status feed via
 │          (i801)  status feed  input   │   /svc/power (read-only sub)
 │                  (shm+event)  core(05)│   devmgr coordinates gates
 └───────────────────────────────────────┘
```

Kernel module layout (`kernel/platform/`): `acpi_tables.zig`, `aml/` (lexer, ns, interp, opregion),
`ec.zig`, `sci.zig`, `battery.zig`, `thermal.zig`, `hotkey.zig`, `pm.zig` (S3/S5/reboot/trampoline),
`rtc.zig`, `smbus_i801.zig`, `clockgen.zig` (overclock mechanism, compile-time optional), `platform_svc.zig`
(channel server for /svc/platform + /svc/power).

Interrupt path: GSI9 (level/high per MADT override) → SCI handler → PM1_STS fixed events + GPE0 scan → EC GPE →
query drain → `_Qxx` (Tier1) / static Q-table (Tier2) → Notify(ATKD, code) → hotkey decode → input core (05).

## 4. THE AML DECISION, an interpreter rather than a register map

**Superseded in its conclusion, kept for its reasoning.** The decision below is that an
interpreter is necessary and a hardcoded EC map is not good enough. That part is unchanged
and the six arguments for it are the reason `platd` carries an interpreter at all.

What changed is who writes it. uACPI is some thirty thousand lines, includes nothing but
`stdint.h` and its neighbours, and fits inside the size cap this document had already set
aside for a smaller one of our own. An interpreter is a thing to be correct at, not a thing
to have written, and the correctness here is somebody else's decade of it.

It runs in `platd` rather than in the kernel, which §3 assumed it would not. This is
bytecode from a 2007 AMI BIOS, interpreted at runtime, whose job is to poke an embedded
controller: that belongs in a restartable process holding a capability.

**Original recommendation: ship the minimal AML interpreter (Tier 1). Hardcoded-EC-only is the fallback, not the plan.**

Justification:
1. **WLDS/CAMS are not reimplementable safely.** They flip EC GPIOs whose identities are *explicitly unknown*
   (quirks §UNCERTAINTIES: "which EC GPIOs they flip", never dumped). Poking wrong KB3310 GPIOs via Index-IO
   risks killing power rails. Only AML knows.
2. **`_Qxx` → hotkey mapping lives in the DSDT** and can differ per BIOS revision (0511/0801/1302). A static
   table works only for the BIOS it was dumped from; the interpreter is revision-proof.
3. **_BIF/_BST field packing over EC** is DSDT-defined; we know the *semantics bug* (percent) but not the EC
   byte offsets of battery registers, not in any research source. Without AML, battery state is guesswork.
4. **S3 requires `_PTS`/`_WAK` and the `_S3` package** (SLP_TYP values). ICH6 SLP_TYP encodings are
   datasheet-standard (S3=101b/S5=111b) so Tier 2 can hardcode them, but skipping `_PTS` on an AMI BIOS risks
   wake failures (BIOS-side bookkeeping in NVS). Tier 1 makes S3 trustworthy; Tier 2 only guarantees S5.
5. **`_OSI` gating**: later BIOSes hide/alter ASUS010 behavior unless `_OSI("Linux")` returns true. Only an
   interpreter can answer _OSI at all.
6. **CFVS containment**: the interpreter gives us a *choke point*, a method-name blacklist that makes the
   known-fatal method uncallable no matter what path reaches it.

Counterweight (why *minimal*): full ACPICA is ~120k LOC and irrelevant (no PCI hotplug ASL, no docking, no
CPU objects we care about: EIST fused off). Era-typical ASUS/AMI DSDTs (INTL 20051117 compiler) use a small,
predictable opcode set.

### 4.1 Interpreter scope (exact)

- **Table load**: DSDT + all SSDTs listed in RSDT (AMI may ship zero or trivial SSDTs). One-pass load executing
  namespace ops; `Method` bodies stored as byte slices, parsed lazily at call. Deferred fixup list for forward
  refs. **No `Load`/`LoadTable`/`Unload`/DDBHandle, treated as eval-fault.** No runtime table mutation.
- **Namespace objects**: Scope, Device, Method, Name, Alias, Mutex, Event, OperationRegion, Field, IndexField,
  CreateByte/Word/DWord/QWord/BitField, Processor (parse+ignore body), ThermalZone (parse as scope), PowerResource
  (parse as scope; _ON/_OFF callable). BankField: parse-fault → poison containing scope feature (not seen in
  era-typical ASUS DSDTs).
- **Data types**: Integer (32-bit math when DSDT revision < 2: AMI rev 1; 64-bit code path exists but is
  compile-time selected out), String, Buffer, Package/VarPackage, Object references.
- **Executable opcodes**: Store, Add, Subtract, Multiply, Divide, Mod, Increment, Decrement, And, Or, Xor, Not,
  Nand, Nor, ShiftLeft, ShiftRight, FindSetLeftBit, FindSetRightBit, LEqual, LGreater, LLess (+ combined forms),
  LAnd, LOr, LNot, If/Else, While/Break/Continue, Return, DerefOf, RefOf, CondRefOf, Index, SizeOf, ObjectType,
  Concatenate (int/str/buf), ToInteger/ToString/ToBuffer/ToHexString/ToDecimalString (subset semantics), Mid,
  Match (full, cheap, AMI uses it), Notify, Sleep, Stall, Acquire/Release, Wait/Signal/Reset, Fatal (log+abort
  eval), Debug (log sink), Breakpoint/Noop (ignore), Timer (PM-timer backed).
- **OperationRegion address spaces**: SystemIO (in/out via kernel port ops), SystemMemory (map_mmio, cached
  mappings), PCI_Config (ECAM at 0xE0000000; _ADR/_BBN resolution), EmbeddedControl (bridges to `ec.zig` under
  the EC mutex). SMBus/CMOS/IPMI opregions: eval-fault (not expected; CMOS handled natively by rtc.zig).
- **Semantics compat**: implicit-return of last computed value (AMI DSDTs written against the Windows
  interpreter rely on it); implicit integer↔buffer conversions per ACPICA behavior; unresolved externals
  evaluate as fault (not crash).
- **_OSI policy**: return TRUE for `"Windows 2001"`, `"Windows 2001 SP1"`, `"Windows 2001 SP2"`,
  `"Windows 2006"` **and `"Linux"`** (the Linux-compat set: this DSDT family gates ASUS010 on it). `_OS` returns
  `"Microsoft Windows NT"`. `_REV` returns 2. Claim set overridable via boot arg `platform.osi=`.
- **Safety rails**: per-eval instruction budget 1M ops + 100 ms wall budget (Sleep yields don't count);
  method recursion cap 16; While iteration cap 100k; Acquire timeout honored via scheduler sleep, deadlock
  detector = 5 s cap → eval-fault. **Method blacklist by name: `CFVS` (and write-path `CPUFV` feature index 12)
, any invocation returns eval-fault without executing** (research: hard-hangs the machine). On any
  eval-fault: log, mark that method poisoned (max 3 faults → permanent), and degrade that *feature* to Tier 2
  per §4.2. Interpreter never panics the kernel; all faults are contained per-eval.
- **Execution context**: AML runs on platd's single userspace thread, never in the SCI hard-IRQ. The kernel
  defers level completion and wakes platd; platd clears the firmware source before `irq_ack`. SCI is isolated
  in the lowest APIC priority class so a failed interpreter cannot suppress unrelated devices.
- **Size estimate**: ~7k LOC Zig ≈ 80–100 KB code (ReleaseSmall, i686); namespace for the 24 KB DSDT ≈
  1000–1500 objects ≈ 64–96 KB arena. Hard cap: 256 KB arena; exceeding = interpreter-off, Tier 2.

### 4.2 Two-tier feature matrix (fallback behavior if interpretation fails)

| Feature | Tier 1 (AML) | Tier 2 (hardcoded, verified regs only) |
|---|---|---|
| EC access | EC opregion via DSDT EC0 | Direct 0x62/0x66 protocol (offsets HIGH-confidence), identical code path underneath |
| EC GPE number | From EC0 `_GPE` | Enable *all* GPE0 bits, identify EC GPE empirically as "the one that fires with SCI_EVT set", latch it |
| Hotkeys | `_Qxx` → Notify(ATKD) → decode | Static Qxx→code table extracted at dev time from BIOS-1302 DSDT dump; unknown Qxx logged+dropped |
| Brightness | PBLG/PBLS 0–15 | None needed for keys: EC applies Fn+F3/F4 autonomously (HIGH); OS-initiated set unavailable; level tracking from notify nibble unavailable → GUI hides slider |
| Wifi gate | WLDG/WLDS + hotplug flow | **No toggling.** Report boot state (probe 01:00.0 vendor ID); Fn+F2 events logged, toggle refused; wifi stays as EC left it |
| Camera gate | CAMG/CAMS | No toggling; camera exists only if BIOS-enabled |
| Battery | _BIF/_BST (+percent fix §7) | Unavailable → status feed reports `battery: unknown`, AC assumed, **auto-sleep thresholds disabled**, GUI shows "?" |
| AC status | ACPI AC0 _PSR / 0x50/0x51 notifies | Unknown (no AML) → assume AC |
| Lid | LID _LID + notify | PM1/GPE lid bit unknown → lid events unavailable; sleep only via key/GUI |
| S3 | Full (_PTS/_S3/_WAK) | **Disabled** (refuse with error), unsafe without _PTS on AMI |
| S5/reboot | _PTS(5)+_S5 pkg | Hardcoded ICH6 SLP_TYP=111b at 0x804; reboot via 0xCF9/i8042 (datasheet-standard, safe) |
| Thermal/fan | Same either way | Direct EC regs 0x51/0x63/0x66/0x67/0xD3 (verified HIGH): Tier-2 native |

## 5. Data structures & interfaces (Zig)

```zig
// ---- kernel/platform/acpi_tables.zig ----
pub const AcpiTables = struct {
    rsdp: *const Rsdp, rsdt: []const u32,           // physical table ptrs (identity-mapped ACPI region)
    fadt: *const Fadt, facs: *volatile Facs, dsdt: []const u8,
    madt: ?*const Madt, mcfg: ?*const Mcfg,
    pub fn find(sig: [4]u8) ?[]const u8;            // raw table by signature (SSDT iteration)
};
pub fn init() !AcpiTables;      // scan EBDA + 0xE0000..0xFFFFF for "RSD PTR ", checksum, map ACPI-data region
pub const PmRegs = struct {     // extracted from FADT, with ICH6 defaults as cross-check
    pm1a_evt: u16 = 0x800, pm1a_cnt: u16 = 0x804, pm_tmr: u16 = 0x808,
    gpe0_sts: u16 = 0x828, gpe0_en: u16 = 0x82C, gpe0_len: u8 = 8,
    smi_cmd: u32, acpi_enable: u8, acpi_disable: u8, sci_int: u8 = 9,
    tmr_32bit: bool,            // FADT TMR_VAL_EXT; ICH6 = 24-bit (false)
    century_cmos: u8,           // FADT century field (0 = none)
};

// ---- kernel/platform/aml/mod.zig ----
pub const AmlValue = union(enum) { int: u32, str: []const u8, buf: []const u8,
                                   pkg: []AmlValue, ref: *NsNode, none: void };
pub const EvalError = error{ NotFound, Fault, Blacklisted, Budget, TypeMismatch, Poisoned };
pub const Aml = struct {
    pub fn load(tables: *const AcpiTables, arena: []u8) !Aml;       // parse DSDT+SSDTs
    pub fn eval(self: *Aml, path: []const u8, args: []const AmlValue) EvalError!AmlValue;
    pub fn evalInt(self: *Aml, path: []const u8, args: []const u32) EvalError!u32;
    pub fn installNotify(self: *Aml, cb: *const fn (dev: *NsNode, code: u8) void) void;
    pub fn findDevice(self: *Aml, hid: []const u8) ?*NsNode;        // e.g. "ASUS010", "PNP0C09", "PNP0C0D"
    pub fn dispatchQuery(self: *Aml, q: u8) EvalError!void;         // eval \_SB...EC0._QXX
};

// ---- kernel/platform/ec.zig ----
pub const Ec = struct {
    pub fn read(self: *Ec, addr: u8) error{Timeout}!u8;             // takes EC mutex
    pub fn write(self: *Ec, addr: u8, val: u8) error{Timeout}!void;
    pub fn query(self: *Ec) error{Timeout}!u8;                      // 0x84; 0 = queue empty
    pub fn readBurst(self: *Ec, base: u8, out: []u8) error{Timeout}!void; // BE/BD wrapped, falls back to loop
    // Index-IO backdoor, compile-time gated: build flag `platform_diag` or the overclock module only.
    pub fn xramRead(self: *Ec, addr: u16) u8;                       // 0x381/0x382/0x383, holds EC mutex
    pub fn xramWrite(self: *Ec, addr: u16, val: u8) void;
};

// ---- kernel/platform/platform_svc.zig, /svc/platform channel protocol (privileged: powerd, devmgr, GUI-server) ----
pub const PlatformReq = union(enum(u16)) {
    get_status: void,                       // → PowerStatus (also mirrored in status shm)
    backlight_set: u4,                      // PBLS 0..15
    backlight_get: void,                    // → u4
    radio_set: struct { which: enum(u8){ wifi, camera }, on: bool }, // full gate flow §7.4
    radio_get: struct { which: enum(u8){ wifi, camera } },           // → GateState
    fan_override: struct { pwm_pct: u8 },   // enters manual mode; caller must renew ≤10 s (watchdog)
    fan_auto: void,
    request_sleep: void, request_poweroff: void, request_reboot: void,
    clock_get: void,                        // → wall_us: u64 (UTC)
    clock_set: struct { wall_us: u64, source: enum(u8){ user, ntp } }, // netd's future NTP entry point
    diag_ec_read: u8,                       // platform_diag builds only
};
pub const PowerStatus = extern struct {     // published in a 64 B shm page, seq-locked, event on change
    seq: u32, flags: u32,                   // bit0 ac_online, bit1 batt_present, bit2 batt_unknown(T2),
                                            // bit3 charging, bit4 lid_closed, bit5 wifi_on, bit6 camera_on,
                                            // bit7 manual_fan, bit8 aml_degraded
    batt_percent: u8, backlight: u8, cpu_temp_c: u8, fan_pwm_pct: u8,
    fan_rpm: u16, batt_mv: u16, est_min_remaining: u16, _pad: u16,
};
// /svc/power = read-only: handle-grant of {status shm (RO), change event}; GUI status bar consumes this.

// ---- hotkey → input core (contract with 05-input) ----
pub const keycodes = @import("../input/keycodes.zig"); // shared table
pub fn injectHotkey(code: u16, value: i32) void;        // wraps input_core.inject(InputEvent{EV_KEY,...})
pub fn injectSwitch(code: u16, value: i32) void;        // EV_SW: SW_LID
// Platform→GUI OSD events (brightness/volume popups) ride the PowerStatus event, not input.

// ---- devmgr coordination (contract with devmgr/06) ----
pub const GateNotice = union(enum(u16)) {   // platform → devmgr channel
    pre_disable: enum(u8){ wifi_pcie_01_00_0, camera_usb },  // devmgr must quiesce netd/usbd, then ack
    disabled: void, enabled_rescan: void,   // after WLDS/CAMS: rescan bus, rebind driver
};

// ---- powerd (userspace) config /cfg/power.conf (key=value) ----
// lid_action=sleep|ignore, sleep_button=sleep, batt_warn=15, batt_sleep=5, batt_off=2,
// fan_mode=auto|curve, curve=40:0,55:30,70:60,80:100, poll_batt_s=10, poll_temp_s=5
```

## 6. Register-level programming sequences

### 6.1 ACPI bring-up (platd, after the kernel routes the IOAPIC)
1. Map ACPI-data + NVS e820 regions (never reclaimed; FACS is in NVS and written at S3 time).
2. Parse RSDP→RSDT→FADT; extract `PmRegs`; sanity-check against ICH6 defaults (log any mismatch, prefer FADT).
3. Initialize uACPI with `UACPI_FLAG_NO_ACPI_MODE`; load and initialize the namespace while SCI remains in legacy routing.
4. Clear PM1_STS: `outw(0x800, 0xFFFF)`. Program PM1_EN (0x802): PWRBTN_EN(bit8) | SLPBTN_EN(bit9); RTC_EN off.
5. GPE0: `outl(0x82C, 0)`, `outl(0x828, 0xFFFFFFFF)` (clear all). Find EC0 (`PNP0C09`), read
   `_CRS` (expect 0x62/0x66) and `_GPE` → n. `outl(0x82C, 1 << n)`. Tier 2: enable-all + empirical latch (§4.2).
6. Evaluate `ATKD.INIT(0x40)` then `CMSG` → supported-feature mask; log. Evaluate `WLDG`, `CAMG`, `PBLG`,
   `AC0._PSR`, `BAT0._BIF` to seed PowerStatus.
7. Claim GSI9 and include its event in `wait_many`. The IOAPIC route was established at boot as level-triggered, active-high (per MADT override), vector 0x20.
8. Only when events are enabled, call `uacpi_enter_acpi_mode`; it performs the FADT SMI-command handshake and waits for SCI_EN rather than writing SCI_EN directly. The default build deliberately omits this transition.
9. Register `/svc/platform` last, as the act that releases dependents: a dependent starts the moment the name appears, so the name appears only once the firmware is fully settled and the serve loop is the next line.

The quirks registry (`src/quirks/`, one module per machine family) is evaluated by the
kernel's early probe before any driver binds, and answers through `sysinfo` (`quirks`,
`quirks.ec`, `quirks.battery`, `acpi.pm`). Rules (`Rule`): DMI vendor, a product family
(exact names plus prefixes, so one quirk covers a whole line), board name, ACPI HID — a
quirk applies when all of its rules match. Today (the Eee line): EC ports 0x62/0x66 for
DSDTs that declare the controller inside the power management block, and the battery
tables' percent-as-capacity mislabel. The EC driver refuses, uncorrected, any port pair
inside the published no-touch ranges (the FADT's PM1 blocks plus the chipset's own PM
base): a running machine without battery and hotkeys beats touching the PM registers.

### 6.2 SCI / GPE / EC query flow
```
sci_irq():  (hard IRQ, level, must ack before unmask)
  sts = inw(0x800) & inw(0x802)
  if sts & PWRBTN(0x100): outw(0x800, 0x100); post(evt_powerbtn)
  if sts & SLPBTN(0x200): outw(0x800, 0x200); post(evt_sleepbtn)
  g = inl(0x828) & inl(0x82C)
  for bit in g: mask bit in 0x82C; post(evt_gpe[bit])       // handler thread re-enables after ack
  eoi(LAPIC)
gpe_thread(bit):                                            // "acpid-k" kernel thread
  if bit == ec_gpe:
    while (inb(0x66) & 0x20) != 0:                          // SCI_EVT
      q = ec.query()                                        // §6.3
      if q != 0: aml.dispatchQuery(q)  // Tier1 → _Qxx → Notify(ATKD, code) → hotkey.decode(code)
                 // Tier2: static_qtab[q] → hotkey.decode
  outl(0x828, 1 << bit)                                     // clear status (level GPE: after servicing)
  set bit in 0x82C                                          // re-enable
```

### 6.3 EC transaction (poll-mode, PM-timer timeouts; EC mutex held)
```
STATUS(0x66): bit0 OBF, bit1 IBF, bit3 CMD, bit4 BURST, bit5 SCI_EVT, bit6 SMI_EVT
wait_ibf0: poll (inb(0x66)&2)==0, timeout 10 ms (spin 50 µs then yield-loop)
wait_obf1: poll (inb(0x66)&1)==1, timeout 10 ms
read(a):  wait_ibf0; outb(0x66,0x80); wait_ibf0; outb(0x62,a); wait_obf1; return inb(0x62)
write(a,v): wait_ibf0; outb(0x66,0x81); wait_ibf0; outb(0x62,a); wait_ibf0; outb(0x62,v)
query():  wait_ibf0; outb(0x66,0x84); wait_obf1; return inb(0x62)
burst read(base,n): outb(0x66,0x82); wait_obf1; ack=inb(0x62) (expect 0x90);
  then n× read(); outb(0x66,0x83); on any timeout: BD + fall back to plain loop
```
Timeout → error counter; 5 consecutive → declare EC wedged, log, retry with 100 ms backoff (never panic).
**Index-IO backdoor (0x380–0x384)**, `outb(0x381, a>>8); outb(0x382, a&0xFF); data = 0x383`, bypasses EC
firmware entirely (full 64 KB XRAM/SFR/ROM). **Diagnostics-only** (compile-gated): it races the KB3310's 8051
firmware with no handshake; a concurrent EC-firmware RMW on the same SFR bank can corrupt fan/battery/charger
state. Sole production exception: overclock module's single GPIO write (§6.8), executed under the EC mutex with
EC transactions quiesced. Justification: no ACPI method exists for VID select; the write is one bit, rare, and
to a GPIO port (0xFC2C) the EC firmware is not known to touch at runtime.

### 6.4 Battery / AC (Tier 1)
- `_BST` → pkg {state, present_rate, remaining, voltage_mV}; `_BIF` → {unit, design_cap, last_full, tech,
  design_mV, warn, low, gran1, gran2, model, serial, type, oem}.
- **Percent-bug heuristic**: `percent_mode = (last_full <= 100 and design_cap > 1000)`. Then:
  `percent = clamp(remaining, 0, 100)`; `est_mAh = percent * 5200 / 100`; ignore `present_rate` (unit unknown);
  ignore warn/low/granularity fields (they're percent constants). If not percent_mode (future replacement pack
  with sane firmware): `percent = remaining * 100 / last_full`.
- **Rate/time estimate**: EWMA of d(percent)/dt over ≥ 3 samples (α = 0.3); `est_min = percent / rate_pct_per_min`;
  clamp to 0–1999; invalid until 3 samples on battery.
- **Cadence**: `_BST` every 10 s on battery / 30 s on AC (powerd timer → get_status forces refresh if stale);
  immediate re-poll on ATKD 0x50/0x51 (AC plug/unplug), BAT0 Notify(0x80/0x81), and resume-from-S3.
- **Policy (powerd)**: thresholds with 2-consecutive-sample debounce and AC-cancel: ≤15 % → GUI warn event;
  ≤5 % → request_sleep; ≤2 % → broadcast sync (VFS flush + servers), then request_poweroff. Tier 2: policy
  disabled (batt_unknown flag set: GUI shows "?").

### 6.5 Thermal / fan
- Default: EC auto (ensure 0xD3 bit1 == 0 at boot: `d3 = ec.read(0xD3); if (d3 & 2) ec.write(0xD3, d3 & ~2)`).
- Monitor: every 5 s read temp(0x51), pwm(0x63), tach(0x66:0x67 → rpm = hi<<8|lo); publish in PowerStatus.
- **Manual fan (optional powerd curve module)**: enter = `ec.write(0xD3, d3|2)` then write pwm 0x63 (0–100).
  **In-kernel watchdog**: manual mode is a *lease*, powerd must send `fan_override` at least every 10 s; missed
  renewal, powerd channel death, or kernel panic path ⇒ kernel restores `0xD3 &= ~2` (EC auto). Kernel also
  force-restores auto + logs if temp ≥ 85 °C while manual (research: manual mode will ride to the 90 °C EC
  hard-cutoff, the watchdog exists to make that unreachable).
- **Critical trip**: temp ≥ 88 °C (TZ00 critical, 3 consecutive 1 s reads once ≥ 84 °C): emergency sync + S5
  (beats the EC's 90 °C forced shutdown, preserving filesystems). 84–87 °C: throttle hint event to sched
  (drop to HLT-heavy idle, GUI notice).

### 6.6 Hotkey decode table (Notify(ATKD, code) → action)
| Code | Action |
|---|---|
| 0x10/0x11 | wifi toggle intent → powerd (gate flow §7.4); also inject KEY_WLAN |
| 0x12 | inject KEY_PROG1 |
| 0x13/0x14/0x15 | inject KEY_MUTE / KEY_VOLUMEDOWN / KEY_VOLUMEUP (sndd/GUI handle) |
| 0x16 | inject KEY_DISPLAYOFF → GUI blanks (display driver DPMS) |
| 0x20–0x2F | brightness already applied by EC: cache level = code & 0xF, update PowerStatus (OSD), no re-set |
| 0x30–0x32 | inject KEY_SWITCHVIDEOMODE → GUI/display driver handles CRT clone. **We do NOT call SDSP**, the display driver owns modeset; firmware mode-switching behind its back is forbidden |
| 0x37 | inject KEY_TOUCHPAD_TOGGLE (defensive; later-model code) |
| 0x50/0x51 | AC plugged/unplugged → battery re-poll + PowerStatus; not injected as key |
| other | log unknown, drop |
Fixed events: PWRBTN → powerd policy (default: orderly shutdown; 4 s hardware override unaffected). SLPBTN or
SLPB-device Notify(0x80) (Fn+F1, MEDIUM which form) → request_sleep. LID (`PNP0C0D`) Notify(0x80) → evaluate
`_LID` (0=closed) → EV_SW SW_LID + powerd policy (default sleep-on-close; configurable).

### 6.7 S3 / S5 / reboot
S3 entry (kernel `pm.zig`, orchestrated by powerd via request_sleep):
1. powerd broadcasts SUSPEND_PREPARE on /svc, order: GUI (stop flips) → sndd (drain, stop DMA) → netd
   (quiesce NICs) → usbd (**sync /data on SD MSC first**, suspend ports, halt EHCI/UHCI schedules). Each ack ≤ 2 s
   (timeout → proceed + log). VFS flush + PATA FLUSH CACHE + standby-immediate.
2. Kernel: freeze user threads; disable i8042 IRQs; display driver saves state + disables pipes; mask IOAPIC
   entries except SCI; stop LAPIC timer.
3. Save area (static struct in kernel BSS): CR0/3/4, GDTR/IDTR shadow, SYSENTER MSRs (0x174–0x176), MTRRs we
   changed, LAPIC regs, IOAPIC RTEs, PIT mode, i8042 command byte, PCI config snapshot of kernel-owned devices
   (00:02.0 display BARs+cmd, 00:1f.2 IDE timings, 00:1f.0 ACPI cfg incl. 0xF0 RCBA note), PM1_EN/GPE0_EN.
4. Copy 16-bit trampoline to 0x8000 (page reserved at boot, identity-mapped); store resume GDT + CR values in
   its data block. `facs.firmware_waking_vector = 0x8000` (and X-vector=0 if FACS length ≥ 64, legacy field wins).
5. `aml.eval("\\_PTS", {3})`. Read `\_S3` pkg → SLP_TYPa (expect 5). Arm wake: PM1_EN = PWRBTN_EN (lid/EC wake
   is EC-firmware default). `outw(0x800, 0x8000)` (clear WAK_STS).
6. `cli; wbinvd; outw(0x804, (typ_a << 10) | (1 << 13));` spin 100 ms → **entry failed**: run `_WAK(3)`, restore
   devices, thaw, report error to powerd (GUI toast).
7. Wake: BIOS → real-mode jump to 0x8000. Trampoline: cli; load flat GDT; PE=1; far jump 32-bit; restore CR4
   (PAE), CR3, CR0(PG); jump high-half resume entry; restore GDTR/IDTR/MSRs/stack.
8. Kernel resume order: LAPIC init; IOAPIC RTE restore; **re-force-enable HPET** (RCBA+0x3404: ICH config lost
   in S3) §6.9; PM-timer reread; TSC recalibrate vs PM timer, monotonic clock += suspend duration (RTC delta);
   EC: re-run §6.1 step 4–5 (PM1_EN/GPE re-arm), drain stale queries; `aml.eval("\\_WAK", {3})`; i8042 re-init
   (05); display re-modeset (no VBE POST needed, we own the pipe programming; s2ram's VBE_POST applied only to
   VESA-path OSes); PATA re-program UDMA/66 timings; thaw userspace; powerd broadcasts RESUME in reverse order
   (usbd → remount /data; netd → wifi rescan if it was on; sndd; GUI full-damage redraw). Server not acking
   RESUME in 5 s → supervisor restarts it (servers are restartable by design).
S5: sync all; `_PTS(5)`; `\_S5` pkg → typ (expect 7); same PM1_CNT write. Tier 2 / `_S5` fault: hardcode
ICH6 SLP_TYP: S3=0b101, S5=0b111 (datasheet encoding; S3 hardcode used only to *document*, not to enable T2 S3).
Reboot ladder: (1) FADT RESET_REG if declared → else `outb(0xCF9, 0x02); delay 1 µs; outb(0xCF9, 0x06)`;
(2) i8042 pulse: wait_ibf0, `outb(0x64, 0xFE)`; (3) triple fault (lidt(0) + int3). Try each, 50 ms apart.
RTC wake: **deferred** (research LOW/untested). Design note: CMOS alarm regs 0x01/0x03/0x05 + RTC_EN(bit10) in
PM1_EN before SLP_EN; revisit in M3.

### 6.8 Overclock module (OFF by default; expert; powerd-hosted, kernel mechanism)
- **i801 SMBus driver (`smbus_i801.zig`)**: PCI 00:1f.3 (8086:266a). `smba = cfg32(0x20) & 0xFFE0`;
  `cfg8(0x40) |= 1` (HST_EN). Regs (off smba): HST_STS 0x00 (BYTE_DONE bit7, INUSE bit6, FAILED bit4, BUS_ERR
  bit3, DEV_ERR bit2, INTR bit1, BUSY bit0), HST_CNT 0x02 (START bit6, CMD bits4:2 = 0b101 block, KILL bit1),
  HST_CMD 0x03, XMIT_SLVA 0x04, HST_D0 0x05 (count), SMBBLKDAT 0x07. Byte-by-byte block protocol (no E32B):
  clear STS (write back read value); SLVA=(0x69<<1)|dir; CMD=0; D0=count(write) ; CNT=block|START; per byte:
  poll BYTE_DONE ≤ 100 ms, read/write SMBBLKDAT, write BYTE_DONE to ack; on FAILED/BUS_ERR/DEV_ERR → KILL, error.
  Whole-op timeout 500 ms (research: block op ≈150 ms).
- **Sequence (clockgen.zig, invoked stepwise by powerd module)**: block-read 32 B blob; verify byte[12]==70 &&
  (byte[11]&0x3F)==24 (stock) else refuse ("unknown PLL state"); kernel retains pristine blob. Raise VID first:
  EC mutex → quiesce EC → Index-IO RMW 0xFC2C |= 0x40 (pin 0x66 high) → resume EC. Then byte[12]=85, block-write,
  sleep 100 ms, verify CPU alive (TSC delta sane), byte[12]=100, block-write. After each step: **recalibrate TSC
  and LAPIC timer against PM timer** (their frequencies scale with FSB; PM timer/HPET are fixed 14.318 MHz-derived
  and are our stable clocksources). Revert = write pristine blob + VID low.
- **Safety**: refuse if temp > 70 °C or on battery; kernel auto-revert watchdog (module lease, 10 s renewal, same
  pattern as fan §6.5); revert on powerd/module crash; big scary confirm in UI; warnings surfaced: +5–10 % power
  draw, possible RAM instability / LCD artifacts (research §10). PCIe clock bytes untouched. Not built into
  default image (module dropped in /drivers, manifest-flagged `expert`).
- Open (LOW confidence): the "EC told 70/100 mode flag" register eee.ko writes is not in our research, extract
  from eeepc-linux `eee.c` before implementing (M3 task); module ships only after that's pinned.

### 6.9 HPET force-enable & time
- HPET: `rcba = cfg32(00:1f.0, 0xF0) & 0xFFFFC000`; map 16 KB; `mmio32[0x3404] = 0x80` (HPTC: enable, addr-sel
  00 → 0xFED00000); read-back; map 0xFED00000; verify GCAP_ID != 0/0xFFFFFFFF (expect 3 timers, ~69.84 ns
  period); set ENABLE_CNF (mmio[0x10] bit0). Primary clocksource = HPET main counter; fallback = PM timer at
  0x808 (**24-bit** unless FADT TMR_VAL_EXT, handle wrap at 3.579545 MHz / 4.69 s via ≥ 1 Hz sampling).
- Idle/C-states: v1 idle = HLT (C1) (+C2 via FADT P_LVL2 I/O read if latency ≤ 100 µs). **C3 disabled in v1**
  (TSC + LAPIC timer halt, research HIGH); M3 may add C3 with HPET-comparator tick + TSC-from-HPET resync.
- RTC (`rtc.zig`): NMI-preserving index writes to 0x70. Read: poll StatusA(0x0A) UIP==0; read
  sec/min/hr/day/mon/yr (0x00/02/04/07/08/09) + century from FADT.century CMOS index if nonzero (AMI: 0x32),
  else pivot year<80→20xx; double-read-compare; decode BCD unless StatusB(0x0B) DM; 12 h → 24 h if !bit1.
  Write: StatusB SET=1, write regs (encode to current DM), SET=0. Wall clock = RTC@boot (UTC assumed) +
  monotonic; `clock_set` slews if |Δ| < 500 ms else steps (netd NTP uses this, interface only, no NTP here).

## 7. Radio / camera gate flows (coordination with devmgr)

Gate state machine per device: `ON ⇄ (transitioning) ⇄ OFF`, persisted by the **EC across reboots** (research
HIGH), never assume boot state; probe:
- Boot: wifi = `WLDG()` cross-checked with ECAM vendor-ID read at 01:00.0 (0xFFFFFFFF = absent). Mismatch →
  trust the bus. camera = `CAMG()` (BIOS-default-disabled: absent from USB until CAMS(1) *and* BIOS option on).
  Report both to devmgr at its registration so netd/usbd don't wait for ghosts.
- **Disable wifi**: platform → devmgr `pre_disable(wifi)`; devmgr → netd quiesce (DMA stop, close) → ack (≤ 2 s,
  timeout = proceed+log); `WLDS(0)`; poll ECAM vendor ID until 0xFFFFFFFF (≤ 500 ms); → devmgr `disabled`.
- **Enable wifi**: `WLDS(1)`; wait 100 ms; poll vendor ID == 0x168C (≤ 1 s, 3 retries, card must re-link) →
  devmgr `enabled_rescan` → devmgr rebinds netd driver. No native PCIe hotplug interrupts exist (research HIGH)
, all rescans are explicit. Root-port Notifies (P0P5/P0P6/P0P7) from AML are consumed as confirmation only.
- **Camera**: same via usbd (device eb1a:2761 on EHCI). **Shared-rail caution** (research: 900 kills the SD
  reader with the camera toggle; unverified on 701): since SD is our persistence device, platform forces a
  /data sync via devmgr before any CAMS(0/1), and M1 bring-up explicitly tests reader survival across toggles.
  Default policy: camera stays OFF until first app request (power + privacy).
- Fn+F2 (0x10/0x11) is an *intent*, routed to powerd → same flow; never a direct method call from IRQ context.

## 8. RAM / disk budget

| Item | Code (ROM/rootfs) | RAM |
|---|---|---|
| acpi_tables + sci/gpe | 6 KB | 2 KB + mapped ACPI regions (BIOS-owned, ~320 KB, not ours) |
| AML interpreter | 90 KB | arena 96 KB typ / 256 KB cap |
| ec / battery / thermal / hotkey | 10 KB | 2 KB |
| pm (S3/S5) + trampoline | 8 KB | 4 KB low page @0x8000 + 2 KB save area |
| rtc + time | 3 KB | <1 KB |
| smbus_i801 + clockgen (optional, off default image) | 6 KB | 1 KB |
| **kernel total** | **≤ 120 KB** of the 1.5 MB kernel ELF | **≤ 300 KB worst, ~140 KB typical** |
| powerd binary (+conf) | ≤ 100 KB rootfs | ≤ 300 KB RSS |
Status shm: 1 page. Fits comfortably in the 48 MB idle budget (< 0.5 MB total).

## 9. Bring-up & test plan

QEMU cannot emulate: KB3310 EC semantics beyond generic ACPI-EC, ATKD/ASUS010 AML, the percent-battery bug,
WLDS PCIe power gate, ICS PLL, Index-IO. **Test seams:**
1. **AML interpreter is hardware-independent**: unit-test suite runs the interpreter *hostside* (Zig test
   runner, x86_64) against (a) a real 701 DSDT dump (extract from BIOS 1302 image / acpidump on Linux live-USB
: M1 prerequisite artifact, checked into `testdata/`), (b) synthetic ASL compiled with `iasl` covering every
   supported opcode + the fault paths (Load, BankField, CFVS blacklist, budget exhaustion). Opregion handlers
   are injected mocks (recorded EC/IO transcripts).
2. **QEMU (q35 lies less than pc for ICH, but use `-M pc` for PIIX PM base differences, read FADT, never
   hardcode in tests)**: exercises RSDP scan, FADT parse, SCI enable, PM timer, RTC, generic EC (qemu `-device`
   none, use the interpreter against qemu's SeaBIOS DSDT to smoke-test namespace load on a *foreign* table),
   S3 (`-global PIIX4_PM.disable_s3=0`) end-to-end incl. trampoline, S5, reboot ladder, i801 SMBus model.
3. **Fake-platform mode** (`platform.fake=1`): kernel feeds synthetic battery/temp/hotkey streams so GUI/powerd
   policy is testable in QEMU (thresholds, OSD, sleep orchestration without hardware).
4. **Real-hardware ladder** (serial-less: logs to framebuffer ring + persisted to /data on sync):
   M1-a: table dump verify (RSDP addr 0xFBE60, PM base, MADT) vs research. M1-b: EC reads (temp/fan plausible,
   temp 30–60 °C). M1-c: SCI + query drain with every Fn key, log Qxx→code table (validates Tier-2 table).
   M1-d: battery _BIF/_BST, confirm percent heuristic on AC and battery. M2: S3 soak (100 cycles scripted via
   RTC-less loop: sleep-on-lid, wake-on-powerbtn), gate toggles ×50 with reader-survival check, S5/reboot.
   Thermal test with fan forced low under load, verify watchdog restores auto ≤ 10 s and 88 °C trip fires (use
   a load loop; abort at 89 °C via external supervision = we watch the screen).
5. **Failure injection**: poisoned-method simulation (force eval-fault per feature) must land exactly on the
   §4.2 fallback row; EC timeout storms must not wedge the acpid-k thread.

## 10. Risks & open questions

1. `_Qxx`→Notify pattern is MEDIUM-inferred; if the 701 DSDT instead maps some keys via EC-to-i8042 or fixed
   events, hotkey routing shifts to 05-input, resolved by the M1 DSDT dump (single most valuable artifact).
2. EC `_GPE` number unknown until DSDT dump; empirical latch fallback designed but is a heuristic.
3. Shared camera/SD-reader power rail (unverified): could unmount our persistence store, mitigated (sync-first,
   M1 test), but if confirmed, CAMS gets a "reader-safe" interlock (refuse while /data dirty).
4. FACS X-waking-vector vs legacy field precedence on this AMI: we write legacy (and zero X if present); if
   resume never arrives, first debug step is writing both.
5. S3 device-restore completeness (display re-modeset w/o VBE POST is HIGH-supported via KMS precedent, but our
   from-scratch GMA driver must restore *everything* it touched, contract with 04-display: `save()/restore()`
   callbacks, tested by M2 soak).
6. Fn+F1 delivery form (SLPB vs ATKD code) MEDIUM, both handled; verify on hardware.
7. Overclock: PLL register map LOW confidence; the eee.ko "EC 70/100 flag" register is unpinned, module blocked
   on reading eeepc-linux `eee.c` (M3); stepped-write bricking risk mitigated by refuse-on-unknown-blob.
8. `_OSI("Linux")` claim could theoretically enable Linux-specific DSDT branches that expect Linux ACPI quirks;
   era evidence says it only *unhides* ASUS010, boot-arg override exists.
9. acpid-k single-thread: a Sleep(1000)-heavy method serializes queries; budget caps bound it; watch M1 logs.

## 11. Phasing

- **M1 (boot + see)**: acpi_tables, SCI/GPE, EC driver + direct regs, Tier-2 static hotkey table, PM timer/HPET
  force-enable, RTC, S5/reboot ladder, PowerStatus feed (temp/fan/AC-guess), DSDT dump artifact + hostside AML
  test rig, interpreter core (namespace + eval, no S3). *Exit: hotkeys drive GUI, temp/fan on status bar, clean
  poweroff/reboot, interpreter passes hostside suite on real DSDT.*
- **M2 (power-correct)**: Tier-1 live (INIT/CMSG, _Qxx dispatch, PBLG/PBLS, _BIF/_BST + percent fix, LID),
  powerd policy (thresholds, lid, debounce), full S3 (trampoline, save/restore contracts with 04/05, server
  quiesce protocol), wifi/camera gates + devmgr flow, thermal trip + fan watchdog. *Exit: 100-cycle S3 soak,
  battery % accurate to ±2 vs Linux live-USB, Fn+F2 round-trips with netd.*
- **M3 (polish + expert)**: fan-curve module, C2 idle (C3 investigation), RTC wake, i801+clockgen overclock
  module (after eee.c extraction), _OSI/boot-arg matrix across BIOS 0511/0801/1302 if obtainable, powerd config
  UI hooks.

# ASUS Eee PC 701 4G: Platform Integration, ACPI/EC, and Prior Art

DMI identity: sys_vendor `ASUSTeK Computer INC.`, product_name `701` (the 4G, 4G Surf, 2G Surf all report "701"; the 8G reports "702"; 701SD/701SDX are DIFFERENT machines, different wifi, CFVS supported) [HIGH, kernel cpufv-blacklist patch + s2ram whitelist].

## 1. ACPI platform device (hotkeys / feature control)

- ACPI HID: **`ASUS010`** (`EEEPC_ACPI_HID` in `drivers/platform/x86/eeepc-laptop.c`); device commonly at `\_SB.ATKD` in the DSDT ("hotkey ATKD xxxx" acpid events) [HIGH, kernel source].
- Driver: **`eeepc-laptop`** (Kconfig `EEEPC_LAPTOP`). Predecessor used by Xandros: ASUS-modified **`asus_acpi`** (ASUS ftp `ASUS_ACPI_071126.rar`) exposing `/proc/acpi/asus/{wlan,camera,brightness,...}` [HIGH].
- Init protocol: driver evaluates method **`INIT`** (integer arg = init flags, returns buffer) then **`CMSG`** (returns bitmask of supported features) [HIGH, kernel source].
- Feature get/set method pairs (evaluated as children of the ASUS010 handle), indexed by CM_ASL bit:
  - get: `WLDG BTHG CAMG PBLG CFVG USBG MODG CRDG M3GG WIMG HWCF LIDG TYPE PBPG TPDG`
  - set: `WLDS BTHS CAMS SDSP PBLS HDPS CFVS MODS CRDS M3GS WIMS PBPS TPDS` [HIGH, kernel source].
- CM_ASL feature bit numbers: WLAN=0, BLUETOOTH=1, IRDA=2, 1394=3, CAMERA=4, TV=5, GPS=6, DVDROM=7, DISPLAYSWITCH=8, PANELBRIGHT=9, BIOSFLASH=10, ACPIFLASH=11, CPUFV=12, CPUTEMPERATURE=13, FANCPU=14, FANCHASSIS=15, USBPORT1=16, USBPORT2=17, USBPORT3=18, MODEM=19, CARDREADER=20, 3G=21, WIMAX=22, HWCF=23, LID=24, TYPE=25, PANELPOWER=26, TPD=27 [HIGH].
- On 701 the relevant supported features: WLAN (WLDG/WLDS), CAMERA (CAMG/CAMS), PANELBRIGHT (PBLG/PBLS, 0–15 levels), DISPLAYSWITCH (SDSP), LID (LIDG), CPUFV present but broken (see §8) [MEDIUM-HIGH].
- Backlight: `PBLG`/`PBLS`, **16 levels (0–15)**, registered as platform backlight [HIGH]. (eeectl on Windows could push brightness "twice brighter" than the BIOS table by writing the EC directly, the EC PWM range exceeds what ASUS exposes [MEDIUM].)

### Hotkey event codes (ACPI Notify on ASUS010/ATKD; eeepc-laptop keymap)
- 0x10 → KEY_WLAN (Fn+F2 wifi on); 0x11 → KEY_WLAN (wifi off variant)
- 0x12 → KEY_PROG1 (Fn+F6 "Task Manager" key on 701)
- 0x13 → KEY_MUTE (Fn+F7); 0x14 → KEY_VOLUMEDOWN (Fn+F8); 0x15 → KEY_VOLUMEUP (Fn+F9)
- 0x16 → KEY_DISPLAY_OFF; 0x1a → KEY_COFFEE, 0x1b → KEY_ZOOM (later models, not on 701)
- 0x20–0x2f → brightness notifications (NOTIFY_BRN range; low nibble encodes new level, Fn+F3/Fn+F4)
- 0x30–0x32 → KEY_SWITCHVIDEOMODE (Fn+F5 LCD/VGA toggle)
- 0x37 → KEY_F13 touchpad-toggle (later models)
- 0x50/0x51 → AC plug/unplug events (ignored by keymap) [HIGH, kernel source; 701-key assignment cross-checked against ASUS 701 user manual hotkey list].
- Physical Fn keys on 701 (user manual): Fn+F1 suspend (surfaces as ACPI sleep-button, not ATKD event [MEDIUM]), Fn+F2 WLAN toggle, Fn+F3 brightness down, Fn+F4 brightness up, Fn+F5 LCD/CRT switch, Fn+F6 Task Manager, Fn+F7 mute, Fn+F8 vol-, Fn+F9 vol+, Fn+F11 numlock overlay [HIGH].
- Delivery mechanism: EC raises SCI; DSDT `_Qxx` EC query methods issue `Notify(ATKD, code)`, standard ASUS pattern [MEDIUM, inferred, consistent with acpid `hotkey ATKD 000000xx` logs]. Volume/mute/wifi keys do NOT come through the i8042 as scancodes on the 701, without eeepc-laptop/asus_acpi loaded they do nothing (Ubuntu bug #232170) [MEDIUM-HIGH].

## 2. Embedded controller: ENE KB3310

- EC chip: **ENE KB3310** (KB3310QF), named as KBC in ASUS "Eee PC 4G" service documentation and in the eeepc-linux `eee.c` source [HIGH].
- Reached two ways:
  1. **Standard ACPI EC** on ports **0x62 (data) / 0x66 (cmd/status)**, used by kernel `ec_read`/`ec_write` and DSDT `EC0` region [HIGH].
  2. **KB3310 "Index IO" backdoor** on ISA ports **0x380–0x384**: write addr-high to **0x381**, addr-low to **0x382**, read/write data at **0x383**. Exposes the EC's ENTIRE 64KB internal space (ROM, RAM, SFRs), bypassing EC firmware. Indexed write ≈90 µs vs ≈2500 ms(sic, likely µs) for an EC transaction [HIGH, eee.c source].
- Register map (KB3310 XRAM address ↔ ACPI-EC offset = low byte; ACPI EC window is based at 0xF4xx):
  - **0xF451** (`ST00`, EC offset 0x51): CPU temperature, °C [HIGH]
  - **0xF463** (`SC02`, EC offset 0x63): fan PWM duty cycle 0–100 (%) [HIGH]
  - **0xF466/0xF467** (`SC05`/`SC06`, EC offsets 0x66/0x67): fan tach RPM high/low byte [HIGH]
  - **0xF4D3** (`SFB3`, EC offset 0xD3): flag byte; **bit 1 (0x02) = SF25 "fan manual"**: 1 = EC hands-off (host controls PWM), 0 = EC auto fan control [HIGH]
  - eeepc-laptop uses exactly EC offsets 0x63/0x66/0x67/0xD3 (`EEEPC_EC_FAN_PWM/HRPM/LRPM/CTRL`) via standard ACPI EC, confirming the offset↔0xF4xx mapping [HIGH].
  - **GPIO banks at 0xFC20+**: pin n → port `0xFC20 + (n>>3)`, mask `1<<(n&7)`. **Pin 0x66 (102) = CPU voltage select** (0=low, 1=high VID) → port 0xFC2C bit 6 [HIGH, eee.c].
- eeectl (Windows, by DCI, cpp.in/dev/eeectl) drove the same hardware through its closed `dciio` port-I/O driver: fan control + temperature module (same EC regs), FSB/PCIe clock via SMBus PLL, CPU voltage via the EC pin; the community `eee.ko` is the open reimplementation [MEDIUM-HIGH].
- Behavioral warning from eeepc-linux README: in manual fan mode the EC will happily let the CPU reach the 90 °C critical trip, then force thermal shutdown [HIGH].
- Battery reporting: standard **ACPI Control Method Battery** (`BAT0`) implemented in DSDT over EC registers (not a direct SBS/SMBus smart battery from the host's view). AC adapter is standard ACPI `AC0` [MEDIUM-HIGH].
- ACPI thermal zone `TZ00`: critical trip 88 °C, passive 85 °C (reads the EC temp reg through DSDT) [MEDIUM].

## 3. Wireless kill & camera enable, electrical mechanism

- Wifi module: **AR5BXB63** (AzureWave AW-GE780) half-mini **PCIe** card, Atheros **AR5007EG / AR2425** single-chip, PCI ID **168c:001c** ("AR242x"), at PCI **01:00.0** (behind ICH6-M PCIe root port 1) [HIGH].
- `WLDS`(1/0) **gates power to the mini-PCIe slot**: the card electrically disappears from/reappears on the PCI bus, a true kill, not just RF mute. State is preserved by EC/BIOS across reboots (a card disabled under one OS stays invisible to the next OS until re-enabled, bit OpenBSD users on the 701) [HIGH].
- Hotplug: DSDT sends Notify on PCIe root-port devices `\_SB.PCI0.P0P5 / P0P6 / P0P7`; modern eeepc-laptop handles this itself (registers notify handlers, then `pci_scan_single_device` on **bus 1 slot 0** / `pci_stop_and_remove_bus_device`; reads vendor ID 0xFFFFFFFF to detect absence). Xandros instead loaded `pciehp` with **`pciehp_force=1`** (no native PCIe hotplug interrupts wired) and echoed `/proc/acpi/asus/wlan` [HIGH].
- Toggle sequence used by Xandros/Gentoo scripts: unload madwifi modules → `echo 0/1 > /proc/acpi/asus/wlan` → (pciehp_force rescan) → reload `ath_pci` [HIGH].
- Camera: USB device **eb1a:2761** (eMPIA EM276x-based, UVC 1.00, enumerates high-speed on the EHCI bus, e.g. `usb 1-8`), driver **uvcvideo**. `CAMS`(1/0) (Xandros: `echo 1 > /proc/acpi/asus/camera`) **gates USB power/enable to the camera**, it drops off the bus entirely. Factory default: camera DISABLED in BIOS setup; an OS must run CAMS (or the user flips the BIOS option) before the camera exists on USB [HIGH].
- Bluetooth: none on 701 (BTHG/BTHS unused) [HIGH].

## 4. Suspend/resume (S3)

- S3 works and was used by Xandros (Fn+F1, lid). Under bare VESA/userspace-video: **s2ram whitelist entry `"ASUSTeK Computer INC.", "701"` requires `VBE_POST|VBE_MODE`**, i.e. the GMA900 needs the video BIOS re-POSTed + VBE mode restore after resume. With i915 KMS the driver re-inits the GPU and no re-POST is needed [HIGH, suspend-utils whitelist.csv].
- Debian-on-701 recommended boot params (Jessie/3.16 era): `pciehp.pciehp_force=1`, `acpi_osi=Linux` (needed for eeepc-laptop to bind on later BIOS revisions), optional `elevator=noop` [HIGH: Debian wiki DebianEeePC/Model/701].
- madwifi (`ath_pci`) had to be unloaded before suspend and reloaded after (Xandros scripts did this); ath5k later handled suspend natively [MEDIUM-HIGH].
- Lid switch: standard ACPI lid device (`LID`), plus `LIDG` state query via ASUS010; default Xandros action = sleep [MEDIUM-HIGH].
- RTC wake: standard ICH6 CMOS RTC (`/proc/acpi/alarm` on 2.6.21), no 701-specific quirk reports found either way [LOW].
- OpenBSD 4.2-era note: `zzz` "does not fully suspend" (pre-ACPI-suspend OpenBSD; APM path broken) [MEDIUM].

## 5. Known BIOS/DSDT bugs affecting bring-up

1. **Battery capacity units bug**: `_BIF/_BST` report design capacity 5200 mAh and design voltage 8400 mV, but `last full capacity`, `remaining capacity`, `warning/low`, granularity are actually **percent** (0–100, granularity 52) mislabeled as mAh. Breaks naive "remaining/last_full" math; OS must special-case [HIGH, /proc/acpi/battery dump, Gentoo wiki].
2. **CFVS (cpufv) hang**: the 701 DSDT implements CFVS but ASUS never supported it on this model (BIOS option removed); calling it can hard-hang the machine. Mainline eeepc-laptop **blacklists cpufv by DMI "701"/"702"** (commit ~2.6.34, sysfs writes return -EPERM; override via `cpufv_disabled`) [HIGH: LKML patch].
3. **acpi_osi**: later 701 BIOS revisions gate the ASUS010 interface on the reported OS; `acpi_osi=Linux` restores eeepc-laptop binding [MEDIUM-HIGH: Debian wiki, Fedora wiki].
4. **No native PCIe hotplug signaling** for the wifi slot, must force pciehp or handle ACPI Notify on P0P5/P0P6/P0P7 (see §3) [HIGH].
5. VBE mode table omits the panel's native mode (see §7) [HIGH].
6. 2.6.28/2.6.29-era oops in `acpi_ac_get_state()` (NULL deref reading /proc AC state) reported on 701, kernel bug exposed by this DSDT, fixed later [MEDIUM: LKML 0904.0/02355].
7. CPU is a 900 MHz Celeron M ULV 353 deliberately underclocked to **630 MHz via 70 MHz FSB** (BIOS/PLL default); /proc/cpuinfo claims "900MHz" model string at 630 MHz actual, confuses cpufreq assumptions; p4-clockmod known to destabilize the machine [HIGH].

## 6. Shipped OS (Xandros): ASUS's own integration choices

- Base: ASUS-customized Xandros, Debian 4.0 etch base, KDE (Easy Mode/Full Desktop). Kernel **2.6.21.4-eeepc** [HIGH, module paths, SvOlli's notes]. (One early eeeuser wiki snapshot claims "2.6.22" from a pre-release engineering sample [LOW]; 2.6.21.4 is the shipping kernel.)
- Drivers: **madwifi `ath_pci`** (madwifi-eeepc build; mainline madwifi lacked AR5007EG, ticket #1192) for wifi; **`atl2`** (out-of-tree Attansic; PCI **1969:2048**, device at 03:00.0) for the 100 Mbit ethernet; **`asus_acpi`** (modified) for hotkeys/toggles; **`uvcvideo`** (linux-uvc) for the camera; `snd-hda-intel` with **Realtek ALC662** codec: ALSA fixup **`model=eeepc-p701`** (patch_realtek.c ASUS_EEEPC_P701, mainlined in commit 291702f); note capture switch defaults OFF (must `amixer cset name='Capture Switch' on`) [HIGH].
- ath5k took over from madwifi for AR2425 around 2.6.30 (Debian: "free ath5k in 2.6.30+ supports AR2425"); early ath5k had AR2425 calibration bugs (e.g. "gain calibration timeout", "noisy environment" resets) [MEDIUM-HIGH].
- **SSD-wear strategy (ASUS's own)**: internal 4GB SSD split into: P1 = 2.7GB **ext2** OS partition mounted **read-only**, P2 = 1.3GB **ext2** user partition, union-mounted over P1 with **unionfs** (writes land only on P2); P3 = 8MB FAT32 (config); P4 = 8MB type-**0xEF** "EFI" partition used by **BootBooster** (BIOS caches POST results/memory dump there, starting at offset 0x200; contains BIOS+VBIOS copies; cuts boot several seconds). No swap partition configured. **F9 at boot** = recovery: wipe P2, restoring "factory" state without reinstall. GRUB + menu.lst bootloader [HIGH].
- Community follow-ons replaced unionfs with aufs to fix loopback-mount issues [MEDIUM].

## 7. Graphics/VESA prior art (console & X bring-up)

- VBE mode table of the 701 VBIOS offers **only 640x480**: modes `0x101` (8bpp), `0x111` (16bpp), `0x112` (32bpp), **no 800x480**. Any VBE/VESA-framebuffer OS is stuck at 640x480 (KolibriOS on the 701 confirms: 640x480 only) [HIGH, uvesafb vbe_modes dump, Gentoo wiki].
- For native-res console Linux users ran **915resolution** to patch a sacrificial mode entry in the shadowed VBIOS in RAM each boot (e.g. `915resolution 5c 800 480 32`, then `uvesafb mode=800x480-32@60`); transient, must rerun every boot [HIGH].
- Xorg (intel/i810 modesetting) programs the pipe directly and needs no VBIOS patch, working modeline: `"800x480" 29.58 800 816 896 992 480 481 484 497 -HSync +VSync` (29.58 MHz pixel clock) [HIGH]. Xandros shipped X at 800x480 natively this way [MEDIUM].
- Implication for a from-scratch OS: don't rely on VBE for the panel; program GMA900 (or patch the mode table à la 915resolution: find mode entry, rewrite resolution fields) [HIGH].

## 8. Alternative/hobby OS reports (bring-up hurdles observed)

- **Haiku** (2008, after targeted bug fixes; R1A4.1 confirmed on 701 4G Surf): boots from USB/SD (Anyboot), sound OK (HDA/OSS), ethernet OK, wifi eventually OK (initially only unencrypted/WEP; no WPA at first; ad-hoc never), early builds: APM/power mgmt dead, headphone jack dead, internal SSD not recognized until reformatted; CD boot path N/A [MEDIUM-HIGH].
- **OpenBSD** (4.2–4.9 era): installs and runs; SSD is `wd0` ("Silicon Motion SM223" behind ICH6 PATA-compat); azalia0 sound OK; `hw.setperf` works; **atl2 ethernet unsupported** at first (Attansic 1969:2048 "not configured") until OpenBSD grew a driver; **ath(4) could not init the AR5007EG** ("unable to reset hardware", AR5212 wakeup failures) for a long time, and the card is invisible entirely if it was ACPI-disabled by the previous OS; suspend incomplete; X had artifacts initially [HIGH].
- **FreeBSD**: AR2425 not supported by ath(4)/HAL for years (worked in OpenBSD/Linux first); the wifi was the canonical blocker [MEDIUM].
- **NetBSD**: installs (video walkthroughs exist); no detailed blocker list found [LOW].
- **KolibriOS**: boots from USB (MBR tool), runs at **640x480 VESA** (no 800x480, see §7), touchpad works as a plain PS/2 mouse, internal SSD detection flaky (`/bd1/1` sometimes lost); wifi/ethernet/sound unaddressed [MEDIUM].
- **ReactOS / MenuetOS / Minix3**: no substantive 701 bring-up reports found [LOW/none].
- Pattern: the three universal hurdles are (1) Atheros AR2425 wifi (driver + the ACPI power-gate), (2) 800x480 not in VBE, (3) platform hotkeys/toggles needing the ASUS010 ACPI methods or direct EC pokes.
- Touchpad: PS/2 (i8042 AUX), **Elantech** on most 701s (kernel reports "ETPS/2 Elantech"; some units Synaptics); basic PS/2 mouse protocol works everywhere without the extension (KolibriOS/Haiku), full multitouch needs psmouse elantech extension (mainline-enabled around 2.6.32) [MEDIUM-HIGH].
- Keyboard: standard i8042 KBD, 80-key; no bring-up quirks reported [HIGH].

## 9. Battery / charging

- Pack: 4-cell Li-ion, **7.4 V, 5200 mAh, 2S2P** (4G/8G models); 4400 mAh on 4G Surf/2G Surf; ACPI design voltage 8400 mV, model string "701", OEM "ASUS", type LION [HIGH].
- Reporting path: ACPI CM battery via EC (§5 bug: values in %) [HIGH].
- Charge start/stop thresholds: **no ACPI method or EC interface known on the 701**; not supported by eeepc-laptop (that feature never existed for this platform) [MEDIUM, absence of evidence across all sources].
- Status LEDs: power (green, blinks in S3), battery-low (red), disk (blue), wifi (aqua), wifi LED driven by the EC/card, not host-controlled [MEDIUM].
- Charger input: 9.5 V × 2.315 A (22 W) [HIGH].

## 10. Clock tree / overclocking path (eeectl & eee.ko)

- FSB clock generator: **ICS9LPR426A** PLL (SetFSB supports it for "standard Eee PC"; 1000-series used ICS9LPR427A) [MEDIUM-HIGH].
- Bus: PLL sits on **SMBus at 7-bit address 0x69**, reached via the ICH6-M i801 SMBus controller (PCI 00:1f.3, Linux i2c adapter 0). Access = SMBus **block read/write, command 0**, 32-byte config blob; a block op takes ≈150 ms [HIGH, eee.c].
- FSB frequency = f(N,M): **byte[12] = N multiplier, byte[11] bits 5:0 = M divisor**. Stock 70 MHz = N=70, M=24 (→630 MHz CPU, 9× multiplier @ quad-pumped 280 MT/s); N=100, M=24 → 100 MHz FSB → the chip's rated 900 MHz. Must step N up gradually (70→85→100) or the machine locks [HIGH].
- Third knob: **CPU voltage select via KB3310 GPIO pin 0x66** (Index-IO port 0xFC2C bit 6): 0=low VID, 1=high VID, needed for stable 100 MHz; also what eeectl's "voltage" flag and `/proc/eee/fsb`'s third field toggle. EC also gets told 70-vs-100 mode ("0=70MHz, 1=100MHz" flag) [HIGH, eee.c + eeeuser howto].
- eeectl additionally set PCIe clock (v0.2.2+) via the same PLL blob [MEDIUM].
- Side effects @100 MHz: +5–10% current draw (measured 1223→1271 mA at 90 MHz), occasional LCD/VGA degradation, not all RAM stable; p4-clockmod interacts badly [MEDIUM-HIGH].

## 11. SSD wear / write mitigation (community practice on the 4GB SM223 SSD)

- ASUS's own: ext2 (no journal) + read-only rootfs + unionfs overlay (§6) [HIGH].
- Community consensus: ext2 over ext3 (journal writes considered harmful/wasteful on this slow ~6 MB/s-write SSD; counter-camp argued ext3 fine, debate never settled empirically) [MEDIUM]; `noatime` (or relatime) mount option universal advice [HIGH]; tmpfs for `/tmp`, `/var/log`, browser cache [HIGH]; `elevator=noop` for the SSD [MEDIUM-HIGH]; watch inode exhaustion on small ext2 partitions (`mke2fs -N`) [MEDIUM]; swap avoided or on SD card [MEDIUM].

## 12. Quick reference, buses/IDs seen by the OS on this platform (integration view)

- ACPI: `ASUS010` (ATKD hotkeys), `PNP0C09` EC at 0x62/0x66, BAT0, AC0, LID, SLPB, TZ00; PCIe root ports `\_SB.PCI0.P0P5/P0P6/P0P7` (wifi behind port 1 → PCI bus 01, ethernet on PCI bus 03) [HIGH].
- Platform I/O: EC Index-IO 0x380–0x384; i8042 at 0x60/0x64; SMBus (i801/ICH6) hosts PLL @0x69 [HIGH].
- Key USB: camera eb1a:2761 (when CAMS=1 and BIOS-enabled) [HIGH].
- Linux driver stack for platform bits: `eeepc-laptop` (hotkeys, rfkill+PCI hotplug, backlight, fan hwmon), `ac`/`battery`/`button`/`thermal` (standard ACPI), `psmouse` (+elantech), `atkbd`, `i2c-i801` (for PLL games), `uvcvideo`, `ath5k`/madwifi, `atl2`, `snd-hda-intel` (ALC662, model=eeepc-p701) [HIGH].

## UNCERTAINTIES
- Exact EC temperature register used by Windows eeectl not independently confirmed (its dciio driver is closed-source); 0xF451/EC-offset-0x51 comes from the eeepc-linux eee.ko reimplementation and is very likely what eeectl reads, but no eeectl.ini dump with register addresses was recovered.
- PLL part number ICS9LPR426A on the 701 is from SetFSB's support list ('standard Eee PC models'); no board photo/silkscreen confirmation for the 701 specifically was found (the eee.ko module never names the chip, only SMBus address 0x69).
- Whether Fn+F1 (sleep) surfaces as a standard ACPI sleep button (SLPB) event vs an ATKD hotkey code on the 701, inferred SLPB from absence of a sleep code in the eeepc-laptop keymap; not directly verified from a 701 acpid log.
- Which exact 701 BIOS revision started requiring acpi_osi=Linux for the ASUS010 device to be exposed, documented for the model line generally, but no per-BIOS-version matrix found.
- Whether the DSDT _Qxx→Notify(ATKD) delivery detail is exactly as described, standard ASUS pattern, but the 701 DSDT disassembly itself was not obtained (worth extracting from a firmware image for register-level ground truth, including the WLDS/CAMS implementations and which EC GPIOs they flip).
- Touchpad vendor split: most evidence says Elantech (ETPS/2) on the 701, some period sources say Synaptics on some units; proportion/serial ranges unknown. Ubuntu bug #441013 title says 'Synaptic Touchpad on my Eee PC 701'.
- RTC wake (S3/S5 alarm) behavior untested in found sources, assumed standard ICH6 RTC, no 701-specific reports either way.
- No substantive bring-up reports found for Minix3, ReactOS, or MenuetOS on the 701 (absence of reports, not evidence of failure).
- FreeBSD wiki AsusEee page was unreachable (Anubis bot-wall); FreeBSD specifics are from secondary forum evidence (AR2425 unsupported by ath(4) for years), driver-by-driver FreeBSD status on the 701 not fully verified.
- The claim that KolibriOS saw the touchpad 'as a USB mouse due to BIOS configuration' is from a forum paraphrase and is almost certainly a PS/2 device (possibly BIOS legacy emulation confusion); treat as anecdote.
- Xandros kernel version: 2.6.21.4-eeepc is well attested (module paths, SvOlli); one early eeeuser wiki snapshot from a pre-release engineering sample claimed 'kernel 2.6.22': 2.6.21.4 is better supported for shipping units.
- Whether the wifi kill also gates the aqua wifi LED via EC vs via the card's own LED pin, not determined.

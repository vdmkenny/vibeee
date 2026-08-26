# ASUS Eee PC 701 4G ("Eee PC 4G", 2007): Peripheral Hardware Inventory
Scope: peripherals (display, GPU, audio, WiFi, Ethernet, input, webcam, card reader, USB, absences). Confidence: HIGH = 2+ independent sources or primary source (kernel code / real lspci dumps); MEDIUM = single good source or strong inference; LOW = plausible but unverified.

## 0. Platform context (verbatim lspci topology from a real 701 4G) [HIGH]
Full `lspci` posted for a 701 4G (unixboard.de thread 34470), IDs cross-checked against `lspci -nn` from a second 701 4G (Launchpad Q#57805) and antiX inxi output:

| Addr | Device | ID |
|---|---|---|
| 00:00.0 | Host bridge, Mobile 915GM/PM/GMS/910GML DRAM controller, rev 04 | 8086:2590 |
| 00:02.0 | VGA controller, Mobile 915GM/GMS/910GML (GMA 900), rev 04 | 8086:2592 |
| 00:02.1 | Display controller (2nd function of IGD), rev 04 | 8086:2792 |
| 00:1b.0 | ICH6-M High Definition Audio, rev 04 | 8086:2668 |
| 00:1c.0 | ICH6 PCIe root port 1 → bus 01 (WiFi) | 8086:2660 [HIGH for presence; numeric ID from ICH6 datasheet, MEDIUM] |
| 00:1c.1 | ICH6 PCIe root port 2 → bus 02 (empty) | 8086:2662 [MEDIUM] |
| 00:1c.2 | ICH6 PCIe root port 3 → bus 03 (Ethernet) | 8086:2664 [MEDIUM] |
| 00:1d.0–.3 | ICH6 USB UHCI #1–#4, rev 04 | 8086:2658 / 2659 / 265a / 265b [HIGH; "#4 = 0x265b" seen in 701 dump] |
| 00:1d.7 | ICH6 USB2 EHCI, rev 04 | 8086:265c [HIGH] |
| 00:1e.0 | 82801 Mobile PCI bridge, rev d4 (nothing behind it) | 8086:2448 [MEDIUM for ID] |
| 00:1f.0 | ISA/LPC bridge, 82801FBM (ICH6-M) | 8086:2641 [HIGH presence; ID standard] |
| 00:1f.2 | IDE interface: ICH6-M SATA controller (combined/IDE mode) | 8086:2653, subsystem **1043:82d8** [HIGH, from lspci + mainline ata_piix patch] |
| 00:1f.3 | ICH6 SMBus | 8086:266a [MEDIUM for ID] |
| 01:00.0 | Atheros AR5007EG/AR242x 802.11bg, rev 01 | 168c:001c |
| 03:00.0 | Attansic L2 100Mbit Ethernet, rev a0 | 1969:2048 |

- Chipset marketing name: **Intel 910GML** GMCH + **ICH6-M** (Wikipedia); lspci string is the shared 915GM/GMS/910GML ID, the silicon reports 8086:2590/2592 either way [HIGH for IDs; "910GML" naming MEDIUM].
- Board subsystem ID used on ICH functions: 1043:82d8 [HIGH].
- No 00:1f.1 PATA function is exposed; the soldered 4GB SSD (Silicon Motion controller, "SILICONMOTION_SM" ATA identify string) sits as a **PATA UDMA device mapped through the 8086:2653 function** (ICH6-M combined mode), driver `ata_piix`. Mainline quirk: `ich_laptop[]` short-cable entry `{ 0x2653, 0x1043, 0x82D8 } /* ICH6M on Asus Eee 701 */`, drive is soldered (no cable), quirk lifts the 40-wire limit, 25.3→34.0 MB/s [HIGH: LKML patch, April 2008].

## 1. Display: 7" 800×480 internal panel
- Resolution 800×480 (WVGA), 7.0"; X reports 800x480@60.01 Hz [HIGH].
- Interface: **single-channel LVDS** from the GMA 900 LVDS port. Evidence: community pinout of the "EEE-PC LCD" cable shows LVDS pairs (a0±, a1±, clk±) + backlight lines; Eee PC 900 (1024×600 LVDS) panels were physically installed into 701s using the same cable [HIGH for LVDS; pin-level detail LOW].
- Panel module: teardown of the sibling EeePC 2G Surf (700, same 7" display assembly) identified an **AU Optronics A070VW04** panel, LED backlit (Electronics360 teardown) [MEDIUM for 701, same display family; ASUS multi-sourced panels]. Replacement market treats **HannStar HSD070IDW1** (7", 800×480) as compatible [MEDIUM]. AUO A070VW04 is a 60-pin 7" 800×480 LVDS panel [MEDIUM].
- Color depth: panels of this class are 6-bit/color (262K native, "16.2M/16.7M" via FRC/dithering); ASUS spec sheet claims "16M colors", i.e. **18-bit LVDS with dithering** [MEDIUM].
- Backlight: **WLED (LED), not CCFL**, replacement screens for 700/701 sold as LED type; no inverter in the LED path [MEDIUM-HIGH].
- Backlight brightness control path: ACPI control methods on the ASUS010 device, get `PBLG` / set `PBLS` (eeepc-laptop `cm_getv/cm_setv`, index `CM_ASL_PANELBRIGHT = 9`); **16 levels (0–15)** [HIGH, kernel driver source]. Fn brightness keys are serviced by BIOS/EC autonomously (brightness changes even with no OS driver) and additionally raise ACPI notify codes 0x20–0x2f (`NOTIFY_BRN_MIN 0x20`, `NOTIFY_BRN_MAX 0x2f`) [HIGH]. Whether the PWM physically originates from the EC or from the GMCH `BLC_PWM_CTL` pin is not documented; the ACPI/EC path is the verified one [LOW on physical PWM source].
- Boot behavior: BIOS/VBIOS brings the LVDS panel up itself; VGA text mode is upscaled to the panel by the GMCH panel fitter, so the display works before any OS graphics driver [MEDIUM]. Caveat: the VBIOS **VBE mode table does not include a native 800×480 mode**: VESA-framebuffer OSes needed `915resolution` to patch a mode entry (e.g. mode 0x32) to 800×480 [MEDIUM].

## 2. GPU: Intel GMA 900 (Gen3, i915-class)
- PCI: 00:02.0 = 8086:2592 (VGA), 00:02.1 = 8086:2792 (second "Display controller" function, not an independent head; drivers ignore it) [HIGH].
- Stolen memory: BIOS pre-allocates 8MB UMA; Linux/X see **7932 KB stolen** on this platform; DVMT can extend dynamically via GTT [MEDIUM].
- Firmware: **none required**, no microcode/blob loading; the only "firmware" involved is the VBIOS/VBT already in the system ROM [HIGH].
- Public docs: **no official public PRM for Gen3** (Intel's public PRM series starts at 965/G35). A public "Intel 915G/915GV/910GL GMCH" datasheet/whitepaper covers config/BAR level. Authoritative register references for a from-scratch driver: Linux `i915` (gen3 paths, `i915_reg.h`), X.org `xf86-video-intel`, and the 965 PRM (display block register layout is largely shared) [HIGH].
- Key facts for a from-scratch modesetting driver (from i915/xf86-video-intel; offsets from `i915_reg.h`) [HIGH for offsets, MEDIUM for 701-specific wiring]:
  - BARs on 915-class: MMIO (MMADR), graphics aperture (GMADR), and a **separate GTT BAR** (GTTADR), unlike gen4+ where GTT lives at MMIO+512K [MEDIUM].
  - 2 pipes (A/B), 2 display planes (A: 0x70180 `DSPACNTR`, B: 0x71180), pipe timing blocks at 0x60000 (A) / 0x61000 (B), `PIPEACONF` 0x70008 / `PIPEBCONF` 0x71008, `PIPEASRC` 0x6001c.
  - DPLLs: `DPLL_A` 0x06014, `DPLL_B` 0x06018, dividers `FPA0/FPB0` 0x06040/0x06048. Gen3 LVDS PLL limits (kernel `intel_limits_i9xx_lvds`): 96 MHz refclk, VCO 1.4–2.8 GHz, m1 8–18, m2 3–11, p1 1–8, p2 = 14 (slow)/7, single-channel LVDS uses p2=14.
  - LVDS port control: reg 0x61180; on gen3 mobile LVDS is used on **pipe B** (driver-enforced convention) [MEDIUM].
  - Panel fitter: `PFIT_CONTROL` 0x61230 / `PFIT_PGM_RATIOS` 0x61234 (does the text-mode/non-native upscale; gen3 dithering enable lives here) [MEDIUM].
  - Backlight PWM regs (if wired): `BLC_PWM_CTL2` 0x61250, `BLC_PWM_CTL` 0x61254.
  - VGA DAC port: `ADPA` 0x61100; legacy VGA plane disable: `VGACNTRL` 0x71400.
  - DDC/EDID via GMBUS (0x5100–0x5120) or bit-banged GPIO regs (0x5010+); the internal panel likely has **no EDID**, native timing should come from the VBT (LFP DTD) in the VBIOS image or be hardcoded [MEDIUM].
- External VGA (DB15): driven by the same GMA 900 ADPA DAC; dual-view supported. ASUS spec: up to **1600×1200** external [HIGH]; GMA 900 DAC itself is capable of 2048×1536 [MEDIUM].

## 3. Audio: Intel HDA (ICH6) + Realtek ALC662
- Controller: 00:1b.0, 8086:2668, ICH6 HDA (Azalia 1.0; spec public). Driver `snd_hda_intel` [HIGH].
- Codec: **Realtek ALC662** (rev1, HDA vendor/device 0x10ec0662), codec subsystem ID **1043:82a1**, proven by the mainline quirk `SND_PCI_QUIRK(0x1043, 0x82a1, "ASUS Eeepc", ALC662_ASUS_EEEPC_P701)` (commit 291702f0, ALSA model `eeepc-p701`) [HIGH]. Claims of ALC660/ALC861 elsewhere are wrong for the 701 [HIGH]. Codec address on the link: 0 (typical single-codec layout) [LOW, not directly verified].
- Pin/port layout (register-level, from the kernel eeepc-p701 preset) [HIGH]:
  - NID **0x14** = internal stereo speakers ("iSpeaker", amp mute control).
  - NID **0x1b** = headphone/line-out jack, **jack-detect enabled** (unsolicited `HP_EVENT`; automute of 0x14 via `alc262_hippo1_automute`). DAC NID 0x02 feeds it.
  - NID **0x18** = external mic jack ("e-Mic"), **jack-detect enabled** (`MIC_EVENT` auto-switches capture source).
  - NID **0x19** = internal mic ("i-Mic"). Capture input mux: e-Mic = index 0, i-Mic = index 1; input mixer NID 0x0b; ADC mux NIDs 0x22/0x23.
- So: stereo speakers, HP jack w/ sense, external mic jack w/ sense, internal mic, all analog; no S/PDIF wired [HIGH]. Modern kernels handle it with the auto-parser + pincfg (the explicit model was removed as unnecessary) [HIGH].
- ALC662 datasheet: circulates publicly (e.g. datasheet4u); plus HDA class spec, sufficient for a from-scratch driver [MEDIUM].

## 4. WiFi: Atheros AR2425 (AR5007EG) on mini PCIe
- PCI 01:00.0, **168c:001c** rev 01 ("AR242x / AR5007EG 802.11bg PCI-Express") [HIGH].
- Physical: full-height **PCI Express Mini Card**: AzureWave **AW-GE780** (label AR5BXB63, AR5007EG reference design), ASUS P/N 04G033054040 (V.C) / 04G033054041 (V.D), named in the 701 service manual [HIGH].
- Silicon: single-chip AR2425 ("Swan"); ath5k probe on the 701 prints `Atheros AR2425 chip found (MAC: 0xe2, PHY: 0x70)`: MAC srev 0xe2 (AR2425), RF 0x70 (RF2425) [HIGH].
- Capabilities: **802.11b/g only** (no 802.11a despite generic "abg" lspci strings) [HIGH].
- Drivers: shipped Xandros used MadWifi (`ath_pci` + binary HAL, interface ath0); mainline driver is **ath5k** (since 2.6.25; interface wlan0) [HIGH].
- Firmware: **none**, ath5k loads no blobs; per-board calibration/MAC data comes from the card's own EEPROM [HIGH].
- Register documentation: no public datasheet; reverse-engineered register headers exist in OpenBSD `ar5k` (Reyk Floeter), MadWifi OpenHAL, and Linux ath5k (`reg.h`, later sanctioned by Atheros/Qualcomm), adequate for a from-scratch driver [HIGH].
- Fn+F2 kill switch: ACPI method (CM_ASL_WLAN, `WLDG`/`WLDS`) **powers the card off and it hot-unplugs from the PCIe bus** (eeepc-laptop watches root ports \_SB.PCI0.P0P5/P0P6/P0P7 and rescans); an OS must tolerate the device disappearing/reappearing [HIGH].

## 5. Ethernet: Attansic (Atheros) L2 Fast Ethernet
- PCI 03:00.0, **1969:2048** rev a0, PCIe x1, 10/100 Mbit, integrated PHY [HIGH].
- Linux driver **atl2** (antiX inxi showed `atl2 v: 2.2.3`); mainlined circa 2.6.26–2.6.28; earlier distros used the out-of-tree vendor atl2 [HIGH for driver name; MEDIUM for merge version].
- Docs: no public datasheet; references = Linux `atl2.c` and FreeBSD `ae(4)` (independent implementation) [MEDIUM].

## 6. Touchpad
- Original 701/4G units: **Synaptics PS/2 touchpad** on the i8042 AUX port, real 701 4G dmesg shows `SynPS/2 Synaptics TouchPad` (Ubuntu bug #441013; TinyCore forum id.). Protocol: Synaptics absolute mode, fully documented in the public "Synaptics TouchPad Interfacing Guide", single finger absolute + pressure; edge-scroll zones done in software; no true multi-finger [HIGH].
- Conflicting claim: Debian wiki's model table lists "Elantech" for the 701. Elantech pads (v1 protocol, e.g. fw 02.00.22 "EF013"; kernel `elantech.c`, magic-knock detect, reg_10/reg_11 config, 4-byte absolute packets) definitely appear in the Eee PC line (900 onward, possibly late 701/701SD builds), but for the original 701 4G, Synaptics is the better-supported answer. Plan for both: probe Synaptics `0xE8`-sequence ID first, then Elantech magic knock [Synaptics on 701 4G: HIGH; existence of Elantech 701 variants: LOW-MEDIUM].
- Either way: standard PS/2 via i8042 AUX; no I2C/SMBus touchpad path [HIGH].

## 7. Keyboard, EC, hotkeys
- Keyboard: PS/2 (AT set 2) through the i8042 interface; controller function provided by the **ENE KB3310** EC (128-pin LQFP, LPC-attached, 18×8 key matrix), identified in the 700/701 service documentation and teardown [HIGH for KB3310 presence; package detail MEDIUM].
- Normal keys and Fn-navigation combos emit ordinary scancodes. Media/system Fn combos are handled by the EC/BIOS and surfaced as **ACPI notifications on the ASUS010 device** (HID `ASUS010`, driver eeepc-laptop), not scancodes [HIGH]. Event codes (eeepc-laptop keymap) [HIGH for codes; pairing to specific Fn keys MEDIUM]:
  - 0x10 / 0x11 → WLAN toggle (Fn+F2)
  - 0x12 → PROG1 ("Task manager" key, Fn+F6)
  - 0x13 → Mute (Fn+F7); 0x14 → Vol- (Fn+F8); 0x15 → Vol+ (Fn+F9)
  - 0x16 → display/backlight off (Fn+F5)
  - 0x20–0x2f → brightness notifications (Fn+F3/F4; firmware already applied the change)
  - Fn+F1 (sleep) → ACPI sleep button event
- ASUS010 control methods (get/set pairs, index = CM_ASL bit): WLAN=0 (`WLDG/WLDS`), Bluetooth=1 (unused on 701), CAMERA=4 (`CAMG/CAMS`, cuts USB power to the webcam), DISPLAYSWITCH=8, PANELBRIGHT=9 (`PBLG/PBLS`), LID=24, TPD=26 [HIGH].
- EC RAM registers (eeepc-laptop hwmon, apply to 701) [HIGH]: fan PWM duty (%) = **0x63**; fan RPM = **0x66** (hi) / **0x67** (lo); manual-fan-control bit ("SF25") in **0xD3**. Windows tool `eeectl` manipulates the same EC + does FSB overclock via the ICS9LPR clock generator over SMBus [MEDIUM for clockgen detail].

## 8. Webcam (present on 4G; absent on 4G Surf/2G Surf)
- USB **VID:PID eb1a:2761**, eMPIA Technology; usb.ids name "EeePC 701 integrated Webcam" [HIGH].
- **UVC 1.0 class-compliant** (uvcvideo: "Found UVC 1.00 device (eb1a:2761)"); no vendor driver needed. The Syntek/stk11xx camera belongs to other Eee models (e.g. some 900s), **not** the 701 [HIGH].
- 0.3 MP: 640×480 max, YUYV/UYVY 4:2:2, 30 fps [HIGH].
- Connects at USB 2.0 high speed on the EHCI bus; observed as port 8 of the root hub (`usb 1-8` / `5-8` depending on bus numbering) [MEDIUM].
- BIOS: Advanced → Onboard Devices Configuration → "Onboard Camera [Enabled/Disabled]", when disabled it does not enumerate at all; additionally runtime power toggle via ACPI CM_ASL_CAMERA (on the 900 this toggle also kills the card reader, shared power rail; likely similar wiring caution on 701) [HIGH for BIOS option; MEDIUM for shared-rail caveat].

## 9. SD/MMC card reader
- **Internal USB 2.0 device, plain USB Mass Storage class**: NOT PCI SDHCI, NOT PCI-attached [HIGH].
- USB ID **0951:1606** (Kingston Technology VID), usb.ids name "Eee PC 701 SD Card Reader [ENE UB6225]", silicon is an **ENE UB6225**; same ID seen across 701 and 900 units on linux-hardware.org [HIGH].
- Class 08/06/50 (SCSI transparent, bulk-only); driver `usb-storage` (or `uas`-era binding on later kernels) [HIGH].
- Attaches high-speed on the EHCI root hub, observed at port 5 (`usb 1-5`) on the 700-series [MEDIUM].
- Accepts SD/SDHC/MMC (SDHC works; one archived report of a specific SDHC card causing repeated USB resets) [MEDIUM].
- BIOS: "Onboard Card Reader [Enabled/Disabled]" under Onboard Devices Configuration [HIGH].
- One teardown claims the KB3310 EC "also serves as card reader controller", contradicted by the USB enumeration evidence (UB6225); the USB story is far better supported [HIGH].

## 10. USB topology
- ICH6-M: 8 USB 2.0 ports total: 4 UHCI controllers (2 ports each; 8086:2658/2659/265a/265b at 00:1d.0–.3) as full-/low-speed companions + 1 EHCI (8086:265c at 00:1d.7) covering all 8 [HIGH].
- Physical external ports: **3× USB 2.0** (1 left, 2 right) [HIGH].
- Internal USB consumers: webcam (eb1a:2761, port ~8) and card reader (0951:1606, port ~5), total 5 of 8 ports used; remaining ports unconnected [MEDIUM for exact port numbers; HIGH for which devices are internal-USB].
- Which physical external port maps to which controller port: undocumented [LOW/unknown].

## 11. Confirmed absences [all HIGH unless noted]
- **No Bluetooth** (CM_ASL_BLUETOOTH exists in the ACPI ASL but no radio fitted).
- **No modem** (no RJ-11; case has a blanked cutout only) [HIGH; cutout detail MEDIUM].
- **No ExpressCard / PCMCIA slot.**
- **No SATA devices**: ICH6-M SATA function (8086:2653) is present in IDE/combined mode, but the only disk is the soldered PATA-behind-2653 SSD; SATA ports unwired.
- No SDHCI PCI controller, no FireWire, no IrDA, no serial/parallel, no TPM observed in any 701 lspci dump.
- 701SD/701SDX are DIFFERENT machines (Realtek RTL8187SE WiFi etc.), do not use their data for the 701 4G.

## Key sources
- Full lspci (701 4G): [unixboard.de thread](https://www.unixboard.de/threads/eeepc-701-4g.34470/); lspci -nn IDs: [Launchpad Q#57805](https://answers.launchpad.net/ubuntu/+question/57805); [antiX forum archive (inxi)](https://antix-skidoo.github.io/archive/antix-jessie-auf-einem-eee-701-4g-aktualisierungsv-t5485.html)
- Audio quirk commit (pin NIDs, SSID 1043:82a1): kernel commit 291702f017efdfe556cb87b8530eb7d1ff08cbae; [ALSA changelogs](https://www.alsa-project.org/wiki/Detailed_HDA_changes_v1.0.24_v1.0.25)
- ata_piix Eee 701 short-cable patch (2653/1043:82d8): [LKML](https://lkml.iu.edu/hypermail/linux/kernel/0804.2/1984.html)
- eeepc-laptop.c (ASUS010, CM bits, EC fan regs, keymap): torvalds/linux `drivers/platform/x86/eeepc-laptop.c`
- WiFi module: [TechInfoDepot AW-GE780](https://techinfodepot.shoutwiki.com/wiki/AzureWave_AW-GE780); AR2425 dmesg: [Launchpad #332429 et al.](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/332429)
- Webcam: [DeviceHunt eb1a:2761](https://devicehunt.com/view/type/usb/vendor/EB1A/device/2761); [Hackaday.io webcam-reuse log](https://hackaday.io/project/110436-laptop-webcam-reuse-made-simple/log/164054-successfully-reused-cameras-not-working-cameras)
- Card reader: [linux-hardware.org usb:0951-1606](https://linux-hardware.org/?id=usb:0951-1606); [Debian bug 623943](https://lists.debian.org/debian-kernel/2013/06/msg01021.html)
- Touchpad: [Ubuntu bug #441013](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/441013) (SynPS/2 on 701 4G); [Debian wiki DebianEeePC/Models](https://wiki.debian.org/DebianEeePC/Models) (Elantech claim); kernel `Documentation/input/elantech.txt`
- Panel: [Electronics360 EeePC 2G Surf teardown](https://electronics360.globalspec.com/article/3610/asus-eeepc-2gsurf-bk-notebook-computer-teardown) (AUO A070VW04, LED); [Accupart 700/701 screen listing](https://www.accupart.co.uk/products/asus-eee-pc-asus-700-701-701sd-7-laptop-screen) (LED, matte)
- Platform: [Wikipedia Asus Eee PC](https://en.wikipedia.org/wiki/Asus_Eee_PC); [Eee PC 4G BIOS/service manual chapter (scribd)](https://www.scribd.com/doc/140822438/Service-Manual-Asus-Eee-PC-4G-701-Chapter-06); [915resolution](http://915resolution.mango-lang.org/); [Intel Linux PRM index (965+ only)](https://www.intel.com/content/www/us/en/docs/graphics-for-linux/developer-reference/1-0/overview.html)

## UNCERTAINTIES
- Original panel part number for the 701 4G specifically: AUO A070VW04 is confirmed only for the 2G Surf (700) teardown; ASUS multi-sourced 7" panels, so 701 units may carry HannStar or CPT equivalents. Exact LVDS timing (pixel clock ~33 MHz class) not pinned from a datasheet.
- Physical source of the backlight PWM (EC pin vs GMCH BLC_PWM_CTL) is undocumented; only the ACPI PBLG/PBLS control path is verified.
- HDA codec link address assumed 0 (single codec); no alsa-info dump from a 701 was found to confirm the address field.
- Touchpad: whether any original 701 4G units shipped with Elantech pads (Debian wiki claim) vs Synaptics-only; evidence strongly favors Synaptics but Elantech variants cannot be excluded (later production / 701SD).
- Exact EHCI root-hub port numbers for webcam (port 8) and card reader (port 5) are inferred from a small number of dmesg reports (700/900-series included); external-port-to-controller mapping unknown.
- ICH6 PCIe root port / SMBus / PCI-bridge numeric device IDs (2660/2662/2664/266a/2448) taken from the ICH6 datasheet family standard, not from a numeric lspci -n dump of a 701.
- atl2 mainline merge version (2.6.26 vs 2.6.28) not pinned precisely.
- VGA DAC maximum resolution: ASUS spec says 1600x1200; GMA 900 DAC capability 2048x1536 not verified on this machine (Wikipedia also contains an odd '1600x1280' figure).
- Whether the 701 (like the 900) cuts card-reader power when the camera ACPI toggle is off (shared USB power rail) was not directly verified for the 701.
- Stolen-memory figure 7932 KB seen on 915GM Eee-class systems; BIOS DVMT options screen for the 701 not directly inspected.

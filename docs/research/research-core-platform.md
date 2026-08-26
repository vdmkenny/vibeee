# ASUS Eee PC 701 4G ("Eee PC 4G"): Core Platform Hardware Inventory
Target: from-scratch OS (bootloader/kernel/drivers). Confidence: HIGH = verbatim dump/datasheet-level, multi-source; MEDIUM = single good source or strong inference; LOW = weak/uncertain.
Primary sources: ivc.no wiki "Eee PC Research" (teardown of an actual 701 4G, via web.archive.org), LKML dmesg of a 701 (lkml.iu.edu 0904.0/02355), Debian bug #604101 mbox (701SD, verbatim lspci -knn + /proc/cpuinfo + /proc/interrupts), Launchpad bug #195221 (701 dmesg ATA), CPU-Z validation valid.x86.fr/3391j0 (Asus 701), ASUS 701 service manual (via search extracts), cpu-world, notebookcheck, jkkmobile (ATTO screenshot read directly), Debian/Gentoo/Ubuntu wikis, lfsb source.

## 1. CPU: HIGH (multiple verbatim dumps)
- **Intel Celeron M ULV 353**, Dothan core (90 nm), **CPUID signature 0x06D8** = family 6, model 13 (0xD), stepping 8 (Dothan **C-0** stepping). Brand string (verbatim, incl. padding): `Intel(R) Celeron(R) M processor          900MHz`, the brand string carries no "353". HIGH.
- Part numbers: RJ80536VC900512 / LE80536VC900512; sSpec **SL7F7 / SL7QX**; package Micro-FCBGA 479-ball, **soldered** (not socketed). TDP 5 W (some sources 5.5 W). MEDIUM-HIGH (cpu-world/Intel MDDS).
- **L2 = 512 KB** (NOT 1 MB): confirmed by `/proc/cpuinfo` (`cache size : 512 KB`), CPU-Z validation, and ivc teardown ("Celeron M 900 MHz 353 ULV 512k"). Any source claiming 1 MB (Dothan-1024) is wrong for this part. HIGH. L1: 32 KB I + 32 KB D; line size 64 B (`clflush size : 64`). HIGH.
- **Clocks**: rated 900 MHz = 9 × 100 MHz FSB (400 MT/s quad-pumped). Shipped **underclocked to 630 MHz by the BIOS programming the external clock generator to BCLK = 70 MHz** (FSB 280 MT/s); multiplier fixed at 9. Measured: `Detected 630.113 MHz processor`, CPU-Z: 630 MHz, ×9, bus 70 MHz. BogoMIPS 1260.73 (lpj=2100376). The multiplier is locked; ALL "overclocking" (eeectl/SetFSB) works by reprogramming the PLL back to 100 MHz over SMBus. HIGH.
- **CPUID feature flags (verbatim Linux dump)**: `fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov clflush dts acpi mmx fxsr sse sse2 ss tm pbe nx bts`. HIGH. Consequences for OS design:
  - Present: TSC, MSRs, **local APIC**, SYSENTER/SYSEXIT (`sep`), MTRR, **PAE**, **NX/XD** (`nx`, usable only in PAE paging mode), SSE/SSE2, FXSR, CLFLUSH, thermal monitor TM1 (`tm`), ACPI thermal MSRs (`acpi`), debug store/BTS.
  - **Absent: SSE3, HT (single core, single thread, `processor : 0` only), x86-64, VT-x, EST/Enhanced SpeedStep (`est` missing: Celeron M has EIST fused off; no P-states, DVFS impossible), TM2, PSE-36, PAT** (Pentium M family hides the PAT flag, do not rely on PAT).
  - `cpuid level : 2`, max basic CPUID leaf is 0x2 (cache info only via leaf-2 descriptors; no leaves 4/5/6). Extended leaves 0x80000000+ exist (brand string, NX bit in 0x80000001.EDX[20]).
  - `address sizes : 32 bits physical, 32 bits virtual`: 4 GB physical ceiling even with PAE (PAE useful here only for NX).
- **32-bit only, 1 core, no HT: confirmed.** HIGH.
- Power/idle: no P-states; C-states via ACPI. Kernel measured **"Marking TSC unstable due to TSC halts in idle"**: TSC stops in deep C-states (C3+); use PM timer/HPET for timekeeping if C3 is enabled. HIGH (verbatim dmesg).

## 2. Chipset & full PCI ID map: HIGH
Northbridge: **Intel 910GML Express** (GMA 900 graphics); southbridge **Intel 82801FBM ICH6-M**. ASUS spec, service manual and ivc teardown all say 910GML (not 915GMS). Note: 910GML shares PCI device IDs and the "Mobile 915GM/PM/GMS/910GML" lspci string with the whole 915M family; CPU-Z reads it as "i915GMS/i910GML **rev B1**" (lspci rev 04). HIGH.

Verbatim device list (bus:dev.fn, name, [vendor:device], rev: Linux driver). IDs verbatim from 701SD lspci -knn; identical device layout verbatim-confirmed on an original 701 4G by ivc's lspci (which shows the same functions/revs and NO 00:1f.1):
| BDF | Function | ID | rev | Linux driver |
|---|---|---|---|---|
| 00:00.0 | Host bridge (DRAM controller) | 8086:2590 | 04 | agpgart-intel / intel-agp |
| 00:02.0 | VGA controller (IGD, GMA 900) | 8086:2592 | 04 | i915 (KMS) / xf86-video-intel |
| 00:02.1 | Display controller (IGD 2nd function) | 8086:2792 | 04 | (none needed) |
| 00:1b.0 | HD Audio controller (ICH6) | 8086:2668 | 04 | snd_hda_intel (codec: Realtek **ALC662**, model `eeepc-p701`) |
| 00:1c.0 | PCIe root port 1 | 8086:2660 | 04 | pcieport |
| 00:1c.1 | PCIe root port 2 | 8086:2662 | 04 | pcieport |
| 00:1c.2 | PCIe root port 3 | 8086:2664 | 04 | pcieport |
| 00:1d.0 | USB UHCI #1 | 8086:2658 | 04 | uhci_hcd |
| 00:1d.1 | USB UHCI #2 | 8086:2659 | 04 | uhci_hcd |
| 00:1d.2 | USB UHCI #3 | 8086:265a | 04 | uhci_hcd |
| 00:1d.3 | USB UHCI #4 | 8086:265b | 04 | uhci_hcd |
| 00:1d.7 | USB2 EHCI | 8086:265c | 04 | ehci_hcd |
| 00:1e.0 | PCI-PCI bridge (82801 Mobile) | 8086:2448 | d4 |, |
| 00:1f.0 | LPC/ISA bridge (ICH6-M) | 8086:2641 | 04 | lpc_ich quirks |
| 00:1f.2 | IDE interface class [0101]: "82801FBM (ICH6M) SATA Controller" | **8086:2653** | 04 | **ata_piix** |
| 00:1f.3 | SMBus | 8086:266a | 04 | i2c-i801 |
| 01:00.0 | WiFi Atheros AR5007EG/AR2425 (b/g) | 168c:001c | 01 | ath5k (madwifi historically) |
| 03:00.0 | Attansic L2 100 Mbit Ethernet | 1969:2048 | a0 | atl2 |
- **There is NO 00:1f.1 PATA function (8086:266f) on this machine.** The ICH6-M SATA controller (8086:2653) runs in legacy/compatibility combined mode: **ata1 = SATA channel, legacy ports 0x1F0/0x3F6, BMDMA 0xFFA0, IRQ 14 (no devices, no SATA ports wired)**; **ata2 = PATA channel, legacy ports 0x170/0x376, BMDMA 0xFFA8, IRQ 15, the SSD lives here** (verbatim: `ata1: SATA max UDMA/133 cmd 0x1f0 ctl 0x3f6 bmdma 0xffa0 irq 14`, `ata2: PATA max UDMA/100 cmd 0x170 ctl 0x376 bmdma 0xffa8 irq 15`). HIGH.
- Subsystem IDs seen on 701SD: 1043:82d9 (host/VGA), 1043:8330 (audio), 1043:82d8 (USB/LPC/IDE/SMBus). Original-4G subsystem IDs not verbatim-confirmed: LOW for the exact subsystem values on the 4G.
- **PCIe ECAM/MMCONFIG present**: `PCI: MCFG configuration 0: base e0000000 segment 0 buses 0 - 255`. HIGH (verbatim).
- IGD: `agpgart-intel ... Intel 915GM Chipset; detected 7932K stolen memory; AGP aperture is 256M @ 0xd0000000`. GMA 900, no hardware T&L; DVMT shared memory. 910GML core clock commonly cited 160 MHz (MEDIUM-LOW). Boot video device = 00:02.0.

## 3. RAM: HIGH (service manual + dumps)
- Shipped: **512 MB DDR2** in **one 200-pin SO-DIMM slot** (nothing soldered: service manual "ON-BOARD MEMORY: None"); 64-bit single channel, 1.8 V.
- Service manual: supports **DDR2-400 devices, max 2 GB**; 2 GB modules verified working by users (the LKML 701 dmesg shows `Memory: 2064636k/2088448k available` with a 2 GB stick). DDR2-533/667 sticks work but clock down.
- Measured timings at stock (CPU-Z validation, Asus 701): "Single Channel (64 bit) DDR2-SDRAM", **"70 MHz (DDR2-140) - Ratio 1:1", timings 3-3-3-9**. i.e. at the 70 MHz underclocked FSB the DRAM clock followed 1:1, effective DDR2-140. This conflicts with spec-sheet claims of DDR2-400 operation; the CPU-Z reading is a single validation, see uncertainties. FSB overclocking to 100 MHz raises memory clock proportionally.

## 4. The 4 GB SSD: HIGH (verbatim dmesg, teardown)
- **Interface: PATA/IDE**, soldered to the motherboard, wired to the ICH6-M PATA channel = **secondary master (ata2.00 / legacy 0x170, IRQ 15)**. Not USB, not SATA, not PCIe (reviews saying "attached via PCI-E" are wrong).
- Controller: **Silicon Motion SM223** (CF-class flash controller with ATA interface) + **4 × 8 Gbit SLC large-block NAND** (observed: Hynix HY27UG088G5M, Intel 29F08G08CANB2; Samsung also used). HIGH (ivc teardown).
- ATA IDENTIFY (verbatim dmesg): `ata2.00: ATA-4: SILICONMOTION SM223AC, , max UDMA/66`, model string `SILICONMOTION SM223AC`, **firmware revision string blank** (note the empty field). `ata2.00: 7815024 sectors, multi 0: LBA` → **7,815,024 × 512 B = 4,001,292,288 B**; **28-bit LBA only, NO LBA48** (ATA-4 device), **multi 0 = no READ/WRITE MULTIPLE**.
- UDMA: device advertises **UDMA/66 max**. Kernels < 2.6.26 mis-detected a "40-wire cable" (short PCB trace, no cable) and limited it to **UDMA/33** (`ata2.00: limited to UDMA/33 due to 40-wire cable`); fixed by an ata_piix cable-detect patch in ≈2.6.26 → `configured for UDMA/66`. An OS driver should program UDMA/66 (BMDMA at 0xFFA8). HIGH.
- Expansion quirk: the SM223's ATA bus is also routed to the vacant mini-PCIe "Flash_con" pads (non-standard slot carrying 1 PCIe lane + USB + ATA); **inserting a card into that slot disables the onboard SSD** (this is how the 8G model relocates its SSD). MEDIUM-HIGH (ivc).
- Measured performance (this exact 4G SSD):
  - HD Tune (notebookcheck): read min/max/avg **5.9 / 30.6 / 28.7 MB/s**, access **0.5 ms**, burst 30.8 MB/s, CPU 7%.
  - ATTO (jkkmobile screenshot, KB/s, block size → write/read): 0.5K → 1315/2413; 4K → 2186/12106; 64K → 21106/32524; 256K → 22901/34267; 8192K → 20027/34636. I.e. **seq read ~34.6 MB/s, seq write ~20–23 MB/s (ATTO, optimistic), small-block writes ~1.3–3 MB/s**. Users report ATTO overstates writes vs. other tools; sustained small random writes are the weak point. MEDIUM (numbers read from a low-res screenshot).

## 5. BIOS / firmware: HIGH unless noted
- Vendor: **AMI** (Aptio-era AMIBIOS8; ACPI OEM strings verbatim: RSDP `ACPIAM`, RSDT `A M I  OEMRSDT ... MSFT 97`, DSDT OEM table `A0797`, rev tag `INTL 20051117`). CPU-Z: "American Megatrends Inc. **1302 (03/11/2009)**": 1302 is the last 701 BIOS; earlier public versions include 0511, 0801 (file `701-ASUS-0801.ROM`). MEDIUM on the exact version list.
- Flash chip: **Winbond 25X40VSIG**: 8-pin SPI, **512 KB (4 Mbit)**, under an adhesive label. HIGH (ivc teardown).
- **Legacy BIOS only, no UEFI, no GPT boot. Confirmed** (2007 AMIBIOS; all installs use MBR + INT 13h). HIGH.
- Keys: **F2** = Setup, **Esc** = boot-device menu at POST, **Alt+F2** = built-in EZ-Flash (reads `701.ROM` from a **FAT16** USB stick; will not downgrade past 0511, use AFUDOS from DOS for that). CMOS clear: `CLRTC` pads inside the expansion bay. HIGH.
- **USB boot: supported and routine** (USB-HDD style; USB key appears in the boot menu / as a hard-disk entry; syslinux and GRUB MBR boots work). INT 13h extensions (EDD) available: Linux/GRUB boot from both SSD and USB relies on it. MEDIUM-HIGH (universal user experience; EDD version not verbatim-confirmed).
- Advanced menu has **"OS Installation: [Start/Finished]"** option (work-around for USB device compatibility during installs). MEDIUM.
- **VBE: the native 800×480 mode is NOT in the video BIOS mode table.** Standard VESA modes only (640×480/800×600/1024×768, panel-scaled); text mode boots as `Console: colour VGA+ 80x25`. To get a native-resolution VESA framebuffer you must patch the shadowed VBIOS mode table at runtime, `915resolution 5c 800 480 32` (or `915resolution 43 800 480 16`), i.e. the classic 915resolution story DOES apply to this machine when using VBE/vesafb; native-mode drivers (Intel KMS) don't need it. MEDIUM-HIGH.
- **E820 map** (verbatim, machine upgraded to 2 GB; layout identical with 512 MB except the top addresses scale down):
```
BIOS-e820: 0000000000000000 - 000000000009fc00 (usable)
BIOS-e820: 000000000009fc00 - 00000000000a0000 (reserved)
BIOS-e820: 00000000000e4000 - 0000000000100000 (reserved)
BIOS-e820: 0000000000100000 - 000000007f780000 (usable)
BIOS-e820: 000000007f780000 - 000000007f790000 (ACPI data)
BIOS-e820: 000000007f790000 - 000000007f7d0000 (ACPI NVS)
BIOS-e820: 000000007f7d0000 - 000000007f7de000 (reserved)
BIOS-e820: 000000007f7e0000 - 000000007f800000 (reserved)
```
  Top-of-DRAM (0x80000000 here) minus ~8.5 MB: **~8 MB graphics stolen memory** (kernel: "detected **7932K stolen memory**") + ~0.5 MB ACPI/reserved. With stock 512 MB, Linux reports ~503–506 MB usable. HIGH (verbatim).
- ACPI: RSDP at 0xFBE60; tables RSDT/FACP/DSDT (0x5F61 bytes)/FACS/APIC (MADT present → IOAPIC declared). **No HPET table** (see §6). ACPI PM base = 0x800 (PM-Timer **I/O 0x808**); GPIO base 0x480 (`region 0800-087f claimed by ICH6 ACPI/GPIO/TCO`, `region 0480-04bf ICH6 GPIO`). HIGH (verbatim).
- Stolen-memory BIOS options: fixed ~8 MB; no user VRAM size setting reported on the 701 BIOS (DVMT handles the rest). MEDIUM-LOW.
- Underclock policy: stock BIOS always programs 70 MHz FSB (630 MHz), no stock speed option; claims that some BIOS revisions ran 900 MHz on AC are unconfirmed for the 701 (see uncertainties).

## 6. Interrupt & timer hardware: HIGH (verbatim dumps)
- **Local APIC: present and used**, at 0xFEE00000 (MADT: `LAPIC (acpi_id[0x01] lapic_id[0x00] enabled)`).
- **IOAPIC: present and usable**: `IOAPIC (id[0x01] address[0xfec00000] gsi_base[0])`, `apic_id 1, version 32 (0x20), GSI 0-23`. MADT overrides: ISA IRQ0→GSI2 (`dfl dfl`), IRQ9→GSI9 high/level (standard ACPI SCI override).
- **8259 PIC pair**: present (ICH6 legacy), used only as fallback/virtual-wire.
- **PIT 8254** (ports 0x40-0x43, IRQ0/GSI2): present. **RTC** (0x70/0x71, IRQ8): present.
- **ACPI PM timer: I/O port 0x808** (3.579545 MHz). HIGH.
- **HPET: present in ICH6-M silicon at 0xFED00000 (3 timers) but NOT declared by the BIOS in ACPI.** Linux force-enables it via the ICH6-M LPC (8086:2641) quirk, verbatim: `pci 0000:00:1f.0: Force enabled HPET at 0xfed00000`, `HPET: 3 timers`. Mechanism (kernel quirks.c): read RCBA from LPC config 0xF0, set the HPTC register at RCBA+0x3404 to enable decode at FED0x000h. An OS must do this itself if it wants HPET. HIGH.
- **TSC: unstable across idle** (`Clocksource tsc unstable`, "TSC halts in idle", stops in C3). LAPIC timer also stops in C3 on this core family (MEDIUM, architectural). Safe monotonic sources: ACPI PM timer, force-enabled HPET, PIT.
- Shipped OS: Xandros with custom kernel **2.6.21.4-eeepc**, predates the ICH6 force-HPET quirk, so the stock OS ran on PIT/ACPI-PM-timer + LAPIC timer, IOAPIC mode. MEDIUM.
- Observed IOAPIC routing (701SD dump; original 701 equivalent expected): IRQ0 timer, 1/12 i8042 (keyboard/touchpad), 8 rtc, 9 acpi SCI, **14/15 ata_piix**, 16 uhci#5?, 18/19 UHCI, **23 EHCI+UHCI#1**. MEDIUM for exact GSI numbers on the 4G.

## 7. Clock generator (the eeectl/SetFSB target): HIGH on chip ID
- **ICS 9LPR426AGLF** ("low-power programmable timing control hub"), identified on the 701 4G board by ivc's teardown and by SetFSB's supported-PLL list (SetFSB ≥2.0 build 18q has the correct ICS9LPR426AGLF profile; the Eee 1000 uses ICS9LPR427). It generates CPU BCLK (70 MHz as programmed by BIOS at POST; 100 MHz = stock rating), PCIe/DDR clocks (SetFSB reports DDR and PCIe ratings and can change PCIe speed separately).
- Bus: sits on the **ICH6-M SMBus** (controller 8086:266a, Linux i2c-i801). **Slave address 0x69 (7-bit; 0xD2/0xD3 in 8-bit write/read form)**, the standard ICS PLL address used by lfsb (`ioctl(File, I2C_SLAVE, 0x69)`) and SetFSB; programmed with SMBus block read/write of its byte-register file (N/M dividers + control bits). Register-level map of the 9LPR426A itself: no public datasheet, reverse-engineered profiles only (SetFSB/eeectl). Chip-ID HIGH; address MEDIUM-HIGH (family-standard, tool-source-confirmed); register map LOW.
- eeectl (Windows) used this path to restore 900 MHz (and beyond, ~1 GHz reported); it additionally drives fan/thermal via the EC.

## 8. Core-adjacent items an OS will hit early
- **Embedded controller: ENE KB3310** on LPC; standard ACPI EC interface at I/O 0x62/0x66; owns battery gauge, fan control, hotkeys, lid switch GPIO. eeectl pokes EC RAM directly for fan speed. MEDIUM-HIGH (ivc teardown).
- ACPI platform device **ASUS010** → Linux `eeepc-laptop` driver (hotkeys, RF kill; wifi toggle unplugs the PCIe device, pciehp interactions notorious). MEDIUM-HIGH.
- i8042 keyboard controller + Synaptics touchpad on PS/2 (IRQ1/IRQ12). HIGH (interrupt dump).
- USB topology: ICH6-M's 8 USB2 ports across 4 UHCI + 1 EHCI; wired to 3 external USB-A ports, internal ENE **UB6225** USB SD-card reader, (4G) USB webcam, mini-PCIe slot USB pins. MEDIUM on exact port assignment.
- Audio: HDA controller 8086:2668 with **Realtek ALC662** codec. HIGH.
- Display panel: AU Optronics **A070VW04** 7" 800×480 LVDS. HIGH (teardown).
- DMI strings: sys vendor "ASUSTeK Computer INC.", product "701". MEDIUM.
- No SATA ports, no PATA slave devices, no optical, no PC Card. Battery 5200 mAh 2S2P.

## 9. Source conflicts (both claims reported)
1. **L2 cache**: many spec sites say Celeron M 353 = 1 MB; Intel MDDS/cpu-world + every direct CPUID dump say **512 KB** → 512 KB wins (HIGH).
2. **Northbridge**: occasional reviews say 915GMS; ASUS docs + teardown say **910GML** → 910GML wins; note shared DIDs 2590/2592 make software identification ambiguous by design.
3. **SSD attachment**: notebookcheck says "via PCI-E"; dmesg proves **PATA on ICH6-M secondary channel** → PATA wins (HIGH).
4. **DRAM speed at stock**: CPU-Z validation says 70 MHz/DDR2-140 (1:1 with FSB, 3-3-3-9); service manual/reviews say DDR2-400 class. Unresolved, single validation vs. paper spec; memory init is BIOS-side, so OS impact is nil, but benchmark expectations should assume the low reading may be real.
5. **UDMA mode**: UDMA/33 (old kernels, wrong cable detect) vs UDMA/66 (correct, device max), program UDMA/66.

## UNCERTAINTIES
- Effective DRAM clock at stock 70 MHz FSB: CPU-Z validation shows 70 MHz (DDR2-140, ratio 1:1, 3-3-3-9), but the service manual says DDR2-400 devices; only one validation dump found, unresolved which the memory controller really runs.
- PCI subsystem IDs (1043:82d9 / 1043:8330 / 1043:82d8) were verbatim-confirmed only on a 701SD; the original 4G's subsystem IDs may differ.
- Exact interrupt GSI assignments for HDA audio, wifi, ethernet on the original 4G (the /proc/interrupts dump used was from a 701SD; IRQ14/15 for ATA and the timer/i8042/RTC/SCI lines are certain).
- Complete 701 BIOS version history (0511, 0801, 1302-final confirmed; intermediate versions and dates not enumerated) and whether any stock 701 BIOS revision ever ran 900 MHz on AC power (claims exist but were not confirmed for the 701; modded BIOSes definitely did).
- ICS9LPR426AGLF register map (byte offsets/divider encodings): no public datasheet; only reverse-engineered SetFSB/eeectl profiles. SMBus slave address 0x69 is family-standard and tool-confirmed but not verbatim-dumped from a 701 i2cdetect.
- ATTO write/read figures were transcribed from a low-resolution screenshot; small digits (especially the 16KB-block write value ~15420 KB/s) may be misread by one digit.
- VBE details: which patched mode number people used varied (0x43 at 16bpp vs 0x5c at 32bpp); VBE version and full stock mode list not captured; INT 13h EDD version not verbatim-confirmed.
- E820 map was captured on a 2 GB-upgraded machine; the stock-512MB map is inferred (same layout, top addresses scaled), not measured.
- Celeron M 353 TDP reported as both 5 W and 5.5 W depending on source; core voltage not confirmed.
- Whether the BIOS can alternatively expose the ICH6-M PATA function at 00:1f.1 (8086:266f) instead of mapping PATA under 00:1f.2 (8086:2653): never observed on any Eee dump, all dumps show 1f.2 only.
- DVMT maximum shared video memory for the 910GML on this BIOS (stolen 8 MB measured; dynamic ceiling 64/128 MB not confirmed).
- SM223AC internals: wear-leveling behavior, erase block size, and whether SMART/ATA security features are implemented (IDENTIFY details beyond model string/sectors/UDMA were not found).

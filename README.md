# vibeee

An experimental graphical operating system written from scratch in Zig.

**Reference machine:** ASUS Eee PC 701 4G (630 MHz Celeron M, 512 MB RAM, 800x480
display). Intended for similar low-end x86 netbooks, including later Eee PCs, the Acer
Aspire One and the HP Mini. The 701 is the hardware validation baseline.

The QEMU development profile matches the 701's CPU, memory, ATA and audio hardware where
QEMU can model them.

![The vibeee desktop: the file manager and the picture viewer side by side, with the launcher open over them](docs/img/desktop.png)

## Quick Start

Requirements: Zig 0.16, NASM, mtools, QEMU.

```bash
make qemu                  # build and boot the development image
make vnc                   # boot with VNC on localhost:5901
make check-all             # format, checks, tests, images, and QEMU boot checks
```

The system starts at a shell. Run `svc start eeewm` to start the desktop.

Other targets:

```bash
make image                 # build build/vibeee.img
make qemu-sd               # boot the release image as USB storage
make sd DEV=/dev/rdiskN    # guarded SD card writer on macOS
make MANUAL=no image       # omit the on-device manual
make fuzz                  # run fuzz targets (does not work on Zig 0.16.0)
```

Set `QEMU_AUDIODEV=none` to keep the emulated audio controller without host audio.

## Minimum System Requirements

The boot image is **64 MiB**. The core system uses **about 7 MiB of RAM** at the shell
in the 512 MiB QEMU profile. A desktop session with several applications, including Hero
across multiple workspaces, measured **about 19 MiB**.

| Component | Minimum | Validated / recommended |
|---|---|---|
| CPU | 32-bit x86 with SSE2, APIC, TSC, MSRs and legacy BIOS; AMD Athlon 64 class or newer | 630 MHz Pentium M / Celeron M class or faster |
| RAM | 32 MiB for basic desktop use | 512 MiB |
| Storage | 64 MiB bootable SD, USB or ATA media | Larger, with `grow` extending `/home` |
| Graphics | VGA-class firmware framebuffer | Intel GMA 900/950 for native modesetting |

32 MiB starts the desktop in QEMU with little room for applications. AMD Athlon 64 class
systems meet the CPU feature floor but are not validated on hardware. SYSENTER, PAE, NX,
SSE3, 64-bit mode and multiple cores are not required.

## Included System

- Bootloader, 32-bit x86 kernel, preemptive O(1) scheduler, processes, ELF loader,
  capabilities, channels, events, shared memory, panic screen with a QR register dump.
- FAT12/16/32 with VFAT long names; persistent `/cfg` and `/home` volumes; a clean
  unmount flag with a check and repair at mount; `check`, `format` and `grow`.
- Suspend to memory.
- Native GMA 900/950 modesetting, a framebuffer display server, tiling and floating
  windows, launcher, and the `libeui` control library.
- ATA, ACPI through uACPI, battery, backlight, USB mass storage, keyboards, mice, hubs
  and serial adapters, AC'97 and HDA playback, wired IPv4 with DHCP, DNS, TCP, UDP
  and SNTP.
- Power switching for the radio, camera, card reader and internal USB ports, through
  standard ACPI methods or the vendor's, followed by a bus rescan.
- The kernel log sent to a USB serial adapter.
- Shell, multicall command-line tools, and a small POSIX-lean C library.

## Kernel Model

The kernel runs in Ring 0. Applications, services and most drivers run in Ring 3 with
separate address spaces. A process receives capability handles at spawn; a child's
capabilities can only be reduced.

Synchronous channels carry control messages and handles. Shared memory and events carry
display surfaces, audio buffers, sockets and other bulk data. The window manager is a
userspace display server that composites client surfaces. USB, audio, networking,
configuration and ACPI support are userspace services. The kernel keeps scheduling,
memory isolation, filesystems, interrupts and the capability boundary.

## Applications

| Application | Function |
|---|---|
| `eTerm` | Terminal with a VT emulator and the `vsh` shell |
| Files | Dual-pane file manager: copy, move, preview, open |
| Pad | UTF-8 text editor with file dialogs |
| Viewer | PNG, JPEG, BMP and GIF viewer with EXIF orientation and metadata |
| Calc | Fixed-point calculator in a floating window |
| Monitor | Process list, CPU and memory use, process termination |
| Settings | Theme, display, input, audio, power and shortcut settings |

The launcher searches installed programs, open windows and files under `/home`.

## Extra Applications

Installed into `/home` rather than the system image: programs into `/home/bin`, which is
searched before `/bin`, and their data into `/home`. Each is built and versioned
separately.

Doom, the Hero character journal, the echat IRC client, the eeemod tracker player, and
`web`, an experimental browser.

```bash
make hero                  # build Hero
make echat                 # test echat's protocol engine
make eeemod                # build eeemod
make web                   # build the browser
make apps                  # build the first-party apps and every recipe
make app APP=doom          # build Doom only
```

Third-party source is fetched into `build/apps/` and not committed. Doom's WAD and
tracker modules are not downloaded; each recipe names what it needs. See
[apps/README.md](apps/README.md).

### The browser is experimental

`web` is not part of the system image. It fetches over HTTP and HTTPS, follows links,
submits forms, loads pictures, runs scripts and draws in one column. The markup parser
and script engine are vendored; the cascade, page extraction and layout are this
project's.

Mainstream pages render partially. Script-heavy pages take tens of seconds on the 701.
Scripts cannot measure layout, `IntersectionObserver` never fires, and there are no CJK
glyphs. See [Status](docs/status.md).

## Real Hardware

1. Run `make image`.
2. Write `build/vibeee.img` to an SD card with `make sd DEV=/dev/rdiskN` on macOS, or
   `dd` elsewhere.
3. Boot the card as USB-HDD on the Eee PC.
4. To use the rest of a larger card for `/home`, find its volume with `disk` (`usb0p3`
   when booted from SD on the 701), then `unmount /home` and `grow` that volume. Copy
   anything important off first; a power cut during `grow` destroys the volume.

Verified on the Eee PC 701: SD boot, native 800x480 display, keyboard, relative-mode
touchpad, battery, backlight, desktop, wired networking, HDA playback, USB storage,
persistent settings and home volumes.

The top-row keys are handled by the firmware on this machine: they work, but the system
does not receive them. Taking them over depends on two firmware gates currently held
shut; `man hotkeys` explains. Their functions are available as commands. `hw wireless
on` powers the radio; `net wifi scan` lists networks and `net wifi join` associates, but
traffic over the radio is not confirmed.

### Testing Other Netbooks

Reports from other low-end x86 netbooks are welcome. Hardware support is selected by PCI
discovery, ACPI and SMBIOS data, and driver manifests, not a fixed 701 profile. The Eee
PC 900, 901 and 1000 carry an Attansic L1E wired port, which has a driver sharing code
with the 701's L2; it has not been run. Firmware corrections are one module per family
under `src/quirks/`; a vendor's control interface is one file under
`src/user/platd/vendor/` plus a row in its registry. Expect gaps in graphics, embedded
controller functions, wireless, audio codecs, touchpads and storage controllers.

Use an overwriteable SD card and preserve the machine's existing disk. Useful reports:
model, firmware version, boot result, screen mode, working and failing devices, and the
output of `log`, `devices`, `smbios` and `sysinfo`. Photograph a panic screen; its QR
code carries the register dump.

Known gaps:

- Power off does not cut power: the panel goes dark and the power LED stays on.
- Wi-Fi scans, joins a WPA2 network and takes a DHCP lease, but traffic is not confirmed.
- Suspend runs in the emulator only. The display driver does not restore the panel
  timing firmware set.
- FAT has no journal. A volume not unmounted cleanly is checked and repaired at mount;
  clusters claimed by two files are reported, not repaired, and that volume is mounted
  read-only. A power cut during `grow` destroys the volume.
- No touchpad tap, scrolling or gestures.

This is unaudited hobby OS software. Use overwriteable media and hardware you can recover
manually.

## Documentation

- [Status](docs/status.md): component inventory, tests and known gaps.
- [Master design](design/00-vibeee.md): goals, architecture and roadmap.
- [Extra applications](apps/README.md): programs outside the system image.
- [System calls](docs/syscalls.md): generated ABI reference.
- [Settings](docs/settings.md): generated configuration reference.
- [libeui](docs/libeui.md): generated UI toolkit reference.

The 701 has no serial port. Boot diagnostics appear on screen and in the kernel log ring,
readable with `log`. With a USB serial adapter named in the `log` settings domain, the
log is sent to it from the point `usbd` finds the adapter.

## Third-Party Notices

Spleen (`third_party/spleen/`) is BSD 2-Clause, copyright Frederic Cambus.
Ark Pixel (`third_party/ark-pixel/`) is SIL Open Font License 1.1, copyright TakWolf.

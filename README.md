# vibeee

A graphical operating system for low-end netbooks, written from scratch in Zig.

![eTerm running eeefetch on the vibeee desktop](docs/img/desktop.png)

It is its own bootloader, kernel, userspace, window manager and control library.
It was built and tested against an **ASUS Eee PC 701 4G** (2007: 630 MHz Celeron M,
512 MB RAM, 800x480 panel) and is aimed at that whole class of machine: later Eees,
the Acer Aspire One, the HP Mini. It boots that machine today, from an SD card to a
working desktop, in about a second.

## Try it

```bash
make qemu    # build everything and boot in QEMU
make vnc     # the same, over VNC (vnc://localhost:5901 on macOS)
```

You need Zig 0.16, nasm, mtools and QEMU. It boots to a shell in about a second.
Type `eeewm` for the desktop.

The emulated machine is built to resemble the target: the CPU is pinned to the Celeron
M's feature set, memory to 512 MB, storage to the parallel ATA the machine's own SSD
speaks, and the audio controller to the ICH6 the southbridge carries, which is the same
part QEMU models and the same driver that binds on hardware. Sound comes out of the
host by default where there is somewhere to send it, and `QEMU_AUDIODEV=none` turns
that off without taking the controller away. What cannot be emulated is the rest of the
chipset: no GMA 900, no wireless radio, no embedded controller, and no panel that
offers 800x480 as a mode, so the console settles for 640x480 under QEMU and gets the
full panel only on the machine.

## What is there

A tiling window manager whose tabs are named after what is in them, and four
applications sharing one control library:

| | |
|---|---|
| **eTerm** | terminal, with its own VT emulator |
| **Pad** | text editor |
| **Monitor** | process list, CPU share, end a task |
| **Settings** | theme, layout, bar position |

Underneath: its own bootloader, a preemptive O(1) scheduler, per-process address
spaces, capability handles, channels and events, ATA and FAT with long names, ACPI
interpreted in a userspace service (uACPI), and a native modeset for the GMA 900/950.
Alongside those, three services the device manager starts when it finds the hardware:
USB over EHCI and its UHCI companions, carrying disks, keyboards, mice and hubs; sound
as a routing graph over AC'97 and HDA; and a wired network stack that takes a lease and
holds a conversation. Settings and home are volumes of their own, so what is changed
outlives the power being cut.
The window manager is an ordinary userspace program that was handed the display:
clients talk to it over a channel, draw into their own shared-memory surface, and
have it composited.

## Programs that are not the system

The image carries what a machine needs to start and be used. Anything else is built
apart from it and installed into `/home`, beside the files it works on:

```bash
make apps               # build every recipe in apps/
make app APP=doom       # build just one
```

A recipe says where a program's source comes from and how to build it, and third-party
source is never committed here. Doom is the first one: it builds, runs, takes input and
saves. Its data is not fetched for you, because what a program may be passed around with
is not a build's decision to make; the recipe names the WAD it wants and where to get
it, and stops there.

## Running on real hardware

You do not need to be an OS developer to run this. If you can write an SD card and
read a screen, that is the whole skill set.

1. `make image` builds `build/vibeee.img`, a disk image.
2. Write it to a card: `make sd DEV=/dev/rdiskN` on macOS, or plain `dd` of the
   image anywhere else. The host build needs no root; only the write does.
3. Put the card in the machine and power on. The BIOS boots it as a USB-HDD, which
   the image is built to be.

Expectations on the machine, day one:

* **Works on the machine:** boot from SD, the screen at the panel's own 800x480 through
  the native GMA modeset, keyboard (US-International and Belgian AZERTY included), the
  touchpad in relative mode, battery state with remaining time, backlight levels,
  hotkeys, the desktop with all four applications, wired networking through the whole
  stack, and settings and a home directory that outlive the power being cut.
* **Written and running, but proven in the emulator rather than on the machine:** USB
  storage, keyboards, mice and hubs, and sound over AC'97 and HDA.
* **Does not work yet:** powering off does not cut the last power (the LED stays on; see
  below), the wireless radio is identified but not driven, and a machine that sleeps
  comes back with its USB devices unenumerated.
* The safest first run is with a card you can overwrite, and a machine you can pull
  the battery out of: this is a toy operating system, not audited software.

## Status, honestly

Everything described above is real and running, on hardware and under QEMU. The
current work is what only the machine can answer: the final power cut, and making
the settings survive a reboot. `docs/status.md` is the day-true inventory of what
exists, what works and what is missing, kept without measurements that go stale.

The code was written largely with AI assistance and has not been audited. It is a
toy OS for a nineteen-year-old netbook, and that is the standard it is built to.

## Reading further

- [docs/status.md](docs/status.md) - what exists, component by component, including the gaps
- [design/00-vibeee.md](design/00-vibeee.md) - the master design, the whole system as it was planned
- [docs/syscalls.md](docs/syscalls.md) - generated from the syscall table, so it cannot drift

Two details are worth knowing early. The target machine has no serial port, which
shaped the whole project: boot time self-tests report on screen, the kernel keeps a
log ring whether or not it is printed (read it back with `log`), and a panic screen
encodes the register dump as a QR code, so a photograph of a crash comes back as
text. And a second verbosity: `verbose` shows the boot narration, while `debug` is a
separate tier for chasing faults, off by default.

## Licence

Spleen (`third_party/spleen/`) is BSD 2-Clause, (c) Frederic Cambus.
Ark Pixel (`third_party/ark-pixel/`) is SIL Open Font License 1.1, (c) TakWolf.

# vibeee

A from-scratch minimal graphical operating system in Zig, targeting the **ASUS Eee PC 701 4G**
(2007 netbook: 630 MHz Celeron M, 512 MB, 4 GB PATA SSD, 800×480 LVDS panel, no serial port).

Written to be portable to similar constrained machines by keeping machine-specific code behind
explicit boundaries — see [`design/00-vibeee.md §3`](design/00-vibeee.md).

## Status — M1

The kernel boots from its own bootloader, brings up memory and interrupts, probes and binds
drivers by confidence, mounts a FAT filesystem, loads ELF programs into their own address
spaces, and drops into an interactive shell.

A normal boot is quiet — the version, then whatever userspace has to say:

```
vibeee 0.1.0  x86

vibeee shell. 'help' for builtins, 'tools' for system tools.
/ $
```

`verbose` on the kernel command line shows the diagnostics. The self-checks run either way;
only their success output is suppressed, so a regression still appears as a `warn` or `fail`
line on a quiet boot.

```
cpu     GenuineIntel family 6 model 5 step 2
        sysenter, fixed clock
mem     511M usable, 510M free, 131040 frames
heap    slab ok, 0 frame(s) held
sys     19 calls, abi ok
time    pit, advancing (20000 us)
smbios  2.8, 9 structures, 413 bytes
board   QEMU Standard PC (i440FX + PIIX, 1996)
acpi    pm1a 0604, S5 type 0
rtc     2026-08-26 03:08:20 UTC
kbd     i8042 ready, layout US-International
ata     hd0: primary master QEMU HARDDISK, 48 MiB
block   hd0p1 type 0c lba 32768 +65536 (32 MiB)
pci     6 devices, 3 bound
  00:01.1 8086:7010 ata_generic weak      IDE controller
  00:02.0 1234:1111 vesafb      weak   *  display controller
  00:03.0 8086:100e e1000       exact  *  ethernet controller
ramdisk rd0: 2048 KiB at 01000000
mount   / on rd0 (fat32, 1 MiB)
sched   2 threads, 11 switches, workers 8/8/8
user    entry 400005f8, 12572 bytes from disk
```

Confidence markers on the probe table are load-bearing: `weak` means a generic class-level
driver matched, `*` means the driver is designed but not yet implemented. On the real machine
the same table shows `exact` matches against the verified device IDs.

Working:

- **Boot** — two-stage bootloader (MBR + unreal-mode loader) reading the kernel over INT 13h EDD,
  then a higher-half transition: the kernel runs at `0xC0100000` with all physical memory linearly
  mapped through 4 MiB pages, leaving the low 3 GiB for user space. The root filesystem is loaded
  to RAM at the same time, because on the 701 the SD card sits behind USB and is unreachable
  until a USB stack exists.
- **Memory** — bitmap physical allocator over the real E820 map, and a slab allocator exposed as a
  `std.mem.Allocator`, so kernel code reads like ordinary Zig. Per-process page directories.
- **Interrupts** — GDT/TSS/IDT with comptime-generated entry stubs, PIC remap, 100 Hz PIT tick.
- **Scheduling** — preemptive O(1) scheduler: two run-queue arrays with a bitmap and one `@ctz` to
  pick the next thread, so scheduling costs the same at three threads or three hundred. Sleeping,
  voluntary yield, reaping of finished threads, and per-thread FPU/SSE state.
- **User mode** — Ring 3 with per-process address spaces, an ELF loader, and `spawn`; the shell
  and every tool run as separate unprivileged programs loaded from the filesystem.
- **Syscalls** — `int 0x80` dispatch generated from a single table that also generates
  [`docs/syscalls.md`](docs/syscalls.md); a documented call with no handler, or a handler with no
  table entry, fails the build.
- **Storage** — ATA PIO, a partition-table reader, a block cache, and FAT12/16/32 with VFAT long
  names, behind a mount table that resolves paths by longest matching prefix.
- **Console** — VGA text or a linear framebuffer with the Spleen bitmap font, chosen at boot from
  what the firmware provided.
- **Input** — i8042 keyboard with comptime-generated keymaps; US-International and Belgian AZERTY,
  with dead-key composition and `Super+Space` to switch.
- **Time** — a monotonic clock from the timer and a wall clock seeded once from the CMOS RTC, so
  file timestamps and `date` are real rather than 1980.
- **Devices** — PCI enumeration, SMBIOS/DMI decoding, and confidence-ranked driver probing.
- **Shutdown** — handles flushed, volumes unmounted, then ACPI power off via the FADT and the
  `_S5_` object.
- **Diagnostics** — a panic screen that encodes the crash dump as a scannable QR code.

Each of these verifies itself at boot: the heap, the syscall ABI and the clock all self-test and
report, so a regression shows up as a `fail` line rather than a mystery hang.

Userspace is a shell (`vsh`) plus a multicall binary carrying `ls`, `cat`, `hexdump`, `grep`,
`free`, `top`, `disk`, `date`, `eeefetch` and `dmidecode`.

Not yet: pipes and redirection, filesystem writes, a text editor, USB, and the GUI. See the
milestone table in the design doc.

## Build

Needs `zig` (0.16), `nasm`, and `qemu` for emulation. Nothing else — no cross-GCC, no autotools,
no root, no loopback mounts.

```bash
make            # build/vibeee.img, a raw dd-able SD image
make qemu       # boot the image on an emulated IDE disk (the dev loop)
make qemu-sd    # boot it the way the real machine does (BIOS → USB → SD)
make qemu-panic # boot straight into the panic screen
make test       # host-side unit tests + QR differential verification
zig build check         # verify the module layering rules
zig build syscall-docs  # regenerate docs/syscalls.md from the syscall table
make sd DEV=/dev/rdiskN   # flash to a card (guarded, asks before erasing)
```

## Layout

```
boot/       stage1 (MBR) and stage2 (real-mode loader), NASM
src/arch/   ISA- and firmware-specific code — x86 only for now
src/kernel/ portable core: memory, scheduling, VFS, syscalls, probing, console, panic, QR
src/platform.zig  composition root: the only file that wires kernel, arch and drivers together
src/drv/    drivers, selected by runtime probe confidence
src/lib/    pure computation shared by kernel and userspace, compiled into both
src/user/   the shell and the system tools, built as ordinary ELF programs
src/keymaps/  keyboard layouts, one file each, compiled to tables at build time
tools/      host-side build and verification tools
design/     the design documents
docs/       verified hardware research, with per-fact confidence markers
```

## Debugging without a serial port

The 701 has no serial port, which shapes the whole diagnostic strategy: QEMU-first development,
a stage2 log ring replayed into dmesg once the kernel is up, a panic ring in reserved memory that
survives warm reboot, and the QR panic screen — photograph the stop screen and the register dump
and backtrace come back as text:

```
VBE1|06|00000000|00000000|00103CFC|00162A78|00162F14|00101126,00107952
     │  │        │        │        │        │        └ backtrace
     │  │        │        │        │        └ ebp
     │  │        │        │        └ esp
     │  │        │        └ eip
     │  │        └ cr2 (page faults)
     │  └ error code
     └ exception vector
```

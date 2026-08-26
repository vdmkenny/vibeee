# vibeee

A from-scratch minimal graphical operating system in Zig, targeting the **ASUS Eee PC 701 4G**
(2007 netbook: 630 MHz Celeron M, 512 MB, 4 GB PATA SSD, 800×480 LVDS panel, no serial port).

Written to be portable to similar constrained machines by keeping machine-specific code behind
explicit boundaries — see [`design/00-vibeee.md §3`](design/00-vibeee.md).

## Status — M0

The kernel boots on its own bootloader from an SD-card image, brings up descriptor tables and
exception vectors, enumerates PCI, probes and binds drivers by confidence, and reports itself.

A normal boot is quiet — the version, then whatever userspace has to say:

```
vibeee 0.1.0-M0  x86

ring3 ok
```

`verbose` on the kernel command line shows the diagnostics. The self-checks run
either way; only their success output is suppressed, so a regression still
appears as a `warn` or `fail` line on a quiet boot.

```
vibeee 0.1.0-M0  x86

cpu     GenuineIntel family 6 model 5 step 2
        sysenter, fixed clock
mem     511M usable, 510M free, 131040 frames
boot    sd
acpi    rsdp 000f52e0
heap    slab ok, 0 frame(s) held
sys     8 calls, abi ok
time    pit, advancing (20000 us)
pci     6 devices, 2 bound
  00:01.1 8086:7010 ata_generic weak   *  IDE controller
  00:02.0 1234:1111 vesafb      weak   *  display controller
  ...
sched   2 threads, 12 switches, workers 8/8/8
user    ring 3 at 40000000, 49 byte image
ring3 ok
exit    user (thread 6) status 0
ready
```

Confidence markers on the probe table are load-bearing: `weak` means a generic
class-level driver matched, `*` means the driver is designed but not yet
implemented. On the real machine the same table shows `exact` matches against
the verified device IDs.

Confidence markers on the probe table are load-bearing: `weak` means a generic class-level driver
matched, `*` means the driver is designed but not yet implemented. On the real machine the same
table shows `exact` matches against the verified device IDs.

Working:

- **Boot** — two-stage bootloader (MBR + unreal-mode loader) reading the kernel over INT 13h EDD,
  then a higher-half transition: the kernel runs at `0xC0100000` with all physical memory linearly
  mapped through 4 MiB pages, leaving the low 3 GiB for user space.
- **Memory** — bitmap physical allocator over the real E820 map, and a slab allocator exposed as a
  `std.mem.Allocator`, so kernel code reads like ordinary Zig.
- **Interrupts** — GDT/TSS/IDT with comptime-generated entry stubs, PIC remap, 100 Hz PIT tick.
- **Scheduling** — preemptive O(1) scheduler: two run-queue arrays with a bitmap and one `@ctz` to
  pick the next thread, so scheduling costs the same at three threads or three hundred. Sleeping,
  voluntary yield, and reaping of finished threads.
- **User mode** — Ring 3 with its own page mappings and a read-only code page; a user program traps
  into the kernel, writes to stdout and exits through the scheduler.
- **Syscalls** — `int 0x80` dispatch generated from a single table that also generates
  [`docs/syscalls.md`](docs/syscalls.md); a documented call with no handler, or a handler with no
  table entry, fails the build.
- **Devices** — PCI enumeration and confidence-ranked driver probing.
- **Diagnostics** — a panic screen that encodes the crash dump as a scannable QR code.

Each of these verifies itself at boot: the heap, the syscall ABI and the clock all self-test and
report, so a regression shows up as a `fail` line rather than a mystery hang.

Not yet: per-process address spaces, an ELF loader, real drivers. See the milestone table in
the design doc.

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
src/kernel/ portable core: memory, syscalls, probing, console, panic, QR
src/platform.zig  composition root: the only file that wires kernel, arch and drivers together
src/drv/    drivers, selected by runtime probe confidence
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

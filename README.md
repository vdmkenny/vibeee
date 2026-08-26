# vibeee

A graphical operating system for low-end netbooks, written from scratch in Zig.

![eTerm running eeefetch on the vibeee desktop](docs/img/desktop.png)

Its own bootloader, kernel, userspace, window manager and control library. Built and tested
against an **ASUS Eee PC 701 4G** (2007: 630 MHz Celeron M, 512 MB RAM, 800×480 panel), and
written for the rest of that class: later Eees, the Acer Aspire One, the HP Mini.

> **⚠️ This is vibecoded.** Hence the name. Almost all of the code and every design document
> were written by Claude under my direction. I set the goals, made the architectural calls
> and drove the debugging; I did not type most of this. Nobody has audited it. It is a toy
> OS for a nineteen-year-old netbook, and that is the standard it is built to.

## Try it

```bash
make qemu    # build and boot
make vnc     # the same, over VNC on :5901
```

It boots to a shell in about a second. Type `eeewm` for the desktop.

## What is there

A tiling window manager whose tabs are named after what is in them, and four applications
sharing one control library:

| | |
|---|---|
| **eTerm** | terminal with its own VT emulator, running the shell over a pipe |
| **Pad** | text editor, opening and saving through a floating file dialog |
| **Monitor** | process tree, per-process CPU share, and a button to end one |
| **Settings** | theme, layout and bar position, applied live |

The window manager is an ordinary userspace program that was handed the display. Clients
connect to it over a channel, are told their geometry, draw into their own shared-memory
surface, and have it composited.

Underneath it: a preemptive O(1) scheduler, per-process address spaces, capability handles,
channels and counting events, ATA and FAT with long names, LAPIC and IOAPIC, SYSENTER,
40 syscalls, 99 host tests.

## Status

The kernel does the things a kernel has to: it boots, schedules, isolates processes, and
talks to disks, keyboards and the screen. The desktop runs on top of it with four
applications. Both halves work.

It runs under QEMU today. Booting the real machine is the next step, and the open problem is
the screen: driving the Eee's graphics chip directly needs registers Intel never documented,
and none of that can be tried under emulation. Until then it uses the mode the firmware
leaves behind, which is how an unfamiliar machine still gets a usable display.

Coming next: a device manager, so drivers can run as ordinary programs outside the kernel;
a C library, so existing C programs can be ported; and that native modesetting.

## Reading further

- [docs/status.md](docs/status.md), what exists, component by component, including the gaps
- [design/00-vibeee.md](design/00-vibeee.md), the master design, authoritative, and the
  milestone plan the status above is measured against
- [docs/syscalls.md](docs/syscalls.md), generated from the syscall table, so it cannot drift

The target machine has no serial port, which shapes the whole project: boot self-tests that
report their results, a kernel log kept whether or not it is printed, a panic record that
survives a warm reboot, and a panic screen that encodes the register dump as a QR code, so a
photograph of the crash comes back as text.

## Licence

Spleen (`third_party/spleen/`) is BSD 2-Clause, © Frederic Cambus.
Ark Pixel (`third_party/ark-pixel/`) is SIL Open Font License 1.1, © TakWolf.

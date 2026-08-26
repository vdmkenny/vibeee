# vibeee

A graphical operating system written from nothing, in Zig, for low-end netbooks.

The machine it is built and tested against is the **ASUS Eee PC 701 4G**: a 2007 netbook
with a 630 MHz Celeron M, 512 MB of RAM, a 4 GB PATA SSD, an 800×480 panel and no serial
port. Targeting one machine is what makes the decisions concrete, and this one is at the
bottom of the range, so what fits here fits the rest of the class.

But nothing is written as though the 701 were the only machine. The netbook era ran to the
early 2010s and the hardware is a small, well-known set: Intel integrated graphics of three
generations, PATA or SATA, i8042, PS/2 or Synaptics touchpads, a handful of wireless parts.
Drivers bind by probe confidence rather than by assumption, so an exact match beats a
class-level fallback and one image boots both this machine and hardware it has never seen.
Where a family is recognised but not yet driven, it says so and falls back rather than
guessing. Later Eees, the Acer Aspire One and the HP Mini are the ones kept in view.

Own bootloader, own kernel, own userspace. No Linux, no BSD, no libc. It builds to a raw
`dd`-able image with `zig`, `nasm` and `make`: no cross-GCC, no root, no loopback mounts.

![eeefetch running on vibeee in framebuffer mode](docs/img/eeefetch.png)

> ### ⚠️ This is vibecoded
>
> Hence the name. Almost all of the code, and all of the design documents, were written by
> Claude under my direction: I set the goals, made the architectural calls, reviewed the
> output and drove the debugging, but I did not type most of this.
>
> Treat it accordingly. It boots, it self-tests, and the bugs found so far were found by
> running it rather than by reading it. Nobody has audited it. It is a toy OS for a
> nineteen-year-old netbook, and that is the standard it is built to, not production, not
> security-reviewed, not something to trust with anything you care about.

```bash
make qemu       # build and boot it
make vnc        # the same, over VNC on :5901
make test       # host-side unit tests
make sd DEV=…   # write the image to a card, guarded and interactive
```

## What it is

It boots to a shell in about a second. Typing `eeewm` starts the desktop.

The desktop is a tiling window manager with tabs. Each tab is a workspace named after
what is in it rather than numbered, so the bar reads `eTerm  Pad  Monitor` instead of
`1 2 3`. Workspaces are created as you need them. Windows tile tall, wide or monocle;
dialogs float above. A `V` menu at the top left launches things and ends the session.
Everything is reachable by pointer and by keyboard, not one with the other bolted on.

Four applications so far, all in Zig against a shared control library:

- **eTerm**, a terminal with its own VT emulator, running the shell over a pipe
- **Pad**, a text editor, soft-wrapped, opening and saving through a floating file dialog
- **Monitor**, the process tree with per-process CPU share, and a button to end one
- **Settings**, theme, bar position and layout, applied live and written to `/etc/eeewm.cfg`

They share `libeui`: buttons, menus, tables, scrollbars, editable text, a status bar, a file
chooser. Painting is damage-driven, so an idle desktop writes no pixels, which matters when
the whole machine is a 630 MHz core with no graphics acceleration.

## The shape of it

A few decisions distinguish this from a toy kernel that happens to draw:

**The window manager is not in the kernel.** `eeewm` is an ordinary Ring 3 process that
owns the display through a handle it was granted. Clients connect over a channel, are told
their geometry, draw into their own shared-memory surface and have it composited. The
kernel knows nothing about windows.

**No ambient authority.** Everything the kernel exposes is a handle in a per-process table
carrying rights bits. Handles pass over channels as objects, not numbers, so a server can
be given a segment it may map but not resize. A process can do exactly what its handles
permit.

**One blocking primitive.** Counting events and `wait_many`, and everything else built on
it. A waiting thread is off the run queues entirely rather than polling: on a single core
a dozen pollers waking every two milliseconds is real time spent deciding to go back to
sleep.

**Drivers can leave the kernel.** `irq_attach` hands a device interrupt to userspace as
something `wait_many` accepts: the kernel's handler masks the line and signals, and the
driver services the device with the line held down. A driver that crashes leaves its line
masked rather than the machine livelocked. Nothing has moved out yet; the mechanism is
there and the first server is next.

**One machine to build against, several to run on.** Modesetting is an interface with a
backend per adapter family, chosen by the same probe that binds every other driver, and the
families are named by the machines they shipped in rather than by part number: gen3 covers
the Eee 701 through the 1001PX, the Aspire One AOA110 and D255, and the HP Mini 110 and 210.
GMA 500 is named separately and deliberately left undriven, because it is a licensed PowerVR
core sharing nothing with Intel graphics but a vendor id. Keyboard layouts are one file
each. Architecture-specific code is reached only through a HAL, and that rule is checked on
every build.

**The interface is one file.** `src/lib/syscalls.zig` declares the syscall table as data.
The dispatcher binding, the userspace stubs and [`docs/syscalls.md`](docs/syscalls.md) are
all derived from it, and a call that is documented without existing, or exists without
being documented, fails the build.

40 syscalls, 99 host tests, and layering rules enforced on every build rather than written
down and hoped for.

## Where it is

**M0 is complete**: boot chain, memory, scheduler, Ring 3, IPC, LAPIC/IOAPIC, SYSENTER,
filesystem, console, keyboard, shell. **M1 is partway**: storage, `init`, the window
manager, the toolkit and the terminal are done and past what that milestone asked for;
a userspace device manager, a C library and the native GMA900 modeset are not.

**It has never run on real hardware.** Everything so far has been QEMU. That first boot is
M1's actual gate, and the honest risk is the panel: no Intel modeset is written yet, the
gen3 registers have no public documentation, and none of it can be tested under emulation.
The fallback is whatever mode the firmware already set, which works and is why an
unrecognised adapter is still a usable machine.

[`docs/status.md`](docs/status.md) is the current state, component by component, including
what is missing. [`design/00-vibeee.md`](design/00-vibeee.md) is the master design and is
authoritative; `01`–`11` cover subsystems.

## No serial port

The 701 has none, and that shapes the whole project. Development happens in QEMU first,
where there *is* one and the console mirrors to it. On the machine itself the ladder is:
boot self-tests that report `fail` rather than hanging, a kernel log ring that keeps every
message whether or not it was printed, a panic record in low memory that survives a warm
reboot and is read back by the next boot, and a panic screen that encodes the register dump
and backtrace as a QR code: photograph the stop screen and the crash comes back as text.

```
VBE1|06|00000000|00000000|C010D400|C0103CE4|C0104FD0|00101126,00107952
     │  │        │        │        │        │        └ backtrace
     │  │        │        │        │        └ ebp
     │  │        │        │        └ esp
     │  │        │        └ eip
     │  │        └ cr2 (page faults)
     │  └ error code
     └ exception vector
```

## Layout

```
boot/             stage1 (MBR) and stage2, NASM
src/arch/         ISA- and firmware-specific code, x86 only for now
src/kernel/       portable core: memory, scheduling, IPC, VFS, syscalls, panic
src/drv/          drivers, bound by runtime probe confidence
src/lib/          pure code compiled into BOTH kernel and userspace
src/user/         init, shell, tools, the window manager, libeui and the apps
src/keymaps/      keyboard layouts, one file each
src/platform.zig  the only file wiring kernel, arch and drivers together
design/           the design documents
docs/             syscall reference, status, and verified hardware research
```

## Licence

Spleen (`third_party/spleen/`) is BSD 2-Clause, © Frederic Cambus.
Ark Pixel (`third_party/ark-pixel/`) is SIL Open Font License 1.1, © TakWolf.

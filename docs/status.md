# Status

What exists, file by file. Kept plain on purpose: the design documents say what the system
is *for*, this says what has actually been written.

The inventory is accurate about what exists; it is not a claim that any of it has been
audited. See the README for the honest warning.

No counts here: lines, syscalls and tests all change faster than a document can
follow, and a number that is wrong is worse than one that was never given. Git
knows when this was last true, and the tree knows how big it is.

## Boot

| Component | File | State |
|---|---|---|
| MBR, 440 bytes | [`boot/stage1.asm`](../boot/stage1.asm) | Done. INT 13h EDD only. |
| Real-mode loader | [`boot/stage2.asm`](../boot/stage2.asm) | A20, E820, RSDP scan, unreal-mode kernel load, VBE mode set, font copy, cmdline, log ring. |
| Image builder | [`tools/mkimage.zig`](../tools/mkimage.zig) | Partition table, stage placement, rootfs append. |
| Higher-half entry | [`src/arch/x86/boot.zig`](../src/arch/x86/boot.zig), `flatboot.zig`, `multiboot.zig` | Both boot paths converge on one `BootInfo`. |

## Kernel core

| Subsystem | File | State |
|---|---|---|
| Physical memory | [`pmm.zig`](../src/kernel/pmm.zig) | Bitmap allocator over E820. |
| Paging | [`arch/x86/paging.zig`](../src/arch/x86/paging.zig) | 2-level non-PAE, 4 MiB linear map, MMIO window, per-process spaces. |
| Heap | [`heap.zig`](../src/kernel/heap.zig) | Slab, exposed as `std.mem.Allocator`. Self-tests at boot. |
| Scheduler | [`sched.zig`](../src/kernel/sched.zig), [`sched/queue.zig`](../src/kernel/sched/queue.zig), [`sched/thread.zig`](../src/kernel/sched/thread.zig) | O(1), 32 priority levels, preemptive. Queues are unit-tested on the host. |
| Blocking | [`wait.zig`](../src/kernel/wait.zig) | One mechanism. Waiter nodes on the blocking thread's stack; no allocation. |
| Events | [`event.zig`](../src/kernel/event.zig) | Counting, with `waitMany`. |
| Channels | [`channel.zig`](../src/kernel/channel.zig) | Synchronous call/reply, 64-byte payload, generation-tagged reply tokens. |
| Service registry | [`svc.zig`](../src/kernel/svc.zig) | Name → channel. |
| Shared memory | [`shm.zig`](../src/kernel/shm.zig), [`lib/ring.zig`](../src/lib/ring.zig) | Segments, refcounted, mapped into a per-process window. Ring layout tested on the host. Frames survive one mapper exiting. |
| Handles | [`handle.zig`](../src/kernel/handle.zig) | Per-process table, rights bits, console/file/directory/event/channel/shm. Up to four travel with a channel message. |
| ELF loading | [`elf.zig`](../src/kernel/elf.zig), [`exec.zig`](../src/kernel/exec.zig) | Static ELF32, sync and detached spawn. |
| Panic record | [`kernel/panicring.zig`](../src/kernel/panicring.zig) | One page of low memory holding the last panic across a warm reboot, magic and checksum guarded so a page firmware clobbered reads as no record rather than a garbled one. The next boot reports it, puts it in the kernel log and clears it. |
| Kernel log | [`kernel/klog.zig`](../src/kernel/klog.zig) | A 16 KiB ring of everything said: kernel lines recorded whether or not they were printed, and the services' own lines teed into the same ring through the `log` syscall. `verbose` and `debug` are separate command-line gates (see below); a quiet boot can still be read back in full with `log`, and a `debug` line that was never asked for was never recorded. |
| Capabilities | [`lib/syscalls.zig`](../src/lib/syscalls.zig) | What a process may do, intersected at every spawn so an authority only ever shrinks down the tree. Declared per service in `/etc/services`. |
| Driver capabilities | [`kernel/irqevent.zig`](../src/kernel/irqevent.zig), [`syscall/driver.zig`](../src/kernel/syscall/driver.zig) | `irq_attach` hands a device line to userspace as something `wait_many` accepts: the kernel's handler masks and signals, the driver services the device and acknowledges. `ioport_grant` opens ports through the CPU's own permission bitmap, copied into the TSS only when the process holding it changes. `map_device` maps a register aperture uncached, marked as belonging elsewhere so teardown does not hand device memory to the page allocator. All three need the driver capability. |
| Interrupts | [`kernel/irq.zig`](../src/kernel/irq.zig), [`arch/x86/lapic.zig`](../src/arch/x86/lapic.zig), [`arch/x86/ioapic.zig`](../src/arch/x86/ioapic.zig) | LAPIC and IOAPIC, routed from the MADT with the firmware's polarity and trigger per line. The 8259s remain the fallback for a machine that describes no controller. How the machine is wired is described in `kernel/irq.zig` and filled in by the composition root, so the architecture never reaches for a firmware parser. |
| Syscalls | [`syscall.zig`](../src/kernel/syscall.zig) + [`syscall/`](../src/kernel/syscall/) | Bound to the table at comptime in both directions. SYSENTER where the CPU has it, `int 0x80` otherwise, same register convention either way; userspace asks the kernel which was armed rather than trusting CPUID. |
| Timekeeping | [`clock.zig`](../src/kernel/clock.zig) | Monotonic + wall clock as offset plus uptime. |
| Shutdown | [`shutdown.zig`](../src/kernel/shutdown.zig) | Flush, unmount, ACPI off. || Panic | [`panic.zig`](../src/kernel/panic.zig), [`qr.zig`](../src/kernel/qr.zig) | QR-encoded crash dump, verified against libqrencode. |

## Storage

| Component | File | State |
|---|---|---|
| Block layer | [`block.zig`](../src/kernel/block.zig) | Device registry, MBR partition parsing. |
| Block cache | [`bcache.zig`](../src/kernel/bcache.zig) | Read cache with hit reporting. |
| FAT | [`fat.zig`](../src/kernel/fat.zig), [`fat/alloc.zig`](../src/kernel/fat/alloc.zig) | FAT12/16/32, VFAT long names, timestamps. Read and write: cluster allocation across all FAT copies, chain extension, create, append, truncate to a length, unlink, and rename. Renaming moves the record, never the content: replacing repoints the entry already carrying the name in one sector write. |
| Mount table | [`vfs.zig`](../src/kernel/vfs.zig) | Longest-prefix resolution, open-file counting, read-only enforcement per mount and per device. Every write goes through here. Userspace attaches and detaches volumes with the `mount` capability. |
| ATA | [`drv/block/ata.zig`](../src/drv/block/ata.zig) | PIO. No DMA. |
| Ramdisk | [`drv/block/ramdisk.zig`](../src/drv/block/ramdisk.zig) | Backs the boot-to-RAM rootfs. |

## Drivers

| Driver | File | State |
|---|---|---|
| PCI | [`drv/bus/pci.zig`](../src/drv/bus/pci.zig) | Enumeration, config space. |
| VGA text | [`drv/video/vgatext.zig`](../src/drv/video/vgatext.zig) | Done, including the hardware cursor and hiding it. |
| Framebuffer console | [`drv/video/fbcon.zig`](../src/drv/video/fbcon.zig) | 32bpp, Spleen font, pixel rectangles for the panic QR, a drawn cursor, and a cell grid that carries content across a mode change. |
| i8042 | [`drv/input/i8042.zig`](../src/drv/input/i8042.zig) | Keyboard, scancode set 1. Owns the controller; the second port is below. |
| PS/2 pointer | [`drv/input/ps2mouse.zig`](../src/drv/input/ps2mouse.zig) | Three buttons, motion, drag. IntelliMouse wheel negotiated and decoded but not verified against hardware. Synaptics and Elantech identified, both driven in relative mode. |
| CMOS RTC | [`drv/rtc/cmos.zig`](../src/drv/rtc/cmos.zig) | Read at boot to seed the clock. |
| ACPI tables | [`drv/acpi/tables.zig`](../src/drv/acpi/tables.zig) | RSDP/RSDT/FADT, `_S5_` pattern match. No AML interpreter. |
| ACPI power | [`drv/acpi/power.zig`](../src/drv/acpi/power.zig) | Power off, reset. |
| SMBIOS | [`drv/platform/smbios.zig`](../src/drv/platform/smbios.zig) | DMI decoding for `smbios` and `eeefetch`. |
| UART 16550 | [`drv/serial/uart16550.zig`](../src/drv/serial/uart16550.zig) | For machines that have one; the 701 does not. |

Probed but **not implemented**, the table reports them so an unfamiliar machine is
diagnosable: `gma900`, `vesafb` (probe only), `ehci`, `uhci`, `hda`, `atl2`, `ath5k`,
`e1000`, `i801smb`, `lpc_ich`.

## Graphics and the GUI

| Component | File | State |
|---|---|---|
| Modesetting | [`drv/video/modeset/`](../src/drv/video/modeset/) | One interface, a backend per adapter family, chosen by the same probe that binds every other driver. Covers the netbook era by PCI id: gen3 (GMA 900/950/3150), gen4, gen5, and GMA 500 named separately because it is PowerVR and shares only a vendor id. gen3 sets the panel's native mode at boot, read from the LVDS timing registers the firmware programmed, and reverts if the pipe reports an underrun. What firmware left is the fallback and always will be. |
| Display owner | [`display.zig`](../src/kernel/display.zig) | Exclusive ownership, scanout buffer handed over as a shared segment. One buffer, no page flip or vblank, which is what a VESA framebuffer offers. |
| Window manager | [`user/eeewm/`](../src/user/eeewm/) | Display server and tiling manager. Dynamic desktops, taskbar of named tabs with per-tab window menus, `V` launcher with session actions, tall/wide/monocle per desktop, floating windows, focus-follows-click, config file. Bindings by keycode; every action reachable by pointer and keyboard. |
| Window protocol | [`user/proto/`](../src/user/proto/) | Channel for control, shm ring for events, shm surface per window. Wire types and the client half; the server half is policy and lives with the manager. `FileDialog` puts `eui`'s chooser panel in a floating window, which is here rather than in the toolkit because opening one means talking to the manager. |
| Control library | [`user/eui/`](../src/user/eui/) | Surface and primitives, swappable theme, buttons, toggles, checkboxes, labels, progress bars, menus, a scrolling table with columns and a tree column, an editable soft-wrapped text area and one-line field, a menu bar with dropdowns and shortcut hints, draggable scrollbars, a status bar of fields, a file chooser panel, keyboard focus with Tab order, per-widget damage. |
| Fonts | [`lib/font.zig`](../src/lib/font.zig) | Shared by kernel and userspace. Spleen 8x16 and 12x24 monospaced for the console, Ark Pixel 12 proportional for interface text. Subset covers Latin-1, punctuation, arrows, box drawing, blocks and shapes; the range table is shared with the generator so slots cannot disagree. |

## Userspace

| Program | File | State |
|---|---|---|
| `init` | [`user/init.zig`](../src/user/init.zig) | PID 1. Manifest parsing, dependency order, restart policy, orphan reaping. |
| `vsh` | [`user/vsh.zig`](../src/user/vsh.zig) | Builtins, program lookup in `/bin`, multicall dispatch, pipelines, `>` and `>>` redirection. Line editing with history and completion; the prompt shortens home to `~` and carries the last command's status in the colour of its arrow. |
| Tools | [`user/tools/`](../src/user/tools/) | `ls cat rm mv mkdir tree hexdump file grep page free top kill log irq devices display disk mount unmount svc cfg date eeefetch smbios` |
| `cfgd` | [`user/cfgd/`](../src/user/cfgd/) | The one writer of the settings store. Validates against a schema fixed at build time, writes the domain's file, and signals an event per domain so a change reaches whoever is watching. |
| `devmgd` | [`user/devmgd/`](../src/user/devmgd/) | Reads a manifest per driver from `/lib/drivers`, matches it against the bus with an exact part beating a family, and starts it with the capabilities the manifest asks for. Leaves alone anything the kernel already drives. |
| `platd` | [`user/platd/`](../src/user/platd/) | The platform service: what the BIOS and the embedded controller still own. uACPI interprets the tables in a process with the driver and power capabilities and nothing else. What runs on it: the embedded controller (`ec`), vendor bring-up and quirks (`asus`, `quirks`), battery, backlight, hotkeys, sleep states and power off through the firmware's own methods. |
| Shared code | [`user/lib/`](../src/user/lib/) | Buffered streams, the heap, paths, colour by role, console shape, config parsing, line editing, completion, time formatting, sysinfo, the process table. |
| Heap | [`user/lib/heap.zig`](../src/user/lib/heap.zig) | Size-class free lists over pages the kernel hands out, exposed both as raw calls and as `std.mem.Allocator`. `malloc` is a wrapper over it, not the other way round. Blocks larger than the classes get a whole segment and are recycled through a reuse list rather than let go, so a caller that churns one size pays for the segment once. |
| Streams | [`user/lib/stream.zig`](../src/user/lib/stream.zig) | Buffered reads and writes over a handle. Standard output is one instance; a C `FILE` is another. |
| eeelibc | [`user/libc/`](../src/user/libc/) | Enough C for a POSIX program to build and run: crt0, errno, descriptors, the heap, stdio with one formatter and a scanner, strings and ctype, termios, `TIOCGWINSZ`, time. A descriptor is a kernel handle, so there is no table. No `fork`, no asynchronous signals, no sockets, no float conversions. |
| Directory listing | [`user/lib/dir.zig`](../src/user/lib/dir.zig) | One decoded listing, parent first, then directories, then names written the way they should be read. |
| Pipes | [`kernel/pipe.zig`](../src/kernel/pipe.zig) | Byte stream with a reader and writer count, waitable by `wait_many`. Bound to a child's standard streams at spawn. |

## Applications

Built in the order of [design §10.8](../design/00-vibeee.md): each needs only what the one
before it forced into place.

| Program | File | State |
|---|---|---|
| Settings | [`user/apps/settings.zig`](../src/user/apps/settings.zig) | Theme, bar position and layout, edited through `cfgd` and generated from the same schema `cfg` uses. The theme applies live. |
| Monitor | [`user/apps/monitor.zig`](../src/user/apps/monitor.zig) | Process tree with per-process CPU share, memory and uptime, refreshed twice a second. Ends a selected process. |
| Pad | [`user/apps/pad.zig`](../src/user/apps/pad.zig) | Text editor: soft-wrapped editing in the interface face, a File menu, open and save through the floating file dialog, live byte count. |
| kilo | [`third_party/kilo/`](../third_party/kilo/), [`user/ports/kilo.c`](../src/user/ports/kilo.c) | antirez's editor, unmodified, built with `eeecc` against eeelibc. A wrapper renames its `main` at compile time to give it the alternate screen, so an update is a re-fetch rather than a merge. |
| eTerm | [`user/eterm/`](../src/user/eterm/) | Terminal window running `vsh` over a pipe pair. Extended VT100 per [design §16](../design/10-gui.md): cursor movement, erase, insert and delete, scrolling regions, alternate screen, SGR with 256 colours, DECCKM, OSC titles. Line editing is the terminal's, until `vsh` does its own. |

## Shared between kernel and userspace

[`src/lib/`](../src/lib/) is compiled into both. It imports nothing else, enforced on every
build.

| Module | Purpose |
|---|---|
| [`syscalls.zig`](../src/lib/syscalls.zig) | The ABI as data: numbers, flags, wire formats. Generates the dispatcher binding and [`syscalls.md`](syscalls.md). |
| [`ring.zig`](../src/lib/ring.zig) | SPSC shared-memory ring layout. |
| [`civil.zig`](../src/lib/civil.zig) | Calendar arithmetic. |
| [`escapes.zig`](../src/lib/escapes.zig) | The terminal escape-sequence state machine. Two terminals here and one grammar: the console draws into a text grid and eTerm into a window. |
| [`style.zig`](../src/lib/style.zig) | What a line of output means, so both sides colour it the same. Roles rather than colours, because the two do not encode colour the same way. |
| [`driver.zig`](../src/lib/driver.zig) | Driver confidence and binding state, so the boot table and `devices` cannot describe the same binding differently. |
| [`str.zig`](../src/lib/str.zig) | Strings, and the one place a number becomes digits. |
| [`logo.zig`](../src/lib/logo.zig) | The wordmark, drawn by the kernel and by `eeefetch`. |

## Testing

- `make test`: host-side unit tests (bootinfo layout, keymap tables, QR encoder, run
  queues, calendar, ring buffer, battery arithmetic and its mislabeled-percent correction,
  command-line flag matching, the terminal emulator and its key encoding, text wrapping
  and cursor arithmetic) plus a differential check of the QR encoder against `libqrencode`
  across all eight masks.
- `zig build check`: the layering rules, and a check that no module imports something it never uses.
- Boot self-tests, heap, syscall ABI, clock advance, IPC. Each reports `fail` on the boot
  log rather than hanging, because the target has no serial port.
- `make shot OUT=x.png TYPE="..."`, boot headless, type at the shell, screenshot, and a full serial transcript beside it.

## The boot log

Two command-line gates, and they decide different things. `verbose` shows the boot's
narration, one line per component and per service as it comes up; `debug` is the tier
beneath it, for chasing a fault, and is the one kind of line that is not recorded when it
was never asked for. A quiet boot shows failures and warnings only, and the whole story,
kernel and services alike, is still in the ring behind `log`, which keeps its own needle
filter and a `-n` tail.

## Milestones

Against the table in [design §15](../design/00-vibeee.md).

**M0 is complete.** Boot chain, kernel entry, PMM/paging/heap, IDT, LAPIC/IOAPIC, timers,
scheduler, syscalls, Ring 3, IPC, ramfs, VESA console, i8042 keyboard and `vsh` are all in
and exercised on every boot.

**M1 is nearly complete**, and the gate is met:

| Item | State |
|---|---|
| PATA + FAT32 | Done, reading and writing |
| `init` | Done: manifests, dependency order, restart policy, orphan reaping |
| `devmgd` | Done. Matches `/drivers/*.manifest` against the bus and starts each driver with the capabilities its manifest asks for. No userspace driver is written yet, so it matches and reports |
| `eeelibc` | Done enough to build and run a POSIX program: kilo compiles unmodified and edits and saves. No `fork`, no asynchronous signals, no sockets, no float conversions |
| Multicall utilities | Done |
| Touchpad | Works in relative mode; no tap zones, edge scrolling or gestures |
| **GMA900 native modeset** | Done and verified on the machine: gen3 reads the panel's timing from the registers firmware programmed and sets it at boot, reverting if the pipe reports an underrun |
| **First boot on real hardware** | Done. The machine boots its image from the SD slot and comes up running; what remains below is the polish, not the bring-up |
| Battery and backlight | Done: `_BIF`/`_BST` through the embedded controller, with this family's mislabeled-percent quirk corrected by vendor in `quirks` and the health figure labelled as the firmware's own word. `_BIF` is read once per session, because spamming it wedged the interpreter into an out-of-memory state that took `_PTS` down with it; a derived rate covers the times the firmware's own is unusable |
| `eeewm` + `libeui` | Done, and past what M1 asked for |
| eTerm | Done |
| Files, Edit | Moved to M3 with the rest of the GUI app work, which is parked there for now |
| Keymaps | Done: US-International and Belgian AZERTY, chosen by a setting or cycled with `Super+Space`, and the choice is remembered |

**M1 is complete**: the machine boots the image from its SD slot and runs. What M2 still
owes is the hardware services (USB, audio, networking) and what M3 owes includes the GUI
apps parked there.

## Known gaps

- Nothing written survives a reboot. `/etc` and `/home` are part of the root image, which
  is rebuilt from the boot medium every time, so settings are set for one session only.
  The persistent volume they are meant to mount from does not exist yet.
- **The final power cut.** Power off reaches `_PTS` and writes the sleep state, the panel
  goes dark, and the power LED stays on: the transition is not finishing. The causes that
  made it look finished are gone: the fallback path no longer writes the sleep registers a
  second time with the raw FADT's values after the service answered, and the kernel's own
  write preserves SCI_EN and splits SLP_TYP from SLP_EN the way ACPICA does. Every step of
  a shutdown is now narrated, so the next try says where it stops. What the machine needs
  after a formed `_S5_` request is still open.
- The pointing device runs in relative mode: no tap zones, edge scrolling or multi-finger gestures.
- Wheel decoding is untested; QEMU's monitor cannot generate scroll events.
- No USB, audio or networking.
- No environment: `getenv` answers null, and `HOME` and the program search path are
  constants in the shell.

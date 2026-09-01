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
| Driver capabilities | [`kernel/irqevent.zig`](../src/kernel/irqevent.zig), [`syscall/driver.zig`](../src/kernel/syscall/driver.zig) | `irq_attach` hands a device line to userspace as something `wait_many` accepts: the kernel's handler masks and signals, the driver services the device and acknowledges. `ioport_grant` opens ports through the CPU's own permission bitmap, copied into the TSS only when the process holding it changes. `map_device` maps a register aperture uncached, marked as belonging elsewhere so teardown does not hand device memory to the page allocator. `pci_read`/`pci_write` answer configuration space with the kernel as its one owner: the two config ports are one shared index pair, and no driver server reaches them itself. All need the driver capability. |
| Interrupts | [`kernel/irq.zig`](../src/kernel/irq.zig), [`arch/x86/lapic.zig`](../src/arch/x86/lapic.zig), [`arch/x86/ioapic.zig`](../src/arch/x86/ioapic.zig) | LAPIC and IOAPIC, routed from the MADT with the firmware's polarity and trigger per line. The 8259s remain the fallback for a machine that describes no controller. PCI interrupts take the firmware's `_PRT` routing rather than the legacy pin. The PIRQ pins ride the falling edge of their active-low wires: a level entry owes the controller a completion to drop its remote-IRR, this machine's firmware traps every runtime word said to the controller, the dedicated completion doorbell included, and an edge entry holds no such state. What makes edge lossless is the drivers' own discipline: each services until its status reads quiet, so the wire is released on exit and every later cause is a fresh edge. The SCI alone keeps level semantics with completion deferred until its owner clears the source, and occupies the lowest priority class. IOAPIC entries are established at boot because the firmware co-owns the controller from system management mode, and the runtime never reaches the controller at all, reads and completions included: runtime questions are answered from the boot record of every entry. SCI activation is a separate protocol: uACPI loads without automatic mode entry, explicitly retains legacy mode by default, finalizes handlers, registers the service, claims the line, and only then may perform the FADT-defined ACPI-mode transition. There is no raw SCI_EN syscall bypass. |
| Syscalls | [`syscall.zig`](../src/kernel/syscall.zig) + [`syscall/`](../src/kernel/syscall/) | Bound to the table at comptime in both directions. SYSENTER where the CPU has it, `int 0x80` otherwise, same register convention either way; userspace asks the kernel which was armed rather than trusting CPUID. |
| Timekeeping | [`clock.zig`](../src/kernel/clock.zig) | Monotonic + wall clock as offset plus uptime. |
| Boot watchdog | [`watchdog.zig`](../src/kernel/watchdog.zig) | Armed once interrupts are on, stood down by `boot_ok`. A boot that stops making progress ends in the panic screen, QR and all; an `init` that reports late (see `netlate` below) keeps it armed through the suspect's grace period. |
| NMI watchdog | [`arch/x86/nmiwatch.zig`](../src/arch/x86/nmiwatch.zig) | The dead man's switch, armed for the machine's whole life on real hardware: a performance counter delivers NMI every couple of seconds, the one delivery no `cli` silences, and each firing asks whether the timer tick advanced. A frozen machine becomes a panic screen naming the interrupted instruction instead of a still photograph; a freeze that leaves no panic behind is thereby convicted of a hung bus transaction or a firmware seizure, the two classes even NMI cannot pierce. Not armed under emulation, whose counters count nothing. The `wedge` boot flag seizes the machine on purpose ten seconds in, to prove the whole path end to end on hardware. |
| Platform quirks | [`quirks/`](../src/quirks/) | One module per machine family, one registry, evaluated in the early probe against the DMI identity. Rules match vendor, a whole product family (exact names plus prefixes) or a board name; corrections (the EC port pair, the battery percent mislabel) are read by kernel code directly and by `platd` through `sysinfo` (`quirks`, `quirks.ec`, `quirks.battery`, `acpi.pm`). The whole registry is data in, corrections out: no driver imports it, and the layering check enforces that. |
| Shutdown | [`shutdown.zig`](../src/kernel/shutdown.zig) | Orderly, in one call: `stop_all` ends every other process and waits for their exits to release IRQ lines, device claims and DMA, then flush, unmount, ACPI off. `platd` runs the same sequence before `_PTS`. Busy-wait free: the keyboard-controller reset poll and the sleep-write pause sleep on the scheduler. |
| Panic | [`panic.zig`](../src/kernel/panic.zig), [`qr.zig`](../src/kernel/qr.zig) | QR-encoded crash dump, verified against libqrencode. |

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
| PCI | [`drv/bus/pci.zig`](../src/drv/bus/pci.zig) | Enumeration, config space, single-owner config access for driver servers, and the boot-time USB handover: the firmware's input emulation is asked off before its periodic system management trap can share interrupt plumbing with an unmasked line. |
| VGA text | [`drv/video/vgatext.zig`](../src/drv/video/vgatext.zig) | Done, including the hardware cursor and hiding it. |
| Framebuffer console | [`drv/video/fbcon.zig`](../src/drv/video/fbcon.zig) | 32bpp, Spleen font, pixel rectangles for the panic QR, a drawn cursor, and a cell grid that carries content across a mode change. One writer renders at a time: an interrupt landing inside another context's half-drawn line keeps the log record and the serial mirror but leaves the pixels alone. Debug boots keep two corner tells for reading a frozen photograph: the heartbeat glyph, which moves as long as timer interrupts arrive, and beside it the last interrupt vector taken, bright while its handler runs and dimmed when it completed, so a freeze names the context that died. |
| i8042 | [`drv/input/i8042.zig`](../src/drv/input/i8042.zig) | Keyboard, scancode set 1. Owns the controller; the second port is below. |
| PS/2 pointer | [`drv/input/ps2mouse.zig`](../src/drv/input/ps2mouse.zig) | Three buttons, motion, drag. IntelliMouse wheel negotiated and decoded but not verified against hardware. Synaptics and Elantech identified, both driven in relative mode. |
| CMOS RTC | [`drv/rtc/cmos.zig`](../src/drv/rtc/cmos.zig) | Read at boot to seed the clock. |
| ACPI tables | [`drv/acpi/tables.zig`](../src/drv/acpi/tables.zig) | RSDP/RSDT/FADT, `_S5_` pattern match. No AML interpreter. |
| ACPI power | [`drv/acpi/power.zig`](../src/drv/acpi/power.zig) | Power off, reset. |
| SMBIOS | [`drv/platform/smbios.zig`](../src/drv/platform/smbios.zig) | DMI decoding for `smbios` and `eeefetch`. |
| UART 16550 | [`drv/serial/uart16550.zig`](../src/drv/serial/uart16550.zig) | For machines that have one; the 701 does not. |

Probed but **not implemented**, the table reports them so an unfamiliar machine is
diagnosable: `gma900` as a driver of its own, the kernel holding the modeset instead,
`vesafb` (probe only), `i801smb` and `lpc_ich`.

## Graphics and the GUI

| Component | File | State |
|---|---|---|
| Modesetting | [`drv/video/modeset/`](../src/drv/video/modeset/) | One interface, a backend per adapter family, chosen by the same probe that binds every other driver. Covers the netbook era by PCI id: gen3 (GMA 900/950/3150), gen4, gen5, and GMA 500 named separately because it is PowerVR and shares only a vendor id. gen3 sets the panel's native mode at boot, read from the LVDS timing registers the firmware programmed, and reverts if the pipe reports an underrun. What firmware left is the fallback and always will be. |
| Display owner | [`display.zig`](../src/kernel/display.zig) | Exclusive ownership, scanout buffer handed over as a shared segment. One buffer, no page flip or vblank, which is what a VESA framebuffer offers. |
| Window manager | [`user/eeewm/`](../src/user/eeewm/) | Display server and tiling manager. Desktops exist while occupied or viewed, gaps allowed and numbers never shifting; one tiling arrangement with per-desktop maximise; floating windows; focus-follows-click. The bar carries named tabs with per-tab window menus and dim number chips while Super is held, a launcher summoned to the middle of the screen that narrows as you type, and status menus for network, sound and power, the last carrying the backlight. Bindings live in one table ([`user/lib/bindings.zig`](../src/user/lib/bindings.zig)) that the dispatch switches on exhaustively and the Settings help pane lists, so a chord that is documented is a chord that works. Compositing is the surface's own row-wise copy; a window owns its surface and damage, so reordering windows can never separate one from its pixels. |
| Window protocol | [`user/proto/`](../src/user/proto/) | Channel for control, shm ring for events, shm surface per window. Wire types and the client half; the server half is policy and lives with the manager. `FileDialog` puts `eui`'s chooser panel in a floating window, which is here rather than in the toolkit because opening one means talking to the manager. |
| Control library | [`user/eui/`](../src/user/eui/) | Surface and primitives, swappable theme with a chosen highlight applied everywhere at once, buttons, toggles, checkboxes, swatch rows, theme-preview tiles, labels, progress bars, sliders, meters, menus with icons and multi-column layouts, a scrolling table with columns, icons and a tree column, a section rail, a window footer, a control strip, an editable soft-wrapped text area and one-line field, a menu bar with dropdowns and shortcut hints, draggable scrollbars, a status bar of fields, a file chooser panel, keyboard focus with Tab order, per-widget damage. Its reference, [`docs/libeui.md`](libeui.md), is generated from the toolkit on every build. |
| Fonts | [`lib/font.zig`](../src/lib/font.zig) | Shared by kernel and userspace. Spleen 8x16 and 12x24 monospaced for the console, Ark Pixel 12 in two cuts for the desktop: proportional for interface text, monospaced for the terminal, so a shell and a button label speak in one voice. Subset covers Latin-1, punctuation, arrows, box drawing, blocks and shapes; the range table is shared with the generator so slots cannot disagree. |

## Userspace

| Program | File | State |
|---|---|---|
| `init` | [`user/init.zig`](../src/user/init.zig) | PID 1. Manifest parsing, dependency order, restart policy, orphan reaping. The boot line can hold a service down (`nonet`, `nohw`) or start one late (`netlate`), which is how a suspect driver is kept off the machine, or brought up under the watchdog, from outside where only the boot line can reach. |
| `vsh` | [`user/vsh.zig`](../src/user/vsh.zig) | Builtins, program lookup in `/bin`, multicall dispatch, pipelines, `>` and `>>` redirection. Line editing with history and completion; the prompt shortens home to `~` and carries the last command's status in the colour of its arrow. |
| Tools | [`user/tools/`](../src/user/tools/) | `ls cat rm mv mkdir tree hexdump file grep page free top kill log irq devices display disk mount unmount svc cfg date eeefetch smbios sysinfo net backlight battery vol` |
| `cfgd` | [`user/cfgd/`](../src/user/cfgd/) | The one writer of the settings store. Validates against a schema fixed at build time, writes the domain's file, and signals an event per domain so a change reaches whoever is watching. |
| `devmgd` | [`user/devmgd/`](../src/user/devmgd/) | Reads a manifest per driver from `/lib/drivers`, matches it against the bus with an exact part beating a family, and starts it with the capabilities the manifest asks for. Leaves alone anything the kernel already drives. |
| `platd` | [`user/platd/`](../src/user/platd/) | The platform service: what the BIOS and the embedded controller still own. uACPI interprets the tables in a process with the driver and power capabilities and nothing else. What runs on it: the embedded controller (`ec`), the ASUS010 vendor greeting (`asus`), battery, backlight, hotkeys, sleep states, power off through the firmware's own methods, and the interrupt model: it answers PCI routing questions from `_PRT`. The EC ports, the battery mislabel and the power-management no-touch ranges come from the kernel's quirk registry through `sysinfo`, so `platd` holds no machine knowledge of its own. Registers its service name once the firmware is fully settled (see the bring-up model below). |
| `devmgd` | [`user/devmgd/`](../src/user/devmgd/) | The one authority on which driver drives which device. Reads `/lib/drivers/*.man` manifests (each naming hardware by PCI id or class, and one home for its driver: a standalone binary it starts and stops, or a service that claims the assignment), walks the bus, and records the bindings. Resident and event-driven: services ask what they were assigned, `driver` lists and controls the standalone ones, and a rescan binds anything newly dropped in. No service compiles in a PCI id. |
| `sndd` | [`user/sndd/`](../src/user/sndd/) | The sound service. A routing graph (`lib/audiograph`) sits in the middle: every program that makes or takes sound is a node with ports, the hardware is a node like any other, and links decide who hears whom. Fan-in mixes, fan-out copies, defaults point at the hardware ins and outs until repointed. Frames ride shared `lib/spsc` rings; the channel carries only the graph's verbs. The pace is the hardware's period interrupt, one bounded mix per wake, nothing polled. Two drivers share `pcm.zig`, which holds what every PCM controller needs and none should write twice: DMA arenas, bounded settling waits, period slicing, and turning a hardware position into "how many periods finished". `ac97` runs the Intel controller's DMA engines over a 32-entry descriptor ring. `hda` runs the High Definition Audio controller and walks its codec's widget graph: nothing about the analog path is assumed, so an output pin with a converter behind it is found by following connections, and that path is what gets powered, unmuted at its own full scale, and pointed at a stream. Both were verified against the emulator's wav capture at the right frequency and amplitude, and `hda` against the machine itself, whose own ALC662 it walks the same way: playback heard out loud. `tone`, `vol` and `patch` are the tools. |
| `usbd` | [`user/usbd/`](../src/user/usbd/) | The USB bus. One event loop over the service channel, the controllers' interrupts and the volumes' doorbells; nothing polls, and a bus with nothing happening on it costs nothing. Two controller drivers sit behind one seam: `ehci.zig` for high speed, which takes the controller from the firmware by the specification's handshake and runs an asynchronous ring for control and bulk transfers and a periodic list for the endpoints hardware polls on its own behalf; and `uhci.zig` for the companions a full or low speed root port belongs to, which is the older and simpler design, registers in I/O space and descriptors of one packet each; the chipset carries four companions, and the driver is one body over four compile-time-bound units. Which of them a device is on changes nothing above. Registers are packed structs with their bit positions proven at compile time, and the descriptors take the extended form always, upper address halves present and zero, because a controller that addresses sixty-four bits reads that form whether or not it is asked to. `core.zig` enumerates: reset a port, learn its packet size, hand it an address, read what it says it is, tell it which configuration to be, and ask the device manager which driver fits; a device that stays deaf through two asks earns one fresh reset, and a transfer that dies narrates what each stage saw, so a class this build has never met is a manifest and a program away. `umass.zig` drives disks over the bulk-only transport, `hid.zig` keyboards and mice in the boot protocol every one of them speaks, and `hub.zig` more ports on a port: a hub is a device with a driver like any other, and what is behind one is enumerated exactly the way a root port's device is. A disk becomes a volume the kernel's filesystems mount; a key becomes a key, meaning whatever the layout says. `usb` is the tool. |
| `netd` | [`user/netd/`](../src/user/netd/) | The network service. One event loop, one compile-time driver registry: `e1000`, `rtl8139`, `atl2` for the 701's own Attansic, and `ar2425` for its radio, each entry declaring the interface class it produces so a radio and a wired port are told apart before either has a name. The radio driver identifies its silicon, resets it and reads its calibration store for the station address, regulatory domain and cipher capability; everything above that, the channel pipeline, rings, association and the supplicant, is refused honestly rather than faked. Rings live in DMA memory behind `dma_alloc`, interrupts are taken and acknowledged through `irqevent`, PCI routing is asked of `platd` and only then does the first packet move. Above the drivers runs lwIP (vendored verbatim, `NO_SYS`, raw API): IPv4, ARP, ICMP, UDP, TCP, a DHCP client per interface and a DNS stub, driven entirely by the loop whose wait deadline is the stack's own next timer. Configuration lives in the `net` settings domain as four matcher slots (class, driver label or bus location, most specific claim first); netd watches it and applies diffs, so `net <iface> up/down/dhcp/static` is persistent and immediate, and a machine with several NICs of one class configures each on its own. `ping` is a deferred-reply channel op, and so are `tcp_connect`, `tcp_accept` and `resolve`: the caller blocks exactly as long as the network does. Stream and datagram traffic never touches the channel: the socket bridge grants each client a shared segment (control page and two `lib/spsc` rings) plus events, with one doorbell shared by every client so the wait set never grows. lwIP's own loopback interface makes 127.0.0.1 real on a machine with no network, delivered by `netif_poll_all` before the loop sleeps. Resolution asks `/etc/hosts` before any DNS server. The boundary is hand-mirrored in `lwip.zig` with comptime layout proofs pinned twice, the Zig side and `lwipport/layout_check.c` against the vendored headers. |
| `edit` | [`user/tools/edit.zig`](../src/user/tools/edit.zig) | The editor. What it does with characters is `lib/text`, and what it does with the screen is the pager's lower half, which both it and `page` draw through: take the screen, draw the body, put a bar on the last row, read a key. Folding long lines and numbering them are that shared body's, so the two programs cannot disagree about what a text looks like, and a line that runs off the edge ends in a dim arrow rather than looking like a line that ended. What is left here is the arrangement. The text comes from a named file, from a pipe, or from nowhere; a document with no file behind it is ordinary and asks where to go when saved, which is also what opening a second file from inside relies on. Nothing is written until asked, and a file too long to hold is opened but refused a save rather than written back as its own head. |
| C examples | [`examples/`](../examples/) | Programs that prove the library rather than demonstrate it. `greet` covers arguments, formatting and allocation; `conform` checks sixty-three library behaviours against the host's C library and must match exactly; `frames` draws a scaled back buffer the way a game does; `beep` mixes and plays a tone; `bigheap` takes sixteen megabytes in one block and reads every page back. |
| The manual | [`manual/`](../manual/), [`tools/gen-manual-index.zig`](../tools/gen-manual-index.zig) | One page per command, plain text, copied to `/doc` and read with `man`. The page is also the source of the one-line summary `tools` and `help` print: a build step reads every page's title line into a comptime table, and a command with no page fails the build naming the file to write. Optional: `make MANUAL=no` (or `-Dmanual=false`) leaves the pages out of the image and the summaries out of the programs, which saves a FAT cluster run in a root filesystem read over the BIOS's own USB path; the listings then print names alone and `man` says there is no manual. On by default. The two used to be written twice and had drifted in half the commands, with one pair contradicting outright. |
| Shared code | [`user/lib/`](../src/user/lib/) | Buffered streams, the heap, paths, colour by role, console shape, config parsing, line editing, completion, time formatting, sysinfo, the process table. |
| Heap | [`user/lib/heap.zig`](../src/user/lib/heap.zig) | Size-class free lists over pages the kernel hands out, exposed both as raw calls and as `std.mem.Allocator`. `malloc` is a wrapper over it, not the other way round. Blocks larger than the classes get a whole segment and are recycled through a reuse list rather than let go, so a caller that churns one size pays for the segment once. |
| Streams | [`user/lib/stream.zig`](../src/user/lib/stream.zig) | Buffered reads and writes over a handle. Standard output is one instance; a C `FILE` is another. |
| eeelibc | [`user/libc/`](../src/user/libc/) | Enough C for a POSIX program to build and run: crt0, errno, descriptors, the heap, stdio with one formatter and a scanner, strings and ctype, termios, `TIOCGWINSZ`, time. A descriptor is a kernel handle, so there is no table. No `fork`, no asynchronous signals, no sockets, no float conversions. |
| Directory listing | [`user/lib/dir.zig`](../src/user/lib/dir.zig) | One decoded listing, parent first, then directories, then names written the way they should be read. |
| Pipes | [`kernel/pipe.zig`](../src/kernel/pipe.zig) | Byte stream with a reader and writer count, waitable by `wait_many`. Bound to a child's standard streams at spawn. |

## Applications

Built in the order of [design §10.8](../design/00-vibeee.md): each needs only what the one
before it forced into place. All of them run in one application frame
([`user/proto/app.zig`](../src/user/proto/app.zig)), which owns the connection, the
window, resizing, theme changes, the draw pass and the commit; a program brings a
draw hook and only the interceptions it wants.

| Program | File | State |
|---|---|---|
| Settings | [`user/apps/settings.zig`](../src/user/apps/settings.zig) | Sections down a rail: Display (theme tiles, highlight and pointer swatches, interface scale, bar position, wallpaper), Input (keyboard layout), Audio, Power (battery at length, backlight in the panel's own levels), Help (the manager's bindings, from the table it dispatches from), About (what the machine is, and nothing about what it is doing). Edited through `cfgd` from the same schema `cfg` uses; everything applies at once. |
| Monitor | [`user/apps/monitor.zig`](../src/user/apps/monitor.zig) | Process tree with per-process CPU share, memory and uptime, refreshed twice a second. Ends a selected process. |
| Pad | [`user/apps/pad.zig`](../src/user/apps/pad.zig) | Text editor: soft-wrapped editing in the interface face, a File menu, open and save through the floating file dialog, live byte count. |
| kilo | [`third_party/kilo/`](../third_party/kilo/), [`user/ports/kilo.c`](../src/user/ports/kilo.c) | antirez's editor, unmodified, built with `eeecc` against eeelibc. A wrapper renames its `main` at compile time to give it the alternate screen, so an update is a re-fetch rather than a merge. |
| eTerm | [`user/eterm/`](../src/user/eterm/) | Terminal window running `vsh` over a pipe pair, on its own warm near-black in every theme, in the interface family's monospace with line-drawing synthesized from cell geometry. Extended VT100 per [design §16](../design/10-gui.md): cursor movement, erase, insert and delete, scrolling regions, alternate screen, SGR with 256 colours, DECCKM, OSC titles. Line editing is the terminal's, until `vsh` does its own. |
| Files | [`user/apps/efm.zig`](../src/user/apps/efm.zig) | Two panes over the toolkit's table, a place button per mounted volume, copy and move between the panes on F5 and F6, folders and deletion behind a question asked in the footer. Moving is a rename where one volume allows it and a copy-then-remove where it does not. |

## Programs that are not the system

The image carries what a machine needs to start and be used. Anything else is built
apart from it and installed into `/home`, where it sits beside the files it works on.

| Component | File | State |
|---|---|---|
| Recipes | [`apps/`](../apps/) | One directory per program: an `app.mk` saying where its source comes from and how to build it, and whatever platform half this system needs that the upstream project has no reason to carry. Third-party source is never committed, and is fetched into `build/apps/`. `make apps` builds all of them, `make app APP=<name>` one. |
| Staging | `home/` | What an app build writes into, and what the image seeds `/home` from. The host side is the source of truth, so rebuilding the image puts an installed program back rather than losing it with the old one. Untracked. |
| Doom | [`apps/doom/`](../apps/doom/) | The portable engine, whose platform half is six calls: this one answers them with the framebuffer, the key stream and the clock. Its source list is read out of the engine's own makefile rather than copied, so a file added upstream arrives without anyone noticing it should have. It builds, runs at the size the screen comes up at, takes input, and writes a save into `/home` through the FAT driver. Sound has no backend yet. Data is not fetched: the recipe names the WAD it wants and where to get it, and stops there. |

## Shared between kernel and userspace

[`src/lib/`](../src/lib/) is compiled into both. It imports nothing else, enforced on every
build.

| Module | Purpose |
|---|---|
| [`syscalls.zig`](../src/lib/syscalls.zig) | The ABI as data: numbers, flags, wire formats. Generates the dispatcher binding and [`syscalls.md`](syscalls.md). |
| [`ring.zig`](../src/lib/ring.zig) | SPSC shared-memory ring layout. |
| [`civil.zig`](../src/lib/civil.zig) | Calendar arithmetic. |
| [`mmio.zig`](../src/lib/mmio.zig) | A device's register window: an enum names the offsets, the window is instantiated for the width they are reached at, and instantiating it proves every offset is aligned for that width. Shared by the drivers, so the volatile access and the proof exist once. |
| [`ieee80211.zig`](../src/lib/ieee80211.zig) | 802.11 framing, pure and host-tested: frame control, the four-address rules the distribution-system bits select between, the QoS and high-throughput control words, and translation to and from ethernet through LLC/SNAP. |
| [`audio.zig`](../src/lib/audio.zig) | Sound as numbers: frames, periods, durations, volume as percent scaled without floating point, mixing that clips rather than wraps, and a fixed-point sine for tones and beeps. Host-tested. |
| [`text.zig`](../src/lib/text.zig) | An editable text as arithmetic: where the lines are, where the cursor is, and what typing or deleting does to both. UTF-8 throughout, so a cursor never lands inside a character and a delete never takes half of one. The column a cursor is asking for is remembered across short lines, which is the one thing everybody notices when an editor gets it wrong. The line index and the window arithmetic are shared with the pager, since a reader and an editor have to agree about what a line is. Pure, host-tested. |
| [`usb.zig`](../src/lib/usb.zig) | The bus as data: request types, descriptors parsed from bytes at whatever offset they sit at, the walk over a configuration, pipes that own their data toggle, and the signature a driver is looked up by, which a manifest may name several of. Pure, host-tested. |
| [`scsi.zig`](../src/lib/scsi.zig) | The bulk-only transport and the part of SCSI a disk needs: command and status wrappers little endian because USB is, the commands inside them big endian because SCSI is, and what capacity, sense and inquiry answers mean. Pure, host-tested. |
| [`hid.zig`](../src/lib/hid.zig) | The boot protocol: the keyboard and mouse report shapes, the table between HID's usage numbers and the keys this system names, built once at compile time, and the difference between two reports, which is what a keystroke actually is. Pure, host-tested. |
| [`volume.zig`](../src/lib/volume.zig) | What the kernel and a userspace disk driver agree about: requests, statuses, and how the shared area they travel in is divided. Held in one place because it is the one thing neither side may have its own version of. Pure, host-tested. |
| [`audiograph.zig`](../src/lib/audiograph.zig) | The routing graph: nodes, source/sink ports, links, defaults. Fan-in is mixing and fan-out copying by topology, so a mixer or recorder is one more node. Pure, host-tested. |
| [`wifi.zig`](../src/lib/wifi.zig) | What a radio can be tuned to and how fast it may talk: band, channel with frequency both ways, channel width, security, SSID as octets, signal, and a rate that is either a legacy rate (whose enum values are the wire encoding) or a modulation-and-coding index. Covers b, g and n, so a later radio changes which values appear and not the vocabulary above it. |
| [`escapes.zig`](../src/lib/escapes.zig) | The terminal escape-sequence state machine. Two terminals here and one grammar: the console draws into a text grid and eTerm into a window. |
| [`style.zig`](../src/lib/style.zig) | What a line of output means, so both sides colour it the same. Roles rather than colours, because the two do not encode colour the same way. |
| [`driver.zig`](../src/lib/driver.zig) | Driver confidence and binding state, so the boot table and `devices` cannot describe the same binding differently. |
| [`str.zig`](../src/lib/str.zig) | Strings, and the one place a number becomes digits. |
| [`logo.zig`](../src/lib/logo.zig) | The wordmark, drawn by the kernel and by `eeefetch`. |

## Testing

- `make test`: host-side unit tests (bootinfo layout, keymap tables, QR encoder, run
  queues, calendar, ring buffer, battery arithmetic and its mislabeled-percent correction,
  the quirk registry's family matching, command-line flag matching, the terminal emulator
  and its key encoding, text wrapping and cursor arithmetic) plus a differential check of the QR encoder against `libqrencode`
- Every file that holds tests is reached by one of the runners, and that is checked
  rather than assumed: the shared library through the test block in `lib.zig`, which
  names its declarations, and everything else by being imported in `src/tests.zig` or
  `src/quirks/tests.zig`. A file that is only re-exported is not analysed until
  something reaches for it, and a runner collects tests from the files it analyses, so
  a file nobody names builds cleanly, reports success, and runs nothing. The way to
  prove a file is in the run is to make one of its tests fail on purpose and watch the
  suite go red
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

Once the shell claims the console, the screen is its conversation: everything else still
says its line, into the ring, in every boot mode. The claim dies with its owner, so the
shutdown's own narration returns to the screen for the last lines.

## The bring-up model

**A service registers its name only once it is ready to answer.** `platd` loads the
firmware, arms the SCI and finishes its transitions, then registers `/svc/platform`.

**Names order the boot, not the clock.** The manifest's `needs` lists the services and
targets a service asks questions of, and `provides` is the name init waits for before
releasing dependants. `netd` declares `needs = platd`, and because `platd` publishes
its name only once the firmware has settled, the adapter's DMA engines start after the
firmware's own boot activity by construction, with no timed allowance anywhere. The
manifest's `target` names the group a service belongs to; the boot's own services
belong to `boot`, and a service in no target starts from the supervising loop once the
targets have settled. Boot-line tokens hold any service down for one boot (`no.<name>`)
or start it late under the watchdog (`late.<name>`, short forms `nonet`, `nohw`,
`netlate`) for diagnosis.

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
| `devmgd` | Done. Matches `/drivers/*.manifest` against the bus and starts each driver with the capabilities its manifest asks for. `usbd`, `sndd` and `netd` come up this way, so what a build drives is a manifest and a program rather than a branch anybody has to edit |
| `eeelibc` | Done enough to build and run a POSIX program that draws its own pixels. `math.h` is a shim: Zig's compiler_rt already carries `sin`, `cos`, `exp`, `log`, `sqrt`, `floor`, `fmod` and the rest under their C names, and `std.math` the inverse angles, hyperbolics, `pow` and `hypot`, so what is written here is the second list wearing its C name. `printf` does the float conversions through `std.fmt.float`, with C's exponent form and `%g`'s trimming. `vibeee.h` covers what POSIX has no word for: taking the screen, reading keys, and joining the sound graph as a node with one output, with the key numbers and modifier bits generated from the enum and packed struct that define them. Parity is checked rather than claimed: `examples/conform.c` is eighty-seven facts with one right answer each, built with the host's compiler and with ours; all of them match. A process carries an environment, handed down from init and passed on by the shell, so `getenv` answers what it was told and `setenv` changes it. `strtod`, `rand`, `assert`, `stat`, `access`, `opendir`, `getopt` and the set-walking string functions are there, which is most of what a program reaches for before it reaches for anything unusual. No `fork`, no asynchronous signals, no sockets. Fixed notation rounds the way C rounds, through `lib/decimal.zig`: a double is expanded to its exact decimal, which every binary fraction has, and rounded to the nearer with a tie going to the even neighbour. The shortest decimal that reads back as a double is a different number and rounds the other way at a half, which is why the digits come from the value itself rather than from a shorter spelling of it. Infinities and NaNs are spelled out before any of that, having no expansion to take. The raw-terminal path (`tcgetattr`/`tcsetattr`, `VMIN`) is implemented and has no program exercising it |
| Multicall utilities | Done |
| Touchpad | Works in relative mode; no tap zones, edge scrolling or gestures |
| **GMA900 native modeset** | Done and verified on the machine: gen3 reads the panel's timing from the registers firmware programmed and sets it at boot, reverting if the pipe reports an underrun |
| **First boot on real hardware** | Done. The machine boots its image from the SD slot and comes up running; what remains below is the polish, not the bring-up |
| Battery and backlight | Done: `_BIF`/`_BST` through the embedded controller, with this family's mislabeled-percent quirk corrected by the kernel's quirk registry and the health figure labelled as the firmware's own word. `_BIF` is read once per session, because spamming it wedged the interpreter into an out-of-memory state that took `_PTS` down with it; a derived rate covers the times the firmware's own is unusable |
| Wired networking | Done and verified on the machine, sustained: a DHCP lease from the home router, the gateway and the internet answering every echo of every round, ARP conversation flowing both ways. On this board the interrupt lines ride the falling edge with the service-until-quiet discipline and the runtime never says a word to the interrupt controller; that ride is now a quirk of this firmware rather than the system's nature, a generic board keeps level lines with the deferred completion, and every acknowledgement says whether its pass found work, so a shared edge wire held low across a neighbour's assertion is chased by a cascade instead of going silent |
| USB | Done and verified on the machine: the high speed controller enumerates a stick and `umass` drives it, on the same port that refused to describe itself for as long as this machine has been booting. The controller addresses sixty-four bits and therefore reads the extended descriptor format whatever the segment register holds, which the emulator's thirty-two bit part never does; the descriptors carry that form always, upper halves present and zero |
| `eeewm` + `libeui` | Done, and past what M1 asked for |
| eTerm | Done |
| Files, Edit | Moved to M3 with the rest of the GUI app work, which is parked there for now |
| Keymaps | Done: US-International and Belgian AZERTY, chosen by a setting or cycled with `Super+Space`, and the choice is remembered |

**The boot line can be changed at the machine.** The loader shows what the kernel is
about to be told and waits two seconds before using it: a key in that window opens the
line for typing, which is the only moment there is, since nothing after it can change
what the kernel starts with. The change lasts for that boot alone; the medium is never
written to, so a line that stops the machine booting is undone by starting it again.
Verified in the emulator for the ordinary boot, an added flag taking effect, backspace,
an empty line, and eighty characters typed into a buffer that holds sixty-three.

**A machine that remembers.** The boot medium carries three volumes: the system,
`/cfg`, and `/home` itself. The loader records the medium's own partition signature, so
the kernel attaches the disk it actually booted from rather than whichever one it found
first. Settings are read from `/etc` and then from `/cfg` on top: a value nobody changed
is what the system was built with, and one that was changed outlives the power being
cut. Home is a volume rather than a directory in the root filesystem, because that
filesystem is rebuilt from the medium at every boot and a home that empties itself
overnight is not one. Verified across clean shutdowns and reboots, and read back off the
image from outside.

**M1 is complete** and M2 is underway: wired networking is done on the machine through
the whole stack, streams and datagrams included: `nc` carries conversations both ways
over the socket bridge, `resolve` answers names from the hosts table and DNS, `ping`
takes names, and 127.0.0.1 works with no hardware under it. Audio runs as a routing
graph over AC'97 and HDA. USB runs on EHCI: a stick enumerates, mounts under /media,
is read and written, and takes its mount with it when it is pulled; a USB keyboard
types and a USB mouse moves the pointer. A hub is a device with a driver like any
other, and what hangs off one enumerates the way a root port's device does. The boot
bring-up model (services behind `needs`/`provides`, registered settled) is
load-bearing. What M2 still owes on USB is suspend and resume. M3 owes the GUI apps
parked there.

## Known gaps

- `/etc` and `/tmp` are part of the root image, which is rebuilt from the boot medium
  every time. That is what `/etc` is for; `/tmp` is named for it. Everything a person
  writes goes to `/home`, which persists.
- **The final power cut.** Power off stops every service, flushes, reaches `_PTS` and
  writes the sleep state; the panel goes dark and the power LED stays on, so the SLP_TYP
  transition on this machine is not finished. What it needs after a formed `_S5_` request
  is still open.
- The pointing device runs in relative mode: no tap zones, edge scrolling or multi-finger gestures.
- Wheel decoding is untested; QEMU's monitor cannot generate scroll events.
- The bus is not suspended or resumed: a machine that sleeps comes back with its
  USB devices unenumerated.
- A full or low speed device behind a hub on the *high speed* controller needs split
  transactions. The queue heads carry the hub and port for them and the arithmetic is
  written, but nothing has exercised it: the emulator will not put a full speed hub on
  an EHCI bus, and the machine's own hubs are the companions' business.
- **What a file is, is decided twice.** The `file` command reads a file's first
  bytes and names what it found; the file manager's preview and its listing
  decide by suffix instead, because reading every file the cursor passes over
  would be a disk seek per keypress. Both answers are useful and neither is the
  other's: what belongs in `lib` is one recogniser with both doors, a cheap one
  from the name and a certain one from the bytes, so the icon a listing draws
  and the kind `file` reports cannot disagree.
- **A program cannot carry its own icon.** The launcher draws a picture per row
  from a list the window manager holds, so a program the manager has never heard
  of has no picture and adding one means editing the manager. What it wants is
  the icon in the program's own binary, with the shell's own set as the fallback:
  design/10-gui.md §6.7 says the shape.
- **The radio hears nothing yet.** `ar2425` brings the chip up, proves which
  silicon it is, reads its store, and now lays its descriptor chains and sets it
  listening. What is missing between that and a network is the soft MAC: a
  channel to sit on, a scan, authentication and association, and the four-way
  handshake behind them. The chains being laid is what makes those the only
  missing pieces, and transmission refuses until there is an association whose
  address a frame's header can name. The descriptor container is pinned at
  compile time; the field positions inside the control and status words follow
  ath5k and ar5k, which no datasheet backs, and are the part to doubt first on
  hardware.

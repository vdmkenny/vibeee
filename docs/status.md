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
| Platform quirks | [`quirks/`](../src/quirks/) | One module per machine family, one registry, evaluated in the early probe against the DMI identity. Rules match vendor, a whole product family (exact names plus prefixes) or a board name; corrections — the EC port pair, the battery percent mislabel — are read by kernel code directly and by `platd` through `sysinfo` (`quirks`, `quirks.ec`, `quirks.battery`, `acpi.pm`). The whole registry is data in, corrections out: no driver imports it, and the layering check enforces that. |
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
| `init` | [`user/init.zig`](../src/user/init.zig) | PID 1. Manifest parsing, dependency order, restart policy, orphan reaping. The boot line can hold a service down (`nonet`, `nohw`) or start one late (`netlate`), which is how a suspect driver is kept off the machine, or brought up under the watchdog, from outside where only the boot line can reach. |
| `vsh` | [`user/vsh.zig`](../src/user/vsh.zig) | Builtins, program lookup in `/bin`, multicall dispatch, pipelines, `>` and `>>` redirection. Line editing with history and completion; the prompt shortens home to `~` and carries the last command's status in the colour of its arrow. |
| Tools | [`user/tools/`](../src/user/tools/) | `ls cat rm mv mkdir tree hexdump file grep page free top kill log irq devices display disk mount unmount svc cfg date eeefetch smbios net` |
| `cfgd` | [`user/cfgd/`](../src/user/cfgd/) | The one writer of the settings store. Validates against a schema fixed at build time, writes the domain's file, and signals an event per domain so a change reaches whoever is watching. |
| `devmgd` | [`user/devmgd/`](../src/user/devmgd/) | Reads a manifest per driver from `/lib/drivers`, matches it against the bus with an exact part beating a family, and starts it with the capabilities the manifest asks for. Leaves alone anything the kernel already drives. |
| `platd` | [`user/platd/`](../src/user/platd/) | The platform service: what the BIOS and the embedded controller still own. uACPI interprets the tables in a process with the driver and power capabilities and nothing else. What runs on it: the embedded controller (`ec`), the ASUS010 vendor greeting (`asus`), battery, backlight, hotkeys, sleep states, power off through the firmware's own methods, and the interrupt model: it answers PCI routing questions from `_PRT`. The EC ports, the battery mislabel and the power-management no-touch ranges come from the kernel's quirk registry through `sysinfo`, so `platd` holds no machine knowledge of its own. Registers its service name once the firmware is fully settled (see the bring-up model below). |
| `devmgd` | [`user/devmgd/`](../src/user/devmgd/) | The one authority on which driver drives which device. Reads `/lib/drivers/*.man` manifests (each naming hardware by PCI id or class, and one home for its driver: a standalone binary it starts and stops, or a service that claims the assignment), walks the bus, and records the bindings. Resident and event-driven: services ask what they were assigned, `driver` lists and controls the standalone ones, and a rescan binds anything newly dropped in. No service compiles in a PCI id. |
| `sndd` | [`user/sndd/`](../src/user/sndd/) | The sound service. A routing graph (`lib/audiograph`) sits in the middle: every program that makes or takes sound is a node with ports, the hardware is a node like any other, and links decide who hears whom. Fan-in mixes, fan-out copies, defaults point at the hardware ins and outs until repointed. Frames ride shared `lib/spsc` rings; the channel carries only the graph's verbs. The pace is the hardware's period interrupt, one bounded mix per wake, nothing polled. The `ac97` driver runs the Intel controller's DMA engines over a 32-entry descriptor ring; the codec's own attenuator is the default sink's volume. `tone`, `vol` and `patch` are the tools. |
| `netd` | [`user/netd/`](../src/user/netd/) | The network service. One event loop, one compile-time driver registry: `e1000`, `rtl8139`, `atl2` for the 701's own Attansic, and `ar2425` for its radio, each entry declaring the interface class it produces so a radio and a wired port are told apart before either has a name. The radio driver identifies its silicon, resets it and reads its calibration store for the station address, regulatory domain and cipher capability; everything above that, the channel pipeline, rings, association and the supplicant, is refused honestly rather than faked. Rings live in DMA memory behind `dma_alloc`, interrupts are taken and acknowledged through `irqevent`, PCI routing is asked of `platd` and only then does the first packet move. Above the drivers runs lwIP (vendored verbatim, `NO_SYS`, raw API): IPv4, ARP, ICMP, UDP, TCP, a DHCP client per interface and a DNS stub, driven entirely by the loop whose wait deadline is the stack's own next timer. Configuration lives in the `net` settings domain as four matcher slots (class, driver label or bus location, most specific claim first); netd watches it and applies diffs, so `net <iface> up/down/dhcp/static` is persistent and immediate, and a machine with several NICs of one class configures each on its own. `ping` is a deferred-reply channel op, and so are `tcp_connect`, `tcp_accept` and `resolve`: the caller blocks exactly as long as the network does. Stream and datagram traffic never touches the channel: the socket bridge grants each client a shared segment (control page and two `lib/spsc` rings) plus events, with one doorbell shared by every client so the wait set never grows. lwIP's own loopback interface makes 127.0.0.1 real on a machine with no network, delivered by `netif_poll_all` before the loop sleeps. Resolution asks `/etc/hosts` before any DNS server. The boundary is hand-mirrored in `lwip.zig` with comptime layout proofs pinned twice, the Zig side and `lwipport/layout_check.c` against the vendored headers. |
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
| [`mmio.zig`](../src/lib/mmio.zig) | A device's register window: an enum names the offsets, the window is instantiated for the width they are reached at, and instantiating it proves every offset is aligned for that width. Shared by the drivers, so the volatile access and the proof exist once. |
| [`ieee80211.zig`](../src/lib/ieee80211.zig) | 802.11 framing, pure and host-tested: frame control, the four-address rules the distribution-system bits select between, the QoS and high-throughput control words, and translation to and from ethernet through LLC/SNAP. |
| [`audio.zig`](../src/lib/audio.zig) | Sound as numbers: frames, periods, durations, volume as percent scaled without floating point, mixing that clips rather than wraps, and a fixed-point sine for tones and beeps. Host-tested. |
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
| `devmgd` | Done. Matches `/drivers/*.manifest` against the bus and starts each driver with the capabilities its manifest asks for. No userspace driver is written yet, so it matches and reports |
| `eeelibc` | Done enough to build and run a POSIX program: kilo compiles unmodified and edits and saves. No `fork`, no asynchronous signals, no sockets, no float conversions |
| Multicall utilities | Done |
| Touchpad | Works in relative mode; no tap zones, edge scrolling or gestures |
| **GMA900 native modeset** | Done and verified on the machine: gen3 reads the panel's timing from the registers firmware programmed and sets it at boot, reverting if the pipe reports an underrun |
| **First boot on real hardware** | Done. The machine boots its image from the SD slot and comes up running; what remains below is the polish, not the bring-up |
| Battery and backlight | Done: `_BIF`/`_BST` through the embedded controller, with this family's mislabeled-percent quirk corrected by the kernel's quirk registry and the health figure labelled as the firmware's own word. `_BIF` is read once per session, because spamming it wedged the interpreter into an out-of-memory state that took `_PTS` down with it; a derived rate covers the times the firmware's own is unusable |
| Wired networking | Done and verified on the machine, sustained: a DHCP lease from the home router, the gateway and the internet answering every echo of every round, ARP conversation flowing both ways. The interrupt line rides the falling edge with the service-until-quiet discipline, and the runtime never says a word to the interrupt controller |
| `eeewm` + `libeui` | Done, and past what M1 asked for |
| eTerm | Done |
| Files, Edit | Moved to M3 with the rest of the GUI app work, which is parked there for now |
| Keymaps | Done: US-International and Belgian AZERTY, chosen by a setting or cycled with `Super+Space`, and the choice is remembered |

**M1 is complete** and M2 is underway: wired networking is done on the machine through
the whole stack, streams and datagrams included: `nc` carries conversations both ways
over the socket bridge, `resolve` answers names from the hosts table and DNS, `ping`
takes names, and 127.0.0.1 works with no hardware under it. The boot bring-up model
(services behind `needs`/`provides`, registered settled) is load-bearing. What M2
still owes is USB and audio. M3 owes the GUI apps parked there.

## Known gaps

- Nothing written survives a reboot. `/etc` and `/home` are part of the root image, which
  is rebuilt from the boot medium every time, so settings are set for one session only.
  The persistent volume they are meant to mount from does not exist yet.
- **The final power cut.** Power off stops every service, flushes, reaches `_PTS` and
  writes the sleep state; the panel goes dark and the power LED stays on, so the SLP_TYP
  transition on this machine is not finished. What it needs after a formed `_S5_` request
  is still open.
- The pointing device runs in relative mode: no tap zones, edge scrolling or multi-finger gestures.
- Wheel decoding is untested; QEMU's monitor cannot generate scroll events.
- No USB or audio; wireless is undesigned until the wired stack is proven further.
- No environment: `getenv` answers null, and `HOME` and the program search path are
  constants in the shell.

# Status

What exists, by file. The design documents describe intent; this describes what is
written. Nothing here has been audited; see the README.

No counts: they go stale. Git records when this was last true.

## Boot

| Component | File | State |
|---|---|---|
| MBR, 440 bytes | [`boot/stage1.asm`](../boot/stage1.asm) | Done. INT 13h EDD only. |
| Real-mode loader | [`boot/stage2.asm`](../boot/stage2.asm) | A20, E820, RSDP scan, unreal-mode kernel load, VBE mode set, font copy, cmdline, log ring. Shows the command line and waits two seconds for a key to edit it; the edit lasts one boot and is never written to the medium. |
| Image builder | [`tools/mkimage.zig`](../tools/mkimage.zig) | Partition table, stage placement, rootfs append. |
| Image configuration | [`src/config/`](../src/config/), [`tools/imageconfig.zig`](../tools/imageconfig.zig) | `make menuconfig`: Linux's menuconfig look and keys. `.config` in the kernel's format; `make <preset>_defconfig`, `savedefconfig`, `olddefconfig`, `list-defconfigs`. Options: processor, sizes, boot line, manual, services, desktop and its programs, desktop at boot, extra applications. Presets: minimal, console, full, and 16 netbooks. The plan filters `etc/services`, `etc/disabled`, `etc/openers` and driver manifests record by record; the default configuration reproduces the committed files byte for byte. `make check-all` checks the default configuration. Host-tested. |
| Higher-half entry | [`src/arch/x86/boot.zig`](../src/arch/x86/boot.zig), `flatboot.zig`, `multiboot.zig` | Both boot paths produce one `BootInfo`. |

## Kernel core

| Subsystem | File | State |
|---|---|---|
| Physical memory | [`pmm.zig`](../src/kernel/pmm.zig) | Bitmap allocator over E820. |
| Paging | [`arch/x86/paging.zig`](../src/arch/x86/paging.zig) | 2-level non-PAE, 4 MiB linear map, MMIO window, per-process spaces. |
| Heap | [`heap.zig`](../src/kernel/heap.zig) | Slab, exposed as `std.mem.Allocator`. Self-tests at boot. |
| Scheduler | [`sched.zig`](../src/kernel/sched.zig), [`sched/queue.zig`](../src/kernel/sched/queue.zig), [`sched/thread.zig`](../src/kernel/sched/thread.zig) | O(1), 32 priority levels, preemptive. Queues host-tested. Kernel thread stacks are 8 to 16 KiB. |
| Blocking | [`wait.zig`](../src/kernel/wait.zig) | Waiter nodes on the blocked thread's stack; no allocation. |
| User stacks | [`arch/x86/usermode.zig`](../src/arch/x86/usermode.zig), [`lib/stack.zig`](../src/lib/stack.zig) | Start at 16 pages, grow on fault to 256 (1 MiB). Leaving a syscall releases pages above the stack pointer, keeping one chunk below it. The page arithmetic is in `lib` and host-tested. |
| Events | [`event.zig`](../src/kernel/event.zig) | Counting, with `waitMany`. |
| Channels | [`channel.zig`](../src/kernel/channel.zig) | Synchronous call/reply, 64-byte payload, generation-tagged reply tokens. |
| Service registry | [`svc.zig`](../src/kernel/svc.zig) | Name to channel. |
| Shared memory | [`shm.zig`](../src/kernel/shm.zig), [`lib/ring.zig`](../src/lib/ring.zig) | Refcounted segments mapped into a per-process window. Frames survive one mapper exiting. Ring layout host-tested. |
| Handles | [`handle.zig`](../src/kernel/handle.zig) | Per-process table with rights bits: console, file, directory, event, channel, shm. Up to four per channel message. |
| ELF loading | [`elf.zig`](../src/kernel/elf.zig), [`exec.zig`](../src/kernel/exec.zig) | Static ELF32, synchronous and detached spawn. |
| Panic record | [`kernel/panicring.zig`](../src/kernel/panicring.zig) | One low-memory page holding the last panic across a warm reboot, magic and checksum guarded. The next boot reports it, logs it and clears it. |
| Kernel log | [`kernel/klog.zig`](../src/kernel/klog.zig) | 16 KiB ring of kernel lines and service lines (via the `log` syscall). Lines are recorded whether or not printed. `debug` lines are recorded only when `debug` is on the command line. |
| Capabilities | [`lib/syscalls.zig`](../src/lib/syscalls.zig) | Intersected at every spawn, so authority only narrows down the process tree. Declared per service in `/etc/services`. `Caps.service` guards the names the system's own services use ([`lib/services.zig`](../src/lib/services.zig)); other names are open to any program. The session holds no capabilities; the desktop is started with `svc start eeewm`. |
| User buffer checks | [`arch/x86/pagetable.zig`](../src/arch/x86/pagetable.zig), [`syscall/context.zig`](../src/kernel/syscall/context.zig), [`kernel/elf/plan.zig`](../src/kernel/elf/plan.zig) | Every syscall buffer is checked page by page against the caller's mappings: present, user-accessible, and writable where the kernel writes. `userRead` and `userWrite` encode the direction in the type. Program images are validated with overflow-checked sums, device apertures in 64 bits. `map_device` maps any physical range the page allocator does not own, on the driver's word; the trust is the `driver` capability, held only by first-party drivers. Host-tested and fuzzed; [`probe`](../src/user/tools/probe.zig) exercises the same checks from Ring 3. |
| Driver capabilities | [`kernel/irqevent.zig`](../src/kernel/irqevent.zig), [`syscall/driver.zig`](../src/kernel/syscall/driver.zig) | `irq_attach` hands a device interrupt to userspace as a waitable event: the kernel masks and signals, the driver services and acknowledges. `ioport_grant` sets the TSS I/O bitmap, copied on process switch. `map_device` maps an aperture uncached and excluded from the page allocator. `pci_read`/`pci_write` serialise config space through the kernel. All need `Caps.driver`. |
| Interrupts | [`kernel/irq.zig`](../src/kernel/irq.zig), [`arch/x86/lapic.zig`](../src/arch/x86/lapic.zig), [`arch/x86/ioapic.zig`](../src/arch/x86/ioapic.zig) | LAPIC and IOAPIC routed from the MADT with per-line polarity and trigger; 8259s as fallback. PCI interrupts use `_PRT` routing. See [Interrupt model](#interrupt-model). |
| Processor | [`lib/processor.zig`](../src/lib/processor.zig), [`arch/x86/fpu.zig`](../src/arch/x86/fpu.zig) | User programs are compiled for the configured processor; the kernel for the same model without SIMD. At boot the kernel stops with the name of an extension the image uses and the processor lacks. FPU state is saved with FXSAVE, from the Pentium II on. RDRAND output is stirred into the entropy pool where present. Booted in the emulator on Pentium II, VIA C7 and Atom models. |
| Syscalls | [`syscall.zig`](../src/kernel/syscall.zig) + [`syscall/`](../src/kernel/syscall/) | Bound to the table at comptime in both directions. SYSENTER where available, `int 0x80` otherwise, same register convention. Userspace asks which is armed rather than reading CPUID. |
| Timekeeping | [`clock.zig`](../src/kernel/clock.zig) | Monotonic clock, and wall clock as offset plus uptime. |
| Randomness | [`random.zig`](../src/kernel/random.zig) | No hardware source. Inter-interrupt timing is hashed in batches of 32 into a pool seeding `std.Random.DefaultCsprng`. Ready at 256 estimated bits, within 3 s at the timer rate alone. `random` fills a buffer and reports whether the pool is ready. `random_stir` lets a driver add its own source (the radio adds received noise); needs `Caps.driver`. |
| Boot watchdog | [`watchdog.zig`](../src/kernel/watchdog.zig) | Armed once interrupts are on, disarmed by `boot_ok`. A stalled boot ends in the panic screen. `netlate` keeps it armed through the late service's grace period. |
| NMI watchdog | [`arch/x86/nmiwatch.zig`](../src/arch/x86/nmiwatch.zig) | On real hardware, a performance counter raises an NMI every few seconds and checks the timer tick advanced; a frozen machine panics and names the interrupted instruction. A freeze with no panic is a hung bus transaction or firmware stall. Not armed under emulation. The `wedge` boot flag freezes the machine after ten seconds to test the path. |
| Platform quirks | [`quirks/`](../src/quirks/) | One module per machine family, one registry, matched against DMI in the early probe by vendor, product family or board name. Corrections (EC port pair, battery percent mislabel) are read by kernel code and by `platd` through `sysinfo` (`quirks`, `quirks.ec`, `quirks.battery`, `acpi.pm`). No driver imports the registry; the layering check enforces it. |
| Shutdown | [`shutdown.zig`](../src/kernel/shutdown.zig) | `stop_all` ends every other process and waits for IRQ lines, device claims and DMA to be released, then flushes, unmounts and powers off. `platd` runs the same sequence before `_PTS`. No busy waits. |
| Panic | [`panic.zig`](../src/kernel/panic.zig), [`qr.zig`](../src/kernel/qr.zig) | Panic screen with a QR-encoded register dump, verified against libqrencode. |

### Interrupt model

- PIRQ lines use falling-edge entries. This firmware traps runtime writes to the
  IOAPIC, including the EOI doorbell, so level entries cannot be completed. Edge is
  lossless because each driver services its device until status reads quiet before
  returning.
- This is a quirk of this firmware. A generic board keeps level lines with deferred
  completion. Each acknowledgement reports whether it found work, so a shared edge line
  held low across a neighbour's assertion is serviced again.
- `netd` serves every interface on a line before acknowledging it once, gives a
  shared line a second round after one that did work, and does not sleep while a
  receive budget left frames waiting
  ([`netd/lines.zig`](../src/user/netd/lines.zig), host-tested). A line not served
  for 250 ms is served on the next pass the loop takes for another reason.
- The SCI keeps level semantics, completes only after its owner clears the source, and
  sits in the lowest priority class.
- IOAPIC entries are programmed at boot; the runtime never touches the controller.
  Runtime queries are answered from the boot record.
- SCI activation: uACPI loads without entering ACPI mode, finalises handlers, registers
  the service and claims the line before the FADT-defined transition. There is no raw
  `SCI_EN` syscall.

## Storage

| Component | File | State |
|---|---|---|
| Block layer | [`block.zig`](../src/kernel/block.zig) | Device registry and MBR partition parsing. Extends the last partition on a disk over free space after it (`grow`). `block.Memory` is a memory-backed device for tests. |
| Block cache | [`bcache.zig`](../src/kernel/bcache.zig) | Read cache with hit reporting. |
| FAT | [`fat.zig`](../src/kernel/fat.zig), [`fat/alloc.zig`](../src/kernel/fat/alloc.zig) | FAT12/16/32, VFAT long names, timestamps. Cluster allocation across all FAT copies, chain extension, create, append, truncate, unlink, rename. Rename moves the directory record, never the data. |
| Volume geometry | [`fat/layout.zig`](../src/kernel/fat/layout.zig) | Where tables, root and data area sit. `read` parses a boot sector (used by mount); `toBpb` writes one (used by format); `plan` chooses a geometry for a size; `grown` chooses one for the same filesystem on a larger volume. Round-trip tested. Computed in 64 bits. |
| Clean unmount | [`fat/clean.zig`](../src/kernel/fat/clean.zig) | Clean flag cleared before a mount's first write, set after its last write reaches the medium. Written in both places systems read: the top bits of the second FAT entry and the boot-sector byte. Either clear means dirty. FAT12 has neither and is checked on every mount. |
| Volume check | [`fat/check.zig`](../src/kernel/fat/check.zig), [`fat/verdict.zig`](../src/kernel/fat/verdict.zig) | Runs at mount on a dirty volume, and on demand as `check`. Walks every chain from the root, then sweeps the table. Frees unreached clusters; cuts chains longer than their record; reduces sizes larger than their chain; ends chains that leave the volume or loop; resynchronises FAT copies. Clusters claimed by two chains are reported, never repaired, and the volume is mounted read-only. `verdict.zig` decides the repair and does no I/O. Memory: one bit per cluster plus a fixed directory stack. |
| Format | [`fat/format.zig`](../src/kernel/fat/format.zig) | `format`. Writes boot sector, FAT32 backup boot sector and FSInfo, the tables, reserved entries and an empty root. Width chosen from size unless named. Data area untouched. Leaves the volume clean. Refused on a mounted volume. |
| Grow | [`fat/grow.zig`](../src/kernel/fat/grow.zig) | `grow`. Extends the partition over free space after it, then the filesystem over the partition. A larger FAT moves the data area forward; cluster numbers are unchanged, so no chain or record is rewritten. Moves highest cluster first. Order: data, tables, boot sector. Power loss during the move leaves the volume unreadable. Refused on a mounted volume, one already filling its partition, or one that would need a wider FAT. |
| Bulk sector I/O | [`fat/bulk.zig`](../src/kernel/fat/bulk.zig) | Clear, copy and shift runs of sectors for format and grow. One static buffer, since kernel thread stacks are too small for it. Callers hold the mount table lock. |
| Mount table | [`vfs.zig`](../src/kernel/vfs.zig) | Longest-prefix resolution, open-file counting, read-only enforcement per mount and per device. All writes go through here. `mount`, `unmount`, `check`, `format` and `grow` need `Caps.mount`. |
| ATA | [`drv/block/ata.zig`](../src/drv/block/ata.zig) | PIO. No DMA. |
| Ramdisk | [`drv/block/ramdisk.zig`](../src/drv/block/ramdisk.zig) | Backs the boot-to-RAM root filesystem. |

## Drivers

| Driver | File | State |
|---|---|---|
| PCI | [`drv/bus/pci.zig`](../src/drv/bus/pci.zig) | Enumeration at boot and on rescan, config space, single-owner config access for driver servers. Disables firmware USB legacy emulation at boot, before its SMM trap can share an interrupt line. |
| VGA text | [`drv/video/vgatext.zig`](../src/drv/video/vgatext.zig) | Done, including the hardware cursor. |
| Framebuffer console | [`drv/video/fbcon.zig`](../src/drv/video/fbcon.zig) | 32 bpp, Spleen font, QR rectangles for the panic screen, drawn cursor. Writes update a cell grid; `present` redraws changed cells once per write. One renderer at a time: an interrupt during another context's draw still records and mirrors the line but does not draw it. Debug boots show a heartbeat glyph and the last interrupt vector (bright while running, dim when done) in a corner. |
| i8042 | [`drv/input/i8042.zig`](../src/drv/input/i8042.zig) | Keyboard, scancode set 1. Owns the controller. |
| PS/2 pointer | [`drv/input/ps2mouse.zig`](../src/drv/input/ps2mouse.zig) | Three buttons, motion, drag. IntelliMouse wheel negotiated and decoded, not verified on hardware. Synaptics and Elantech identified; both in relative mode. |
| CMOS RTC | [`drv/rtc/cmos.zig`](../src/drv/rtc/cmos.zig) | Read at boot to seed the clock, and on resume. |
| ACPI tables | [`drv/acpi/tables.zig`](../src/drv/acpi/tables.zig) | RSDP, RSDT, FADT, MADT. Pattern-matches `_S5_` and `_S3_` in the DSDT. No AML interpretation in the kernel; `platd` runs uACPI. |
| ACPI power | [`drv/acpi/power.zig`](../src/drv/acpi/power.zig) | Power off, reset, and the PM1 write that suspends to memory. |
| Suspend to memory | [`sleep.zig`](../src/kernel/sleep.zig), [`arch/x86/s3.zig`](../src/arch/x86/s3.zig), [`boot/s3wake.asm`](../boot/s3wake.asm) | `suspend`, and Sleep in the desktop menu. See [Suspend](#suspend). |
| SMBIOS | [`drv/platform/smbios.zig`](../src/drv/platform/smbios.zig) | DMI decoding for `smbios` and `eeefetch`. |
| UART 16550 | [`drv/serial/uart16550.zig`](../src/drv/serial/uart16550.zig) | For machines that have one. The 701 does not. |

The driver table lists only drivers the build contains; a device with no entry is
unclaimed. Chipset bridges and the SMBus controller are listed by class and not
driven. Modesetting belongs to the kernel; `firmware-set` keeps the firmware's mode.

### Suspend

- `platd` evaluates `_PTS` and arms the wake. The kernel flushes filesystems, saves
  CPU state, places a real-mode trampoline at 0x2000, writes its address to the FACS
  waking vector, and writes PM1.
- Wake enters the trampoline, which switches to protected mode with paging on and
  restores the descriptor tables and the suspending thread's stack.
- Restored in order: MTRRs, interrupt controller redirection entries, SYSENTER MSRs,
  timers, PCI headers, display mode, i8042 configuration, wall clock from the RTC.
- Each hardware service is then woken by its own event and re-claims its devices.
- A machine whose display has no modeset backend refuses to suspend.
- Verified in the emulator by `make check-all`. Not run on the 701: the gen3 driver
  does not save and restore the panel power delays and watermarks.

## Graphics and the GUI

| Component | File | State |
|---|---|---|
| Modesetting | [`drv/video/modeset/`](../src/drv/video/modeset/) | One interface, one backend per adapter family, bound by the device probe. PCI ids for gen3 (GMA 900/950/3150), gen4, gen5, GMA 500 (PowerVR, separate), and `bochs` for emulators (dispi ports plus VGA registers). gen3 sets the panel's native mode at boot from the LVDS timing firmware programmed, reverting on pipe underrun. The firmware mode is always the fallback. |
| Display owner | [`display.zig`](../src/kernel/display.zig) | Exclusive ownership; the scanout buffer is handed over as a shared segment. One buffer, no page flip, no vblank. Capabilities are reported in one field defined with the protocol. The hardware pointer plane is set through a pair of calls the composition root installs, reachable only by the display owner. |
| Pointer plane | [`drv/video/modeset/gen3cursor.zig`](../src/drv/video/modeset/gen3cursor.zig) | gen3 hardware cursor; moving it is a register write, so nothing reads the framebuffer back. The cursor image goes in the page after the scanout buffer in stolen memory, used only if the memory map shows that page is not the allocator's; otherwise the pointer is drawn in software. Registers are packed structs and the image arithmetic is pure, both host-tested. Not emulated; verified only on the machine. |
| Window manager | [`user/eeewm/`](../src/user/eeewm/) | Display server and tiling manager. See [Window manager](#window-manager). |
| Window protocol | [`user/proto/`](../src/user/proto/) | Control channel, shm event ring, shm surface per window. Wire types and client half; the server half lives with the manager. `FileDialog` hosts `eui`'s chooser in a floating window. `opening.zig` resolves which program opens a file, via the settings service. |
| Control library | [`user/eui/`](../src/user/eui/) | Surface and primitives; theme with a highlight colour; buttons, toggles, checkboxes, swatches, theme tiles, labels, progress bars, sliders, meters; menus with icons and columns; scrolling table with icon and tree columns; section rail; footer; control strip; text area and field; menu bar with shortcuts; scrollbars; status bar; file chooser; keyboard focus with Tab order; per-widget damage. Reference: [`docs/libeui.md`](libeui.md), generated on every build. |
| Fonts | [`lib/font.zig`](../src/lib/font.zig) | Spleen 8x16 and 12x24 for the console, linked into the kernel. Ark Pixel 12, proportional and monospaced, for the desktop. Subset: Latin-1, punctuation, arrows, box drawing, blocks, shapes; the range table is shared with the generator. `make image` packs the desktop faces into `/share/fonts.pack`; the window manager maps it once and shares the handle with every client. |

### Window manager

- Desktops exist while occupied or viewed; numbers never shift. One tiling arrangement
  with per-desktop maximise. Floating windows. Full-display focus on the manager's own
  key. Focus follows click.
- The bar: named tabs with per-tab window menus, number chips while Super is held, a
  centred launcher that filters as you type, and status menus for network, sound and
  power (including backlight).
- Bindings are one table ([`user/lib/bindings.zig`](../src/user/lib/bindings.zig)),
  dispatched exhaustively and listed in Settings help.
- Compositing is a row-wise surface copy. Each window owns its surface and damage.
- The pointer uses the hardware plane where available and is drawn in software
  otherwise, from one description of its image.
- Floating windows open at their requested size, move with Super and arrows or Super
  and drag, and stop at the screen edge.
- The launcher indexes `/home` two levels deep when it opens and ranks files with apps,
  windows and verbs. Enter opens a file with its opener; Shift+Enter opens its folder.
- Launcher rows show the icon a program carries as an ELF note
  ([design/10-gui.md](../design/10-gui.md) §6.7), or its category's icon. The system
  applications and the first-party extra applications carry one; Doom does not.

## Userspace

| Program | File | State |
|---|---|---|
| `init` | [`user/init.zig`](../src/user/init.zig) | PID 1. Manifests, dependency order, readiness, restart policy, orphan reaping. A service promising a name is up only once the name is registered; missing the window counts as a failed start. Stop asks through the quit event and ends the process after three seconds. `svc` shows `starting` and `stopping`. The boot line can hold a service down (`nonet`, `nohw`, `no.<name>`) or start it late under the watchdog (`netlate`, `late.<name>`). |
| `vsh` | [`user/vsh.zig`](../src/user/vsh.zig) | Builtins, `/bin` lookup, multicall dispatch, pipelines, `>` and `>>`. Line editing with history and completion. Prompt shows `~` for home and colours its arrow by the last exit status. |
| Tools | [`user/tools/`](../src/user/tools/) | `ls cp mv rm mkdir cat hexdump file icon find tree grep head tail wc sort pack unpack page free top kill log irq devices display disk mount unmount check format grow svc cfg date eeefetch smbios sysinfo net backlight battery vol ser`. `log -f` follows new lines on the ring's event. Lines come from [`ulib.lines`](../src/user/lib/lines.zig) and directory walks from [`ulib.walk`](../src/user/lib/walk.zig). `pack` writes ustar, checked against a real archiver both ways. |
| `edit` | [`user/tools/edit.zig`](../src/user/tools/edit.zig) | Text editor in the console. Text handling is `lib/text`; screen handling is shared with `page`, including folding, numbering and the overflow arrow. Opens a named file, a pipe, or nothing (asks for a name on save). Writes nothing until asked. A file too long to hold opens read-only. |
| `cfgd` | [`user/cfgd/`](../src/user/cfgd/) | Sole writer of the settings store. Validates against a build-time schema, writes the domain file, signals an event per domain. |
| `platd` | [`user/platd/`](../src/user/platd/) | Platform service running uACPI. See [Platform service](#platform-service). |
| `devmgd` | [`user/devmgd/`](../src/user/devmgd/) | Driver-to-device binding authority. Reads `/lib/drivers/*.man` (PCI id or class, and a standalone binary or a claiming service), walks the bus, records bindings. Services ask for their assignment; `driver` lists and controls standalone drivers. A rescan re-walks the bus first, so new drivers and newly powered hardware both bind. No service compiles in a PCI id. |
| `sndd` | [`user/sndd/`](../src/user/sndd/) | Sound service. See [Sound](#sound). |
| `usbd` | [`user/usbd/`](../src/user/usbd/) | USB bus service. See [USB](#usb). |
| `logd` | [`user/logd/`](../src/user/logd/) | Sends the kernel log to a USB serial port named in the `log` settings domain: the whole ring on open, then each new line. Covers everything from `usbd` onwards. Blocks on events only: the setting, the port list, the ring, and port buffer space. A full port buffer ends the pass and resumes from the unsent line. |
| `netd` | [`user/netd/`](../src/user/netd/) | Network service. See [Network](#network). |
| C examples | [`examples/`](../examples/) | `greet` (arguments, formatting, allocation); `conform` (library behaviours compared line by line against the host's C library, must match exactly); `frames` (scaled back buffer); `beep` (a tone); `mixing` (three tones, panned, two stopped); `bigheap` (16 MiB block, every page read back). |
| The manual | [`manual/`](../manual/), [`tools/gen-manual-index.zig`](../tools/gen-manual-index.zig) | One plain-text page per command, installed to `/doc`, read with `man`. Each page's title line is the command's summary in `tools` and `help`; a command without a page fails the build. The Manual pages option in `make menuconfig` (or `-Dmanual=false`) leaves pages and summaries out. On by default. |
| Shared code | [`user/lib/`](../src/user/lib/) | Streams, heap, paths, colour roles, console shape, config parsing, line editing, completion, time formatting, sysinfo, process table. |
| Heap | [`user/lib/heap.zig`](../src/user/lib/heap.zig) | Size-class free lists over kernel pages, as raw calls and as `std.mem.Allocator`; `malloc` wraps it. Oversized blocks get their own segment and are reused rather than released. |
| Streams | [`user/lib/stream.zig`](../src/user/lib/stream.zig) | Buffered reads and writes over a handle. Standard output and C `FILE` are both instances. |
| eeelibc | [`user/libc/`](../src/user/libc/) | See [eeelibc](#eeelibc). |

### Platform service

- uACPI runs in a process holding only `Caps.driver` and `Caps.power`.
- Provides: embedded controller, battery, backlight, hotkeys, switchable parts (radio,
  camera, card reader, USB ports, modem), sleep states, firmware power off, and PCI
  interrupt routing from `_PRT`.
- Backlight and switchable parts each have a standard backend and a vendor backend
  behind one interface.
- A vendor is one row in [`vendor.zig`](../src/user/platd/vendor.zig) plus a file
  under `vendor/`: recognition, firmware greeting, notification numbering, features.
  No other code names a vendor.
- EC ports, the battery mislabel and power-management no-touch ranges come from the
  kernel quirk registry through `sysinfo`.
- Registers `/svc/platform` once firmware is settled.
- Two firmware gates are held shut on this unit: the SCI (its method burst is not yet
  understood) and the vendor greeting (it writes a trap port whose handler sometimes
  does not return). With both shut, panel, battery, switchable parts and routing work
  on request, and nothing arrives unrequested: no lid, mains or key notifications. The
  top-row keys still work because firmware handles them in SMM. The decoding for them
  exists and activates when the gates open.

### Sound

- A routing graph (`lib/audiograph`): each program and each hardware device is a node
  with ports; links route. Fan-in mixes, fan-out copies. Defaults point at the hardware
  until changed.
- Audio travels in shared `lib/spsc` rings; the channel carries only graph operations.
- Ring depth is chosen by the opener: 1/6 s for live sound, 1/3 s for pre-written sound.
  A program producing sound per frame needs a ring at least one frame deep.
- Paced by the hardware period interrupt: one bounded mix per wake, no polling.
- `pcm.zig` is shared by every driver: DMA arenas, bounded settling waits, each
  direction's period buffers, hardware position to completed periods.
- Everything is mixed at 48 kHz. A device declares its own rate; one at 44.1 kHz has
  each period converted on the way out and in by `audio.Resampler`, exact integer
  steps with comptime weights.
- `ac97`: Intel controller, 32-entry descriptor ring.
- `es1370`: Ensoniq AudioPCI with its AK4531 codec. DAC2 and the ADC loop over their
  buffers at 44.1 kHz, the only rate its clock divides to near 48; periods are counted
  from each engine's place in its buffer. Registers and codec setup in
  [`es1370/regs.zig`](../src/user/sndd/es1370/regs.zig), host-tested.
- `hda`: High Definition Audio. Walks the codec widget graph to find an output pin with
  a converter behind it, powers and unmutes that path. Verified against the emulator's
  wav capture and by ear on the 701's ALC662.
- Ports are named by device and port, so two cards list distinctly.
- Tools: `tone`, `vol`, `patch`.

### USB

- One event loop over the service channel, controller interrupts and volume doorbells.
  No polling. Class drivers look at their watched endpoints after every event, since a
  transfer made for any event may have taken the interrupt that finished one.
- `ehci.zig`: high speed. Takes the controller from firmware by the specification
  handshake; asynchronous ring for control and bulk, periodic list for interrupt
  endpoints. What a finished chain of transfer descriptors came to is in
  [`ehci/transfer.zig`](../src/user/usbd/ehci/transfer.zig), fuzzed against a model of
  the controller.
- `uhci.zig`: full and low speed companions. I/O-space registers; the chipset's four
  companions are one driver over four comptime-bound units (`hc.unitOps`).
- `ohci.zig`: the full and low speed controller of AMD, SiS, ALi, NVIDIA and OPTi
  chipsets, up to five units. Taken from the firmware through its ownership request,
  at boot and again at open. One endpoint descriptor each for control and bulk, and one
  per watched endpoint, hung from every slot of the interrupt table. An endpoint's queue
  is in [`ohci/queue.zig`](../src/user/usbd/ohci/queue.zig), fuzzed against a model of
  the controller. OUT data is queued 32 packets at a time.
- Registers are packed structs with bit positions checked at compile time, or by host
  tests for the shapes in `lib`. Descriptors always use the 64-bit layout with upper
  halves zero.
- `core.zig` enumerates: port reset, packet size, address, descriptors, configuration,
  driver lookup through `devmgd`. A device silent through two requests gets one more
  reset. A failed transfer logs each stage.
- Class drivers: `umass.zig` (bulk-only disks), `hid.zig` (boot-protocol keyboards and
  mice), `hub.zig`, `acm.zig` (CDC-ACM serial), `ftdi.zig` (FTDI serial; values in
  [`ftdi/regs.zig`](../src/user/usbd/ftdi/regs.zig), host-tested against documented
  divisors).
- Serial ports are served through `serial.zig`, which answers the `serial` service; a
  new chip implements four functions. An idle port costs nothing; chips that report
  state on every read are read only while a program holds the port.
- `usb rebuild`, and resume, stop every controller, discard bus state and enumerate
  again. Volumes are matched to disks by physical position, so mounts survive.
- Tools: `usb`, `ser`.

### Network

- Drivers in a compile-time registry, each declaring its interface class: `e1000`,
  `rtl8139`, `e100`, `atl2` (701 wired), `atl1e` (1000 wired), `ar5212` (701 radio).
- `e1000` keeps its two descriptor rings in [`e1000/rings.zig`](../src/user/netd/e1000/rings.zig)
  and `rtl8139` its receive ring in [`rtl8139/ring.zig`](../src/user/netd/rtl8139/ring.zig),
  each fuzzed against a model of the part.
- `e100`: Intel PRO/100 (82557 to 82551) and the LAN controller in ICH2 to ICH7 and
  NM10. Receives into a descriptor ring behind a moving fence; configuration and frames
  share one command block ring. The PHY is read one register per management cycle, each
  ending in an interrupt. Both rings are in [`e100/rings.zig`](../src/user/netd/e100/rings.zig),
  fuzzed against a model of the part that runs as the hardware and as QEMU do.
- Attansic parts share block reset, MDIO, station address, gaps, half-duplex rules,
  MAC control low half and vendor PHY registers in
  [`attansic.zig`](../src/user/netd/attansic.zig), bit positions checked at build.
  802.3 registers are in [`mii.zig`](../src/user/netd/mii.zig).
- `atl1e` transmits from a descriptor ring and receives into two alternating pages of
  sequenced records. An out-of-sequence record triggers an adapter rebuild. The page
  walk is in [`rxpage.zig`](../src/user/netd/rxpage.zig), host-tested and fuzzed. All
  register and descriptor words are pinned at compile time.
- `ar5212` identifies the silicon, reads the calibration EEPROM, runs the reset and
  channel-set pipeline transcribed from FreeBSD's Atheros HAL (reference only in
  `third_party/ath_hal`; tables generated by `make athtables`), programs transmit power
  from board calibration, and delivers intact frames with signal strength.
- Radios are reached through a radio table on the interface. A radio-class driver
  without one does not compile.
- The station scans the regulatory plan's channels, tracks networks heard, and drives
  authentication, association and the four-way handshake. Rate selection uses
  per-rate success. Encryption is done in the station, independent of the radio.
- The handshake nonce comes from the entropy pool, which the radio feeds with noise,
  and is used once.
- On a protected network every data frame is decrypted under the association keys or
  dropped; accepted packet numbers are remembered against replay; only verified frames
  advance the counter.
- DMA rings via `dma_alloc`, interrupts via `irqevent`, PCI routing from `platd`
  before the first packet.
- lwIP, vendored unmodified, `NO_SYS`, raw API: IPv4, ARP, ICMP, UDP, TCP, DHCP per
  interface, DNS stub. The loop waits until the soonest of lwIP's next timer, the
  station's and the adapters'; it has no fixed wake.
- Configuration: `net` settings domain, four matcher slots (class, driver label or bus
  location; most specific wins). `net <iface> up|down|dhcp|static` persists and
  applies immediately.
- Wireless key: off takes the interface down and releases the hardware before power
  off; on powers first, rescans, then claims. A card that lost power is reclaimed and
  restarted, waiting for it to answer.
- `net load` reports wake reasons and wakes with no work. `irq` counts wakes caused by
  shared lines.
- `ping`, `tcp_connect`, `tcp_accept` and `resolve` are deferred-reply channel
  operations.
- Socket data bypasses the channel: each socket has its own segment (control page and
  two `lib/spsc` rings) and event, released on close. A socket belongs to the process
  that created it; only that process may close or accept on it. One shared doorbell.
- Loopback 127.0.0.1 through lwIP's loop interface. `/etc/hosts` is consulted before
  DNS.
- The lwIP boundary is mirrored in `lwip.zig` with comptime layout checks on both
  sides (`lwipport/layout_check.c`).

### eeelibc

- crt0, errno, descriptors (kernel handles, no table), heap, stdio with one formatter
  and a scanner, strings, ctype, termios, `TIOCGWINSZ`, time, environment (`getenv`,
  `setenv`), `strtod`, `rand`, `assert`, `stat`, `access`, `opendir`, `getopt`.
- `math.h` maps to Zig's compiler_rt and `std.math`.
- Float formatting through `std.fmt.float`, including exponent form and `%g`. Fixed
  notation rounds half to even from the exact decimal expansion, via
  [`lib/decimal.zig`](../src/lib/decimal.zig).
- `vibeee.h`: taking the screen, reading keys, joining the sound graph. Key numbers and
  modifier bits are generated from their Zig definitions.
- Checked by `examples/conform.c` against the host C library.
- Not provided: `fork`, asynchronous signals, sockets.
- `tcgetattr`/`tcsetattr` and `VMIN` are implemented with no program exercising them.

## Applications

Built in the order of [design §10.8](../design/00-vibeee.md). All run in one application
frame ([`user/proto/app.zig`](../src/user/proto/app.zig)) that owns the connection,
window, resizing, theme changes, draw pass and commit; a program supplies a draw hook.

| Program | File | State |
|---|---|---|
| Settings | [`user/apps/settings.zig`](../src/user/apps/settings.zig) | Rail sections: Display (theme, highlight, pointer, scale, bar position, wallpaper), Network (interfaces, enable, DHCP or static, heard networks for radios), Input (layout), Audio, Power (battery, backlight levels), Help (bindings), About. Edits through `cfgd` using the `cfg` schema; applies immediately. Network state is shared with `net` and the bar menu in `ulib/netconfig.zig`; the pane waits on the service's event. |
| Monitor | [`user/apps/monitor.zig`](../src/user/apps/monitor.zig) | Process tree with CPU share, memory and uptime, refreshed twice a second. Ends a selected process. |
| Pad | [`user/apps/pad.zig`](../src/user/apps/pad.zig) | Soft-wrapped text editor, File menu, open and save dialogs, byte count. Opens its command-line argument. Asks save, discard or cancel before closing with unsaved changes. |
| eTerm | [`user/eterm/`](../src/user/eterm/) | Terminal running `vsh` over a pipe pair. Extended VT100 per [design §16](../design/10-gui.md): cursor movement, erase, insert, delete, scroll regions, alternate screen, 256-colour SGR, DECCKM, OSC titles. Line editing is the terminal's until a program takes the alternate screen or sets the private line-editor mode (also honoured by the console). Full-screen programs read key sequences from the pipe ([`user/lib/keys.zig`](../src/user/lib/keys.zig), encode and decode proven inverse) and query window size in band. |
| Files | [`user/efm/`](../src/user/efm/) | Two panes, a place button per mounted volume, F5 copy and F6 move (rename within a volume, copy and delete across volumes), new folder and delete with confirmation. F3 previews: thumbnail and EXIF for photos, head of text files, kind for anything else. Enter opens with the file's opener, or runs a program. |
| Viewer | [`user/apps/eimg.zig`](../src/user/apps/eimg.zig) | One picture at a time at fit, actual or double size, rotated by hand in quarter turns on top of the EXIF orientation. EXIF sidebar, off by default. |
| Calc | [`user/apps/calc.zig`](../src/user/apps/calc.zig) | Floating calculator. Arithmetic from `lib/calc.zig`. Every pad key has a keyboard key; Tab and Space work as on every control. |
| Screenshot | [`user/apps/screenshot.zig`](../src/user/apps/screenshot.zig) | PNG of the display or the focused window, into `/home`. A command, spawned by `Super+S` and `Super+Shift+S`. The manager copies pixels; encoding happens in this process. |

## Programs that are not the system

Built separately from the image and installed into `/home`.

| Component | File | State |
|---|---|---|
| Recipes | [`apps/`](../apps/) | One directory per program: `app.mk` (source and build) plus any platform glue. Third-party source is fetched into `build/apps/`, never committed. `make apps` builds all; `make app APP=<name>` one. |
| Staging | `home/` | Build output and the image's `/home` seed. Programs go in `home/bin/`, searched before `/bin`. Untracked; rebuilding the image restores installed programs. |
| Doom | [`apps/doom/`](../apps/doom/) | Portable engine with a six-call platform layer: framebuffer, keys, clock, mixer. Source list read from the engine's makefile. Runs in a window with sound effects and saves to `/home`. No music backend. The WAD is not fetched; the recipe names it. |
| eeemod | [`apps/eeemod/`](../apps/eeemod/) | Tracker module player. [`module.zig`](../apps/eeemod/module.zig) decodes the file lazily; [`player.zig`](../apps/eeemod/player.zig) sequences rows, ticks and the ProTracker effect set as one tagged union; period table built at comptime. Voices go to the shared mixer. Both halves host-tested. Four strips, each repainted only on change; the pattern is shown a page at a time. Uses the toolkit's open dialog. Works without a sound service. |
| Hero | [`apps/hero/`](../apps/hero/) | D&D 2024 character journal. Opens `.hero` files; rolls, damage, rests, spells, gold, notes. Model host-tested by `zig build test-hero`, which `make hero` runs first. `hero --version`. |
| web | [`apps/web/`](../apps/web/) | **Experimental.** Browser: [`fetch.zig`](../apps/web/fetch.zig) (HTTP and HTTPS, kept-alive connections), lexbor (markup and selectors), [`css.zig`](../apps/web/css.zig) (cascade), [`extract.zig`](../apps/web/extract.zig) (tree to page), [`layout.zig`](../apps/web/layout.zig), QuickJS behind [`dom.zig`](../apps/web/dom.zig), [`pictures.zig`](../apps/web/pictures.zig). One column: visibility, colours, text direction, box spacing, flex and grid rows, positioned boxes. GET and POST forms. Pictures fetched three at a time and cached. Scripts run under memory, depth and time bounds, with their own connections. `web -t <address>` prints a page's text. Tests: `zig build test-web`, `zig build test-dom`. |
| echat | [`apps/echat/`](../apps/echat/) | IRC client. Engine: IRCv3 tags, stream framing, `RPL_ISUPPORT`, CAP 302 including multi-line and post-registration capabilities, SASL `PLAIN` and `EXTERNAL`, nick retries, keepalive, registration timeout. No sockets or allocation, so it is host-tested against `third_party/irc-parser-tests` (transcribed by `make irctests`). Window: network rail with rooms and counts, grouped transcript, member list, input line. `/server /join /part /nick /topic /me /msg /quit`. Up to four networks. Verified on a real network. Config in `/cfg/echat.cfg`. TLS through `ulib.tls` and `/share/ca.store` (`make castore`) is written and does not work; plaintext on 6667 until it does. |

## Shared between kernel and userspace

[`src/lib/`](../src/lib/) is compiled into both and imports nothing else, enforced on
every build. Code used by one driver only stays with that driver, for example
[`user/netd/ar5212/family.zig`](../src/user/netd/ar5212/family.zig).

| Module | Purpose |
|---|---|
| [`syscalls.zig`](../src/lib/syscalls.zig) | The ABI as data: numbers, flags, wire formats. Generates the dispatcher binding and [`syscalls.md`](syscalls.md). |
| [`ring.zig`](../src/lib/ring.zig) | SPSC ring layout, and a segment carrying one ring each way. Host-tested. |
| [`civil.zig`](../src/lib/civil.zig) | Calendar arithmetic. |
| [`mmio.zig`](../src/lib/mmio.zig) | Register windows: an enum names offsets, instantiation proves each offset aligned for the access width. Port windows take each access's width from the value's type. |
| [`audio.zig`](../src/lib/audio.zig) | Frames, periods, durations, integer volume scaling, clipping mix, fixed-point sine. A voice mixer: 8-bit signed or unsigned and 16-bit samples, loops, start offsets, pitch bend, linear interpolation. Period progress from a hardware position. A resampler between rates with exact integer steps. Host-tested; the resampler is fuzzed. |
| [`text.zig`](../src/lib/text.zig) | Editable text: line index, cursor, insert and delete, UTF-8 safe, remembered column. Shared with the pager. Host-tested. |
| [`usb.zig`](../src/lib/usb.zig) | Request types, descriptor parsing, configuration walk, pipes with data toggle, driver signatures. Host-tested. |
| [`ehci.zig`](../src/lib/ehci.zig), [`uhci.zig`](../src/lib/uhci.zig), [`ohci.zig`](../src/lib/ohci.zig) | Host controller shapes the kernel's boot handover and `usbd` share: EHCI capability parameters and legacy support capability, the UHCI legacy support register, and the OHCI registers and descriptors. Host-tested. |
| [`scsi.zig`](../src/lib/scsi.zig) | Bulk-only transport wrappers and the SCSI commands a disk needs. Host-tested. |
| [`hid.zig`](../src/lib/hid.zig) | Boot-protocol keyboard and mouse reports, usage-to-key table built at comptime, report differencing. Host-tested. |
| [`pci.zig`](../src/lib/pci.zig) | Device identity and capability shapes: link power states, maximum payload per direction. Host-tested. |
| [`serial.zig`](../src/lib/serial.zig) | Line settings (rate, bits, parity, stop bits), control lines, the seven status signals, in RS-232 numbering. Parses and prints `115200 8N1`. Host-tested. |
| [`volume.zig`](../src/lib/volume.zig) | Kernel and userspace disk-driver protocol: requests, statuses, shared area layout. Host-tested. |
| [`audiograph.zig`](../src/lib/audiograph.zig) | Routing graph: nodes, ports, links, defaults. Host-tested. |
| [`wifi.zig`](../src/lib/wifi.zig) | Band, channel and frequency, width, security, SSID, signal, legacy rate or MCS index. Covers 802.11b, g and n. |
| [`ieee80211.zig`](../src/lib/ieee80211.zig) | Frame control, addressing rules, QoS and HT control, LLC/SNAP to Ethernet, beacon fields, information elements, RSN element. |
| [`mlme.zig`](../src/lib/mlme.zig) | Open-system authentication, association, probe request, deauthentication and disassociation, and a scanned network's record from a beacon. Fuzzed. |
| [`wpa2.zig`](../src/lib/wpa2.zig) | WPA2-PSK: PMK from passphrase, PTK from nonces, key MIC, group key unwrap, four-way handshake. Each checked against the standard's vectors. Data frames use the library's AES-CCM with 802.11 parameters. |
| [`join.zig`](../src/lib/join.zig) | Joining as a state value: frames in, next action out. Host-tested without a radio. |
| [`rates.zig`](../src/lib/rates.zig) | Rate selection by smoothed per-rate delivery probability weighted by airtime, with periodic sampling. |
| [`entropy.zig`](../src/lib/entropy.zig) | Interrupt timing ring and hashing pool. Draws return a hash and a readiness flag, never the pool. |
| [`escapes.zig`](../src/lib/escapes.zig) | Terminal escape-sequence parser, shared by the console and eTerm. |
| [`style.zig`](../src/lib/style.zig) | Output colour roles shared by console and GUI. |
| [`driver.zig`](../src/lib/driver.zig) | Driver confidence and binding state for the boot table and `devices`. |
| [`elf.zig`](../src/lib/elf.zig) | ELF32 identification, header, program headers and notes, read from untrusted bytes with checked arithmetic. `FixedNote` lays out a note for export and finds it again. Used by the loader's plan, `file`, `icon` and the launcher. Host-tested; the note walk is fuzzed. |
| [`processor.zig`](../src/lib/processor.zig) | The processors an image can be compiled for: compiler model, added extensions, QEMU model, menu text. Host-tested. |
| [`stanzas.zig`](../src/lib/stanzas.zig) | `key = value` record files: `etc/services`, `etc/openers`, driver manifests. Records split so that laid end to end they are the file. Host-tested. |
| [`kind.zig`](../src/lib/kind.zig) | File kind from name (`fromName`), from bytes (`fromBytes`), or both (`of`), with a family per kind. Used by `file`, the file manager and the launcher. Host-tested. |
| [`openers.zig`](../src/lib/openers.zig) | Which program opens which file family. Programs declare themselves in `/etc/openers`; `open.cfg` holds the user's choice, falling back if the chosen program is gone. Host-tested. |
| [`calc.zig`](../src/lib/calc.zig) | Calculator: immediate execution, six-place fixed point, keys as a state machine. Host-tested. |
| [`fuzzing.zig`](../src/lib/fuzzing.zig) | Choice source for fuzz targets: the fuzzer's `Smith`, or a seeded generator. Test-only. |
| [`str.zig`](../src/lib/str.zig) | Strings and number formatting. |
| [`logo.zig`](../src/lib/logo.zig) | The wordmark, drawn by the kernel and `eeefetch`. |

## Testing

- `make test`: host-side tests for everything that runs without hardware, including the
  optional applications' models, plus the QR encoder compared against `libqrencode`
  across all eight masks.
- `zig build check`: layering rules, unused imports, and the host tests compiled for
  x86-64 Linux as well as the build machine.
- Pure logic is kept in files with no I/O so it can be tested directly: page-table
  walk, program-image plan, FAT long-name assembly, volume check decisions, volume
  geometry, receive-page walk, PRO/100 rings, 82540 rings, RTL8139 receive ring, OHCI
  endpoint queue, EHCI transfer accounting, netd's line serving.
- A new test file runs only if `src/tests.zig`, `src/quirks/tests.zig` or the test
  block in `lib.zig` names it; a re-export is not enough. Confirm by making one of its
  tests fail.
- `probe` checks kernel boundaries from Ring 3: null and unmapped pointers, kernel
  addresses, wrapping lengths, buffers crossing a page end, read-only pages as write
  targets, stray handles, misaligned messages, reserved service names, read-only
  events, crafted program images, a keyboard held by another program. It then passes
  handles over a channel repeatedly and checks for leaked references.
- `make fuzz` drives fuzz targets. It does not work on Zig 0.16.0: the compiler's test
  runner fails to build in fuzz mode. Each target has a seeded counterpart in
  `make test`, driven through [`lib/fuzzing.zig`](../src/lib/fuzzing.zig). Targets
  build a plausible input and choose damage in the format's own terms:
  - Volume, [`fat/check.zig`](../src/kernel/fat/check.zig): mount, check, and a second
    check finds nothing.
  - Boot sector, same file: fields pushed past their checks.
  - Program image, [`elf/plan.zig`](../src/kernel/elf/plan.zig): every accepted plan
    satisfies what the loader assumes.
  - Note segment, [`lib/elf.zig`](../src/lib/elf.zig): the walk ends, and every owner
    and description lies inside the segment.
  - Receive page, [`netd/rxpage.zig`](../src/user/netd/rxpage.zig): the walk advances or
    stops; frames lie inside the page.
  - Management frame, [`lib/mlme.zig`](../src/lib/mlme.zig): parsers are total and
    deterministic.
  - Manifest line, [`lib/driver.zig`](../src/lib/driver.zig): read back as exactly the
    devices it was written for.
  - Link reading, [`netd/mii.zig`](../src/user/netd/mii.zig): ends within the registers
    it may ask, whatever the PHY answers.
  - PRO/100 rings, [`netd/e100/rings.zig`](../src/user/netd/e100/rings.zig): against a
    model of the part stepping at every barrier, each frame is taken and each block run
    once and in order.
  - PRO/100 EEPROM, [`netd/e100/regs.zig`](../src/user/netd/e100/regs.zig): read exactly
    at either size; a glitching line still ends every read.
  - Resampler, [`lib/audio.zig`](../src/lib/audio.zig): a stream gives the same output
    however it is cut into periods.
  - OHCI endpoint queue, [`usbd/ohci/queue.zig`](../src/user/usbd/ohci/queue.zig): the
    controller model only ever processes what the host has finished writing, and each
    transfer settles to what the model made of it.
  - 82540 rings, [`netd/e1000/rings.zig`](../src/user/netd/e1000/rings.zig): against a
    model of the part stepping at every barrier and register write, the part is given
    only cleared descriptors and sends only filled ones; each frame is taken and each
    send made once and in order.
  - RTL8139 receive ring, [`netd/rtl8139/ring.zig`](../src/user/netd/rtl8139/ring.zig):
    against a model of the chip stepping at every barrier and register access, each
    record is taken once and in order with the bytes written, never before CBR passed
    it; CAPR moves only to the end of a record taken.
  - EHCI transfer accounting, [`usbd/ehci/transfer.zig`](../src/user/usbd/ehci/transfer.zig):
    against a model of the controller stepping at every barrier, a chain is counted only
    once finished without a failure, at what the controller moved and never more than
    was asked.
  - Page table, [`arch/x86/pagetable.zig`](../src/arch/x86/pagetable.zig): agrees with a
    walk without shortcuts.
- `make check-all` is the gate. It runs `zig fmt` check, `zig build check`,
  `make test`, the browser document tests, builds both images, checks the volumes'
  contents, then boots the development image headless for each step:
  1. First boot reports done; `probe` passes and leaks nothing; services are up; no panic
     or watchdog; a setting is written.
  2. Second boot reads the setting back; a service stops on request.
  3. Power cut: a volume written then killed is found dirty, checked, keeps its data, and
     is clean on the following boot.
  4. The image on a larger card: `/home` grows into it, keeps its data and checks clean;
     another volume is formatted and checks clean.
  5. Network: DHCP lease and echo on every emulated adapter.
  6. Sound: a tone through the AudioPCI is recorded at its pitch.
  7. USB serial adapter: enumerates, takes settings, carries typed data.
  8. Serial console: the log reaches the port, including lines written after it opened.
  9. Hub and bus rebuild: a disk behind a hub keeps its mount across `usb rebuild`, and
     a disk and keyboard on an OHCI controller are read, written and typed on across it.
  10. Suspend and resume: display, keyboard, disk and network work after waking.
  11. Card reader boot: the volumes arrive through USB.
- Boot self-tests: heap, syscall ABI, clock advance, IPC. Failures print `fail` in the
  boot log rather than hanging.
- `make shot OUT=x.png TYPE="..."` boots headless, types at the shell, and writes a
  screenshot and a serial transcript. `PAUSE` sets the wait after each line.

## The boot log

- `verbose` shows one line per component and service as it starts. `debug` adds a
  lower tier and is the only kind of line not recorded unless requested.
- A quiet boot shows failures and warnings. Everything is in the ring behind `log`,
  which filters by substring and tails with `-n`.
- Once the shell owns the console, other output goes to the ring only. The claim ends
  with its owner, so shutdown messages reach the screen.

## The bring-up model

- A service registers its name only when ready to answer. `platd` registers
  `/svc/platform` once firmware is settled.
- Names order the boot, not time. `needs` lists the services a service calls; `provides`
  is the name init waits for before starting dependants. `netd` needs `platd`, so the
  network adapter starts after firmware boot activity without a timed delay.
- `target` groups services. Boot services belong to `boot`; services in no target start
  after targets settle.
- Boot-line tokens: `no.<name>` holds a service down for one boot; `late.<name>` starts
  it late under the watchdog. Short forms: `nonet`, `nohw`, `netlate`.

## Milestones

Against [design §15](../design/00-vibeee.md).

### M0: complete

Boot chain, kernel entry, PMM, paging, heap, IDT, LAPIC and IOAPIC, timers, scheduler,
syscalls, Ring 3, IPC, ramfs, VESA console, i8042 keyboard, `vsh`. Exercised every boot.

### M1: complete

| Item | State |
|---|---|
| PATA + FAT32 | Read and write. |
| `init`, `devmgd` | Manifests, dependency order, readiness, restart policy, orphan reaping; drivers bound from manifests. |
| libc | Builds and runs POSIX programs that draw their own pixels. See [eeelibc](#eeelibc). |
| Multicall utilities | Done. |
| Touchpad | Relative mode only. |
| GMA900 native modeset | Verified on the machine. The 701 boots from the SD slot. |
| `eeewm` + `libeui` | Done. |
| eTerm | Done. |
| Keymaps | US-International and Belgian AZERTY, set in Settings or cycled with `Super+Space`, remembered. |

### M2: complete

| Item | State |
|---|---|
| `usbd` | EHCI, UHCI and OHCI, mass storage, keyboards, mice, hubs. Verified on the machine: a stick enumerates, mounts under `/media`, unmounts on removal. |
| `platd` | uACPI, EC, battery, backlight, switchable parts, routing. Battery percent mislabel corrected by the quirk registry; `_BIF` read once per session. Hotkey decoding is written; notifications are gated off on the 701 (see [Platform service](#platform-service)). |
| `sndd` | Routing graph over AC'97, HDA and the Ensoniq AudioPCI. HDA verified by ear on the 701. |
| `netd` | Wired networking with lwIP, DHCP, DNS, and SNTP (`timed`). Verified on the machine: lease, gateway and internet reachable. `nc`, `resolve`, `ping`; 127.0.0.1 without hardware. |
| Pad, Monitor, Settings | Done. |

### M3: in progress

| Item | State |
|---|---|
| Wi-Fi | Scans, joins a WPA2 network and takes a DHCP lease on the machine. Traffic not confirmed. |
| Suspend to memory | Verified in the emulator. Not run on the 701. |
| Install to SSD | Not started. Prerequisites done: `format`, `grow`, volume check. |
| A/B updater | Not started. |
| UVC webcam | Not started. |
| Turbo mode | Not started. |
| Mines, Draw | Not started. |

### Not on the roadmap, done

| Item | State |
|---|---|
| Persistent settings and home | The boot medium carries the system, `/cfg` and `/home`. Settings read from `/etc` then `/cfg`. The loader records the medium's partition signature so the right disk is used. On the 701, `/cfg` and `/home` mount when `usbd` brings up the card reader. Verified in the emulator across shutdowns and reboots. |
| Volume check, format, grow | Clean-unmount flag, check at mount, `check`, `format`, `grow`. Verified in the emulator by the gate. |
| Fuzz targets | Fifteen targets with seeded counterparts in `make test`. See [Testing](#testing). |
| Bus rebuild | A disk behind a hub keeps its mount across `usb rebuild`. Verified in the emulator. |
| Serial console | The log reaches a USB serial port. Verified in the emulator; not tried on the machine. |
| Serial adapters | FTDI verified in the emulator: enumeration, `ser`, typed data both ways, settings, unplug. `acm` not run against a device. |
| Eee PC 1000 wired port | `atl1e` written, not run. Shared Attansic code tested on the build machine. |
| Boot line editing | Loader waits two seconds for a key to edit the command line. Verified in the emulator. |
| Files, Viewer, Calc | Done. |
| Floating windows, file search | Done. |

## Known gaps

- `/etc` and `/tmp` are in the root image, which is rebuilt from the boot medium every
  boot. `/home` persists.
- **Power off does not cut power.** It stops services, flushes, runs `_PTS` and writes
  the sleep state; the panel goes dark but the power LED stays on. What the 701 needs
  after `_S5_` is not known.
- The pointing device is relative only: no tap zones, edge scrolling or gestures.
  Wheel decoding is unverified; QEMU's monitor cannot send scroll events.
- **Suspend has not run on the 701.** The gen3 driver does not save and restore the
  panel power delays and watermarks, so a wake may mistime the panel.
- **Growing a volume is not power-safe.** A power cut while `grow` moves data leaves
  the volume unreadable.
- Full or low speed devices behind a hub on the EHCI controller need split
  transactions. The arithmetic is written and untested: the emulator does not put a
  full speed hub on EHCI, and the 701's own hubs are on the companions.
- A serial port has one pending read: one packet on the companions, eight on EHCI. A
  device that outruns the service loses data; the ring flags the loss and `ser` prints
  it.
- `acm` has not run against a device. Its descriptor parsing is host-tested.
- The serial console starts when `usbd` finds the adapter. A boot that fails earlier
  sends nothing to the port.
- A serial break is held by the device where the class supports a timed break, and
  refused otherwise.
- `atl1e` has not run against hardware. It does not use checksum or segmentation
  offload, uses one of four receive queues, and uses the link's negotiated burst size.
- **TLS does not work.** `ulib.tls` wraps `std.crypto.tls.Client` with the CA store; the
  transport, store, randomness and buffers are verified, and the handshake reaches
  certificate name comparison. Two standard library limits block it: no response to
  `certificate_request` (Libera.Chat and OFTC send one), and a fault in `Client.init`
  on a chain that verifies. `echat` uses plaintext on 6667.
- **Wi-Fi does not carry traffic.**
  - Confirmed on the machine: `net wifi scan` lists networks; the station
    authenticates, associates, completes the key exchange and takes a DHCP lease.
  - Not confirmed: a ping to the gateway gets no reply, and the bar's network icon
    stays dim while `net` shows an address.
  - 802.11w is not implemented, so a forged deauthentication or disassociation ends
    the association.
  - The radio must be powered before it appears on the bus. `hw wireless on` powers it
    through the vendor method and rescans; `netd` does the same at start when
    configured.
  - Diagnostics: the station reports the step it failed at, the last step answered and
    the reason code; counts frames heard, frames addressed to it and authentication
    frames. The radio reports its queue, registers, pending descriptor, and drops by
    cause.
  - Host tests cover the join state machine, frame construction, key derivation, rate
    selection and replay protection, but the access point in those tests is this same
    code. Captured frame fixtures and a fake radio are not written.
- **The browser is experimental** and not part of the image. Known missing:
  - `getBoundingClientRect` returns zeros: layout runs after scripts.
  - `IntersectionObserver` and similar never fire.
  - Ordinary blocks ignore a stated width; `margin: 0 auto` does not centre.
  - Line breaks follow the element's tag, not its computed `display`.
  - No CJK glyphs: the system font covers Latin, Greek and Cyrillic.
  - Scripts are slow: about 25 s for a search results page on the 701, against about
    2.5 s on a desktop.
  - Stylesheets are fetched one at a time.

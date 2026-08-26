# Status

What exists, file by file. Kept plain on purpose: the design documents say what the system
is *for*, this says what has actually been written.

**Mostly vibecoded.** See the note in the [README](../README.md). The inventory below is
accurate about what exists; it is not a claim that any of it has been audited.

Last updated 2026-08-26. Roughly 16,400 lines of Zig and 870 of assembly, 35 syscalls,
36 host-side tests.

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
| Syscalls | [`syscall.zig`](../src/kernel/syscall.zig) + [`syscall/`](../src/kernel/syscall/) | 35 calls, bound to the table at comptime in both directions. |
| Timekeeping | [`clock.zig`](../src/kernel/clock.zig) | Monotonic + wall clock as offset plus uptime. |
| Shutdown | [`shutdown.zig`](../src/kernel/shutdown.zig) | Flush, unmount, ACPI off. |
| Panic | [`panic.zig`](../src/kernel/panic.zig), [`qr.zig`](../src/kernel/qr.zig) | QR-encoded crash dump, verified against libqrencode. |

## Storage

| Component | File | State |
|---|---|---|
| Block layer | [`block.zig`](../src/kernel/block.zig) | Device registry, MBR partition parsing. |
| Block cache | [`bcache.zig`](../src/kernel/bcache.zig) | Read cache with hit reporting. |
| FAT | [`fat.zig`](../src/kernel/fat.zig), [`fat/alloc.zig`](../src/kernel/fat/alloc.zig) | FAT12/16/32, VFAT long names, timestamps. Read and write: cluster allocation across all FAT copies, chain extension, create, append, truncate, unlink. Creating uses 8.3 names only. |
| Mount table | [`vfs.zig`](../src/kernel/vfs.zig) | Longest-prefix resolution, open-file counting, read-only enforcement. Every write goes through here. |
| ATA | [`drv/block/ata.zig`](../src/drv/block/ata.zig) | PIO. No DMA. |
| Ramdisk | [`drv/block/ramdisk.zig`](../src/drv/block/ramdisk.zig) | Backs the boot-to-RAM rootfs. |

## Drivers

| Driver | File | State |
|---|---|---|
| PCI | [`drv/bus/pci.zig`](../src/drv/bus/pci.zig) | Enumeration, config space. |
| VGA text | [`drv/video/vgatext.zig`](../src/drv/video/vgatext.zig) | Done. |
| Framebuffer console | [`drv/video/fbcon.zig`](../src/drv/video/fbcon.zig) | 32bpp, Spleen font, pixel rectangles for the panic QR. |
| i8042 | [`drv/input/i8042.zig`](../src/drv/input/i8042.zig) | Keyboard, scancode set 1. Owns the controller; the second port is below. |
| PS/2 pointer | [`drv/input/ps2mouse.zig`](../src/drv/input/ps2mouse.zig) | Three buttons, motion, drag. IntelliMouse wheel negotiated and decoded but not verified against hardware. Synaptics and Elantech identified, both driven in relative mode. |
| CMOS RTC | [`drv/rtc/cmos.zig`](../src/drv/rtc/cmos.zig) | Read at boot to seed the clock. |
| ACPI tables | [`drv/acpi/tables.zig`](../src/drv/acpi/tables.zig) | RSDP/RSDT/FADT, `_S5_` pattern match. No AML interpreter. |
| ACPI power | [`drv/acpi/power.zig`](../src/drv/acpi/power.zig) | Power off, reset. |
| SMBIOS | [`drv/platform/smbios.zig`](../src/drv/platform/smbios.zig) | DMI decoding for `dmidecode` and `eeefetch`. |
| UART 16550 | [`drv/serial/uart16550.zig`](../src/drv/serial/uart16550.zig) | For machines that have one; the 701 does not. |

Probed but **not implemented**, the table reports them so an unfamiliar machine is
diagnosable: `gma900`, `vesafb` (probe only), `ehci`, `uhci`, `hda`, `atl2`, `ath5k`,
`e1000`, `i801smb`, `lpc_ich`.

## Graphics and the GUI

| Component | File | State |
|---|---|---|
| Display owner | [`display.zig`](../src/kernel/display.zig) | Exclusive ownership, scanout buffer handed over as a shared segment. One buffer, no page flip or vblank, which is what a VESA framebuffer offers. |
| Window manager | [`user/eeewm/`](../src/user/eeewm/) | Display server and tiling manager. Dynamic desktops, taskbar of named tabs with per-tab window menus, `V` launcher with session actions, tall/wide/monocle per desktop, floating windows, focus-follows-click, config file. Bindings by keycode; every action reachable by pointer and keyboard. |
| Window protocol | [`user/proto/`](../src/user/proto/) | Channel for control, shm ring for events, shm surface per window. Wire types and the client half; the server half is policy and lives with the manager. `FileDialog` puts `eui`'s chooser panel in a floating window, which is here rather than in the toolkit because opening one means talking to the manager. |
| Control library | [`user/eui/`](../src/user/eui/) | Surface and primitives, swappable theme, buttons, toggles, checkboxes, labels, progress bars, menus, a scrolling table with columns and a tree column, an editable soft-wrapped text area and one-line field, a menu bar with dropdowns and shortcut hints, draggable scrollbars, a file chooser panel, keyboard focus with Tab order, per-widget damage. |
| Fonts | [`lib/font.zig`](../src/lib/font.zig) | Shared by kernel and userspace. Spleen 8x16 and 12x24 monospaced for the console, Ark Pixel 12 proportional for interface text. Subset covers Latin-1, punctuation, arrows, box drawing, blocks and shapes; the range table is shared with the generator so slots cannot disagree. |

## Userspace

| Program | File | State |
|---|---|---|
| `init` | [`user/init.zig`](../src/user/init.zig) | PID 1. Manifest parsing, dependency order, restart policy, orphan reaping. |
| `vsh` | [`user/vsh.zig`](../src/user/vsh.zig) | Builtins, program lookup, multicall dispatch, `>` and `>>` redirection. No pipes. |
| Tools | [`user/tools/`](../src/user/tools/) | `ls cat rm hexdump grep free top kill disk svc date eeefetch dmidecode pointer ringtest` |
| `hello` | [`user/hello.zig`](../src/user/hello.zig) | Loader, `.bss`, sleep and IPC checks from Ring 3. |
| Shared code | [`user/lib/`](../src/user/lib/) | Buffered output, strings, time formatting, sysinfo, the process table. |
| Directory listing | [`user/lib/dir.zig`](../src/user/lib/dir.zig) | One decoded listing, parent first, then directories, then names written the way they should be read. |
| Pipes | [`kernel/pipe.zig`](../src/kernel/pipe.zig) | Byte stream with a reader and writer count, waitable by `wait_many`. Bound to a child's standard streams at spawn. |

## Applications

Built in the order of [design §10.8](../design/00-vibeee.md): each needs only what the one
before it forced into place.

| Program | File | State |
|---|---|---|
| Settings | [`user/apps/settings.zig`](../src/user/apps/settings.zig) | Theme, bar position and layout. Reads and writes `/etc/eeewm.cfg`; the theme applies live. |
| Monitor | [`user/apps/monitor.zig`](../src/user/apps/monitor.zig) | Process tree with per-process CPU share, memory and uptime, refreshed twice a second. Ends a selected process. |
| Pad | [`user/apps/pad.zig`](../src/user/apps/pad.zig) | Text editor: soft-wrapped editing in the interface face, a File menu, open and save through the floating file dialog, live byte count. |
| eTerm | [`user/eterm/`](../src/user/eterm/) | Terminal window running `vsh` over a pipe pair. Extended VT100 per [design §16](../design/10-gui.md): cursor movement, erase, insert and delete, scrolling regions, alternate screen, SGR with 256 colours, DECCKM, OSC titles. Line editing is the terminal's, until `vsh` does its own. |

## Shared between kernel and userspace

[`src/lib/`](../src/lib/) is compiled into both. It imports nothing else, enforced on every
build.

| Module | Purpose |
|---|---|
| [`syscalls.zig`](../src/lib/syscalls.zig) | The ABI as data: numbers, flags, wire formats. Generates the dispatcher binding and [`syscalls.md`](syscalls.md). |
| [`ring.zig`](../src/lib/ring.zig) | SPSC shared-memory ring layout. |
| [`civil.zig`](../src/lib/civil.zig) | Calendar arithmetic. |
| [`logo.zig`](../src/lib/logo.zig) | The wordmark, drawn by the kernel and by `eeefetch`. |

## Testing

- `make test`: 36 host-side unit tests (bootinfo layout, keymap tables, QR encoder, run
  queues, calendar, ring buffer) plus a differential check of the QR encoder against
  `libqrencode` across all eight masks.
- `zig build check`, the layering rules.
- Boot self-tests, heap, syscall ABI, clock advance, IPC. Each reports `fail` on the boot
  log rather than hanging, because the target has no serial port.
- `make shot OUT=x.png TYPE="..."`, boot headless, type at the shell, screenshot, and a full serial transcript beside it.

## Known gaps

- Creating a file uses an 8.3 short name; long names are read but not written.
- No `mkdir`: directories cannot be created, only read.
- The dispatcher is `int 0x80`; SYSENTER is designed but not wired.
- Interrupt handling uses the 8259 PICs and the PIT, not the IOAPIC/LAPIC the design calls for.
- The pointing device runs in relative mode: no tap zones, edge scrolling or multi-finger gestures.
- Wheel decoding is untested; QEMU's monitor cannot generate scroll events.
- No USB, audio or networking.

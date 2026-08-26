# Status

What exists, file by file. Kept plain on purpose: the design documents say what the system
is *for*, this says what has actually been written.

**Mostly vibecoded** — see the note in the [README](../README.md). The inventory below is
accurate about what exists; it is not a claim that any of it has been audited.

Last updated 2026-08-26. Roughly 15,900 lines of Zig and 870 of assembly, 28 syscalls,
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
| Shared rings | [`lib/ring.zig`](../src/lib/ring.zig) | Layout and arithmetic done and tested. **Not yet mapped between address spaces.** |
| Handles | [`handle.zig`](../src/kernel/handle.zig) | Per-process table, rights bits, console/file/directory/event/channel. |
| ELF loading | [`elf.zig`](../src/kernel/elf.zig), [`exec.zig`](../src/kernel/exec.zig) | Static ELF32, sync and detached spawn. |
| Syscalls | [`syscall.zig`](../src/kernel/syscall.zig) + [`syscall/`](../src/kernel/syscall/) | 28 calls, bound to the table at comptime in both directions. |
| Timekeeping | [`clock.zig`](../src/kernel/clock.zig) | Monotonic + wall clock as offset plus uptime. |
| Shutdown | [`shutdown.zig`](../src/kernel/shutdown.zig) | Flush, unmount, ACPI off. |
| Panic | [`panic.zig`](../src/kernel/panic.zig), [`qr.zig`](../src/kernel/qr.zig) | QR-encoded crash dump, verified against libqrencode. |

## Storage

| Component | File | State |
|---|---|---|
| Block layer | [`block.zig`](../src/kernel/block.zig) | Device registry, MBR partition parsing. |
| Block cache | [`bcache.zig`](../src/kernel/bcache.zig) | Read cache with hit reporting. |
| FAT | [`fat.zig`](../src/kernel/fat.zig) | FAT12/16/32, VFAT long names, timestamps. **Read-only.** |
| Mount table | [`vfs.zig`](../src/kernel/vfs.zig) | Longest-prefix resolution, open-file counting. |
| ATA | [`drv/block/ata.zig`](../src/drv/block/ata.zig) | PIO. No DMA. |
| Ramdisk | [`drv/block/ramdisk.zig`](../src/drv/block/ramdisk.zig) | Backs the boot-to-RAM rootfs. |

## Drivers

| Driver | File | State |
|---|---|---|
| PCI | [`drv/bus/pci.zig`](../src/drv/bus/pci.zig) | Enumeration, config space. |
| VGA text | [`drv/video/vgatext.zig`](../src/drv/video/vgatext.zig) | Done. |
| Framebuffer console | [`drv/video/fbcon.zig`](../src/drv/video/fbcon.zig) | 32bpp, Spleen font, pixel rectangles for the panic QR. |
| i8042 | [`drv/input/i8042.zig`](../src/drv/input/i8042.zig) | Keyboard only; touchpad not started. |
| CMOS RTC | [`drv/rtc/cmos.zig`](../src/drv/rtc/cmos.zig) | Read at boot to seed the clock. |
| ACPI tables | [`drv/acpi/tables.zig`](../src/drv/acpi/tables.zig) | RSDP/RSDT/FADT, `_S5_` pattern match. No AML interpreter. |
| ACPI power | [`drv/acpi/power.zig`](../src/drv/acpi/power.zig) | Power off, reset. |
| SMBIOS | [`drv/platform/smbios.zig`](../src/drv/platform/smbios.zig) | DMI decoding for `dmidecode` and `eeefetch`. |
| UART 16550 | [`drv/serial/uart16550.zig`](../src/drv/serial/uart16550.zig) | For machines that have one; the 701 does not. |

Probed but **not implemented** — the table reports them so an unfamiliar machine is
diagnosable: `gma900`, `vesafb` (probe only), `ehci`, `uhci`, `hda`, `atl2`, `ath5k`,
`e1000`, `i801smb`, `lpc_ich`.

## Userspace

| Program | File | State |
|---|---|---|
| `init` | [`user/init.zig`](../src/user/init.zig) | PID 1. Manifest parsing, dependency order, restart policy, orphan reaping. |
| `vsh` | [`user/vsh.zig`](../src/user/vsh.zig) | Builtins, program lookup, multicall dispatch. No pipes or redirection. |
| Tools | [`user/tools/`](../src/user/tools/) | `ls cat hexdump grep free top disk svc date eeefetch dmidecode` |
| `hello` | [`user/hello.zig`](../src/user/hello.zig) | Loader, `.bss`, sleep and IPC checks from Ring 3. |
| Shared code | [`user/lib/`](../src/user/lib/) | Buffered output, strings, time formatting, sysinfo. |

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

- `make test` — 36 host-side unit tests (bootinfo layout, keymap tables, QR encoder, run
  queues, calendar, ring buffer) plus a differential check of the QR encoder against
  `libqrencode` across all eight masks.
- `zig build check` — the layering rules.
- Boot self-tests — heap, syscall ABI, clock advance, IPC. Each reports `fail` on the boot
  log rather than hanging, because the target has no serial port.
- `make shot OUT=x.png TYPE="..."` — boot headless, type at the shell, screenshot.

## Known gaps

- FAT is read-only; nothing can create or modify a file.
- Rings exist but cannot be shared between processes, so IPC is limited to 64-byte messages.
- Handles cannot be passed over channels.
- The dispatcher is `int 0x80`; SYSENTER is designed but not wired.
- Interrupt handling uses the 8259 PICs and the PIT, not the IOAPIC/LAPIC the design calls for.
- No touchpad, USB, audio, networking or GUI.

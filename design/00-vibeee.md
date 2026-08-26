# vibeee, master design

A from-scratch minimal graphical OS in Zig. Flagship target: **ASUS Eee PC 701 4G**. Written to be portable to similar constrained machines (other netbooks, ARM CE-era devices) by containing machine-specific code behind explicit boundaries.

**How this was built.** vibeee is vibecoded: the code and these documents were written by
Claude under the author's direction. The design decisions recorded here are real decisions
with real reasoning, and the hardware research is verified against primary sources, but
nothing here has been audited by a human line by line.

**Implementation status.** This document is the design. What exists today is the M0 set plus part
of M1, boot chain, memory, interrupts, the O(1) scheduler, syscalls, Ring 3 with per-process
address spaces and an ELF loader, IPC (channels, events, `/svc`), ATA and FAT behind a mount
table, the framebuffer console, the i8042 keyboard with switchable layouts, timekeeping, ACPI
shutdown, and a shell with a set of system tools, listed precisely in [`../README.md`](../README.md). Everything else here is unbuilt.
Subsystem documents `01`–`11` carry their own status headers.

Companion docs: [`01-boot.md`](01-boot.md) … [`11-userspace.md`](11-userspace.md) hold the
per-subsystem detail; this document is authoritative where they differ, since it carries later
decisions. Hardware ground truth: [`../docs/research/`](../docs/research/), three verified
reports with per-fact confidence markers. **Never contradict them; where they mark a fact
LOW confidence, probe at runtime.**

---

## 1. Goals and budgets

| Budget | Cap | Rationale |
|---|---|---|
| SD image | ≤ 48 MB | Fits any card; fast to flash and to read over the slow BIOS→USB path |
| Kernel ELF | ≤ 1.5 MB | Loaded uncompressed by stage2 |
| Uncompressed rootfs | ≤ 24 MB | Lives in RAM permanently |
| Idle RAM (GUI up) | ≤ 48 MB | Of 503 MB usable; leaves headroom for real work |
| Cold boot → GUI | ≤ 8 s | Beat the shipped Xandros |
| Compositor full-damage frame | ≤ 8 ms | 800×480×4 = 1.5 MB; memory bandwidth is the constraint |

Non-goals for v1: SMP, 64-bit, IPv6, Unicode shaping, swap, multi-user.

---

## 2. Target hardware → owner map

Every device gets an owner or an explicit exclusion. Facts from the research reports; `[C]` = confidence.

| Device | ID | Owner | Notes |
|---|---|---|---|
| Celeron M 353 Dothan | CPUID 0x06D8 | `arch/x86` | 630 MHz (9×70), **no EIST/P-states**, SSE2, no SSE3, SYSENTER, LAPIC. `[HIGH]` |
| 910GML host bridge | 8086:2590 | kernel PCI |, |
| GMA 900 IGD | 8086:2592 | `drv/video/gma900` (in-kernel) | Native LVDS modeset; **VBE has no 800×480** `[HIGH]` |
| Any VGA-class device | class 03:00 | `drv/video/vesafb` (fallback) | VBE linear framebuffer, mode set by stage2 in real mode. Works on this machine at 640×480, on QEMU, and on unknown hardware |
| IGD 2nd function | 8086:2792 | none | Not a head; ignore |
| HDA controller | 8086:2668 | `sndd` (userspace) | Codec ALC662, SSID 1043:82a1 `[HIGH]` |
| PCIe root ports | 8086:2660/2662/2664 | kernel PCI + `platd` | WiFi hot-unplug lives here |
| UHCI ×4 | 8086:2658–265b | `usbd` | Phase 2, only needed for FS/LS external devices |
| EHCI | 8086:265c | `usbd` | All internal USB devices are high-speed |
| PCI bridge | 8086:2448 | kernel PCI | Nothing behind it |
| LPC bridge | 8086:2641 | `platd` | RCBA at cfg 0xF0 → HPET force-enable |
| IDE (combined mode) | 8086:2653 | `drv/block/pata` (in-kernel) | **PATA on secondary: 0x170/0x376, BMDMA 0xFFA8, IRQ15** `[HIGH]` |
| SMBus | 8086:266a | `platd` (opt-in) | Only for turbo mode (PLL @ 0x69) |
| WiFi AR2425 | 168c:001c | `netd` | Reverse-engineered; power-gated by Fn+F2 `[HIGH]` |
| Ethernet Attansic L2 | 1969:2048 | `netd` | 100 Mbit `[HIGH]` |
| SSD SM223AC | PATA sec. master | `drv/block/pata` | **28-bit LBA only, no READ/WRITE MULTIPLE**, UDMA/66 `[HIGH]` |
| SD card reader | USB 0951:1606 | `usbd` → ublk | ENE UB6225, mass-storage class. **This is the boot device** |
| Webcam | USB eb1a:2761 | `usbd` (UVC) | BIOS-disabled by default + ACPI `CAMS` gate `[HIGH]` |
| Panel 800×480 LVDS | AUO A070VW04 | `drv/video/gma900` | Modeline 29.58 MHz, no EDID expected |
| Backlight |, | `platd` via ACPI `PBLS` | 16 levels `[HIGH]` |
| VGA out | ADPA 0x61100 | `drv/video/gma900` | Pipe A + DPLL_A |
| i8042 kbd + touchpad | 0x60/0x64, IRQ1/12 | `drv/input/i8042` | Touchpad **Synaptics or Elantech, probe both** `[MED]` |
| EC ENE KB3310 | 0x62/0x66 | `platd` | Fan 0x63, tach 0x66/67, temp 0x51, manual bit 0xD3.1 `[HIGH]` |
| ACPI ASUS010/ATKD |, | `platd` | Hotkeys, WLDS, CAMS, PBLS. **Never call CFVS, it hangs** `[HIGH]` |
| Battery / AC | ACPI | `platd` | **Values are percent mislabelled as mAh**, special-case `[HIGH]` |
| Bluetooth, modem, ExpressCard, SATA, serial |, | **excluded** | Not fitted `[HIGH]` |

**No serial port** is the single most important development constraint: it dictates the panic/logging design (§6.9) and makes QEMU-first mandatory.

---

## 3. Portability architecture

Portability is a *layering* requirement, not a promise to ship an ARM build. Three boundaries, enforced by directory:

```
src/
  arch/x86/        # ISA + firmware-era code: GDT/IDT/TSS, paging, SYSENTER,
                   #   PIC/APIC, PIT/HPET/TSC, port I/O, context switch asm
  arch/arm/        # (stub) MMU, GIC, generic timer, SVC, future
  board/eee701/    # THIS machine: device inventory, quirk table, DSDT
                   #   workarounds, EC map, panel modeline, GPIO meanings
  board/generic-pc/# Fallback board: VESA + PS/2 + PATA + ACPI only
  kernel/          # Portable: mm, sched, ipc, vfs, handles, driver registry
  drv/             # Drivers; each declares which arch/bus it needs
  lib/             # Pure computation, compiled into BOTH kernel and userspace
  user/            # The shell and system tools, as ordinary ELF programs
  svc/  app/       # Userspace servers and applications, portable by construction
```

Rules:
1. **`kernel/` must never `@import` from `arch/`.** It imports one module, `hal`, whose interface is a Zig struct of comptime-known functions. `build.zig` binds `hal` → `arch/<target>`.
2. **Everything the HAL exposes is in a single file**, `kernel/hal.zig`, so the ARM port's contract is one readable page: MMU ops, context switch, timer, IRQ controller, I/O access, CPU feature query, atomic/barrier primitives.
3. **`board/` supplies data, not code, wherever possible**, device tables, quirk flags, timings. A new machine should be mostly a new table.
4. **Endianness and word size** are parameters (`usize`, `std.mem.readInt` with explicit endianness), never assumed.
5. Port I/O (`in`/`out`) exists only on x86; drivers needing it declare `.needs = .{ .port_io = true }` and are excluded from non-x86 builds at comptime.
6. **`lib/` is shared by both sides of the privilege boundary**, so it holds nothing but pure computation, no state, no hardware, no syscalls. Calendar arithmetic lives there because the kernel needs it to stamp a FAT directory entry and `date` needs it to print one, and one leap-year rule in the system is better than two that can disagree. It is imported as a named module rather than by relative path, so kernel and userspace get the same instance and its types are the same type across a syscall.
7. **The rules are enforced, not just documented.** `tools/check-layering.zig` runs as part of every `zig build` and fails it on a violation, with the offending file, line and rule. A rule that is only written down decays: the breach stays invisible until someone attempts a port and finds the HAL was quietly bypassed a dozen times. Exceptions are listed in that file, each with its reason, so the compromises are countable. `src/platform.zig` is the composition root, the one file permitted to know about kernel core, the architecture layer and concrete drivers at once, which is what lets everything else stay strict.

A second, cheaper portability payoff: the **host backend** (§10.6) lets the GUI and most userspace compile as a normal Linux/macOS binary, which is where most iteration happens.

---

## 4. Hardware probing and driver binding

Two registries, one model.

**In-kernel drivers, compile-time registry, runtime probe.** Zig comptime builds the table; each driver exposes a `probe()` that returns confidence, so ordering is data not `#ifdef`s:

```zig
pub const DriverKind = enum { block, video, input, bus, misc };

pub const Driver = struct {
    name: []const u8,
    kind: DriverKind,
    needs: Needs,                    // port_io, mmio, dma, arch tag
    match: []const Match,            // PCI id, class, ACPI HID, or .probe_only
    probe: *const fn (*Device) ProbeResult, // .no | .weak | .strong | .exact
    attach: *const fn (*Device, Allocator) anyerror!*anyopaque,
};

pub const ProbeResult = enum(u8) { no = 0, weak = 1, strong = 2, exact = 3 };

// build.zig injects the enabled set; comptime flattens it to a static array.
pub const registry: []const Driver = @import("drv_manifest").drivers;
```

Binding order at boot: enumerate buses → for each device collect candidate drivers by `match` → call `probe()` → attach the highest `ProbeResult`, ties broken by registry order. This is what makes the same image boot on a *different* machine: GMA900 returns `.exact` on 8086:2592 and `.no` elsewhere, VESA returns `.weak` on any VGA class device, so an unknown laptop gets a working-but-dumb framebuffer instead of a black screen.

Same mechanism handles the touchpad ambiguity the research flagged: probe Synaptics `0xE8` identify (`.exact` on success) → Elantech magic knock (`.exact`) → bare PS/2 mouse (`.weak`). No build-time guess required.

**Userspace drivers, drop-in binaries.** `devmgd` matches PCI/USB IDs against manifests in `/drivers/*.manifest` and spawns the binary with the capabilities it declares:

```ini
name    = netd
binary  = /drivers/netd
match   = pci:1969:2048, pci:168c:001c
caps    = mmio, dma, irq, pci_cfg
restart = always
```

Adding a driver = copy two files, no rebuild, no reboot. That is the modularity requirement, satisfied.

**`hwprobe`**, a userspace tool and a boot-time report: dumps every enumerated device, which driver bound, at what confidence, and what was left unclaimed. On an unfamiliar machine this is the porting worksheet, and it's also the bug report you'd want when something doesn't come up.

---

## 5. Boot

Complete in [`01-boot.md`](01-boot.md). Summary of what the rest of the system depends on:

- MBR stage1 (≤440 B, NASM) → stage2 (real-mode NASM stub + 32-bit Zig, PM↔RM trampolines for BIOS calls).
- Loads kernel ELF to phys 1 MB + zstd rootfs container, CRC32-verified, A/B copies with 3-strike auto-fallback via a boot-journal sector.
- Handoff: `EAX=0x0EEEB007`, `EBX=&BootInfo` at phys 0x6000: E820, RSDP, kernel/rootfs ranges, cmdline, disk signature, and an **8 KB stage2 text-log ring** that the kernel imports into dmesg (this is how you debug early boot with no serial port).
- Image: MBR | stage2 A/B | journal | P1 FAT16 32 MB (boot+system) | P2 /cfg | P3 /data, all 4 MB-aligned for SD erase blocks. Boot Booster's 0xEF partition is preserved, never used.
- **Boot-to-RAM is load-bearing**: the SD card is behind the BIOS's USB emulation, so once we leave real mode we cannot read it again until `usbd` is up. Everything needed to reach a shell must be in RAM before then.

**Addition for portability:** accept a **Multiboot2** header as an alternate entry point. Costs ~150 lines, and buys `qemu -kernel vibeee.elf` (skipping the whole boot chain) plus GRUB-booting on any dev machine. The BootInfo struct is populated from either source.

---

## 6. Kernel

Hybrid: boot, mm, sched, IPC, VFS, block, video, input, platform in-kernel; USB, network, audio as restartable userspace servers. Rationale (settled earlier): the machine has no serial port, so the components you'll iterate on longest: WiFi, USB, audio, are exactly the ones worth being able to restart without rebooting.

### 6.1 Physical memory

Bitmap allocator over the E820 map. 512 MB / 4 KB = 131072 frames = **16 KB bitmap**. Find-free is `@ctz` over `u64` words. A buddy allocator is not worth its complexity here: the only multi-frame contiguous allocations are DMA buffers, which are few, early, and long-lived, served by a dedicated low-memory contiguous arena (2 MB reserved under 16 MB, sized for EHCI schedules + HDA rings + NIC rings).

### 6.2 Virtual memory

**Decision: plain 32-bit 2-level paging, not PAE.** PAE's only benefit on this machine is NX (the CPU has `nx` but it's PAE-only), we cannot use PAE for memory above 4 GB because the CPU is 32-bit-physical anyway. The costs are 8-byte PTEs (double the page-table memory), a third level of walk, and a messier ARM-portability story. NX is a hardening nicety on a single-user hobby OS; W^X at the *mapping* level (never map a page both writable and executable in the same VMA) gets most of the practical benefit for free. The HAL hides the page-table format, so switching to PAE later is a contained change.

Layout: user 0–3 GB, kernel 3–4 GB with the physical map at 0xC0000000. Kernel is mapped identically in every address space so syscalls need no CR3 switch. Guard pages on every kernel and user stack.

### 6.3 Kernel heap

Slab allocator over the PMM, exposed as a `std.mem.Allocator`, so kernel code is idiomatic Zig (`try alloc.create(Process)`). Size classes 16/32/64/128/256/512/1024/2048 B; larger goes straight to page allocation. Per-class free lists with slab headers off-page so allocations stay cache-aligned. A `std.heap.ArenaAllocator` is used for anything request-scoped (path resolution, IPC message assembly).

### 6.4 Scheduler

**O(1) scheduler.** Two runqueue arrays (active/expired), swap pointers when active empties, per-priority linked lists, bitmap to find the top priority in constant time. But:

- **32 priority levels, not 140.** One `u32` bitmap, one `@ctz`, no multi-word scan, no `bsf` inline asm needed (Zig's `@ctz` lowers to `BSF`/`TZCNT` and stays portable to ARM's `CLZ`-based equivalent). 140 levels exist in Linux to separate 100 realtime from 40 nice levels; we need maybe 4 bands: realtime (audio mixer, input), interactive (GUI, foreground app), normal, batch.
- Timeslices scale with priority (interactive 20 ms, batch 100 ms); interactivity bonus computed from sleep-vs-run ratio, clamped, integer-only, **no 64-bit division anywhere in the tick path**. This is the reason CFS is not used: its red-black tree walk and 64-bit vruntime arithmetic on every tick are a poor trade on a 630 MHz in-order core.
- Single core: no load balancing, no per-CPU runqueues, no locks in the fast path (interrupts-off is sufficient mutual exclusion).

Tick source: **LAPIC timer** in one-shot mode (tickless-ish; ~250 Hz effective under load, idle ticks suppressed). Not the PIT, the PIT costs a port I/O round-trip per read and we want it free for calibration only. Idle: `HLT` (C1) only. **C3 is deliberately not used**: the research confirms the TSC halts in C3 on this part, and the LAPIC timer stops too, which would force a fallback to slower timekeeping for a battery win we can measure later. Revisit in M4.

### 6.5 Time

Ladder, in order of preference: **HPET** (must be force-enabled ourselves, read RCBA from LPC cfg 0xF0, set bit in HPTC at RCBA+0x3404, then it decodes at 0xFED00000; the BIOS does not declare it in ACPI) → **ACPI PM timer** at I/O 0x808 (always present, 3.579545 MHz) → PIT. TSC is used only as a fast *relative* counter within a scheduling quantum, never as the monotonic clock, because it stops in idle.

**Two clocks, one of them derived.** [`kernel/clock.zig`](../src/kernel/clock.zig) exposes a monotonic clock counting microseconds since boot, and a wall clock that is *not* read from hardware on demand: it is an offset, established once, plus however long the machine has been up. Reading the CMOS RTC costs several port round trips and must be retried to avoid catching a mid-carry update, which is too much to pay per timestamp; deriving from the monotonic counter also gives microsecond resolution and guarantees that two timestamps taken in order compare in order.

Where the offset comes from is not the clock's concern. The RTC (0x70/0x71, with century handling) supplies it at boot; SNTP will supply a better one over the network later, through the same `set` call, so nothing else has to learn that the source changed. The research is right that these machines' CMOS batteries are long dead, and **a wrong clock breaks TLS**, so SNTP is a v1 requirement, not a nicety. Until something sets it, the clock reports that it does not know the time rather than claiming 1970, `realtime_us` returns `EINVAL` and `date` says so.

UTC throughout, never local time. A timezone is a display concern; applying one in the kernel would mean every holder of a timestamp had to know whether it had already been shifted. The calendar arithmetic is in [`lib/civil.zig`](../src/lib/civil.zig), shared with userspace (§3 rule 6).

### 6.6 Interrupts

x86-contained. IDT with 256 entries; 0–31 exceptions, 32+ for IRQs. **IOAPIC + LAPIC**, not the 8259s (mask and abandon the PICs after boot), honouring the MADT overrides the research captured: **ISA IRQ0→GSI2, SCI IRQ9 level/high**. Known routing: IRQ1/12 i8042, IRQ8 RTC, IRQ9 ACPI SCI, IRQ14/15 ATA, ~23 EHCI. Vector allocation is dynamic above 48.

Userspace driver IRQs: `irq_attach(gsi) → event handle`. The kernel's stub handler masks the line, signals the event, and EOIs; the userspace driver unmasks when it has serviced the device. This is what makes a crashed driver survivable, a wedged server leaves its line masked, not the machine livelocked.

### 6.7 Privilege rings and system calls

**Ring separation is non-negotiable in this design**, a buggy app must not be able to scribble on the kernel or touch hardware directly. x86 gives four rings; like every practical x86 OS we use two, because paging (not segmentation) is what actually enforces memory isolation, and page-table permissions only distinguish supervisor from user.

**Ring 0, kernel.** Boot, mm, scheduler, IPC, VFS, and the in-kernel drivers (block, video, input, platform). Full instruction set, full address space.

**Ring 3, everything else.** `init`, `devmgd`, the driver servers (`usbd`, `netd`, `sndd`), `eeewm`, and all applications. Drivers run here too, that is the whole point of the hybrid design, and reach hardware only through explicitly granted capabilities, never by privilege level.

**GDT layout** (flat, paging does the real work): null, kernel code (DPL 0), kernel data (DPL 0), user code (DPL 3), user data (DPL 3), TSS. One TSS for the machine (single core); its `esp0` is rewritten on every context switch to point at the incoming thread's kernel stack, so an interrupt taken in Ring 3 lands on a known-good stack.

**Entering Ring 3 the first time**: build a fake interrupt frame on the kernel stack (user SS/ESP, EFLAGS with IF set and IOPL 0, user CS, entry EIP) and execute `iret`. The CPU pops into user mode with the process's page directory already loaded.

**Returning to Ring 0** happens exactly three ways, and no others:

1. **`SYSENTER`**, the primary syscall path. MSRs `IA32_SYSENTER_CS` (0x174), `_ESP` (0x175), `_EIP` (0x176) are programmed once at boot; the CPU switches to Ring 0 with no memory access at all, which is why it's roughly 3× faster than `int` on this Dothan core. Since SYSENTER clobbers the user stack pointer, the userspace stub stashes `esp`/`eip` before trapping and `SYSEXIT` restores them.
2. **`int 0x80`**, the fallback path, kept because it's trivially debuggable and because it works identically on machines whose SYSENTER MSRs we can't rely on. Chosen at libc init via CPUID `sep`, so the ABI is identical either way.
3. **Interrupts and exceptions**: IDT gates with DPL 0 for hardware IRQs (user code cannot invoke them with `int`) and DPL 3 only for the syscall gate. Page faults, GPFs, and friends land in the kernel's handler, which for a user fault kills the process and reports it to `Monitor`, rather than panicking the machine.

**Syscall ABI**: `eax` = call number, args in `ebx/ecx/edx/esi/edi`, return in `eax`, errors as negative errno. The interface is defined once, as data, in `kernel/syscall_table.zig`; the dispatcher, the reference documentation ([`docs/syscalls.md`](../docs/syscalls.md)) and eventually the libc stubs are all generated from that table. Two comptime checks make the binding total in both directions: a documented call with no handler fails the build, and so does a handler with no table entry, an undocumented syscall being one userspace has no way to learn about. Arguments that are pointers are validated against the calling process's address space before use, length-checked, never trusted, never dereferenced twice (no TOCTOU on copy-in). Copy-in/copy-out for anything larger than a register; the kernel never follows a user pointer into user memory during an interrupt-disabled section.

**Object model**: everything the kernel exposes is a handle in a per-process table, `file, channel, event, shm, process, irqevent`, each carrying rights bits (read/write/map/signal/transfer). Handles can be passed over channels, which is how a server receives, say, a shm ring it may map but not resize. There is no ambient authority: a process can do exactly what its handles permit.

**I/O privilege**: `IOPL` stays 0 for every process, so no user code can execute `in`/`out`. Drivers that need port I/O (rare, only `platd`'s EC and SMBus paths on this machine) get a per-process **I/O permission bitmap in the TSS**, granting exactly the port ranges their manifest declares. MMIO is granted by mapping the physical range into the driver's address space via `map_mmio`, which requires the `mmio` capability.

**The honest caveat, stated once**: the 910GML has **no IOMMU**. Ring separation and page tables contain CPU-side bugs, a driver dereferencing a bad pointer faults and gets restarted, but a driver that programs a DMA engine with a bad physical address can still corrupt kernel memory. This design contains the common failure mode (which is CPU-side), not the worst one. `dma_alloc` returning pinned, bounds-checked buffers makes the correct thing the easy thing, and that is as far as the hardware lets us go.

### 6.8 IPC

- **Channels** ([`kernel/channel.zig`](../src/kernel/channel.zig)): synchronous call/reply, ≤64 B inline payload. Sync-by-default kills a whole class of buffering bugs and matches the request/response shape of every server we have. The in-flight call record lives on the calling thread's kernel stack, so a call cannot fail for want of memory; a reply names its call by a token carrying a generation, so a server that has been restarted cannot write a stale reply into a frame that has since gone. Messages carry up to four handles, as kernel objects rather than numbers: a number means nothing outside the process that owns it, so the kernel takes a reference to what the sender named and gives the receiver a fresh number for the same object. This is how a server hands a client a segment it may map but did not make.
- **Shm rings**: SPSC ring buffers in shared memory for bulk data (block requests, audio frames, network payloads, GUI surfaces), with an event handle for wakeups. One ring layout, defined once in [`lib/ring.zig`](../src/lib/ring.zig), reused by all four subsystems, this is the single most important internal contract in the system. Segments live in [`kernel/shm.zig`](../src/kernel/shm.zig): a refcounted list of frames, mappable into any number of address spaces at each one's own address, in a per-process window above the program image. Shared pages carry a software flag so tearing an address space down unmaps them without freeing them, which is what lets a segment outlive the process that made it. Byte totals rather than offsets, so full and empty are distinguishable; a power-of-two capacity so the offset is a mask, not a divide; and every index clamped on read, because the header lives in memory the untrusted side can write.
- **Events + `wait_many`** ([`kernel/event.zig`](../src/kernel/event.zig)): the only blocking primitive. No signals. Events count rather than latch, so a signal that arrives before anyone waits is kept instead of lost. All blocking in the kernel funnels through [`kernel/wait.zig`](../src/kernel/wait.zig), whose waiter nodes live on the blocking thread's stack, waiting allocates nothing, and a blocked thread is off the run queues entirely rather than polling.
- **`/svc` registry** ([`kernel/svc.zig`](../src/kernel/svc.zig)): name → channel. Service discovery and the reconnect path after a server restart. Clients hold a name, not a handle to one instance, which is what makes a restartable server possible. Closing the serving handle fails every call still waiting, so a crashed server is distinguishable from a slow one, and the name it held becomes free for its replacement to take. A lookup of a name whose server has gone reports NotFound rather than handing back a channel that would fail every call. Visible from userspace as `svc`.

### 6.9 Debugging without a serial port

The constraint that shapes everything. Five mechanisms, in order of use:

1. **QEMU first.** Everything that can be developed in QEMU is developed in QEMU (i8042, PATA, EHCI, HDA, VESA, ACPI all emulate well). What *cannot*: GMA900 modeset, AR2425 WiFi, atl2, the EC, the real DSDT.
2. **stage2 log ring** imported into dmesg, so early-boot failures are visible once the kernel comes up.
3. **Persistent panic ring** in a reserved physical page that survives warm reboot, panic writes it, the next boot reads and dumps it. Turns a triple-fault reboot loop into a readable trace.
4. **Panic screen with a QR crash dump**, *implemented and verified*. Blue full-screen stop, readable text on the left (fault name, decoded page-fault cause, registers, backtrace) and a QR code on the right carrying the same data machine-readably, so a phone photo becomes structured input to a symboliser instead of hand-transcribed hex. Payload format, deliberately human-readable once scanned:

   ```
   VBE1|<vec>|<errcode>|<cr2>|<eip>|<esp>|<ebp>|<bt>,<bt>,...
   ```

   The encoder ([`src/kernel/qr.zig`](../src/kernel/qr.zig)) is byte-mode, EC level L, versions 1–5, those are exactly the versions with a *single* error-correction block, which removes all interleaving logic and keeps it small. Rendering uses the upper-half-block glyph (0xDF) so two module rows share one character cell: a 37×37 symbol occupies 21 text rows, leaving room for text beside it in 80×25. Correctness is enforced by `make qr-verify`, which diffs our matrix against libqrencode across all eight masks, a QR that merely *looks* right is worthless, since the failure mode only surfaces when you are already debugging something else.
5. **Post-mortem to disk**: panic log appended to `/data/panic/` on next boot from the persistent ring.

The ICH6 EHCI does expose a debug port, but it needs a specific USB debug cable and a working EHCI stack to be useful, i.e. exactly the thing that's broken when you need it. Documented, not relied upon.

---

## 7. Storage

**PATA driver** for 8086:2653 in combined mode: secondary channel only (the SATA channel has nothing wired). Program **UDMA/66** via BMDMA at 0xFFA8 with PRD tables. Critical device constraints from the research: **28-bit LBA only** (no LBA48, cap at 128 GB, irrelevant here at 4 GB) and **no READ/WRITE MULTIPLE** (`multi 0`), so PIO fallback is single-sector and DMA is the only fast path. Kernels that mis-detect the 40-wire cable fall back to UDMA/33, we know there is no cable (soldered), so we force UDMA/66 unconditionally on this board.

**Block layer**: no elevator, reordering is pointless on flash and costs CPU (`noop`). MBR partition scan. `ublk` bridge lets `usbd` serve USB storage as kernel-mountable block devices over the standard shm ring.

**Filesystems:**

| FS | Role | Notes |
|---|---|---|
| `vfs` + `ramfs` | `/`, `/tmp`, `/dev`, `/svc` | Rootfs lives in RAM permanently |
| **FAT32 + VFAT LFN** | `/boot`, `/data`, SD cards, USB sticks | The only on-disk filesystem. Read/write |
| `vzi` | rootfs container | Read-only, zstd, built by `mkvzi` |

**One filesystem, and not a new one.** An earlier draft specified a custom
log-structured filesystem (`eeefs`) for `/data`, on the reasoning that turning
scattered small writes into sequential segment appends suits an SSD whose
small-random-write floor is 1–3 MB/s. That reasoning is sound and the design is
still rejected, for reasons that outweigh it:

- **Filesystems are where data loss lives.** Crash consistency, garbage
  collection and the long tail of corner cases are hard to get right and
  expensive to test properly. A bug costs the user their files.
- **Nothing else could read it.** The single most valuable property for a hobby
  OS is that a card can be taken out, put in any other machine, and inspected or
  repaired. A private format forfeits that exactly when it matters most.
- **The write-pattern argument is weaker than it looks.** The SM223 is not raw
  NAND: it has its own flash translation layer doing wear levelling and write
  coalescing behind the ATA interface. A log-structured layer on top is
  second-guessing a controller we cannot see inside.
- **One implementation instead of two.** FAT is already required for the boot
  partition and for interchange, so making it the only on-disk filesystem halves
  the code that has to be correct.

The real cost is FAT's absence of crash consistency. That is handled where it
belongs, above the filesystem, with the same atomic double-buffered write the
config store already uses: write a new copy, flush, then flip a pointer. Files
that matter are never modified in place. The rootfs is read-only and in RAM, so
steady-state write volume is low to begin with.

If a stronger filesystem is ever wanted, the answer is to port an existing one
(littlefs is the natural fit for flash), not to write one.

**The root filesystem is a FAT image loaded into RAM.** Not an optimisation, a
necessity. On the target the SD card sits behind a USB card reader, so the BIOS
can read it in real mode but the kernel cannot reach it at all until `usbd`
exists. stage2 therefore copies the root filesystem into RAM before leaving real
mode, and everything needed to reach a shell has to be in that copy.

It is a plain FAT image rather than a bespoke container, so the existing driver
mounts it with no new code and it can be inspected or edited from any other
machine. It is writable, which removes the need for an overlay for `/tmp`.

*On compression, and squashfs.* The rootfs is currently uncompressed. That is
right while it holds kilobytes; once it holds a shell, utilities, fonts and
applications, the BIOS-USB read path (roughly 2–8 MB/s) makes compression worth
several seconds of boot time. The cheap step then is to compress the FAT image
as a blob and decompress it into RAM, one decompressor, no second filesystem.
squashfs is the standard answer to this problem and would additionally
decompress on demand, so a large root would occupy only the pages actually
touched. It is deferred rather than rejected: it costs a reader of a thousand
or so lines plus a decompressor, and adds a second filesystem implementation
immediately after the decision to have only one. Revisit it when RAM pressure or
boot time actually justifies it.

**Detecting FAT32.** The width is *not* decided by cluster count alone. The
specification says the count decides, and that describes what a correct
formatter produces, but real formatters will happily create a small FAT32
volume whose cluster count falls in the FAT16 range, and reading its 32-bit FAT
entries as 16-bit ones produces a chain that ends early and looks like
corruption. FAT32 is identified structurally instead: `sectors_per_fat_16` and
`root_entries` are zero on FAT32 and never zero otherwise. Only once FAT32 is
ruled out does the count distinguish 12 from 16.

**Long filenames.** VFAT is not an alternative to FAT32, it is the long-name
extension, and it applies to all three FAT widths. Directory scanning assembles
the UTF-16 fragments and verifies each against the 8.3 checksum, so orphaned
long-name entries left behind by another operating system cannot attach
themselves to an unrelated file. The FAT width itself is decided by cluster
count, as the specification requires, and never from the MBR partition type
byte, which is frequently wrong.

**Unpartitioned media.** Most SD cards and USB sticks ship "superfloppy"
formatted, a filesystem starting at sector 0 with no partition table. That
sector still carries the 0xAA55 signature, so it is told apart from a partition
table by content: a boot sector begins with a jump instruction and declares a
plausible sector size and media descriptor.

**Mount table.** Paths resolve by longest mounted prefix, matched at component
boundaries so `/media` cannot capture `/mediaplayer`. The boot volume mounts at
`/`; everything else appears under `/media/<device>`. Unmounting flushes first,
FAT has no journal, so anything the device still holds is lost if the medium
goes away first, and refuses while files are open, but still detaches after a
failed flush, since a device that is already gone must not leave a permanently
stuck mount point.

**Block cache.** A four-way set-associative sector cache (128 KiB) sits under
every block device. It matters more here than it would elsewhere: reads are PIO,
so each sector costs the CPU 256 port reads plus polling, and filesystem access
re-reads the same few sectors constantly, the boot sector, the FAT, the
directory. Four ways rather than direct-mapped because the FAT and the data area
are walked in step and would otherwise evict each other.

Write-through, deliberately. The recovery strategy above depends on a completed
write having actually reached the medium; write-back would open a window where
the application believes data landed and it has not, which is the exact failure
that strategy exists to prevent.

**No swap.** Demand paging to disk is rejected on this hardware, not deferred.
The SSD is the worst possible swap device: swapping is small random writes, and
small random writes are this device's measured floor of 1–3 MB/s, so thrashing
would present as a hang. It also writes constantly, which is the fastest way to
wear out a 4 GB SLC part from 2007. The period community consensus was the same
, swap disabled, or moved to an SD card.

If memory pressure ever becomes real, the answer is **compressed RAM swap**:
compress cold anonymous pages in place rather than writing them out. That spends
CPU, which is idle, instead of flash endurance and I/O latency, which are
scarce. At roughly 2:1 on cold pages it is worth 100–200 MB on this machine, and
it touches no disk at all. Either way it needs demand paging and a page-
replacement policy first, neither of which exists yet, and neither of which is
worth building before something actually runs out of memory.

`/cfg` uses double-buffered atomic blobs (write B, fsync, flip pointer in superblock), config must never be half-written after a power cut.

---

## 8. Graphics

In-kernel driver for the GMA 900. **This is the highest-risk component after WiFi**, because VBE genuinely does not offer 800×480 on this BIOS (`[HIGH]` confidence, the whole `915resolution` saga exists because of this), so a native modeset is mandatory for the native resolution.

Sequence: map MMIO/GTT/aperture BARs (gen3 has a *separate* GTT BAR, unlike gen4+) → reuse the ~7932 KB of stolen memory as the framebuffer (avoids consuming main RAM and its bandwidth) → disable plane/pipe/port → program **DPLL_B** for the 29.58 MHz pixel clock from the 96 MHz reference (gen3 LVDS limits: VCO 1.4–2.8 GHz, m1 8–18, m2 3–11, p1 1–8, **p2 = 14** for single-channel LVDS) → pipe B timings from the known-good modeline `800 816 896 992 / 480 481 484 497 -HSync +VSync` → LVDS port at 0x61180 with dithering (the panel is 6-bit + FRC) → plane B → panel power sequencing → enable in the required order with vblank waits.

LVDS is on **pipe B** by driver convention on gen3; VGA out uses pipe A + DPLL_A for clone/extend on Fn+F5.

**Write-combining without PAT**: the CPU hides the PAT flag (Pentium M family), so the framebuffer aperture gets WC via a **variable MTRR**. Fallback if MTRRs are exhausted: uncached mapping plus a shadow buffer in normal RAM that we blit from, measurably slower, so MTRR setup failing is a warning-level event.

**Compositing model**: single kernel-side framebuffer owner (`eeewm`), double-buffered with a `DSPBADDR` flip on vblank. At 1.5 MB/frame and ~1 GB/s of achievable bandwidth, a full-screen flip is cheap but a full-screen *composite* is not, hence damage tracking is mandatory (§10.3).

**2D acceleration is deliberately deferred to M4.** The gen3 BLT ring can do fills and copies, but ring setup, fencing, and cache coherency cost real complexity, and SSE2 software blits at DDR2 bandwidth are competitive for our workload (mostly small damage rectangles, not full-screen scrolls). Revisit only if profiling says so.

**VESA fallback driver** shares the `DisplayDev` interface, probes `.weak`, and gives 640×480 anywhere, this is what makes the image boot on a random other PC, and it's the QEMU path.

---

## 9. Input and keymaps

**i8042**: standard init, scancode set 2, translation off, watchdog for a wedged controller. Keyboard on IRQ1, touchpad on IRQ12. Touchpad probe ladder as described in §4 (Synaptics → Elantech → bare PS/2), exposing absolute packets as pointer + scroll events with tap-to-click and edge scroll.

**Keymap system.**

Three layers, and **exactly one owner of compose state**: the kernel input core produces `(keycode, modifiers, press/release)`; the **input service** owns the layout tables and the dead-key/compose state machine and emits Unicode codepoints; `libeui` text widgets consume codepoints and never see scancodes. Putting compose in the input service (not in each app, not in libeui) means every text surface, the terminal, the WiFi PSK field, the editor, gets identical behaviour for free.

- **US-International (default)**, you touch-type this. Dead keys: `'` `"` `` ` `` `~` `^` composing á ä à ã â etc.; AltGr for € ñ ç ø.
- **Belgian AZERTY**, matches the physical keycaps on the target unit. Heavy AltGr use: `@` `#` `[` `]` `{` `}` `\` `|` `€`; dead keys `^` `¨` for âêîôû/äëïöü.

Layout source is a readable text format compiled to Zig tables at build time (`tools/mkkeymap.zig`), so adding a layout is a data file and a rebuild, never code. Runtime switch on `Super+Space`, default in `/cfg/input.conf`, indicator in the status bar.

Coverage needed: Latin-1 Supplement + Latin Extended-A + €. No shaping, no IME in v1.

**GUI keybindings bind to keycodes (physical position), not symbols**, otherwise every window-manager shortcut moves when you switch to AZERTY, which would be maddening on a machine whose keycaps are AZERTY but whose layout is US.

**ACPI hotkeys** arrive from `platd` as a separate event type and are merged into the same stream: 0x10/0x11 WiFi, 0x12 task manager, 0x13/0x14/0x15 mute/vol−/vol+, 0x16 display off, 0x20–0x2f brightness (low nibble = new level), 0x30–0x32 display switch.

---

## 10. GUI

### 10.1 `eeewm`, tiling compositor

Layout tree as a **Zig tagged union**. `switch` on `union(enum)` keeps traversal and coordinate computation direct:

```zig
const Node = union(enum) {
    window: *Window,
    split: struct { dir: Dir, ratio: f16, a: *Node, b: *Node },
};
```

Layouts: tall (master/stack), wide, monocle, tabbed; floating exception for dialogs. Workspace tags (6). At 800×480 with 133 DPI, borders are 1 px and the status bar is 16 px, screen real estate is the scarcest resource on this machine, which is why tiling wins here.

### 10.2 Client model

Clients render into their own shm surface (XRGB8888) and send damage rectangles over a channel. The compositor blits; it does not draw client content. No blending in v1 except the bar and notifications (alpha compositing at 630 MHz is a bandwidth tax with little visual payoff on a 6-bit panel).

### 10.3 Damage tracking and frame pacing

Per-frame: union the client damage rects, clip to visible tile regions, merge overlapping rects (simple sweep; if the merged area exceeds ~60% of the screen, promote to full-screen and skip the bookkeeping), blit only those spans with SSE2, then flip on the vblank event. Cursor is a software sprite with save-under. This is the difference between an idle blinking terminal cursor costing 30 KB/frame and costing 1.5 MB/frame.

### 10.4 Render-pass arena

Persistent window tree on the general allocator, everything per-frame (clip lists, damage sets, layout scratch) on a `std.heap.ArenaAllocator` reset at end of frame. Zero fragmentation in the hot path, no per-node frees.

### 10.5 `libeui`: Nuklear-style API and look, retained-mode core

The goal is Nuklear's *ergonomics and appearance* without Nuklear's *redraw cost*. Those are separable concerns, and separating them is the design:

**Immediate-mode API, retained-mode core.** Application code looks like Nuklear, you describe the UI every frame, no widget handles to store, no callbacks to wire:

```zig
if (ui.begin("Settings", rect, .{ .title = true, .border = true })) {
    ui.layoutRow(.dynamic, 24, 2);
    ui.label("Brightness", .left);
    if (ui.slider(&brightness, 0, 15, 1)) platd.setBrightness(brightness);

    ui.layoutRow(.dynamic, 24, 1);
    if (ui.combo(&layout_idx, &.{ "US-International", "Belgian AZERTY" })) input.setLayout(layout_idx);

    if (ui.treePush(.tab, "Advanced", &adv_open)) {
        ui.property(i32, "Fan %", &fan, 0, 100, 1);
        ui.checkbox("Turbo (900 MHz)", &turbo);
        ui.treePop();
    }
}
ui.end();
```

Underneath, `libeui` does **not** repaint on every call. Each frame the builder emits a compact command list; the core **diffs it against last frame's list** by stable widget ID (hashed from call-site + label + container path, the same trick Dear ImGui/Nuklear use for state). Only widgets whose command bytes or state actually changed are marked dirty, and their bounding boxes become the frame's damage rectangles. A blinking cursor in a text field damages ~30 KB, not 1.5 MB.

The diff pass costs a linear walk over a few hundred command structs, microseconds, and entirely CPU-cache-resident, which is the price for keeping the API that makes UI code pleasant to write. Widget *state* that must persist (scroll offsets, text selection, tree expansion, focus) lives in a retained side table keyed by the same IDs, so the immediate-mode surface is a genuine illusion, not a leak.

**Widget set: Nuklear parity where it matters:** label, button (text/icon/toggle), checkbox, radio, **property/spinner** (drag-or-type numeric field), slider, progress, **combo box**, list view (virtualized), scrollbar, **group with independent scrolling**, tabs, **collapsible tree**, text input (single + multi-line), **color picker**, **chart/sparkline** (Monitor uses these), tooltip, context menu, dialog, toast, and a searchable **command palette** in place of menu bars, the right primary interaction on a small keyboard-first screen.

**Layout** follows Nuklear's row model, which is the part of its API that ages best: `layoutRow(.dynamic|.static, height, cols)` plus explicit per-column ratio templates and a `space` mode for absolute placement. No constraint solver, no reflow passes, layout is computed in one downward walk and is trivially arena-allocated (§10.4).

**Look.** Nuklear's aesthetic, flat surfaces, crisp 1 px borders, chunky hit targets, restrained palette, visible widget chrome, is genuinely well suited to this hardware, and not by coincidence: it was designed for software rasterization. Flat fills and single-pixel borders are exactly what a CPU blitter is fast at, and what a 6-bit + FRC panel displays cleanly. We take that aesthetic wholesale, as a theme token table (surface, surface-raised, border, text, text-dim, accent, accent-hover, warning, error) with a dark default theme and a light variant. Explicitly avoided: gradients and large translucent regions, both band visibly on this panel and cost bandwidth we don't have.

So: Nuklear's API shape, Nuklear's widget breadth, Nuklear's visual language, with per-widget dirty tracking instead of unconditional full repaint. That keeps the compositor's damage model (§10.3) intact, which is the thing that keeps the Celeron under 100%.

**Static linking** for the whole OS. With Zig's dead-code elimination a `libeui` app links maybe 120–180 KB of toolkit; a dynamic linker plus PLT/GOT machinery costs complexity everywhere and its RAM saving only materialises with many concurrent apps, which a 512 MB single-user machine won't have. Revisit if app count ever exceeds ~15.

### 10.6 Host backend (development accelerator)

The highest-leverage item in this document for development speed. `eeewm` and every `libeui` app target a `Backend` interface (`blit`, `fill`, `text`, `pollEvent`, `present`). Two implementations: `backend/vibeee` (shm surfaces + IPC) and `backend/host` (SDL2 + libc). The entire GUI, toolkit, layout algebra, keymap engine, and app logic then compile and run as a native desktop window, with a real debugger, in a one-second edit-run loop. Only the pixels' final destination differs.

### 10.7 Text rendering

`stb_truetype` via `@cImport`, rasterizing to an 8-bit alpha mask, with a **glyph cache in the compositor** (not per-client, one cache, shared, keyed by face+size+codepoint; saves both RAM and repeated rasterization). At 133 DPI, hinting matters: use `stb_truetype`'s output with a gamma-corrected blend and no subpixel AA (the panel is 6-bit + FRC; subpixel rendering would produce visible colour fringing). Ship one UI face and one monospace face, plus a bitmap fallback font baked into the kernel for the panic screen and early console.

### 10.8 Applications

Rebranded, in our own style, all `libeui`:

| App | Analogue | Notes |
|---|---|---|
| **Pad** | WordPad | Rich-ish text: bold/italic, sizes, save as `.txt`/`.rtf`-lite |
| **Draw** | MS Paint | Bitmap editor: pencil, fill, shapes, selection. Saves PNG via `stb_image_write` |
| **Edit** | vim/kilo | Terminal editor, port `kilo.c` (§11 verdict) |
| **Monitor** | Task Manager | Processes, CPU, RAM, per-server health, kill/restart. Bound to Fn+F6 (ATKD 0x12), which is literally the task-manager key on this keyboard |
| **Files** | Explorer | Dual-pane, mount/eject awareness for SD and USB |
| **Calc** | Calculator | Basic + programmer modes |
| **Mines** |, | Minesweeper: tiny, no assets, keyboard + mouse, fits the screen exactly |
| **Term** | terminal | VT100/xterm subset via `libvterm` |
| **View** | image viewer | PNG/JPEG/BMP via `stb_image` |

**System configuration, one app, plus two popovers.** `Control` is the single config utility, organised in panels, so there is one place to look and one settings schema:

| Panel | Contents |
|---|---|
| **Audio** | Mixer: master + per-client volume sliders with live meters, mute, output routing (speakers/headphones with jack-detect state), capture source (internal vs external mic) and gain. Note the shipped-Xandros gotcha the research turned up, capture defaults to *off* on this codec, which we do not replicate |
| **Network** | WiFi scan list with signal and security, PSK entry, saved networks, connect/forget; ethernet link state; per-interface IP/DNS, DHCP vs static; the Fn+F2 radio-kill state, which needs explaining rather than silently failing |
| **Display** | Brightness, external VGA mode and clone/extend, idle dimming |
| **Input** | Keymap (US-International ↔ Belgian AZERTY), repeat rate, touchpad tap/scroll |
| **Power** | Battery detail, thermal and fan readout, fan curve (expert), turbo toggle with its warning |
| **System** | Version, storage use, install-to-SSD, factory reset, about |

Because the two you actually reach for mid-task are volume and network, both also get a **status-bar popover**, click (or hit the hotkey) on the bar item for a slider or a network list, without leaving the current app. Fn+F7/F8/F9 drive volume directly through `sndd` and flash the same popover as feedback. Everything else lives only in `Control`.

---

## 11. Third-party libraries, verdicts

Candidate libraries, adjudicated against the hardware research and the budgets above. Each row is a decision, not a survey.

| Library | Verdict | Reasoning |
|---|---|---|
| **`stb_truetype`** | **ADOPT** | Single file, public domain, `@cImport` clean. No realistic alternative at this size |
| **`stb_image`** | **ADOPT (scoped)** | PNG + BMP compiled into the system; JPEG only linked into View and Draw to keep the base small |
| **`stb_image_write`** | **ADOPT** | Draw and screenshots need PNG output |
| **`dr_wav` / `dr_flac` / `dr_mp3`** | **ADOPT** | Exactly the right shape: no deps, PCM out, we own the sink |
| **`miniaudio`** | **REJECT** | It's a cross-platform *backend abstraction*, its value is device enumeration across CoreAudio/WASAPI/ALSA. We are the backend. Its mixer is ~1 k lines we'd write anyway in Zig, without the porting layer |
| **`lwIP`** | **ADOPT** | The single biggest schedule saver here. A correct TCP with congestion control, retransmit, and DHCP/DNS/SNTP is months of work and a rich source of subtle bugs. Run `NO_SYS=0` with our threads; write `sys_arch` (~300 lines) and a netif shim. SNTP comes free, and we need it because dead CMOS batteries break TLS |
| **`eiwd`** | **REJECT** | Welded to Linux `nl80211` + ELL event loop; the port surface is larger than the problem. WPA2-PSK is PBKDF2-HMAC-SHA1 + a 4-way handshake + CCMP, all of which are in Zig's `std.crypto`. ~1500 lines of Zig, no C dependency, and we control the state machine that has to survive the Fn+F2 power-gate |
| **ACPICA** | **ADAPT → prefer `uACPI`** | ACPICA is the reference but it's large, has an idiosyncratic OSL contract, and drags in a lot for what we need. **`uACPI`** is the modern hobby-OS-oriented AML interpreter with a much smaller and saner host interface, and it's actively maintained. Take uACPI; keep ACPICA as the fallback if uACPI hits a wall on this AMI DSDT. Either way: we need real AML, because `WLDS`/`CAMS`/`PBLS`/`_BIF`/`_Qxx` are all AML methods. **And whichever we use must blacklist `CFVS`, calling it hangs this machine** `[HIGH]` |
| **`mbedTLS` / `BearSSL`** | **DEFER, use Zig `std.crypto.tls`** | Zig ships a TLS 1.3 client in std. That covers HTTPS for a browser and SNTP-adjacent needs with zero C deps. Only revisit if we need TLS 1.2-only servers or a TLS *server* |
| **`libvterm`** | **ADOPT** | Terminal emulation is a deceptively large state machine (CSI/OSC/DEC modes, scroll regions, character sets). libvterm is pure state, no I/O, the ideal shape. MIT |
| **`bestline` / `linenoise`** | **REJECT** | Both assume POSIX termios and a Unix tty. We own the terminal end to end; line editing with history and completion is ~400 lines of Zig against our own event stream, and avoids implementing termios semantics we otherwise never need |
| **`kilo`** | **ADOPT (as `Edit`)** | ~1 k lines, zero deps, pure VT100 escapes, and we have `libvterm` on the other end speaking exactly that. Cheapest possible real editor. Rebrand, tidy, keep the syntax highlighting |
| **`s6`** | **REJECT** | Daemontools-style supervision assumes fork/exec, signals, and Unix sockets. We deliberately have no `fork`. Our supervisor is ~800 lines of Zig against native `spawn` + events, and gets dependency-aware restart that s6 would need extra machinery for |
| **`Nuklear` / `microui`** | **ADAPT, take the API and the look, not the renderer** | Nuklear's builder API, row-layout model, widget breadth, and flat software-rasterizer aesthetic are all worth having and all well suited to a CPU blitter. What we can't take is unconditional full repaint every frame, which contradicts damage tracking. `libeui` reimplements the API shape over a diffing retained core (§10.5). Reimplementing rather than vendoring also avoids bolting Nuklear's font/vertex-buffer assumptions onto our compositor |
| **`litehtml` + `quickjs`** | **DEFER to M5, feasible** | litehtml needs a draw/measure backend, which `libeui` + `stb_truetype` can provide; quickjs is ~200 KB and runs fine. The honest blockers are not the engines: they're TLS + HTTP + fonts + 512 MB of RAM against a modern web that assumes 100× this machine. Realistic target is a *reader* for simple pages, not a general browser. Worth doing, worth not promising |
| **PCI enumeration in Zig** | **AGREE** | ~200 lines with packed structs over 0xCF8/0xCFC, plus MCFG/ECAM at 0xE0000000 which this board has `[HIGH]` |
| **Config via Zig std** | **ADAPT** | JSON is noisy to hand-edit and `std.json` allocates more than we want at boot. Use a ~200-line TOML-lite key/value parser in Zig, parsing directly into comptime-known structs, arena-allocated |
| **O(1) scheduler** | **ADAPT** | 32 levels and `@ctz` rather than 140 levels and inline `bsf`, see §6.4 |
| **Turbo mode (PLL)** | **ADOPT (opt-in)** | See §12 |

Rule for every C dependency: it lives in `third_party/`, is vendored at a pinned commit, wrapped in a thin Zig module that owns its allocation, and is built with `zig cc`, no autotools, no configure, no system headers.

---

## 12. Platform, power, and turbo

`platd` owns ACPI (via uACPI), the EC, hotkeys, battery, thermal, and the radio/camera gates.

- **EC** at 0x62/0x66: temperature 0x51, fan PWM 0x63, tach 0x66/0x67, manual-fan bit 0xD3.1. The 0x380–0x384 Index-IO backdoor is documented and exposed **diagnostics-only**, it bypasses EC firmware entirely and is a good way to brick a session.
- **Fan**: EC auto by default. Manual curve is opt-in with a watchdog that restores auto on crash or exit, the research carries an explicit warning that manual mode will happily let this CPU walk to its 90 °C trip.
- **Battery**: `_BIF`/`_BST` values on this machine are **percentages mislabelled as mAh** `[HIGH]`. Detect (design capacity 5200 with last-full ≤100 and granularity 52) and correct, rather than doing the naive division that every generic OS gets wrong here.
- **WiFi kill (Fn+F2)** power-gates the PCIe slot, so the card physically vanishes. Flow: hotkey → `platd` notifies `devmgd` → `netd` quiesces and closes the device → `WLDS(0)` → on re-enable, `WLDS(1)` → rescan bus 1 slot 0 → `netd` re-attaches. `netd` must treat all-`0xFFFFFFFF` reads as "device gone", not as data. State persists in the EC across reboots, so boot-with-WiFi-off is a normal case to handle.
- **Camera** is BIOS-disabled by default *and* gated by `CAMS`: Settings must be able to explain that, not just fail.
- **S3 suspend**: freeze userspace → quiesce servers in dependency order → save device state (we never re-POST the VBIOS, so the display driver's full register save/restore list is load-bearing) → `_PTS` → set waking vector in FACS → PM1 `SLP_TYP`/`SLP_EN` → real-mode trampoline on resume → restore in reverse order → resync timers.
- **Turbo mode**: opt-in, off by default, big warnings. Reprogram the **ICS9LPR426A** PLL over SMBus at slave 0x69 (block read/modify/write, N in byte 12, M in byte 11 bits 5:0), stepping **70 → 85 → 100 MHz** because a direct jump locks the machine `[HIGH]`, plus the KB3310 GPIO voltage select (pin 0x66, Index-IO port 0xFC2C bit 6) for stability at 100 MHz. That's the rated 900 MHz, a 43% clock increase, which is very noticeable in this class of machine. Guarded: revert-on-panic, revert-on-thermal, off across suspend, and a first-run "this may destabilise your machine" dialog. Note the memory clock rides the same FSB, so this is also a RAM overclock and not every module survives it.

---

## 13. Userspace

- **`init`** (PID 1): mounts `/`, starts `devmgd` and `platd`, brings up servers in dependency order, GUI last. Declarative service manifests (binary, deps, caps, restart policy, watchdog interval). Dependency-aware restart: `usbd` dying must not permanently unmount `/data`; in-flight `ublk` requests get aborted with a clean error so VFS callers see `EIO` rather than hanging forever.
- **`devmgd`**: PCI + USB enumeration, manifest matching, spawn with capabilities (§4).
- **`libc` (`eeelibc`)**: POSIX-lean, C-ABI exported so `zig cc` can build ported C. Files, `posix_spawn`, `waitpid`, `clock_gettime`, `nanosleep`, malloc family, stdio, pthreads-lite over kernel threads + futex-lite, BSD sockets shimmed to `netd` IPC. **No `fork`**, returns `ENOSYS` with a documented porting pattern. This is the one POSIX-ism worth refusing: fork on a from-scratch kernel means COW page tables, and every program we care about uses it immediately followed by `exec`.
- **Shell + utilities**: `vsh` (line editing, history, globs, pipes, redirects, no job control in v1) plus a **multicall binary** à la busybox with ~30 applets: `ls cat cp mv rm mkdir rmdir ln stat du df mount umount eject ps kill top free sync date hexdump grep find head tail wc sort uniq echo sleep uname dmesg hwprobe keymap brightness sysinfo install-ssd`. One binary, argv[0] dispatch, shared Zig code, a fraction of the size of 30 separate static binaries.
- **Emergency console**: `Ctrl+Alt+F1` drops to a kernel-framebuffer console with a minimal shell, independent of `eeewm`. This is what saves you when the GUI won't start on real hardware.

**Package management**, recommendation: **don't build one.** Two mechanisms cover the actual needs:

1. **System updates**: A/B whole-image. The boot design already has A/B copies with CRC verification and 3-strike auto-fallback; an update writes the inactive slot and flips a pointer. Atomic, revertible, no dependency resolution, no partial-upgrade states.
2. **Apps**: a bundle is a directory, `app.manifest` + static binary + assets, dropped into `/data/apps/<name>/`, discovered by the launcher at startup. Install = copy. Uninstall = delete.

Static linking is what makes this work: with no shared libraries there are no version constraints, so a dependency solver would have nothing to solve. If a package *format* is ever wanted, it's a tarball with a manifest, not a database.

---

## 14. Build system

Plain GNU Make, out-of-tree build, no root required to produce the image.

```
make            # everything → build/vibeee.img
make qemu       # qemu-system-i386 with a hardware profile close to the 701
make qemu-usb   # boot via emulated USB mass storage, mirrors the real SD path
make host       # GUI + apps as a native SDL2 binary (§10.6)
make sd DEV=/dev/rdiskN   # guarded flasher (refuses non-removable devices)
make hwprobe-report        # boot in QEMU, dump the probe table
```

Pipeline: `nasm` (stage1/stage2 stub) → `zig build-exe` per component (`-target x86-freestanding`, `ReleaseSmall`, pinned Zig version via `toolchain.lock`) → `mkvzi` (rootfs container, zstd) → `mformat`/`mcopy` (populate FAT16 P1) → `mkpart` + `dd` (partition table + assembly) → `vibeee.img`.

Toolchain: Zig (pinned), NASM, mtools, and nothing else. No autotools, no libc on the host, no cross-GCC to build, `zig cc` handles every vendored C dependency.

---

## 15. Phasing

| Milestone | Content | Runs on |
|---|---|---|
| **M0** | Boot chain, kernel entry, PMM/paging/heap, IDT, LAPIC/IOAPIC, timers, scheduler, syscalls, Ring 3, IPC, ramfs, VESA console, i8042 keyboard, `vsh` | QEMU |
| **M1** | PATA + FAT32, `init`/`devmgd`, libc, multicall utils, touchpad, **GMA900 native modeset**, `eeewm` + `libeui`, Term/Files/Edit, keymaps | **First real-hardware boot** |
| **M2** | `usbd` (EHCI + mass storage + ublk), `platd` (uACPI, EC, hotkeys, battery, backlight), `sndd` (HDA + ALC662), `netd` ethernet + lwIP + DHCP/DNS/SNTP, Pad/Calc/Monitor/Mines/Settings | Hardware |
| **M3** | AR2425 WiFi + WPA2 supplicant, S3 suspend/resume, UVC webcam, Draw/View, install-to-SSD, A/B updater, turbo mode | Hardware |
| **M4** | Polish: 2D acceleration if profiling justifies, C3 idle, power tuning, ARM/HAL second-board proof, app bundles | Hardware |
| **M5** | Browser experiment (litehtml + quickjs + Zig TLS), explicitly exploratory | Hardware |

**M1 is the honest risk gate**: it contains the GMA900 modeset, which cannot be tested in QEMU and has no public gen3 documentation. If the native modeset resists, the fallback is 640×480 VESA (ugly, letterboxed, but a working GUI) while the modeset is debugged against the i915 source and `xf86-video-intel` as references.

---

## 16. Principal risks

1. **GMA900 modeset**, no public gen3 PRM, untestable in QEMU, and the panel has no EDID so timings come from the known-good modeline or the VBT. *Mitigation*: VESA fallback always present; panic screen falls back to VGA text.
2. **AR2425 WiFi**, reverse-engineered silicon, no datasheet, known calibration bugs in early ath5k, plus the power-gate hot-unplug dance. *Mitigation*: ethernet first, WiFi in M3, ath5k as the reference implementation, and accept that b/g at moderate rates is a success condition.
3. **AML interpreter**, battery, backlight, hotkeys, and the radio gates all depend on it. *Mitigation*: uACPI, with a hardcoded direct-EC degraded mode (the research gives us the exact EC registers) so the machine remains usable if AML misbehaves.
4. **No serial port**, every hardware-only bug is debugged through a framebuffer and a persistent panic ring. *Mitigation*: §6.9's five mechanisms, and maximising what QEMU covers.
5. **Budget pressure**: 48 MB image and 48 MB idle RAM are tight once fonts, uACPI, lwIP, and the apps land. *Mitigation*: measure per component from M1 and treat the budget table as a build-time assertion, not an aspiration.

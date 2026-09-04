# vibeee Kernel Core Design (02-kernel-core)

> **Status: partially implemented.**
>
> Built and working: physical memory ([`pmm.zig`](../src/kernel/pmm.zig)), the slab heap ([`heap.zig`](../src/kernel/heap.zig)), the O(1) scheduler with per-thread FPU state ([`sched.zig`](../src/kernel/sched.zig)), per-process address spaces, the ELF loader ([`elf.zig`](../src/kernel/elf.zig), [`exec.zig`](../src/kernel/exec.zig)), the handle table ([`handle.zig`](../src/kernel/handle.zig)), table-driven syscalls ([`syscall_table.zig`](../src/kernel/syscall_table.zig)), timekeeping ([`clock.zig`](../src/kernel/clock.zig)), blocking and IPC ([`wait.zig`](../src/kernel/wait.zig), [`event.zig`](../src/kernel/event.zig), [`channel.zig`](../src/kernel/channel.zig), [`svc.zig`](../src/kernel/svc.zig), [`shm.zig`](../src/kernel/shm.zig)), and clean shutdown ([`shutdown.zig`](../src/kernel/shutdown.zig)).
>
> Also built: SYSENTER where the CPU has it, with `int 0x80` as the fallback and the same
> register convention either way; the userspace-driver API (`irq_attach`, `ioport_grant`,
> `map_device`), all three behind the driver capability; pipes; and the VFS with FAT over
> both a ramdisk and a partition.
>
> Not yet: the ublk bridge, which is what lets `usbd` provide a block device, and therefore
> what stands between this machine and a filesystem that outlives a reboot.
>
> There is no devfs and there will not be: a program reaches hardware through a capability
> granted at spawn, and a name in a directory cannot grant one.
>
> Where this document and [`00-vibeee.md`](00-vibeee.md) disagree, the master design
> wins: it carries later decisions this document predates.

Target: ASUS Eee PC 701 4G only. Celeron M 353 (Dothan C-0, 630 MHz, single core, 32-bit), 512 MB DDR2 (~504 MB usable), no serial port. Zig freestanding i686 + NASM stubs, ReleaseSmall.

## 1. Overview

Monolithic-with-servers hybrid. Kernel core owns: physical/virtual memory, processes/threads/scheduler, time, interrupts, SYSENTER syscalls, channels/events/shm IPC, handles, ELF loading, VFS + page-cache-lite + FAT over a ramdisk for `/` and over a partition for the rest, the user-driver API (PCI cfg, MMIO, ports, DMA, IRQ events), the ublk userspace-block bridge, and panic/debug infrastructure. Everything is single-core: no locks beyond IRQ-disable critical sections (`cli`/`sti` pairs wrapped in `SpinIrq` that compiles to pushf/cli/popf), no IPIs, no TLB shootdown. This assumption is load-bearing and pervasive.

Design center: minimize memory traffic (~1 GB/s bus), minimize code (≤1.5 MB ELF), keep GUI (8 ms frames) and audio (20 ms periods) schedulable, and be debuggable with no serial port.

## 2. Hardware facts used (with research confidence)

| Fact | Source/confidence |
|---|---|
| CPUID flags: pae, nx (PAE-only), pse, pge, sep (SYSENTER), mtrr, fxsr, sse2, tsc, msr, apic; NO PAT, NO SSE3, NO x86-64, cpuid level 2 | core-platform §1 HIGH |
| Single core, no HT, no P-states (EIST fused off), multiplier locked, 630 MHz (70 MHz FSB) | core-platform §1 HIGH |
| TSC halts in C3 ("Marking TSC unstable... TSC halts in idle"); LAPIC timer stops in C3 (MEDIUM, architectural) | core-platform §6 HIGH/MEDIUM |
| ACPI PM timer at I/O 0x808 (3.579545 MHz); PM base 0x800 | core-platform §5/§6 HIGH |
| HPET in ICH6-M at 0xFED00000, NOT in ACPI tables; enable via LPC (00:1f.0) cfg 0xF0 → RCBA, HPTC at RCBA+0x3404 | core-platform §6 HIGH |
| LAPIC 0xFEE00000, IOAPIC id 1 at 0xFEC00000, GSI 0–23, MADT overrides IRQ0→GSI2, SCI IRQ9→GSI9 level/high | core-platform §6 HIGH |
| Observed IRQs: 1/12 i8042, 8 RTC, 9 SCI, 14/15 ata_piix, 16 UHCI, 18/19 UHCI, 23 EHCI+UHCI#1 (701SD dump; MEDIUM for exact PCI GSIs on 4G) | core-platform §6 MEDIUM |
| E820 map shape (usable to top-of-DRAM minus ~8.5 MB stolen/ACPI; 512 MB machine ≈ usable ends ~0x1F78_0000) | core-platform §5 HIGH (shape), inferred for 512 MB |
| MCFG ECAM at 0xE000_0000 phys, buses 0–255 | core-platform §2 HIGH |
| SSD: PATA secondary master 0x170/0x376, BMDMA 0xFFA8, IRQ15, ATA-4, 28-bit LBA, no R/W MULTIPLE, UDMA/66; seq W ~20 MB/s, 4K writes ~1–3 MB/s | core-platform §4 HIGH (perf MEDIUM) |
| GMA aperture 256 MB @ 0xD000_0000, ~8 MB stolen; VBE has no 800×480 | core-platform §2/§5 HIGH |
| SCI=IRQ9, EC at 0x62/0x66, ASUS010 hotkeys via Notify, CFVS hangs (never call) | quirks §1/§2/§5 HIGH |
| No serial port; legacy BIOS; boots USB-HDD | core-platform §5 HIGH |
| Wifi slot power-gated by WLDS (device hot-unplugs): IRQ/PCI state must tolerate device vanishing | peripherals §4 HIGH |

## 3. Memory management

### 3.1 Paging decision: plain 32-bit 2-level (NO PAE). Numbers:

- **PTE overhead**: typical process (2 MB text+data, 128 KB stack, 1 MB heap): 2-level = 4 KB PD + 3 PTs = **16 KB**; PAE = PDPT page + 2 PDs + 6 PTs (8-byte entries) = **~36 KB**. At 24 live processes: 384 KB vs 864 KB. Absolute delta (~0.5 MB of 512 MB) is negligible, memory is NOT the decider.
- **Page-walk bandwidth**: 4-byte PTEs pack 16 entries per 64 B cache line vs 8 for PAE. Every TLB miss walk on a ~1 GB/s memory bus touches half the lines. With 512 KB L2 this matters on compositor-scale working sets.
- **Large pages**: PSE gives 4 MB pages → the whole 504 MB linear map = **126 PDEs, zero PTs**; PAE's 2 MB pages need 252 PDEs. 4 MB pages also halve large-page TLB pressure (Dothan's large-page TLB is small).
- **Code complexity**: PAE needs 64-bit PTE stores (torn-write discipline even on one core because the hardware walker runs concurrently with the instruction stream), PDPT reload rules, cmpxchg8b paths: ~+400 lines and +2–3 KB text.
- **What we give up**: NX. On this machine every driver server already has unrestricted DMA (no IOMMU), kernel integrity cannot be guaranteed against a hostile privileged server anyway, and it is a single-user appliance. NX for ordinary apps is real but marginal; not worth the tax. **Decision: 2-level + PSE + PGE. No NX, documented as accepted risk.** W^X is still applied at the VFS/loader policy level (mappings are created RO or RW+noexec-by-convention; unenforceable in HW).

CR4 = PSE|PGE. CR0.WP=1 (kernel honors RO pages, catches kernel bugs writing to shared text).

### 3.2 Virtual layout (3G/1G)

```
0x0000_0000–0x0000_FFFF  user: unmapped (null guard, 64 KB)
0x0001_0000–0xBEFF_FFFF  user: image (fixed base 0x0804_8000), heap ↑, mmap/shm area ↓ from 0xBE00_0000
0xBF00_0000–0xBFFF_EFFF  user: main stack region (grows down, guard page below each stack)
0xC000_0000–0xDFFF_FFFF  kernel: linear map of RAM, 4 MB global PSE pages (126 used @512MB)
0xE000_0000–0xEFFF_FFFF  kernel: ioremap window (4 KB PTEs; ECAM slice, LAPIC, IOAPIC, HPET, RCBA, HDA BAR, GMA MMIO, FB aperture)
0xF000_0000–0xF7FF_FFFF  kernel: kstack area (8 KB stacks, 4 KB guard holes)
0xF800_0000–0xFFBF_FFFF  kernel: vmalloc spare / large heap spill
0xFFC0_0000–0xFFFF_FFFF  recursive PD mapping (PDE[1023] = PD)
```
Kernel PDEs (0xC00–0xFFF range, 256 entries) live in a master template; per-process PDs copy them once at creation (kernel mappings never change shape after boot except ioremap, which pre-reserves PTs for the whole 0xE000_0000 window at boot: 64 PTs = 256 KB, flat, no sync problem).

### 3.3 Physical allocator: bitmap (not buddy)

512 MB = 131,072 frames = **16 KB bitmap** (in .bss). Justification vs buddy: allocation profile is (a) single 4 KB frames, dominant, served O(1) amortized by a rotating next-fit cursor; (b) physically-contiguous multi-page DMA/framebuffer allocations, which happen a few dozen times, nearly all at boot/driver-start, a linear first-fit scan over 16 KB (≤16 µs worst case at memory speed) is irrelevant. Buddy costs ~3× the code (~400 lines + free-list metadata) to optimize the case we don't have. Contiguous alloc takes `align` and `boundary` args (`boundary=64K` for anything fed to BMDMA PRDs).

E820 handling: bootloader passes raw E820 (INT 15h AX=E820) in BootInfo. Kernel marks reserved: E820 non-usable, frame 0, 0x9F000–0xFFFFF, kernel image, initrd (until unpacked), the **panic page** (top 64 KB of usable RAM, §12), and stolen-graphics implicitly (not in usable E820).

```zig
pub const phys = struct {
    pub fn allocFrame() ?u32;                       // returns paddr
    pub fn allocContig(pages: u32, align_: u32, boundary: u32) ?u32;
    pub fn free(paddr: u32, pages: u32) void;
    pub fn stats() PhysStats;                       // free/total/contig-largest
};
```

### 3.4 Kernel heap (Zig)

Two tiers exposing `std.mem.Allocator`:
1. **`SlabAlloc`**: size classes {16,32,64,128,256,512,1024,2048} B, per-class singly-linked free lists carved from whole frames obtained from `phys`; frame header holds class + inuse count; empty frames returned. O(1), ~200 lines, no per-object header (freelist link stored in the free object).
2. ≥2049 B: page-granular from `phys` via linear map (contig not required, vaddr==linear map, so must be phys-contig; if `allocContig` fails, fall back to vmalloc window mapping scattered frames).
Fixed kernel-heap **cap 4 MB** (commit-accounted); hitting it is a bug, panic in debug builds, ENOMEM in release. Kernel stacks come from the kstack area, 2 frames + guard hole; overflow hits the guard → #PF → double-fault task gate path (§12).

### 3.5 Address spaces, shm, COW

`AddrSpace` = PD paddr + sorted region list (`Region{base, len, kind: .image|.heap|.stack|.shm|.mmio|.dma, prot, obj: ?*ShmObj, file: ?*Vnode}`; max 64 regions/process). Anonymous memory is **demand-zero** (#PF allocates+zeroes a frame); file text pages are mapped **shared read-only directly from ramfs frames** (ramfs stores files as page arrays, zero copy, the big win at 512 MB); data segments are **copied eagerly** at load.

**COW: not implemented.** No fork exists (spawn only), so the only COW candidate would be data-segment sharing between instances of the same binary, a few hundred KB per process, versus the cost of per-frame refcounts + fault-path complexity. Eager copy of .data at ~1 GB/s costs <1 ms per spawn. Cut it.

**shm**: `ShmObj{frames: []u32, npages, refs, uncached: bool}`, object-level refcount (not per-page). Created by `shm_create(bytes)`; mapped via `shm_map(handle, prot)` into the mmap area; destroyed when refs (mappings + handles) hit zero. shm frames need not be contiguous. `dma_alloc` is a privileged variant that IS contiguous and reports paddr (§9).

## 4. Processes, threads, scheduler

### 4.1 Objects

```zig
pub const Thread = struct {
    tid: u32, proc: *Process,
    kstack_top: u32,                 // also written to IA32_SYSENTER_ESP on switch
    ctx: SwitchFrame,                // ebx esi edi ebp esp eip (callee-saved only)
    fxsave: *align(16) [512]u8,      // SSE/x87 state, lazily maintained
    tls_base: u32,                   // GDT[6] base rewritten on switch
    state: enum { runnable, running, blocked, sleeping, zombie },
    prio: Prio, quantum_left_us: u32,
    wait: WaitState,                 // what it's blocked on (chan txid, event set, sleep deadline)
    link: DList,                     // run queue / wait queue / sleep queue linkage
};
pub const Process = struct {
    pid: u32, aspace: AddrSpace, handles: HandleTable,
    caps: Caps,                      // packed: driver, rt, ublk_register, klog
    threads: DList, exit_code: i32, parent: ?*Process,
};
pub const Prio = enum(u2) { rt = 0, high = 1, normal = 2, idle = 3 };
```

1:1 threads. GDT: 0x08 kcode, 0x10 kdata, 0x18 ucode(DPL3), 0x20 udata(DPL3) (this order is mandatory for SYSENTER/SYSEXIT), 0x28 user TLS (base rewritten per-thread, `gs`), 0x30 TSS, 0x38 double-fault TSS.

### 4.2 Context switch & FPU

Switch = save callee-saved regs on old kstack, swap `esp`, write `IA32_SYSENTER_ESP` (MSR 0x175) = new kstack_top, rewrite GDT TLS entry + `mov gs`, reload CR3 only if the process changes (kernel mappings are Global: PGE keeps them in TLB). Cost estimate: ~1–2 µs.

**FPU: lazy via CR0.TS + #NM, safe and optimal on a single core** (the classic SMP hazard, stale state on another CPU, cannot occur). Switch sets TS; first SSE/x87 use traps #NM → `clts`, `fxsave` to previous owner's area, `fxrstor` current. Threads that never touch SSE (most driver servers' control paths) pay zero. Kernel itself is compiled **soft-float, no SSE/MMX/x87** (Zig target: `pentium_m` minus sse,sse2,mmx,x87) so kernel code never triggers #NM; the two exceptions (memcpy tuning) are not worth the state discipline, `rep movsd` saturates this bus anyway.

### 4.3 Scheduler

Strict-priority round-robin, 4 levels, per-level FIFO run queues; preemptive.
- `rt` (sndd mix thread, usbd ISO/interrupt path): 2 ms quantum, plus an anti-runaway guard, if `rt` consumed >80 ms of any rolling 100 ms window, it is demoted to `high` until the window drains (protects the UI from a looping driver).
- `high` (GUI server, input dispatch, netd RX): 5 ms.
- `normal` (apps): 10 ms.
- `idle` (background indexing etc.): 20 ms, runs only when others empty.

Rationale: audio needs the CPU every 20 ms for <2 ms of mixing, `rt` guarantees that against a busy compositor. Compositor needs ≤8 ms/frame, `high` preempts apps immediately on input/vblank events. A fair/CFS-style scheduler buys nothing on a 630 MHz single core with <100 threads; strict priority + IPC priority donation (§7) is simpler and more predictable.

Sleep queue: deadline-sorted doubly-linked list (≤~64 threads; insertion O(n) is fine). `Prio.rt` requires `Caps.rt` (granted by devmgr manifests).

### 4.4 Idle policy: C1 (HLT) only

`sti; hlt` loop. **No ACPI C2/C3.** Justification: C3 halts TSC and the LAPIC timer (verified on this machine), forcing PM-timer/HPET wakeup re-arming and clock resync machinery; C2 entry via P_LVL2 I/O read saves little on a 5 W ULV part whose platform (panel/chipset ~7 W) dominates draw. Estimated battery cost of skipping C3: minutes, not tens of minutes. Deep idle is an M3 experiment behind a boot flag, never default. This decision is what makes TSC and LAPIC-timer usable (§5).

## 5. Time

Source ladder (all normalized to a 64-bit monotonic `ns` counter):
1. **ACPI PM timer (0x808)**, always works, used from earliest boot for calibration; 3.579545 MHz, 24-bit (check FADT `TMR_VAL_EXT` for 32-bit; assume 24). Wrap ≈ 4.69 s → only safe with a <2 s poll guarantee; used as bootstrap + fallback.
2. **HPET (primary)**, force-enable sequence (verbatim from research, register-exact):
   1. `rcba = pci_cfg_read32(0:31.0, 0xF0)`; if bit0==0, write back `|1`. `rcba_base = rcba & 0xFFFF_C000`.
   2. ioremap 16 KB UC at `rcba_base`.
   3. `hptc = mmio32[rcba+0x3404]`; write `(hptc & ~0x3) | 0x80` (address-select 00 → 0xFED0_0000, bit7 = decode enable); read back to flush.
   4. ioremap 4 KB UC at 0xFED0_0000; read GCAP_ID (+0x00): expect period ≈ 69,841,279 fs (14.318 MHz) and 3 timers; 0xFFFF_FFFF ⇒ fall back to PM timer permanently.
   5. Write GEN_CONF (+0x10) bit0=1 (ENABLE_CNF), **LEG_RT_CNF=0** (do not steal IRQ0/8).
   6. Main counter (+0xF0), 64-bit, read with hi/lo/hi loop. No comparator IRQs used in v1 (LAPIC does event arming); comparators reserved for the M3 deep-idle experiment.
3. **LAPIC timer**, tick/one-shot event source (not a clock). Runs at bus clock (~70 MHz; **changes if FSB is ever reprogrammed**, recalibrate hook). Calibrated at boot against PM timer over 50 ms.
4. **TSC**, fast relative timestamps only (input events, profiling, IPC tracing): constant 630.113 MHz because we never enter C3 and never change P-states; disciplined against HPET every second; demoted to untrusted if FSB overclock is ever engaged.

**Tickless one-shot**: no periodic tick. The LAPIC timer is armed to `min(current quantum end, earliest sleep deadline, PM-wrap guard when HPET absent)`. Idle with no deadlines arms nothing, pure IRQ wakeup. Timekeeping never depends on ticks (HPET is free-running). This removes ~250–1000 wakeups/s of overhead on a machine where every cycle and milliwatt counts, at ~100 lines of extra complexity over a periodic tick.

**Wall clock**: RTC (0x70/0x71) read once at boot (UIP-wait, BCD decode, century from ACPI FADT if sane); wall = rtc_boot + monotonic. `clock_wall` returns µs since epoch; RTC written back on explicit `settime` only.

## 6. Interrupts

Bring-up order: mask PIC → LAPIC → IOAPIC → calibrate → enable.
1. **8259 remap+mask**: ICW init to vectors 0x20–0x2F (so spurious IRQ7/15 land identifiably), then OCW1 = 0xFF to both. Never used again (no virtual-wire).
2. **LAPIC** (ioremap UC 0xFEE0_0000; confirm base/enable in IA32_APIC_BASE MSR 0x1B bit 11): SVR (0xF0) = 0x100 | 0xFF (enable, spurious vector 0xFF); TPR (0x80) = 0; LVT LINT0 masked, LVT LINT1 = NMI, LVT error = 0xFD, LVT timer = vector 0x50 one-shot, DCR (0x3E0) = divide-by-1.
3. **IOAPIC** (0xFEC0_0000, IOREGSEL/+0x10 IOWIN): read version reg 0x01 → 24 RTEs. Program each used RTE once at boot: physical dest APIC 0, fixed delivery, trigger/polarity from the MADT. Runtime avoids redirection writes because this firmware co-owns the controller from SMM.

Vector map with IOAPIC: 0x00–0x1F exceptions; **0x20 SCI alone**; 0x30–0x4F non-legacy GSIs; 0x50–0x5F legacy lines; 0x80 int80 syscall gate (DPL3); 0xD1/0xDC keyboard/mouse; 0xE0 timer; 0xFD LAPIC error; 0xFF spurious. SCI occupies the lowest APIC priority class, while kernel input and timekeeping outrank every deferred userspace vector. PIC fallback retains its conventional 0x20–0x2F range.

GSI table for this machine (MADT overrides applied):

| GSI | Source | Trig/Pol | Consumer | Confidence |
|---|---|---|---|---|
| 1 | i8042 KBD | edge/high | kernel input | HIGH |
| 2 | PIT (ISA IRQ0 override) | edge/high | calibration only, then masked | HIGH |
| 8 | RTC | edge/high | unused (boot-only reads) | HIGH |
| 9 | ACPI SCI | level (polarity from MADT at runtime; research says high) | userspace platd | HIGH |
| 12 | i8042 AUX | edge/high | kernel input | HIGH |
| 14 | ata1 (no devices) | edge/high | unused | HIGH |
| 15 | ata2: SSD | edge/high | kernel PATA | HIGH |
| 16,18,19 | UHCI (PIRQ A/C/D) | level/low | usbd | MEDIUM (701SD dump) |
| 23 | EHCI + UHCI#1 (PIRQ H) | level/low, shared | usbd | MEDIUM |
| 16–23 | HDA, wifi (01:00.0), ethernet (03:00.0) via PIRQ links | level/low | sndd/netd | LOW-MEDIUM, resolve at boot |

PCI IRQ resolution: ICH6 PIRQA–H map fixed to GSI16–23. Boot-time resolver: parse `_PRT` with the mini-AML interpreter (platform subsystem); cross-check against the ICH6 PIRQ route registers (LPC cfg 0x60–0x63/0x68–0x6B) and the device's Interrupt Line register; log all three. If they disagree, trust PIRQ registers. This is a named bring-up validation item.

EOI protocol: edge → LAPIC EOI in the low-level handler. Level → defer LAPIC EOI, signal the sole owner, and retire the deferred EOI only after `irq_ack`. This avoids runtime IOAPIC writes while preventing redelivery before userspace clears the device. An ownerless asserted level remains quarantined; SCI's dedicated low priority class limits that quarantine to SCI itself.

## 7. Syscalls & IPC

### 7.1 SYSENTER ABI

MSRs at boot: IA32_SYSENTER_CS (0x174) = 0x08; IA32_SYSENTER_EIP (0x176) = `sysenter_entry`; IA32_SYSENTER_ESP (0x175) = current thread kstack_top (rewritten each switch). SYSENTER clears IF; entry stub switches to kstack (already in ESP via MSR), pushes user ECX(=user ESP)/EDX(=user return EIP), re-enables IF, dispatches.

Convention: EAX = syscall #; args in **EBX, ESI, EDI, EBP** (≤4 register args; wider calls pass a pointer to an argument struct); returns EAX (negative errno) + EDX (high half of u64 results). Timeouts are u32 µs (0xFFFF_FFFF = infinite). Return path: `sti; sysexit` with ECX/EDX restored. **int 0x80 fallback**: same register convention, IDT gate DPL3, used by early bring-up and by any tooling that predates the vsyscall stub; libc always uses the SYSENTER stub.

### 7.2 Syscall table (grouped, Zig)

```zig
pub const Sys = enum(u32) {
    // process 0x00
    proc_spawn = 0x00, proc_exit, proc_wait, proc_kill,
    thread_create, thread_exit, thread_sleep_until, yield_,
    // memory 0x10
    vm_map = 0x10, vm_unmap, vm_protect, shm_create, shm_map, shm_unmap,
    // handles 0x20
    h_close = 0x20, h_dup,
    // ipc 0x28
    chan_create = 0x28, chan_call, chan_recv, chan_reply,
    ev_create, ev_signal, ev_wait, wait_many, timer_set,
    svc_register, svc_open,
    // time 0x38
    clock_mono_us = 0x38, clock_wall_us, clock_settime,
    // fs/io 0x40
    open = 0x40, read, write, seek, fstat, readdir, mkdir, unlink,
    rename, mount, unmount, fsync, ioctl, ftruncate,
    // driver (Caps.driver required) 0x60
    pci_cfg_read = 0x60, pci_cfg_write, map_mmio, ioport_grant,
    dma_alloc, dma_free, irq_attach, irq_ack, ublk_register,
    // debug 0x70
    klog = 0x70, klog_read, lastpanic_read, kstats,
};

pub const Handle = u32; // index(24) | generation(8); 0xFFFFFFFF = invalid

// representative signatures (userspace view; isize<0 = -errno)
extern fn sys_proc_spawn(args: *const SpawnArgs) isize;            // returns process handle
extern fn sys_chan_call(ch: Handle, send: *const Msg, recv: *Msg, timeout_us: u32) isize;
extern fn sys_chan_recv(ch: Handle, msg: *Msg, timeout_us: u32) isize; // returns txid
extern fn sys_chan_reply(ch: Handle, txid: u32, msg: *const Msg) isize;
extern fn sys_ev_wait(ev: Handle, timeout_us: u32) isize;          // returns count since last wait
extern fn sys_wait_many(hs: [*]const Handle, n: u32, out_idx_mask: *u32, timeout_us: u32) isize;
extern fn sys_vm_map(len: u32, prot: u32, flags: u32) isize;       // returns vaddr (demand-zero anon)
extern fn sys_shm_map(shm: Handle, prot: u32) isize;               // returns vaddr
extern fn sys_map_mmio(paddr: u32, len: u32, flags: MmioFlags) isize; // vaddr; flags.wc → MTRR path
extern fn sys_dma_alloc(len: u32, flags: DmaFlags) isize;          // fills DmaFlags.out {vaddr,paddr}
extern fn sys_irq_attach(gsi: u32) isize;                          // returns irqevent handle
extern fn sys_irq_ack(irqev: Handle) isize;

pub const SpawnArgs = extern struct {
    path: [*:0]const u8, argv: [*]const [*:0]const u8, argc: u32,
    envp: [*]const [*:0]const u8, envc: u32,
    grants: [*]const Handle, ngrants: u32,   // become child handles 0..n-1 (0/1/2 = stdio by convention)
    prio: u8, caps_mask: u32,                // caps ⊆ parent caps
};
pub const Msg = extern struct {
    op: u32, len: u32,           // len ≤ 64
    data: [64]u8,
    nhandles: u32, handles: [4]Handle,
};
```

### 7.3 Channels

Kernel object: `Chan` = two endpoints; each endpoint has a FIFO of blocked callers and at most a set of blocked receivers. `chan_call`: validate/detach handles (TRANSFER right; handles MOVE, caller loses them; `h_dup` first to keep), copy 64+16 B into the caller's Thread slot, block; if a receiver is waiting → **direct switch** to it (bypasses run queue; the server inherits `max(caller prio, own prio)` for the duration of the transaction, priority donation prevents the GUI blocking behind a `normal` server). Receiver gets msg + `txid` (index into a per-channel 32-entry in-flight table). `chan_reply(txid)` copies the reply into the still-blocked caller and direct-switches back if donation applies. Timeout: applies while queued (dequeue → ETIMEDOUT) and optionally to reply (poisons txid; server's late reply gets EPIPE). **Death notification**: endpoint owner exit ⇒ peers' pending calls return ECONNRESET; the surviving endpoint becomes level-signaled with `CHAN_PEER_GONE` (visible to `wait_many`), which is how devmgr notices a dead server. Msg copies are 80 B through a kernel bounce, two copies total, ~200 ns; not worth mapping games.

### 7.4 Events, wait_many, timers

`Event`: 32-bit sticky counter; `ev_signal` increments (saturating) + wakes; `ev_wait` returns-and-zeroes. `wait_many(≤16)`: arms waiters on each object (events, channels-receivable, irqevents, process-exit), returns bitmask of ready indices; O(n) arm/disarm, n≤16, fine. `timer_set(ev, deadline_us, period_us)` binds a kernel timer to an event (period 0 = one-shot), this is how sndd gets its 20 ms cadence and the compositor a frame pacer if vblank is off.

### 7.5 Shm ring spec (shared by ublk/audio/net/gui)

```zig
pub const RingHdr = extern struct {          // one per direction, 64B-line separated
    magic: u32 = 0x45455247,                 // "GREE"
    version: u16, flags: u16,
    entry_size: u32,                         // pow2 bytes/slot
    capacity: u32,                           // pow2 slot count
    _pad0: [48]u8,
    head: u32, need_wake_cons: u32, _pad1: [56]u8,   // producer line
    tail: u32, need_wake_prod: u32, _pad2: [56]u8,   // consumer line
};
```
Indices are free-running u32; slot = `idx & (capacity-1)`; occupancy = `head - tail` (wrap-safe). Producer: if full → set `need_wake_prod=1`, re-check, `ev_wait(space_evt)`. Publish: write slot, then store head (x86 TSO, single core, plain stores, no fences), then `if (xchg(&need_wake_cons, 0) == 1) ev_signal(data_evt)`. Consumer mirrors with tail/space_evt. Each ring instance is an shm object + 2 event handles passed over a channel at setup. Byte-stream mode (audio): entry_size=1, indices are byte offsets.

## 8. Handles

`HandleTable`: per-process array (64 entries, grows ×2 to 1024 max), entry = `{obj: *KObj, type: u4, rights: u16, gen: u8}`; handle value = index|gen<<24. Rights bits: `DUP, TRANSFER, READ, WRITE, MAP, SIGNAL, WAIT, CALL, MANAGE`. `h_dup(h, new_rights)` requires DUP and `new_rights ⊆ rights`. Message transfer: handles are validated for TRANSFER, detached from sender atomically at send, attached to receiver at delivery (or refunded to sender on ECONNRESET/timeout-before-delivery). All KObjs are refcounted; `h_close` decrements.

## 9. User-driver API (the contract servers consume)

Privilege: `Caps.driver` set at spawn by devmgr (itself granted by init's manifest). Every syscall below checks it. **No IOMMU: a driver server with dma_alloc can overwrite the kernel. Servers are trusted code that we restart for robustness, not a security boundary. This is a documented, deliberate posture.**

- `pci_cfg_read/write(bdf: u32, off: u16, width: u8)`: via ECAM (ioremap of 0xE000_0000 + bus<<20; buses 0–3 pre-mapped = 4 MB). devmgr policy restricts each server to its granted BDFs (kernel keeps a per-process BDF allowlist installed by devmgr via a MANAGE channel op). Config writes to bridges denied except devmgr itself (wifi hot-unplug rescan needs root-port pokes).
- `map_mmio(paddr, len, flags{uc, wc})`: UC = PTE PCD=1|PWT=1 (correct without PAT). **WC for the framebuffer: MTRR, not PAT** (no PAT on Dothan). Kernel MTRR service: on the first `.wc` request covering 0xD000_0000 it programs one variable MTRR pair: check MTRRcap (MSR 0xFE) WC bit10; sequence: `cli; CR0.CD=1; wbinvd; disable MTRRs (MSR 0x2FF bit11=0); PHYSBASE_n (0x200+2n) = 0xD000_0000|0x01 (WC); PHYSMASK_n (0x201+2n) = (~(0x1000_0000-1)) & 0xF_FFFF_FFFF | (1<<11); re-enable; CR0.CD=0; sti`. 256 MB aperture is naturally aligned, exactly one MTRR. PTEs over it stay WB (MTRR WC + PTE WB ⇒ effective WC). Non-aligned WC requests → EINVAL (only the aperture qualifies).
- `ioport_grant(base, len)`: **TSS IOPB** (chosen over syscall-mediated I/O). Rationale: only usbd (UHCI) and possibly platform tools need ports; direct `in/out` keeps UHCI simple and fast; cost is one 8 KB bitmap. Implementation: single TSS with full 8 KB IOPB, default all-1s (deny); kernel tracks an "IOPB owner", the bitmap is rewritten lazily only when switching TO a thread whose process has grants and isn't the current owner (memcpy of the process's shadow bitmap, ~8 µs; owner changes are rare since usbd is the only heavy user). CPL3 `in/out` on granted ports then runs at native speed; syscall-mediated fallback (`sys_io_rw`) exists for one-off pokes.
- `dma_alloc(len, flags{boundary64k, below_16m(unused), zero}) → {vaddr, paddr}`: contiguous, <4 GB trivially (all RAM is), mapped into the server as WB (x86 DMA is cache-coherent), also usable as ring backing. `dma_free` on exit is automatic (tracked per-process).
- `irq_attach(gsi) → irqevent`: kernel installs the RTE (trigger/polarity from the GSI table), leaves it masked until first `ev_wait`. Level GSIs: handler masks+EOIs+signals; server processes then `irq_ack(irqev)` → unmask when all sharers acked (§6). Edge GSIs: EOI+count. On process death: detach, and if a level GSI has zero attachers it stays masked (safe default; devmgr restarts the server which re-attaches). Wifi power-gate: netd must treat `0xFFFF_FFFF` config reads as device-gone and drop its irq_attach; the GSI quarantine (§6) is the backstop.

## 10. In-kernel driver registries (Zig comptime)

```zig
// iface definitions (kernel-internal, stable within a release)
pub const BlockDev = struct {
    name: []const u8, sectors: u64, ssize: u32,
    read: *const fn (self: *BlockDev, lba: u32, n: u32, buf: []u8) BlkErr!void,
    write: *const fn (self: *BlockDev, lba: u32, n: u32, buf: []const u8) BlkErr!void,
    flush: *const fn (self: *BlockDev) BlkErr!void,
    ctx: *anyopaque,
};
pub const BlockDriver = struct {
    name: []const u8,
    probe: *const fn () ?*BlockDev,       // returns null if hw absent
};
pub const DisplayDev = struct { modeset: ..., surface: ..., vblank_event: ..., flip: ... };
pub const InputSource = struct { name: []const u8, start: *const fn (*InputCore) anyerror!void };
pub const FsDriver = struct { name: []const u8,
    mount: *const fn (dev: ?*BlockDev, flags: u32) FsErr!*Superblock };

// registry: comptime-validated, zero runtime cost
pub fn Registry(comptime T: type, comptime decls: []const T) type {
    comptime for (decls) |d| {                       // duplicate-name check at compile time
        var n: u32 = 0;
        for (decls) |e| { if (std.mem.eql(u8, d.name, e.name)) n += 1; }
        if (n != 1) @compileError("duplicate driver: " ++ d.name);
    };
    return struct {
        pub const all = decls;
        pub fn byName(name: []const u8) ?T { inline for (all) |d|
            if (std.mem.eql(u8, d.name, name)) return d; return null; }
    };
}
// board wiring, the ONLY file that differs between qemu and eee701 builds:
pub const blk_registry  = Registry(BlockDriver, &.{ ramdisk.driver, ata_piix.driver, ublk.driver });
pub const fs_registry   = Registry(FsDriver, &.{ fat.driver });
pub const disp_registry = Registry(DisplayDriver, &.{ board.display });   // gma900 | bochsvbe
pub const input_registry= Registry(InputDriver, &.{ i8042.driver, acpi_hotkey.driver });
```
`board.zig` is selected by `-Dboard=eee701|qemu` and swaps GMA900↔Bochs-VBE display, adds a 0x3F8 serial klog sink on qemu, etc. his is the QEMU test seam.

## 11. VFS, page cache, ublk

### 11.1 VFS core

`Vnode{ino, type, size, ops, sb, refs}`; `Superblock{fsdrv, blockdev, root, gen}`. Mount table: fixed 8 entries `{path, sb}`, enough for `/`, `/etc`, `/home` and a few volumes under `/media`. Path walk: component-wise, mount-crossing at boundaries, `..` clamped at root, max depth 32, path ≤ 512 B, **no symlinks in v1** (revisit M3). fd = handle of type file (`FileObj{vnode, off, oflags}`), so stdio grants are just handles 0/1/2. The service registry is reached by syscall rather than by path: `svc_register(name, chan)`, `svc_open(name, timeout)` → dup of the registered channel, and a listing for the `svc` tool. There are no device files; hardware is reached through a capability granted at spawn.

### 11.2 Page-cache-lite: read cache, write-through

Block-granular read cache: key `(sb_gen, blockdev, lba4k)` → frame; open-addressed hash (4096 entries), LRU eviction, **cap 4 MB** (tunable via kstats). Reads ≥128 KB sequential bypass the cache (streaming detection: 3 consecutive misses in ascending order) to avoid flushing it during media playback.
**Writes are write-through** (update-or-invalidate cached copy, then submit): the SSD lies about nothing we can verify (SM223 internals unknown, FLUSH CACHE (0xE7) is optional in ATA-4 and may abort, treat command-abort as success-with-log), the battery/DC-jack yank risk is real, and vibeee's write volume is tiny (config saves, user documents, / is read-only RAM). Write-back caching would buy latency hiding for exactly the workload we don't have, at crash-consistency cost. The 1-3 MB/s random-write cliff is avoided rather than smoothed: nothing here writes at that rate.

### 11.3 ublk, userspace block provider protocol (full spec)

usbd registers SD-reader/USB-stick media: `ublk_register(info: *const UblkInfo, shm: Handle, sq_evt: Handle, cq_evt: Handle) → ublk_id`. Requires `Caps.ublk_register`. The shm region layout (single object, kernel maps it too):

```
0x0000  UblkInfo   { magic 'UBLK', ssize u32, sectors u64, max_sect_per_req u16 (=128), sq_slots u16 (=64), cq_slots u16 (=64), data_slots u16 (=16) }
0x0040  SQ RingHdr (entry_size=32, capacity=64)            // kernel = producer
0x0140  SQ slots: 64 × UblkReq (32 B)                      // 0x0140–0x0940
0x0940  CQ RingHdr (entry_size=16, capacity=64)            // server = producer
0x0A40  CQ slots: 64 × UblkCpl (16 B)
0x1000  slot allocation bitmap (kernel-private mirror kept in-kernel; region bytes unused)
0x10000 data arena: 16 × 64 KB slots                        // total region = 0x110000 (1.06 MB)

UblkReq = extern struct { tag: u16, op: u16 /*0=read,1=write,2=flush*/, lba: u64, nsect: u32, dslot: u16, _r: [14]u8 };
UblkCpl = extern struct { tag: u16, status: u16 /*0=ok, else errno*/, _r: [12]u8 };
```
Kernel-side `ublk.BlockDev.read/write`: split into ≤64 KB ops; acquire data slot(s); for writes copy caller data into the slot first; enqueue UblkReq, signal per ring protocol; block calling thread on cq_evt with **5 s timeout**; on completion copy read data out to the caller. The extra copy costs <1% at USB2 storage speeds and avoids user-page pinning entirely. Flush maps to SCSI SYNCHRONIZE CACHE in usbd. Ordering: kernel guarantees it never issues a write for a region with a read in flight (VFS serializes per-file; cache updates before submit).
Death/removal: server exit or `ublk_unregister` ⇒ all in-flight complete ECONNRESET, BlockDev marked dead, mounts on it forced into errors-on-touch, `devfs` node removed, event to devmgr → usbd restart → re-register creates a NEW ublk_id + sb_gen (stale cache keys die naturally); automounter (userspace) remounts /data.

## 12. ELF loader, stack/TLS

**Fixed-base static ET_EXEC** (base 0x0804_8000), not PIE. Rationale: ASLR is theater on a machine with no NX and trusted-DMA servers; PIE costs a relocation pass (+code, +boot time per spawn) and ~2–5% size in GOT-relative addressing. Loader: validate EM_386/ET_EXEC, PT_LOAD within user range; text/rodata pages mapped **shared RO from ramfs frames** (zero copy); data copied eagerly; bss demand-zero. PT_TLS: per-thread TLS block allocated atop the stack region; GDT[6] base = tls_block; `gs:0` = self-ptr (Zig/LLVM i386 convention). Initial stack (64 KB, grown on fault into a 1 MB reservation and handed back on the way out of a syscall once the pointer has climbed away; `lib/stack.zig` decides both and is tested on the host): `[argc][argv*][NULL][envp*][NULL][auxv: AT_PAGESZ, AT_PHDR, AT_ENTRY, AT_NULL][strings]`. Grants land as handles 0..n-1 before entry.

## 13. Panic & debug (no serial port)

1. **Framebuffer panic console**: panic path draws directly to whatever the display driver last configured (kernel keeps `{fb_vaddr, pitch, w, h, bpp}` in a pinned struct; a compiled-in 8×16 PSF font, 4 KB). Pre-modeset panics fall back to VGA text 0xB8000 (BIOS leaves 80×25 alive). Dump: reason, EIP/CR2/registers, last 8 klog lines, stack words. Then: wait 30 s showing the screen → warm reboot via 0xCF9=0x06 (keyboard-controller 0xFE pulse as fallback).
2. **Persistent panic ring**: top 64 KB of usable RAM is reserved out of the allocator; page 0 of it = panic ring `{magic 'EPAN', seq u32, len u32, crc32, text[4080]}`. Panic appends before drawing. On boot, kernel checks magic+crc, if valid, copies to /tmp/lastpanic and exposes `lastpanic_read`; then re-arms. **Risk (MEDIUM): AMI POST may scrub RAM on warm reboot; BootBooster shortens POST and improves odds. Bring-up test #1 on real HW: write pattern, warm-reboot, check.** If RAM doesn't survive, fallback plan: stash panic text in RTC CMOS spare bytes (~100 B, truncated reason+EIP) and/or a reserved sector written raw via polled PIO (last resort, sync, no interrupts).
3. **klog**: 64 KB ring in kernel memory, readable via `klog_read`, mirrored to an on-screen console (toggle hotkey via GUI) and to COM1 0x3F8 on the QEMU board build only.
4. **EHCI debug port**: ICH6 EHCI implements the Debug Port capability (HCSPARAMS debug-port number nonzero per ICH6 datasheet: MEDIUM until read on HW). It requires a Net20DC-class debug dongle and lands on ONE specific physical port (mapping unknown: LOW). Verdict: **evaluate in M2 (read HCSPARAMS, identify the port), do not depend on it**; the panic ring + fb console are the primary story.
5. **QEMU-first strategy**: everything except GMA900 modeset, ath5k, atl2, EC/ACPI-quirks runs in QEMU (`-M pc -cpu pentium-m-ish (pentium2+sse2 flags) -m 512`): PATA secondary channel at 0x170/IRQ15 exists, i8042, UHCI/EHCI, intel-hda IS ICH6 (8086:2668), Bochs-VBE display behind DisplayDev. GDB stub + `-d int` for triple-fault hunts. Host-native `zig test` covers phys/slab allocators, ring protocol, handle table, path walk (pure logic, no HW).

## 14. RAM & kernel binary budgets

Kernel idle RAM (counts against the 48 MB system budget): image ~0.9 MB • heap cap 4 MB (vnodes, threads, channels; expected ~1.5 used) • page cache cap 4 MB • kstacks ~0.5 MB (48 threads) • page tables ~0.6 MB (24 processes) • ioremap PTs 0.26 MB • IOPB/GDT/IDT/misc 0.1 MB • klog+panic 0.13 MB ⇒ **cap ~10.5 MB, expected ~7 MB**. (RAM-rootfs ≤24 MB is accounted to the rootfs, not the kernel.)

Kernel ELF ≤1.5 MB, allocation (text+rodata, ReleaseSmall estimates): entry/stubs 8K • mm 40K • sched/proc 36K • syscall/IPC/handles 28K • time 12K • interrupts 12K • ACPI tables + mini-AML interpreter 160K (largest risk; hard cap 256K) • EC/platform/hotkeys 20K • PATA 14K • GMA900 modeset 56K • i8042+input core 16K • VFS core 32K • FAT 28K • page cache 8K • ublk 10K • PSF font 4K • panic/fbcon/klog 18K • Zig rt/compiler-rt 24K ⇒ **~514 KB, ~2.9x headroom**. Enforced by a Make size gate per milestone (fail build if ELF > budget).

## 15. Bring-up & test plan

| Stage | QEMU | Real 701 |
|---|---|---|
| Boot/mm/GDT/IDT | gdbstub, triple-fault logs | fb/VGA text prints; panic ring test (warm-reboot survival) FIRST |
| Timers | PIT/HPET(QEMU has HPET natively) | PM-timer vs HPET force-enable cross-check; measure LAPIC timer = ~70 MHz bus |
| Interrupts | i8042/ATA IRQs | verify GSI table: fire each device, log vector; resolve PIRQ→GSI for HDA/wifi/eth (three-way check §6) |
| Syscall/IPC | unit tests + latency bench (call/reply target <5 µs) | same binaries |
| PATA | qemu ide secondary | UDMA/66 vs fallback PIO; FLUSH-abort handling; 4K random-write soak |
| ublk | qemu usb-storage via usbd | internal SD reader (boot device!) re-attach cycle |
| Display | Bochs VBE DisplayDev | GMA900 driver (display subsystem); kernel only validates MTRR-WC path (bench: memcpy to FB with/without WC, expect ~4× ) |
| Panic | forced panics, klog_read | lastpanic after real panic; EHCI debug port HCSPARAMS read (M2) |

Self-test mode: `boot arg selftest=1` runs allocator/IPC/VFS test suites at boot and prints pass/fail to fb, usable on real HW without any debugger.

## 16. Risks & open questions

- **PIRQ→GSI for HDA/wifi/ethernet unverified on the 4G** (MEDIUM/LOW): mitigated by triple-source boot-time resolution + hardware validation item. Worst case: mini-AML _PRT parse is mandatory earlier than planned.
- **Panic RAM survival across warm reboot unproven** (MEDIUM): fallback CMOS/raw-sector paths specced (§13.2).
- **Mini-AML interpreter scope creep**: needed for _PRT, EC _Qxx→Notify, battery/SCI methods. Cap at 256 KB; if it bloats, hardcode the 701 DSDT paths (extract DSDT once, precompile the 6 methods we call into a table, this machine never changes).
- **SM223 FLUSH CACHE may be unimplemented** (ATA-4 optional): treat abort as no-op + log; nothing may rely on a barrier having happened.
- **MTRR WC + VGA range interaction**: fixed-range MTRRs below 1 MB left as BIOS set them; only the 0xD000_0000 variable range is touched.
- **FSB overclock (future)** would change TSC and LAPIC-timer rates: recalibration hooks exist; TSC demoted when engaged.
- Open: does wait_many need edge-vs-level semantics per handle type for the GUI server's main loop? (current: channels level-readable, events sticky-counted, believed sufficient).
- Open: SD-boot media and ublk, the BOOT SD sits in the internal USB reader; kernel boots from RAM so the reader can be reset by usbd later. Handoff protocol (when usbd claims EHCI, BIOS legacy USB must be disabled: EHCI legacy-support handoff via EECP semaphore) is usbd's job, kernel provides pci_cfg access for it; noted here as cross-subsystem dependency.
- Open: `Caps` growth, is a bitmask enough for v1 (yes, claimed) or do we need per-BDF/port grant objects (devmgr allowlist covers it).

## 17. Phasing

- **M1 (boots, computes, talks)**: NASM entry + GDT/IDT, 2-level paging + linear map, bitmap phys alloc, slab heap, threads + strict-prio sched + tickless LAPIC, PM-timer clock, PIC mask + LAPIC/IOAPIC + GSI 1/2/12/15, SYSENTER + int80 + full handle/channel/event/wait_many/shm-ring IPC, ELF loader + spawn, ramfs + devfs + VFS core, PATA PIO→UDMA, i8042, VGA-text+fb klog, panic ring + selftest. QEMU parity build.
- **M2 (drivers live)**: HPET force-enable + clock ladder, MTRR-WC + full user-driver API (ECAM, IOPB grants, dma_alloc, irq_attach level protocol), ublk + FAT, page-cache-lite, svc registry, priority donation, PIRQ resolution + mini-AML _PRT, EHCI debug-port evaluation, size gates enforced.
- **M3 (polish/hardening)**: eeefs integration, IRQ storm quarantine + server-death drills (kill usbd during I/O soak), rt-class runaway guard tuning with sndd underrun telemetry, optional C2/C3 experiment behind boot flag, CMOS panic fallback if RAM test failed, wait_many semantics revision if GUI needs it.

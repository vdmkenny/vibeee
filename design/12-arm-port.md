# 12. ARM port: bring-up plan

The second-architecture proof, aimed at the ARM netbooks of the CE era. Status:
**planned, not started.** The build plumbing exists and the x86 build is untouched;
the arm build fails by design until the pieces below land.

## 1. Target device class

The flagship target's ARM sibling: the **VIA VT8500 / WonderMedia WM8505** Windows
CE netbooks of 2009 (MenQ EasyPC E760, EasyTC E3 and their many rebadges). Same
shape as the 701's era, same budgets:

| | Eee PC 701 | VT8500 class |
|---|---|---|
| Core | Celeron M Dothan, 630 MHz | **ARM926EJ-S, 300–400 MHz** `[HIGH]` |
| RAM | 512 MB | **128 MB** `[HIGH]` |
| Panel | 800×480 LVDS | 800×480 TTL `[MED]` |
| OS shipped | Xandros | **Windows CE 6.0** |
| Boot | BIOS + USB-SD | vendor IPL, NAND/SD `[MED]` |

The one fact the whole plan hangs on: **QEMU's `versatilepb` presents an
ARM926EJ-S** — the same core, same MMU (ARMv5TEJ short-descriptor VMSA), same
instruction set. QEMU also carries `imx25-pdk` (another ARM926 board) as a second
opinion, and `collie` (SA-1110, ARMv4) as the purity check that no ARMv5-only
instructions leaked into the portable core. Verified against QEMU 11.1.0 on this
machine. Nothing above is hardware fact until it is probed on a real device;
QEMU is the sanity target, not the product.

## 2. Build plumbing (done)

- `Makefile`: `ARCH ?= x86`, threaded to `zig build -Darch=...`. `make ARCH=arm qemu`
  boots the kernel directly: `qemu-system-arm -machine versatilepb -cpu arm926
  -m 256M -display none -serial stdio -kernel zig-out/bin/vibeee.elf`. The SD
  image pipeline (`image`, `dev-image`, `sd`, `qemu-panic`) is x86-only and
  refuses with a message rather than building a useless MBR.
- `build.zig`: `-Darch` selects the target once, everywhere. arm = `arm926ej_s`,
  freestanding, `.eabi` (soft float — the core has no VFP). Both kernel and
  userspace share the model on arm, since there is no FPU state to save.
- The arm build currently fails exactly where it should: `start.zig`'s
  architecture switch and the x86 user stub. That is the honest state until §4.

## 3. Style rules for the port

1. **Zig-native only.** Enums, unions, packed structs, comptime where the x86
   code uses comptime. No C-shaped code: no tagged raw pointers where a union
   names the case, no magic-number tables where a packed struct can say what the
   bits mean. The HAL is the contract; the arm side is a Zig implementation of it.
2. **No assembly outside `src/arch/`.** Enforced already by `check-layering.zig`;
   the arm port keeps the rule by putting its exception vectors, context switch
   and MMU enable in `src/arch/arm/` as the x86 side does in `src/arch/x86/`.
3. **`kernel/` must not import `arch/`.** It already does not; the port's test
   is that the layering check stays green throughout.

## 4. The bring-up, in order

Each step is small and each ends with something that boots.

| Step | Content | Proves |
|---|---|---|
| 4.1 | `src/arch/arm/linker.ld`, `start.zig` arm branch, a stub `kmain` printing via PL011 | QEMU loads the image, vectors land, UART speaks |
| 4.2 | `src/arch/arm/cpu.zig` (CPSR, CP15), `paging.zig` (VMSA short descriptors, kernel linear map), `initCpu` | MMU on, C-linked kernel at its virtual base |
| 4.3 | `src/arch/arm/irq.zig` (PL190 VIC), `timer.zig` (SP804), `initInterruptController`, `initTimer` | `clock.zig` advances; the boot self-tests `main.zig` already runs (heap, syscall ABI, clock advance) pass |
| 4.4 | `context.zig` (callee-saved switch, SVC stacks), scheduler start | The preemption workers interleave |
| 4.5 | `usermode.zig` (SVC-mode entry to ring-equivalent user mode), `syscall_arch.zig` (SWI), user-side `arch/arm/syscall.zig` | IPC self-test, `init` spawns, shell over serial |
| 4.6 | PL111 framebuffer + PL050 keyboard as drivers, replacing the x86 console/input binding | The existing console and `eeewm` run at 640×480 |
| 4.7 | `-M collie` (ARMv4) boot of the same kernel | No ARMv5-only instructions in portable code |
| 4.8 | A real VT8500 device, probed like the 701 was | The product |

The ordering is the same trick the x86 milestones used: every step is a
diagnosable state, and QEMU's serial port means a real log from the first byte,
where the 701 forced the QR-and-ring apparatus.

## 5. What the arm port is allowed to change

- `src/arch/arm/**`, new. The whole architecture.
- `src/start.zig`: add the arm branch to the existing switch.
- `src/kernel/hal.zig`: add the arm branch; also make `inl`/`outl` conditional on
  the port-IO capability rather than unconditional, and have `pcicfg.zig` refuse
  on a machine with no port I/O — arm has no PCI config ports at all.
- `src/kernel/elf.zig`: accept `.arm` machine tags in the loader check.
- `src/user/syscall.zig`: switch on arch for the trap stub, like `start.zig` does.
- A new `src/board/` for the machine data (UART base, RAM layout), because a CE
  device has no ACPI, SMBIOS or MADT: the board supplies what firmware tables do
  on x86. This is the `board/` directory design/00-vibeee.md §3 promised; the
  port is what forces it to exist.

Everything else — sched, wait, channel, event, shm, handle, vfs, fat, bcache,
console grammar — must compile untouched. That is the definition of the proof.

## 6. Non-goals

No CE-specific devices (NAND, touchscreen, audio codecs), no Thumb, no
big-endian, no SMP, no 64-bit, no dynamic linking. QEMU first and only, until
4.8. This document is the plan; a step is done when its QEMU state boots.

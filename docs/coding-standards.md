# Coding standards

`make check-all` enforces formatting, layering, unused imports and tests. Review
enforces the rest.

## Target

- Eee PC 701: one 630 MHz core, 512 MB RAM, no serial port.
- Scheduler tick: 10 ms.
- Measure speed and timing on this machine, not in QEMU.

## Layout

| Path | Contents |
|---|---|
| `src/arch/` | Architecture code. No driver imports. |
| `src/kernel/` | Kernel core. Architecture access only through `kernel/hal.zig`. |
| `src/drv/` | In-kernel drivers. |
| `src/platform.zig` | Composition root: joins kernel, architecture and drivers. |
| `src/lib/` | Shared by kernel and userspace. No hardware, no syscalls, no imports from either. |
| `src/user/lib/` | Shared by user programs. |
| `src/user/<service>/` | One service and its drivers. |
| `src/quirks/` | Firmware corrections, one module per family. |
| `src/user/platd/vendor/` | Vendor control interfaces, one file each, plus a registry entry. |
| `src/config/` | Image configuration. Build machine only. |
| `apps/` | Programs outside the system image. |
| `third_party/` | Vendored code. Pinned, unmodified. |

- Import rules: [`tools/check-layering.zig`](../tools/check-layering.zig), run by
  `zig build check`. Each exception states its file and reason.
- One concern per module. Other modules through their interfaces only.
- Sequencing across services belongs to the service that owns the affected state.
- Reusable UI controls: `src/user/eui/`.
- Browser features (DOM, `Intl`, fetch): `apps/web/`. Only general code goes in
  `src/lib/`.
- Vendored code is never edited. Adaptations go in a wrapper. New dependencies: verdict
  in [design §11](../design/00-vibeee.md), entry in
  [third_party/README.md](../third_party/README.md).

## Zig

### Format and names

- `zig fmt`, checked by `make fmt`.
- `TitleCase` types. `camelCase` functions. `snake_case` fields, locals and files.
  `SCREAMING_SNAKE_CASE` container-level constants.
- Keywords as identifiers: `@"suspend"`.
- An unused container-level import fails `zig build check`.

### Data types

No masks, shifts, flag constants or numeric offsets in logic.

| Data | Type |
|---|---|
| Bit fields | `packed struct(uN)`. Reserved bits named. |
| Command and code values | `enum(uN)`. Non-exhaustive if most values are data. |
| Alternatives | `union(enum)`. Variant-only fields in the payload, `void` elsewhere. |
| Layout offsets | `@offsetOf` on a struct of the layout. |
| Memory shared with a device | `extern struct`, `extern union`. |
| One value split across fields | One packed struct that joins and splits it. |
| Related constants | Derived from one value, tested against the documented numbers. |
| Errors | Error unions and `errdefer`. No in-band sentinels. |

### Registers

- MMIO: `lib.mmio.Window(Register, Access)`, one window per access width.
- Port I/O: `ulib.ports.Window(Register)`. Width from the value's type.
- `Register`: enum of offsets.
- Each register: a packed struct, read and written whole.

```zig
device.control = .{ .codec_enabled = true, .clock_divider = DIVIDER };
device.window.write(.control, device.control);

const status = device.window.read(regs.Status, .status);
if (!status.interrupt) return .{};
```

### Comptime

- Assert hardware and ABI layouts.

```zig
comptime {
    if (@sizeOf(Hcca) != 256) @compileError("the communications area is 256 bytes");
    if (@offsetOf(Hcca, "done_head") != 0x84) @compileError("the done head is at 0x84");
}
```

- Assert limits that depend on other limits, e.g. usbd's wait set against
  `limits.MAX_WAIT_HANDLES`.
- Tables and bindings at comptime: the syscall table, `hc.unitOps(Driver, unit)`,
  `inline for` over `std.meta.fields`.
- Generics check required declarations with `@hasDecl` and `@compileError`.

### Reuse

- Lookup order: `std`, `src/lib/`, the service's shared modules. In `apps/web/`: lexbor
  and QuickJS first.
- Code used twice goes in a shared module: `lib.mac.fromWords`, `netd/mii.zig`,
  `sndd/pcm.zig`, `usbd/hc.zig`.
- New code that duplicates existing code: merge both in the same change.
- Single-use code stays local.

### Compiler issues

- `@min` and `@max` return the narrowest type that fits. Annotate before arithmetic:
  `const n: usize = @min(a, CAP);`. ReleaseSmall wraps on overflow.
- ReleaseSmall can miscompile runtime size arithmetic. Comptime sizes on ABI
  boundaries: stack frames, wire records. For an offset the source cannot produce,
  disassemble `zig-out/bin/vibeee.elf`.

## Performance and events

Optimize for old, slow, CPU-constrained hardware. Event driven. No busy loops, no
redundant syscalls.

- Block until an event or the earliest pending deadline:
  - No work: `sys.waitMany(handles, sys.FOREVER)`.
  - Work due later: timeout computed from the earliest deadline, not a fixed period.
    E.g. eeewm wakes at the next clock minute or idle step, whichever is first.
  - Work now: do it, no syscall.
- On wake, process all ready work, then block. Never one step per wait.
- Bound work per pass so one source cannot hold the loop. If work remains, run another
  pass before blocking.
- No polling loops, periodic idle wakeups, short timeouts, zero-length waits or yield
  loops.
- Sleeps and timeouts expire at scheduling points, at worst the next 10 ms tick.
- One syscall per batch, not per item: one `waitMany` over all handles, buffered output
  through `ulib.stream`. No syscall whose result is already known.
- Bulk data (surfaces, audio, socket data): shared memory and events. Channels: control
  messages and handles.
- Requests to other processes: bounded.
- Bounded hardware waits: `ulib.device.settles(attempts, pause_us, context, ready)`.
  Checks before each sleep. Each pause expires on a tick: `settles(50, 1_000, ...)` can
  take 500 ms.
- Busy-wait only for deadlines under one tick, with a comment.
- Redraw on state change only, damaged regions only.
- Every pixel a control paints is reported as damage in the same pass. A fill with no
  damage leaves the surface and the screen apart until the next whole blit of the window.
- A control of rows keeps a mark of what each row showed and repaints the rows whose mark
  differs; the whole only when the ground under them changed: scroll, width, focus.
- Nothing walked per pass that the pass cannot have changed: a count over the whole text
  is kept until the text, the caret or the width differs.
- Constant tables: comptime or generated, not computed at runtime.

## Memory and limits

- Fixed sizes close to need. Shared limits:
  [`src/lib/limits.zig`](../src/lib/limits.zig).
- At a limit: rule out a leak or unneeded data. Otherwise double it; the comment states
  what uses the space.
- No silent truncation.
- The build checks shipped files against their limits where possible.
- Driver state: a static, `var device: Device = .{}`. DMA memory: allocated once, at
  open.

## Drivers

- Datasheet delays and timeouts. QEMU completes resets, commands, EEPROM and PHY
  operations instantly; hardware does not.
- Every hardware wait bounded.
- Completion interrupts, not busy-bit polling. No completion signal: next step on the
  next event.
- Interrupt handlers service the device until the cause register reads zero. 701 PCI
  interrupts are edge-triggered; a cause bit left set raises no new interrupt. See
  netd's `dev.serveIrq`.
- Handle every capability bit, including bits QEMU leaves clear: 64-bit BARs, 64-bit
  descriptor formats.
- Match the whole family: every device ID, including rebranded and chipset-integrated
  parts, or the class code for a standard interface. Declared in
  [`src/lib/driver.zig`](../src/lib/driver.zig). `zig build driver-manifests` writes
  `drivers/*.man`.
- Files: `<driver>.zig` for I/O, `<driver>/regs.zig` for register and descriptor
  types, one file per shared-memory state machine (rings, queues).
- Implement the service's operations table: `NicOps`, `HcOps`, `PcmOps`. Code shared by
  drivers goes in the service's common module.
- Capabilities: `driver` only.
- Devices QEMU emulates get an end-to-end step in
  [`tools/check-all.sh`](../tools/check-all.sh).

## Pure logic

- Decisions on data from a device or medium: separate file, no I/O. E.g.
  `kernel/fat/verdict.zig`, `kernel/elf/plan.zig`, `user/netd/rxpage.zig`,
  `user/netd/e100/rings.zig`, `user/usbd/ohci/queue.zig`.
- Hardware-facing code is generic over its access, so tests pass a model:
  `Queue(slots, Barrier)`, `Eeprom(Pins)`, `PortWindow(Register, Io)`.
- File named for the decision. Outcomes as a union or enum; a test reaches every case.

## Tests

- Host tests: `make test`.
- A test file runs only if `src/tests.zig`, `src/quirks/tests.zig` or the test block in
  `src/lib/lib.zig` imports it by path: `_ = @import("user/netd/e100/rings.zig");`. A
  re-export does not run its tests.
- Every new test: break the code it covers, confirm `make test` fails, restore.
- Expected values from the specification or a reference implementation, never from the
  code under test: ES1370 codec bytes against Linux, the QR encoder against libqrencode.
- Test names state the behaviour: `test "mixing clips instead of wrapping"`.
- Boot self-tests print `fail`. They do not hang.

## Fuzzing

- Targets for all external input: volumes, program images, network frames, manifests,
  registers and shared memory written by devices.
- Target: `fn (fuzzing.Choices) anyerror!void`, from
  [`src/lib/fuzzing.zig`](../src/lib/fuzzing.zig). Two tests each: `std.testing.fuzz`,
  and `fuzzing.seeded` with a fixed seed.

```zig
test "fuzz: a resampled stream is the same however it is cut" {
    const Target = struct {
        fn one(_: void, smith: *std.testing.Smith) anyerror!void {
            return resampleOneStream(.{ .fuzzer = smith });
        }
    };
    try std.testing.fuzz({}, Target.one, .{});
}

test "streams resampled at random" {
    try fuzzing.seeded(resampleOneStream, 0x44_100_48, 500);
}
```

- Input: valid structure with targeted corruption. Never random bytes into a `Smith`.
- Memory shared with a device: fuzz against a device model that takes a random number
  of steps per barrier. Assert each item is processed once, in order, and only after
  the host finishes writing it. Assert pending work completes.
- Model check: inject a bug, confirm the target fails. Confirm the seeded run reaches
  every outcome.
- `make fuzz` is broken on Zig 0.16.0. Seeded tests run under `make test`.
- New targets go in the Testing list in [docs/status.md](status.md).

## User interface

- Every GUI feature has an equivalent command. Settings through cfgd.
- Keyboard: Tab to focus, visible focus, Enter or Space to activate, arrows to move
  (Page Up, Page Down, Home, End in lists), Escape to cancel. Tested with key input.
- Controls: theme styling, libeui focus and damage rules.

## Browser

- `web` is "the browser".
- Behaviour per the standards and mainstream browsers. No hostname, class-name or
  site-specific code.
- Per behaviour: a host test and an isolated test page.
- Renderings checked against a mainstream browser's screenshot of the same page.

## Program names

- System components: `eee` prefix. `eeewm`, `eeelibc`, `eeefetch`.
- Programs people type: short names. `eTerm`, Pad, Files.
- Tools: named for their function, not after other systems' tools. `smbios`, not
  `dmidecode`. Common words are fine: `ls`, `cat`, `top`.
- Ported programs: original names.

## Comments

- What the code does and why.
- Current state only. No history, failed attempts, bugs found or effort. Failure modes
  and constraints are fine: "a node pushed twice links to itself".
- Dry, terse, plain, technical. No inversions, aphorisms, slogans, idioms, wordplay,
  drama or personification.
- No em dashes.
- `//!` header per file: a few short paragraphs on what the module does and its
  structure.
- `///` only where the name is not enough.
- Fix violations in text near an edit.

## Log messages

- `log.fail`: stopped. `log.warn`: degraded. `log.say`: progress.
- Lowercase, no full stop. What failed, and the consequence if not obvious:
  `"cannot read a valid MAC address"`.
- Quiet boot: failures and warnings. `verbose`: one line per component. `debug`: more.

## Documentation

Same rules as comments. Updated in the same commit:

- [docs/status.md](status.md): inventory, tests, fuzz targets, gate steps, known gaps.
- The subsystem's status header in [design/](../design/).
- [README.md](../README.md): features, supported hardware.
- `manual/<command>`: command changes.
- [drivers/README](../drivers/README): manifest format.

Generated files are regenerated, never edited:

| File | Command |
|---|---|
| `docs/syscalls.md` | `zig build syscall-docs` |
| `docs/settings.md`, manual key lists | `zig build settings-docs` |
| `docs/libeui.md` | `zig build eui-docs` |
| `drivers/*.man` for PCI devices | `zig build driver-manifests` |
| `src/lib/fonts/` | `zig build fonts` |
| `src/arch/x86/s3wake.zig` | `zig build s3-trampoline` |

## Gate

- `make check-all` passes before a change is done: `zig fmt --check`, `zig build check`
  (layering, unused imports, x86-64 Linux test build), `make test`, browser document
  tests, both images, QEMU boot checks in `tools/check-all.sh`.
- Default configuration only. `apps/` is not built: after a shared module or protocol
  change, run `make apps`.
- Pass: exit code 0, `Build Summary`, `check-all: everything holds`. A
  `failed command:` line after a passing test step is Zig echoing stderr.
- `build/vibeee-dev.img` keeps `/cfg` and `/home` between runs. Manual sessions use a
  copy. If a boot check also fails with the change stashed, delete it and
  `build/check-sd.img`.
- Harness scripts: one command per line. `vsh` has no `;` or `&&`.

## Commits

- One change per commit. Each passes the gate.
- Subject: imperative, sentence case, no full stop, no prefix.
  `Drive the Intel PRO/100`.
- Body: what changed and why. No account of the work.
- No `Co-Authored-By` or `Generated with` trailers.

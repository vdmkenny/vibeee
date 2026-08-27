# vibeee Userspace Foundations (design/11-userspace.md)

> **Status: partially implemented.**
>
> Built and working: the shell ([`vsh.zig`](../src/user/vsh.zig)) with pipelines, redirection, line editing, history and modular completion; the multicall tools binary ([`tools.zig`](../src/user/tools.zig)); the service supervisor ([`init.zig`](../src/user/init.zig)) and the device manager ([`devmgd/`](../src/user/devmgd/)); the settings store ([`cfgd/`](../src/user/cfgd/)) and the `cfg` tool over it; `eeelibc` ([`libc/`](../src/user/libc/)) and the `eeecc` wrapper, enough that antirez's `kilo` builds unmodified and runs; and the shared userspace helpers in [`src/user/lib/`](../src/user/lib/), including the heap and the buffered streams the C library is a wrapper over.
>
> Not yet: environment variables, package management, and anything that outlives a reboot.
>
> Where this document and [`00-vibeee.md`](00-vibeee.md) disagree, the master design
> wins: it carries later decisions this document predates.

Subsystem: init/service management, devmgd, eeelibc, CLI environment, configuration system, and the build system (Makefiles → dd-able SD image).

## 1. Overview

Userspace is five small, boring, restartable pieces glued by the kernel's channel/handle contract:

- **init (PID 1)**: declarative service manager. Reads manifests, starts services when their dependencies appear in /svc, supervises with backoff + crash-loop breaker + watchdog, orchestrates shutdown in reverse order. Owns the recovery TUI and the console-fallback shell.
- **devmgd**: device→driver matchmaker. Consumes the kernel's PCI table and usbd's hotplug stream, matches against drop-in manifests in /drivers, asks init to spawn (or message) the right driver server with the right privileges. Handles the Fn+F2 wifi hot-unplug without killing netd.
- **eeelibc**: Zig-implemented, C-ABI-exported POSIX-lean libc. Linux errno numbering, no fork (posix_spawn), pthreads-lite over kernel threads + futex-lite, sockets shim over netd IPC. **Everything statically linked** (decision with numbers, §6.6).
- **CLI**: `esh` shell + `eeebox` multicall binary (~40 applets). Lives in the GUI terminal app; a console fallback exists only when the GUI is absent (recovery / GUI crash-loop), no VT switching.
- **Build system**: plain GNU Make, pinned Zig + NASM + mtools + zstd, no root, out-of-tree `out/`, produces `out/vibeee.img` (48 MB, dd-able), `make qemu`, guarded `make sd DEV=`, and an in-system updater that reflashes P1 files + stage2 with journal-protected fallback.

Budget shares claimed here: userspace (excl. GUI subsystem, incl. rootfs skeleton) ≈ 10.5 MB of the 24 MB uncompressed rootfs, ≈ 6.5 MB of idle RAM; boot-time share from kernel-entry to GUI-start-gate ≈ 1.3 s.

## 2. Hardware facts used (confidence per research reports)

- Boot medium is the internal USB SD reader (ENE UB6225, 0951:1606, USB MSC) → **/cfg and /data arrive only after usbd is up**; init must gate mounts on a ublk provider, and usbd crash must not permanently unmount them [HIGH, peripherals §9].
- SSD variant: PATA secondary master 0x170/IRQ15, 28-bit LBA, small random writes 1–3 MB/s → config writes are rare, small, atomic (tmp+fsync+rename); no swap; /tmp is RAM [HIGH, core §4].
- Fn+F2 **power-gates the wifi PCIe slot**, device hot-unplugs; state persists across reboots [HIGH, quirks §3]. devmgd must treat PCI as (rarely) hot-pluggable and re-attach to a *running* netd.
- Camera eb1a:2761 is BIOS-default-disabled + ACPI CAMS-gated [HIGH, quirks §3] → devmgd/policyd expose an enable path; absence of the device is normal.
- MCFG ECAM at 0xE0000000, buses 0–255 [HIGH, core §5], kernel enumerates; devmgd consumes a table (decision §5.1).
- ACPI ASUS010/ATKD hotkeys, battery-percent bug, CFVS hang (never call), acpi_osi gating [HIGH, quirks §1/§5], all handled in-kernel (platform driver); userspace sees clean input events + a power/battery channel. policyd never touches EC/ACPI directly.
- 630 MHz single core, ~1 GB/s memory bandwidth [HIGH, core §1/§3] → single-lock allocator (no per-thread caches), 1 KB stdio buffers, spawn-not-fork, multicall binary to keep icache/rootfs small.
- No serial port [HIGH] → init verbose mode logs to kernel klog ring + VGA text console; `dmesg` applet reads it back.
- Touchpad Synaptics OR Elantech [conflicting, core HIGH vs quirks MEDIUM], irrelevant here except: keymap/input config must not assume pad model (kernel input core abstracts).
- QEMU cannot emulate GMA900/AR2425/atl2/KB3310 → test seams in §10.

## 3. Architecture

```
kernel ── spawns /sbin/init (PID 1, only pre-granted handles: klog, vfs-root, svc-registry-watch)
  init ─┬─ parses /etc/svc/*.svc + /cfg/svc/*.svc (overrides, once /cfg mounts)
        ├─ spawns devmgd ──┬ sys_pci_table() → match /drivers/*.drv → "spawn netd/usbd/sndd" → init
        │                  └ /svc/usb.events (from usbd) → USB matches / uif delegation
        ├─ spawns policyd  (power button→shutdown, lid→sleep policy, battery warnings, camera toggle)
        ├─ mounts /cfg /data  (VFS mount-by-tag; blocks until ublk or PATA provider appears)
        ├─ spawns gui (last; gated on display+input only, config applied late)
        └─ supervises all: restart/backoff/crash-loop/watchdog; shutdown = reverse topo order
apps/CLI ── eeelibc (static) ── SYSENTER syscalls + channels to netd/sndd/init
```

Every service gets, at spawn: a **supervision channel** to init (watchdog pings, ready-notify, shutdown requests travel here), its manifest-granted capability handles, and stdio handles routed to klog. Service discovery is the kernel /svc registry (contract): services register `provides` names themselves after `notify_ready`; init *watches* the registry to trigger dependents (needs kernel `svc_watch()` → event; OPEN-K1).

## 4. init (PID 1)

### 4.1 Boot sequence (from kernel handoff)

1. Kernel has unpacked rootfs→ramfs, mounted `/` (RO), `/tmp` `/dev` `/svc` namespaces per contract, spawned `/sbin/init` with `BootInfo`-derived environment: `boot.flags` (verbose/recovery/backup), `boot.disk_sig` (hex), `boot.from_ssd`.
2. init parses `/etc/svc/*.svc` (rootfs, read-only defaults). `/cfg` overrides are folded in later (step 5), services started before /cfg use rootfs manifests only (by design: driver plumbing must not depend on config).
3. `recovery=1` → skip to recovery TUI (§4.6). Otherwise spawn `devmgd`, `policyd` immediately (no deps).
4. devmgd matches PCI → requests spawns of `usbd`, `netd`, `sndd` (§5). init spawns them per manifest privileges.
5. init issues `mount(tag="boot:p2", "/cfg", eeefs, RW)` and `mount(tag="boot:p3", "/data", eeefs, RW)`. `tag` = `disk_sig` from BootInfo + partition index; VFS blocks the mount until a matching provider registers: PATA (kernel, SSD boot, immediate) or usbd's ublk ring (SD boot, ~0.6 s). Timeout 10 s → boot continues degraded (GUI shows warning; /cfg reads fall back to `/etc/defaults`).
6. When kernel display driver + input core report ready (via /svc names `display`, `input`), init spawns `gui`. GUI does not wait for /cfg: it starts with `/etc/defaults`, subscribes to a "cfg-ready" event from init, re-reads config when it lands (≤1 s later typically). Keyboard layout default us-intl comes from rootfs defaults so even degraded boots type correctly.
7. After 60 s of stable operation (no service in backoff), init acks the boot journal via kernel (`sys_bootjournal_ack()`, kernel writes LBA 2040 through its own path per 01-boot §5.3) and runs the updater commit hook (§9.6).

### 4.2 Service manifest format ("EMF": TOML-lite, one parser in libvibeee)

Grammar: `[section]`, `key = value`, values: bare string, "quoted", integer, bool, comma-list. `#` comments. No nesting, no multiline. Parser ≈ 300 lines Zig, shared by init + devmgd + config files.

```toml
# /etc/svc/sndd.svc
[service]
name = sndd
exec = /drivers/bin/sndd
args =
needs = devmgd            # /svc names that must exist before spawn
provides = audio          # names sndd will register after notify_ready
restart = on-failure      # never | on-failure | always
backoff_ms = 250          # doubles per crash, cap:
backoff_cap_ms = 30000
crashloop = 5/60          # >5 restarts in 60 s -> state=failed
watchdog_ms = 5000        # 0 = disabled; miss 2 pings -> restart
console = klog            # klog | null

[privileges]
caps = pci, mmio, dma, irq
ram_kb = 1536             # advisory; logged+GUI-warned if exceeded, not killed (v1)
```

### 4.3 Supervision semantics

- **Restart with backoff**: exit≠0 or watchdog miss → wait backoff (250 ms → ×2 → cap 30 s), respawn. Clean exit 0 with `restart=on-failure` → stay stopped.
- **Crash-loop breaker**: window counter per manifest; tripped → `state=failed`, event on `/svc/init.events`, GUI toast, `svcctl start <name>` re-arms.
- **Dependency ripple**: when a service dies, init does NOT kill dependents. Dependents' channels to it break (kernel channel-peer-death error); well-behaved clients (libc shims, GUI) reconnect via /svc when the name reappears. Two special cases:
  - **usbd crash must not lose /data**: VFS keeps ublk-backed mounts **frozen** on provider death: new I/O blocks (up to 10 s), in-flight writes are journaled failures reported EIO. Restarted usbd re-enumerates (~1 s), re-registers ublk rings with the same `disk_sig:part` tags, VFS re-attaches, blocked I/O completes. Only a >10 s outage degrades to forced unmount + GUI warning. (Contract addition OPEN-K2.)
  - **gui crash-loop**: breaker trips → init starts the **console fallback shell** (`econ`: kernel text console + esh) so the machine is never a brick. Exit of econ retries GUI.
- **Watchdog**: supervised service sends `watchdog_ping` on its supervision channel; init checks lazily on a 1 s timer tick. Drivers ping from their main event loop, so a wedged IRQ loop is caught.

### 4.4 Shutdown / reboot orchestration

`svcctl poweroff|reboot|recovery` or policyd (power button, lid policy, battery critical) → init:
1. Broadcast `shutdown_intent` on /svc/init.events; GUI asks apps to close (grace 2 s).
2. Stop in reverse topological order of `needs` (apps → gui → netd/sndd → policyd), each: `shutdown` message on supervision channel, grace 2 s, then kill.
3. `sync()` VFS; unmount /data, /cfg; stop usbd; stop devmgd.
4. `sys_power(.s5)` / `sys_power(.reboot)`, kernel platform driver performs ACPI S5 (SLP_TYP from \_S5 + SLP_EN) or reset via 0xCF9. Recovery-reboot sets the boot flag by writing `recovery=1` into the journal-adjacent scratch? No, recovery is a *boot-menu* choice (01-boot §9); `svcctl recovery` simply reboots after writing `/cfg/system/next-boot=recovery`, which init reads pre-GUI next boot. (Keeps stage2 dumb.)

### 4.5 Zig interface (supervision protocol, public)

```zig
// libs/libvibeee/src/init_proto.zig, messages on the supervision/control channels (≤64 B inline)
pub const SvcRequest = union(enum(u8)) {
    start: SvcName, stop: SvcName, restart: SvcName, status: SvcName, list,
    watchdog_ping,                       // service -> init, on supervision channel
    notify_ready,                        // service -> init; init then allows dependents
    spawn_driver: SpawnDriverReq,        // devmgd -> init (manifest path + attach tag)
    shutdown: enum(u8) { poweroff, reboot, recovery },
    cfg_ready_sub,                       // subscribe to /cfg-mounted event
};
pub const SvcName = extern struct { name: [24]u8 };
pub const SpawnDriverReq = extern struct { manifest: [40]u8, tag: [16]u8 };
pub const SvcStatusRep = extern struct {
    state: enum(u8) { stopped, starting, running, backoff, failed },
    pid: u32, restarts: u32, last_exit: i32, uptime_s: u32,
};
```

### 4.6 Recovery TUI

`recovery=1` (boot menu) → init spawns no services except a static-linked `recover` binary on the kernel text console: restore .BAK files, fsck/mkfs /cfg /data, factory reset, install/repair SSD, expand /data, show logs, actions per 01-boot §9; implementation is eeebox applets driven by a 500-line menu. Works with zero working /data because rootfs is RAM.

## 5. devmgd

### 5.1 PCI enumeration decision

**Kernel enumerates; devmgd consumes a table.** The kernel must walk PCI anyway for its in-kernel drivers (display 00:02.0, PATA 00:1f.2, LPC/SMBus/HDA-power platform bits). It walks ECAM once at boot (`base 0xE0000000 | bus<<20 | dev<<15 | fn<<12 | off`, MCFG-verified; port 0xCF8 fallback), marks devices it claims, and exposes:

```zig
pub const PciBar = extern struct { base: u32, len: u32, flags: u32 }; // flags: io/mem/64(unused)/pref
pub const PciDevInfo = extern struct {
    bdf: u16, vid: u16, did: u16, rev: u8, claimed: enum(u8){ free, kernel, user },
    class: u32,            // base<<16|sub<<8|prog
    irq_gsi: u8, _pad: [3]u8,
    bars: [6]PciBar,
};
pub extern fn sys_pci_table(buf: [*]PciDevInfo, max: u32) i32;    // count or -errno
pub extern fn sys_pci_rescan(bus: u8) i32;                        // re-walk one bus (wifi slot)
```
User drivers still use contract `pci_cfg_read/write(bdf)` for their own device; the table is for matching only. Rationale: no TOCTOU on claims, one enumerator, devmgd stays unprivileged for config-space writes.

### 5.2 Driver manifest (drop-in), exact format + netd example

`/drivers/<name>.drv` (EMF) + `/drivers/bin/<name>`. devmgd scans rootfs `/drivers` and, once mounted, `/data/drivers` (user drop-ins; same-name wins over rootfs, the modularity story).

```toml
# /drivers/netd.drv
[driver]
name = netd
exec = /drivers/bin/netd
class = pci
single_instance = true       # matches beyond the first become `attach` messages
priority = 10                # lower wins on conflicting match

[match]
pci = 168c:001c, 1969:2048   # AR2425 wifi OR Attansic L2, either brings netd up
# also legal:  pci_class = 02/00/*        (any ethernet)
#              usb = 0951:1606            (usb VID:PID)
#              usb_class = 08/06/50      (MSC bulk-only)

[privileges]
caps = pci, mmio, ioport, dma, irq, netstack
ram_kb = 3072

[service]
restart = on-failure
backoff_ms = 500
watchdog_ms = 5000
provides = net
```

### 5.3 Matching, dedup, conflict rules

1. Identity: every device gets a stable **tag**: `pci:BB:DD.F`, `usb:<bus>-<path>`, `acpi:<HID>`. devmgd keeps a claim registry `tag → (manifest, pid)`; a claimed tag is never re-matched until released (device removed or driver failed permanently).
2. Two manifests match one device → lowest `priority` wins; tie → lexicographic name; loser logged (`devctl list` shows shadowed matches).
3. `single_instance=true` (all v1 servers): first match → `spawn_driver` via init; further matches → `attach{tag}` message on the driver's control channel (e.g. netd gets atl2 at boot, ath5k attach later).
4. Removal (wifi kill): kernel ACPI notify → kernel rescans bus 1, updates table, emits device-gone on /svc/devmgd.events → devmgd sends `detach{tag}` to netd (netd drops the ath5k instance, keeps running). Re-enable (Fn+F2): kernel rescan finds 168c:001c → `attach` again. netd is never killed for this.
5. USB flow: usbd enumerates; interfaces it owns natively (MSC, UVC, HID per locked architecture) it just drives, publishing events. Unclaimed interfaces → event to devmgd → manifest match (`usb =` / `usb_class =`) → spawned driver speaks the **uif** passthrough protocol to usbd (control/bulk/interrupt transfer submission over channel+shm ring). This is the third-party USB driver story; v1 ships no uif driver but the seam exists.
6. `devctl rescan` re-scans /drivers dirs + re-matches unclaimed tags, completes the "drop a .drv + binary into /data/drivers, plug device" story with zero reboots.

## 6. eeelibc

Zig source, exports C ABI (`export fn`), headers shipped for C ports. Compiled per-app as a static archive; Zig comptime + `--gc-sections`-equivalent dead-code elim keeps per-app cost low.

### 6.1 errno model

Linux x86 numbering (porting ease), subset: EPERM 1, ENOENT 2, ESRCH 3, EINTR 4, EIO 5, ENXIO 6, E2BIG 7, ENOEXEC 8, EBADF 9, ECHILD 10, EAGAIN 11, ENOMEM 12, EACCES 13, EFAULT 14, EBUSY 16, EEXIST 17, ENODEV 19, ENOTDIR 20, EISDIR 21, EINVAL 22, ENFILE 23, EMFILE 24, ENOTTY 25, EFBIG 27, ENOSPC 28, ESPIPE 29, EROFS 30, EPIPE 32, ERANGE 34, ENAMETOOLONG 36, ENOSYS 38, ENOTEMPTY 39, ETIMEDOUT 110, ECONNREFUSED 111, EHOSTUNREACH 113, EINPROGRESS 115. `errno` is a field in the thread control block; `#define errno (*__errno_location())`; TCB reached via `%gs:0` (kernel loads a per-thread GDT slot; `sys_thread_set_tls(base)`).

### 6.2 File descriptors

Userspace fd table (64 entries, growable to 256): `fd → {handle, kind: file|dir|pipe_r|pipe_w|sock|chan, flags}`. Kernel file handles do the heavy lifting; pipes/sockets are libc-glued objects.

Surface v1: `open close read write pread pwrite lseek stat fstat lstat(=stat, symlinks per VFS) readdir(opendir/readdir/closedir) mkdir rmdir unlink rename dup dup2 pipe fcntl(F_GETFL/F_SETFL/F_DUPFD) ftruncate fsync access getcwd chdir ioctl(whitelisted: TIOCGWINSZ, FIONREAD)`. cwd is **libc-maintained** (string; relative paths resolved client-side, kernel sees absolute), keeps kernel path handling dumb.

**pipe()**: SPSC shm ring (16 KB) + 2 events (readable/writable), bundled as two fd-wrapped handle triples. One reader + one writer only, exactly what shell pipelines need; documented limitation (dup'ing both ends across >2 processes is EINVAL-on-write territory; esh never does).

**poll/select**: every fd kind yields a waitable event (files: always-ready; pipes: ring events; sockets: netd-provided event per socket) → translate to `wait_many(events, timeout)`. Caps: 64 fds.

### 6.3 Process, env, time, signals-lite

- `posix_spawn/posix_spawnp` (+file_actions: adddup2/addopen/addclose; attr: argv/envp only) → kernel `spawn(path, argv, env, grants)`; stdio fds become handle grants at slots 0/1/2. `waitpid` (0/WNOHANG), `_exit/exit/atexit`, `getpid getppid`.
- **fork() = ENOSYS**, always. Rationale: no fork in kernel v1 (single address space clone cost, no overcommit story, 512 MB). Porting guide pattern: `s/fork();exec(...)/posix_spawn(...)/`, `s/fork();work()/pthread_create or spawn self with argv flag/`. vfork also ENOSYS. `system()` and `popen()` ARE provided (implemented over posix_spawn + pipe), they cover 80 % of ported code's fork use.
- Signals: **no asynchronous delivery**. `kill(pid, SIGTERM)` → kernel termination-request event; libc runtime thread turns it into the handler registered via `sigaction(SIGTERM|SIGINT|SIGHUP)` (called on a dedicated tiny thread, documented deviation) or default `exit(128+sig)`. SIGKILL = hard kill. Everything else (SIGSEGV etc.) is kernel-fatal with a klog dump. `sigprocmask` is a no-op returning 0.
- env: `environ getenv setenv putenv unsetenv` (copied at spawn, ≤4 KB).
- time: `clock_gettime(CLOCK_MONOTONIC|CLOCK_REALTIME)` (kernel: HPET/PM-timer based: TSC halts in C3, research core §6; REALTIME = RTC + offset), `gettimeofday time nanosleep sleep usleep`.

### 6.4 malloc, stdio, strings

- **Allocator**: "eeemalloc", size-class segregated free lists. 16 classes 16 B…2 KB carved from 64 KB arenas obtained via kernel `vm_map` (anonymous mmap-lite); >2 KB → direct vm_map, 4 KB-rounded. **One global lock** (single core @630 MHz: per-thread caches waste RAM and win nothing; a futex-based lock is uncontended-fast). Empty arenas returned to kernel with 1-arena hysteresis. Code ≈ 2.5 KB. `malloc free calloc realloc posix_memalign`. `mmap(MAP_ANONYMOUS)` exposed; file-backed mmap ENOSYS (porting note).
- **stdio**: `FILE` = 40 B struct + lazily-allocated **1 KB buffer** (BUFSIZ 1024; RAM-precious). Line-buffered on tty-ish fds, full elsewhere, stderr unbuffered. `printf/fprintf/snprintf/vsnprintf` (one Zig core ≈ 7 KB, no float-%a, %Lf), `fopen fclose fread fwrite fgets fputs fputc fgetc ungetc fseek ftell rewind fflush setvbuf perror puts getline`.
- string/mem/ctype: full C89 set + `strdup strndup strtok_r strcasecmp snprintf strtol/strtoul/strtod`. ctype is C+UTF-8 only: `mbrtowc/wcrtomb` for UTF-8 exist; no locale machinery, `setlocale` returns "C".

### 6.5 pthreads-lite + kernel futex contract

Kernel additions requested (OPEN-K3, coordinate with kernel-core):
```zig
pub extern fn sys_thread_create(entry: usize, stack_top: usize, tls: usize, arg: usize) i32; // tid
pub extern fn sys_thread_exit() noreturn;
pub extern fn sys_futex_wait(uaddr: *const u32, expect: u32, timeout_us: u64) i32; // 0|-ETIMEDOUT|-EAGAIN
pub extern fn sys_futex_wake(uaddr: *const u32, nwake: u32) i32;
```
`pthread_create/join/detach/self`, mutex (Drepper 3-state: 0 free / 1 locked / 2 contended; uncontended lock = one `lock cmpxchg`, no syscall), cond (`wait/timedwait/signal/broadcast` via futex + generation counter), `pthread_once`, TLS via `pthread_key_create` (16 keys). No cancellation, no rwlock (M2). Default stack 64 KB (guard page below). Fallback if kernel rejects futex: mutex = kernel event object per mutex (heavier: syscall on every lock; ~3× slower contended paths), futex strongly preferred.

### 6.6 Static vs dynamic linking: DECISION: fully static

| | static | dynamic |
|---|---|---|
| loader | none | ld-eee ≈ 40 KB + kernel PT_INTERP support + reloc processing 10–30 ms/app @630 MHz |
| per-app eeelibc after Zig DCE | 40–90 KB | ~4 KB stubs |
| per-app libeui after DCE | 120–180 KB | ~8 KB |
| 8 GUI apps + 6 services, total code | ≈ 2.1 MB | ≈ 0.9 MB + 430 KB shared libs |
| RAM cost of duplication | ≈ 1.3 MB (2.7 % of 48 MB budget) | 0 |
| i686 PIC tax | 0 | +5–8 % code size, %ebx pinned to GOT (measurable perf loss on a 4-GPR-tight ISA) |
| on-disk (zstd, binaries laid adjacent in EAR, 8 MB window) | +≈0.6 MB compressed | baseline |
| engineering | zero | weeks; Zig's shared-lib story for a custom freestanding OS is immature |

Static loses ~1.3 MB RAM and ~0.6 MB compressed image; buys zero loader complexity, whole-program DCE/inlining (which is *why* per-app costs are 3–5× smaller than musl-style baselines), deterministic 5–10 ms spawns (map PT_LOADs, zero bss, jump). Revisit only if app count exceeds ~15 (then: multicall GUI-app binary before a dynamic linker).

### 6.7 Sockets shim & C porting story

- `socket bind connect listen accept send recv sendto recvfrom setsockopt/getsockopt(subset: SO_REUSEADDR, SO_ERROR, TCP_NODELAY) shutdown getaddrinfo/freeaddrinfo gethostbyname(shim) inet_ntop/pton`. socket() opens a channel to /svc/net; each socket = netd-side id + TX/RX shm rings + readable/writable events. AF_INET SOCK_STREAM/DGRAM only. getaddrinfo does DNS via a netd call (netd owns the resolver).
- **C ports**: `eeecc` wrapper = pinned `zig cc -target x86-freestanding -mcpu=pentium_m -O ReleaseSmall -nostdinc -isystem $SYSROOT/include -nostdlib $SYSROOT/lib/crt0.o -leeelibc -T $SYSROOT/lib/user.ld`. A small editor (kilo-class) needs: termios raw mode (provided: `tcgetattr/tcsetattr` with ICANON/ECHO/VMIN over the terminal channel), read/write/snprintf, TIOCGWINSZ, all present. Port checklist shipped in docs: no fork → posix_spawn; no signal handlers beyond TERM/INT/HUP; no file mmap; no locale.

## 7. CLI environment

### 7.1 esh (shell), honest subset

- Line editing: emacs-lite (C-a/C-e/C-k/C-w/C-u, arrows, C-r incremental history search), history 200 entries RAM + persisted to `/data/home/.esh_history` on exit.
- Globs `* ? [a-z]` (own ~150-line matcher over readdir); tilde expansion.
- Pipes `a | b | c` (SPSC pipe per link), redirects `> >> < 2> 2>&1`; `&&  ||  ;`; `$VAR $? $#` expansion, single/double quotes, backslash.
- v1 EXCLUDES (honest): no `$(...)`/backticks, no job control (`&`, fg/bg, no terminal process groups; Ctrl+C = TERM-request to foreground child via line discipline), no functions/if/for. M2 adds `$()`, if/for/while for port-ability. Init needs no shell (declarative manifests) so this costs nothing structurally.

### 7.2 eeebox, single multicall binary (decision: yes, à la busybox)

One static binary, applet dispatch on argv[0]/first arg; ≈ 450 KB total vs ≈ 2.5 MB as separate binaries. Symlinks in /bin. ~40 applets:

- files: `ls cat cp mv rm mkdir rmdir ln stat du df head tail wc grep(-E lite) find(-lite: -name/-type) hexdump less(pager) touch`
- system: `ps top(top-lite: 1 s refresh, CPU%/RSS via sys_proc_list) free kill dmesg date uname sysinfo(DMI+CPU+RAM+disk summary) sync mount umount eject reboot poweroff svcctl devctl`
- hw/config: `keymap(us-intl|be-azerty → /cfg/system/keymap + reload msg to input owner) brightness(0-15 → policyd) mixer(sndd) netcfg netstat(-lite) ping wifi(scan/join/status → netd) camera(on|off → policyd)`
- maintenance: `update(§9.6) install-to-ssd(§9.6) factory-reset fsck.eeefs mkfs.eeefs`

`ps/top/free` consume kernel `sys_proc_list/sys_proc_stat/sys_meminfo` (read-only syscalls, no /proc filesystem in v1; OPEN-K4).

### 7.3 Where the CLI lives, decision

- Primary: **eterm** (GUI terminal app; the tiling WM makes fullscreen-terminal a first-class workspace, covers the "VT" use case).
- **No Ctrl+Alt+F1 VT switching**: display contract has ONE owner; live console/GUI switching would punch a hole in it for marginal benefit.
- **Emergency shell: KEEP, as fallback not as VT**: init runs `econ` (kernel text console + esh) when (a) `recovery=1`, (b) GUI crash-loop breaker trips, (c) `gui.enabled=false` in /cfg. Kernel fb/text console for panic already exists; econ reuses the kernel console write syscall + input core stream. You are never stranded, and the display owner invariant holds (console owner ⇔ GUI absent).

## 8. Settings

Two programs must be able to change the same setting and see each other do it:
the Settings app and a shell. That is what a plain file per program does not
give, and it is the whole reason there is a service here rather than just a
parser.

The shape is the one dconf and the Windows registry share, and the storage is
not: a typed schema, one writer, and a change notification, over files anyone
can read.

### 8.1 The schema is the structs

A domain is a Zig struct. Field names are keys, field types are the value
grammar, and field defaults are the defaults. There is no schema language, no
compiler for it, and no second table to forget to update, because the type is
already all three of those things.

```zig
pub const Domains = struct {
    input: Input = .{},
    wm: Wm = .{},
};

pub const Wm = struct {
    theme:  Theme = .classic,
    bar:    Bar = .top,
    layout: Layout = .tall,
    master: u7 = 58,
};
```

A value set is a value the type already had a name for. `Theme` is checked at
compile time against the toolkit's list of themes and `Input.keymap` is the
keyboard registry's own name type, so a layout added to `src/keymaps` is one
the settings accept, the completer offers and the Settings app lists, with no
second list anywhere to fall behind the first.

A key is `domain.field`: `wm.theme`, `power.dim_after`. Two levels, not a tree.
Two levels is what maps one-to-one onto one file per domain and one struct per
domain, and a deeper namespace is how a registry ends up with orphaned subtrees
nobody can attribute.

What comptime reflection over this gives, at no further cost: the set of valid
keys, the set of valid values for every enum, the range of every integer, and
the default to reset to. Every consumer below is a walk over
`std.meta.fields`.

**Keys cannot be invented at runtime.** `cfg set nothing.here 1` is an error,
not a new key. This is the property that separates a schema from a registry: the
store cannot accumulate anything nobody declared, so it cannot rot.

### 8.2 Storage stays text

One file per domain, `/etc/wm.cfg` and so on, in the `key = value` format
[`config.zig`](../src/user/lib/config.zig) already reads. A file holds only what
differs from the default, so a fresh system has almost empty files and
`cfg reset` is a deletion rather than a restoration.

Text because the recovery story for this machine is a card in another computer's
reader. A binary store would have to be readable by a tool that only runs on the
machine that is broken. The cost is parsing, which is a few microseconds a
domain, once.

Writes go through §6's ordering: a new name, then a rename over the old one.
Replacing repoints the record already carrying the name, so a yank during a
settings write loses the write and never the settings.

### 8.3 `cfgd`, the one writer

Registers `cfg` in `/svc`. Holds every domain parsed, answers over a channel:

| Request | Effect |
|---|---|
| `get(key)` | the current value, formatted |
| `set(key, value)` | validate against the type, apply, write the domain's file, bump its event |
| `reset(key)` | drop the override, back to the field default |
| `list(domain)` | every key, its value, and whether it is default |
| `watch(domain)` | a handle to the domain's event |

One writer means two programs setting keys at once cannot interleave into one
file, which on a filesystem with no atomic anything is not a theoretical worry.

**Notification is a counting event per domain.** A watcher already has an event
loop and `wait_many`; a settings change wakes it and it re-reads. eeewm applies a
theme change without restarting because of this, and that is the visible payoff.

### 8.4 The library, and the boot-order escape hatch

`ulib.cfg` is what everything calls. It connects to `cfg` on first use, and
**falls back to reading the file directly** when the service is not registered.

The fallback is not a convenience. `init` reads settings before it has started
anything, `devmgd` runs beside `cfgd` rather than after it, and the recovery
console has to work when the service is the thing that is broken. A design where
configuration is only reachable through a running service is a design where a
failed service is unrecoverable.

Read-only in that mode. Anything early enough to need the fallback is early
enough to have no business writing.

### 8.5 Settings the kernel holds

Most settings are applied by whoever reads them: the desktop themes itself. The
keyboard layout is different, because the kernel holds it and translates every
keystroke through it, so somebody has to hand it over.

`cfgd` does, once at startup and again whenever the domain changes. Not because
the store should be in the business of policy, but because it is already the one
place that knows a setting has changed, and a second party watching for it would
be a second place for the kernel's copy and the file to disagree.

That keeps one answer to "which layout is this": the file. `Super+Space` cycles
by setting the value rather than by calling the kernel, so a layout chosen with
a chord and one chosen in a file are the same choice, and the bar draws the two
letters the layout gives for the purpose.

### 8.6 What is not settings

Manifests are not settings and do not go here. `/etc/services` says what to
start and `/lib/*.man` says what a driver claims; both are read by things that
run before `cfgd` exists, both are edited by whoever builds the image rather
than by whoever uses the machine, and neither has a default to fall back to.
They stay plain files, read directly.

The line: **a manifest says what exists, a setting says how it behaves.**

Nor is user data. Documents, state and caches live under `/home`. A settings
store that programs use as scratch space is how a registry becomes a database.

### 8.7 The two front ends

`cfg` is the command-line one:

```
cfg                        every domain, every key
cfg wm                     one domain
cfg get wm.theme
cfg set wm.theme dusk
cfg reset wm.theme
cfg watch wm               print changes as they happen
```

Completion comes free from §8.1 and the source table in
[`complete.zig`](../src/user/lib/complete.zig): `cfg set wm.<tab>` offers the
field names, and `cfg set wm.theme <tab>` offers the enum's values, because both
are `std.meta.fields` over a type the tool already imports.

**Settings**, the app, is generated from the same schema rather than hand-laid
out: an enum becomes a dropdown, a bool a checkbox, a bounded integer a slider.
Adding a setting is adding a field, and it appears in both front ends. The
widgets belong to libeui; the app walks the schema and asks for one per field.

## 9. Build system

### 9.1 Repo layout

```
vibeee/
  versions.mk            # single source of pinned versions + sha256s
  Makefile               # top-level; includes */build.mk
  boot/                  # stage1.asm, stage2/ (per 01-boot)
  kernel/
  libs/{eeelibc,libvibeee,libeui}/
  core/{init,devmgd,policyd,recover}/
  servers/{netd,usbd,sndd}/
  cli/{esh,eeebox}/
  apps/{gui,eterm,efiles,...}/
  tools/                 # host tools: mkear.zig mkpart.zig patchhdr.zig mkeeefs.zig
                         #   fetch-toolchain.sh check-env.sh flash.sh mkupd.zig
  image/                 # rootfs skeleton (etc/, drivers/*.drv), BOOT.CFG template
  design/ docs/
  out/                   # ALL build products (git-ignored): out/host/ out/obj/ out/rootfs/ out/vibeee.img
```

### 9.2 Toolchain pinning (no root anywhere)

`versions.mk`: `ZIG_VERSION := 0.14.1` (pin exact; one stable for kernel+userspace+host tools), `NASM_MIN := 2.16`, `MTOOLS_MIN := 4.0`, `ZSTD_MIN := 1.5` + per-host-platform Zig tarball sha256s. `tools/fetch-toolchain.sh` downloads Zig into `toolchain/zig/` and sha256-verifies; nasm/mtools/zstd come from the host (macOS: brew; Linux: distro) and `tools/check-env.sh` hard-fails with install hints if missing/too old. `zig cc` doubles as the C cross-compiler for ports (no GCC/binutils dependency; objcopy needs = `zig objcopy`).

### 9.3 Makefile architecture

- Top-level `Makefile` sets `ZIG := toolchain/zig/zig`, `ZFLAGS_USER := -target x86-freestanding -mcpu=pentium_m -O ReleaseSmall -fstrip -fsingle-threaded=false`, includes every `*/build.mk`; components append to `ROOTFS_FILES`/`HOST_TOOLS`. Parallel-safe (`make -j`): all rules write only into `out/`, no shared temp names.
- Dependency tracking: Zig compiles whole programs per invocation; per-component rules depend on `$(shell find <comp>/src libs -name '*.zig')`, conservative and always-correct; a full from-clean userspace build is < 60 s on a modern host, so over-rebuild is cheap. (If the pinned Zig's `--emit-deps`-style flag proves reliable, swap in exact dep files, noted, not load-bearing.)
- Canonical component fragment:

```make
# core/init/build.mk
INIT_SRC := $(shell find core/init/src libs/libvibeee/src libs/eeelibc/src -name '*.zig')
out/rootfs/sbin/init: $(INIT_SRC) | out/rootfs/sbin
	$(ZIG) build-exe $(ZFLAGS_USER) -T libs/eeelibc/user.ld \
	  --name init core/init/src/main.zig -femit-bin=$@
ROOTFS_FILES += out/rootfs/sbin/init
```

### 9.4 Image pipeline (exact layout, owned jointly with 01-boot)

`make image` → `out/vibeee.img`, 48 MB flat file, layout per 01-boot §8 (MBR+stage1 @0; stage2 A @LBA 1, B @1024; journal @2040; P1 FAT16 32 MB @LBA 8192; P2 eeefs 8 MB @73728; P3 stub 4 MB @90112):

1. Build all `ROOTFS_FILES` into `out/rootfs/` (staging tree = the future ramfs: /sbin /bin(symlinks→eeebox) /drivers /etc /usr/share/fonts …), timestamps normalized to `SOURCE_DATE_EPOCH`.
2. `zig run tools/mkear.zig -- out/rootfs` → EAR1 (entries sorted, binaries adjacent for zstd locality) → `zstd -19 --no-check` → EZI1 wrap with CRCs → `out/ROOTFS.EZI` (target ≤ 9 MB).
3. `mformat` P1 (FAT16, fixed volume serial), `mcopy` BOOT.CFG KERNEL.ELF ROOTFS.EZI + .BAK copies (first image: BAK = same files).
4. `zig run tools/mkeeefs.zig` → P2 image (seeded /cfg defaults? no, empty; init seeds) and P3 stub.
5. `truncate 48M` + `tools/mkpart.zig` (MBR, CHS-capped entries, disk_sig = first 4 bytes of sha256 of P1 image, deterministic AND version-unique) + `dd conv=notrunc` each region.
Reproducibility: pinned zig/zstd, sorted EAR, fixed FAT serial+timestamps, derived disk_sig → byte-identical images from identical trees (`make repro-check` builds twice into different dirs and cmps).

### 9.5 make targets & QEMU profile

```
make            # everything
make image      # out/vibeee.img
make test       # host-native unit tests (manifest parser, esh tokenizer, allocator, EAR round-trip)
make qemu       # boot SD-path image
make qemu-ssd   # image attached as IDE secondary master (install-to-ssd testing)
make qemu-gdb   # -s -S
make sd DEV=/dev/rdiskN   # guarded flasher
make repro-check clean
```

`make qemu` exact flags:
```
qemu-system-i386 -M pc -cpu n270,-sse3,-ssse3 -m 512 \
  -drive id=sd,file=out/vibeee.img,if=none,format=raw \
  -device usb-ehci,id=ehci -device usb-storage,bus=ehci.0,drive=sd \
  -device intel-hda -device hda-duplex \
  -device virtio-net-pci,netdev=n0 -netdev user,id=n0 \
  -vga std -rtc base=utc -no-reboot -d guest_errors
```
(`-M pc` i440FX: PIIX3 IDE = same legacy-BMDMA programming model class as ICH6 combined mode; PIIX3 UHCI ≈ ICH6 UHCI, spec-identical; `n270` masked to SSE2-only traps any illegal SSE3 use; no ICH6/GMA900/atl2/AR2425/KB3310 emulation exists, see §10 seams.)

`make sd`: `tools/flash.sh` refuses unless: DEV explicitly given; device exists, is removable (macOS `diskutil info` "Removable Media", Linux `/sys/block/*/removable`), is not the system disk, size 64 MB–128 GB; prints current partition table; requires the user to type `YES`; then unmount, `dd bs=4m`, `sync`, eject. Never auto-detects a device.

### 9.6 Update & install (OTA-less)

- Package: `vibeee-<ver>.upd` = EAR archive: `manifest.emf {version, min_version, crc32s}` + `KERNEL.ELF ROOTFS.EZI [stage2.bin]`, built by `make upd` (`tools/mkupd.zig`).
- `update <file>` (eeebox, needs /svc/init cooperation for the P1 mount): 1. verify CRCs (spool via /tmp if ≥16 MB free, else /data); 2. mount P1 RW (kernel FAT driver over the boot medium, ublk on SD, PATA on SSD); 3. copy *running* KERNEL.ELF/ROOTFS.EZI → .BAK (running = proven good), update BOOT.CFG CRC lines (tmp+rename; FAT rename = single dir-sector rewrite, near-atomic; residual window covered by stage2's .BAK fallback + boot journal auto-slot, 01-boot §9); 4. write new files, read back, verify CRC; 5. stage2 update only if shipped: raw-write copy B (LBA 1024) via whole-disk device, read back, then copy A (LBA 1), never both in one failure window; 6. reboot. A failed new kernel auto-falls back after 3 journal attempts; the post-boot commit hook (init, §4.1.7) records success in /cfg/VERSION history. Downgrade refused unless `--force` (schema-versioned /cfg makes downgrades risky).
- `install-to-ssd`: recovery-TUI/CLI action per 01-boot §8: writes MBR+stage2+P1+P2 to the PATA SSD via kernel BlockDev, sizes P3 to remaining ~3.9 GB, preserves any existing 0xEF Boot Booster partition slot, mkfs's P2/P3, copies current /cfg.

## 10. Register-level programming sequences

Userspace is deliberately register-free; the hardware-facing sequences this design *owns* are:
- **ECAM config read used for the PCI table** (kernel-side, consumed here): `mmio32(0xE0000000 + (bus<<20)+(dev<<15)+(fn<<12)+reg)`; MCFG verified at 0xE0000000 buses 0–255 [HIGH]. Fallback `outl(0xCF8, 0x80000000|bdf<<8|reg); inl(0xCFC)`.
- **Updater raw-sector ordering** (via kernel BlockDev/ublk write): stage2-B sectors LBA 1024–1534 → flush → read-back CRC → stage2-A LBA 1–511 → flush → read-back; journal sector LBA 2040 untouched by updater (kernel owns acks). MBR (LBA 0) written only by `install-to-ssd`/`mkpart`, never by `update`.
- ACPI S5/reset, EC fan/battery, CAMS/WLDS toggles: **kernel platform driver territory**; policyd/eeebox reach them via `sys_power`, `/svc/platform` channel ops (`camera_set`, `wifi_set`, `brightness_set(0-15)` → PBLS, battery status with the percent-mislabeled-as-mAh bug already normalized by the kernel per quirks §5.1). This doc's utilities never touch ports 0x62/0x66/0x380–0x384 directly.

## 11. RAM / disk budget roll-up & boot-time budget

Uncompressed rootfs (cap 24 MB), userspace roll-up:

| item | size |
|---|---|
| init + recover TUI | 0.30 MB |
| devmgd + policyd | 0.25 MB |
| eeebox (multicall, static) + esh | 0.50 MB |
| netd / usbd / sndd binaries | 0.9 + 0.8 + 0.6 MB |
| gui server + libeui-linked | 2.5 MB (its own budget) |
| apps (eterm, efiles, editor, settings, viewer, sysmon) | 1.8 MB |
| fonts (2 faces, subset) | 0.7 MB |
| /etc defaults + manifests + keymaps + /drivers/*.drv | 0.15 MB |
| **total** | **≈ 8.5 MB** (15.5 MB headroom; EZI compressed ≈ 3.5–4.5 MB) |

Idle RAM (booted to GUI; cap 48 MB incl. RAM rootfs):

| item | RSS |
|---|---|
| RAM rootfs (above) | 8.5 MB |
| kernel (own budget assumption) | 6.0 MB |
| init + policyd + devmgd | 0.5 MB |
| usbd (incl. DMA buffers) / netd / sndd | 1.2 / 2.5 / 1.0 MB |
| gui server (pixel buffers largely in stolen 8 MB, outside E820) | 3.5 MB |
| eterm idle | 0.5 MB |
| slack (fd tables, stacks, cfg cache) | 1.0 MB |
| **total** | **≈ 24.7 MB** → > 23 MB headroom |

Cold boot to usable GUI (cap 8 s):

| # | phase | est |
|---|---|---|
| 1 | BIOS POST (no Boot Booster) | ~2.0 s (measure M1) |
| 2 | stage1+stage2: kernel+rootfs reads (01-boot cap) | ≤ 3.9 s (likely ~2.5) |
| 3 | kernel: zstd-unpack 9 MB rootfs @ ~60 MB/s | 0.25 s |
| 4 | kernel core init (mm/sched/ACPI/display modeset ‖) | 0.30 s |
| 5 | init: manifests + spawn devmgd/policyd | 0.05 s |
| 6 | devmgd: pci table + match + spawn 3 servers | 0.05 s |
| 7 | gui spawn→first frame (gated on display+input only) | 0.50 s |
| 8 | ‖ usbd EHCI+SD enumerate+MSC ready → /cfg mount | 0.7 s (overlaps 7) |
| | **total to interactive GUI (defaults), cfg applied +≤1 s** | **≈ 7.2–7.5 s** |

If POST or BIOS reads measure worse, the recovery levers are in 01-boot (rootfs size, zstd level), userspace's own path is ~1.3 s and has no fat left worth cutting.

## 12. Bring-up & test plan

- **Host-native tests** (`make test`, plain Zig tests): EMF parser (fuzz corpus), esh tokenizer/expander, eeemalloc (torture + leak accounting), fd-table, printf, EAR/upd round-trip, manifest dependency-order property tests (random DAGs → verify start order + ripple rules in a simulated init with mock spawn/kill).
- **init/devmgd simulation seam**: both take their syscall surface through a `Sys` vtable (Zig comptime interface); a host build links a fake kernel (in-memory /svc, scripted pci table, scripted service deaths) → crash-loop, backoff, watchdog, usbd-freeze scenarios run as unit tests, no QEMU.
- **QEMU integration** (per §9.5): boots to GUI-less profile (`gui.enabled=false`) → econ shell on text console; scripted expect-style test via exit-port device: spawn, pipes, mounts (/cfg on USB-MSC-backed P2, the real SD topology), `update` applied then journal-fallback tested by corrupting KERNEL.ELF, install-to-ssd onto IDE secondary disk then reboot from it. Testable in QEMU: full boot path, UHCI/EHCI+MSC (real usbd), HDA controller w/ generic codec, PATA-class IDE, virtio-net (netd's test driver seam, atl2/ath5k are real-HW-only), i8042. NOT testable: GMA900 (kernel display falls back to Bochs-VBE seam), AR2425/atl2, KB3310/ASUS010 (kernel platform driver mocked behind /svc/platform; policyd fully testable against the mock).
- **Real hardware**: photograph-the-screen protocol (no serial): verbose boot prints per-phase timestamps (settles the §11 table), then: Fn+F2 detach/attach loop ×20 (netd survives), yank-SD-crash usbd via `svcctl kill usbd` (frozen-mount reattach), 24 h GUI+audio soak with `top` logging to /data.

## 13. Risks & open questions

- **OPEN-K1** (kernel): `svc_watch() → event` on registry changes, init's dependency engine needs it (polling fallback: 100 ms scan, ugly but workable).
- **OPEN-K2** (kernel/VFS): frozen-mount semantics for dead ublk providers + reattach by tag. Without it, usbd crash = EIO storm on /data; with it, a 1 s blip. Highest-value contract addition requested by this subsystem.
- **OPEN-K3** (kernel): futex_wait/wake + thread_create/set_tls syscalls (§6.5). Fallback exists but is slower and fatter.
- **OPEN-K4** (kernel): read-only `sys_proc_list/proc_stat/meminfo` for ps/top/free.
- **OPEN-S1** (storage/03): eeefs atomic rename guarantee (config writes); mount-by-tag (`disk_sig:part`) resolution living in VFS.
- **OPEN-G1** (GUI): late-config application (start on defaults, reload on cfg-ready event), agreed split of the ≤8 s budget depends on it.
- **R-U1**: `-cpu n270,-sse3,-ssse3` masking must be validated against the pinned QEMU (feature-flag names drift); fallback `-cpu pentium3` catches only SSE2-and-below builds (too strict), worst case we accept unmasked n270 and rely on `-mcpu=pentium_m` codegen discipline.
- **R-U2**: FAT rename atomicity window during update (BOOT.CFG rewrite), mitigated by journal auto-fallback; residual risk = power cut in a <10 ms window leaves stale CRC → stage2 falls back to .BAK (safe, just old).
- **R-U3**: pipe-as-SPSC-ring breaks exotic multi-writer pipe idioms in ports; documented; M2 could add a kernel pipe object if a real port demands it.
- **R-U4**: find-based Make deps over-rebuild whole components on any libs/ edit; acceptable (<60 s clean build) but revisit with Zig dep-file emission at the pinned version.
- **R-U5**: /data/drivers drop-ins run with manifest-declared privileges, with no IOMMU a malicious .drv owns the machine (contract-documented: DMA is trusted). Mitigation is social, not technical: /data/drivers requires an explicit `devctl trust` first-use confirmation recorded in /cfg.

## 14. Phasing

- **M1**: eeelibc core (fds, spawn, malloc, stdio, errno; no threads/sockets), init minimal (ordered start from rootfs manifests, restart w/ backoff, no watchdog), devmgd PCI-only matching, esh minimal (pipes/redirects/globs, no history-persist), eeebox ~15 applets, full build system: pinned toolchain, `make image/qemu/test`, host-sim seam for init. Gate: QEMU boots to econ shell, spawns pipelines, mounts /cfg via USB-MSC path.
- **M2**: pthreads-lite+futex, sockets shim (with netd), watchdog + crash-loop + usbd frozen-mount ripple (with kernel), /cfg schema+atomic writes+factory reset, recovery TUI, updater + journal-fallback E2E test, remaining applets, `make sd` + real-hardware smoke, GUI fallback econ path.
- **M3**: `$()`/control-flow in esh, uif third-party USB driver seam, eeecc sysroot + first C port (kilo-class editor) as porting-guide validation, repro-check in CI, boot-time tuning against measured hardware numbers, `devctl trust` störy for drop-ins, downgrade tooling.

# vibeee Design 08, netd: Userspace Network Stack + NIC Drivers

> Where this document and [`00-vibeee.md`](00-vibeee.md) disagree, the master design wins:
> it carries later decisions this document predates.

Status: v1 design. The layer below the stack is implemented and verified on the
machine: netd's event loop, the atl2 driver (rx, tx and a completed ARP round trip on
real hardware), the e1000 and rtl8139 test drivers, interrupt routing answered by
`platd` from `_PRT`, and the deferred-completion interrupt model. The stack (§6),
interface management (§7), the socket bridge (§8) and the tools (§9) are design ready
to implement. WiFi (§5) is design for a later milestone.

Scope: lwIP-based TCP/IP stack inside netd, interface lifecycle and configuration
through cfgd, DHCP for unconfigured interfaces, ICMP with `ping`, a stream tool `nc`,
and the socket bridge they ride on. Everything is event driven: the one loop blocks in
`wait_many` and the timeout it passes is the stack's own next deadline, so an idle
network costs zero CPU.

## 1. Overview

netd is ONE userspace process (single-threaded event loop) that owns every NIC and the
entire TCP/IP stack. It is a privileged driver server using the user-driver API
(`pci_read/write`, `map_device`, `dma_alloc`, `irq_attach`). Apps never see packets:
tools speak the `/svc/net` channel protocol, and stream traffic crosses in shared
memory rings with events for readiness. Rationale for single process / single thread:
a 630 MHz single core means threads buy zero parallelism and cost locks; an event loop
over `wait_many` gives deterministic, testable behavior.

The stack core is **lwIP**, vendored the way uACPI is (third-party verdict in the
master design: ADOPT). Handrolling TCP was rejected: lwIP's raw API in `NO_SYS` mode
is exactly this architecture, a pure single-threaded library driven by explicit input
calls and one timeout function, with two decades of deployment behind its state
machines. What stays ours is everything lwIP does not know: the drivers, the netif
glue, interface policy, configuration, the IPC bridge, and the tools.

Internal layering (all in one binary):

```
+------------------------------------------------------------------+
| bridge: socket table, per-socket shm rings, /svc/net protocol    |
+------------------------------------------------------------------+
| policy: interface lifecycle, cfg watch, DHCP/static decisions    |
+------------------------------------------------------------------+
| lwIP (NO_SYS): TCP | UDP | ICMP | DHCP | DNS | ARP | IPv4 | ethv |
+------------------------------------------------------------------+
| netif glue: one struct netif per NicDev, pbuf in/out             |
+------------------------------------------------------------------+
| NicDriver iface:  atl2  |  e1000  |  rtl8139  |  ath5k (later)   |
+------------------------------------------------------------------+
| user-driver API: map_device, dma_alloc, irq_attach, pci_*        |
+------------------------------------------------------------------+
```

No IOMMU exists: netd's DMA programming can overwrite any RAM. netd is therefore a
trusted, supervised system service. This trust boundary is documented, not mitigated.

## 2. Hardware facts used

- Attansic L2 at 03:00.0, 1969:2048 rev a0, PCIe x1, 10/100, integrated PHY.
  Implemented and verified on the machine; register truth in §4 and in the driver.
- Interrupt routing is the firmware's: netd asks `platd`, which answers from `_PRT`
  (the wired port arrives on line 17). Lines are shareable level-triggered IOAPIC
  inputs under the deferred-completion model; the controller is never touched at
  runtime. Neither driver uses MSI (atl2 MSI is known-flaky in Linux).
- Atheros AR2425 at 01:00.0, 168c:001c, b/g only: §5, later milestone.
- QEMU emulates neither atl2 nor AR2425; the e1000 and rtl8139 drivers exist so every
  layer above the driver interface is exercised in emulation (§11).
- Memory budget math assumes the pessimistic ~350 MB/s practical memcpy.

## 3. Architecture

### 3.1 Event loop

One `wait_many`, every external stimulus an event or a channel message, and the
timeout the stack's own next deadline:

```
sources: service channel | one irq handle per taken line | cfg watch event
         | client doorbell event
timeout: sys_timeouts_sleeptime()   (lwIP's next timer, FOREVER when it has none)
```

- After every wake, whatever the reason: `sys_check_timeouts()`. lwIP schedules its
  own retransmits, DHCP renewals, ARP aging and DNS retries through this one call;
  netd never ticks, polls or sleeps on its own account. An idle network parks the
  loop in `wait_many` forever.
- IRQ wake: read the device ISR, service, `irq_ack`. A shared line costs the other
  driver one "not mine" ISR read.
- Channel wake: drain requests (§7 ops, §8 ops).
- cfg watch wake: reload the `net` domain, diff against running state, apply (§7.3).
- Doorbell wake: walk sockets with ring work pending (§8.2).
- `wait_many` accepts eight sources. The fixed set is channel + cfg watch + doorbell
  + one handle per distinct interrupt line (at most two today, wired and wifi): six.
  The single shared doorbell is what keeps client fan-in out of the wait set.

### 3.2 lwIP integration

Vendored at `third_party/lwip` (git release tag, `src/core`, `src/include`,
`src/netif/ethernet.c`), compiled into netd by the same build pattern as uACPI. The
port surface in `NO_SYS` mode is two functions and a header:

- `sys_now()`: milliseconds from `clockMicros() / 1000`.
- `LWIP_RAND()`: from the kernel's entropy syscall if present, else a splitmix over
  `clockMicros()`; DHCP xids and TCP ISNs are the consumers.
- `lwipopts.h`, the decisions that matter:
  - `NO_SYS=1`, `LWIP_NETCONN=0`, `LWIP_SOCKET=0`: raw callback API only. No OS
    emulation layer, no threads, no mailboxes.
  - `MEM_LIBC_MALLOC=0`, static pools. `MEM_SIZE` 64 KB, `PBUF_POOL_SIZE` 48 ×
    `PBUF_POOL_BUFSIZE` 1536. Exhaustion drops packets, never blocks the loop.
  - `LWIP_ARP=1, LWIP_ICMP=1, LWIP_DHCP=1, LWIP_DNS=1, LWIP_RAW=1, LWIP_UDP=1,
    LWIP_TCP=1`. `LWIP_IPV6=0` in v1. `LWIP_AUTOIP=0`: an interface that fails DHCP
    stays addressless and says so, a 169.254 address on a home LAN is a lie of
    convenience.
  - TCP: `TCP_MSS=1460`, `TCP_WND=16384`, `TCP_SND_BUF=16384`. NewReno as lwIP ships
    it. Enough for LAN bulk at this machine's budget; window scaling can wait.
  - All checksums in software (`CHECKSUM_GEN_*`, `CHECKSUM_CHECK_*` on): no NIC here
    offloads any of them.
  - `LWIP_NETIF_STATUS_CALLBACK=1`, `LWIP_NETIF_LINK_CALLBACK=1`: address and link
    changes flow back into policy and narration.
  - `LWIP_STATS` only in debug builds, surfaced through `net -s`.

### 3.3 netif glue

One `struct netif` per NicDev. Output: lwIP hands a pbuf chain, the glue flattens it
into the driver's `transmit` (every driver copies into its own ring or FIFO anyway,
so the flatten is the same copy). Input: the driver's rx delivery allocates a
`PBUF_POOL` pbuf, copies the frame in, and calls `netif.input` (`ethernet_input`).
One copy each direction beyond DMA; §4's budget already paid for it at 100 Mbit.
Driver link changes call `netif_set_link_up/down`, which is also what makes lwIP's
DHCP restart discovery when the cable returns. The existing ARP probe diagnostic
(`net -p`) keeps its hand-built frame and its zero sender per RFC 5227: it exercises
the driver path beneath the stack and stays useful precisely because it does not
depend on it.

### 3.4 NicDriver interface

As implemented in `src/user/netd/dev.zig`: `open`, `start`, `stop`, `irq`,
`transmit`, `link`, `sync_link`, with rx delivered upward through `deliverRx`. The
stack consumes rx via the netif glue; the `NicOps` contract does not change for the
stack milestone. The wifi driver later adds `WifiOps` consumed only by the MLME
module; the netstack sees wifi as an ethernet netif carrying ethertype frames.

### 3.5 The language boundary

lwIP is vendored verbatim and never patched, exactly like uACPI. Everything of ours
is Zig in this codebase's idiom, and the boundary follows platd's precedent:

- A single `netd/lwip.zig` hand-mirrors the handful of C shapes and entry points the
  glue actually touches (`netif`, `pbuf`, `err_t`, the dhcp/dns state the tools
  report), as extern structs and `enum(uN)` with comptime `@sizeOf`/`@offsetOf`
  assertions against the vendored headers' layouts, the way `uacpi.zig` pins the
  FADT. No `@cImport`: what we depend on is written down and checked, not inhaled.
- The port surface (`sys_now`, rand, the few `LWIP_PLATFORM_*` hooks) is Zig
  exporting C-ABI functions, like platd's `glue.zig`.
- Everything above the boundary is native: channel ops are packed structs like every
  proto, interface and socket state machines are exhaustive enums, ring arithmetic
  and the config schema carry comptime proofs, and shared-memory shapes (`SockCtrl`)
  are extern structs whose size and field offsets are comptime-asserted, because a
  cross-process ABI is a layout promise and the compiler is where promises are kept.

### 3.6 Service lifecycle

netd's manifest declares `needs = platd,cfgd` and `provides = net`:

- `platd` registers its own name only once the firmware is fully settled, and netd
  orders itself behind that name: its routing question is asked of a service already
  in its serve loop. netd's own name doubles as its instance claim, so it is
  registered first; nothing downstream waits on it before the hardware is up.
- `cfgd` is in the boot target already; declaring it makes the watch in §7.3 always
  available rather than sometimes.
- First hardware touch only after the dependencies are up. Probe, claim, map, then
  drive; a dependency that cannot answer is a refusal, not a machine that stops.
- The boot line can hold the service down (`nonet`) or start it late under the boot
  watchdog (`netlate`) for one boot, which is how a suspect is isolated without
  touching the image.

## 4. atl2 ethernet driver (1969:2048)

Implemented and verified on the machine: probe, MAC read, rings, PCIe fixes, link
management, interrupts under deferred completion, rx of real LAN traffic and a
completed ARP round trip. The register-level narrative below is the reference the
implementation followed; `src/user/netd/atl2.zig` is the truth for current shapes.

### 4.1 Ring scheme (atl2's unusual design)

atl2 has NO scatter-gather descriptor ring. Three regions in ONE dma_alloc block:

- **TXD ring**: a plain byte FIFO (8 KB, dword-aligned) into which the CPU
  memcpy's `{ tx_pkt_header (4 B: pkt_size:11, ins_vlan:1, vlan:16) + frame bytes }`,
  dword-padded, wrapping at the end. Hardware consumes at its own read pointer; we
  tell it how far we've written via mailbox `REG_MB_TXD_WR_IDX (0x15F0)` = write ptr
  **>> 2** (dword index).
- **TXS ring**: 160 × 4-byte `tx_pkt_status` entries (ok/underrun/collision bits +
  `update` flag), hardware posts one per completed packet.
- **RXD ring**: 64 × 1536-byte fixed slots, each = `{ rx_pkt_status (incl. update,
  ok, crc, runt, frag, trunc, vlan, pkt_size:11) + packet }`. Hardware fills slots in
  order; we consume where `status.update == 1`, clear it, and advance mailbox
  `REG_MB_RXD_RD_IDX (0x15F4)`.

### 4.2 Init/reset sequence

The implemented sequence: soft reset, idle poll, PCIe block vendor defaults
(LTSSM_TEST_MODE 0x6500, PCIE_DLL_TX_CTRL1 0x568) with the four PCIe error-report
enables masked at the capability, MAC address from the working registers, PHY wake
with power-save cleared and link interrupts armed, ring bases and sizes, interrupt
moderation (ITIMER 200 µs), MTU and thresholds, mailboxes zeroed, DMA engines on,
status acknowledged whole. `MAC_CTRL` is written flat with the vendor's full value on
every link refresh (preamble, CRC, pad, flow control, PHY clock, broadcast accept).

### 4.3 Hot paths

TX: reap statuses, refuse when TXS or FIFO space is short, header + frame into the
FIFO with wrap, dword advance, mailbox write, posted-write flush. IRQ: ISR read
("not mine" on a shared line is a zero read), ack with the hold bit, PHY latch read
before the ack when the PHY raised it, reap rx slots and tx statuses, link refresh on
PHY events, release. Fatal events (DMA timeouts, PCIe link loss) take the full
reconfigure path and relink. The ISR narrates only what ordinary traffic does not
explain.

### 4.4 100 Mbit budget math @630 MHz

Full-duplex worst case, 1518 B frames, 8.1 kpps each way: ring copies ≈ 10%, stack
per-packet ≈ 3%, IRQ amortized ≈ 3% per direction. Total ≈ **28–33% CPU at full
duplex saturation**; ~17% for one-direction bulk. Memory bandwidth ~50 MB/s of the
~350 MB/s practical. The lwIP copy each way is inside these numbers (§3.3).

## 5. AR2425 WiFi driver (ath5k-class), honest design

Unchanged from v0 and still the plan for its own milestone: probe/EEPROM/reset
pipeline, softMAC MLME, WPA2-PSK supplicant with hardware CCMP and a software
fallback, minstrel-lite rate control, kill-switch surprise-removal handling. Two
integration points move with the stack decision: the driver feeds the same netif glue
as ethernet (802.11 to 802.3 translation stays in the driver), and EAPOL (0x888E)
frames are diverted to the supplicant before `netif.input`. Everything else in the
v0 §5 text stands and is not repeated here; see git history for the full section
until implementation revises it in place.

## 6. The stack: lwIP module map

What each requirement rides on, and what is deliberately off:

| Concern | Module | Notes |
|---|---|---|
| ARP | `etharp` | replaces nothing: the hand ARP probe stays as a driver diagnostic |
| IPv4 | `ip4` | one address per netif; no forwarding between netifs |
| ICMP | `icmp` | echo reply is free once up; echo request via a raw pcb for `ping` |
| DHCP client | `dhcp` | §7.4; lease events narrated; per-netif |
| DNS | `dns` | servers from DHCP option 6 or static config; `resolve` op for tools |
| UDP | `udp` | record rings in the bridge |
| TCP | `tcp` | byte rings in the bridge; NewReno; MSS 1460 |
| IPv6 | off | v1 statement, structures do not preclude it |
| AUTOIP | off | no address is better than a pretend one |
| IGMP/mDNS | off | with the multicast filter work, later |

There is no handrolled protocol code above the drivers. The pure `lib/eth.zig` frame
builder remains for the probe diagnostic and its host tests, not as a stack.

## 7. Interfaces: lifecycle, configuration, DHCP

### 7.1 Identity and state

An interface is named by its driver, with `.N` appended from the second instance of
the same driver (`atl2`, `e1000`, `e1000.1`). Configuration binds to the **role**,
not the name: `wired` (ethernet class) and `wifi` (802.11), because this machine has
exactly one of each and config outlives the driver that serves it.

State per interface, each level gating the next:

```
driven ──> enabled (user intent, persisted) ──> link (carrier) ──> addressed
```

`up` and `down` are the `enabled` bit. Down quiesces the engine (`ops.stop` level:
DMA idle, device IMR masked, netif admin-down, DHCP released) but keeps the claim and
the interrupt line, so up is cheap and nothing races a re-probe.

### 7.2 The `net` settings domain

One typed struct beside the existing domains in `proto/settings.zig`, stored by cfgd
at `/etc/net.cfg`, validated against the schema like every domain:

```zig
pub const NetRole = struct {
    enabled: bool = true,
    /// dhcp when empty; "a.b.c.d/nn" claims the address statically.
    address: []const u8 = "",
    gateway: []const u8 = "",
    /// Up to two, comma separated. Empty defers to the DHCP offer.
    dns: []const u8 = "",
};
pub const Net = struct {
    wired: NetRole = .{},
    wifi: NetRole = .{ .enabled = false },
};
```

The defaults are the whole zero-configuration story: an untouched machine brings the
wired port up and asks DHCP for an address.

### 7.3 Event-driven configuration

cfgd is the single writer of `/etc`; netd never writes config and tools never talk
netd into remembering anything. The `net` tool writes through cfgd; netd holds the
domain's watch event in its wait set, and a wake reloads the domain, diffs it against
running state and applies exactly the deltas: enable/disable, static address
assign/release, DHCP start/stop, DNS server update. One mechanism serves boot load
(initial read at start), the tool (every change lands as a watch wake) and any future
writer (the GUI's network panel writes the same domain).

### 7.4 DHCP

lwIP's DHCP client, inside netd, per netif. Policy: an interface that is enabled, has
link, and has no static address runs DHCP; a static address stops it. Lease, renew,
rebind and expiry all ride `sys_check_timeouts` (§3.1): no polling exists. Lease
acquisition and loss are narrated (`lease 192.168.178.27 for 864000s from
192.168.178.1`, `lease expired; asking again`), and `net` shows the lease and its
remaining time.

**There is no separate dhcpd process.** The requirement, an address for any upped
unconfigured interface, is interface configuration policy, and the actor that owns
netif addresses is the stack. A separate process would need address-set and lease
IPC, its own event loop and timers, and raw sockets that work before the interface
has an address, all to arrive at the same lwIP client code netd links anyway. It
would be a second network trust domain that isn't one: both processes would hold
`driver` over the same DMA-capable device class. If a future deployment wants DHCP
policy outside netd, the §7.3 watch mechanism is where it plugs in, by writing
static addresses into the domain.

### 7.5 The `provides = net` moment

netd registers `/svc/net` first as its instance claim (§3.6). Interfaces come up,
addresses arrive, asynchronously after; `net` reports honestly at every stage. The
boot does not wait for a DHCP lease: a machine on a dead cable boots at full speed
and says `wired: up, no address` when asked.

## 8. Socket bridge

The kernel already carries everything the bridge needs: channels transfer `event`,
`channel` and `shm` handles inside messages (at most four per message, refcounted),
and `wait_many` composes them. No kernel work is required.

### 8.1 Objects

Per client socket: one shm segment and two events.

- `shm` (40 KB TCP: one 4 KB control page, 16 KB tx ring, 16 KB rx ring; 20 KB UDP
  with record framing `{len:u16, addr:u32, port:u16, data..., pad to 8}`).
- `ev_app`, netd signals: data readable, space writable, state change.
- `doorbell`, the client signals: **one event shared by every client**, created by
  netd, transferred to each client at socket creation. SPSC rings per socket keep
  data private; the doorbell only says "someone produced", and netd walks its socket
  table on each ring. This is what keeps netd's wait set within the eight-source
  budget at any socket count.

The control page mirrors state for lock-free reads:

```zig
pub const SockCtrl = extern struct {
    tx_head: u32, tx_tail: u32,   // app produces at head; netd consumes at tail
    rx_head: u32, rx_tail: u32,   // netd produces; app consumes
    state: u32,                   // syn_sent/established/fin_wait/closed/...
    so_error: i32,                // reset/refused/net-down, valid when closed
};
```

### 8.2 Control ops (on `/svc/net`, packed structs like every proto)

```
tcp_connect{addr, port}      -> deferred reply on establish or failure:
                                {sock, shm, ev_app, doorbell}
tcp_listen{port, backlog}    -> {listener}
tcp_accept{listener}         -> deferred reply on next connection:
                                {sock, peer, shm, ev_app, doorbell}
udp_open{laddr, lport, raddr, rport} -> {sock, shm, ev_app, doorbell}
close{sock}                  -> errno   (graceful FIN, linger ≤ 5 s)
resolve{name}                -> deferred reply {n, addr[2]}   (lwIP dns)
ping{addr, timeout_ms}       -> deferred reply {rtt_us | timed_out}
```

Deferred replies are the channel model working for us: the server keeps the request
token and answers when the stack calls back, so a blocking `connect`, `accept`,
`resolve` or `ping` costs the client nothing but its own wait, and costs netd
nothing at all. Data never crosses the channel; only establishment, teardown and
questions do.

Client death: handles die with the process, netd's next ring touch or FIN sees the
peer gone and aborts the pcb. netd death: clients' waits return on dead handles,
sockets read as reset, the supervisor restarts netd, and TCP state is gone, exactly
what a router reboot looks like. No transparent resurrection.

### 8.3 What v1 does not do

No POSIX/libc socket shim yet: `ping` and `nc` use the native client library
(`user/lib/` wrapper over these ops). The shim belongs to the C-apps milestone and
layers on this bridge without changing it. No `select` semantics beyond `wait_many`
over `ev_app` handles. No out-of-band, no socket options beyond NODELAY.

## 9. Tools

- `net`: status (per interface: driver, role, enabled, link, address and how it was
  obtained, lease remaining, counters). Verbs write config and cfgd's watch delivers
  them (§7.3): `net wired up`, `net wired down`, `net wired dhcp`,
  `net wired static 192.168.178.50/24 gw 192.168.178.1 [dns 192.168.178.1]`.
  Diagnostics stay: `net -p <ip>` (driver-level ARP probe), `net -s` (lwIP stats,
  debug builds).
- `ping <addr|name> [-c n]`: resolves if needed, then one `ping` op per second, each
  a deferred-reply call; prints RTT per reply and a summary. Ctrl+C ends it like any
  tool. ICMP echo *reply* needs no tool: the stack answers pings the moment an
  interface is addressed.
- `nc <host> <port>` / `nc -l <port>` / `-u`: connect or listen, then one loop over
  `wait_many(stdin, ev_app)`: stdin to tx ring, doorbell; rx ring to stdout; closed
  state with drained ring exits with the peer's story (`so_error`). The first
  interactive proof that rings, events and the stack compose.

## 10. RAM / disk budget

| Item | Size |
|---|---|
| lwIP core, ReleaseSmall | ≈ 100–130 KB code in netd |
| lwIP pools (`MEM_SIZE` + pbufs + pcbs) | ≈ 160 KB static |
| netd binary total | ≤ 400 KB at this milestone (wifi adds its ≈ 250 KB later) |
| driver rings (dma, per §4) | ≈ 106 KB |
| socket shm | 40 KB per live TCP socket; tens, not hundreds, on this machine |
| Idle RAM share | ≈ 0.5 MB |

## 11. Bring-up & test plan

1. **QEMU is the stack's CI**: slirp answers DHCP, `ping 10.0.2.2` exercises ICMP
   both ways, `nc` against a hostfwd port proves TCP and the bridge, and the
   `make shot` transcript asserts the lease line and the ping RTT line. The e1000
   and rtl8139 drivers make all of it driver-plural.
2. **Host-native**: lwIP arrives with upstream's own test heritage; our pure code
   (`lib/eth.zig`, ring arithmetic, config parsing) keeps its host tests. The netif
   glue is deliberately too thin to need a harness.
3. **Hardware checklist**, in order: boot with defaults on the home LAN, watch the
   lease narration, `net` shows address and lease; `ping 192.168.178.1` under load;
   `nc` chat between the 701 and another machine both directions; `net wired static`
   round trip through cfgd survives reboot; cable pull mid-lease renarrates link and
   re-acquires on return; `no.netd` boot line still isolates everything.

## 12. Risks & open questions

- **lwIP in ReleaseSmall/32-bit**: mature territory, but the port header is ours;
  wrong `MEM_ALIGNMENT` or a signed `sys_now` wrap would be quiet corruption. The
  QEMU seam catches both on day one.
- **Doorbell fairness**: one doorbell means netd walks all sockets per wake; at this
  machine's socket counts the walk is trivial, and the design accepts it explicitly.
- **DNS trust**: the stub resolves against whatever DHCP names; no DNSSEC, stated.
- **Fn+F2 wired implications**: none, the kill switch gates only the mini-PCIe slot;
  wired keeps running.

## 13. Phasing

- **N1, the stack breathes**: vendor lwIP, port header, netif glue, cfg `net`
  domain + watch, interface lifecycle, DHCP policy, ICMP, `ping` op + tool, `net`
  verbs. Exit: on the machine, an untouched boot acquires a lease, `ping` answers
  and is answered, `net wired static` persists across reboot.
- **N2, streams**: socket bridge, native client library, `nc` both directions,
  `resolve`. Exit: `nc` chat with another machine over the home LAN; QEMU transcript
  asserts a TCP round trip.
- **N3, wifi**: §5 unchanged, feeding the same netif glue; DHCP and everything above
  it works on day one of a joined network.

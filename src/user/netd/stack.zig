//! The stack glue: one lwIP netif per driven interface, and the policy that
//! decides what each carries.
//!
//! Frames go up by copy into a pool pbuf and `ethernet_input`; frames come
//! down by flattening a pbuf chain into the driver's own transmit copy. One
//! copy each way beyond DMA, inside the budget design/08 section 4.4 already
//! pays. Addresses are policy: a configured static claim applies directly,
//! anything else enabled-with-link asks DHCP, and both arrive back here
//! through lwIP's own callbacks, where they are narrated.

const dev = @import("dev.zig");
const icmp = @import("lib").icmp;
const hostname = @import("lib").hostname;
const ifmatch = @import("lib").ifmatch;
const ipv4 = @import("lib").ipv4;
const log = @import("ulib").log;
const lwip = @import("lwip.zig");
const out = @import("ulib").out;
const proto_net = @import("proto").net;
const settings = @import("proto").settings;
const std = @import("std");
const sys = @import("sys");

const MAX = 4;

/// What policy last asked of an interface, so a config reload applies only
/// the differences.
const Mode = enum { down, dhcp, static_claim };

const Slot = struct {
    netif: lwip.Netif = .{},
    nic: ?*dev.NicDev = null,
    mode: Mode = .down,
};

var slots: [MAX]Slot = @splat(.{});
var count: usize = 0;

/// The machine's name, and the bytes lwIP hands to a DHCP server.
///
/// One of each, because there is one machine: every interface gives the
/// same answer to the same question, and lwIP keeps the pointer rather
/// than the bytes, so what it points at has to outlive the interface.
var chosen_name: hostname.Hostname = .{};
var current_name: hostname.Hostname = .{};
var name_bytes: [hostname.MAX + 1]u8 = @splat(0);

/// Settle the name and point every interface at it.
///
/// Called both when configuration arrives and when an interface does,
/// because the derived name comes from the first interface's own address
/// and neither event is reliably first.
fn refreshName() void {
    const address: [6]u8 = if (count > 0)
        if (slots[0].nic) |nic| nic.mac else @splat(0)
    else
        @splat(0);

    const settled = chosen_name.resolve(address);
    if (settled.eql(current_name)) return;

    current_name = settled;
    const text = settled.cString(&name_bytes);
    for (slots[0..count]) |*slot| slot.netif.hostname = text.ptr;

    log.begin("netd", .key);
    out.text("this machine is ");
    out.text(text);
    if (settled.isDerived()) out.text(", from its own address");
    log.end();
}

/// What the machine currently answers to, for whoever has to say it.
pub fn name() []const u8 {
    return std.mem.sliceTo(&name_bytes, 0);
}

pub fn init() void {
    lwip.lwip_init();
}

/// Deliver whatever the stack queued for its own addresses: the loopback
/// interface and any netif talking to itself. The event loop runs this
/// after every piece of work, and one call drains the queue completely,
/// conversations included, because delivery may queue the answer.
pub fn deliverLoopback() void {
    lwip.netif_poll_all();
}

/// Give a driven interface its netif. The first one is the default route's.
pub fn attach(nic: *dev.NicDev) void {
    if (count == MAX) return;
    const slot = &slots[count];
    slot.nic = nic;

    if (lwip.netif_add(&slot.netif, null, null, null, nic, netifInit, lwip.ethernet_input) == null) {
        log.warn("netd", "the stack refused the interface");
        slot.nic = null;
        return;
    }
    slot.netif.num = @intCast(count);
    if (count == 0) lwip.netif_set_default(&slot.netif);
    count += 1;

    refreshName();
    if (nic.state.up) lwip.netif_set_link_up(&slot.netif);
}

/// lwIP's one question at netif_add time: what this interface is.
fn netifInit(netif: *lwip.Netif) callconv(.c) lwip.Err {
    const nic: *dev.NicDev = @ptrCast(@alignCast(netif.state orelse return .arg));
    netif.mtu = 1500;
    netif.hwaddr = nic.mac;
    netif.hwaddr_len = nic.mac.len;
    netif.flags.broadcast = true;
    netif.flags.etharp = true;
    netif.name = .{ 'e', 'n' };
    netif.output = lwip.etharp_output;
    netif.linkoutput = linkOutput;
    netif.status_callback = statusChanged;
    netif.link_callback = linkChanged;
    return .ok;
}

/// Down the wire: flatten the chain into the driver's transmit, which copies
/// into its own ring either way. A refused transmit is ERR_MEM, which is the
/// answer lwIP retries on.
fn linkOutput(netif: *lwip.Netif, p: *lwip.Pbuf) callconv(.c) lwip.Err {
    const nic: *dev.NicDev = @ptrCast(@alignCast(netif.state orelse return .arg));

    if (p.next == null) {
        return if (nic.ops.transmit(nic, p.payload[0..p.len])) .ok else .mem;
    }

    var frame: [1518]u8 = undefined;
    if (p.tot_len > frame.len) return .arg;
    const took = lwip.pbuf_copy_partial(p, &frame, p.tot_len, 0);
    if (took != p.tot_len) return .arg;
    return if (nic.ops.transmit(nic, frame[0..took])) .ok else .mem;
}

/// Up the stack: every received frame, copied into a pool pbuf. Exhaustion
/// drops the frame; the pool refills as the stack consumes.
pub fn rx(nic: *dev.NicDev, frame: []const u8) void {
    const slot = slotOf(nic) orelse return;
    if (frame.len > std.math.maxInt(u16)) return;

    const p = lwip.pbuf_alloc(.raw, @intCast(frame.len), .pool) orelse return;
    if (lwip.pbuf_take(p, frame.ptr, @intCast(frame.len)) != .ok) {
        _ = lwip.pbuf_free(p);
        return;
    }
    const input = slot.netif.input orelse {
        _ = lwip.pbuf_free(p);
        return;
    };
    if (input(p, &slot.netif) != .ok) _ = lwip.pbuf_free(p);
}

/// The driver's link followed into the stack, which is also what makes the
/// DHCP client start discovery when the cable returns.
pub fn linkState(nic: *dev.NicDev, up: bool) void {
    const slot = slotOf(nic) orelse return;
    if (up) {
        lwip.netif_set_link_up(&slot.netif);
    } else {
        lwip.netif_set_link_down(&slot.netif);
    }
}

fn slotOf(nic: *dev.NicDev) ?*Slot {
    for (slots[0..count]) |*slot| {
        if (slot.nic == nic) return slot;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Policy: what the config domain says, applied as differences
// ---------------------------------------------------------------------------

/// Bind each configuration slot to its interface and apply what it says.
/// An interface no slot claims stays down: bringing traffic up is a choice
/// somebody wrote down, never a side effect of having hardware.
pub fn applyConfig(cfg: settings.Net) void {
    chosen_name = settings.netMachine(cfg).hostname;
    refreshName();

    // The comptime accessors unrolled into a runtime table, because which
    // slot governs which interface is decided at runtime by the binder.
    var wants: [settings.NET_SLOTS]settings.NetSlot = undefined;
    inline for (0..settings.NET_SLOTS) |i| wants[i] = settings.netSlot(cfg, i);

    var matches: [settings.NET_SLOTS]ifmatch.Match = undefined;
    for (&matches, wants) |*m, want| m.* = want.match;

    var ifaces: [MAX]ifmatch.Iface = undefined;
    for (slots[0..count], 0..) |slot, i| {
        const nic = slot.nic orelse continue;
        ifaces[i] = .{ .class = nic.class, .label = nic.label, .location = nic.location };
    }

    var bound: [MAX]?u8 = undefined;
    ifmatch.bind(&matches, ifaces[0..count], bound[0..count]);

    // A slot nothing claimed. The rest of the fields are whatever a slot
    // starts as, so a field added to the shape does not have to be added
    // here too.
    const parked = settings.NetSlot{ .match = .none, .enabled = false };
    for (slots[0..count], bound[0..count]) |*slot, claim| {
        applySlot(slot, if (claim) |s| wants[s] else parked);
    }

    // Statically named servers outrank whatever a lease suggested; the
    // first bound slot naming any speaks for the machine, because DNS is
    // one table however many interfaces feed it.
    for (bound[0..count]) |claim| {
        const want = wants[claim orelse continue];
        if (want.dns.first == 0 and want.dns.second == 0) continue;
        if (want.dns.first != 0) {
            const server = lwip.toWire(want.dns.first);
            lwip.dns_setserver(0, &server);
        }
        if (want.dns.second != 0) {
            const server = lwip.toWire(want.dns.second);
            lwip.dns_setserver(1, &server);
        }
        break;
    }
}

fn applySlot(slot: *Slot, role: settings.NetSlot) void {
    const nic = slot.nic orelse return;

    if (!role.enabled) {
        if (slot.mode == .down) return;
        if (slot.mode == .dhcp) lwip.dhcp_release_and_stop(&slot.netif);
        lwip.netif_set_down(&slot.netif);
        slot.mode = .down;
        say(nic, "taken down");
        return;
    }

    if (role.address.isSet()) {
        if (slot.mode == .dhcp) lwip.dhcp_release_and_stop(&slot.netif);
        // Mode first: the address write fires the status callback, which
        // reads the mode to say where the address came from.
        slot.mode = .static_claim;
        const addr = lwip.toWire(role.address.addr);
        const mask = lwip.toWire(role.address.mask());
        const gw = lwip.toWire(role.gateway.addr);
        lwip.netif_set_addr(&slot.netif, &addr, &mask, &gw);
        lwip.netif_set_up(&slot.netif);
        return;
    }

    // Enabled with nothing claimed: the interface comes up addressless and
    // DHCP asks. Restarting an already-running client is left to the client.
    if (slot.mode == .static_claim) {
        lwip.netif_set_addr(&slot.netif, &.{}, &.{}, &.{});
    }
    lwip.netif_set_up(&slot.netif);
    if (slot.mode != .dhcp) {
        if (lwip.dhcp_start(&slot.netif) == .ok) {
            slot.mode = .dhcp;
            say(nic, "asking dhcp");
        } else {
            log.warn("netd", "the dhcp client did not start");
        }
    }
}

/// The address changed under the netif: a lease arrived or expired, or a
/// static claim landed. Narrated here because this is the one place every
/// path converges.
fn statusChanged(netif: *lwip.Netif) callconv(.c) void {
    const nic: *dev.NicDev = @ptrCast(@alignCast(netif.state orelse return));
    if (netif.ip_addr.addr == 0) {
        if (netif.flags.up) say(nic, "no address");
        return;
    }

    log.begin(nic.name, .key);
    out.text("address ");
    sayAddr(lwip.fromWire(netif.ip_addr));
    if (netif.gw.addr != 0) {
        out.text(", gateway ");
        sayAddr(lwip.fromWire(netif.gw));
    }
    const slot = slotOf(nic) orelse {
        log.end();
        return;
    };
    if (slot.mode == .dhcp) {
        if (netif.dhcpData()) |lease| {
            out.text(", leased for ");
            out.decimal(lease.leaseRemaining());
            out.text("s");
        }
    }
    log.end();
}

fn linkChanged(netif: *lwip.Netif) callconv(.c) void {
    const nic: *dev.NicDev = @ptrCast(@alignCast(netif.state orelse return));
    say(nic, if (netif.flags.link_up) "carrier" else "no carrier");
}

fn say(nic: *dev.NicDev, what: []const u8) void {
    log.say(nic.name, .dim, what);
}

fn sayAddr(addr: u32) void {
    var field: [15]u8 = undefined;
    out.text(ipv4.text(addr, &field));
}

/// The current address story for one interface, for the `net` reply.
pub const AddressView = struct {
    addr: u32 = 0,
    prefix: u8 = 0,
    gateway: u32 = 0,
    source: proto_net.AddrSource = .none,
    lease_remaining_s: u32 = 0,
};

pub fn addressOf(nic: *dev.NicDev) AddressView {
    const slot = slotOf(nic) orelse return .{};
    var view = AddressView{
        .addr = lwip.fromWire(slot.netif.ip_addr),
        .prefix = prefixOf(lwip.fromWire(slot.netif.netmask)),
        .gateway = lwip.fromWire(slot.netif.gw),
    };
    switch (slot.mode) {
        .down => {},
        .static_claim => view.source = .static_claim,
        .dhcp => {
            if (view.addr != 0) view.source = .dhcp;
            if (slot.netif.dhcpData()) |lease| {
                view.lease_remaining_s = lease.leaseRemaining();
            }
        },
    }
    return view;
}

fn prefixOf(mask: u32) u8 {
    return @popCount(mask);
}

// ---------------------------------------------------------------------------
// The ping op: one echo in flight, answered by callback
// ---------------------------------------------------------------------------

/// What the serve loop hands us to finish a ping with. One outstanding echo:
/// the tool paces itself, and a second asker meets `refused` rather than a
/// table.
pub const PingDone = *const fn (rtt_us: u64) void;
pub const PingTimeout = *const fn () void;

var ping_pcb: ?*lwip.RawPcb = null;
var ping_busy = false;
var ping_ident: u16 = 0;
var ping_sequence: u16 = 0;
var ping_sent_at: u64 = 0;
var ping_done: ?PingDone = null;
var ping_timed_out: ?PingTimeout = null;

/// Send one echo request. False when the stack cannot, in which case nothing
/// was sent and nothing will call back.
pub fn ping(addr: u32, timeout_ms: u32, done: PingDone, timed_out: PingTimeout) bool {
    if (ping_busy) return false;

    const pcb = ping_pcb orelse blk: {
        const fresh = lwip.raw_new(lwip.PROTO_ICMP) orelse return false;
        if (lwip.raw_bind(fresh, &.{}) != .ok) return false;
        lwip.raw_recv(fresh, pingReply, null);
        ping_pcb = fresh;
        break :blk fresh;
    };

    ping_sequence +%= 1;
    ping_ident = @truncate(@as(u32, @intCast(sys.clockMicros())) | 1);

    const p = lwip.pbuf_alloc(.ip, icmp.MESSAGE, .ram) orelse return false;
    var message: [icmp.MESSAGE]u8 = undefined;
    icmp.request(&message, ping_ident, ping_sequence);
    if (lwip.pbuf_take(p, &message, icmp.MESSAGE) != .ok) {
        _ = lwip.pbuf_free(p);
        return false;
    }

    const target = lwip.toWire(addr);
    const sent = lwip.raw_sendto(pcb, p, &target);
    _ = lwip.pbuf_free(p);
    if (sent != .ok) return false;

    ping_busy = true;
    ping_sent_at = @intCast(sys.clockMicros());
    ping_done = done;
    ping_timed_out = timed_out;
    lwip.sys_timeout(timeout_ms, pingExpired, null);
    return true;
}

/// The first byte of an IPv4 header, as fields: how a raw receive finds its
/// payload past the header the pcb includes.
const VersionIhl = packed struct(u8) {
    /// Header length in 32-bit words.
    ihl: u4,
    version: u4,
};

fn pingReply(_: ?*anyopaque, _: *lwip.RawPcb, p: *lwip.Pbuf, _: *const lwip.Ip4Addr) callconv(.c) u8 {
    if (!ping_busy) return 0;

    var packet: [lwip.IP_HEADER + 40 + icmp.MESSAGE]u8 = undefined;
    const have = lwip.pbuf_copy_partial(p, &packet, @min(p.tot_len, packet.len), 0);
    if (have < 1) return 0;

    const shape: VersionIhl = @bitCast(packet[0]);
    const header: usize = @as(usize, shape.ihl) * 4;
    if (shape.version != 4 or have < header) return 0;
    if (!icmp.isReply(packet[header..have], ping_ident, ping_sequence)) return 0;

    const done = ping_done;
    finishPing();
    _ = lwip.pbuf_free(p);
    if (done) |call| call(@as(u64, @intCast(sys.clockMicros())) - ping_sent_at);
    return 1;
}

fn pingExpired(_: ?*anyopaque) callconv(.c) void {
    if (!ping_busy) return;
    const timed_out = ping_timed_out;
    ping_busy = false;
    ping_done = null;
    ping_timed_out = null;
    if (timed_out) |call| call();
}

fn finishPing() void {
    lwip.sys_untimeout(pingExpired, null);
    ping_busy = false;
    ping_done = null;
    ping_timed_out = null;
}

// ---------------------------------------------------------------------------
// The loop's two hooks
// ---------------------------------------------------------------------------

/// Run whatever the stack owes: retransmits, leases, ARP aging. Called after
/// every wake, whatever the reason.
pub fn tick() void {
    lwip.sys_check_timeouts();
}

/// Microseconds until the stack next needs the loop, for the wait deadline.
/// Null when it holds no timer at all.
pub fn nextDeadline() ?u64 {
    const ms = lwip.sys_timeouts_sleeptime();
    if (ms == std.math.maxInt(u32)) return null;
    return @as(u64, ms) * 1000;
}

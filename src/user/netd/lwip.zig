//! The lwIP boundary: the C shapes and entry points the glue touches.
//!
//! Hand-mirrored rather than inhaled: every struct, offset and constant here
//! is pinned twice, by the comptime assertions below on this side and by
//! `lwipport/layout_check.c` against the vendored headers on the other. A
//! header change and a mirror change each fail the build on their own.
//!
//! Addresses cross this boundary in network byte order, which on this little
//! endian machine is the byte-swapped image of `lib.ipv4`'s wire-order words;
//! `fromWire`/`toWire` are that one conversion, named.

const log = @import("ulib").log;
const std = @import("std");
const sys = @import("sys");

pub const Err = enum(i8) {
    ok = 0,
    mem = -1,
    buf = -2,
    timeout = -3,
    rte = -4,
    inprogress = -5,
    val = -6,
    wouldblock = -7,
    use = -8,
    already = -9,
    isconn = -10,
    conn = -11,
    interface = -12,
    abrt = -13,
    rst = -14,
    clsd = -15,
    arg = -16,
    _,
};

/// An IPv4 address as lwIP holds it: one word in network byte order.
pub const Ip4Addr = extern struct { addr: u32 = 0 };

/// `lib.ipv4`'s wire-order word from lwIP's in-memory representation.
pub fn fromWire(a: Ip4Addr) u32 {
    return @byteSwap(a.addr);
}

pub fn toWire(addr: u32) Ip4Addr {
    return .{ .addr = @byteSwap(addr) };
}

pub const Pbuf = extern struct {
    next: ?*Pbuf,
    payload: [*]u8,
    tot_len: u16,
    len: u16,
    type_internal: u8,
    flags: u8,
    ref: u8,
    if_idx: u8,
};

pub const ETH_HEADER = 14;
pub const IP_HEADER = 20;
pub const TRANSPORT_HEADER = 20;

/// Where a new pbuf's payload starts: the header room the layer needs,
/// derived from the headers themselves rather than quoted.
pub const Layer = enum(c_int) {
    raw = 0,
    link = ETH_HEADER,
    ip = ETH_HEADER + IP_HEADER,
    transport = ETH_HEADER + IP_HEADER + TRANSPORT_HEADER,
};

/// How a pbuf is allocated and what may be assumed about it: lwIP encodes
/// this as flag arithmetic, mirrored here as the fields those flags are.
pub const PbufKind = packed struct(u32) {
    /// 0 is the byte heap, 1 the pbuf pool, 2 the frame pool.
    alloc_source: u4 = 0,
    _4: u2 = 0,
    data_volatile: bool = false,
    struct_data_contiguous: bool = false,
    rx: bool = false,
    data_contiguous: bool = false,
    _10: u22 = 0,

    /// A frame buffer from the receive pool.
    pub const pool = PbufKind{ .alloc_source = 2, .struct_data_contiguous = true, .rx = true };
    /// Struct and payload in one heap allocation, contiguous.
    pub const ram = PbufKind{ .alloc_source = 0, .struct_data_contiguous = true, .data_contiguous = true };
    /// Struct only; the payload belongs to someone else and may change.
    pub const ref = PbufKind{ .alloc_source = 1, .data_volatile = true };
};

/// The netif flag byte, as fields.
pub const Flags = packed struct(u8) {
    up: bool = false,
    broadcast: bool = false,
    link_up: bool = false,
    etharp: bool = false,
    ethernet: bool = false,
    igmp: bool = false,
    mld6: bool = false,
    _7: u1 = 0,
};

pub const InputFn = *const fn (*Pbuf, *Netif) callconv(.c) Err;
pub const OutputFn = *const fn (*Netif, *Pbuf, *const Ip4Addr) callconv(.c) Err;
pub const LinkOutputFn = *const fn (*Netif, *Pbuf) callconv(.c) Err;
pub const NetifCallbackFn = *const fn (*Netif) callconv(.c) void;
pub const NetifInitFn = *const fn (*Netif) callconv(.c) Err;

pub const Netif = extern struct {
    next: ?*Netif = null,
    ip_addr: Ip4Addr = .{},
    netmask: Ip4Addr = .{},
    gw: Ip4Addr = .{},
    input: ?InputFn = null,
    output: ?OutputFn = null,
    linkoutput: ?LinkOutputFn = null,
    status_callback: ?NetifCallbackFn = null,
    link_callback: ?NetifCallbackFn = null,
    state: ?*anyopaque = null,
    /// One client slot: the DHCP state, when the client runs on this netif.
    client_data: [1]?*anyopaque = @splat(null),
    /// The name this machine gives in a lease request. lwIP keeps the
    /// pointer rather than the bytes, so whatever it names has to outlive
    /// the interface.
    hostname: ?[*:0]const u8 = null,
    mtu: u16 = 0,
    hwaddr: [6]u8 = @splat(0),
    hwaddr_len: u8 = 0,
    flags: Flags = .{},
    name: [2]u8 = @splat(0),
    num: u8 = 0,
    /// The loopback queue: frames a netif sends to its own address wait
    /// here for `netif_poll_all`, which the event loop runs after every
    /// piece of work.
    loop_first: ?*Pbuf = null,
    loop_last: ?*Pbuf = null,
    loop_cnt_current: u16 = 0,

    pub fn dhcpData(self: *const Netif) ?*const Dhcp {
        return @ptrCast(@alignCast(self.client_data[0] orelse return null));
    }
};

pub const DhcpState = enum(u8) {
    off = 0,
    bound = 10,
    _,
};

/// The DHCP client's own record, read for the lease view `net` reports.
pub const Dhcp = extern struct {
    xid: u32,
    pcb_allocated: u8,
    state: DhcpState,
    tries: u8,
    dhcp_flags: u8,
    request_timeout: u16,
    t1_timeout: u16,
    t2_timeout: u16,
    t1_renew_time: u16,
    t2_rebind_time: u16,
    /// Coarse-timer ticks since the last acknowledgement; one tick is
    /// `COARSE_TIMER_SECS`.
    lease_used: u16,
    t0_timeout: u16,
    server_ip_addr: Ip4Addr,
    offered_ip_addr: Ip4Addr,
    offered_sn_mask: Ip4Addr,
    offered_gw_addr: Ip4Addr,
    /// Lease period in seconds.
    offered_t0_lease: u32,
    offered_t1_renew: u32,
    offered_t2_rebind: u32,

    pub const COARSE_TIMER_SECS = 60;

    pub fn leaseRemaining(self: *const Dhcp) u32 {
        const used = @as(u32, self.lease_used) * COARSE_TIMER_SECS;
        return self.offered_t0_lease -| used;
    }
};

/// The raw protocol number the ping op listens on.
pub const PROTO_ICMP: u8 = 1;

pub const RawPcb = opaque {};
pub const RawRecvFn = *const fn (?*anyopaque, *RawPcb, *Pbuf, *const Ip4Addr) callconv(.c) u8;
pub const TimeoutFn = *const fn (?*anyopaque) callconv(.c) void;

/// Protocol control blocks stay opaque: the bridge holds pointers and asks
/// questions through functions. The one exception is the connection prefix
/// below, mirrored for the peer's name because no function answers it.
pub const TcpPcb = opaque {};
pub const UdpPcb = opaque {};

/// The head every connection pcb starts with, as far as the remote port:
/// who a connection is with, for narration and grants. Pinned like every
/// mirror here, on both sides.
pub const TcpPcbPeek = extern struct {
    local_ip: Ip4Addr,
    remote_ip: Ip4Addr,
    netif_idx: u8,
    so_options: u8,
    tos: u8,
    ttl: u8,
    next: ?*anyopaque,
    callback_arg: ?*anyopaque,
    state: c_int,
    prio: u8,
    local_port: u16,
    remote_port: u16,
};

pub const TcpPeer = struct { addr: u32, port: u16 };

pub fn tcpPeer(pcb: *TcpPcb) TcpPeer {
    const peek: *const TcpPcbPeek = @ptrCast(@alignCast(pcb));
    return .{ .addr = fromWire(peek.remote_ip), .port = peek.remote_port };
}

/// `tcp_write` copies the bytes before returning, which is what lets the
/// caller's ring slot be consumed immediately.
pub const TCP_WRITE_COPY: u8 = 0x01;

pub const TcpConnectedFn = *const fn (?*anyopaque, *TcpPcb, Err) callconv(.c) Err;
/// A null pbuf is the peer's FIN.
pub const TcpRecvFn = *const fn (?*anyopaque, *TcpPcb, ?*Pbuf, Err) callconv(.c) Err;
pub const TcpSentFn = *const fn (?*anyopaque, *TcpPcb, u16) callconv(.c) Err;
/// The pcb is already freed when this is called.
pub const TcpErrFn = *const fn (?*anyopaque, Err) callconv(.c) void;
pub const TcpAcceptFn = *const fn (?*anyopaque, ?*TcpPcb, Err) callconv(.c) Err;
pub const UdpRecvFn = *const fn (?*anyopaque, *UdpPcb, *Pbuf, *const Ip4Addr, u16) callconv(.c) void;
pub const DnsFoundFn = *const fn ([*:0]const u8, ?*const Ip4Addr, ?*anyopaque) callconv(.c) void;

comptime {
    // The Zig half of the layout proof; layout_check.c is the C half.
    if (@sizeOf(Netif) != 76) @compileError("netif mirror size drifted");
    if (@offsetOf(Netif, "input") != 16 or
        @offsetOf(Netif, "linkoutput") != 24 or
        @offsetOf(Netif, "state") != 36 or
        @offsetOf(Netif, "client_data") != 40 or
        @offsetOf(Netif, "hostname") != 44 or
        @offsetOf(Netif, "mtu") != 48 or
        @offsetOf(Netif, "hwaddr") != 50 or
        @offsetOf(Netif, "flags") != 57 or
        @offsetOf(Netif, "num") != 60 or
        @offsetOf(Netif, "loop_first") != 64 or
        @offsetOf(Netif, "loop_cnt_current") != 72)
    {
        @compileError("netif mirror fields drifted");
    }
    if (@sizeOf(Pbuf) != 16 or @offsetOf(Pbuf, "tot_len") != 8 or @offsetOf(Pbuf, "ref") != 14) {
        @compileError("pbuf mirror drifted");
    }
    if (@offsetOf(Dhcp, "state") != 5 or
        @offsetOf(Dhcp, "lease_used") != 18 or
        @offsetOf(Dhcp, "server_ip_addr") != 24 or
        @offsetOf(Dhcp, "offered_ip_addr") != 28 or
        @offsetOf(Dhcp, "offered_t0_lease") != 40)
    {
        @compileError("dhcp mirror drifted");
    }
    if (@offsetOf(TcpPcbPeek, "remote_ip") != 4 or
        @offsetOf(TcpPcbPeek, "local_port") != 26 or
        @offsetOf(TcpPcbPeek, "remote_port") != 28)
    {
        @compileError("tcp pcb prefix mirror drifted");
    }
    const flag_bits: u8 = @bitCast(Flags{ .up = true });
    const broadcast_bits: u8 = @bitCast(Flags{ .broadcast = true });
    const etharp_bits: u8 = @bitCast(Flags{ .etharp = true });
    if (flag_bits != 0x01 or broadcast_bits != 0x02 or etharp_bits != 0x08) {
        @compileError("netif flag bits drifted");
    }
    if (@as(u32, @bitCast(PbufKind.pool)) != 0x0182 or
        @as(u32, @bitCast(PbufKind.ram)) != 0x0280 or
        @as(u32, @bitCast(PbufKind.ref)) != 0x0041)
    {
        @compileError("pbuf kind fields drifted from lwIP's flag values");
    }
}

// ---------------------------------------------------------------------------
// The entry points the glue calls
// ---------------------------------------------------------------------------

pub extern fn lwip_init() void;
pub extern fn sys_check_timeouts() void;
pub extern fn sys_timeouts_sleeptime() u32;
pub extern fn sys_timeout(msecs: u32, handler: TimeoutFn, arg: ?*anyopaque) void;
pub extern fn sys_untimeout(handler: TimeoutFn, arg: ?*anyopaque) void;

pub extern fn netif_add(
    netif: *Netif,
    ipaddr: ?*const Ip4Addr,
    netmask: ?*const Ip4Addr,
    gw: ?*const Ip4Addr,
    state: ?*anyopaque,
    init: NetifInitFn,
    input: InputFn,
) ?*Netif;
pub extern fn netif_set_default(netif: *Netif) void;
pub extern fn netif_set_up(netif: *Netif) void;
pub extern fn netif_set_down(netif: *Netif) void;
pub extern fn netif_set_link_up(netif: *Netif) void;
pub extern fn netif_set_link_down(netif: *Netif) void;
pub extern fn netif_set_addr(
    netif: *Netif,
    ipaddr: ?*const Ip4Addr,
    netmask: ?*const Ip4Addr,
    gw: ?*const Ip4Addr,
) void;

pub extern fn netif_poll_all() void;

pub extern fn ethernet_input(p: *Pbuf, netif: *Netif) Err;
pub extern fn etharp_output(netif: *Netif, q: *Pbuf, addr: *const Ip4Addr) Err;

pub extern fn pbuf_alloc(layer: Layer, length: u16, kind: PbufKind) ?*Pbuf;
pub extern fn pbuf_free(p: *Pbuf) u8;
pub extern fn pbuf_take(p: *Pbuf, data: *const anyopaque, len: u16) Err;
pub extern fn pbuf_take_at(p: *Pbuf, data: *const anyopaque, len: u16, offset: u16) Err;
pub extern fn pbuf_copy_partial(p: *const Pbuf, into: *anyopaque, len: u16, offset: u16) u16;

pub extern fn dhcp_start(netif: *Netif) Err;
pub extern fn dhcp_release_and_stop(netif: *Netif) void;

pub extern fn dns_setserver(index: u8, server: *const Ip4Addr) void;

pub extern fn raw_new(proto: u8) ?*RawPcb;
pub extern fn raw_bind(pcb: *RawPcb, addr: *const Ip4Addr) Err;
pub extern fn raw_recv(pcb: *RawPcb, handler: RawRecvFn, arg: ?*anyopaque) void;
pub extern fn raw_sendto(pcb: *RawPcb, p: *Pbuf, addr: *const Ip4Addr) Err;

pub extern fn tcp_new() ?*TcpPcb;
pub extern fn tcp_arg(pcb: *TcpPcb, arg: ?*anyopaque) void;
pub extern fn tcp_bind(pcb: *TcpPcb, addr: ?*const Ip4Addr, port: u16) Err;
pub extern fn tcp_connect(pcb: *TcpPcb, addr: *const Ip4Addr, port: u16, connected: TcpConnectedFn) Err;
pub extern fn tcp_listen_with_backlog(pcb: *TcpPcb, backlog: u8) ?*TcpPcb;
pub extern fn tcp_accept(pcb: *TcpPcb, accept: TcpAcceptFn) void;
pub extern fn tcp_recv(pcb: *TcpPcb, recv: TcpRecvFn) void;
pub extern fn tcp_sent(pcb: *TcpPcb, sent: TcpSentFn) void;
pub extern fn tcp_err(pcb: *TcpPcb, err: TcpErrFn) void;
pub extern fn tcp_recved(pcb: *TcpPcb, len: u16) void;
pub extern fn tcp_write(pcb: *TcpPcb, data: *const anyopaque, len: u16, apiflags: u8) Err;
pub extern fn tcp_output(pcb: *TcpPcb) Err;
pub extern fn tcp_close(pcb: *TcpPcb) Err;
pub extern fn tcp_abort(pcb: *TcpPcb) void;

pub extern fn udp_new() ?*UdpPcb;
pub extern fn udp_remove(pcb: *UdpPcb) void;
pub extern fn udp_bind(pcb: *UdpPcb, addr: ?*const Ip4Addr, port: u16) Err;
pub extern fn udp_connect(pcb: *UdpPcb, addr: *const Ip4Addr, port: u16) Err;
pub extern fn udp_recv(pcb: *UdpPcb, recv: UdpRecvFn, arg: ?*anyopaque) void;
pub extern fn udp_send(pcb: *UdpPcb, p: *Pbuf) Err;
pub extern fn udp_sendto(pcb: *UdpPcb, p: *Pbuf, addr: *const Ip4Addr, port: u16) Err;

pub extern fn dns_gethostbyname(
    name: [*:0]const u8,
    addr: *Ip4Addr,
    found: DnsFoundFn,
    arg: ?*anyopaque,
) Err;

// ---------------------------------------------------------------------------
// The port hooks lwIP calls back
// ---------------------------------------------------------------------------

/// Milliseconds since boot, the one clock the stack keeps time by.
export fn sys_now() callconv(.c) u32 {
    return @truncate(@as(u64, @intCast(sys.clockMicros())) / 1000);
}

/// For DHCP transaction ids and TCP sequence numbers, from the machine's own
/// pool. A sequence number somebody else can work out is a connection somebody
/// else can interfere with, and the clock is not a secret.
export fn netd_lwip_rand() callconv(.c) c_uint {
    var bytes: [@sizeOf(c_uint)]u8 = undefined;
    _ = sys.random(&bytes);
    return @bitCast(bytes);
}

/// A failed stack invariant. The stack's state is not trustworthy past this
/// point, so the process ends and the supervisor restarts it clean.
export fn netd_lwip_assert(message: [*:0]const u8) callconv(.c) void {
    log.fail("netd", "stack invariant failed");
    log.fail("netd", std.mem.span(message));
    sys.exit(1);
}

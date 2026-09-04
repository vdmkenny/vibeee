//! netd: the network interface service.
//!
//! One process, one thread, one event loop, per design/08-network.md §1: a
//! 630 MHz core buys no parallelism from threads and pays locks. Everything
//! here waits on `wait_many`: the service channel and the interrupt lines of
//! the adapters it was handed. Nothing polls.
//!
//! Started by init once the platform service has published its name, which
//! only happens with the firmware fully settled. The /svc name doubles as
//! the claim, so a second instance finds the name taken and steps aside
//! rather than fight the first for the hardware.
//!
//! The drivers themselves live beside this file, one module each, behind one
//! interface (`dev.zig`). Above them, `stack.zig` runs lwIP: addresses,
//! DHCP, ICMP and the policy the `net` settings domain declares, all inside
//! this one loop, whose wait deadline is the stack's own next timer.

const ar5212 = @import("ar5212.zig");
const atl2 = @import("atl2.zig");
const rtl8139 = @import("rtl8139.zig");
const dev = @import("dev.zig");
const e1000 = @import("e1000.zig");

// The routines lwIP's C calls by name, emitted into this binary from the
// libc's own C-callable half: one implementation in the system, not two.
comptime {
    _ = @import("clibc");
}
const log = @import("ulib").log;
const out = @import("ulib").out;
const irqroute = @import("ulib").irqroute;
const pci = @import("ulib").pci;
const platform = @import("proto").platform;
const proto = @import("proto").net;
const proto_devices = @import("proto").devices;
const bridge = @import("bridge.zig");
const settings = @import("proto").settings;
const stack = @import("stack.zig");
const station = @import("station.zig");
const std = @import("std");
const sys = @import("sys");
const str = @import("lib").str;
const lib = @import("lib");
const quit = @import("ulib").quit;

/// The drivers this build knows, each with the ids that recognise its card.
/// Adding a driver is one line here and a module beside; startup does not
/// change.
const Driver = struct {
    name: []const u8,
    ops: dev.NicOps,
    /// What kind of interface the driver produces. Configuration slots
    /// match on it, so a radio and a wired port are told apart before
    /// either has a name.
    class: lib.ifmatch.Class = .ether,
};

/// Which silicon each of these fits is the device manager's knowledge,
/// declared in `/lib/drivers/*.man`; this table only joins a name the
/// manager assigns to the code compiled in beside this file.
const DRIVERS = [_]Driver{
    .{ .name = e1000.name, .ops = e1000.ops },
    .{ .name = atl2.name, .ops = atl2.ops },
    .{ .name = rtl8139.name, .ops = rtl8139.ops },
    .{ .name = ar5212.name, .ops = ar5212.ops, .class = ar5212.class },
};

comptime {
    // A radio is reached entirely through its radio table: nothing above
    // the driver names one. A driver that calls itself a radio and brings
    // no table would be an interface the station could do nothing with,
    // so it is not one that compiles.
    for (DRIVERS) |driver| {
        if ((driver.class == .wifi) != (driver.ops.radio != null)) {
            @compileError("`" ++ driver.name ++ "` disagrees with itself about being a radio");
        }
    }
}

/// How many interfaces a machine of this class can have behind one service.
const MAX_IFACES = 4;

var ifaces: [MAX_IFACES]dev.NicDev = @splat(.{ .name = "", .ops = undefined, .location = .{ .bus = 0, .device = 0, .function = 0 } });
var count: usize = 0;

export fn _start() callconv(.c) noreturn {
    netdMain();
}

fn netdMain() noreturn {
    // The claim, before the hardware: a second instance started for a second
    // adapter must stand down cleanly, not duel the first.
    const channel = sys.svcRegister(proto.SERVICE);
    if (channel < 0) {
        log.note("netd", "already serving; letting this instance stand down");
        sys.exit(0);
    }

    // The hooks before the hardware. A driver is started by the adopting
    // below, and starting is when it reports itself up; a radio says that
    // exactly once, and a report made to a hook nobody has taken yet is
    // made to nobody. The station never began, so it never hopped, so a
    // radio sat on the channel it was first tuned to and heard whatever
    // happened to be there.
    //
    // Frames may arrive from this point, and one for an interface the
    // stack has not been given yet is dropped where it lands rather than
    // being a reason to start the hardware first.
    stack.init();
    dev.stack_rx = stack.rx;
    dev.stack_link = stack.linkState;
    dev.changed = addressChanged;
    station.init();

    _ = adopt();

    if (count == 0) {
        log.warn("netd", "no adapter matched a driver");
    }

    for (ifaces[0..count]) |*iface| stack.attach(iface);
    stack.applyConfig(settings.load("net"));

    // A radio the firmware leaves powered down is on no bus, so there was
    // nothing to adopt and nothing configuration could be applied to. Asked
    // for once here when configuration says it should be in use: the key
    // that would otherwise ask is handled by the firmware itself on this
    // machine and never arrives, so nothing else would ever ask.
    if (stack.isEnabled(.wifi) and !anyOfClass(.wifi)) setWireless(true);

    serve(@intCast(channel));
}

/// Take every device the manager has assigned this service that is not
/// already driven here, and bring each up. Answers how many joined.
///
/// The same walk at boot and afterwards: a radio switched on by a person is
/// hardware that arrived, and nothing about adopting it differs from adopting
/// what was there when the machine started. Devices already driven are passed
/// over by where they are, so a walk that runs again over a machine that has
/// not changed changes nothing.
fn adopt() usize {
    var joined: usize = 0;
    var index: u32 = 0;
    while (count < MAX_IFACES) : (index += 1) {
        var assignment = proto_devices.Assignment{};
        proto_devices.claimNext(proto.SERVICE, index, &assignment) catch break;

        const location: lib.pci.Location = @bitCast(assignment.location);
        if (driving(location)) continue;

        const driver = driverNamed(assignment.driverSlice()) orelse {
            log.warn("netd", "assigned a driver this build does not carry");
            continue;
        };

        // Built where it will live, and brought up there. Starting a
        // driver hands it this address and it keeps it: the station holds
        // the radio by it for as long as the radio is driven, so an
        // interface brought up somewhere else and copied here afterwards
        // leaves everything that was handed the address pointing at a
        // place nothing owns any more.
        ifaces[count] = .{
            .name = driver.name,
            .label = labelFor(driver.name),
            .class = driver.class,
            .ops = driver.ops,
            .location = location,
        };

        log.begin("netd", .key);
        out.text(driver.name);
        out.text(" at ");
        var place: [8]u8 = undefined;
        out.text(lib.pci.spell(location, &place));
        out.text(" is ours to drive");
        log.end();

        if (!attach(&ifaces[count])) continue;
        count += 1;
        joined += 1;
        log.note("netd", "driving the hardware");
    }
    return joined;
}

/// Whether an interface of this kind is being driven here.
fn anyOfClass(class: lib.ifmatch.Class) bool {
    for (ifaces[0..count]) |iface| {
        if (iface.class == class) return true;
    }
    return false;
}

fn driving(location: lib.pci.Location) bool {
    for (ifaces[0..count]) |iface| {
        if (iface.location.eql(location)) return true;
    }
    return false;
}

fn driverNamed(wanted: []const u8) ?*const Driver {
    for (&DRIVERS) |*driver| {
        if (std.mem.eql(u8, driver.name, wanted)) return driver;
    }
    return null;
}

/// The label an interface answers to: the driver's name, and an ordinal
/// from the second interface of one driver, so two cards of one kind stay
/// tellable apart in listings and in configuration.
fn labelFor(driver_name: []const u8) lib.ifmatch.Name {
    var same: usize = 0;
    for (ifaces[0..count]) |iface| {
        if (std.mem.eql(u8, iface.name, driver_name)) same += 1;
    }
    if (same == 0) {
        return lib.ifmatch.Name.of(driver_name) orelse .{};
    }
    var buf: [lib.ifmatch.NAME_MAX]u8 = undefined;
    var b = str.Builder{ .buf = &buf };
    b.text(driver_name);
    b.byte('.');
    b.number(same);
    return lib.ifmatch.Name.of(b.done()) orelse .{};
}

/// Map, open and interrupt-wire one interface.
fn attach(iface: *dev.NicDev) bool {
    if (sys.claimDevice(iface.location) < 0) {
        log.warn("netd", "the adapter is already claimed");
        return false;
    }
    var keep_claim = false;
    defer if (!keep_claim) {
        _ = sys.releaseDevice(iface.location);
    };

    const line = routedLine(iface);

    // Lines are shared on this machine's wiring, and the kernel hands a
    // line to one holder. One process holding it once is enough: every
    // driver on the line gets the wake, and each reads its own ISR and
    // says "not mine" with no other cost. So a line already taken here is
    // shared, not refused.
    if (line) |gsi| {
        iface.irq_gsi = gsi;
        var shared = false;
        for (ifaces[0..count]) |other| {
            if (other.irq != 0 and other.irq_gsi == gsi) {
                iface.irq = other.irq;
                shared = true;
                break;
            }
        }
        if (!shared) {
            iface.irq = sys.irqAttach(gsi) catch {
                log.warn("netd", "the interrupt line refused to attach");
                return false;
            };
            iface.irq_owned = true;
            log.begin("netd", .value);
            out.text("line ");
            out.decimal(gsi);
            out.text(" taken");
            log.end();
        }
    } else {
        // An adapter with no line still opens; it just never hears anything.
        // Worth a line of its own, because everything after looks like a
        // silent wire.
        log.warn("netd", "the firmware assigned no interrupt line");
    }

    if (!iface.ops.open(iface.location, iface)) {
        log.warn("netd", "the adapter did not open");
        releaseIrq(iface);
        return false;
    }

    // Walked by what the adapter said when it opened.
    log.begin(iface.name, .key);
    out.text("link ");
    sayLink(iface.state);
    out.text(", mac ");
    const spelled = lib.mac.text(iface.mac);
    out.text(&spelled);
    log.end();

    if (!iface.ops.start(iface)) {
        log.warn("netd", "the adapter did not start");
        iface.ops.stop(iface);
        releaseIrq(iface);
        return false;
    }

    keep_claim = true;
    iface.driving = true;
    return true;
}

/// Give the hardware back: stopped, its line let go, its claim released.
///
/// The interface itself stays, because what a person configured about it is
/// still true and the part may be back in a moment. What does not stay is
/// anything that describes the hardware's current state, because a part
/// about to lose its power is about to stop having one.
fn detach(iface: *dev.NicDev) void {
    if (!iface.driving) return;
    iface.driving = false;
    iface.ops.stop(iface);
    releaseIrq(iface);
    _ = sys.releaseDevice(iface.location);
}

fn releaseIrq(iface: *dev.NicDev) void {
    if (iface.irq_owned and iface.irq != 0) _ = sys.close(iface.irq);
    iface.irq = 0;
    iface.irq_gsi = null;
    iface.irq_owned = false;
}

/// Which line this adapter's interrupt arrives on.
///
/// The firmware's routing table is the answer for the interrupt model this
/// system runs; the number in configuration space answers for the mode it
/// does not. Where the platform service cannot say, the legacy number is
/// what remains, alive but possibly deaf.
fn routedLine(iface: *dev.NicDev) ?u32 {
    return irqroute.routedLine("netd", iface.location);
}

// ---------------------------------------------------------------------------
// The event loop
// ---------------------------------------------------------------------------

/// Wait on an interface's interrupt line as well.
///
/// One handle per line rather than per interface: lines are shared on this
/// machine's wiring, and a line waited on twice is one event delivered twice
/// with nothing more behind it. An interface that arrived after the loop
/// started joins the same way the ones at boot did.
fn watchLine(iface: *dev.NicDev) void {
    if (iface.irq == 0) return;
    for (sources[1..source_count]) |s| {
        if (s == iface.irq) return;
    }
    if (source_count >= sources.len) return;
    sources[source_count] = iface.irq;
    source_count += 1;
}

/// What the loop waits on: the channel, one handle per interface's line, the
/// doorbell, the config domain's watch, the wireless key and the supervisor's
/// request to go. Capped, because each of those is one or none and there are
/// at most `MAX_IFACES` lines.
///
/// Here rather than inside the loop because an interface can arrive after the
/// loop has started: a radio switched on is a line to wait on that nothing
/// was waiting on a moment ago.
var sources: [MAX_IFACES + 5]u32 = undefined;
var source_count: usize = 0;

fn serve(channel: u32) noreturn {
    source_count = 1;
    sources[0] = channel;

    const event = sys.eventCreate();
    if (event >= 0) {
        address_event = @intCast(event);
        stack.announce = addressChanged;
    }

    for (ifaces[0..count]) |*iface| watchLine(iface);

    // Streams and datagrams ride shared rings; the doorbell is the one
    // wake for every client's production.
    var bell: ?u32 = null;
    if (bridge.init(channel)) |bell_handle| {
        bell = bell_handle;
        sources[source_count] = bell_handle;
        source_count += 1;
    } else {
        log.warn("netd", "no doorbell; sockets are off");
    }

    // The `net` tool writes configuration through cfgd; this is how the
    // change arrives here without either side polling.
    var cfg_watch: ?u32 = null;
    if (settings.watch("net")) |handle| {
        cfg_watch = handle;
        sources[source_count] = handle;
        source_count += 1;
    } else |_| {
        log.warn("netd", "no settings watch; configuration is boot-time only");
    }

    // The key on the top row that has no other way to reach here: the
    // platform service turns the ACPI notification into an event the same
    // shape as everything else this loop waits on. Nothing to wait on
    // where there is no such service, or no such key.
    var hotkey_watch: ?u32 = null;
    if (platform.watchHotkeys()) |handle| {
        hotkey_watch = handle;
        sources[source_count] = handle;
        source_count += 1;
    } else |_| {
        log.warn("netd", "the platform service reports no hotkeys; the wireless key does nothing");
    }

    // The supervisor's request to go. Answered by giving the lines back and
    // leaving; the lease and the sockets are the kernel's to unwind.
    const quit_event = quit.event();
    if (quit_event != 0) {
        sources[source_count] = quit_event;
        source_count += 1;
    }

    while (true) {
        // The wait's deadline is the stack's own next timer: DHCP renewals,
        // TCP retransmits and ARP aging all ride this one number, and an
        // idle network parks here forever.
        const timeout: usize = if (soonest(stack.nextDeadline(), station.nextDeadline())) |us|
            @intCast(@min(us, std.math.maxInt(usize) - 1))
        else
            sys.FOREVER;
        const woke = sys.waitMany(sources[0..source_count], timeout);
        stack.tick();
        station.tick();
        if (woke >= 0) dispatch: {
            const index = @as(usize, @intCast(woke));
            if (index >= source_count) break :dispatch;
            const handle = sources[index];

            if (handle == channel) {
                drain(channel);
                break :dispatch;
            }
            if (quit_event != 0 and handle == quit_event) {
                for (ifaces[0..count]) |*iface| detach(iface);
                sys.exit(0);
            }
            if (bell != null and handle == bell.?) {
                bridge.drainRings();
                break :dispatch;
            }
            if (cfg_watch != null and handle == cfg_watch.?) {
                stack.applyConfig(settings.load("net"));
                break :dispatch;
            }
            if (hotkey_watch != null and handle == hotkey_watch.?) {
                drainHotkeys();
                break :dispatch;
            }
            // An interrupt line. Which interface it belongs to is the match
            // the attach made; the service runs its handler, then the ack,
            // saying whether any of them found work: a line can carry more
            // than one device, and a productive pass here may have been
            // holding the shared wire across a neighbour's assertion.
            var found = false;
            for (ifaces[0..count]) |*iface| {
                if (iface.irq == handle) {
                    iface.irq_count += 1;
                    if (iface.ops.irq(iface)) found = true;
                }
            }
            _ = sys.irqAck(handle, found);
        }

        // Whatever this pass queued for the machine itself is delivered
        // before the loop sleeps: loopback never waits for a wake.
        stack.deliverLoopback();
    }
}

/// Everything the platform service has queued. The wireless key is the
/// only one this service can do anything about; the rest are somebody
/// else's, and are left for them to read.
fn drainHotkeys() void {
    while (true) {
        var press = platform.Press{};
        platform.nextHotkey(&press) catch return;
        if (press.hotkey == .wireless) setWireless(!stack.isEnabled(.wifi));
    }
}

/// The wireless, both halves of it, in the order that keeps them agreeing.
///
/// The radio's power is the platform service's and the interface using it is
/// this service's, and the two have an order. Going off, the interface comes
/// down first: a driver left polling a part whose power has gone reads its
/// registers as all ones and has no way to tell that from an answer. Coming
/// on, the power goes first, because until it does there is nothing on the
/// bus to look for.
///
/// A machine whose radio has no switch at all is served by the same path:
/// the platform service answers that it cannot switch it, the enabling
/// carries on, and the interface is configured as it always was.
fn setWireless(on: bool) void {
    const where = wirelessPlace();

    if (!on) {
        stack.setEnabled(.wifi, false);
        for (ifaces[0..count]) |*iface| {
            if (iface.class == .wifi) detach(iface);
        }
        _ = platform.setFeature(.wireless, where, false);
        return;
    }

    const state = platform.setFeature(.wireless, where, true);
    if (state.isPresent() and !state.isOn()) {
        log.warn("netd", "the firmware would not power the radio");
        return;
    }

    takeUp(.wifi);
    stack.setEnabled(.wifi, true);
}

/// Take up hardware that has just been powered, until it is there.
///
/// Asked more than once because a part does not answer the moment its power
/// does: a card comes up, trains its link and only then reads back as
/// anything but an empty slot, and how long that takes is the card's. So the
/// answer is waited for rather than a length of time, with a bound past
/// which the part is powered and unclaimed and says so, which is a state a
/// person can see and act on.
///
/// Two ways in, because a part coming back is not always new. An interface
/// this service already knows is taken up again from the beginning: the card
/// came back with its registers as the factory left them, so what was mapped
/// and started before means nothing now. Anything the manager has newly
/// bound is adopted as at boot.
fn takeUp(class: lib.ifmatch.Class) void {
    for (0..ARRIVAL_TRIES) |attempt| {
        if (attempt > 0) sys.sleepMicros(ARRIVAL_WAIT_US);

        // Through the manager, because which driver drives what is its
        // question: it walks the bus again and binds what it finds, and this
        // service then claims what was bound to it.
        var reply = proto_devices.Rep{};
        proto_devices.call(.{ .tag = .rescan }, &reply) catch {
            log.warn("netd", "no device manager; the hardware is powered and unclaimed");
            return;
        };

        var took = false;
        for (ifaces[0..count]) |*iface| {
            if (iface.class != class or iface.driving) continue;
            if (!answering(iface.location) or !attach(iface)) continue;
            watchLine(iface);
            took = true;
        }

        const joined = adopt();
        for (ifaces[count - joined ..][0..joined]) |*iface| {
            stack.attach(iface);
            watchLine(iface);
        }

        if (took or joined > 0) return;
    }

    log.warn("netd", "the hardware is powered and nothing appeared on the bus");
}

/// Whether anything answers at that place. Asked before a claim so that a
/// slot still coming up is waited for rather than reported as a device that
/// refused: the two look the same from a claim that failed.
fn answering(location: lib.pci.Location) bool {
    return @as(u16, @truncate(pci.read(location, 0))) != lib.pci.NO_DEVICE;
}

/// How long to keep looking. A card of this era is on the bus well inside
/// this; a machine that takes longer has something else wrong with it, and
/// waiting further would only hold the network's own loop for longer.
const ARRIVAL_TRIES = 6;
const ARRIVAL_WAIT_US = 100_000;

/// Where the radio is, for the standard way of switching it, which needs the
/// device's place to find the node that speaks for it. Null on a machine
/// whose radio has never been seen, where only a vendor's own method can
/// help: that method names the part itself and needs no place.
fn wirelessPlace() ?lib.pci.Location {
    for (ifaces[0..count]) |iface| {
        if (iface.class == .wifi) return iface.location;
    }
    return stack.configuredPlace(.wifi);
}

/// The nearer of two deadlines, either of which may be none.
fn soonest(a: ?u64, b: ?u64) ?u64 {
    const first = a orelse return b;
    const second = b orelse return first;
    return @min(first, second);
}

fn drain(channel: u32) void {
    while (true) {
        var message = sys.Message{};
        const request = sys.recv(channel, &message, sys.POLL) orelse return;

        // A ping is answered when the echo is, not now: the token is kept
        // and the caller's call blocks exactly as long as the ping does.
        // Sockets and names go the same way, through the bridge.
        const bytes = message.bytes();
        if (bytes.len >= @sizeOf(proto.Req)) {
            const asked: *const proto.Req = @ptrCast(@alignCast(bytes.ptr));
            switch (asked.tag) {
                .ping => {
                    startPing(channel, request.token, asked.param, asked.param2);
                    continue;
                },
                .tcp_connect, .tcp_listen, .tcp_accept, .udp_open, .sock_close, .resolve => {
                    bridge.handle(&message, request.token);
                    continue;
                },
                .watch => {
                    handWatch(channel, request.token);
                    continue;
                },
                else => {},
            }
        }

        var reply = proto.Rep{};
        reply.status = answer(&message, &reply);
        replyWith(channel, request.token, &reply);
    }
}

/// The event a waiting service holds, signalled whenever an address arrives
/// or goes away, and whenever the radio hears a network it had not. One event
/// for the whole system: a lease landing wakes every waiter at once, and
/// nobody is left asking every few seconds.
var address_event: u32 = 0;

fn addressChanged() void {
    if (address_event != 0) _ = sys.eventSignal(address_event);
}

/// Hand back the address event, so a caller learns the network arrived
/// rather than having to ask whether it has.
fn handWatch(channel: u32, token: u32) void {
    var reply = proto.Rep{};
    if (address_event == 0) {
        reply.status = .refused;
        replyWith(channel, token, &reply);
        return;
    }

    var out_msg = sys.Message{};
    @memcpy(out_msg.data[0..@sizeOf(proto.Rep)], std.mem.asBytes(&reply));
    out_msg.len = @sizeOf(proto.Rep);
    // Sending retains rather than consumes, so the event stays ours and
    // every waiter ends up holding the same one.
    out_msg.handles[0] = address_event;
    out_msg.handle_count = 1;
    _ = sys.replyMsg(channel, token, &out_msg);
}

fn replyWith(channel: u32, token: u32, reply: *const proto.Rep) void {
    var out_msg = sys.Message{};
    @memcpy(out_msg.data[0..@sizeOf(proto.Rep)], std.mem.asBytes(reply));
    out_msg.len = @sizeOf(proto.Rep);
    _ = sys.replyMsg(channel, token, &out_msg);
}

/// The one echo in flight and who is owed its answer. The stack holds one
/// too; refusing a second asker here keeps both honest.
var ping_channel: u32 = 0;
var ping_token: u32 = 0;
var ping_pending = false;

fn startPing(channel: u32, token: u32, addr: u32, timeout_ms: u32) void {
    var reply = proto.Rep{};
    if (ping_pending or addr == 0) {
        reply.status = .refused;
        replyWith(channel, token, &reply);
        return;
    }

    const patience = if (timeout_ms == 0) 1000 else @min(timeout_ms, 10_000);
    if (!stack.ping(addr, patience, pingCame, pingLate)) {
        reply.status = .refused;
        replyWith(channel, token, &reply);
        return;
    }
    ping_pending = true;
    ping_channel = channel;
    ping_token = token;
}

fn pingCame(rtt_us: u64) void {
    if (!ping_pending) return;
    ping_pending = false;
    var reply = proto.Rep{ .body = .{ .rtt_us = @truncate(rtt_us) } };
    replyWith(ping_channel, ping_token, &reply);
}

fn pingLate() void {
    if (!ping_pending) return;
    ping_pending = false;
    var reply = proto.Rep{ .status = .timed_out };
    replyWith(ping_channel, ping_token, &reply);
}

fn answer(message: *const sys.Message, reply: *proto.Rep) proto.Status {
    const bytes = message.bytes();
    if (bytes.len < @sizeOf(proto.Req)) return .refused;

    const request: *const proto.Req = @ptrCast(@alignCast(bytes.ptr));

    if (request.tag == .count) {
        reply.body = .{ .count = @intCast(count) };
        return .ok;
    }

    // The machine's randomness is kept here, because what feeds it is here:
    // a radio hears what nobody arranged. A program asks rather than making
    // its own out of a clock every other program can read.
    if (request.tag == .random) {
        const wanted = @min(request.param, proto.RANDOM_MAX);
        if (wanted == 0) return .refused;
        var drawn: [proto.RANDOM_MAX]u8 = @splat(0);
        station.draw(drawn[0..wanted]);
        reply.body = .{ .random = drawn };
        return .ok;
    }

    // The scan's list is the station's, indexed on its own.
    if (request.tag == .wifi_scan) {
        const bss = station.network(request.index) orelse return .end;
        reply.body = .{ .network = proto.Network.of(bss) };
        return .ok;
    }

    if (request.index >= count) return .end;

    const iface = &ifaces[request.index];

    // The address story is the stack's, not the adapter's: answered without
    // waking the hardware for a link refresh nothing here uses.
    if (request.tag == .address) {
        const address = stack.addressOf(iface);
        reply.body = .{ .address = .{
            .addr = address.addr,
            .gateway = address.gateway,
            .lease_remaining_s = address.lease_remaining_s,
            .prefix = address.prefix,
            .source = address.source,
        } };
        return .ok;
    }

    // Fresh link state before anything uses it: what the adapter reports
    // and what its registers were told must agree.
    if (iface.ops.sync_link) |sync| {
        sync(iface);
    } else {
        iface.state = iface.ops.link(iface);
    }

    if (request.tag == .arp_probe) {
        // The whole of outbound traffic until the stack lands: one ARP
        // request, hand-built by the pure frame library, asking who holds
        // the target and told where to answer. The reply, when it comes,
        // proves the ring and the line from outside.
        if (!iface.state.up) return .refused;

        var frame: [lib.eth.FRAME]u8 = undefined;
        lib.eth.arpRequest(&frame, iface.mac, PROBE_SOURCE, request.param);
        return if (dev.send(iface, &frame)) .ok else .refused;
    }

    reply.body = .{
        .iface = .{
            .up = @intFromBool(iface.state.up),
            .duplex = iface.state.duplex,
            .mbps = iface.state.mbps,
            .mac = iface.mac,
            .rx_pkts = @truncate(iface.stats.rx_pkts),
            .rx_bytes = @truncate(iface.stats.rx_bytes),
            .tx_pkts = @truncate(iface.stats.tx_pkts),
            .tx_bytes = @truncate(iface.stats.tx_bytes),
            .arp_replies = @truncate(iface.stats.rx_arp),
            .kind = if (iface.class == .wifi) .radio else .wire,
            .channel = iface.radio_channel,
            // Only a radio joins anything, so a wire reports nothing about it.
            .joining = if (iface.class == .wifi) station.joining() else .idle,
            .stopped = if (iface.class == .wifi) station.stopped() else .none,
        },
    };
    const label = iface.label.slice();
    @memcpy(reply.body.iface.driver[0..label.len], label);
    reply.body.iface.location = @bitCast(iface.location);
    if (iface.peer) |peer| {
        reply.body.iface.peer_ip = peer.addr;
        reply.body.iface.peer_mac = peer.mac;
    }

    return .ok;
}

/// The probe's sender protocol address: none. An address probe carries a
/// zero sender per RFC 5227, which any host answers without an opinion on
/// subnets; a real source address waits for configuration to exist.
const PROBE_SOURCE: u32 = 0; // 0.0.0.0

// ---------------------------------------------------------------------------
// Small spelling helpers
// ---------------------------------------------------------------------------

fn sayLink(state: dev.Link) void {
    if (!state.up) {
        out.text("down");
        return;
    }
    out.decimal(state.mbps);
    out.text(" Mbit ");
    out.text(switch (state.duplex) {
        .half => "half",
        .full => "full",
        else => "unknown",
    });
    out.text(" duplex");
}

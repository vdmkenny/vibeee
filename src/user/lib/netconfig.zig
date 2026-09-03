//! The network configuration as every surface edits it.
//!
//! The `net` settings domain is four slots, each a matcher and what the
//! interface it matches should do. Which slot speaks for which interface is
//! decided by the same binding the service uses, so what a pane shows beside
//! an interface is what the service applied to it. The handful of changes a
//! person makes, enabling, asking DHCP, claiming an address, joining a
//! network, forgetting one, are here once, so the command, the Settings pane
//! and the bar's menu give a verb one meaning, and a slot edited by any of
//! them is the slot the others read.

const lib = @import("lib");
const proto = @import("proto");

const ifmatch = lib.ifmatch;
const ipv4 = lib.ipv4;
const net = proto.net;
const settings = proto.settings;
const wifi = lib.wifi;

/// How many interfaces a surface shows. The service holds this many.
pub const MAX_IFACES = 4;

/// The slots, and the interfaces they are bound to.
pub const Model = struct {
    cfg: settings.Net = .{},
    slots: [settings.NET_SLOTS]settings.NetSlot = undefined,
    ifaces: [MAX_IFACES]net.Iface = undefined,
    addresses: [MAX_IFACES]net.AddressInfo = undefined,
    count: usize = 0,
    /// Which slot speaks for each interface, or null when none does.
    bound: [MAX_IFACES]?u8 = @splat(null),
    /// Whether the service answered. Without it the configuration is still
    /// editable; it is applied when the service is back.
    serving: bool = false,

    /// The configuration as stored, and the interfaces as served.
    pub fn load() Model {
        var model = Model{ .cfg = settings.load("net") };
        inline for (0..settings.NET_SLOTS) |i| model.slots[i] = settings.netSlot(model.cfg, i);
        model.refresh();
        return model;
    }

    /// Ask the service again for the interfaces and bind the slots to them.
    /// The configuration is left as it is.
    pub fn refresh(self: *Model) void {
        self.count = @min(net.interfaceCount(), MAX_IFACES);
        self.serving = self.count > 0 or net.interfaceCount() > 0;
        for (0..self.count) |i| {
            self.ifaces[i] = net.interfaceAt(i) orelse .{};
            self.addresses[i] = net.addressOf(i) orelse .{};
        }
        self.bind();
    }

    fn bind(self: *Model) void {
        var matches: [settings.NET_SLOTS]ifmatch.Match = undefined;
        for (&matches, self.slots) |*m, slot| m.* = slot.match;

        var described: [MAX_IFACES]ifmatch.Iface = undefined;
        for (0..self.count) |i| described[i] = describe(&self.ifaces[i]);

        ifmatch.bind(&matches, described[0..self.count], self.bound[0..self.count]);
    }

    /// The slot bound to an interface, if one is.
    pub fn slotOf(self: *Model, iface: usize) ?*settings.NetSlot {
        if (iface >= self.count) return null;
        const which = self.bound[iface] orelse return null;
        return &self.slots[which];
    }

    /// The slot an interface will be configured in: the one bound to it, or
    /// a free slot claimed with the interface's own name. Null when every
    /// slot is taken, which the caller says in its own words.
    pub fn claim(self: *Model, iface: usize) ?*settings.NetSlot {
        if (self.slotOf(iface)) |slot| return slot;
        if (iface >= self.count) return null;
        for (&self.slots, 0..) |*slot, i| {
            if (slot.match != .none) continue;
            slot.* = .{ .match = .{ .driver = ifmatch.Name.of(net.nameOf(&self.ifaces[iface])) orelse return null } };
            self.bound[iface] = @intCast(i);
            return slot;
        }
        return null;
    }

    /// Enable or disable an interface, persistently.
    pub fn setEnabled(self: *Model, iface: usize, enabled: bool) bool {
        const slot = self.claim(iface) orelse return false;
        slot.enabled = enabled;
        return true;
    }

    /// Clear any static claim: DHCP asks.
    pub fn setDhcp(self: *Model, iface: usize) bool {
        const slot = self.claim(iface) orelse return false;
        slot.askDhcp();
        return true;
    }

    /// Claim an address; the gateway and the servers may be unset.
    pub fn setStatic(self: *Model, iface: usize, address: ipv4.Cidr, gateway: ipv4.Maybe, dns: ipv4.Pair) bool {
        const slot = self.claim(iface) orelse return false;
        slot.claimStatic(address, gateway, dns);
        return true;
    }

    /// Join a network with a secret, or with none for an open one.
    pub fn join(self: *Model, iface: usize, ssid: wifi.Ssid, psk: wifi.Psk) bool {
        const slot = self.claim(iface) orelse return false;
        slot.join(ssid, psk);
        return true;
    }

    /// Forget the network a radio was told to join.
    pub fn forget(self: *Model, iface: usize) bool {
        const slot = self.slotOf(iface) orelse return true;
        slot.forget();
        return true;
    }

    /// Hand every slot to the store. The service watches the domain and
    /// applies the change.
    pub fn save(self: *Model) settings.Error!void {
        inline for (0..settings.NET_SLOTS) |i| settings.setNetSlot(&self.cfg, i, self.slots[i]);
        try settings.save("net", self.cfg);
    }

    /// Whether an interface is a radio.
    pub fn isRadio(self: *const Model, iface: usize) bool {
        return iface < self.count and self.ifaces[iface].kind == .radio;
    }

    /// The first radio, if there is one.
    pub fn radio(self: *const Model) ?usize {
        for (0..self.count) |i| {
            if (self.ifaces[i].kind == .radio) return i;
        }
        return null;
    }
};

/// An interface as the binding sees it.
fn describe(iface: *const net.Iface) ifmatch.Iface {
    return .{
        .class = switch (iface.kind) {
            .wire => .ether,
            .radio => .wifi,
        },
        .label = ifmatch.Name.of(net.nameOf(iface)) orelse .{},
        .location = @bitCast(iface.location),
    };
}

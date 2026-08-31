//! What a USB device says about itself.
//!
//! Pure and host-tested: setup packets, descriptors, and the walk over a
//! configuration's packed descriptor list. Nothing here touches a
//! controller, which is what lets the awkward part of USB, the parsing of
//! bytes a stranger's firmware wrote, be tested on the build machine
//! rather than discovered on the bus.
//!
//! Descriptors arrive in DMA memory at whatever offset the device chose,
//! so everything is read from byte slices rather than cast over them: a
//! sixteen-bit field at an odd offset is ordinary here.

const std = @import("std");
const str = @import("str.zig");

/// How fast a port negotiated. The controller decides this, not the
/// device, and it decides what a packet may be.
pub const Speed = enum(u8) {
    low,
    full,
    high,

    pub fn spell(self: Speed) []const u8 {
        return switch (self) {
            .low => "low",
            .full => "full",
            .high => "high",
        };
    }
};

/// Which way a transfer goes, from the host's point of view.
pub const Direction = enum(u1) {
    /// Host to device.
    out = 0,
    /// Device to host.
    in = 1,
};

pub const RequestKind = enum(u2) {
    standard = 0,
    class = 1,
    vendor = 2,
    _,
};

pub const Recipient = enum(u5) {
    device = 0,
    interface = 1,
    endpoint = 2,
    other = 3,
    _,
};

/// The first byte of a setup packet, as its fields.
pub const RequestType = packed struct(u8) {
    recipient: Recipient = .device,
    kind: RequestKind = .standard,
    direction: Direction = .out,
};

/// The requests every device must answer.
pub const Request = enum(u8) {
    get_status = 0,
    clear_feature = 1,
    set_feature = 3,
    set_address = 5,
    get_descriptor = 6,
    set_descriptor = 7,
    get_configuration = 8,
    set_configuration = 9,
    get_interface = 10,
    set_interface = 11,
    _,
};

pub const DescriptorType = enum(u8) {
    device = 1,
    configuration = 2,
    string = 3,
    interface = 4,
    endpoint = 5,
    device_qualifier = 6,
    other_speed = 7,
    interface_power = 8,
    _,
};

/// The eight bytes that begin every control transfer.
pub const Setup = extern struct {
    request_type: RequestType = .{},
    request: Request = .get_status,
    value: u16 align(1) = 0,
    index: u16 align(1) = 0,
    length: u16 align(1) = 0,

    pub const BYTES = 8;

    /// Ask a device for one of its descriptors. The type and the index
    /// share a word, the type above the index, which is the one piece of
    /// this encoding nobody remembers.
    pub fn getDescriptor(kind: DescriptorType, index: u8, length: u16) Setup {
        return .{
            .request_type = .{ .direction = .in, .recipient = .device },
            .request = .get_descriptor,
            .value = (@as(u16, @intFromEnum(kind)) << 8) | index,
            .length = length,
        };
    }

    /// Whether this request carries a data stage at all. A request that
    /// asks for nothing is setup and status and no more.
    pub fn carriesData(self: Setup) bool {
        return self.length != 0;
    }

    /// Which way the status stage runs, which is the opposite of the data
    /// stage and *in* whenever there is no data stage: a device executes a
    /// control write when the host asks for its status, so getting this
    /// backwards makes the request complete without ever happening.
    pub fn statusDirection(self: Setup) Direction {
        if (!self.carriesData()) return .in;
        return switch (self.request_type.direction) {
            .in => .out,
            .out => .in,
        };
    }

    pub fn setAddress(address: u7) Setup {
        return .{
            .request_type = .{ .direction = .out, .recipient = .device },
            .request = .set_address,
            .value = address,
        };
    }

    pub fn setConfiguration(value: u8) Setup {
        return .{
            .request_type = .{ .direction = .out, .recipient = .device },
            .request = .set_configuration,
            .value = value,
        };
    }

    /// One of a device's strings, in a language it offers. Index zero is
    /// the list of languages themselves, asked for with no language.
    pub fn stringDescriptor(index: u8, language: u16, length: u16) Setup {
        return .{
            .request_type = .{ .direction = .in, .recipient = .device },
            .request = .get_descriptor,
            .value = (@as(u16, @intFromEnum(DescriptorType.string)) << 8) | index,
            .index = language,
            .length = length,
        };
    }

    /// Take an endpoint out of the halt a failed transfer left it in.
    /// Until this is done the endpoint answers nothing but a stall, and
    /// the device's own toggle goes back to zero with it.
    pub fn clearHalt(endpoint_address: u8) Setup {
        return .{
            .request_type = .{ .direction = .out, .recipient = .endpoint },
            .request = .clear_feature,
            .value = FEATURE_ENDPOINT_HALT,
            .index = endpoint_address,
        };
    }

    /// A request a class defines rather than the specification, aimed at
    /// one interface. Every class control request has this shape.
    pub fn classRequest(
        direction: Direction,
        request: u8,
        value: u16,
        interface: u8,
        length: u16,
    ) Setup {
        return .{
            .request_type = .{ .direction = direction, .kind = .class, .recipient = .interface },
            .request = @enumFromInt(request),
            .value = value,
            .index = interface,
            .length = length,
        };
    }
};

/// The one standard endpoint feature, and the only one anything here sets
/// or clears.
pub const FEATURE_ENDPOINT_HALT: u16 = 0;

comptime {
    if (@sizeOf(Setup) != Setup.BYTES) @compileError("a setup packet is eight bytes");
    if (@as(u8, @bitCast(RequestType{ .direction = .in })) != 0x80) {
        @compileError("the request type's direction bit drifted");
    }
}

/// What a device is for, as the assigned class numbers say. Only the
/// classes this system acts on are named; the rest travel as numbers.
pub const Class = enum(u8) {
    /// The device says nothing; its interfaces do.
    per_interface = 0x00,
    audio = 0x01,
    communications = 0x02,
    /// Keyboards, mice, and everything shaped like them.
    human_interface = 0x03,
    physical = 0x05,
    image = 0x06,
    printer = 0x07,
    /// Disks, card readers, anything holding blocks.
    mass_storage = 0x08,
    hub = 0x09,
    /// Cameras, among other things.
    video = 0x0E,
    wireless = 0xE0,
    vendor_specific = 0xFF,
    _,

    pub fn spell(self: Class) []const u8 {
        return switch (self) {
            .per_interface => "per interface",
            .audio => "audio",
            .communications => "communications",
            .human_interface => "input",
            .physical => "physical",
            .image => "image",
            .printer => "printer",
            .mass_storage => "storage",
            .hub => "hub",
            .video => "video",
            .wireless => "wireless",
            .vendor_specific => "vendor specific",
            _ => "unknown",
        };
    }
};

/// The device descriptor, eighteen bytes, the first thing anything asks.
pub const Device = struct {
    usb_version: u16 = 0,
    class: Class = .per_interface,
    subclass: u8 = 0,
    protocol: u8 = 0,
    /// The largest packet endpoint zero accepts. Needed before anything
    /// else can be read, which is why the first read asks for only the
    /// eight bytes that carry it.
    max_packet_zero: u8 = 0,
    vendor: u16 = 0,
    product: u16 = 0,
    device_version: u16 = 0,
    manufacturer_name: u8 = 0,
    product_name: u8 = 0,
    serial_name: u8 = 0,
    configurations: u8 = 0,

    pub const BYTES = 18;

    pub fn parse(bytes: []const u8) ?Device {
        if (bytes.len < BYTES) return null;
        if (bytes[1] != @intFromEnum(DescriptorType.device)) return null;
        return .{
            .usb_version = std.mem.readInt(u16, bytes[2..4], .little),
            .class = @enumFromInt(bytes[4]),
            .subclass = bytes[5],
            .protocol = bytes[6],
            .max_packet_zero = bytes[7],
            .vendor = std.mem.readInt(u16, bytes[8..10], .little),
            .product = std.mem.readInt(u16, bytes[10..12], .little),
            .device_version = std.mem.readInt(u16, bytes[12..14], .little),
            .manufacturer_name = bytes[14],
            .product_name = bytes[15],
            .serial_name = bytes[16],
            .configurations = bytes[17],
        };
    }

    /// Endpoint zero's packet size from a short first read: the eight
    /// bytes every device answers whatever its real descriptor length.
    pub fn packetZeroOf(bytes: []const u8) ?u8 {
        if (bytes.len < 8) return null;
        if (bytes[1] != @intFromEnum(DescriptorType.device)) return null;
        return switch (bytes[7]) {
            // A packet size is a power of two, and eight is the smallest
            // a device may declare. Anything else is a device answering
            // nonsense, and guessing would send packets it cannot take.
            8, 16, 32, 64 => bytes[7],
            else => null,
        };
    }
};

pub const Configuration = struct {
    total_length: u16 = 0,
    interfaces: u8 = 0,
    value: u8 = 0,
    name: u8 = 0,
    attributes: u8 = 0,
    /// In two-milliamp units, as the wire counts them.
    max_power: u8 = 0,

    pub const BYTES = 9;

    pub fn parse(bytes: []const u8) ?Configuration {
        if (bytes.len < BYTES) return null;
        if (bytes[1] != @intFromEnum(DescriptorType.configuration)) return null;
        return .{
            .total_length = std.mem.readInt(u16, bytes[2..4], .little),
            .interfaces = bytes[4],
            .value = bytes[5],
            .name = bytes[6],
            .attributes = bytes[7],
            .max_power = bytes[8],
        };
    }

    pub fn milliamps(self: Configuration) u16 {
        return @as(u16, self.max_power) * 2;
    }
};

pub const Interface = struct {
    number: u8 = 0,
    alternate: u8 = 0,
    endpoints: u8 = 0,
    class: Class = .per_interface,
    subclass: u8 = 0,
    protocol: u8 = 0,
    name: u8 = 0,

    pub const BYTES = 9;

    pub fn parse(bytes: []const u8) ?Interface {
        if (bytes.len < BYTES) return null;
        if (bytes[1] != @intFromEnum(DescriptorType.interface)) return null;
        return .{
            .number = bytes[2],
            .alternate = bytes[3],
            .endpoints = bytes[4],
            .class = @enumFromInt(bytes[5]),
            .subclass = bytes[6],
            .protocol = bytes[7],
            .name = bytes[8],
        };
    }
};

/// How an endpoint carries what it carries.
pub const TransferKind = enum(u2) {
    control = 0,
    isochronous = 1,
    bulk = 2,
    interrupt = 3,

    pub fn spell(self: TransferKind) []const u8 {
        return @tagName(self);
    }
};

pub const Endpoint = struct {
    /// The endpoint's number, without the direction bit.
    number: u4 = 0,
    direction: Direction = .out,
    kind: TransferKind = .control,
    max_packet: u16 = 0,
    /// Frames between polls, for the kinds that are polled.
    interval: u8 = 0,

    pub const BYTES = 7;

    pub fn parse(bytes: []const u8) ?Endpoint {
        if (bytes.len < BYTES) return null;
        if (bytes[1] != @intFromEnum(DescriptorType.endpoint)) return null;
        return .{
            .number = @truncate(bytes[2]),
            .direction = if (bytes[2] & 0x80 != 0) .in else .out,
            .kind = @enumFromInt(@as(u2, @truncate(bytes[3]))),
            // The top bits carry the transactions per microframe on a
            // high-speed device; the size is the low eleven.
            .max_packet = std.mem.readInt(u16, bytes[4..6], .little) & 0x7FF,
            .interval = bytes[6],
        };
    }

    /// The address as the wire writes it: number, with the direction in
    /// the top bit.
    pub fn address(self: Endpoint) u8 {
        return @as(u8, self.number) | (@as(u8, @intFromEnum(self.direction)) << 7);
    }

    /// The pipe this endpoint becomes once a device owns it, which is
    /// the only form a driver transfers through.
    pub fn open(self: Endpoint, address_of_device: u7, speed: Speed, route: Route) Pipe {
        return .{
            .address = address_of_device,
            .number = self.number,
            .direction = self.direction,
            .speed = speed,
            .max_packet = self.max_packet,
            .route = route,
        };
    }
};

/// A walk over the descriptors a configuration read returns.
///
/// They arrive as one run of variable-length records, each carrying its
/// own length, and a device is free to include kinds nobody asked about.
/// So the walk is by length and the caller matches on type, which is what
/// keeps an unfamiliar descriptor from derailing the parse.
pub const Walk = struct {
    bytes: []const u8,
    at: usize = 0,

    pub const Record = struct {
        kind: DescriptorType,
        bytes: []const u8,
    };

    pub fn next(self: *Walk) ?Record {
        // Two bytes at least: a length and a type. A record claiming to
        // be shorter than its own header, or longer than what is left,
        // ends the walk rather than being trusted.
        if (self.at + 2 > self.bytes.len) return null;
        const length = self.bytes[self.at];
        if (length < 2 or self.at + length > self.bytes.len) return null;

        const record = Record{
            .kind = @enumFromInt(self.bytes[self.at + 1]),
            .bytes = self.bytes[self.at..][0..length],
        };
        self.at += length;
        return record;
    }
};

pub fn walk(bytes: []const u8) Walk {
    return .{ .bytes = bytes };
}

/// What a driver is matched against: a device says what it is, or says
/// nothing and leaves its interfaces to say it.
/// Where on the bus a device sits: which hub carries it, and on which of
/// that hub's ports.
///
/// Zero means a root port, which is a device the controller reaches
/// directly. Anything else is a device the controller reaches *through*
/// something, and a fast controller talking to a slow device that way has
/// to split every transaction in two and address the halves at the hub.
/// So this travels with every transfer rather than being looked up.
pub const Route = struct {
    hub: u7 = 0,
    port: u7 = 0,

    /// Whether reaching this device means splitting transactions: a full
    /// or low speed device behind a hub on a high speed bus. A high speed
    /// device needs no such thing wherever it sits, and neither does
    /// anything on a controller that is slow itself.
    pub fn splits(self: Route, device_speed: Speed, bus_speed: Speed) bool {
        return self.hub != 0 and bus_speed == .high and device_speed != .high;
    }
};

/// One open endpoint on one device, and the toggle it is up to.
///
/// The descriptor `Endpoint` says what an endpoint is; this says who it
/// belongs to and where its conversation has got to, which is what a
/// driver actually holds.
///
/// The data toggle belongs to the endpoint rather than to any one
/// transfer: a device that receives DATA0 when it expected DATA1 drops
/// the packet and the transfer stalls, so whoever holds the pipe holds
/// the toggle and tells the controller what it currently is. A control
/// endpoint is the exception and resets to zero every setup, which is
/// why only the pipes opened this way carry one.
pub const Pipe = struct {
    address: u7 = 0,
    number: u4 = 0,
    direction: Direction = .in,
    speed: Speed = .high,
    max_packet: u16 = 512,
    toggle: bool = false,
    /// The hub this device hangs off, if any.
    route: Route = .{},

    /// How many packets a transfer of this many bytes takes. A transfer
    /// of nothing is still one packet: a zero-length packet is how a
    /// device says a short answer is finished.
    pub fn packetsFor(self: Pipe, bytes: usize) usize {
        if (bytes == 0) return 1;
        const size = @max(self.max_packet, 1);
        return (bytes + size - 1) / size;
    }

    /// The toggle after moving this many bytes: it flips once per packet,
    /// so an odd number of packets leaves it the other way round.
    pub fn advance(self: *Pipe, moved: usize) void {
        if (self.packetsFor(moved) % 2 == 1) self.toggle = !self.toggle;
    }

    /// What a reset or a `clear feature halt` leaves behind.
    pub fn resetToggle(self: *Pipe) void {
        self.toggle = false;
    }
};

pub const Signature = struct {
    class: Class = .per_interface,
    subclass: u8 = 0,
    protocol: u8 = 0,
    vendor: u16 = 0,
    product: u16 = 0,

    /// The signature as the two numbers a device-manager request carries.
    /// Packed and unpacked in one place so the bus and the manager cannot
    /// disagree about which byte is which.
    pub fn pack(self: Signature) Packed {
        return .{
            .kind = @as(u32, @intFromEnum(self.class)) << 16 |
                @as(u32, self.subclass) << 8 | self.protocol,
            .part = @as(u32, self.vendor) << 16 | self.product,
        };
    }

    pub fn unpack(numbers: Packed) Signature {
        return .{
            .class = @enumFromInt(@as(u8, @truncate(numbers.kind >> 16))),
            .subclass = @truncate(numbers.kind >> 8),
            .protocol = @truncate(numbers.kind),
            .vendor = @truncate(numbers.part >> 16),
            .product = @truncate(numbers.part),
        };
    }

    pub const Packed = struct { kind: u32, part: u32 };

    /// Whether a manifest's `match` line names this exact device:
    /// `usb:vendor:product`, in hex. The line may list several, separated
    /// by commas: one driver and one program can serve several devices,
    /// and saying so once beats a manifest each.
    pub fn matchesPart(self: Signature, match: []const u8) bool {
        return anySpec(self, match, part);
    }

    /// Whether it names this device's class: `usb-class:class:subclass`,
    /// with an optional protocol, and again a comma-separated list.
    pub fn matchesClass(self: Signature, match: []const u8) bool {
        return anySpec(self, match, class_);
    }

    fn anySpec(
        self: Signature,
        match: []const u8,
        comptime one: fn (Signature, []const u8) bool,
    ) bool {
        var specs = str.split(match, ',');
        while (specs.next()) |spec| {
            const trimmed = str.trim(spec);
            if (trimmed.len != 0 and one(self, trimmed)) return true;
        }
        return false;
    }

    fn part(self: Signature, spec: []const u8) bool {
        var it = str.split(spec, ':');
        if (!str.eql(str.trim(it.next() orelse return false), "usb")) return false;
        const vendor = str.fromHex(str.trim(it.next() orelse return false));
        const product = str.fromHex(str.trim(it.next() orelse return false));
        return vendor == self.vendor and product == self.product;
    }

    /// A manifest that names no protocol fits every protocol of that
    /// subclass, which is how one driver serves a whole family without
    /// listing its members.
    fn class_(self: Signature, spec: []const u8) bool {
        var it = str.split(spec, ':');
        if (!str.eql(str.trim(it.next() orelse return false), "usb-class")) return false;
        if (str.fromHex(str.trim(it.next() orelse return false)) != @intFromEnum(self.class)) return false;
        if (str.fromHex(str.trim(it.next() orelse return false)) != self.subclass) return false;
        const rest = str.trim(it.next() orelse return true);
        if (rest.len == 0) return true;
        return str.fromHex(rest) == self.protocol;
    }
};

/// One interface and the endpoints that belong to it, picked out of a
/// configuration. A class driver needs its own interface's number and its
/// pipes and nothing else, and finding them is the same walk every time.
pub const InterfaceView = struct {
    interface: Interface = .{},
    /// The endpoints listed under it, in the order the device wrote them.
    endpoints: [ENDPOINTS_MAX]Endpoint = @splat(.{}),
    endpoint_count: u8 = 0,

    pub const ENDPOINTS_MAX = 8;

    pub fn endpointSlice(self: *const InterfaceView) []const Endpoint {
        return self.endpoints[0..@min(self.endpoint_count, self.endpoints.len)];
    }

    /// The first endpoint of a kind going a given way, which is how a
    /// class driver names the pipes it needs: "the bulk one that reads".
    pub fn find(self: *const InterfaceView, kind: TransferKind, direction: Direction) ?Endpoint {
        for (self.endpointSlice()) |endpoint| {
            if (endpoint.kind == kind and endpoint.direction == direction) return endpoint;
        }
        return null;
    }
};

/// The interface in a configuration that matches a class, and its
/// endpoints. Alternate settings other than the first are skipped: a
/// device offering a faster alternate is asking to be configured, which
/// is more than a driver needs to start.
pub fn interfaceFor(
    configuration: []const u8,
    class: Class,
    subclass: u8,
    protocol: u8,
) ?InterfaceView {
    var records = walk(configuration);
    var found: ?InterfaceView = null;

    while (records.next()) |record| {
        switch (record.kind) {
            .interface => {
                if (found != null) return found;
                const interface = Interface.parse(record.bytes) orelse continue;
                if (interface.alternate != 0) continue;
                if (interface.class != class) continue;
                if (interface.subclass != subclass) continue;
                if (interface.protocol != protocol) continue;
                found = .{ .interface = interface };
            },
            .endpoint => {
                var view = &(found orelse continue);
                const endpoint = Endpoint.parse(record.bytes) orelse continue;
                if (view.endpoint_count >= InterfaceView.ENDPOINTS_MAX) continue;
                view.endpoints[view.endpoint_count] = endpoint;
                view.endpoint_count += 1;
            },
            else => {},
        }
    }
    return found;
}

// ---------------------------------------------------------------------------
// What a device calls itself
// ---------------------------------------------------------------------------

/// The first language a device offers, out of the list at string index
/// zero. Devices in practice offer one, and which one is not a choice
/// worth making: the point is to ask for a language the device has.
pub fn firstLanguage(bytes: []const u8) ?u16 {
    if (bytes.len < 4) return null;
    if (bytes[1] != @intFromEnum(DescriptorType.string)) return null;
    return std.mem.readInt(u16, bytes[2..4], .little);
}

/// A string descriptor's text, written out as UTF-8.
///
/// Devices store their strings as UTF-16, so this is a conversion and not
/// a copy. Characters outside the basic plane arrive as a surrogate pair
/// and are dropped rather than half-encoded: no device names itself with
/// one, and half a character is worse than none.
pub fn decodeString(bytes: []const u8, into: []u8) []const u8 {
    if (bytes.len < 2 or bytes[1] != @intFromEnum(DescriptorType.string)) return "";

    // The descriptor's own length bounds the text, and so does what
    // actually arrived: a device that overstates itself is not followed.
    const claimed = @min(@as(usize, bytes[0]), bytes.len);
    if (claimed < 4) return "";

    var written: usize = 0;
    var at: usize = 2;
    while (at + 1 < claimed) : (at += 2) {
        const unit = std.mem.readInt(u16, bytes[at..][0..2], .little);
        if (unit >= 0xD800 and unit <= 0xDFFF) continue;

        var encoded: [4]u8 = undefined;
        const width = std.unicode.utf8Encode(unit, &encoded) catch continue;
        if (written + width > into.len) break;
        @memcpy(into[written..][0..width], encoded[0..width]);
        written += width;
    }
    return into[0..written];
}

// ---------------------------------------------------------------------------
// Hubs
// ---------------------------------------------------------------------------

/// A hub's own descriptor, which is a class descriptor rather than one of
/// the standard kinds and so has a type number of its own.
pub const Hub = struct {
    ports: u8 = 0,
    /// Milliseconds between powering a port and a device on it being
    /// usable. The specification stores half of it, so this is doubled.
    power_on_ms: u16 = 0,
    /// Whether the hub switches power per port or all together. A hub
    /// that switches nothing reports ganged and ignores the request.
    per_port_power: bool = false,

    pub const DESCRIPTOR: u8 = 0x29;
    pub const BYTES = 7;

    pub fn parse(bytes: []const u8) ?Hub {
        if (bytes.len < BYTES) return null;
        if (bytes[1] != DESCRIPTOR) return null;
        const characteristics = std.mem.readInt(u16, bytes[3..5], .little);
        return .{
            .ports = bytes[2],
            // Two milliseconds per unit, and never less than the hundred
            // the specification calls the settling time: a hub reporting
            // nothing is a hub whose ports still need a moment.
            .power_on_ms = @max(@as(u16, bytes[5]) * 2, 100),
            .per_port_power = characteristics & 0x03 == 0x01,
        };
    }
};

/// What a hub says about one of its ports. The low half is how things
/// are; the high half is what has changed since anybody last asked, and
/// stays set until it is cleared.
pub const PortStatus = packed struct(u32) {
    connected: bool = false,
    enabled: bool = false,
    suspended: bool = false,
    over_current: bool = false,
    resetting: bool = false,
    _5: u3 = 0,
    powered: bool = false,
    low_speed: bool = false,
    high_speed: bool = false,
    test_mode: bool = false,
    indicator: bool = false,
    _13: u3 = 0,

    connection_changed: bool = false,
    enable_changed: bool = false,
    suspend_changed: bool = false,
    over_current_changed: bool = false,
    reset_changed: bool = false,
    _21: u11 = 0,

    pub const BYTES = 4;

    pub fn parse(bytes: []const u8) ?PortStatus {
        if (bytes.len < BYTES) return null;
        return @bitCast(std.mem.readInt(u32, bytes[0..4], .little));
    }

    /// How fast whatever is on the port speaks. Two bits say it, and
    /// neither set means full speed, which is the one nobody flags.
    pub fn speed(self: PortStatus) Speed {
        if (self.low_speed) return .low;
        if (self.high_speed) return .high;
        return .full;
    }

    pub fn changed(self: PortStatus) bool {
        return self.connection_changed or self.enable_changed or
            self.suspend_changed or self.over_current_changed or self.reset_changed;
    }
};

/// What a hub feature request names. The ones below sixteen are states;
/// the ones above are the change bits, which are cleared rather than set.
pub const PortFeature = enum(u16) {
    connection = 0,
    enable = 1,
    suspended = 2,
    over_current = 3,
    reset = 4,
    power = 8,
    low_speed = 9,
    connection_changed = 16,
    enable_changed = 17,
    suspend_changed = 18,
    over_current_changed = 19,
    reset_changed = 20,
    _,
};

/// The requests a hub answers about its ports. Class requests, so they
/// share the standard numbering but mean what the hub class says.
pub const hub_requests = struct {
    /// A hub's own descriptor, asked for the way a class descriptor is.
    pub fn descriptor(length: u16) Setup {
        return .{
            .request_type = .{ .direction = .in, .kind = .class, .recipient = .device },
            .request = .get_descriptor,
            .value = @as(u16, Hub.DESCRIPTOR) << 8,
            .length = length,
        };
    }

    pub fn portStatus(port: u8) Setup {
        return .{
            .request_type = .{ .direction = .in, .kind = .class, .recipient = .other },
            .request = .get_status,
            .index = port,
            .length = PortStatus.BYTES,
        };
    }

    pub fn setPort(port: u8, feature: PortFeature) Setup {
        return .{
            .request_type = .{ .direction = .out, .kind = .class, .recipient = .other },
            .request = .set_feature,
            .value = @intFromEnum(feature),
            .index = port,
        };
    }

    pub fn clearPort(port: u8, feature: PortFeature) Setup {
        return .{
            .request_type = .{ .direction = .out, .kind = .class, .recipient = .other },
            .request = .clear_feature,
            .value = @intFromEnum(feature),
            .index = port,
        };
    }
};

/// The signature to look a driver up by. A device that declares its own
/// class is taken at its word; one that declares none is described by its
/// first interface, which is where a storage device or a keyboard says
/// what it is.
pub fn signatureOf(descriptor: Device, configuration: []const u8) Signature {
    var found = Signature{
        .class = descriptor.class,
        .subclass = descriptor.subclass,
        .protocol = descriptor.protocol,
        .vendor = descriptor.vendor,
        .product = descriptor.product,
    };
    if (descriptor.class != .per_interface) return found;

    var it = walk(configuration);
    while (it.next()) |record| {
        if (record.kind != .interface) continue;
        const interface = Interface.parse(record.bytes) orelse continue;
        found.class = interface.class;
        found.subclass = interface.subclass;
        found.protocol = interface.protocol;
        return found;
    }
    return found;
}

/// Which addresses on a bus are spoken for.
///
/// A device is born at address zero and is given one of its own before
/// anything else can be asked of it, because address zero is where every
/// unaddressed device answers and two of them at once cannot be told
/// apart. One is the lowest a device may be given and a hundred and
/// twenty seven the highest the field holds.
pub const Addresses = struct {
    taken: [COUNT]bool = @splat(false),

    /// The highest address the field holds, and how many slots that is.
    pub const MAX: u7 = 127;
    const COUNT: usize = @as(usize, MAX) + 1;

    pub fn take(self: *Addresses) ?u7 {
        var candidate: u7 = 1;
        while (candidate < MAX) : (candidate += 1) {
            if (self.taken[candidate]) continue;
            self.taken[candidate] = true;
            return candidate;
        }
        return null;
    }

    pub fn release(self: *Addresses, address: u7) void {
        if (address == 0) return;
        self.taken[address] = false;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

/// A mass storage device's descriptor, as one answers.
const device_bytes = [_]u8{
    18, 1, 0x00, 0x02, 0x00, 0x00, 0x00, 64,
    0x51, 0x09, 0x06, 0x16, 0x00, 0x01, 1, 2, 3, 1,
};

/// One configuration: config, interface, two bulk endpoints.
const config_bytes = [_]u8{
    9,  2, 32, 0, 1, 1, 0, 0x80, 50,
    9,  4, 0,  0, 2, 0x08, 0x06, 0x50, 0,
    7,  5, 0x81, 0x02, 0x00, 0x02, 0,
    7,  5, 0x02, 0x02, 0x00, 0x02, 0,
};

test "a setup packet is the eight bytes the wire expects" {
    const setup = Setup.getDescriptor(.device, 0, 18);
    const bytes = std.mem.asBytes(&setup);
    try std.testing.expectEqual(@as(u8, 0x80), bytes[0]);
    try std.testing.expectEqual(@as(u8, 6), bytes[1]);
    // The descriptor type sits above the index in one little-endian word.
    try std.testing.expectEqual(@as(u16, 0x0100), std.mem.readInt(u16, bytes[2..4], .little));
    try std.testing.expectEqual(@as(u16, 18), std.mem.readInt(u16, bytes[6..8], .little));

    const addressed = Setup.setAddress(5);
    try std.testing.expectEqual(@as(u8, 0x00), std.mem.asBytes(&addressed)[0]);
    try std.testing.expectEqual(@as(u16, 5), addressed.value);
}

test "a device descriptor names its maker and its class" {
    const device = Device.parse(&device_bytes).?;
    try std.testing.expectEqual(@as(u16, 0x0200), device.usb_version);
    try std.testing.expectEqual(@as(u16, 0x0951), device.vendor);
    try std.testing.expectEqual(@as(u16, 0x1606), device.product);
    try std.testing.expectEqual(@as(u8, 64), device.max_packet_zero);
    try std.testing.expectEqual(Class.per_interface, device.class);
    try std.testing.expectEqual(@as(u8, 1), device.configurations);
}

test "the first short read gives endpoint zero's packet size" {
    try std.testing.expectEqual(@as(?u8, 64), Device.packetZeroOf(device_bytes[0..8]));

    // A size that is not a power of two is a device answering nonsense.
    var broken = device_bytes;
    broken[7] = 63;
    try std.testing.expectEqual(@as(?u8, null), Device.packetZeroOf(broken[0..8]));

    // And a descriptor that is not a device descriptor is refused.
    var wrong = device_bytes;
    wrong[1] = 2;
    try std.testing.expectEqual(@as(?u8, null), Device.packetZeroOf(wrong[0..8]));
}

test "a configuration walks to its interface and its endpoints" {
    const config = Configuration.parse(&config_bytes).?;
    try std.testing.expectEqual(@as(u16, 32), config.total_length);
    try std.testing.expectEqual(@as(u8, 1), config.interfaces);
    try std.testing.expectEqual(@as(u16, 100), config.milliamps());

    var found_interface: ?Interface = null;
    var endpoints: [4]Endpoint = undefined;
    var count: usize = 0;

    var it = walk(&config_bytes);
    while (it.next()) |record| {
        switch (record.kind) {
            .interface => found_interface = Interface.parse(record.bytes),
            .endpoint => {
                endpoints[count] = Endpoint.parse(record.bytes).?;
                count += 1;
            },
            else => {},
        }
    }

    const interface = found_interface.?;
    try std.testing.expectEqual(Class.mass_storage, interface.class);
    try std.testing.expectEqual(@as(u8, 0x50), interface.protocol);
    try std.testing.expectEqual(@as(usize, 2), count);

    try std.testing.expectEqual(Direction.in, endpoints[0].direction);
    try std.testing.expectEqual(@as(u4, 1), endpoints[0].number);
    try std.testing.expectEqual(TransferKind.bulk, endpoints[0].kind);
    try std.testing.expectEqual(@as(u16, 512), endpoints[0].max_packet);
    try std.testing.expectEqual(@as(u8, 0x81), endpoints[0].address());

    try std.testing.expectEqual(Direction.out, endpoints[1].direction);
    try std.testing.expectEqual(@as(u8, 0x02), endpoints[1].address());
}

test "a device that says nothing is described by its interface" {
    // The mass storage device above declares no class of its own.
    const descriptor = Device.parse(&device_bytes).?;
    const signature = signatureOf(descriptor, &config_bytes);
    try std.testing.expectEqual(Class.mass_storage, signature.class);
    try std.testing.expectEqual(@as(u8, 0x06), signature.subclass);
    try std.testing.expectEqual(@as(u8, 0x50), signature.protocol);
    // The maker travels with it either way, so a quirk can name one part.
    try std.testing.expectEqual(@as(u16, 0x0951), signature.vendor);
    try std.testing.expectEqual(@as(u16, 0x1606), signature.product);
}

test "a device that declares a class is taken at its word" {
    var hub = device_bytes;
    hub[4] = @intFromEnum(Class.hub);
    hub[5] = 0;
    hub[6] = 1;

    const signature = signatureOf(Device.parse(&hub).?, &config_bytes);
    try std.testing.expectEqual(Class.hub, signature.class);
    try std.testing.expectEqual(@as(u8, 1), signature.protocol);
}

test "addresses are handed out from one and given back" {
    var pool = Addresses{};
    try std.testing.expectEqual(@as(?u7, 1), pool.take());
    try std.testing.expectEqual(@as(?u7, 2), pool.take());
    try std.testing.expectEqual(@as(?u7, 3), pool.take());

    // A device that left frees the address for the next one.
    pool.release(2);
    try std.testing.expectEqual(@as(?u7, 2), pool.take());

    // Address zero is where every unaddressed device answers, so it is
    // never handed out and never freed.
    pool.release(0);
    try std.testing.expect(!pool.taken[0]);
}

test "a bus full of devices refuses rather than reusing an address" {
    var pool = Addresses{};
    var given: usize = 0;
    while (pool.take()) |_| given += 1;
    try std.testing.expectEqual(@as(usize, Addresses.MAX - 1), given);
    try std.testing.expectEqual(@as(?u7, null), pool.take());
}

test "a walk stops rather than trusting a length that cannot be" {
    // A record claiming more than remains.
    const overlong = [_]u8{ 9, 2, 32, 0, 1 };
    var it = walk(&overlong);
    try std.testing.expectEqual(@as(?Walk.Record, null), it.next());

    // A record shorter than its own header.
    const impossible = [_]u8{ 1, 2, 0, 0 };
    var second = walk(&impossible);
    try std.testing.expectEqual(@as(?Walk.Record, null), second.next());

    // A descriptor kind nobody here knows, a class's own, is walked over
    // rather than tripped on: the endpoint behind it still parses.
    const unknown = [_]u8{ 4, 0x21, 0, 0, 7, 5, 0x81, 0x03, 0x08, 0x00, 10 };
    var third = walk(&unknown);
    try std.testing.expectEqual(@as(u8, 0x21), @intFromEnum(third.next().?.kind));
    const endpoint = third.next().?;
    try std.testing.expectEqual(DescriptorType.endpoint, endpoint.kind);
    try std.testing.expectEqual(TransferKind.interrupt, Endpoint.parse(endpoint.bytes).?.kind);
}

test "a signature survives the trip through a device-manager request" {
    const original = Signature{
        .class = .mass_storage,
        .subclass = 0x06,
        .protocol = 0x50,
        .vendor = 0x0951,
        .product = 0x1666,
    };
    const back = Signature.unpack(original.pack());
    try std.testing.expectEqual(original.class, back.class);
    try std.testing.expectEqual(original.subclass, back.subclass);
    try std.testing.expectEqual(original.protocol, back.protocol);
    try std.testing.expectEqual(original.vendor, back.vendor);
    try std.testing.expectEqual(original.product, back.product);
}

test "a class this build has never met still packs and unpacks" {
    const original = Signature{ .class = @enumFromInt(0xAB), .subclass = 0xCD, .protocol = 0xEF };
    const back = Signature.unpack(original.pack());
    try std.testing.expectEqual(@as(u8, 0xAB), @intFromEnum(back.class));
    try std.testing.expectEqual(@as(u8, 0xCD), back.subclass);
    try std.testing.expectEqual(@as(u8, 0xEF), back.protocol);
}

test "a manifest naming one part matches only that part" {
    const disk = Signature{ .vendor = 0x0951, .product = 0x1666, .class = .mass_storage };
    try std.testing.expect(disk.matchesPart("usb:0951:1666"));
    try std.testing.expect(disk.matchesPart(" usb : 0951 : 1666 "));
    try std.testing.expect(!disk.matchesPart("usb:0951:1667"));
    try std.testing.expect(!disk.matchesPart("usb:0952:1666"));
    try std.testing.expect(!disk.matchesPart("pci:0951:1666"));
    try std.testing.expect(!disk.matchesPart("usb-class:08:06"));
    try std.testing.expect(!disk.matchesPart("usb"));
    try std.testing.expect(!disk.matchesPart(""));
}

test "a manifest naming a class matches every part in it" {
    const disk = Signature{
        .class = .mass_storage,
        .subclass = 0x06,
        .protocol = 0x50,
        .vendor = 0x0951,
        .product = 0x1666,
    };
    try std.testing.expect(disk.matchesClass("usb-class:08:06:50"));
    // No protocol named: the whole subclass.
    try std.testing.expect(disk.matchesClass("usb-class:08:06"));
    try std.testing.expect(disk.matchesClass("usb-class:08:06:"));
    // A different protocol of the same subclass is a different driver.
    try std.testing.expect(!disk.matchesClass("usb-class:08:06:62"));
    try std.testing.expect(!disk.matchesClass("usb-class:08:05"));
    try std.testing.expect(!disk.matchesClass("usb-class:03:01"));
    try std.testing.expect(!disk.matchesClass("usb:0951:1666"));
}

test "the status stage runs against the data stage, and in when there is none" {
    // A request that asks for nothing: the device does the work when the
    // host asks for its status, so the status stage must be in.
    try std.testing.expectEqual(Direction.in, Setup.setAddress(1).statusDirection());
    try std.testing.expectEqual(Direction.in, Setup.setConfiguration(1).statusDirection());
    try std.testing.expect(!Setup.setAddress(1).carriesData());

    // A read: data comes in, status goes out.
    const read = Setup.getDescriptor(.device, 0, 18);
    try std.testing.expect(read.carriesData());
    try std.testing.expectEqual(Direction.out, read.statusDirection());

    // A write with a payload: data goes out, status comes in.
    var write = Setup{ .request_type = .{ .direction = .out }, .request = .set_descriptor, .length = 4 };
    try std.testing.expectEqual(Direction.in, write.statusDirection());
    write.length = 0;
    try std.testing.expectEqual(Direction.in, write.statusDirection());
}

test "a pipe counts packets and flips its toggle once per packet" {
    var endpoint = Pipe{ .max_packet = 512 };

    // A transfer of nothing is one packet, so it flips.
    try std.testing.expectEqual(@as(usize, 1), endpoint.packetsFor(0));
    endpoint.advance(0);
    try std.testing.expect(endpoint.toggle);

    // A short transfer is one packet.
    try std.testing.expectEqual(@as(usize, 1), endpoint.packetsFor(31));
    endpoint.advance(31);
    try std.testing.expect(!endpoint.toggle);

    // Exactly one packet, then exactly two.
    try std.testing.expectEqual(@as(usize, 1), endpoint.packetsFor(512));
    try std.testing.expectEqual(@as(usize, 2), endpoint.packetsFor(513));
    try std.testing.expectEqual(@as(usize, 2), endpoint.packetsFor(1024));
    try std.testing.expectEqual(@as(usize, 3), endpoint.packetsFor(1025));

    // An even number of packets leaves the toggle where it was.
    endpoint.advance(1024);
    try std.testing.expect(!endpoint.toggle);
    endpoint.advance(1025);
    try std.testing.expect(endpoint.toggle);

    endpoint.resetToggle();
    try std.testing.expect(!endpoint.toggle);
}

test "a full speed pipe counts by its own packet size" {
    var endpoint = Pipe{ .speed = .full, .max_packet = 64 };
    try std.testing.expectEqual(@as(usize, 8), endpoint.packetsFor(512));
    endpoint.advance(512);
    try std.testing.expect(!endpoint.toggle);
    try std.testing.expectEqual(@as(usize, 9), endpoint.packetsFor(513));
    endpoint.advance(513);
    try std.testing.expect(endpoint.toggle);
}

test "a descriptor's endpoint opens into a pipe on a device" {
    const descriptor = Endpoint.parse(&[_]u8{ 7, 0x05, 0x81, 0x02, 0x00, 0x02, 0 }) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u4, 1), descriptor.number);
    try std.testing.expectEqual(Direction.in, descriptor.direction);
    try std.testing.expectEqual(TransferKind.bulk, descriptor.kind);
    try std.testing.expectEqual(@as(u16, 512), descriptor.max_packet);
    try std.testing.expectEqual(@as(u8, 0x81), descriptor.address());

    const pipe = descriptor.open(3, .high, .{});
    try std.testing.expectEqual(@as(u7, 3), pipe.address);
    try std.testing.expectEqual(@as(u4, 1), pipe.number);
    try std.testing.expectEqual(Direction.in, pipe.direction);
    try std.testing.expectEqual(@as(u16, 512), pipe.max_packet);
    try std.testing.expect(!pipe.toggle);
}

/// A configuration as a mass storage stick writes it: one interface of
/// class eight, subclass six, protocol eighty, with two bulk endpoints.
const STICK_CONFIGURATION = [_]u8{
    9,    0x02, 32,   0,    1,    1,    0,    0x80, 50,
    9,    0x04, 0,    0,    2,    0x08, 0x06, 0x50, 0,
    7,    0x05, 0x81, 0x02, 0x00, 0x02, 0,
    7,    0x05, 0x02, 0x02, 0x00, 0x02, 0,
};

test "an interface is found by class, with the endpoints under it" {
    const view = interfaceFor(&STICK_CONFIGURATION, .mass_storage, 0x06, 0x50) orelse
        return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u8, 0), view.interface.number);
    try std.testing.expectEqual(@as(u8, 2), view.endpoint_count);

    const reading = view.find(.bulk, .in) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u4, 1), reading.number);
    try std.testing.expectEqual(@as(u16, 512), reading.max_packet);

    const writing = view.find(.bulk, .out) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u4, 2), writing.number);

    // Nothing of a kind the interface does not carry.
    try std.testing.expect(view.find(.interrupt, .in) == null);

    // And nothing at all for a class this configuration does not offer.
    try std.testing.expect(interfaceFor(&STICK_CONFIGURATION, .human_interface, 1, 1) == null);
    try std.testing.expect(interfaceFor(&STICK_CONFIGURATION, .mass_storage, 0x06, 0x62) == null);
    try std.testing.expect(interfaceFor(&.{}, .mass_storage, 0x06, 0x50) == null);
}

test "endpoints after the next interface belong to that interface" {
    // A composite device: the wanted interface first, then another whose
    // endpoints must not be gathered into it.
    const composite = [_]u8{
        9, 0x02, 46,   0,    2,    1,    0,    0x80, 50,
        9, 0x04, 0,    0,    1,    0x08, 0x06, 0x50, 0,
        7, 0x05, 0x81, 0x02, 0x00, 0x02, 0,
        9, 0x04, 1,    0,    1,    0x03, 0x01, 0x01, 0,
        7, 0x05, 0x83, 0x03, 0x08, 0x00, 10,
    };

    const disk = interfaceFor(&composite, .mass_storage, 0x06, 0x50) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), disk.endpoint_count);
    try std.testing.expectEqual(@as(u4, 1), (disk.find(.bulk, .in) orelse unreachable).number);

    const keyboard = interfaceFor(&composite, .human_interface, 0x01, 0x01) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 1), keyboard.interface.number);
    try std.testing.expectEqual(@as(u8, 1), keyboard.endpoint_count);
    const polled = keyboard.find(.interrupt, .in) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u4, 3), polled.number);
    try std.testing.expectEqual(@as(u16, 8), polled.max_packet);
    try std.testing.expectEqual(@as(u8, 10), polled.interval);
}

test "the control requests a class driver sends are shaped as the wire wants" {
    const halt = Setup.clearHalt(0x81);
    try std.testing.expectEqual(@as(u8, 0x02), @as(u8, @bitCast(halt.request_type)));
    try std.testing.expectEqual(Request.clear_feature, halt.request);
    try std.testing.expectEqual(@as(u16, 0), halt.value);
    try std.testing.expectEqual(@as(u16, 0x81), halt.index);
    try std.testing.expectEqual(Direction.in, halt.statusDirection());

    // Get max lun: in, class, interface.
    const lun = Setup.classRequest(.in, 0xFE, 0, 0, 1);
    try std.testing.expectEqual(@as(u8, 0xA1), @as(u8, @bitCast(lun.request_type)));
    try std.testing.expectEqual(@as(u8, 0xFE), @intFromEnum(lun.request));
    try std.testing.expectEqual(@as(u16, 1), lun.length);
    try std.testing.expectEqual(Direction.out, lun.statusDirection());

    // Reset: out, class, interface, no data.
    const reset = Setup.classRequest(.out, 0xFF, 0, 0, 0);
    try std.testing.expectEqual(@as(u8, 0x21), @as(u8, @bitCast(reset.request_type)));
    try std.testing.expectEqual(Direction.in, reset.statusDirection());
}

test "a manifest may name several things one driver fits" {
    const keyboard = Signature{ .class = .human_interface, .subclass = 0x01, .protocol = 0x01 };
    const mouse = Signature{ .class = .human_interface, .subclass = 0x01, .protocol = 0x02 };
    const disk = Signature{ .class = .mass_storage, .subclass = 0x06, .protocol = 0x50 };

    const both = "usb-class:03:01:01, usb-class:03:01:02";
    try std.testing.expect(keyboard.matchesClass(both));
    try std.testing.expect(mouse.matchesClass(both));
    try std.testing.expect(!disk.matchesClass(both));

    // A list of parts, and a list mixing spacing and empty entries.
    const quirks = "usb:0951:1666,usb:0930:6545";
    const first = Signature{ .vendor = 0x0951, .product = 0x1666 };
    const second = Signature{ .vendor = 0x0930, .product = 0x6545 };
    const neither = Signature{ .vendor = 0x0951, .product = 0x1667 };
    try std.testing.expect(first.matchesPart(quirks));
    try std.testing.expect(second.matchesPart(quirks));
    try std.testing.expect(!neither.matchesPart(quirks));
    try std.testing.expect(first.matchesPart(" usb:0951:1666 , , usb:0000:0000 "));

    // A single entry is a list of one, which is what every manifest that
    // names one thing already was.
    try std.testing.expect(disk.matchesClass("usb-class:08:06:50"));
    try std.testing.expect(!disk.matchesClass(""));
    try std.testing.expect(!disk.matchesClass(",,"));
}

test "a hub says how many ports it has and how long they take to come up" {
    // Four ports, per-port power, fifty units of two milliseconds.
    const wire = [_]u8{ 9, Hub.DESCRIPTOR, 4, 0x09, 0x00, 50, 0x00, 0xFF, 0x00 };
    const hub = Hub.parse(&wire) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(u8, 4), hub.ports);
    try std.testing.expectEqual(@as(u16, 100), hub.power_on_ms);
    try std.testing.expect(hub.per_port_power);

    // A hub switching power all together says so in the low two bits.
    const ganged = [_]u8{ 9, Hub.DESCRIPTOR, 7, 0x00, 0x00, 1, 0x00 };
    const all = Hub.parse(&ganged) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u8, 7), all.ports);
    try std.testing.expect(!all.per_port_power);
    // Never less than the settling time, whatever the hub claims.
    try std.testing.expectEqual(@as(u16, 100), all.power_on_ms);

    // Anything that is not a hub descriptor is refused rather than read.
    try std.testing.expect(Hub.parse(&[_]u8{ 9, 0x02, 4, 0, 0, 50, 0 }) == null);
    try std.testing.expect(Hub.parse(wire[0..5]) == null);
}

test "a port's status says what is there and what has changed" {
    // Connected, enabled, powered, low speed; the connection changed.
    var wire: [4]u8 = @splat(0);
    std.mem.writeInt(u32, &wire, 0x0001_0303, .little);

    const port = PortStatus.parse(&wire) orelse return error.TestUnexpectedResult;
    try std.testing.expect(port.connected);
    try std.testing.expect(port.enabled);
    try std.testing.expect(port.powered);
    try std.testing.expect(port.low_speed);
    try std.testing.expectEqual(Speed.low, port.speed());
    try std.testing.expect(port.connection_changed);
    try std.testing.expect(!port.reset_changed);
    try std.testing.expect(port.changed());

    // Nothing set anywhere is an empty port with nothing to report.
    const empty = PortStatus{};
    try std.testing.expect(!empty.connected);
    try std.testing.expect(!empty.changed());
    // Neither speed bit is full speed, which is the one nobody flags.
    try std.testing.expectEqual(Speed.full, empty.speed());

    try std.testing.expect(PortStatus.parse(wire[0..3]) == null);
}

test "the port status bits sit where the specification puts them" {
    try std.testing.expectEqual(@as(u32, 0x0001), @as(u32, @bitCast(PortStatus{ .connected = true })));
    try std.testing.expectEqual(@as(u32, 0x0010), @as(u32, @bitCast(PortStatus{ .resetting = true })));
    try std.testing.expectEqual(@as(u32, 0x0100), @as(u32, @bitCast(PortStatus{ .powered = true })));
    try std.testing.expectEqual(@as(u32, 0x0200), @as(u32, @bitCast(PortStatus{ .low_speed = true })));
    try std.testing.expectEqual(@as(u32, 0x0400), @as(u32, @bitCast(PortStatus{ .high_speed = true })));
    try std.testing.expectEqual(@as(u32, 0x0001_0000), @as(u32, @bitCast(PortStatus{ .connection_changed = true })));
    try std.testing.expectEqual(@as(u32, 0x0010_0000), @as(u32, @bitCast(PortStatus{ .reset_changed = true })));
}

test "the hub's port requests are shaped the way the wire wants" {
    const status = hub_requests.portStatus(3);
    try std.testing.expectEqual(@as(u8, 0xA3), @as(u8, @bitCast(status.request_type)));
    try std.testing.expectEqual(Request.get_status, status.request);
    try std.testing.expectEqual(@as(u16, 3), status.index);
    try std.testing.expectEqual(@as(u16, 4), status.length);

    const reset = hub_requests.setPort(2, .reset);
    try std.testing.expectEqual(@as(u8, 0x23), @as(u8, @bitCast(reset.request_type)));
    try std.testing.expectEqual(Request.set_feature, reset.request);
    try std.testing.expectEqual(@as(u16, 4), reset.value);
    try std.testing.expectEqual(@as(u16, 2), reset.index);
    // No data stage, so the status stage runs in.
    try std.testing.expectEqual(Direction.in, reset.statusDirection());

    const clear = hub_requests.clearPort(1, .connection_changed);
    try std.testing.expectEqual(Request.clear_feature, clear.request);
    try std.testing.expectEqual(@as(u16, 16), clear.value);

    const descriptor = hub_requests.descriptor(9);
    try std.testing.expectEqual(@as(u8, 0xA0), @as(u8, @bitCast(descriptor.request_type)));
    try std.testing.expectEqual(@as(u16, 0x2900), descriptor.value);
}

test "only a slow device behind a hub on a fast bus needs splitting" {
    const root = Route{};
    const behind = Route{ .hub = 2, .port = 3 };

    // A root port never splits, whatever speed anything is.
    try std.testing.expect(!root.splits(.low, .high));
    try std.testing.expect(!root.splits(.full, .high));

    // Behind a hub on a high speed bus, a slow device does.
    try std.testing.expect(behind.splits(.low, .high));
    try std.testing.expect(behind.splits(.full, .high));
    // A high speed device talks for itself wherever it is.
    try std.testing.expect(!behind.splits(.high, .high));
    // And a controller that is slow itself has nothing to split.
    try std.testing.expect(!behind.splits(.low, .full));
    try std.testing.expect(!behind.splits(.full, .full));
}

test "a device's language list is read from its first entry" {
    // Two languages: English, then French.
    const wire = [_]u8{ 6, 0x03, 0x09, 0x04, 0x0C, 0x04 };
    try std.testing.expectEqual(@as(u16, 0x0409), firstLanguage(&wire).?);

    try std.testing.expect(firstLanguage(&[_]u8{ 4, 0x02, 0x09, 0x04 }) == null);
    try std.testing.expect(firstLanguage(&[_]u8{ 2, 0x03 }) == null);
}

test "a device's name is read out of its own encoding" {
    var into: [32]u8 = undefined;

    // "USB" as the wire carries it: length, type, then two bytes a letter.
    const wire = [_]u8{ 8, 0x03, 'U', 0, 'S', 0, 'B', 0 };
    try std.testing.expectEqualStrings("USB", decodeString(&wire, &into));

    // A character outside plain ASCII is encoded rather than truncated.
    const accented = [_]u8{ 6, 0x03, 0xE9, 0x00, 'a', 0 };
    try std.testing.expectEqualStrings("éa", decodeString(&accented, &into));

    // The descriptor's own length is what bounds the text, so trailing
    // bytes past it are not read as characters.
    const short = [_]u8{ 4, 0x03, 'A', 0, 'B', 0 };
    try std.testing.expectEqualStrings("A", decodeString(&short, &into));

    // A device that overstates its length is not followed past what came.
    const overstated = [_]u8{ 40, 0x03, 'A', 0 };
    try std.testing.expectEqualStrings("A", decodeString(&overstated, &into));

    // Half of a character outside the basic plane is worse than none.
    const surrogate = [_]u8{ 8, 0x03, 0x3D, 0xD8, 'x', 0 };
    try std.testing.expectEqualStrings("x", decodeString(&surrogate, &into));

    // A name longer than the room for it is cut, not overrun.
    var tiny: [2]u8 = undefined;
    const long = [_]u8{ 10, 0x03, 'a', 0, 'b', 0, 'c', 0, 'd', 0 };
    try std.testing.expectEqualStrings("ab", decodeString(&long, &tiny));

    // Anything that is not a string descriptor is refused.
    try std.testing.expectEqualStrings("", decodeString(&[_]u8{ 8, 0x02, 'U', 0 }, &into));
    try std.testing.expectEqualStrings("", decodeString(&[_]u8{ 2, 0x03 }, &into));
}

test "a string request names the language it wants" {
    const languages = Setup.stringDescriptor(0, 0, 8);
    try std.testing.expectEqual(@as(u16, 0x0300), languages.value);
    try std.testing.expectEqual(@as(u16, 0), languages.index);

    const product = Setup.stringDescriptor(2, 0x0409, 64);
    try std.testing.expectEqual(@as(u16, 0x0302), product.value);
    try std.testing.expectEqual(@as(u16, 0x0409), product.index);
    try std.testing.expectEqual(Direction.out, product.statusDirection());
}

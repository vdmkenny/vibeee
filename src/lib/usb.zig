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
const devspec = @import("devspec.zig");
const serial = @import("serial.zig");

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

/// An endpoint's address as the wire writes it: the number, and the direction
/// in the top bit.
///
/// A struct rather than the two halves put together by hand at each use. Three
/// places built this byte with the same shift, and the one with a test was not
/// the one that ran on hardware.
pub const EndpointAddress = packed struct(u8) {
    number: u4 = 0,
    _reserved: u3 = 0,
    direction: Direction = .out,

    pub fn byte(self: EndpointAddress) u8 {
        return @bitCast(self);
    }
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
    /// A descriptor a class defines, written under an interface. Its
    /// third byte says which of its class's descriptors it is.
    interface_functional = 0x24,
    /// The same, written under an endpoint.
    endpoint_functional = 0x25,
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

    /// A request a maker defines rather than the specification, aimed at
    /// the device itself. What `index` means is that maker's business:
    /// on a device with more than one port it is usually which port.
    pub fn vendorRequest(
        direction: Direction,
        request: u8,
        value: u16,
        index: u16,
        length: u16,
    ) Setup {
        return .{
            .request_type = .{ .direction = direction, .kind = .vendor, .recipient = .device },
            .request = @enumFromInt(request),
            .value = value,
            .index = index,
            .length = length,
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
    /// The other half of a communications device: the interface its
    /// bytes travel on, while the requests go to the first.
    cdc_data = 0x0A,
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
            .cdc_data => "communications data",
            .video => "video",
            .wireless => "wireless",
            .vendor_specific => "vendor",
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

/// The packet-size word of an endpoint descriptor.
///
/// The size is eleven bits; the two above it say how many transactions a
/// high-speed device wants per microframe, counted from zero. Kept as a shape
/// rather than masked off, because the controller that schedules the polling
/// has a field for it and could only ever fill it with one.
pub const MaxPacket = packed struct(u16) {
    size: u11 = 0,
    per_microframe: u2 = 0,
    _reserved: u3 = 0,
};

pub const Endpoint = struct {
    /// The endpoint's number, without the direction bit.
    number: u4 = 0,
    direction: Direction = .out,
    kind: TransferKind = .control,
    max_packet: u16 = 0,
    /// How many transactions per microframe this endpoint wants, one for
    /// everything but a high-speed device asking for more.
    per_microframe: u2 = 1,
    /// Frames between polls, for the kinds that are polled.
    interval: u8 = 0,

    pub const BYTES = 7;

    pub fn parse(bytes: []const u8) ?Endpoint {
        if (bytes.len < BYTES) return null;
        if (bytes[1] != @intFromEnum(DescriptorType.endpoint)) return null;
        const packet: MaxPacket = @bitCast(std.mem.readInt(u16, bytes[4..6], .little));
        return .{
            .number = @truncate(bytes[2]),
            .direction = if (bytes[2] & 0x80 != 0) .in else .out,
            .kind = @enumFromInt(@as(u2, @truncate(bytes[3]))),
            .max_packet = packet.size,
            .per_microframe = packet.per_microframe + 1,
            .interval = bytes[6],
        };
    }

    /// The address as the wire writes it.
    pub fn address(self: Endpoint) EndpointAddress {
        return .{ .number = self.number, .direction = self.direction };
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
            .per_microframe = self.per_microframe,
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
/// How long a connection must have been seen standing before the reset
/// that follows it. Contact bounce reads as a parade of arrivals, and the
/// specification owes a device a hundred milliseconds of stable attach
/// before anything is done to it.
pub const ATTACH_DEBOUNCE_US: u32 = 100_000;

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
    /// How many transactions per microframe this endpoint asked for. One for
    /// everything but a high-speed endpoint that wants more bandwidth than a
    /// single packet a microframe gives it.
    per_microframe: u2 = 1,
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

    /// The address as the wire writes it, which is what a request naming this
    /// endpoint carries.
    pub fn address_on_wire(self: Pipe) EndpointAddress {
        return .{ .number = self.number, .direction = self.direction };
    }
};

pub const Signature = struct {
    class: Class = .per_interface,
    subclass: u8 = 0,
    protocol: u8 = 0,
    vendor: u16 = 0,
    product: u16 = 0,

    /// The signature as the two numbers a device-manager request carries.
    ///
    /// One shape for each word rather than a pair of functions built from
    /// shifts: the packing runs in the bus service and the unpacking in the
    /// device manager, across a channel, so a shift changed on one side would
    /// compile, link, and bind the wrong driver. A cast between a struct and
    /// its own bits cannot come apart that way.
    pub fn pack(self: Signature) Packed {
        return .{
            .kind = @bitCast(Kind{
                .protocol = self.protocol,
                .subclass = self.subclass,
                .class = self.class,
            }),
            .part = @bitCast(Part{ .product = self.product, .vendor = self.vendor }),
        };
    }

    pub fn unpack(numbers: Packed) Signature {
        const kind: Kind = @bitCast(numbers.kind);
        const part_of: Part = @bitCast(numbers.part);
        return .{
            .class = kind.class,
            .subclass = kind.subclass,
            .protocol = kind.protocol,
            .vendor = part_of.vendor,
            .product = part_of.product,
        };
    }

    /// What a device is, in one word.
    pub const Kind = packed struct(u32) {
        protocol: u8 = 0,
        subclass: u8 = 0,
        class: Class = .per_interface,
        _reserved: u8 = 0,
    };

    /// Which device it is, in the other.
    pub const Part = packed struct(u32) {
        product: u16 = 0,
        vendor: u16 = 0,
    };

    pub const Packed = struct { kind: u32, part: u32 };

    /// Whether a manifest's `match` line names this exact device:
    /// `usb:vendor:product`, in hex. The line may list several, separated
    /// by commas: one driver and one program can serve several devices,
    /// and saying so once beats a manifest each.
    pub fn matchesPart(self: Signature, match: []const u8) bool {
        return devspec.any(match, self, part);
    }

    /// Whether it names this device's class: `usb-class:class:subclass`,
    /// with an optional protocol, and again a comma-separated list.
    pub fn matchesClass(self: Signature, match: []const u8) bool {
        return devspec.any(match, self, class_);
    }

    fn part(self: Signature, spec: []const u8) bool {
        var fields = devspec.Spec.under(spec, "usb") orelse return false;
        return fields.is(self.vendor) and fields.is(self.product);
    }

    fn class_(self: Signature, spec: []const u8) bool {
        var fields = devspec.Spec.under(spec, "usb-class") orelse return false;
        return fields.is(@intFromEnum(self.class)) and fields.is(self.subclass) and
            fields.isOrAbsent(self.protocol);
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
    /// Everything the device wrote under this interface and before the
    /// next one, endpoint descriptors included.
    ///
    /// A class that describes itself in descriptors of its own puts them
    /// here, and where exactly it puts them is not something to depend
    /// on: some devices write them after the interface and some after
    /// its endpoints, so the span covers both and the reader filters.
    under: []const u8 = &.{},

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

/// Which interface of a configuration is wanted.
///
/// Two ways of naming one, because a class driver knows what it drives
/// and a device that pairs two interfaces names the other by number.
pub const Wanted = union(enum) {
    /// The first interface that says it is this. A null protocol takes
    /// whichever the device declares, for a class where the protocol
    /// names a dialect above the interface rather than the interface.
    signature: struct { class: Class, subclass: u8, protocol: ?u8 = null },
    /// The interface the device gave this number, whatever it is.
    numbered: u8,

    fn matches(self: Wanted, interface: Interface) bool {
        return switch (self) {
            .signature => |want| interface.class == want.class and
                interface.subclass == want.subclass and
                (want.protocol == null or interface.protocol == want.protocol.?),
            .numbered => |number| interface.number == number,
        };
    }
};

/// The interface a configuration wanted, and its endpoints. Alternate
/// settings other than the first are skipped: a device offering a faster
/// alternate is asking to be configured, which is more than a driver
/// needs to start.
pub fn interfaceIn(configuration: []const u8, wanted: Wanted) ?InterfaceView {
    var records = walk(configuration);
    var found: ?InterfaceView = null;
    var began: usize = 0;

    while (records.next()) |record| {
        // Where this record started, which is where the span under the
        // interface before it ends.
        const here = records.at - record.bytes.len;
        switch (record.kind) {
            .interface => {
                if (found) |*view| {
                    view.under = configuration[began..here];
                    return view.*;
                }
                const interface = Interface.parse(record.bytes) orelse continue;
                if (interface.alternate != 0) continue;
                if (!wanted.matches(interface)) continue;
                found = .{ .interface = interface };
                began = records.at;
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
    if (found) |*view| view.under = configuration[began..records.at];
    return found;
}

/// The interface in a configuration that matches a class exactly, which
/// is what a driver for one class of device asks for.
pub fn interfaceFor(
    configuration: []const u8,
    class: Class,
    subclass: u8,
    protocol: u8,
) ?InterfaceView {
    return interfaceIn(configuration, .{
        .signature = .{ .class = class, .subclass = subclass, .protocol = protocol },
    });
}

// ---------------------------------------------------------------------------
// Communications devices: a serial port reached over the bus
// ---------------------------------------------------------------------------

/// The serial port a communications device presents.
///
/// Two interfaces make one port: the first takes the requests that set
/// the line up, the second carries the bytes. Which is which the device
/// says in descriptors of its own, written under the first, and enough of
/// them get it wrong that every reference driver carries the same three
/// fallbacks. They are here, in one function, tested against the shapes
/// real devices write rather than against the specification.
pub const cdc = struct {
    /// What a communications interface does. Only the one a serial port
    /// is named; the rest travel as numbers.
    pub const Subclass = enum(u8) {
        abstract_control = 0x02,
        _,
    };

    /// The highest protocol number that is still a serial port.
    ///
    /// Zero is a plain port. One to six are modems, each answering a
    /// different dialect of AT commands, which is the business of
    /// whatever talks to the port rather than of the port. Above that is
    /// a device wearing this class's number for reasons of its own, and
    /// its bytes are not a byte stream.
    pub const COMMANDS_MAX: u8 = 0x06;

    pub fn speaksSerial(protocol: u8) bool {
        return protocol <= COMMANDS_MAX;
    }

    /// The descriptors a communications interface writes under itself,
    /// by the subtype in their third byte.
    pub const Functional = enum(u8) {
        header = 0x00,
        /// Says which interface carries the bytes, among other things.
        call_management = 0x01,
        abstract_control = 0x02,
        /// Names the interfaces that together make one function: the one
        /// that takes the requests, then the ones that carry the bytes.
        @"union" = 0x06,
        country = 0x07,
        _,
    };

    /// Which of its class's descriptors a record is, or nothing when it
    /// is not one of them at all.
    pub fn functionalOf(bytes: []const u8) ?Functional {
        if (bytes.len < 3) return null;
        if (bytes[1] != @intFromEnum(DescriptorType.interface_functional)) return null;
        return @enumFromInt(bytes[2]);
    }

    /// What the host asks a serial port to do. Every one of these is a
    /// class request aimed at the interface that takes them, never at
    /// the one carrying the bytes.
    pub const Ask = enum(u8) {
        set_line_coding = 0x20,
        get_line_coding = 0x21,
        set_control_lines = 0x22,
        send_break = 0x23,
        _,
    };

    /// How the port is to treat the line, as `set_line_coding` carries
    /// it: the same four facts `serial.Line` holds, in the order and the
    /// numbering the wire writes them.
    ///
    /// The numbering is the same because this class took it from RS-232,
    /// which is where `lib.serial` takes it from too; the order is not,
    /// which is the whole reason this is a second shape.
    pub const LineCoding = extern struct {
        /// Bits per second.
        rate: u32 align(1) = 9600,
        stop: serial.Stop = .one,
        parity: serial.Parity = .none,
        /// Bits to a character, counted rather than named.
        bits: u8 = 8,

        pub const BYTES = 7;

        pub fn of(set: serial.Line) LineCoding {
            return .{
                .rate = set.rate,
                .stop = set.stop,
                .parity = set.parity,
                .bits = set.bits,
            };
        }

        pub fn line(self: LineCoding) serial.Line {
            return .{
                .rate = self.rate,
                .bits = self.bits,
                .parity = self.parity,
                .stop = self.stop,
            };
        }

        pub fn parse(bytes: []const u8) ?LineCoding {
            if (bytes.len < BYTES) return null;
            return .{
                .rate = std.mem.readInt(u32, bytes[0..4], .little),
                .stop = @enumFromInt(bytes[4]),
                .parity = @enumFromInt(bytes[5]),
                .bits = bytes[6],
            };
        }
    };

    pub fn setLineCoding(interface: u8) Setup {
        return Setup.classRequest(
            .out,
            @intFromEnum(Ask.set_line_coding),
            0,
            interface,
            LineCoding.BYTES,
        );
    }

    /// Hold up the lines that say a program has the port open. The
    /// request carries them in its value, where only the low two bits
    /// mean anything.
    pub fn setControlLines(interface: u8, held: serial.Held) Setup {
        return Setup.classRequest(
            .out,
            @intFromEnum(Ask.set_control_lines),
            @as(u8, @bitCast(held)),
            interface,
            0,
        );
    }

    /// Hold the line at break for this many milliseconds. All ones holds
    /// it until told otherwise, and zero lets it go.
    pub fn sendBreak(interface: u8, milliseconds: u16) Setup {
        return Setup.classRequest(
            .out,
            @intFromEnum(Ask.send_break),
            milliseconds,
            interface,
            0,
        );
    }

    pub const BREAK_UNTIL_TOLD: u16 = 0xFFFF;
    pub const BREAK_OFF: u16 = 0;

    /// What a device says on its notice endpoint, without the payload.
    ///
    /// The same eight bytes a setup packet has, sent the other way: the
    /// device asking the host to look at something rather than the other
    /// way round.
    pub const Notice = struct {
        what: Kind,
        /// How many bytes follow these eight.
        length: u16,

        pub const BYTES = Setup.BYTES;

        pub const Kind = enum(u8) {
            network_connection = 0x00,
            response_available = 0x01,
            serial_state = 0x20,
            speed_change = 0x2A,
            _,
        };

        /// The one request type a notice carries: a class request, about
        /// an interface, travelling from the device.
        const from_device = RequestType{ .direction = .in, .kind = .class, .recipient = .interface };

        pub fn parse(bytes: []const u8) ?Notice {
            if (bytes.len < BYTES) return null;
            if (bytes[0] != @as(u8, @bitCast(from_device))) return null;
            return .{
                .what = @enumFromInt(bytes[1]),
                .length = std.mem.readInt(u16, bytes[6..8], .little),
            };
        }

        /// The payload of a notice, bounded by both what it claims and
        /// what actually arrived.
        pub fn payload(self: Notice, bytes: []const u8) []const u8 {
            if (bytes.len <= BYTES) return &.{};
            const rest = bytes[BYTES..];
            return rest[0..@min(self.length, rest.len)];
        }
    };

    /// What the device said its line is doing, out of the payload of a
    /// `serial_state` notice.
    ///
    /// The bitmap this class sends is exactly `serial.State`: RS-232's
    /// own facts in RS-232's own order, which is what the class copied.
    pub fn stateOf(payload: []const u8) ?serial.State {
        if (payload.len < 2) return null;
        // Only the seven this class defines: the rest of the word is
        // reserved, and a device setting one of them is not saying
        // anything about a line that this class can carry.
        const word = std.mem.readInt(u16, payload[0..2], .little);
        return @bitCast(word & SAID);
    }

    /// The bits of `serial.State` this class has anything to say about.
    const SAID: u16 = @bitCast(serial.State{
        .dcd = true,
        .dsr = true,
        .broke = true,
        .ring = true,
        .framing = true,
        .parity = true,
        .overrun = true,
    });

    /// A serial port as a configuration describes it.
    pub const Port = struct {
        /// The interface every request goes to.
        control: u8,
        /// The interface the bytes travel on.
        data: u8,
        read: Endpoint,
        write: Endpoint,
        /// Where the device says what its lines are doing, if it has
        /// anywhere to say it. Optional: a port works without one, and
        /// devices ship without one.
        notice: ?Endpoint = null,
    };

    /// The serial port a configuration describes, or nothing where it
    /// describes none.
    ///
    /// The interface that takes the requests is found by what it says it
    /// is. The one carrying the bytes is whichever of these the device
    /// managed: named by a union descriptor, named by a call management
    /// descriptor, the same interface where it carries all three
    /// endpoints itself, or simply the next one along. Whichever it
    /// turns out to be, the bulk pair is found by what the endpoints are
    /// rather than by the order they were written in, which is the last
    /// of the ways a device gets this wrong.
    pub fn portIn(configuration: []const u8) ?Port {
        const control = interfaceIn(configuration, .{ .signature = .{
            .class = .communications,
            .subclass = @intFromEnum(Subclass.abstract_control),
        } }) orelse return null;
        if (!speaksSerial(control.interface.protocol)) return null;

        const paired = pairedWith(configuration, control) orelse control;
        // A device that put the bulk pair somewhere other than where it
        // said it would has still said where they are, by having them
        // there: the interface that carries them is the data interface.
        const carrier = if (bulkPair(paired) != null) paired else control;
        const pair = bulkPair(carrier) orelse return null;

        return .{
            .control = control.interface.number,
            .data = carrier.interface.number,
            .read = pair.read,
            .write = pair.write,
            .notice = control.find(.interrupt, .in),
        };
    }

    const Bulk = struct { read: Endpoint, write: Endpoint };

    fn bulkPair(view: InterfaceView) ?Bulk {
        return .{
            .read = view.find(.bulk, .in) orelse return null,
            .write = view.find(.bulk, .out) orelse return null,
        };
    }

    /// The interface that goes with the one taking the requests.
    fn pairedWith(configuration: []const u8, control: InterfaceView) ?InterfaceView {
        if (dataNumberIn(control.under)) |number| {
            if (interfaceIn(configuration, .{ .numbered = number })) |view| return view;
        }
        // Nothing said, or what was named is not there. Three endpoints
        // on the one interface is a whole port by itself; otherwise the
        // bytes are on the interface after the one taking the requests,
        // which is where a device that says nothing puts them.
        if (control.endpoint_count >= 3) return control;
        return interfaceIn(configuration, .{ .numbered = control.interface.number +% 1 });
    }

    /// Which interface the descriptors under a communications interface
    /// say carries the bytes.
    ///
    /// A union descriptor is the answer where there is one, and a call
    /// management descriptor where there is not. First of each wins: a
    /// device writing two of either has contradicted itself, and the one
    /// it wrote first is no worse a guess than the one it wrote last.
    fn dataNumberIn(under: []const u8) ?u8 {
        var united: ?u8 = null;
        var managed: ?u8 = null;

        var records = walk(under);
        while (records.next()) |record| {
            if (record.kind != .interface_functional) continue;
            // Both carry the interface number in their fifth byte, and
            // both are written longer than five bytes by devices with
            // more than one subordinate interface to name.
            if (record.bytes.len < 5) continue;
            const which = record.bytes[4];
            switch (functionalOf(record.bytes) orelse continue) {
                .@"union" => if (united == null) {
                    united = which;
                },
                .call_management => if (managed == null) {
                    managed = which;
                },
                else => {},
            }
        }
        return united orelse managed;
    }
};

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
    18,   1,    0x00, 0x02, 0x00, 0x00, 0x00, 64,
    0x51, 0x09, 0x06, 0x16, 0x00, 0x01, 1,    2,
    3,    1,
};

/// One configuration: config, interface, two bulk endpoints.
const config_bytes = [_]u8{
    9,    2,    32,   0,    1,    1,    0,    0x80, 50,
    9,    4,    0,    0,    2,    0x08, 0x06, 0x50, 0,
    7,    5,    0x81, 0x02, 0x00, 0x02, 0,    7,    5,
    0x02, 0x02, 0x00, 0x02, 0,
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
    try std.testing.expectEqual(@as(u8, 0x81), endpoints[0].address().byte());

    try std.testing.expectEqual(Direction.out, endpoints[1].direction);
    try std.testing.expectEqual(@as(u8, 0x02), endpoints[1].address().byte());
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
    try std.testing.expectEqual(@as(u8, 0x81), descriptor.address().byte());

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
    7,    0x05, 0x81, 0x02, 0x00, 0x02, 0,    7,    0x05,
    0x02, 0x02, 0x00, 0x02, 0,
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
        9,    0x02, 46,   0,    2,    1,    0,    0x80, 50,
        9,    0x04, 0,    0,    1,    0x08, 0x06, 0x50, 0,
        7,    0x05, 0x81, 0x02, 0x00, 0x02, 0,    9,    0x04,
        1,    0,    1,    0x03, 0x01, 0x01, 0,    7,    0x05,
        0x83, 0x03, 0x08, 0x00, 10,
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

// ---------------------------------------------------------------------------
// Serial ports
// ---------------------------------------------------------------------------

/// The descriptors a communications interface writes under itself, in the
/// order and at the lengths devices actually write them.
const cdc_header = [_]u8{ 5, 0x24, 0x00, 0x10, 0x01 };
const cdc_call_management = [_]u8{ 5, 0x24, 0x01, 0x01, 1 };
const cdc_abstract_control = [_]u8{ 4, 0x24, 0x02, 0x02 };
const cdc_union = [_]u8{ 5, 0x24, 0x06, 0, 1 };

const comm_interface = [_]u8{ 9, 4, 0, 0, 1, 0x02, 0x02, 0x01, 0 };
const notice_endpoint = [_]u8{ 7, 5, 0x82, 0x03, 0x08, 0x00, 0xFF };
const data_interface = [_]u8{ 9, 4, 1, 0, 2, 0x0A, 0x00, 0x00, 0 };
const bulk_in = [_]u8{ 7, 5, 0x83, 0x02, 0x40, 0x00, 0 };
const bulk_out = [_]u8{ 7, 5, 0x04, 0x02, 0x40, 0x00, 0 };

/// A configuration header long enough to walk; the length it claims is
/// not what bounds the walk, the bytes that arrived are.
const cdc_config = [_]u8{ 9, 2, 0, 0, 2, 1, 0, 0xC0, 50 };

test "a serial port is found across the two interfaces that make it" {
    const bytes = cdc_config ++ comm_interface ++ cdc_header ++ cdc_call_management ++
        cdc_abstract_control ++ cdc_union ++ notice_endpoint ++
        data_interface ++ bulk_out ++ bulk_in;

    const port = cdc.portIn(&bytes).?;
    try std.testing.expectEqual(@as(u8, 0), port.control);
    try std.testing.expectEqual(@as(u8, 1), port.data);
    // Found by what they are, not by the order they were written in: the
    // device above wrote the one that writes first.
    try std.testing.expectEqual(@as(u4, 3), port.read.number);
    try std.testing.expectEqual(Direction.in, port.read.direction);
    try std.testing.expectEqual(@as(u4, 4), port.write.number);
    try std.testing.expectEqual(@as(u16, 64), port.write.max_packet);
    try std.testing.expectEqual(@as(u4, 2), port.notice.?.number);
    try std.testing.expectEqual(TransferKind.interrupt, port.notice.?.kind);
}

test "a device that names its data interface only in the call management descriptor" {
    const bytes = cdc_config ++ comm_interface ++ cdc_header ++ cdc_call_management ++
        notice_endpoint ++ data_interface ++ bulk_in ++ bulk_out;

    const port = cdc.portIn(&bytes).?;
    try std.testing.expectEqual(@as(u8, 1), port.data);
    try std.testing.expectEqual(@as(u4, 3), port.read.number);
}

test "a device that names nothing leaves the bytes on the interface after" {
    const bytes = cdc_config ++ comm_interface ++ notice_endpoint ++
        data_interface ++ bulk_in ++ bulk_out;

    const port = cdc.portIn(&bytes).?;
    try std.testing.expectEqual(@as(u8, 0), port.control);
    try std.testing.expectEqual(@as(u8, 1), port.data);
    try std.testing.expectEqual(@as(u4, 2), port.notice.?.number);
}

test "a device that carries all three endpoints itself is a port by itself" {
    // One interface, no second one to pair with, and the three endpoints
    // a port needs: requests and bytes go to the same interface.
    const alone = [_]u8{ 9, 4, 0, 0, 3, 0x02, 0x02, 0x00, 0 };
    const bytes = cdc_config ++ alone ++ notice_endpoint ++ bulk_in ++ bulk_out;

    const port = cdc.portIn(&bytes).?;
    try std.testing.expectEqual(@as(u8, 0), port.control);
    try std.testing.expectEqual(@as(u8, 0), port.data);
    try std.testing.expectEqual(@as(u4, 3), port.read.number);
    try std.testing.expectEqual(@as(u4, 4), port.write.number);
    try std.testing.expectEqual(@as(u4, 2), port.notice.?.number);
}

test "a device whose union descriptor names an interface that is not there" {
    // The union says interface 3; there is no interface 3. The walk falls
    // through to the interface after the one taking the requests rather
    // than refusing a port that is plainly there.
    const wrong = [_]u8{ 5, 0x24, 0x06, 0, 3 };
    const bytes = cdc_config ++ comm_interface ++ wrong ++ notice_endpoint ++
        data_interface ++ bulk_in ++ bulk_out;

    const port = cdc.portIn(&bytes).?;
    try std.testing.expectEqual(@as(u8, 1), port.data);
}

test "a communications interface that is not a serial port is left alone" {
    // Protocol 0xFF: a device wearing this class's number for its own
    // reasons, whose bytes are not a byte stream.
    const vendor = [_]u8{ 9, 4, 0, 0, 1, 0x02, 0x02, 0xFF, 0 };
    const bytes = cdc_config ++ vendor ++ cdc_union ++ notice_endpoint ++
        data_interface ++ bulk_in ++ bulk_out;
    try std.testing.expectEqual(@as(?cdc.Port, null), cdc.portIn(&bytes));

    // And a configuration with no communications interface at all.
    try std.testing.expectEqual(@as(?cdc.Port, null), cdc.portIn(&config_bytes));
}

test "a port with no bulk pair is not a port" {
    const bytes = cdc_config ++ comm_interface ++ cdc_union ++ notice_endpoint ++
        data_interface ++ bulk_in;
    try std.testing.expectEqual(@as(?cdc.Port, null), cdc.portIn(&bytes));
}

test "the line coding is the seven bytes the wire writes" {
    const coding = cdc.LineCoding{ .rate = 115200, .stop = .two, .parity = .even, .bits = 7 };
    const bytes = std.mem.asBytes(&coding);
    try std.testing.expectEqual(@as(usize, cdc.LineCoding.BYTES), bytes.len);
    try std.testing.expectEqual(@as(u32, 115200), std.mem.readInt(u32, bytes[0..4], .little));
    try std.testing.expectEqual(@as(u8, 2), bytes[4]);
    try std.testing.expectEqual(@as(u8, 2), bytes[5]);
    try std.testing.expectEqual(@as(u8, 7), bytes[6]);

    const back = cdc.LineCoding.parse(bytes).?;
    try std.testing.expectEqual(coding.rate, back.rate);
    try std.testing.expectEqual(coding.stop, back.stop);
    try std.testing.expectEqual(coding.parity, back.parity);
    try std.testing.expectEqual(coding.bits, back.bits);

    // The same four facts a line is set by, in the order the wire wants
    // them rather than the order a person says them.
    const line = serial.Line{ .rate = 115200, .bits = 7, .parity = .even, .stop = .two };
    try std.testing.expectEqual(coding, cdc.LineCoding.of(line));
    try std.testing.expectEqual(line, coding.line());
}

test "the requests a port answers are aimed at the interface that takes them" {
    const setup = cdc.setLineCoding(2);
    try std.testing.expectEqual(@as(u8, 0x21), @as(u8, @bitCast(setup.request_type)));
    try std.testing.expectEqual(@as(u8, 0x20), @intFromEnum(setup.request));
    try std.testing.expectEqual(@as(u16, 2), setup.index);
    try std.testing.expectEqual(@as(u16, cdc.LineCoding.BYTES), setup.length);

    const lines = cdc.setControlLines(2, .{ .dtr = true, .rts = true });
    try std.testing.expectEqual(@as(u8, 0x22), @intFromEnum(lines.request));
    try std.testing.expectEqual(@as(u16, 3), lines.value);
    try std.testing.expectEqual(@as(u16, 0), lines.length);

    const broken = cdc.sendBreak(2, cdc.BREAK_UNTIL_TOLD);
    try std.testing.expectEqual(@as(u16, 0xFFFF), broken.value);
}

test "a notice says what its device is telling the host" {
    const bytes = [_]u8{ 0xA1, 0x20, 0, 0, 0, 0, 2, 0, 0x03, 0x00 };
    const notice = cdc.Notice.parse(&bytes).?;
    try std.testing.expectEqual(cdc.Notice.Kind.serial_state, notice.what);
    try std.testing.expectEqual(@as(u16, 2), notice.length);

    const state = cdc.stateOf(notice.payload(&bytes)).?;
    try std.testing.expect(state.dcd);
    try std.testing.expect(state.dsr);
    try std.testing.expect(!state.spoiled());

    // A notice claiming more than arrived carries only what arrived.
    const cut = [_]u8{ 0xA1, 0x20, 0, 0, 0, 0, 8, 0, 0x40 };
    const short = cdc.Notice.parse(&cut).?;
    try std.testing.expectEqual(@as(usize, 1), short.payload(&cut).len);
    try std.testing.expectEqual(@as(?serial.State, null), cdc.stateOf(short.payload(&cut)));

    // Anything that is not a device talking to the host is not a notice.
    var wrong = bytes;
    wrong[0] = 0x21;
    try std.testing.expectEqual(@as(?cdc.Notice, null), cdc.Notice.parse(&wrong));
    try std.testing.expectEqual(@as(?cdc.Notice, null), cdc.Notice.parse(bytes[0..4]));
}

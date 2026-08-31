//! Walking the kernel's PCI table, for services that adopt hardware.
//!
//! The kernel answers `sysinfo("pci")` with one line per device; every
//! driver service walks it looking for its silicon. The parse lives here
//! so the services share one reading of the format, and a column added to
//! the table is a change in one place.

const lib = @import("lib");
const str = lib.str;
const sys = @import("sys");

pub const Entry = struct {
    location: lib.pci.Location,
    vendor: u16,
    device: u16,
    class: u8,
    subclass: u8,
    /// Whether the kernel already drives it. A userspace driver leaves
    /// those alone: two drivers on one device is worse than the wrong one.
    driven: bool,
};

pub const Scan = struct {
    buf: [2048]u8 = @splat(0),
    lines: str.Splitter = .{ .text = "", .separator = '\n' },

    /// Ask the kernel once; iterate the answer with `next`.
    pub fn start(self: *Scan) bool {
        const n = sys.sysinfo("pci", self.buf[0..]);
        if (n <= 0) return false;
        self.lines = str.lines(self.buf[0..@intCast(n)]);
        return true;
    }

    pub fn next(self: *Scan) ?Entry {
        while (self.lines.next()) |line| {
            if (line.len == 0) continue;

            var fields = str.fields(line);
            const at = fields.next() orelse continue;
            const vendor = str.fromHex(fields.next() orelse continue);
            const device = str.fromHex(fields.next() orelse continue);
            const class = str.fromHex(fields.next() orelse continue);
            const subclass = str.fromHex(fields.next() orelse continue);
            _ = fields.next() orelse continue; // what the kernel bound
            const state = fields.next() orelse continue;

            return .{
                .location = lib.pci.parse(at) orelse continue,
                .vendor = @truncate(vendor),
                .device = @truncate(device),
                .class = @truncate(class),
                .subclass = @truncate(subclass),
                .driven = str.eql(str.trim(state), "driven"),
            };
        }
        return null;
    }
};

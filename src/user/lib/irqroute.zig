//! Which line a device's interrupt arrives on.
//!
//! The firmware's routing table is the answer for the interrupt model this
//! system runs; the number in configuration space answers for the mode it
//! does not. The platform service owns the tables and comes up in parallel
//! with the driver services, so the question is waited out rather than
//! raced. Every driver service asks this same question; asking it here
//! keeps the waiting policy and the fallback in one place.

const log = @import("log.zig");
const out = @import("out.zig");
const pci = @import("pci.zig");
const proto_platform = @import("proto").platform;
const sys = @import("sys");

/// Zero and all-ones in configuration space both mean the firmware wrote
/// no line there.
const UNROUTED: u8 = 0xFF;

/// The routed line for `location`, asked of the platform service, or the
/// legacy configuration-space line where the tables cannot say. Null when
/// nothing names a line at all. `tag` is the asking service's name, for
/// the narration.
pub fn routedLine(tag: []const u8, location: pci.Location) ?u32 {
    const pin = pci.interruptPin(location).acpiIndex() orelse {
        log.warn(tag, "the device exposes no routable interrupt pin");
        return null;
    };
    var ask = proto_platform.RouteAsk{
        .pin = pin,
        .device = @truncate(location.device),
    };
    if (pci.carrierOf(location.bus)) |carrier| {
        ask.behind_bridge = true;
        ask.bridge_device = @truncate(carrier.device);
        ask.bridge_function = @truncate(carrier.function);
    }

    // The platform service settles the firmware before publishing its
    // name; waiting for it here is what orders the first touch of the
    // device behind the firmware's own bring-up.
    var waited: u32 = 0;
    while (waited < 2_000_000) : (waited += 20_000) {
        if (proto_platform.routePci(ask)) |gsi| {
            log.begin(tag, .dim);
            out.text("the firmware routes this interrupt to line ");
            out.decimal(gsi);
            log.end();
            return gsi;
        } else |err| {
            if (err != error.NoService) break;
            sys.sleepMicros(20_000);
        }
    }

    const legacy = pci.interruptLine(location);
    log.begin(tag, .dim);
    out.text("no routing answer; config-space line ");
    out.decimal(legacy);
    log.end();
    return if (legacy == 0 or legacy == UNROUTED) null else legacy;
}

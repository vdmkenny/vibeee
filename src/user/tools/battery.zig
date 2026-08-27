//! battery: what the pack is doing, and what it has come to.
//!
//! Two questions, and the second is the one nothing else answers. How full it
//! is now is a number anybody can watch; how much it can still hold against
//! what it was built to hold is what says whether a netbook of this age has a
//! battery or an ornament, and it is inferred from the firmware's own record
//! of the last full charge.

const ink = @import("ulib").ink;
const out = @import("ulib").out;
const platform = @import("proto").platform;

pub fn run(_: []const []const u8) void {
    var reply = platform.Rep{};

    platform.call(.battery, &reply) catch |err| {
        out.text(switch (err) {
            error.NoService => "battery: the platform service is not answering\n",
            else => "battery: the firmware would not say\n",
        });
        out.flush();
        return;
    };

    const pack = reply.body.battery;
    if (!pack.isPresent()) {
        out.text("no battery\n");
        out.flush();
        return;
    }

    report(pack);
    out.flush();
}

fn report(pack: platform.Battery) void {
    const unit = if (pack.in_milliamps != 0) "mAh" else "mWh";

    field("charge");
    if (pack.charge()) |percent| {
        ink.use(roleFor(pack, percent));
        out.decimal(percent);
        out.byte('%');
        ink.plain();
        out.text("  ");
    }
    quantity(pack.remaining, unit);
    out.text(" of ");
    quantity(pack.last_full, unit);
    out.byte('\n');

    field("state");
    ink.write(stateRole(pack), stateWord(pack));
    if (pack.rate != 0 and pack.rate != platform.Battery.UNKNOWN) {
        out.text(" at ");
        quantity(pack.rate, if (pack.in_milliamps != 0) "mA" else "mW");
    }
    out.byte('\n');

    // The wear, which is the whole reason the static half is read.
    field("health");
    if (pack.health()) |percent| {
        ink.use(healthRole(percent));
        out.decimal(percent);
        out.byte('%');
        ink.plain();
        out.text("  holds ");
        quantity(pack.last_full, unit);
        out.text(" of the ");
        quantity(pack.design, unit);
        out.text(" it was built for");
    } else {
        out.text("the firmware does not say");
    }
    out.byte('\n');

    field("voltage");
    quantity(pack.voltage_mv, "mV");
    if (pack.design_voltage_mv != 0) {
        out.text(", designed for ");
        quantity(pack.design_voltage_mv, "mV");
    }
    out.byte('\n');

    if (pack.warning != 0 or pack.low != 0) {
        field("thresholds");
        out.text("warns at ");
        quantity(pack.warning, unit);
        out.text(", low at ");
        quantity(pack.low, unit);
        out.byte('\n');
    }
}

fn field(label: []const u8) void {
    out.byte(' ');

    var padded: [12]u8 = @splat(' ');
    @memcpy(padded[0..@min(label.len, padded.len)], label[0..@min(label.len, padded.len)]);
    ink.write(.key, &padded);
}

/// A number and its unit, or a plain word when the firmware said it does not
/// know: `0xFFFFFFFF` is that answer, and printing it as a number would be
/// reporting four billion of something.
fn quantity(value: u32, unit: []const u8) void {
    if (value == platform.Battery.UNKNOWN) {
        out.text("unknown");
        return;
    }
    out.decimal(value);
    out.byte(' ');
    out.text(unit);
}

fn stateWord(pack: platform.Battery) []const u8 {
    if (pack.critical != 0) return "critical";
    if (pack.charging != 0) return "charging";
    if (pack.discharging != 0) return "discharging";
    return "full";
}

fn stateRole(pack: platform.Battery) @import("lib").style.Role {
    if (pack.critical != 0) return .bad;
    if (pack.charging != 0) return .good;
    return .value;
}

/// Charge is only alarming when it is low and going down: a machine on mains
/// at ten per cent is filling up, not about to stop.
fn roleFor(pack: platform.Battery, percent: u32) @import("lib").style.Role {
    if (pack.charging != 0) return .good;
    if (percent <= 10) return .bad;
    if (percent <= 25) return .warn;
    return .value;
}

/// A pack that has lost a fifth of what it could hold is worth noticing, and
/// one that has lost half is the answer to why the machine does not last.
fn healthRole(percent: u32) @import("lib").style.Role {
    if (percent < 50) return .bad;
    if (percent < 80) return .warn;
    return .good;
}

//! What a driver can reach, and what everything else cannot.
//!
//! Exercises the two ways a program outside the kernel touches hardware: I/O
//! ports, granted through the CPU's permission bitmap so `in` and `out` run at
//! full speed, and a device's registers mapped into the address space.
//!
//! Run from a shell it reports being refused, which is the point: the session
//! tree holds no driver capability, so nothing started from it can reach
//! either. It works from a process the device manager started for the job.

const sys = @import("sys");
const out = @import("ulib").out;
const str = @import("ulib").str;

/// The POST diagnostic port. Writing to it has been a harmless way to waste a
/// microsecond since the PC/AT, and nothing here reads it for meaning.
const SAFE_PORT: u16 = 0x80;

pub fn driver(args: []const []const u8) void {
    const what = if (args.len > 0) args[0] else "port";

    if (str.eql(what, "map")) {
        mapAperture();
        return;
    }

    const granted = !str.eql(what, "raw");

    if (granted) {
        const result = sys.ioportGrant(SAFE_PORT, 1);
        if (result < 0) {
            out.text(if (result == -1)
                "driver: only a driver may be granted ports, and this is not one\n"
            else
                "driver: cannot grant\n");
            out.flush();
            return;
        }
        out.text("driver: 0x80 granted\n");
        out.flush();
    } else {
        out.text("driver: reading 0x80 without a grant, expect to be stopped\n");
        out.flush();
    }

    const value = inb(SAFE_PORT);

    out.text("driver: read 0x");
    out.hex(value, 2);
    out.text(" from 0x80\n");
    out.flush();
}

/// The local APIC's own page. Read only, and its version register says what it
/// is without disturbing anything: proof that an uncached aperture reached the
/// device rather than a stale cache line.
const LAPIC_PHYS: usize = 0xFEE0_0000;
const LAPIC_VERSION: usize = 0x30 / 4;

fn mapAperture() void {
    const regs = sys.mapDevice(LAPIC_PHYS, 0x1000) orelse {
        out.text("driver: only a driver may map a device, and this is not one\n");
        out.flush();
        return;
    };

    out.text("driver: mapped the local APIC, version register 0x");
    out.hex(regs[LAPIC_VERSION], 8);
    out.byte('\n');
    out.flush();
}

fn inb(p: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (p),
    );
}

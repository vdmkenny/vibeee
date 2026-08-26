//! Reading and writing an I/O port from userspace.
//!
//! What a driver server does constantly, and what nothing else may do at all.
//! With the port allowed, `in` runs at full speed with no syscall in the way;
//! without it, the same instruction faults and stops the program.
//!
//! Run from a shell it reports being refused, which is the point: the session
//! tree is granted no driver capability, so nothing started from it can reach
//! a port. It works from a process the device manager started for the job.

const sys = @import("sys");
const out = @import("ulib").out;
const str = @import("ulib").str;

/// The POST diagnostic port. Writing to it has been a harmless way to waste a
/// microsecond since the PC/AT, and nothing here reads it for meaning.
const SAFE_PORT: u16 = 0x80;

pub fn port(args: []const []const u8) void {
    const granted = args.len == 0 or !str.eql(args[0], "raw");

    if (granted) {
        const result = sys.ioportGrant(SAFE_PORT, 1);
        if (result < 0) {
            out.text(if (result == -1)
                "port: only a driver may be granted ports, and this is not one\n"
            else
                "port: cannot grant\n");
            out.flush();
            return;
        }
        out.text("port: 0x80 granted\n");
        out.flush();
    } else {
        out.text("port: reading 0x80 without a grant, expect to be stopped\n");
        out.flush();
    }

    const value = inb(SAFE_PORT);

    out.text("port: read 0x");
    out.hex(value, 2);
    out.text(" from 0x80\n");
    out.flush();
}

fn inb(p: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (p),
    );
}

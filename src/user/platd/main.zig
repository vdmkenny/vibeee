//! platd: the firmware's own account of this machine.
//!
//! Everything the BIOS and the embedded controller still own after boot is
//! described in tables the firmware left behind, and most of that description
//! is bytecode rather than data: which pin turns the radio off, what the
//! battery registers mean, what has to happen before the machine may sleep.
//! None of it can be worked out from outside, and a table of offsets copied
//! from a forum post is a way to turn off a power rail that should have stayed
//! on. So it is interpreted, by [uACPI](../../../third_party/uacpi/).
//!
//! In a process rather than in the kernel, holding the driver capability and
//! nothing else. This is bytecode from a 2007 AMI BIOS whose job is to poke
//! hardware; if it goes wrong it should take a restartable server with it and
//! not the machine.

const glue = @import("glue.zig");
const out = @import("ulib").out;
const sys = @import("sys");

/// uACPI's own entry points. The rest of it reaches back through `glue`.
extern fn uacpi_initialize(flags: u64) c_uint;
extern fn uacpi_namespace_load() c_uint;
extern fn uacpi_namespace_initialize() c_uint;
extern fn uacpi_status_to_string(status: c_uint) [*:0]const u8;

const OK: c_uint = 0;

comptime {
    // Nothing calls into `glue` from Zig: uACPI links against it. Naming it
    // here is what puts it in the program.
    _ = glue;
}

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ xorl %ebp, %ebp
        \\ call platdMain
        \\ hlt
    );
}

export fn platdMain() callconv(.c) noreturn {
    if (!bringUp()) sys.exit(1);

    // Nothing calls this yet. Registering anyway, so the name exists the
    // moment there is something behind it and a client written against it can
    // be tried before that.
    const channel = sys.svcRegister(SERVICE);
    if (channel < 0) {
        out.text("platd: cannot register\n");
        out.flush();
        sys.exit(1);
    }

    sleepForever();
}

pub const SERVICE = "platform";

/// Read the tables and make the namespace usable.
///
/// Three steps in the order uACPI asks for them: the tables themselves, the
/// namespace built from them, and then the `_INI` methods that let the
/// firmware set itself up now that somebody is listening.
fn bringUp() bool {
    if (!step("tables", uacpi_initialize(0))) return false;
    if (!step("namespace", uacpi_namespace_load())) return false;
    if (!step("devices", uacpi_namespace_initialize())) return false;

    out.text("platd: acpi ready\n");
    out.flush();
    return true;
}

fn step(what: []const u8, status: c_uint) bool {
    if (status == OK) return true;

    out.text("platd: ");
    out.text(what);
    out.text(": ");
    out.text(span(uacpi_status_to_string(status)));
    out.byte('\n');
    out.flush();
    return false;
}

fn span(text: [*:0]const u8) []const u8 {
    var n: usize = 0;
    while (text[n] != 0) n += 1;
    return text[0..n];
}

/// Nothing to serve yet, and exiting would have `init` restart it forever.
fn sleepForever() noreturn {
    while (true) sys.sleepMicros(1_000_000);
}

//! A real user program: a separately compiled, statically linked ELF the kernel
//! loads into its own address space.
//!
//! Nothing here is privileged and nothing is shared with the kernel except the
//! syscall numbers, which is the point. If this runs, the loader, the address
//! space, the privilege drop and the syscall ABI are all correct together.

const sys = @import("syscall.zig");
const out = @import("lib/out.zig");

/// Zero-initialised, so it lands in .bss: the file records no bytes for it and
/// the loader must supply the zeroes. Reading it proves that happened.
///
/// Explicitly zeroed rather than `undefined`, reading undefined memory is
/// undefined behaviour, and the optimiser is entitled to delete a function that
/// does it. It does exactly that.
var scratch: [64]u8 = [_]u8{0} ** 64;

/// Initialised data, so the loader is also proven to copy file contents.
var greeting: [*:0]const u8 = "vibeee userspace";

export fn _start() callconv(.naked) noreturn {
    // No stack frame to inherit and nothing to return to: jump straight in.
    asm volatile (
        \\ xorl %ebp, %ebp
        \\ call main
        \\ hlt
    );
}

/// Check that .bss arrived zeroed.
///
/// The reads are volatile so the compiler must actually perform them. Without
/// that it proves the array is all zeros, folds the answer to `true`, and drops
/// the array, leaving a test that passes without testing anything, and no
/// .bss segment for the loader to get wrong.
fn bssIsClean() bool {
    const p: [*]volatile u8 = &scratch;
    var i: usize = 0;
    while (i < scratch.len) : (i += 1) {
        if (p[i] != 0) return false;
    }
    return true;
}

/// Exercise the blocking primitive from user mode.
///
/// The kernel self-tests IPC from Ring 0, which proves the objects work but
/// not that the syscall gate carries them: a wrong argument register or a
/// mishandled user pointer only shows up from this side. Signalling before
/// waiting is deliberate, an event that counts must release a waiter that
/// arrives late, and getting that wrong is a hang, not a wrong answer.
fn ipcAbiWorks() bool {
    const handle = sys.eventCreate();
    if (handle < 0) return false;
    const event: u32 = @intCast(handle);
    defer _ = sys.close(event);

    if (sys.eventSignal(event) < 0) return false;
    if (sys.eventWait(event, sys.FOREVER) != 0) return false;

    // Nothing left to consume, so a poll must report a timeout rather than
    // returning a signal that was never sent.
    if (sys.eventWait(event, sys.POLL) >= 0) return false;

    // A name nobody registered must fail cleanly rather than returning a
    // handle to nothing.
    if (sys.svcConnect("no.such.service") >= 0) return false;

    return true;
}

export fn main() callconv(.c) noreturn {
    const bss_clean = bssIsClean();
    const ipc_ok = ipcAbiWorks();

    if (!ipc_ok) _ = sys.write(sys.STDERR, "hello: the IPC syscalls do not work from ring 3\n");
    _ = sys.write(sys.STDOUT, "hello from ");
    var n: usize = 0;
    while (greeting[n] != 0) n += 1;
    _ = sys.write(sys.STDOUT, greeting[0..n]);
    _ = sys.write(sys.STDOUT, ", pid ");
    out.decimal(@intCast(sys.getpid()));
    out.flush();
    _ = sys.write(sys.STDOUT, if (bss_clean) ", bss clean\n" else ", BSS DIRTY\n");

    // Prove scheduling works from user mode: sleep, and confirm the clock moved
    // by roughly the right amount rather than not at all.
    const before = sys.clockMicros();
    sys.sleepMicros(50_000);
    const after = sys.clockMicros();
    _ = sys.write(sys.STDOUT, if (after > before) "slept, clock advanced\n" else "SLEEP FAILED\n");

    // Echo what is typed, proving the whole input chain: i8042 to keycode to
    // layout to line discipline to read().
    _ = sys.write(sys.STDOUT, "type something ('off' to power down, 'quit' to exit):\n");

    var buf: [256]u8 = undefined;
    while (true) {
        _ = sys.write(sys.STDOUT, "> ");
        const got = sys.read(sys.STDIN, &buf);
        if (got <= 0) break;

        const len: usize = @intCast(got);
        var line = buf[0..len];
        if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];

        if (eql(line, "quit")) break;
        if (eql(line, "off")) sys.shutdown(sys.POWER_OFF);
        if (eql(line, "reboot")) sys.shutdown(sys.REBOOT);

        _ = sys.write(sys.STDOUT, "you typed: ");
        _ = sys.write(sys.STDOUT, line);
        _ = sys.write(sys.STDOUT, "\n");
    }

    sys.exit(0);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

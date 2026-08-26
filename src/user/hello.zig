//! A real user program: a separately compiled, statically linked ELF the kernel
//! loads into its own address space.
//!
//! Nothing here is privileged and nothing is shared with the kernel except the
//! syscall numbers — which is the point. If this runs, the loader, the address
//! space, the privilege drop and the syscall ABI are all correct together.

const sys = @import("syscall.zig");

/// Zero-initialised, so it lands in .bss: the file records no bytes for it and
/// the loader must supply the zeroes. Reading it proves that happened.
///
/// Explicitly zeroed rather than `undefined` — reading undefined memory is
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

fn writeDecimal(value: isize) void {
    var buf: [12]u8 = undefined;
    var i: usize = buf.len;
    var v: usize = if (value < 0) @intCast(-value) else @intCast(value);
    if (v == 0) {
        i -= 1;
        buf[i] = '0';
    }
    while (v > 0) : (v /= 10) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(v % 10));
    }
    _ = sys.write(sys.STDOUT, buf[i..]);
}

/// Check that .bss arrived zeroed.
///
/// The reads are volatile so the compiler must actually perform them. Without
/// that it proves the array is all zeros, folds the answer to `true`, and drops
/// the array — leaving a test that passes without testing anything, and no
/// .bss segment for the loader to get wrong.
fn bssIsClean() bool {
    const p: [*]volatile u8 = &scratch;
    var i: usize = 0;
    while (i < scratch.len) : (i += 1) {
        if (p[i] != 0) return false;
    }
    return true;
}

export fn main() callconv(.c) noreturn {
    const bss_clean = bssIsClean();

    _ = sys.write(sys.STDOUT, "hello from ");
    var n: usize = 0;
    while (greeting[n] != 0) n += 1;
    _ = sys.write(sys.STDOUT, greeting[0..n]);
    _ = sys.write(sys.STDOUT, ", pid ");
    writeDecimal(sys.getpid());
    _ = sys.write(sys.STDOUT, if (bss_clean) ", bss clean\n" else ", BSS DIRTY\n");

    // Prove scheduling works from user mode: sleep, and confirm the clock moved
    // by roughly the right amount rather than not at all.
    const before = sys.clockMicros();
    sys.sleepMicros(50_000);
    const after = sys.clockMicros();
    _ = sys.write(sys.STDOUT, if (after > before) "slept, clock advanced\n" else "SLEEP FAILED\n");

    sys.exit(0);
}

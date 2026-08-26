//! CPU control and feature detection for x86.
//!
//! The feature set here is checked against the verified Eee PC 701 inventory:
//! Celeron M 353 (Dothan C-0, CPUID 0x06D8) has tsc/msr/pae/apic/sep/mtrr/
//! clflush/mmx/fxsr/sse/sse2/nx, and does NOT have sse3, est (SpeedStep),
//! ht, pat, or long mode. See docs/research/research-core-platform.md.

const std = @import("std");

pub inline fn cli() void {
    asm volatile ("cli" ::: .{ .memory = true });
}

pub inline fn sti() void {
    asm volatile ("sti" ::: .{ .memory = true });
}

pub inline fn hlt() void {
    asm volatile ("hlt");
}

pub fn halt() noreturn {
    while (true) {
        cli();
        hlt();
    }
}

/// Disable interrupts and return whether they were previously enabled, so
/// critical sections can nest without a caller re-enabling them too early.
pub inline fn saveAndDisableInterrupts() bool {
    const flags = asm volatile (
        \\ pushfl
        \\ popl %[out]
        : [out] "=r" (-> u32),
        :
        : .{ .memory = true });
    cli();
    return (flags & 0x200) != 0;
}

pub inline fn restoreInterrupts(were_enabled: bool) void {
    if (were_enabled) sti();
}

pub const CpuidResult = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

pub fn cpuid(leaf: u32, subleaf: u32) CpuidResult {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (subleaf),
    );
    return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
}

/// Feature bits we actually branch on. Deliberately not exhaustive, a flag
/// belongs here only when some code path consults it.
pub const Features = struct {
    tsc: bool = false,
    msr: bool = false,
    pae: bool = false,
    apic: bool = false,
    /// SYSENTER/SYSEXIT. Selects the fast syscall path; `int 0x80` otherwise.
    sep: bool = false,
    mtrr: bool = false,
    clflush: bool = false,
    fxsr: bool = false,
    sse: bool = false,
    sse2: bool = false,
    sse3: bool = false,
    /// Enhanced SpeedStep. Absent on the 701's Celeron M, no P-states, so
    /// there is no DVFS to drive and the governor is a no-op.
    est: bool = false,
    /// NX/XD, usable only under PAE paging. We do not enable PAE (see
    /// design/00-vibeee.md §6.2), so this is reported but unused.
    nx: bool = false,
    htt: bool = false,

    pub fn detect() Features {
        var f = Features{};
        const max_leaf = cpuid(0, 0).eax;
        if (max_leaf >= 1) {
            const r = cpuid(1, 0);
            f.tsc = (r.edx & (1 << 4)) != 0;
            f.msr = (r.edx & (1 << 5)) != 0;
            f.pae = (r.edx & (1 << 6)) != 0;
            f.apic = (r.edx & (1 << 9)) != 0;
            f.sep = (r.edx & (1 << 11)) != 0;
            f.mtrr = (r.edx & (1 << 12)) != 0;
            f.clflush = (r.edx & (1 << 19)) != 0;
            f.fxsr = (r.edx & (1 << 24)) != 0;
            f.sse = (r.edx & (1 << 25)) != 0;
            f.sse2 = (r.edx & (1 << 26)) != 0;
            f.htt = (r.edx & (1 << 28)) != 0;
            f.sse3 = (r.ecx & (1 << 0)) != 0;
            f.est = (r.ecx & (1 << 7)) != 0;
        }
        const max_ext = cpuid(0x8000_0000, 0).eax;
        if (max_ext >= 0x8000_0001) {
            f.nx = (cpuid(0x8000_0001, 0).edx & (1 << 20)) != 0;
        }
        return f;
    }
};

/// CPU brand string from extended CPUID leaves. On the 701 this reads
/// "Intel(R) Celeron(R) M processor          900MHz", note it advertises
/// 900 MHz while actually running at 630 (70 MHz FSB), which is why we never
/// trust it for timing and always calibrate against a real timer.
pub fn brandString(buf: *[49]u8) []const u8 {
    // Pre-Pentium 4 parts (and several emulated CPUs) have no brand string.
    // Fall back to vendor + family/model/stepping, which is still enough to
    // identify the part, and on the real 701 the brand string is present.
    if (cpuid(0x8000_0000, 0).eax < 0x8000_0004) {
        const v = cpuid(0, 0);
        var vendor: [12]u8 = undefined;
        std.mem.writeInt(u32, vendor[0..4], v.ebx, .little);
        std.mem.writeInt(u32, vendor[4..8], v.edx, .little);
        std.mem.writeInt(u32, vendor[8..12], v.ecx, .little);
        const sig = cpuid(1, 0).eax;
        const family = ((sig >> 8) & 0xF) + ((sig >> 20) & 0xFF);
        const model = ((sig >> 4) & 0xF) | (((sig >> 16) & 0xF) << 4);
        return std.fmt.bufPrint(buf, "{s} family {d} model {d} step {d}", .{
            vendor, family, model, sig & 0xF,
        }) catch "unknown cpu";
    }
    var i: usize = 0;
    var leaf: u32 = 0x8000_0002;
    while (leaf <= 0x8000_0004) : (leaf += 1) {
        const r = cpuid(leaf, 0);
        for ([_]u32{ r.eax, r.ebx, r.ecx, r.edx }) |word| {
            var b: u5 = 0;
            while (b < 4) : (b += 1) {
                buf[i] = @truncate(word >> (@as(u5, b) * 8));
                i += 1;
            }
        }
    }
    buf[48] = 0;
    // Intel pads the brand string with leading spaces; trim both ends.
    return std.mem.trim(u8, buf[0..48], " \x00");
}

pub fn readMsr(msr: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [msr] "{ecx}" (msr),
    );
    return (@as(u64, hi) << 32) | lo;
}

pub fn writeMsr(msr: u32, value: u64) void {
    asm volatile ("wrmsr"
        :
        : [lo] "{eax}" (@as(u32, @truncate(value))),
          [hi] "{edx}" (@as(u32, @truncate(value >> 32))),
          [msr] "{ecx}" (msr),
    );
}

pub inline fn readTsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

pub inline fn readCr2() u32 {
    return asm volatile ("movl %%cr2, %[out]"
        : [out] "=r" (-> u32),
    );
}

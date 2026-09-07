//! CPU control and feature detection for x86.
//!
//! The feature set here is checked against the verified Eee PC 701 inventory:
//! Celeron M 353 (Dothan C-0, CPUID 0x06D8) has tsc/msr/pae/apic/sep/mtrr/
//! clflush/mmx/fxsr/sse/sse2/nx, and does NOT have sse3, est (SpeedStep),
//! ht, pat, or long mode. See docs/research/research-core-platform.md.

const std = @import("std");
const str = @import("lib").str;

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

/// A deliberate invalid opcode, for exercising the exception path on demand.
pub fn raiseInvalidOpcode() void {
    asm volatile ("ud2");
}

/// The operand `lgdt` and `lidt` take: how far the table reaches, one less
/// than its size, and where it starts. Six bytes with nothing between them,
/// which is what the alignment says.
pub const TableRegister = extern struct {
    limit: u16 align(1),
    base: u32 align(1),

    /// For a table in memory. Its size less one is what the CPU wants: the
    /// limit is the last byte's offset, not the count.
    pub fn of(table: anytype) TableRegister {
        return .{
            .limit = @sizeOf(@TypeOf(table.*)) - 1,
            .base = @intFromPtr(table),
        };
    }
};

/// Point the CPU at an interrupt descriptor table.
pub fn loadIdt(register: *const TableRegister) void {
    asm volatile ("lidt (%[d])"
        :
        : [d] "r" (register),
        : .{ .memory = true });
}

/// Reset by triple fault, the way that needs no chipset: an empty interrupt
/// table makes the next trap unrecoverable, which every x86 answers with a
/// reset.
pub fn resetByTripleFault() noreturn {
    const empty = TableRegister{ .limit = 0, .base = 0 };
    loadIdt(&empty);
    asm volatile ("int $3");
    halt();
}

/// Disable interrupts and return whether they were previously enabled, so
/// critical sections can nest without a caller re-enabling them too early.
/// The flags register, by the one bit read here.
const Eflags = packed struct(u32) {
    _0: u9,
    interrupt: bool,
    _10: u22,
};

pub inline fn saveAndDisableInterrupts() bool {
    const flags: Eflags = @bitCast(asm volatile (
        \\ pushfl
        \\ popl %[out]
        : [out] "=r" (-> u32),
        :
        : .{ .memory = true }));
    cli();
    return flags.interrupt;
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
            const edx: Leaf1Edx = @bitCast(r.edx);
            const ecx: Leaf1Ecx = @bitCast(r.ecx);
            f.tsc = edx.tsc;
            f.msr = edx.msr;
            f.pae = edx.pae;
            f.apic = edx.apic;
            f.sep = edx.sep;
            f.mtrr = edx.mtrr;
            f.clflush = edx.clflush;
            f.fxsr = edx.fxsr;
            f.sse = edx.sse;
            f.sse2 = edx.sse2;
            f.htt = edx.htt;
            f.sse3 = ecx.sse3;
            f.est = ecx.est;
        }
        const max_ext = cpuid(0x8000_0000, 0).eax;
        if (max_ext >= 0x8000_0001) {
            const ext: ExtendedLeaf1Edx = @bitCast(cpuid(0x8000_0001, 0).edx);
            f.nx = ext.nx;
        }
        return f;
    }
};

/// The feature words of the first leaf, bit by name. The names are the
/// manual's; the positions are its too, and a position typed once here is
/// a position never typed as a shift anywhere else.
const Leaf1Edx = packed struct(u32) {
    fpu: bool,
    vme: bool,
    de: bool,
    pse: bool,
    tsc: bool,
    msr: bool,
    pae: bool,
    mce: bool,
    cx8: bool,
    apic: bool,
    _10: u1,
    sep: bool,
    mtrr: bool,
    pge: bool,
    mca: bool,
    cmov: bool,
    pat: bool,
    pse36: bool,
    psn: bool,
    clflush: bool,
    _20: u1,
    ds: bool,
    acpi: bool,
    mmx: bool,
    fxsr: bool,
    sse: bool,
    sse2: bool,
    ss: bool,
    htt: bool,
    tm: bool,
    _30: u1,
    pbe: bool,
};

const Leaf1Ecx = packed struct(u32) {
    sse3: bool,
    _1: u6,
    est: bool,
    _8: u24,
};

const ExtendedLeaf1Edx = packed struct(u32) {
    _0: u20,
    nx: bool,
    _21: u11,
};

/// The processor signature the first leaf returns in EAX: the family and
/// model each in a base field and an extension, added and joined the way
/// the manual says.
const Signature = packed struct(u32) {
    stepping: u4,
    model: u4,
    family: u4,
    kind: u2,
    _14: u2,
    extended_model: u4,
    extended_family: u8,
    _28: u4,

    fn fullFamily(self: Signature) u32 {
        return @as(u32, self.family) + self.extended_family;
    }

    fn fullModel(self: Signature) u32 {
        return @as(u32, self.model) | (@as(u32, self.extended_model) << 4);
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
        const sig: Signature = @bitCast(cpuid(1, 0).eax);
        return std.fmt.bufPrint(buf, "{s} family {d} model {d} step {d}", .{
            vendor, sig.fullFamily(), sig.fullModel(), sig.stepping,
        }) catch "unknown cpu";
    }
    // The string comes four bytes a register, least significant first,
    // which is the order they sit in memory here.
    var i: usize = 0;
    var leaf: u32 = 0x8000_0002;
    while (leaf <= 0x8000_0004) : (leaf += 1) {
        const r = cpuid(leaf, 0);
        for ([_]u32{ r.eax, r.ebx, r.ecx, r.edx }) |word| {
            std.mem.writeInt(u32, buf[i..][0..4], word, .little);
            i += 4;
        }
    }
    buf[48] = 0;
    // The leaves are NUL-terminated, and Intel pads what is left at the ends
    // and again in a run before the clock speed, which on an 80-column console
    // is ten wasted columns in the middle of the name.
    const end = std.mem.indexOfScalar(u8, buf[0..49], 0) orelse 48;
    return str.collapseSpaces(buf[0..end]);
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

//! Write-combining for the framebuffer, through the MTRRs.
//!
//! The page tables map the framebuffer cacheable, but the memory type the
//! CPU actually uses is the page attribute combined with the range's MTRR,
//! and the firmware routinely leaves the video aperture at the uncacheable
//! default. Uncached, every store is its own bus transaction: a full blit is
//! a third of a million of them, and a person watches the screen fill from
//! the top. Write-combining lets the store buffers gather a cache line and
//! burst it, which is the difference between a repaint and a wipe.
//!
//! This Celeron has MTRRs and no PAT, so the MTRR is the only way to say it.
//! One core, so there is no synchronisation dance: interrupts off, caches
//! flushed and disabled around the change, exactly as the manual orders it.

const cpu = @import("cpu.zig");

const MTRRCAP = 0xFE;
const DEF_TYPE = 0x2FF;
const PHYS_BASE0 = 0x200;

/// The memory types a range register can name. Only one is wanted here.
const MemoryType = enum(u8) {
    uncacheable = 0x00,
    write_combining = 0x01,
    write_through = 0x04,
    write_protected = 0x05,
    write_back = 0x06,
    _,
};

/// IA32_MTRRCAP: what this CPU's range registers can do.
const Capability = packed struct(u64) {
    variable_count: u8,
    fixed_supported: bool,
    _reserved0: u1 = 0,
    write_combining: bool,
    _reserved1: u53 = 0,
};

/// IA32_MTRR_PHYSBASEn: where a range starts and what type it gets.
const Base = packed struct(u64) {
    type: MemoryType,
    _reserved0: u4 = 0,
    /// Bits 35:12 of the physical base, this family's 36 address bits.
    page: u24,
    _reserved1: u28 = 0,

    fn of(start: u64, memory_type: MemoryType) Base {
        return .{ .type = memory_type, .page = @truncate(start >> 12) };
    }

    fn address(self: Base) u64 {
        return @as(u64, self.page) << 12;
    }
};

/// IA32_MTRR_PHYSMASKn: how much of the base is compared, and whether the
/// pair means anything.
const Mask = packed struct(u64) {
    _reserved0: u11 = 0,
    valid: bool,
    /// Bits 35:12 of the mask: a physical address is in the range when
    /// `address & mask == base & mask`.
    page: u24,
    _reserved1: u28 = 0,

    fn covering(size: u64) Mask {
        return .{ .valid = true, .page = @truncate(~(size - 1) >> 12) };
    }

    fn masks(self: Mask, address: u64) u64 {
        return address & (@as(u64, self.page) << 12);
    }
};

/// IA32_MTRR_DEF_TYPE: the type everything not in a range gets, and the
/// switch for the whole mechanism.
const Default = packed struct(u64) {
    type: MemoryType,
    _reserved0: u2 = 0,
    fixed_enabled: bool,
    enabled: bool,
    _reserved1: u52 = 0,
};

fn readAs(comptime T: type, msr: u32) T {
    return @bitCast(cpu.readMsr(msr));
}

fn write(msr: u32, value: anytype) void {
    cpu.writeMsr(msr, @bitCast(value));
}

/// What came of asking. Worth distinguishing: "this CPU cannot" and "the
/// firmware already typed that range" call for different reactions from
/// whoever reads the boot log.
pub const Outcome = enum {
    taken,
    no_mtrr,
    no_write_combining,
    no_aligned_span,
    range_already_typed,
    no_free_register,

    pub fn label(self: Outcome) []const u8 {
        return switch (self) {
            .taken => "on",
            .no_mtrr => "no MTRRs on this CPU",
            .no_write_combining => "this CPU's MTRRs cannot",
            .no_aligned_span => "no aligned span fits the aperture",
            .range_already_typed => "the firmware already typed the range",
            .no_free_register => "no free range register",
        };
    }
};

/// Ask for `phys .. phys+len` to be write-combined.
///
/// An MTRR covers a power-of-two span aligned to its own size, so the span
/// covers the whole aperture the framebuffer sits in rather than the exact
/// pixels: a BAR is itself power-of-two sized and aligned, so rounding the
/// length up lands on the aperture and nothing else.
pub fn writeCombine(phys: usize, len: usize) Outcome {
    if (!cpu.Features.detect().mtrr) return .no_mtrr;
    if (len == 0) return .no_aligned_span;

    const cap = readAs(Capability, MTRRCAP);
    if (!cap.write_combining) return .no_write_combining;

    const span = spanFor(phys, len) orelse return .no_aligned_span;

    // A range the firmware already typed is left alone: overlapping MTRRs
    // combine in ways that are never what anyone wanted, and the firmware
    // may know something about this aperture that we do not.
    var free: ?u8 = null;
    for (0..cap.variable_count) |slot| {
        const mask = readAs(Mask, maskMsr(slot));
        if (!mask.valid) {
            if (free == null) free = @intCast(slot);
            continue;
        }
        const base = readAs(Base, baseMsr(slot));
        if (overlaps(base, mask, span)) return .range_already_typed;
    }
    const chosen = free orelse return .no_free_register;

    // The manual's sequence: nothing may be cached while the type changes.
    const flags = cpu.saveAndDisableInterrupts();
    defer cpu.restoreInterrupts(flags);

    disableCaches();
    var default = readAs(Default, DEF_TYPE);
    default.enabled = false;
    write(DEF_TYPE, default);

    write(baseMsr(chosen), Base.of(span.base, .write_combining));
    write(maskMsr(chosen), Mask.covering(span.size));

    default.enabled = true;
    write(DEF_TYPE, default);
    enableCaches();
    return .taken;
}

fn baseMsr(slot: usize) u32 {
    return PHYS_BASE0 + 2 * @as(u32, @intCast(slot));
}

fn maskMsr(slot: usize) u32 {
    return baseMsr(slot) + 1;
}

/// One programmed range, as `sysinfo` shows it. The whole point is reading
/// the map off a machine whose firmware did something surprising, so the
/// values come straight from the registers every time.
pub const Range = struct {
    base: u64,
    /// The span the mask implies. Zero when the mask is not a contiguous
    /// power of two, which the manual allows and nobody sane programs.
    size: u64,
    type: MemoryType,

    pub fn typeName(self: Range) []const u8 {
        return switch (self.type) {
            .uncacheable => "uncacheable",
            .write_combining => "write-combining",
            .write_through => "write-through",
            .write_protected => "write-protected",
            .write_back => "write-back",
            _ => "unknown",
        };
    }
};

/// How many variable ranges this CPU has, or zero without MTRRs.
pub fn rangeCount() usize {
    if (!cpu.Features.detect().mtrr) return 0;
    return readAs(Capability, MTRRCAP).variable_count;
}

/// The `slot`th programmed range, or null for one that is switched off.
pub fn rangeAt(slot: usize) ?Range {
    const mask = readAs(Mask, maskMsr(slot));
    if (!mask.valid) return null;
    const base = readAs(Base, baseMsr(slot));

    const masked = @as(u64, mask.page) << 12;
    const size = (~masked + 1) & 0xF_FFFF_FFFF;
    return .{ .base = base.address(), .size = size, .type = base.type };
}

const Span = struct { base: u64, size: u64 };

/// The aligned power-of-two span holding `phys .. phys+len`, or null when no
/// such span exists below 4 GiB that starts at an aligned base.
fn spanFor(phys: usize, len: usize) ?Span {
    var size: u64 = 4096;
    while (size < len) size *= 2;

    // Grow until the base aligns: an aperture's BAR base is aligned to the
    // BAR's own size, so this terminates at the aperture.
    while (size <= (1 << 31)) : (size *= 2) {
        const base = @as(u64, phys) & ~(size - 1);
        if (base + size >= @as(u64, phys) + len) return .{ .base = base, .size = size };
    }
    return null;
}

/// Whether an existing range and the wanted span touch: either base falls
/// inside the other's range under the coarser of the two masks.
fn overlaps(base: Base, mask: Mask, span: Span) bool {
    if (mask.masks(span.base) == mask.masks(base.address())) return true;
    const ours = Mask.covering(span.size);
    return ours.masks(base.address()) == ours.masks(span.base);
}

/// CR0.CD around a memory-type change, with the flushes the manual asks for.
fn disableCaches() void {
    asm volatile (
        \\ movl %%cr0, %%eax
        \\ orl $0x40000000, %%eax
        \\ movl %%eax, %%cr0
        \\ wbinvd
        ::: .{ .eax = true, .memory = true });
}

fn enableCaches() void {
    asm volatile (
        \\ wbinvd
        \\ movl %%cr0, %%eax
        \\ andl $0xBFFFFFFF, %%eax
        \\ movl %%eax, %%cr0
        ::: .{ .eax = true, .memory = true });
}

// ---------------------------------------------------------------------------
// Tests
//
// The MSR access and the cache dance need the machine; the arithmetic that
// decides what to write does not, and it is where a wrong bit would hide.
// ---------------------------------------------------------------------------

const testing = @import("std").testing;

test "a register round-trips its own address" {
    const base = Base.of(0xD000_0000, .write_combining);
    try testing.expectEqual(@as(u64, 0xD000_0000), base.address());
    try testing.expectEqual(MemoryType.write_combining, base.type);
    // The low twelve bits are the type and reserved space, never address.
    try testing.expectEqual(@as(u64, 0xD000_0000), Base.of(0xD000_0ABC, .write_combining).address());
}

test "a mask matches exactly the addresses inside its span" {
    const mask = Mask.covering(8 * 1024 * 1024);
    try testing.expect(mask.valid);
    const base: u64 = 0xD000_0000;
    try testing.expectEqual(mask.masks(base), mask.masks(base + 8 * 1024 * 1024 - 1));
    try testing.expect(mask.masks(base) != mask.masks(base + 8 * 1024 * 1024));
}

test "the span holding a framebuffer is aligned to its own size" {
    // The 701's aperture: base aligned, length not a power of two.
    const span = spanFor(0xD000_0000, 800 * 480 * 4) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0xD000_0000), span.base);
    try testing.expectEqual(@as(u64, 2 * 1024 * 1024), span.size);
    try testing.expect(span.base % span.size == 0);
    try testing.expect(span.base + span.size >= 0xD000_0000 + 800 * 480 * 4);

    // A base off alignment grows the span until it fits.
    const grown = spanFor(0xD010_0000, 4 * 1024 * 1024) orelse return error.TestUnexpectedResult;
    try testing.expect(grown.base % grown.size == 0);
    try testing.expect(grown.base <= 0xD010_0000);
    try testing.expect(grown.base + grown.size >= 0xD010_0000 + 4 * 1024 * 1024);
}

test "overlap is seen from either side" {
    const span = Span{ .base = 0xD000_0000, .size = 4 * 1024 * 1024 };

    // The firmware typed a large range containing ours.
    const wide = Base.of(0xC000_0000, .uncacheable);
    try testing.expect(overlaps(wide, Mask.covering(512 * 1024 * 1024), span));

    // And a small range inside ours.
    const narrow = Base.of(0xD010_0000, .uncacheable);
    try testing.expect(overlaps(narrow, Mask.covering(64 * 1024), span));

    // A range elsewhere is nobody's business.
    const apart = Base.of(0xF000_0000, .uncacheable);
    try testing.expect(!overlaps(apart, Mask.covering(64 * 1024 * 1024), span));
}

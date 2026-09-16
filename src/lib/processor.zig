//! The processors an image can be compiled for.
//!
//! One list for `build.zig`, which compiles for the choice, the image
//! configuration, which offers it, and the kernel, which checks at boot that
//! the running processor has every extension user programs were compiled to
//! use.

const std = @import("std");

const x86 = std.Target.x86;
const Features = std.Target.Cpu.Feature.Set;

pub const Processor = enum {
    pentium2,
    pentium3,
    pentium_m,
    atom,
    silvermont,
    goldmont,
    core2,
    nehalem,
    k8,
    k10,
    via_c3,
    via_c7,
    via_nano,

    /// What the menu calls it.
    pub fn prompt(self: Processor) []const u8 {
        return switch (self) {
            .pentium2 => "Pentium II, Celeron (Mendocino)",
            .pentium3 => "Pentium III, Celeron (Coppermine)",
            .pentium_m => "Celeron M, Pentium M (Eee PC 701)",
            .atom => "Atom N270 to N2800",
            .silvermont => "Bay Trail, Cherry Trail",
            .goldmont => "Apollo Lake",
            .core2 => "Core 2",
            .nehalem => "Sandy Bridge Celeron, Core i (Nehalem)",
            .k8 => "Athlon 64, Sempron (K8)",
            .k10 => "Sempron, V series, Athlon II (K10)",
            .via_c3 => "VIA C3 (Nehemiah), Eden",
            .via_c7 => "VIA C7, C7-M",
            .via_nano => "VIA Nano",
        };
    }

    pub fn help(self: Processor) []const u8 {
        return switch (self) {
            .pentium2 =>
            \\MMX, no SSE. Runs on every Intel and AMD processor listed here, with
            \\no SIMD in the blitters, decoders and mixer.
            ,
            .pentium3 =>
            \\SSE, no SSE2. Does not run on a Pentium II.
            ,
            .pentium_m =>
            \\SSE2, no SSE3. The Eee PC 701 (Celeron M 353) and 900. Does not run
            \\on a Pentium II or III.
            ,
            .atom =>
            \\SSE3, SSSE3 and MOVBE. Every netbook Atom: N270 and N280, N450 to
            \\N570, N2600 and N2800. Runs on Atom and later Atom only.
            ,
            .silvermont =>
            \\SSE4.2, POPCNT and PCLMUL. Celeron N2800 and N2900 series, Pentium
            \\N3500, Atom Z3700 and x5-Z8000. Needs the firmware's legacy boot
            \\mode, which not every machine offers.
            ,
            .goldmont =>
            \\Adds AES-NI and SHA to Bay Trail's extensions. Celeron N3350 and
            \\N3450, Pentium N4200. Needs the firmware's legacy boot mode, which
            \\not every machine offers.
            ,
            .core2 =>
            \\SSE3 and SSSE3. Core 2 laptops, in 32-bit mode. Does not run on a
            \\Celeron M or older.
            ,
            .nehalem =>
            \\SSE4.2 and POPCNT, no AES-NI or AVX. Core i processors from
            \\Nehalem on, and the Sandy Bridge Celerons without AVX: the G440
            \\and the 787, the last single-core Intel desktop and mobile
            \\processors. The kernel runs on one core.
            ,
            .k8 =>
            \\SSE2 and 3DNow!. AMD K8 machines, in 32-bit mode. Does not run on
            \\Intel processors.
            ,
            .k10 =>
            \\SSE4a, POPCNT, LZCNT and 3DNow!. The Sempron 150 and the V105,
            \\the last single-core AMD desktop and mobile processors, and
            \\Athlon II and Phenom II machines. The kernel runs on one core.
            ,
            .via_c3 =>
            \\SSE, and no long NOPs, which the C3 lacks and Intel models emit.
            \\Runs on every processor listed here from the Pentium III on.
            ,
            .via_c7 =>
            \\SSE2 and SSE3, no long NOPs. The HP 2133 Mini-Note and the Everex
            \\CloudBook.
            ,
            .via_nano =>
            \\SSE3 and SSSE3, no long NOPs. The Samsung NC20.
            ,
        };
    }

    /// The compiler's model for this processor, and extensions it adds to
    /// the model: LLVM has no model for the VIA C7 or Nano.
    pub const Target = struct {
        model: *const std.Target.Cpu.Model,
        add: Features = .empty,
    };

    pub fn target(self: Processor) Target {
        return switch (self) {
            .pentium2 => .{ .model = &x86.cpu.pentium2 },
            .pentium3 => .{ .model = &x86.cpu.pentium3 },
            .pentium_m => .{ .model = &x86.cpu.pentium_m },
            .atom => .{ .model = &x86.cpu.bonnell },
            .silvermont => .{ .model = &x86.cpu.silvermont },
            .goldmont => .{ .model = &x86.cpu.goldmont },
            .core2 => .{ .model = &x86.cpu.core2 },
            .nehalem => .{ .model = &x86.cpu.nehalem },
            .k8 => .{ .model = &x86.cpu.k8 },
            .k10 => .{ .model = &x86.cpu.amdfam10 },
            .via_c3 => .{ .model = &x86.cpu.c3_2 },
            .via_c7 => .{ .model = &x86.cpu.c3_2, .add = x86.featureSet(&.{ .sse2, .sse3 }) },
            .via_nano => .{ .model = &x86.cpu.c3_2, .add = x86.featureSet(&.{ .sse2, .sse3, .ssse3, .cx16 }) },
        };
    }

    /// Every extension code compiled for this processor may use.
    pub fn extensions(self: Processor) Features {
        const chosen = self.target();
        var set = chosen.model.features;
        set.addFeatureSet(chosen.add);
        set.populateDependencies(&x86.all_features);
        return set;
    }

    /// QEMU's `-cpu` for the closest model it emulates.
    pub fn emulated(self: Processor) []const u8 {
        return switch (self) {
            .pentium2 => "pentium2",
            .pentium3, .via_c3 => "pentium3",
            // SSE2 and no SSE3, as on the 701, with PAE and NX as the Dothan
            // has them.
            .pentium_m => "pentium3,+sse2,+pae,+nx,-sse3",
            .atom => "n270",
            // QEMU has no Silvermont: an N270 with its extensions added.
            .silvermont => "n270,+sse4.1,+sse4.2,+popcnt,+pclmulqdq",
            .goldmont => "Denverton",
            .core2, .via_nano => "core2duo",
            .nehalem => "Nehalem",
            .k8 => "Opteron_G1",
            .k10 => "phenom",
            .via_c7 => "pentium3,+sse2,+sse3",
        };
    }
};

const testing = std.testing;

test "a processor's extensions include what the ones it names imply" {
    const has = x86.featureSetHas;
    try testing.expect(has(Processor.pentium_m.extensions(), .sse));
    try testing.expect(has(Processor.pentium_m.extensions(), .sse2));
    try testing.expect(!has(Processor.pentium_m.extensions(), .sse3));

    try testing.expect(has(Processor.silvermont.extensions(), .ssse3));
    try testing.expect(has(Processor.k8.extensions(), .@"3dnow"));

    const c7 = Processor.via_c7.extensions();
    try testing.expect(has(c7, .sse3));
    try testing.expect(has(c7, .sse2));
    try testing.expect(!has(c7, .nopl));
}

test "every Intel and AMD model from the Pentium II on emits long NOPs, and no VIA one does" {
    for (std.enums.values(Processor)) |one| {
        const via = switch (one) {
            .via_c3, .via_c7, .via_nano => true,
            else => false,
        };
        try testing.expectEqual(!via, x86.featureSetHas(one.extensions(), .nopl));
    }
}

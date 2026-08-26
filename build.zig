//! vibeee build.
//!
//! The Makefile drives the image pipeline (partitioning, FAT population, dd);
//! this file builds the binaries. Keeping the split that way means `zig build`
//! alone gives you a kernel to run under `qemu -kernel`, and `make` gives you a
//! bootable SD image — see design/00-vibeee.md §14.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseSmall — footprint is a hard requirement)",
    ) orelse .ReleaseSmall;

    // ---------------------------------------------------------------------
    // Target: 32-bit x86, freestanding.
    //
    // The CPU baseline is deliberately explicit rather than `.baseline`. The
    // Eee PC 701's Celeron M 353 is a Dothan: it has SSE2 but NOT SSE3, so
    // pinning the model here makes the compiler reject anything the real
    // machine cannot execute, instead of us finding out via #UD on hardware.
    // ---------------------------------------------------------------------
    // Kernel code must not touch the FPU or SIMD registers implicitly: we do
    // not save that state on interrupt entry, and lazy FPU handling arrives
    // with the scheduler. So SSE/MMX/x87 are subtracted and soft_float is
    // added, which makes the compiler refuse to emit them rather than
    // corrupting user FPU state at some unlucky moment. Userspace modules
    // (blitters, the mixer) get their own target with SSE2 enabled.
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.pentium_m },
        .cpu_features_add = std.Target.x86.featureSet(&.{.soft_float}),
        .cpu_features_sub = std.Target.x86.featureSet(&.{ .x87, .mmx, .sse, .sse2 }),
    });

    // ---------------------------------------------------------------------
    // Userspace programs.
    //
    // Built as ordinary freestanding executables and embedded in the kernel
    // image, so the ELF loader is exercised by a real linker's output rather
    // than by something hand-assembled to be easy to load.
    //
    // A separate target from the kernel's: user code may use SSE2, since the
    // kernel saves FPU state on its behalf.
    // ---------------------------------------------------------------------
    const user_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.pentium_m },
    });

    const tools = b.addExecutable(.{
        .name = "tools",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user/tools.zig"),
            .target = user_target,
            .optimize = optimize,
            .single_threaded = true,
            .strip = true,
            .stack_check = false,
            .stack_protector = false,
        }),
    });
    tools.setLinkerScript(b.path("src/user/linker.ld"));
    tools.entry = .{ .symbol_name = "_start" };
    b.installArtifact(tools);

    const hello = b.addExecutable(.{
        .name = "hello",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user/hello.zig"),
            .target = user_target,
            .optimize = optimize,
            .single_threaded = true,
            .strip = true,
            .stack_check = false,
            .stack_protector = false,
        }),
    });
    hello.setLinkerScript(b.path("src/user/linker.ld"));
    hello.entry = .{ .symbol_name = "_start" };
    b.installArtifact(hello);

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/start.zig"),
        .target = target,
        .optimize = optimize,
        // No red zone: interrupt handlers run on the same stack and would
        // otherwise clobber it.
        .red_zone = false,
        // Frame pointers are what make panic.zig's backtrace work, and on a
        // machine with no serial port that backtrace is often the only
        // diagnostic available. Worth the register.
        .omit_frame_pointer = false,
        .single_threaded = true,
        .strip = false,
        .stack_check = false,
        .stack_protector = false,
    });

    const kernel = b.addExecutable(.{
        .name = "vibeee.elf",
        .root_module = kernel_mod,
    });
    // Embed the user programs so the kernel can load one without a filesystem.
    // This is temporary scaffolding: once eeefs and the boot rootfs exist, init
    // reads them from disk like anything else.
    kernel_mod.addAnonymousImport("user_hello", .{
        .root_source_file = hello.getEmittedBin(),
    });

    kernel.setLinkerScript(b.path("src/arch/x86/linker.ld"));
    // Sections must not be reordered or GC'd: the linker script places the
    // Multiboot2 header first by name.
    kernel.link_gc_sections = false;
    kernel.entry = .{ .symbol_name = "_start" };

    b.installArtifact(kernel);

    // ---------------------------------------------------------------------
    // Layering check. The portability rules in design/00-vibeee.md §3 are only
    // worth stating if they are enforced, so this runs on every build: a
    // kernel/ file that reaches into arch/ fails the build rather than quietly
    // making the eventual port harder.
    // ---------------------------------------------------------------------
    const layering = b.addRunArtifact(b.addExecutable(.{
        .name = "check-layering",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check-layering.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    }));
    layering.has_side_effects = true;
    kernel.step.dependOn(&layering.step);

    b.step("check", "Verify the module layering rules").dependOn(&layering.step);

    // ---------------------------------------------------------------------
    // Syscall reference, generated from the same table the dispatcher is built
    // from, so the two cannot disagree.
    // ---------------------------------------------------------------------
    const syscall_docs = b.addRunArtifact(b.addExecutable(.{
        .name = "gen-syscall-docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_syscall_docs.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    }));
    syscall_docs.addArg("docs/syscalls.md");
    syscall_docs.has_side_effects = true;
    b.step("syscall-docs", "Regenerate docs/syscalls.md from the syscall table")
        .dependOn(&syscall_docs.step);

    // ---------------------------------------------------------------------
    // Console fonts, converted from BDF at build time so the .bdf stays the
    // source of truth and the generated tables are never hand-edited.
    // ---------------------------------------------------------------------
    const mkfont = b.addExecutable(.{
        .name = "mkfont",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mkfont.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });

    const fonts_step = b.step("fonts", "Regenerate src/fonts/ from third_party BDF files");
    for ([_][3][]const u8{
        .{ "third_party/spleen/spleen-8x16.bdf", "src/fonts/spleen_8x16.zig", "Spleen 8x16" },
        .{ "third_party/spleen/spleen-12x24.bdf", "src/fonts/spleen_12x24.zig", "Spleen 12x24" },
    }) |spec| {
        const run = b.addRunArtifact(mkfont);
        run.addFileArg(b.path(spec[0]));
        run.addArg(spec[1]);
        run.addArg(spec[2]);
        run.has_side_effects = true;
        fonts_step.dependOn(&run.step);
    }

    // ---------------------------------------------------------------------
    // `zig build run` — quick QEMU boot without building an SD image.
    // ---------------------------------------------------------------------
    const run = b.addSystemCommand(&.{
        "qemu-system-i386",
        "-machine",       "pc",
        "-cpu",           "pentium2",
        "-m",             "512M",
        "-kernel",        "zig-out/bin/vibeee.elf",
        "-display",       "none",
        "-serial",        "stdio",
        "-no-reboot",
    });
    run.step.dependOn(b.getInstallStep());
    b.step("run", "Boot the kernel in QEMU via -kernel").dependOn(&run.step);

    // ---------------------------------------------------------------------
    // Host-side unit tests. These run natively, so anything portable
    // (allocators, keymap tables, filesystem structures, layout algebra) is
    // testable without hardware or emulation — see design §10.6.
    // ---------------------------------------------------------------------
    const test_step = b.step("test", "Run host-side unit tests");
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

//! vibeee build.
//!
//! The Makefile drives the image pipeline (partitioning, FAT population, dd);
//! this file builds the binaries. Keeping the split that way means `zig build`
//! alone gives you a kernel to run under `qemu -kernel`, and `make` gives you a
//! bootable SD image, see design/00-vibeee.md §14.

const std = @import("std");

/// True when `name` appears in a comma-separated list.
fn named(list: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, std.mem.trim(u8, entry, " "), name)) return true;
    }
    return false;
}

pub fn build(b: *std.Build) void {
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Optimization mode (default: ReleaseSmall, footprint is a hard requirement)",
    ) orelse .ReleaseSmall;

    // User programs to build with a symbol table, comma separated. A faulting
    // address reported on the target is only a number until something can match
    // it against a symbol, and the machine has no debugger and no serial port.
    // Naming one program rather than all of them keeps the root filesystem
    // inside its budget.
    const symbols = b.option(
        []const u8,
        "symbols",
        "User programs to build unstripped, comma separated",
    ) orelse "";

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

    // Shared, platform-neutral code, see src/lib. Handed to the kernel and to
    // every user program as the same named module rather than by relative
    // path, so both sides get one instance of it and its types compare equal
    // across the syscall boundary.
    const user_lib = b.createModule(.{
        .root_source_file = b.path("src/lib/lib.zig"),
        .target = user_target,
        .optimize = optimize,
    });

    // Userspace is three modules, each its own domain, wired here so a
    // program in a subdirectory can reach them: relative imports cannot climb
    // out of a module's own root directory.
    //
    //   sys   the syscall layer
    //   ulib  conveniences that assume a process (output, strings, time)
    //   eui   the control library, which touches no syscalls at all
    // The keyboard layouts. Userspace needs the names of them, for a setting
    // and the control that edits it; the kernel needs the tables. Both compile
    // the same list, so a name chosen in a settings file is one the kernel
    // knows.
    const keymaps_mod = b.createModule(.{
        .root_source_file = b.path("src/keymaps/registry.zig"),
        .target = user_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lib", .module = user_lib }},
    });

    const sys_mod = b.createModule(.{
        .root_source_file = b.path("src/user/syscall.zig"),
        .target = user_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lib", .module = user_lib },
            .{ .name = "keymaps", .module = keymaps_mod },
        },
    });

    const ulib_mod = b.createModule(.{
        .root_source_file = b.path("src/user/lib/ulib.zig"),
        .target = user_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lib", .module = user_lib },
            .{ .name = "sys", .module = sys_mod },
        },
    });

    const eui_mod = b.createModule(.{
        .root_source_file = b.path("src/user/eui/eui.zig"),
        .target = user_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lib", .module = user_lib }},
    });

    // The window protocol: wire types only, so client and server compile the
    // same definitions and neither can drift.
    const proto_mod = b.createModule(.{
        .root_source_file = b.path("src/user/proto/proto.zig"),
        .target = user_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "lib", .module = user_lib },
            .{ .name = "sys", .module = sys_mod },
            .{ .name = "eui", .module = eui_mod },
            .{ .name = "keymaps", .module = keymaps_mod },
            .{ .name = "ulib", .module = ulib_mod },
        },
    });

    // eeelibc: a static archive, because the alternative is a dynamic loader
    // and on a machine with ten programs that costs more in complexity and
    // per-spawn milliseconds than the duplication costs in RAM.
    const libc = b.addLibrary(.{
        .name = "eeelibc",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user/libc/libc.zig"),
            .target = user_target,
            .optimize = optimize,
            .single_threaded = true,
            .stack_check = false,
            .stack_protector = false,
            .imports = &.{
                .{ .name = "lib", .module = user_lib },
                .{ .name = "sys", .module = sys_mod },
                .{ .name = "ulib", .module = ulib_mod },
            },
        }),
    });
    // A C program links this and nothing else, so the archive has to carry the
    // routines the compiler emits calls to: 64-bit division on a 32-bit target
    // is a call to compiler-rt, not an instruction.
    libc.bundle_compiler_rt = true;
    b.installArtifact(libc);

    const user_imports = [_]std.Build.Module.Import{
        .{ .name = "lib", .module = user_lib },
        .{ .name = "sys", .module = sys_mod },
        .{ .name = "ulib", .module = ulib_mod },
        .{ .name = "eui", .module = eui_mod },
        .{ .name = "keymaps", .module = keymaps_mod },
        .{ .name = "proto", .module = proto_mod },
    };

    // Every user program is built identically; only its root file differs.
    // Listing them keeps adding one to a single line here.
    const USER_PROGRAMS = [_]struct { name: []const u8, root: []const u8 }{
        .{ .name = "init", .root = "src/user/init.zig" },
        .{ .name = "devmgd", .root = "src/user/devmgd/main.zig" },
        .{ .name = "cfgd", .root = "src/user/cfgd/main.zig" },
        .{ .name = "eeewm", .root = "src/user/eeewm/main.zig" },
        .{ .name = "tools", .root = "src/user/tools.zig" },
        .{ .name = "vsh", .root = "src/user/vsh.zig" },
        .{ .name = "settings", .root = "src/user/apps/settings.zig" },
        .{ .name = "monitor", .root = "src/user/apps/monitor.zig" },
        .{ .name = "eterm", .root = "src/user/eterm/main.zig" },
        .{ .name = "pad", .root = "src/user/apps/pad.zig" },
    };

    var user_bins: [USER_PROGRAMS.len]*std.Build.Step.Compile = undefined;

    inline for (USER_PROGRAMS, 0..) |program, i| {
        const exe = b.addExecutable(.{
            .name = program.name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(program.root),
                .target = user_target,
                .optimize = optimize,
                .single_threaded = true,
                .strip = !named(symbols, program.name),
                .stack_check = false,
                .stack_protector = false,
                .imports = &user_imports,
            }),
        });
        exe.setLinkerScript(b.path("src/user/linker.ld"));
        exe.entry = .{ .symbol_name = "_start" };
        b.installArtifact(exe);
        user_bins[i] = exe;
    }

    const kernel_lib = b.createModule(.{
        .root_source_file = b.path("src/lib/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("src/start.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lib", .module = kernel_lib }},
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

    // An import nothing uses is a dependency claimed and not made. Same
    // reasoning as the layering check, and the same enforcement: every build.
    const imports = b.addRunArtifact(b.addExecutable(.{
        .name = "check-imports",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check-imports.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    }));
    imports.has_side_effects = true;
    kernel.step.dependOn(&imports.step);

    const check = b.step("check", "Verify the module layering and import rules");
    check.dependOn(&layering.step);
    check.dependOn(&imports.step);

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

    const fonts_step = b.step("fonts", "Regenerate src/lib/fonts/ from third_party BDF files");

    const FontSpec = struct {
        source: []const u8,
        out: []const u8,
        name: []const u8,
    };

    for ([_]FontSpec{
        .{
            .source = "third_party/spleen/spleen-8x16.bdf",
            .out = "src/lib/fonts/spleen_8x16.zig",
            .name = "Spleen 8x16",
        },
        .{
            .source = "third_party/spleen/spleen-12x24.bdf",
            .out = "src/lib/fonts/spleen_12x24.zig",
            .name = "Spleen 12x24",
        },
        // Proportional, for interface text. A terminal wants a fixed grid; a
        // button label does not, and monospaced UI text is the loudest sign of
        // an interface drawn by a program that only had a console font.
        .{
            .source = "third_party/ark-pixel/ark-pixel-12px-proportional-latin.bdf",
            .out = "src/lib/fonts/ark_ui_12.zig",
            .name = "Ark Pixel 12",
        },
    }) |spec| {
        const run = b.addRunArtifact(mkfont);
        run.addFileArg(b.path(spec.source));
        run.addArg(spec.out);
        run.addArg(spec.name);
        run.has_side_effects = true;
        fonts_step.dependOn(&run.step);
    }

    // ---------------------------------------------------------------------
    // `zig build run`, quick QEMU boot without building an SD image.
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
    // testable without hardware or emulation, see design §10.6.
    // ---------------------------------------------------------------------
    const test_step = b.step("test", "Run host-side unit tests");
    const host_lib = b.createModule(.{
        .root_source_file = b.path("src/lib/lib.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{ .name = "lib", .module = host_lib }},
        }),
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);

    // `lib` is its own module, and `zig test` only collects tests from the
    // root module of the binary it builds, so tests inside it need their own
    // runner or they are silently skipped, which is worse than having none.
    const lib_tests = b.addTest(.{ .root_module = host_lib });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
}

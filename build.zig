//! vibeee build.
//!
//! The Makefile drives the image pipeline (partitioning, FAT population, dd);
//! this file builds the binaries. Keeping the split that way means `zig build`
//! alone gives you a kernel to run under `qemu -kernel`, and `make` gives you a
//! bootable SD image, see design/00-vibeee.md §14.

const std = @import("std");

/// Hand every manual page to the index generator as a tracked input.
fn addManualPages(b: *std.Build, run: *std.Build.Step.Run) void {
    const io = b.graph.io;
    var dir = b.build_root.handle.openDir(io, "manual", .{ .iterate = true }) catch {
        std.log.err("no manual directory: every command's summary lives there", .{});
        std.process.exit(1);
    };
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        run.addFileArg(b.path(b.fmt("manual/{s}", .{entry.name})));
    }
}

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

    // Which architecture to build. x86 is the flagship and the default; arm
    // selects the ARM926EJ-S HAL of design/12-arm-port.md, the second-arch
    // proof aimed at the VT8500-class Windows CE netbooks. Everything below
    // picks a side once, so no other code re-checks the architecture.
    const arch = b.option(
        []const u8,
        "arch",
        "Target architecture: x86 (default) or arm",
    ) orelse "x86";
    const is_arm = std.mem.eql(u8, arch, "arm");
    if (!is_arm and !std.mem.eql(u8, arch, "x86")) {
        std.log.err("unknown -Darch '{s}': supported values are x86 and arm", .{arch});
        std.process.exit(1);
    }

    // Whether this build carries the manual. With it, every command's
    // summary comes from its page and a command without one fails the
    // build; without it, the pages are neither read nor shipped and the
    // listings print names alone. Twenty kilobytes of text in a root
    // filesystem read over the BIOS's own USB path is worth being able
    // to decline.
    const with_manual = b.option(
        bool,
        "manual",
        "Read command summaries from manual/ and require a page per command (default: true)",
    ) orelse true;

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
    // Target, one per architecture.
    //
    // x86: 32-bit, freestanding, the CPU baseline deliberately explicit rather
    // than `.baseline`. The Eee PC 701's Celeron M 353 is a Dothan: it has
    // SSE2 but NOT SSE3, so pinning the model here makes the compiler reject
    // anything the real machine cannot execute, instead of us finding out via
    // #UD on hardware.
    //
    // Kernel code must not touch the FPU or SIMD registers implicitly: we do
    // not save that state on interrupt entry, and lazy FPU handling arrives
    // with the scheduler. So SSE/MMX/x87 are subtracted and soft_float is
    // added, which makes the compiler refuse to emit them rather than
    // corrupting user FPU state at some unlucky moment. Userspace modules
    // (blitters, the mixer) get their own target with SSE2 enabled.
    //
    // arm: ARM926EJ-S, the core of the VT8500/WM8505 Windows CE netbooks, and
    // the CPU QEMU's versatilepb presents by default. Same reasoning as x86:
    // pinned, so the compiler rejects what the device cannot run. No VFP on
    // this core, so the EABI soft-float convention is the only one available
    // and the compiler emits software float calls.
    // ---------------------------------------------------------------------
    const target = if (is_arm)
        b.resolveTargetQuery(.{
            .cpu_arch = .arm,
            .os_tag = .freestanding,
            .abi = .eabi,
            .cpu_model = .{ .explicit = &std.Target.arm.cpu.arm926ej_s },
        })
    else
        b.resolveTargetQuery(.{
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
    // On x86 a separate target from the kernel's: user code may use SSE2,
    // since the kernel saves FPU state on its behalf. On arm there is no FPU
    // to save, so both halves share the same model.
    // ---------------------------------------------------------------------
    const user_target = if (is_arm)
        target
    else
        b.resolveTargetQuery(.{
            .cpu_arch = .x86,
            .os_tag = .freestanding,
            .abi = .none,
            .cpu_model = .{ .explicit = &std.Target.x86.cpu.pentium_m },
        });

    // ---------------------------------------------------------------------
    // Userspace programs: x86 only for now. The arm skeleton
    // (design/12-arm-port.md §4) is kernel-first; the user-side arch stub
    // arrives in step 4.5, and until then building the programs would fail
    // on the x86 trap stub. The gate is this region and disappears then.
    // ---------------------------------------------------------------------
    if (!is_arm) {
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
        // The socket client in ulib speaks the net protocol; the proto module's
        // own conveniences already lean on ulib, and the cycle is fine because
        // modules are names, not link units.
        ulib_mod.addImport("proto", proto_mod);

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

        // The manual is the source of every command's one-line summary.
        // A generator reads the pages' title lines into a comptime table,
        // so `tools` and `help` print what the manual says and a command
        // with no page fails the build rather than shipping unlookupable.
        const manual_index = b.addRunArtifact(b.addExecutable(.{
            .name = "gen-manual-index",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/gen-manual-index.zig"),
                .target = b.graph.host,
                .optimize = .ReleaseSafe,
            }),
        }));
        const manual_table = manual_index.addOutputFileArg("manual.zig");
        // Each page named as its own input, so the build hashes their
        // contents and re-reads the manual exactly when one changes,
        // arrives or leaves. A directory argument would hash only its
        // name, and a page removed behind the build's back would ship as
        // a summary for a command nobody can look up.
        if (with_manual) addManualPages(b, manual_index);
        const manual_mod = b.createModule(.{
            .root_source_file = manual_table,
            .target = user_target,
            .optimize = optimize,
        });

        const user_imports = [_]std.Build.Module.Import{
            .{ .name = "lib", .module = user_lib },
            .{ .name = "sys", .module = sys_mod },
            .{ .name = "ulib", .module = ulib_mod },
            .{ .name = "eui", .module = eui_mod },
            .{ .name = "keymaps", .module = keymaps_mod },
            .{ .name = "proto", .module = proto_mod },
            .{ .name = "manual", .module = manual_mod },
        };

        // Every user program is built identically; only its root file differs.
        // Listing them keeps adding one to a single line here.
        const USER_PROGRAMS = [_]struct { name: []const u8, root: []const u8 }{
            .{ .name = "init", .root = "src/user/init.zig" },
            .{ .name = "devmgd", .root = "src/user/devmgd/main.zig" },
            .{ .name = "netd", .root = "src/user/netd/main.zig" },
            .{ .name = "sndd", .root = "src/user/sndd/main.zig" },
            .{ .name = "usbd", .root = "src/user/usbd/main.zig" },
            .{ .name = "cfgd", .root = "src/user/cfgd/main.zig" },
            .{ .name = "platd", .root = "src/user/platd/main.zig" },
            .{ .name = "eeewm", .root = "src/user/eeewm/main.zig" },
            .{ .name = "tools", .root = "src/user/tools.zig" },
            .{ .name = "vsh", .root = "src/user/vsh.zig" },
            .{ .name = "settings", .root = "src/user/apps/settings.zig" },
            .{ .name = "monitor", .root = "src/user/apps/monitor.zig" },
            .{ .name = "eterm", .root = "src/user/eterm/main.zig" },
            .{ .name = "pad", .root = "src/user/apps/pad.zig" },
        };

        // platd carries uACPI, which is C. Compiled into the program rather than
        // linked as an archive: it is one program's dependency, not the system's,
        // and whole-program dead-code elimination gets to see all of it.
        //
        // `UACPI_PHYS_ADDR_IS_32BITS` because this machine is, and it saves
        // 64-bit arithmetic on every address the interpreter touches.
        const uacpi_sources = [_][]const u8{
            "third_party/uacpi/source/default_handlers.c",
            "third_party/uacpi/source/event.c",
            "third_party/uacpi/source/interpreter.c",
            "third_party/uacpi/source/io.c",
            "third_party/uacpi/source/mutex.c",
            "third_party/uacpi/source/namespace.c",
            "third_party/uacpi/source/notify.c",
            "third_party/uacpi/source/opcodes.c",
            "third_party/uacpi/source/opregion.c",
            "third_party/uacpi/source/osi.c",
            "third_party/uacpi/source/registers.c",
            "third_party/uacpi/source/resources.c",
            "third_party/uacpi/source/shareable.c",
            "third_party/uacpi/source/sleep.c",
            "third_party/uacpi/source/stdlib.c",
            "third_party/uacpi/source/tables.c",
            "third_party/uacpi/source/types.c",
            "third_party/uacpi/source/uacpi.c",
            "third_party/uacpi/source/utilities.c",
        };

        // netd carries lwIP, which is C, vendored verbatim like uACPI and
        // compiled into the one program that is its dependency. The port headers
        // live beside netd; the layout proof in lwipport/layout_check.c pins the
        // struct shapes netd's Zig mirror relies on.
        const lwip_sources = [_][]const u8{
            "third_party/lwip/src/core/def.c",
            "third_party/lwip/src/core/dns.c",
            "third_party/lwip/src/core/inet_chksum.c",
            "third_party/lwip/src/core/init.c",
            "third_party/lwip/src/core/ip.c",
            "third_party/lwip/src/core/mem.c",
            "third_party/lwip/src/core/memp.c",
            "third_party/lwip/src/core/netif.c",
            "third_party/lwip/src/core/pbuf.c",
            "third_party/lwip/src/core/raw.c",
            "third_party/lwip/src/core/stats.c",
            "third_party/lwip/src/core/sys.c",
            "third_party/lwip/src/core/tcp.c",
            "third_party/lwip/src/core/tcp_in.c",
            "third_party/lwip/src/core/tcp_out.c",
            "third_party/lwip/src/core/timeouts.c",
            "third_party/lwip/src/core/udp.c",
            "third_party/lwip/src/core/ipv4/dhcp.c",
            "third_party/lwip/src/core/ipv4/etharp.c",
            "third_party/lwip/src/core/ipv4/icmp.c",
            "third_party/lwip/src/core/ipv4/ip4.c",
            "third_party/lwip/src/core/ipv4/ip4_addr.c",
            "third_party/lwip/src/core/ipv4/ip4_frag.c",
            "third_party/lwip/src/netif/ethernet.c",
            "src/user/netd/lwipport/layout_check.c",
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
            if (comptime std.mem.eql(u8, program.name, "netd")) {
                exe.root_module.addIncludePath(b.path("third_party/lwip/src/include"));
                exe.root_module.addIncludePath(b.path("src/user/netd/lwipport"));
                exe.root_module.addIncludePath(b.path("include"));
                exe.root_module.addCSourceFiles(.{
                    .files = &lwip_sources,
                    .flags = &.{
                        "-std=c11",
                        "-ffreestanding",
                        "-fno-stack-protector",
                    },
                });
                // For the routines lwIP's C calls by name: the libc's C-callable
                // half, imported so its exports are emitted into this binary.
                // Not the archive, whose start code would collide with netd's.
                exe.root_module.addImport("clibc", b.createModule(.{
                    .root_source_file = b.path("src/user/libc/freestanding.zig"),
                    .target = user_target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "lib", .module = user_lib },
                        .{ .name = "sys", .module = sys_mod },
                        .{ .name = "ulib", .module = ulib_mod },
                    },
                }));
            }
            if (comptime std.mem.eql(u8, program.name, "platd")) {
                exe.root_module.addIncludePath(b.path("third_party/uacpi/include"));
                exe.root_module.addCSourceFiles(.{
                    .files = &(uacpi_sources ++ [_][]const u8{"src/user/platd/abi.c"}),
                    .flags = &.{
                        "-std=c11",
                        "-ffreestanding",
                        "-fno-stack-protector",
                        "-DUACPI_PHYS_ADDR_IS_32BITS",
                        "-DUACPI_SIZED_FREES=0",
                    },
                });
            }

            exe.setLinkerScript(b.path("src/user/linker.ld"));
            exe.entry = .{ .symbol_name = "_start" };
            b.installArtifact(exe);
            user_bins[i] = exe;
        }
    } // !is_arm

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
    // One script per architecture: the x86 layout places the Multiboot2 header
    // first by name, the arm layout puts the vector table and boot text where
    // QEMU's versatilepb expects them (design/12-arm-port.md §4.1).
    kernel.setLinkerScript(b.path(if (is_arm) "src/arch/arm/linker.ld" else "src/arch/x86/linker.ld"));
    if (!is_arm) {
        // Sections must not be reordered or GC'd: the linker script places the
        // Multiboot2 header first by name.
        kernel.link_gc_sections = false;
    }
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
    // The key numbers a C program needs, written from the enum that
    // defines them. Generated rather than mirrored: two lists agreeing
    // today is not two lists agreeing.
    const key_header = b.addRunArtifact(b.addExecutable(.{
        .name = "gen-key-header",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_key_header.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    }));
    key_header.addArg("build/include/vibeee-keys.h");
    key_header.has_side_effects = true;
    b.getInstallStep().dependOn(&key_header.step);

    // The settings reference, projected from the schema onto docs/settings.md
    // and onto every manual page that asks for a domain. The schema imports
    // nothing that talks to the kernel, which is what lets it be read here.
    const docs_lib = b.createModule(.{
        .root_source_file = b.path("src/lib/lib.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const host_keymaps = b.createModule(.{
        .root_source_file = b.path("src/keymaps/registry.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "lib", .module = docs_lib }},
    });
    const settings_docs = b.addRunArtifact(b.addExecutable(.{
        .name = "gen-settings-docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_settings_docs.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "lib", .module = docs_lib },
                .{ .name = "keymaps", .module = host_keymaps },
            },
        }),
    }));
    settings_docs.addArg("docs/settings.md");
    settings_docs.addArg("manual");
    settings_docs.has_side_effects = true;
    // On every build, like the layering check and for the same reason: a
    // reference that has to be remembered is one that goes stale. It
    // writes only what changed, so a build that alters nothing leaves the
    // tree alone.
    b.getInstallStep().dependOn(&settings_docs.step);
    b.step("settings-docs", "Regenerate docs/settings.md and the manual's key lists")
        .dependOn(&settings_docs.step);

    // The toolkit describes itself: controls, parts, pictures and themes are
    // all read out of eui rather than listed by hand.
    const host_eui = b.createModule(.{
        .root_source_file = b.path("src/user/eui/eui.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
        .imports = &.{.{ .name = "lib", .module = docs_lib }},
    });
    const eui_docs = b.addRunArtifact(b.addExecutable(.{
        .name = "gen-eui-docs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/gen_eui_docs.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
            .imports = &.{.{ .name = "eui", .module = host_eui }},
        }),
    }));
    eui_docs.addArg("docs/libeui.md");
    eui_docs.addArg("src/user/eui/widget.zig");
    eui_docs.has_side_effects = true;
    b.getInstallStep().dependOn(&eui_docs.step);
    b.step("eui-docs", "Regenerate docs/libeui.md from the toolkit")
        .dependOn(&eui_docs.step);

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
    const run = if (is_arm)
        b.addSystemCommand(&.{
            "qemu-system-arm",
            "-machine",
            "versatilepb",
            "-cpu",
            "arm926",
            "-m",
            "256M",
            "-kernel",
            "zig-out/bin/vibeee.elf",
            "-display",
            "none",
            "-serial",
            "stdio",
            "-no-reboot",
        })
    else
        b.addSystemCommand(&.{
            "qemu-system-i386",
            "-machine",
            "pc",
            "-cpu",
            "pentium2",
            "-m",
            "512M",
            "-kernel",
            "zig-out/bin/vibeee.elf",
            "-display",
            "none",
            "-serial",
            "stdio",
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

    // The quirk registry is pure data and pure functions, so its recognition
    // and correction rules are testable on the host, where a machine's whole
    // identity is a few strings.
    const quirks_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/quirks/tests.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });
    test_step.dependOn(&b.addRunArtifact(quirks_tests).step);
}

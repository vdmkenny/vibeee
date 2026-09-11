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
/// Which picture formats a program is built to read, or null for one that
/// reads none.
///
/// Every format costs the binary that carries it, so this is a list of what
/// each program actually opens rather than one decoder with everything in it:
/// a viewer opens photographs, and the desktop behind it opens a wallpaper.
fn imageFormats(name: []const u8) ?[]const []const u8 {
    // The file manager previews what is under the cursor, which is as much a
    // viewer as the viewer is.
    if (std.mem.eql(u8, name, "eimg") or std.mem.eql(u8, name, "efm")) {
        return &.{ "-DSTBI_ONLY_PNG", "-DSTBI_ONLY_JPEG", "-DSTBI_ONLY_BMP", "-DSTBI_ONLY_GIF" };
    }
    // `screenshot` writes a picture and opens none. One format is named
    // because naming none compiles every decoder in; nothing calls it, and
    // what nothing calls is collected out again.
    if (std.mem.eql(u8, name, "screenshot")) return &.{"-DSTBI_ONLY_PNG"};
    return null;
}

/// What every user program is built the same way from: the target, the
/// modules it imports, and the pieces a program that opens pictures or
/// calls C by name also needs.
///
/// A system program and an extra application differ in where they are
/// installed and whether they ship, and in nothing about how they are
/// built, which is why building one is written once.
const UserBuild = struct {
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    imports: []const std.Build.Module.Import,
    lib: *std.Build.Module,
    sys: *std.Build.Module,
    ulib: *std.Build.Module,

    /// A program: freestanding, single-threaded, its own linker script,
    /// entered at `_start`.
    fn exe(self: UserBuild, name: []const u8, root: []const u8, strip: bool) *std.Build.Step.Compile {
        const out = self.b.addExecutable(.{
            .name = name,
            .root_module = self.b.createModule(.{
                .root_source_file = self.b.path(root),
                .target = self.target,
                .optimize = self.optimize,
                .single_threaded = true,
                .strip = strip,
                .stack_check = false,
                .stack_protector = false,
                .imports = self.imports,
            }),
        });
        out.setLinkerScript(self.b.path("src/user/linker.ld"));
        out.entry = .{ .symbol_name = "_start" };
        return out;
    }

    /// The libc's C-callable half, imported so its exports are emitted into
    /// this binary. Not the archive, whose start code would collide with the
    /// program's own.
    fn addClibc(self: UserBuild, out: *std.Build.Step.Compile) void {
        out.root_module.addImport("clibc", self.b.createModule(.{
            .root_source_file = self.b.path("src/user/libc/freestanding.zig"),
            .target = self.target,
            .optimize = self.optimize,
            .imports = &.{
                .{ .name = "lib", .module = self.lib },
                .{ .name = "sys", .module = self.sys },
                .{ .name = "ulib", .module = self.ulib },
            },
        }));
    }

    /// The picture decoder, opening the formats named and no others: what
    /// is not named is not in the binary at all.
    fn addPictures(self: UserBuild, out: *std.Build.Step.Compile, formats: []const []const u8) void {
        out.root_module.addIncludePath(self.b.path("third_party/stb"));
        out.root_module.addIncludePath(self.b.path("include"));
        out.root_module.addCSourceFiles(.{
            .files = &.{"src/user/img/stb.c"},
            .flags = self.cFlags(formats),
        });
        self.addClibc(out);
    }

    /// The HTML parser, compiled into whatever needs one.
    ///
    /// The modules taken are the ones `html` and `dom` reference and no
    /// others: no CSS, no character-set tables, which between them are most
    /// of what upstream ships. A reader sets a page in its own two faces, so
    /// a cascade buys it nothing, and the tables it would need are a
    /// megabyte before the first page is fetched.
    ///
    /// Walked rather than written out, for the reason the Doom recipe reads
    /// its engine's own source list: a file added upstream should arrive
    /// with the next re-fetch, not wait for somebody here to notice it.
    fn addLexbor(self: UserBuild, out: *std.Build.Step.Compile) void {
        const io = self.b.graph.io;
        const root = "third_party/lexbor/source/lexbor";
        const modules = [_][]const u8{ "core", "dom", "html", "ns", "tag" };

        var files: [400][]const u8 = undefined;
        var count: usize = 0;

        for (modules) |module| {
            const rel = self.b.fmt("{s}/{s}", .{ root, module });
            var dir = self.b.build_root.handle.openDir(io, rel, .{ .iterate = true }) catch
                @panic("lexbor: a module named here is not vendored");
            defer dir.close(io);

            var walker = dir.walk(self.b.allocator) catch @panic("out of memory");
            while (walker.next(io) catch @panic("lexbor: the module would not walk")) |entry| {
                if (entry.kind != .file) continue;
                if (!std.mem.endsWith(u8, entry.basename, ".c")) continue;
                if (count == files.len) @panic("lexbor: more sources than there is room for");
                files[count] = self.b.fmt("{s}/{s}", .{ rel, entry.path });
                count += 1;
            }
        }

        // The platform layer, without the half that reads files: opening one
        // is this system's own business, and upstream's wants a stat field
        // this system does not define.
        for ([_][]const u8{ "memory", "perf" }) |part| {
            files[count] = self.b.fmt("{s}/ports/posix/lexbor/core/{s}.c", .{ root, part });
            count += 1;
        }

        // The layout proof, which pins the struct shapes the Zig mirror
        // relies on. No code, only assertions.
        files[count] = "apps/web/lexborport/layout_check.c";
        count += 1;

        out.root_module.addIncludePath(self.b.path("third_party/lexbor/source"));
        out.root_module.addIncludePath(self.b.path("include"));
        out.root_module.addCSourceFiles(.{
            .files = files[0..count],
            .flags = self.cFlags(&.{"-DLEXBOR_STATIC"}),
        });
        self.addClibc(out);
    }

    /// How C is compiled here, and whatever else this piece of it needs
    /// said. Freestanding, because there is no host underneath.
    fn cFlags(self: UserBuild, extra: []const []const u8) []const []const u8 {
        const base = [_][]const u8{ "-std=c11", "-ffreestanding", "-fno-stack-protector" };
        const flags = self.b.allocator.alloc([]const u8, base.len + extra.len) catch @panic("out of memory");
        @memcpy(flags[0..base.len], &base);
        @memcpy(flags[base.len..], extra);
        return flags;
    }
};

fn named(list: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, std.mem.trim(u8, entry, " "), name)) return true;
    }
    return false;
}

/// Make `step` actually build `compiled`.
///
/// Depending on a compile step alone leaves it with nothing to produce,
/// so it reports success without having read a line. Asking for the
/// binary is what makes it compile, and the binary itself is not wanted:
/// this is for checking that something builds for a machine that is not
/// this one, which cannot run what it produces anyway.
fn demand(step: *std.Build.Step, compiled: *std.Build.Step.Compile) void {
    _ = compiled.getEmittedBin();
    step.dependOn(&compiled.step);
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
        const framebuffer_mod = b.createModule(.{
            .root_source_file = b.path("src/user/framebuffer.zig"),
            .target = user_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "lib", .module = user_lib },
                .{ .name = "sys", .module = sys_mod },
                .{ .name = "ulib", .module = ulib_mod },
                .{ .name = "eui", .module = eui_mod },
                .{ .name = "proto", .module = proto_mod },
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
                    .{ .name = "framebuffer", .module = framebuffer_mod },
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

        // Pictures. The wrapper is Zig and the decoder is C, attached to
        // whichever program asks for it rather than to all of them: which
        // formats a binary knows is that binary's business, and a viewer
        // wants JPEG where the desktop behind it does not.
        const img_mod = b.createModule(.{
            .root_source_file = b.path("src/user/img/img.zig"),
            .target = user_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "lib", .module = user_lib }},
        });

        const user_imports = [_]std.Build.Module.Import{
            .{ .name = "lib", .module = user_lib },
            .{ .name = "img", .module = img_mod },
            .{ .name = "sys", .module = sys_mod },
            .{ .name = "ulib", .module = ulib_mod },
            .{ .name = "eui", .module = eui_mod },
            .{ .name = "keymaps", .module = keymaps_mod },
            .{ .name = "proto", .module = proto_mod },
            .{ .name = "framebuffer", .module = framebuffer_mod },
            .{ .name = "manual", .module = manual_mod },
        };

        const user = UserBuild{
            .b = b,
            .target = user_target,
            .optimize = optimize,
            .imports = &user_imports,
            .lib = user_lib,
            .sys = sys_mod,
            .ulib = ulib_mod,
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
            .{ .name = "calc", .root = "src/user/apps/calc.zig" },
            .{ .name = "eimg", .root = "src/user/apps/eimg.zig" },
            .{ .name = "efm", .root = "src/user/efm/main.zig" },
            .{ .name = "screenshot", .root = "src/user/apps/screenshot.zig" },
            .{ .name = "timed", .root = "src/user/timed/main.zig" },
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
            const exe = user.exe(program.name, program.root, !named(symbols, program.name));
            if (comptime std.mem.eql(u8, program.name, "netd")) {
                // lwIP's own asserts are a debugging aid, not a production
                // policy: this port routes one to a handler that exits, so an
                // invariant a malformed packet trips would take every
                // connection on the machine down with it. Kept where the
                // handler's message is the point, dropped where a stack that
                // degrades is worth more than one that dies loudly.
                const lwip_flags: []const []const u8 = if (optimize == .Debug)
                    &.{}
                else
                    &.{"-DLWIP_NOASSERT"};

                exe.root_module.addIncludePath(b.path("third_party/lwip/src/include"));
                exe.root_module.addIncludePath(b.path("src/user/netd/lwipport"));
                exe.root_module.addIncludePath(b.path("include"));
                exe.root_module.addCSourceFiles(.{
                    .files = &lwip_sources,
                    .flags = user.cFlags(lwip_flags),
                });
                // For the routines lwIP's C calls by name.
                user.addClibc(exe);
            }
            // Which formats a program can open. Named per program, so what
            // is not named is not in the binary at all.
            if (comptime imageFormats(program.name)) |formats| {
                user.addPictures(exe, formats);
            }

            if (comptime std.mem.eql(u8, program.name, "platd")) {
                exe.root_module.addIncludePath(b.path("third_party/uacpi/include"));
                exe.root_module.addCSourceFiles(.{
                    .files = &(uacpi_sources ++ [_][]const u8{"src/user/platd/abi.c"}),
                    .flags = user.cFlags(&.{
                        "-DUACPI_PHYS_ADDR_IS_32BITS",
                        "-DUACPI_SIZED_FREES=0",
                    }),
                });
            }

            b.installArtifact(exe);
            user_bins[i] = exe;
        }

        // Extra applications: first-party programs that are not part of the
        // system. Built on demand into home/, beside where a person's files
        // live, rather than into the image's /bin. `zig build hero`, which
        // `make apps` runs; see apps/README.md. Built exactly as a system
        // program is, the toolkit and the picture decoder included, because it
        // is one in every way but where it is installed and whether it ships.
        {
            const hero = user.exe("hero", "apps/hero/hero.zig", true);
            user.addPictures(hero, &.{
                "-DSTBI_ONLY_PNG",
                "-DSTBI_ONLY_JPEG",
                "-DSTBI_ONLY_BMP",
                "-DSTBI_ONLY_GIF",
            });

            // Its own step, so the default build and the image never carry it.
            const hero_step = b.step("hero", "Build the Hero extra application into zig-out/bin");
            hero_step.dependOn(&b.addInstallArtifact(hero, .{}).step);

            const echat = user.exe("echat", "apps/echat/echat.zig", !named(symbols, "echat"));
            const echat_step = b.step("echat", "Build the echat IRC client into zig-out/bin");
            echat_step.dependOn(&b.addInstallArtifact(echat, .{}).step);

            const web = user.exe("web", "apps/web/web.zig", !named(symbols, "web"));
            user.addLexbor(web);
            const web_step = b.step("web", "Build the web reader into zig-out/bin");
            web_step.dependOn(&b.addInstallArtifact(web, .{}).step);

            // The portable library built for the host, which the apps' host
            // tests import as the apps themselves do.
            const app_lib = b.createModule(.{
                .root_source_file = b.path("src/lib/lib.zig"),
                .target = b.graph.host,
                .optimize = .Debug,
            });

            // Its host side: addresses, the protocol, encodings, the page
            // and its layout, which are all arithmetic over text.
            const web_test = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("apps/web/tests.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                    .imports = &.{.{ .name = "lib", .module = app_lib }},
                }),
            });
            const web_test_step = b.step("test-web", "Test web's addresses, protocol, encodings, page and layout on the host");
            web_test_step.dependOn(&b.addRunArtifact(web_test).step);

            // The character-journal model, on the host: the whole of a
            // character is what its lines add up to, and none of it needs a
            // screen to be checked.
            const hero_test = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("apps/hero/journal.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                    .imports = &.{.{ .name = "lib", .module = b.createModule(.{
                        .root_source_file = b.path("src/lib/lib.zig"),
                        .target = b.graph.host,
                        .optimize = .Debug,
                    }) }},
                }),
            });
            const hero_test_step = b.step("test-hero", "Test the Hero character-journal model on the host");
            hero_test_step.dependOn(&b.addRunArtifact(hero_test).step);

            // echat's host side: the protocol engine, tested against the
            // shared parser vectors, and the state the window draws.
            const echat_test = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("apps/echat/tests.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                    .imports = &.{
                        .{ .name = "lib", .module = app_lib },
                        .{ .name = "eui", .module = b.createModule(.{
                            .root_source_file = b.path("src/user/eui/eui.zig"),
                            .target = b.graph.host,
                            .optimize = .Debug,
                            .imports = &.{.{ .name = "lib", .module = app_lib }},
                        }) },
                    },
                }),
            });
            const echat_test_step = b.step("test-echat", "Test echat's engine and model on the host");
            echat_test_step.dependOn(&b.addRunArtifact(echat_test).step);

            const roll = user.exe("roll", "apps/roll/roll.zig", !named(symbols, "roll"));
            user.addPictures(roll, &.{ "-DSTBI_ONLY_JPEG", "-DSTBI_ONLY_PNG" });
            const roll_step = b.step("roll", "Build the Roll photo sheet into zig-out/bin");
            roll_step.dependOn(&b.addInstallArtifact(roll, .{}).step);

            // Its host side: the sheet, which is a list and a cursor over it.
            const roll_test = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("apps/roll/tests.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                    .imports = &.{.{ .name = "lib", .module = b.createModule(.{
                        .root_source_file = b.path("src/lib/lib.zig"),
                        .target = b.graph.host,
                        .optimize = .Debug,
                    }) }},
                }),
            });
            const roll_test_step = b.step("test-roll", "Test Roll's sheet on the host");
            roll_test_step.dependOn(&b.addRunArtifact(roll_test).step);

            const eeemod = user.exe("eeemod", "apps/eeemod/eeemod.zig", true);
            const eeemod_step = b.step("eeemod", "Build the eeemod tracker player into zig-out/bin");
            eeemod_step.dependOn(&b.addInstallArtifact(eeemod, .{}).step);

            // The format and the sequencer, on the host. A module is bytes
            // in and notes out, and a song is those notes on a clock, so
            // neither needs a sound card to be checked.
            const eeemod_test = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = b.path("apps/eeemod/tests.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                    .imports = &.{.{ .name = "lib", .module = b.createModule(.{
                        .root_source_file = b.path("src/lib/lib.zig"),
                        .target = b.graph.host,
                        .optimize = .Debug,
                    }) }},
                }),
            });
            const eeemod_test_step = b.step("test-eeemod", "Test the tracker's format and sequencer on the host");
            eeemod_test_step.dependOn(&b.addRunArtifact(eeemod_test).step);
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
    // The boot sections the linker script places by name are wrapped in KEEP,
    // so collecting the rest is safe and takes the soft-float and libm that
    // compiler-rt exports and the kernel never calls: a third of the image.
    kernel.link_gc_sections = true;
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

    // The host tests, compiled for another host as well as this one.
    //
    // `zig build test` builds for whatever machine it is run on, so code
    // that compiles on one and not another passes here and fails wherever
    // the tests are run next. The libc's `va_list` is the case that
    // matters: it is a plain pointer on aarch64 and a structure of its own
    // on x86_64, and a function reading one is accepted on the first and
    // refused on the second. Compiled and not run, because a binary for
    // another machine is a binary this one cannot run: what is being
    // checked is that it builds.
    {
        const elsewhere = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux });
        const cross_lib = b.createModule(.{
            .root_source_file = b.path("src/lib/lib.zig"),
            .target = elsewhere,
            .optimize = .Debug,
        });
        for ([_][]const u8{ "src/tests.zig", "src/user/eui/eui.zig" }) |root| {
            const built = b.addTest(.{ .root_module = b.createModule(.{
                .root_source_file = b.path(root),
                .target = elsewhere,
                .optimize = .Debug,
                .imports = &.{.{ .name = "lib", .module = cross_lib }},
            }) });
            demand(check, built);
        }
        demand(check, b.addTest(.{ .root_module = cross_lib }));
    }

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
        .{
            .source = "third_party/ark-pixel/ark-pixel-16px-proportional-latin.bdf",
            .out = "src/lib/fonts/ark_ui_16.zig",
            .name = "Ark Pixel 16",
        },
        // The same family with a fixed advance, for the terminal: a shell and
        // a button label in one voice, at a weight the panel can carry.
        .{
            .source = "third_party/ark-pixel/ark-pixel-12px-monospaced-latin.bdf",
            .out = "src/lib/fonts/ark_mono_12.zig",
            .name = "Ark Pixel Mono 12",
        },
    }) |spec| {
        const run = b.addRunArtifact(mkfont);
        run.addFileArg(b.path(spec.source));
        run.addArg(spec.out);
        run.addArg(spec.name);
        run.has_side_effects = true;
        // What the converter writes is formatted like everything else in the
        // tree, so a regenerated face passes the same check a hand-written
        // file does.
        const tidy = b.addFmt(.{ .paths = &.{spec.out} });
        tidy.step.dependOn(&run.step);
        fonts_step.dependOn(&tidy.step);
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

    // The toolkit, for the same reason. It touches no syscalls, so all of it
    // builds for the host: geometry, the repaint decisions, the icon and
    // figure arithmetic, and what a control does with a key. `eui.zig` pulls
    // its modules in with `refAllDecls`, so a file added there is tested
    // without anyone listing it a second time.
    const eui_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/user/eui/eui.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
        .imports = &.{.{ .name = "lib", .module = host_lib }},
    }) });
    test_step.dependOn(&b.addRunArtifact(eui_tests).step);

    // The picture decoder, on the host: the wrapper is what this system
    // wrote and the decoder is what it vendored, and the seam between them is
    // exactly what a test should be looking at. Built against the host's own
    // library, since what is being checked is the bytes that come back rather
    // than which allocator found room for them. Its synthetic fixtures live in
    // img.zig so a fresh checkout never depends on ignored home/ contents.
    const img_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/user/img/img.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{.{ .name = "lib", .module = host_lib }},
        }),
    });
    img_tests.root_module.addIncludePath(b.path("third_party/stb"));
    img_tests.root_module.addCSourceFiles(.{
        .files = &.{"src/user/img/stb.c"},
        .flags = &.{
            "-std=c11",
            // The writer packs bits with a shift the sanitiser calls
            // undefined and every compiler carries out as meant; the machine
            // build has no sanitiser, and the test should see what it sees.
            "-fno-sanitize=undefined",
            "-DSTBI_ONLY_PNG",
            "-DSTBI_ONLY_JPEG",
            "-DSTBI_ONLY_BMP",
            "-DSTBI_ONLY_GIF",
        },
    });
    test_step.dependOn(&b.addRunArtifact(img_tests).step);

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

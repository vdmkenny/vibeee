//! probe: hand the kernel the arguments a broken or hostile program would.
//!
//! Everything here is a call that must come back as an error rather than as a
//! dead machine. A kernel that reads a user pointer without checking that the
//! pages behind it are there faults in its own context, and a fault in kernel
//! context is a panic: any program could stop the machine with a stray
//! pointer, which is the difference between a bug in a program and a bug in
//! the system.
//!
//! Written as a program rather than a host test because what is being tested
//! is the boundary itself: the check, the fault path, and the errno that comes
//! back are only really exercised by a Ring 3 call into a running kernel.
//! `probe` with no arguments runs the lot and says how many passed.

const abi = @import("lib").syscalls;
const out = @import("ulib").out;
const sys = @import("sys");

/// Somewhere in the user half no program has been given. Above where any
/// program's heap reaches and far below the kernel's base, so it is an
/// address the check must refuse for being absent rather than for being
/// out of range.
const UNMAPPED: usize = 0x3000_0000;

/// The kernel's own half. A user program naming it is asking the kernel to
/// read or write itself on its behalf.
const SUPERVISOR: usize = 0xC000_0000;

const Case = struct {
    says: []const u8,
    run: *const fn () isize,
    /// What the kernel must answer. Every one of these is a refusal: the
    /// point is that none of them is a fault.
    want: abi.Errno,
};

const CASES = [_]Case{
    .{ .says = "a null pointer", .run = &nullPointer, .want = .fault },
    .{ .says = "a pointer nothing is mapped at", .run = &unmapped, .want = .fault },
    .{ .says = "an address in the kernel's own half", .run = &supervisor, .want = .fault },
    .{ .says = "a length that wraps the address space", .run = &wrapping, .want = .fault },
    .{ .says = "a buffer that runs off the end of its page", .run = &crossPage, .want = .fault },
    .{ .says = "a read-only page as somewhere to write", .run = &readOnly, .want = .fault },
    .{ .says = "a path that reaches into the kernel", .run = &kernelPath, .want = .fault },
    .{ .says = "a handle nobody was given", .run = &strayHandle, .want = .badf },
    .{ .says = "a message at an address it cannot sit at", .run = &misalignedMessage, .want = .fault },
    .{ .says = "one of the system's own service names", .run = &reservedName, .want = .perm },
};

pub fn run(args: []const []const u8) void {
    _ = args;

    var passed: usize = 0;
    for (CASES) |case| {
        const got = case.run();
        const ok = got == case.want.value();
        if (ok) passed += 1;

        out.text(if (ok) "  ok   " else "  FAIL ");
        out.pad(case.says, 44);
        say(got, case.want);
        out.byte('\n');
    }

    out.decimal(passed);
    out.text(" of ");
    out.decimal(CASES.len);
    out.text(" refused as they should be\n");
    out.flush();
}

fn say(got: isize, want: abi.Errno) void {
    if (got == want.value()) {
        out.text(name(want));
        return;
    }
    out.text("wanted ");
    out.text(name(want));
    out.text(", got ");
    if (got < 0) {
        out.text("errno ");
        out.decimal(@intCast(-got));
    } else {
        out.text("success (");
        out.decimal(@intCast(got));
        out.byte(')');
    }
}

fn name(which: abi.Errno) []const u8 {
    return switch (which) {
        .fault => "refused (fault)",
        .badf => "refused (bad handle)",
        .perm => "refused (not allowed)",
        else => "refused",
    };
}

// ---------------------------------------------------------------------------
// The cases
//
// Each one names a syscall that reads or writes the caller's memory, because
// that is the boundary being tested rather than the call.
// ---------------------------------------------------------------------------

fn nullPointer() isize {
    // Zero is not a pointer Zig will make, which is the whole reason the
    // kernel has to be the one that refuses it.
    return sys.writeRaw(abi.STDOUT, 0, 8);
}

fn unmapped() isize {
    return sys.writeRaw(abi.STDOUT, UNMAPPED, 8);
}

fn supervisor() isize {
    return sys.writeRaw(abi.STDOUT, SUPERVISOR, 8);
}

/// A length that carries the end of the range past the top of the address
/// space, which is how a check written as `ptr + len` and nothing else is
/// walked straight past.
fn wrapping() isize {
    const near_top: usize = 0x2000_0000;
    return sys.writeRaw(abi.STDOUT, near_top, 0 -% near_top);
}

/// One page, and nothing after it.
///
/// A segment rather than a static array: the page after anything the loader
/// laid out is likely to be mapped too, so a buffer running off the end of one
/// would be caught by nothing and prove nothing. A freshly mapped segment ends
/// where the mapping ends.
fn onePage(writable: bool) usize {
    const handle = sys.shmCreate(PAGE);
    if (handle < 0) return 0;
    const at = sys.shmMap(@intCast(handle), .{ .writable = writable }) orelse return 0;
    return @intFromPtr(at);
}

const PAGE = 4096;

/// A buffer whose first page is there and whose second is not, which a check
/// that looks only at where a range starts passes and then faults partway
/// through the copy.
fn crossPage() isize {
    const page = onePage(true);
    if (page == 0) return NOT_RUN;
    return sys.writeRaw(abi.STDOUT, page + PAGE - 8, 16);
}

/// Somewhere the program may read and may not write, offered to the kernel as
/// the place to put a result.
fn readOnly() isize {
    const page = onePage(false);
    if (page == 0) return NOT_RUN;
    return sys.statRaw("/", page, 64);
}

/// What a case answers when the machinery it needs was unavailable, so a
/// missing segment reads as a case that did not run rather than as a hole.
const NOT_RUN: isize = 1;

fn kernelPath() isize {
    return sys.openRaw(SUPERVISOR, 12, .{});
}

fn strayHandle() isize {
    return sys.close(4095);
}

/// The name the settings store answers to. A program that took it would be
/// asked every question about what this machine is set to, and would answer
/// them. It is held back for whatever is actually the settings store.
fn reservedName() isize {
    return sys.svcRegister("cfg");
}

/// A message at an address it could never be laid out at. The kernel treats
/// the bytes there as a struct, and a struct at a misaligned address is
/// undefined before it is anything else.
fn misalignedMessage() isize {
    const page = onePage(true);
    if (page == 0) return NOT_RUN;

    // A channel of this program's own, because a handle that is not a channel
    // is refused before the message is looked at and the case would then say
    // nothing about the message.
    const channel = sys.svcRegister("probe");
    if (channel < 0) return NOT_RUN;

    return sys.recvRaw(@intCast(channel), page + 1, page + 8);
}

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

const std = @import("std");
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
    .{ .says = "signalling an event only given to read", .run = &readOnlyEvent, .want = .perm },
    .{ .says = "a program whose bytes reach past its file", .run = &crookedProgram, .want = .inval },
};

pub fn run(args: []const []const u8) void {
    // Started with `echo` this program is the other end of its own channel:
    // the handle cases need something to call, and a server that answers is
    // the smallest thing that will do.
    if (args.len > 0 and std.mem.eql(u8, args[0], "echo")) return echo();

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

    balance();
    out.flush();
}

// ---------------------------------------------------------------------------
// What a channel gives back
//
// A handle sent over a channel is counted at both ends, and the counting is
// invisible from outside: nothing a program can ask says how many references
// an object has. What it can ask is how much the kernel is holding, so the
// test is arithmetic on that. A reference left behind on every call is an
// object that is never freed, and a hundred of them is a number that shows.
// ---------------------------------------------------------------------------

/// How many calls to make. Enough that a single leaked object per call is
/// larger than the noise of everything else the machine is doing, and small
/// enough to be over before anybody is waiting for it.
const ROUNDS = 200;

fn balance() void {
    // Detached: the server outlives this call rather than being waited for.
    const server = sys.spawnDetached("/bin/tools", &.{ "tools", "probe", "echo" });
    if (server < 0) {
        out.text("  ..   handles over a channel: nothing to call\n");
        return;
    }

    // The server has to have published its name before the first connect.
    const channel = connect();
    if (channel < 0) {
        out.text("  ..   handles over a channel: nobody answered\n");
        return;
    }

    const before = held();
    for (0..ROUNDS) |_| {
        const e = sys.eventCreate();
        if (e < 0) break;
        const msg = abi.Message.init("x", &.{@intCast(e)});
        var answer: abi.Message = .{};
        _ = sys.callMsg(@intCast(channel), &msg, &answer);
        _ = sys.close(@intCast(e));
    }
    const after = held();

    _ = sys.close(@intCast(channel));

    // Some growth is the rest of the machine, and a leak is proportional to
    // the number of rounds: an event is tens of bytes, so a reference kept per
    // call is thousands and anything below that is noise.
    const grew = if (after > before) after - before else 0;
    const room = ROUNDS * @sizeOf(usize);

    out.text(if (grew < room) "  ok   " else "  FAIL ");
    out.pad("handles sent over a channel are given back", 44);
    if (grew < room) {
        out.text("nothing left behind");
    } else {
        out.decimal(grew);
        out.text(" bytes held after ");
        out.decimal(ROUNDS);
        out.text(" calls");
    }
    out.byte('\n');
}

/// How many bytes the kernel is holding in objects right now.
fn held() usize {
    var buf: [64]u8 = undefined;
    const n = sys.sysinfo("heap", &buf);
    if (n <= 0) return 0;

    // "<n> bytes live, <n> frames".
    const said = buf[0..@intCast(n)];
    const end = std.mem.indexOfScalar(u8, said, ' ') orelse return 0;
    return std.fmt.parseInt(usize, said[0..end], 10) catch 0;
}

/// Wait for the server's name to appear. It is a program that has to be
/// scheduled, loaded and run before it registers anything.
fn connect() isize {
    for (0..200) |_| {
        const got = sys.svcConnect(ECHO);
        if (got >= 0) return got;
        sys.sleepMicros(1000);
    }
    return -1;
}

const ECHO = "probe.echo";

/// The other end: take whatever arrives, close the handles that came with it,
/// and answer. Closing them is the point, because a handle nobody closes tells
/// nothing about whether the kernel would have let it go.
fn echo() void {
    const channel = sys.svcRegister(ECHO);
    if (channel < 0) {
        out.text("probe: echo could not publish itself\n");
        out.flush();
        return;
    }

    var idle: usize = 0;
    while (idle < 500) {
        var msg: abi.Message = .{};
        const got = sys.recv(@intCast(channel), &msg, 10_000) orelse {
            idle += 1;
            continue;
        };
        idle = 0;
        for (msg.handleSlice()) |number| _ = sys.close(number);
        _ = sys.reply(@intCast(channel), got.token, "");
    }
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
        .inval => "refused (not a program)",
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

/// A program image whose one segment says its bytes start near the top of the
/// address space and run a page past it.
///
/// Every offset in a program header is a number the file chose. Added up in
/// the machine's own width the sum comes back around to nothing, a bounds
/// check written that way passes, and the loader then copies a page from
/// wherever that offset lands into memory the program can read: a way to be
/// handed any of the machine's memory by asking to be run.
///
/// The arithmetic is checked where it can be tested, in `elf/plan.zig`. What
/// this case covers is the whole path: that a file which cannot be believed
/// comes back as a program that would not start, from the call that starts it.
fn crookedProgram() isize {
    var image: [Elf.SIZE]u8 = @splat(0);
    Elf.write(&image, .{ .offset = 0xFFFF_F000, .filesz = 0x1000 });

    const file = sys.open(CROOKED, .{ .write = true, .create = true, .truncate = true });
    if (file < 0) return NOT_RUN;
    const wrote = sys.write(@intCast(file), &image);
    _ = sys.close(@intCast(file));
    if (wrote != image.len) return NOT_RUN;

    return sys.spawn(CROOKED, &.{CROOKED});
}

const CROOKED = "/tmp/crooked";

/// Just enough of a program image to be believed as far as its one segment.
const Elf = struct {
    const HEADER = 52;
    const PROGRAM = 32;
    pub const SIZE = HEADER + PROGRAM;

    const Says = struct { offset: u32, filesz: u32 };

    fn write(into: *[SIZE]u8, says: Says) void {
        into[0..4].* = "\x7fELF".*;
        into[4] = 1; // 32-bit
        into[5] = 1; // little-endian
        into[6] = 1; // the only version there is
        put(into, 16, 2); // an executable
        put(into, 18, 3); // for this machine
        put(into, 20, 1);
        put(into, 24, 0x1000); // where it would start
        put(into, 28, HEADER); // where the program table is
        put(into, 40, HEADER); // how big this header is
        put(into, 42, PROGRAM);
        put(into, 44, 1); // one segment

        const at = HEADER;
        put(into, at + 0, 1); // to be loaded
        put(into, at + 4, says.offset);
        put(into, at + 8, 0x1000); // where it goes
        put(into, at + 16, says.filesz);
        put(into, at + 20, says.filesz);
        put(into, at + 24, 0b101); // read and run
    }

    /// Little-endian, four bytes, which is every field this writes: the two
    /// halfword fields have room to spare and nothing after them to disturb.
    fn put(into: *[SIZE]u8, at: usize, value: u32) void {
        std.mem.writeInt(u32, into[at..][0..4], value, .little);
    }
};

/// The keyboard's own ready event, which `watch` hands out to read and not to
/// write. Everything waiting on keys waits on this one: a program that could
/// signal it would wake every window on the machine whenever it liked.
fn readOnlyEvent() isize {
    const watched = sys.watch(.keys);
    if (watched < 0) return NOT_RUN;
    return sys.eventSignal(@intCast(watched));
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

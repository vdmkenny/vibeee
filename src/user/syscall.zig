//! Userspace syscall stubs.
//!
//! Thin: each function packs registers and traps. Everything the two sides must
//! agree on, call numbers, flag layouts, wire formats, comes from
//! `lib/syscalls.zig`, which the kernel compiles too, so there is nothing here
//! to keep in sync. `abi.number` resolves a call number at compile time and
//! fails the build on a name that does not exist.

const abi = @import("lib").syscalls;

/// Re-exported so call sites say `sys.STDOUT` rather than reaching two modules
/// deep for a constant. One definition, still; this is only the local name.
pub const STDIN = abi.STDIN;
pub const STDOUT = abi.STDOUT;
pub const STDERR = abi.STDERR;

pub const Timeout = abi.Timeout;
pub const POLL = abi.Timeout.poll;
pub const FOREVER = abi.Timeout.forever;

pub const MAX_PAYLOAD = abi.MAX_PAYLOAD;
pub const MAX_ARGS = abi.MAX_ARGS;

pub const Dirent = abi.Dirent;
pub const OpenFlags = abi.OpenFlags;
pub const SpawnFlags = abi.SpawnFlags;

// ---------------------------------------------------------------------------
// Entering the kernel
//
// Two ways in, one register convention. `int 0x80` works everywhere; SYSENTER
// skips the IDT lookup, the stack switch and the segment loads, which is most
// of what a syscall costs on this core.
//
// One shape for every call rather than one per arity: the arguments live in
// the same five registers whichever path is taken, so a call that needs fewer
// passes zero for the rest. That costs a register clear and saves ten
// near-identical copies of the trap sequence.
// ---------------------------------------------------------------------------

const Method = enum { unknown, trap, fast };
var method: Method = .unknown;

/// Which way in this process uses.
///
/// Asked once, through the slow path, and asked of the kernel rather than of
/// CPUID: what matters is whether the kernel programmed the fast path's
/// registers, and the capability bit cannot tell a kernel that did from one
/// that did not. Getting that wrong means jumping to nothing.
fn chooseMethod() Method {
    const key = "syscall";
    var answer: [16]u8 = @splat(0);

    const n = trapIn(
        abi.number("sysinfo"),
        @intFromPtr(key.ptr),
        key.len,
        @intFromPtr(&answer),
        answer.len,
        0,
    );

    method = if (n > 0 and answer[0] == 's') .fast else .trap;
    return method;
}

inline fn enter(nr: u32, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    const how = if (method != .unknown) method else chooseMethod();
    return switch (how) {
        .fast => fastIn(nr, a0, a1, a2, a3, a4),
        else => trapIn(nr, a0, a1, a2, a3, a4),
    };
}

inline fn trapIn(nr: u32, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile ("int $0x80"
        : [ret] "={eax}" (-> isize),
        : [nr] "{eax}" (nr),
          [a0] "{ebx}" (a0),
          [a1] "{ecx}" (a1),
          [a2] "{edx}" (a2),
          [a3] "{esi}" (a3),
          [a4] "{edi}" (a4),
        : .{ .memory = true });
}

/// The fast path.
///
/// SYSENTER saves neither the stack pointer nor the address to come back to,
/// so both are stashed first: the stack pointer in `ebp`, and the return
/// address pushed just below it where the kernel reads it back. SYSEXIT is
/// given them in `ecx` and `edx`, which is why both are clobbered on return.
inline fn fastIn(nr: u32, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return asm volatile (
        \\ push %%ebp
        \\ push $1f
        \\ mov  %%esp, %%ebp
        \\ sysenter
        \\ 1:
        \\ add  $4, %%esp
        \\ pop  %%ebp
        : [ret] "={eax}" (-> isize),
        : [nr] "{eax}" (nr),
          [a0] "{ebx}" (a0),
          [a1] "{ecx}" (a1),
          [a2] "{edx}" (a2),
          [a3] "{esi}" (a3),
          [a4] "{edi}" (a4),
        : .{ .memory = true, .ecx = true, .edx = true });
}

inline fn syscall0(nr: u32) isize {
    return enter(nr, 0, 0, 0, 0, 0);
}

inline fn syscall1(nr: u32, a0: usize) isize {
    return enter(nr, a0, 0, 0, 0, 0);
}

inline fn syscall3(nr: u32, a0: usize, a1: usize, a2: usize) isize {
    return enter(nr, a0, a1, a2, 0, 0);
}

inline fn syscall4(nr: u32, a0: usize, a1: usize, a2: usize, a3: usize) isize {
    return enter(nr, a0, a1, a2, a3, 0);
}

inline fn syscall5(nr: u32, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return enter(nr, a0, a1, a2, a3, a4);
}

pub fn write(handle: u32, bytes: []const u8) isize {
    return syscall3(abi.number("write"), handle, @intFromPtr(bytes.ptr), bytes.len);
}

pub fn read(handle: u32, buf: []u8) isize {
    return syscall3(abi.number("read"), handle, @intFromPtr(buf.ptr), buf.len);
}

pub fn log(bytes: []const u8) isize {
    return syscall3(abi.number("log"), @intFromPtr(bytes.ptr), bytes.len, 0);
}

pub fn getpid() isize {
    return syscall0(abi.number("getpid"));
}

pub fn yield() void {
    _ = syscall0(abi.number("yield"));
}

pub fn sleepMicros(us: usize) void {
    _ = syscall1(abi.number("sleep_us"), us);
}

pub fn clockMicros() u64 {
    var out: u64 = 0;
    _ = syscall1(abi.number("clock_us"), @intFromPtr(&out));
    return out;
}

/// Wall-clock microseconds since 1970-01-01 UTC, or null if the clock has
/// never been set. Null rather than zero so a caller cannot mistake an unset
/// clock for a real timestamp.
pub fn realtimeMicros() ?i64 {
    var out: i64 = 0;
    if (syscall1(abi.number("realtime_us"), @intFromPtr(&out)) < 0) return null;
    return out;
}

fn syscall2(nr: u32, a0: usize, a1: usize) isize {
    return asm volatile ("int $0x80"
        : [ret] "={eax}" (-> isize),
        : [nr] "{eax}" (nr),
          [a0] "{ebx}" (a0),
          [a1] "{ecx}" (a1),
        : .{ .memory = true });
}



pub fn open(path: []const u8, flags: OpenFlags) isize {
    return syscall3(
        abi.number("open"),
        @intFromPtr(path.ptr),
        path.len,
        @as(u32, @bitCast(flags)),
    );
}

pub fn unlink(path: []const u8) isize {
    return syscall2(abi.number("unlink"), @intFromPtr(path.ptr), path.len);
}

pub fn close(handle: usize) isize {
    return syscall1(abi.number("close"), handle);
}

pub fn seek(handle: usize, offset: isize, whence: usize) isize {
    return syscall3(abi.number("seek"), handle, @bitCast(offset), whence);
}

pub fn readdir(handle: usize, buf: []u8) isize {
    return syscall3(abi.number("readdir"), handle, @intFromPtr(buf.ptr), buf.len);
}

pub fn stat(path: []const u8, buf: []u8) isize {
    return syscall4(abi.number("stat"), @intFromPtr(path.ptr), path.len, @intFromPtr(buf.ptr), buf.len);
}

/// Pack arguments and run a program, returning its exit status.
var spawn_buf: [1024]u8 = undefined;

pub fn spawn(path: []const u8, args: []const []const u8) isize {
    return spawnWith(path, args, .{});
}

/// Start a program without waiting; returns its process id.
pub fn spawnDetached(path: []const u8, args: []const []const u8) isize {
    return spawnWith(path, args, .{ .detached = true });
}

pub const Exited = struct { pid: u32, status: i32 };

/// Collect a child that has exited. `pid` of 0 takes whichever exits first.
pub fn wait(pid: u32, timeout_us: usize) ?Exited {
    var status: i32 = 0;
    const got = syscall3(abi.number("wait"), pid, timeout_us, @intFromPtr(&status));
    if (got < 0) return null;
    return .{ .pid = @intCast(got), .status = status };
}

/// Start a program with its standard streams bound to handles of the caller's
/// choosing. What a terminal emulator uses; everything else wants `spawn`.
pub fn spawnStreams(path: []const u8, args: []const []const u8, options: abi.Spawn) isize {
    const n = abi.Argv.pack(args, &spawn_buf) catch return -22;
    return syscall5(
        abi.number("spawn"),
        @intFromPtr(path.ptr),
        path.len,
        @intFromPtr(&spawn_buf),
        n,
        @intFromPtr(&options),
    );
}

fn spawnWith(path: []const u8, args: []const []const u8, flags: SpawnFlags) isize {
    return spawnStreams(path, args, .{ .flags = @bitCast(flags) });
}

pub const Pipe = struct { read: u32, write: u32 };

/// Create a pipe. The read end can be passed to `waitMany`.
pub fn pipe() ?Pipe {
    var ends: [2]u32 = .{ 0, 0 };
    if (syscall1(abi.number("pipe"), @intFromPtr(&ends)) < 0) return null;
    return .{ .read = ends[0], .write = ends[1] };
}

pub fn chdir(path: []const u8) isize {
    return syscall3(abi.number("chdir"), @intFromPtr(path.ptr), path.len, 0);
}

pub fn getcwd(buf: []u8) isize {
    return syscall3(abi.number("getcwd"), @intFromPtr(buf.ptr), buf.len, 0);
}

pub fn sysinfo(key: []const u8, buf: []u8) isize {
    return syscall4(abi.number("sysinfo"), @intFromPtr(key.ptr), key.len, @intFromPtr(buf.ptr), buf.len);
}

pub const POWER_OFF = 0;
pub const REBOOT = 1;
pub const HALT = 2;

pub fn shutdown(action: usize) noreturn {
    _ = syscall1(abi.number("shutdown"), action);
    unreachable;
}

pub fn kill(pid: u32) isize {
    return syscall1(abi.number("kill"), pid);
}

pub fn exit(status: usize) noreturn {
    _ = syscall1(abi.number("exit"), status);
    unreachable;
}

// ---------------------------------------------------------------------------
// IPC
// ---------------------------------------------------------------------------

pub fn eventCreate() isize {
    return syscall0(abi.number("event_create"));
}

pub fn eventSignal(handle: usize) isize {
    return syscall1(abi.number("event_signal"), handle);
}

/// Block until one of `handles` is signalled; returns which. This is the only
/// way a program stops running without spinning.
pub fn waitMany(handles: []const u32, timeout_us: usize) isize {
    return syscall3(abi.number("wait_many"), @intFromPtr(handles.ptr), handles.len, timeout_us);
}

pub fn eventWait(handle: u32, timeout_us: usize) isize {
    const one = [_]u32{handle};
    return waitMany(&one, timeout_us);
}

/// Publish a service under `name`, returning the serving end of its channel.
pub fn svcRegister(name: []const u8) isize {
    return syscall2(abi.number("svc_register"), @intFromPtr(name.ptr), name.len);
}

pub fn svcConnect(name: []const u8) isize {
    return syscall2(abi.number("svc_connect"), @intFromPtr(name.ptr), name.len);
}

pub const Message = abi.Message;

/// Send a request and block until the reply arrives.
///
/// `reply_out` receives the whole reply message, including any handles the
/// server sent: a segment handle arrives as a number valid in this process.
pub fn callMsg(handle: usize, request: *const Message, reply_out: *Message) isize {
    return syscall3(
        abi.number("call"),
        handle,
        @intFromPtr(request),
        @intFromPtr(reply_out),
    );
}

/// The common case: bytes out, bytes back, no handles.
pub fn call(handle: usize, request: []const u8, reply_buf: []u8) isize {
    const msg = Message.init(request, &.{});
    var answer: Message = .{};

    const n = callMsg(handle, &msg, &answer);
    if (n < 0) return n;

    const got = @min(@as(usize, @intCast(n)), reply_buf.len);
    @memcpy(reply_buf[0..got], answer.data[0..got]);
    return @intCast(got);
}

pub const Request = struct { len: usize, token: u32 };

/// Block until a request arrives on a served channel.
pub fn recv(handle: usize, msg: *Message, timeout_us: usize) ?Request {
    var token: u32 = 0;
    const n = syscall4(
        abi.number("recv"),
        handle,
        @intFromPtr(msg),
        @intFromPtr(&token),
        timeout_us,
    );
    if (n < 0) return null;
    return .{ .len = @intCast(n), .token = token };
}

pub fn replyMsg(handle: usize, token: u32, msg: *const Message) isize {
    return syscall3(abi.number("reply"), handle, token, @intFromPtr(msg));
}

pub fn reply(handle: usize, token: u32, payload: []const u8) isize {
    const msg = Message.init(payload, &.{});
    return replyMsg(handle, token, &msg);
}

// ---------------------------------------------------------------------------
// Shared memory
// ---------------------------------------------------------------------------

pub const PointerEvent = abi.PointerEvent;
pub const Buttons = abi.Buttons;

/// Read pending pointer events, blocking until there is at least one.
pub fn pointerRead(buf: []PointerEvent, timeout_us: usize) []PointerEvent {
    const n = syscall3(
        abi.number("pointer_read"),
        @intFromPtr(buf.ptr),
        buf.len * @sizeOf(PointerEvent),
        timeout_us,
    );
    if (n <= 0) return buf[0..0];
    return buf[0..@divTrunc(@as(usize, @intCast(n)), @sizeOf(PointerEvent))];
}

pub const MapFlags = abi.MapFlags;
pub const DisplayInfo = abi.DisplayInfo;
pub const KeyEvent = abi.KeyEvent;
pub const KeyCode = abi.KeyCode;
pub const Modifiers = abi.Modifiers;

/// Take the screen. Returns a handle to the scanout buffer, which maps like
/// any other segment, or null if something else already owns it.
pub const DisplayError = error{
    /// Nothing to take: the console is in text mode.
    NoDisplay,
    /// Something else already owns it.
    Busy,
    OutOfMemory,
};

/// Take the display. The error says which of the two ordinary reasons it
/// failed, because "no" and "not yet" call for different things from whoever
/// is reading the message.
pub fn displayAcquire(info: *DisplayInfo) DisplayError!isize {
    const handle = syscall1(abi.number("display_acquire"), @intFromPtr(info));
    if (handle >= 0) return handle;

    return switch (-handle) {
        @intFromEnum(abi.Errno.noent) => error.NoDisplay,
        @intFromEnum(abi.Errno.busy) => error.Busy,
        else => error.OutOfMemory,
    };
}

/// Read raw key events, claiming the keyboard from the line discipline.
pub fn keyRead(buf: []KeyEvent, timeout_us: usize) []KeyEvent {
    const n = syscall3(
        abi.number("key_read"),
        @intFromPtr(buf.ptr),
        buf.len * @sizeOf(KeyEvent),
        timeout_us,
    );
    if (n <= 0) return buf[0..0];
    return buf[0..@divTrunc(@as(usize, @intCast(n)), @sizeOf(KeyEvent))];
}

/// Allocate a shared-memory segment. Pass the handle over a channel to share it.
pub fn shmCreate(size: usize) isize {
    return syscall1(abi.number("shm_create"), size);
}

/// Map a segment into this process, returning its address.
pub fn shmMap(handle: usize, flags: MapFlags) ?[*]u8 {
    const at = syscall2(abi.number("shm_map"), handle, @as(u32, @bitCast(flags)));
    if (at < 0) return null;
    return @ptrFromInt(@as(usize, @intCast(at)));
}

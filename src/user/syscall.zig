//! Userspace syscall stubs.
//!
//! Thin: each function packs registers and traps. Everything the two sides must
//! agree on, call numbers, flag layouts, wire formats, comes from
//! `lib/syscalls.zig`, which the kernel compiles too, so there is nothing here
//! to keep in sync. The numbers in particular used to be a hand-kept list, and
//! it drifted; `abi.number` resolves them at compile time and fails the build
//! on a name that does not exist.

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

inline fn syscall0(nr: u32) isize {
    return asm volatile ("int $0x80"
        : [ret] "={eax}" (-> isize),
        : [nr] "{eax}" (nr),
        : .{ .memory = true });
}

inline fn syscall1(nr: u32, a0: usize) isize {
    return asm volatile ("int $0x80"
        : [ret] "={eax}" (-> isize),
        : [nr] "{eax}" (nr),
          [a0] "{ebx}" (a0),
        : .{ .memory = true });
}

inline fn syscall3(nr: u32, a0: usize, a1: usize, a2: usize) isize {
    return asm volatile ("int $0x80"
        : [ret] "={eax}" (-> isize),
        : [nr] "{eax}" (nr),
          [a0] "{ebx}" (a0),
          [a1] "{ecx}" (a1),
          [a2] "{edx}" (a2),
        : .{ .memory = true });
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

fn syscall4(nr: u32, a0: usize, a1: usize, a2: usize, a3: usize) isize {
    return asm volatile ("int $0x80"
        : [ret] "={eax}" (-> isize),
        : [nr] "{eax}" (nr),
          [a0] "{ebx}" (a0),
          [a1] "{ecx}" (a1),
          [a2] "{edx}" (a2),
          [a3] "{esi}" (a3),
        : .{ .memory = true });
}

fn syscall5(nr: u32, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
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

pub fn open(path: []const u8, flags: OpenFlags) isize {
    return syscall3(
        abi.number("open"),
        @intFromPtr(path.ptr),
        path.len,
        @as(u32, @bitCast(flags)),
    );
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

fn spawnWith(path: []const u8, args: []const []const u8, flags: SpawnFlags) isize {
    const n = abi.Argv.pack(args, &spawn_buf) catch return -22;
    return syscall5(
        abi.number("spawn"),
        @intFromPtr(path.ptr),
        path.len,
        @intFromPtr(&spawn_buf),
        n,
        @as(u32, @bitCast(flags)),
    );
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

/// Send a request and block until the reply arrives.
pub fn call(handle: usize, request: []const u8, reply_buf: []u8) isize {
    return syscall5(
        abi.number("call"),
        handle,
        @intFromPtr(request.ptr),
        request.len,
        @intFromPtr(reply_buf.ptr),
        reply_buf.len,
    );
}

pub const Request = struct { len: usize, token: u32 };

/// Block until a request arrives on a served channel.
pub fn recv(handle: usize, buf: []u8, timeout_us: usize) ?Request {
    var token: u32 = 0;
    const n = syscall5(
        abi.number("recv"),
        handle,
        @intFromPtr(buf.ptr),
        buf.len,
        @intFromPtr(&token),
        timeout_us,
    );
    if (n < 0) return null;
    return .{ .len = @intCast(n), .token = token };
}

pub fn reply(handle: usize, token: u32, payload: []const u8) isize {
    return syscall4(abi.number("reply"), handle, token, @intFromPtr(payload.ptr), payload.len);
}

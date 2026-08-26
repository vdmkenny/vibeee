//! Userspace syscall stubs.
//!
//! Hand-written for now; these become generated output from
//! `kernel/syscall_table.zig` once eeelibc exists, so the numbers and argument
//! order cannot drift from the kernel's.

/// Numbers must match kernel/syscall_table.zig.
pub const SYS_EXIT = 0;
pub const SYS_WRITE = 1;
pub const SYS_READ = 2;
pub const SYS_YIELD = 3;
pub const SYS_SLEEP_US = 4;
pub const SYS_CLOCK_US = 5;
pub const SYS_GETPID = 6;
pub const SYS_LOG = 7;
pub const SYS_SHUTDOWN = 8;
pub const SYS_SYSINFO = 9;
pub const SYS_OPEN = 10;
pub const SYS_CLOSE = 11;
pub const SYS_SEEK = 12;
pub const SYS_READDIR = 13;
pub const SYS_STAT = 14;
pub const SYS_SPAWN = 15;
pub const SYS_CHDIR = 16;
pub const SYS_GETCWD = 17;
pub const SYS_REALTIME_US = 18;
pub const SYS_EVENT_CREATE = 19;
pub const SYS_EVENT_SIGNAL = 20;
pub const SYS_WAIT_MANY = 21;
pub const SYS_SVC_REGISTER = 22;
pub const SYS_SVC_CONNECT = 23;
pub const SYS_CALL = 24;
pub const SYS_RECV = 25;
pub const SYS_REPLY = 26;

/// Timeout sentinels for the blocking calls.
pub const POLL: usize = 0;
pub const FOREVER: usize = 0xFFFF_FFFF;

/// Largest inline channel payload, matching kernel/channel.zig. Anything
/// bigger is bulk data and belongs in a shared ring.
pub const MAX_PAYLOAD = 64;

pub const OPEN_DIRECTORY: usize = 1 << 0;

/// Directory entry wire format, matching kernel/syscall.zig.
pub const DIRENT_HEADER = 10; // u32 size, i32 mtime, u8 flags, u8 name_len
pub const DIRENT_FLAG_DIR: u8 = 1 << 0;

/// Matches the kernel limit in arch/x86/usermode.zig.
pub const MAX_ARGS = 16;

pub const STDIN = 0;
pub const STDOUT = 1;
pub const STDERR = 2;

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
    return syscall3(SYS_WRITE, handle, @intFromPtr(bytes.ptr), bytes.len);
}

pub fn read(handle: u32, buf: []u8) isize {
    return syscall3(SYS_READ, handle, @intFromPtr(buf.ptr), buf.len);
}

pub fn log(bytes: []const u8) isize {
    return syscall3(SYS_LOG, @intFromPtr(bytes.ptr), bytes.len, 0);
}

pub fn getpid() isize {
    return syscall0(SYS_GETPID);
}

pub fn yield() void {
    _ = syscall0(SYS_YIELD);
}

pub fn sleepMicros(us: usize) void {
    _ = syscall1(SYS_SLEEP_US, us);
}

pub fn clockMicros() u64 {
    var out: u64 = 0;
    _ = syscall1(SYS_CLOCK_US, @intFromPtr(&out));
    return out;
}

/// Wall-clock microseconds since 1970-01-01 UTC, or null if the clock has
/// never been set. Null rather than zero so a caller cannot mistake an unset
/// clock for a real timestamp.
pub fn realtimeMicros() ?i64 {
    var out: i64 = 0;
    if (syscall1(SYS_REALTIME_US, @intFromPtr(&out)) < 0) return null;
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

pub fn open(path: []const u8, flags: usize) isize {
    return syscall3(SYS_OPEN, @intFromPtr(path.ptr), path.len, flags);
}

pub fn close(handle: usize) isize {
    return syscall1(SYS_CLOSE, handle);
}

pub fn seek(handle: usize, offset: isize, whence: usize) isize {
    return syscall3(SYS_SEEK, handle, @bitCast(offset), whence);
}

pub fn readdir(handle: usize, buf: []u8) isize {
    return syscall3(SYS_READDIR, handle, @intFromPtr(buf.ptr), buf.len);
}

pub fn stat(path: []const u8, buf: []u8) isize {
    return syscall4(SYS_STAT, @intFromPtr(path.ptr), path.len, @intFromPtr(buf.ptr), buf.len);
}

/// Pack arguments and run a program, returning its exit status.
var spawn_buf: [1024]u8 = undefined;

pub fn spawn(path: []const u8, args: []const []const u8) isize {
    var n: usize = 0;
    if (spawn_buf.len < 2) return -22;
    spawn_buf[0] = @truncate(args.len);
    spawn_buf[1] = @truncate(args.len >> 8);
    n = 2;

    for (args) |arg| {
        if (n + 2 + arg.len > spawn_buf.len) return -22;
        spawn_buf[n] = @truncate(arg.len);
        spawn_buf[n + 1] = @truncate(arg.len >> 8);
        n += 2;
        for (arg, 0..) |c, i| spawn_buf[n + i] = c;
        n += arg.len;
    }

    return syscall4(SYS_SPAWN, @intFromPtr(path.ptr), path.len, @intFromPtr(&spawn_buf), n);
}

pub fn chdir(path: []const u8) isize {
    return syscall3(SYS_CHDIR, @intFromPtr(path.ptr), path.len, 0);
}

pub fn getcwd(buf: []u8) isize {
    return syscall3(SYS_GETCWD, @intFromPtr(buf.ptr), buf.len, 0);
}

pub fn sysinfo(key: []const u8, buf: []u8) isize {
    return syscall4(SYS_SYSINFO, @intFromPtr(key.ptr), key.len, @intFromPtr(buf.ptr), buf.len);
}

pub const POWER_OFF = 0;
pub const REBOOT = 1;
pub const HALT = 2;

pub fn shutdown(action: usize) noreturn {
    _ = syscall1(SYS_SHUTDOWN, action);
    unreachable;
}

pub fn exit(status: usize) noreturn {
    _ = syscall1(SYS_EXIT, status);
    unreachable;
}

// ---------------------------------------------------------------------------
// IPC
// ---------------------------------------------------------------------------

pub fn eventCreate() isize {
    return syscall0(SYS_EVENT_CREATE);
}

pub fn eventSignal(handle: usize) isize {
    return syscall1(SYS_EVENT_SIGNAL, handle);
}

/// Block until one of `handles` is signalled; returns which. This is the only
/// way a program stops running without spinning.
pub fn waitMany(handles: []const u32, timeout_us: usize) isize {
    return syscall3(SYS_WAIT_MANY, @intFromPtr(handles.ptr), handles.len, timeout_us);
}

pub fn eventWait(handle: u32, timeout_us: usize) isize {
    const one = [_]u32{handle};
    return waitMany(&one, timeout_us);
}

/// Publish a service under `name`, returning the serving end of its channel.
pub fn svcRegister(name: []const u8) isize {
    return syscall2(SYS_SVC_REGISTER, @intFromPtr(name.ptr), name.len);
}

pub fn svcConnect(name: []const u8) isize {
    return syscall2(SYS_SVC_CONNECT, @intFromPtr(name.ptr), name.len);
}

/// Send a request and block until the reply arrives.
pub fn call(handle: usize, request: []const u8, reply_buf: []u8) isize {
    return syscall5(
        SYS_CALL,
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
        SYS_RECV,
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
    return syscall4(SYS_REPLY, handle, token, @intFromPtr(payload.ptr), payload.len);
}

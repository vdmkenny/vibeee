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

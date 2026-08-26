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

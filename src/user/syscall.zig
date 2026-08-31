//! Userspace syscall stubs.
//!
//! Thin: each function packs registers and traps. Everything the two sides must
//! agree on, call numbers, flag layouts, wire formats, comes from
//! `lib/syscalls.zig`, which the kernel compiles too, so there is nothing here
//! to keep in sync. `abi.number` resolves a call number at compile time and
//! fails the build on a name that does not exist.

const lib = @import("lib");
const abi = lib.syscalls;
const arch = @import("arch/x86/syscall.zig");

/// Hardware access that is an instruction rather than a syscall, scoped to
/// the architecture directory and reached through this layer so nothing
/// else in userspace carries assembly.
pub const ports = @import("arch/x86/ports.zig");
pub const barrier = @import("arch/x86/barrier.zig");
const keymaps = @import("keymaps");

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
pub const MAX_ENV = abi.MAX_ENV;

pub const Dirent = abi.Dirent;
pub const OpenFlags = abi.OpenFlags;
pub const SpawnFlags = abi.SpawnFlags;
pub const Spawn = abi.Spawn;
pub const Caps = abi.Caps;

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
    return arch.trap(nr, a0, a1, a2, a3, a4);
}

/// The fast path, SYSENTER, whose contract lives beside the instruction.
inline fn fastIn(nr: u32, a0: usize, a1: usize, a2: usize, a3: usize, a4: usize) isize {
    return arch.fast(nr, a0, a1, a2, a3, a4);
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

/// Report that the boot reached a usable state. Init's call: it stands the
/// kernel's boot watchdog down before it ends the boot with a panic screen.
pub fn bootOk() isize {
    return syscall0(abi.number("boot_ok"));
}

/// End every other process and wait for them to exit. Returns how many
/// threads were still exiting when the wait ended, or a negative errno.
pub fn stopAll() isize {
    return syscall0(abi.number("stop_all"));
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

/// Set the wall clock. Needs the `time` capability; answers false without it.
///
/// `source` is a short name for where the time came from, which the kernel
/// puts in its log: a machine whose clock jumped should be able to say what
/// moved it.
pub fn setRealtimeMicros(epoch_us: i64, source: []const u8) bool {
    var value = epoch_us;
    return syscall3(
        abi.number("realtime_set"),
        @intFromPtr(&value),
        @intFromPtr(source.ptr),
        source.len,
    ) >= 0;
}

fn syscall2(nr: u32, a0: usize, a1: usize) isize {
    return enter(nr, a0, a1, 0, 0, 0);
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
/// Start a program, telling it what its parent knows.
///
/// The environment is packed the way the arguments are, because it is the
/// same thing: a list of strings.
pub fn spawnEnv(
    path: []const u8,
    args: []const []const u8,
    environment: []const []const u8,
    options: abi.Spawn,
) isize {
    var carried = options;
    if (environment.len != 0) {
        const packed_bytes = abi.Argv.pack(environment, &env_buf) catch return -22;
        carried.env = @intFromPtr(&env_buf);
        carried.env_len = @intCast(packed_bytes);
    }
    return spawnStreams(path, args, carried);
}

var env_buf: [1024]u8 = undefined;

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

pub const IrqError = error{
    /// The caller is not a driver. Capabilities come down the process tree,
    /// so this means nothing above it granted one.
    Denied,
    /// Something already answers for the line, in the kernel or outside it.
    Busy,
    /// Not a line this machine has, or not one the controller can route.
    NoLine,
    OutOfMemory,
};

/// Take a device interrupt line. The handle can be passed to `waitMany`, and
/// the line stays masked until the first wait.
pub fn irqAttach(gsi: u32) IrqError!u32 {
    const handle = syscall1(abi.number("irq_attach"), gsi);
    if (handle >= 0) return @intCast(handle);

    return switch (-handle) {
        @intFromEnum(abi.Errno.perm) => error.Denied,
        @intFromEnum(abi.Errno.busy) => error.Busy,
        @intFromEnum(abi.Errno.inval) => error.NoLine,
        else => error.OutOfMemory,
    };
}

/// Map a device's registers into this process. Needs the driver capability.
pub fn mapDevice(phys: usize, len: usize) ?[*]volatile u32 {
    const at = syscall3(abi.number("map_device"), phys, len, 0);
    return if (at < 0) null else @ptrFromInt(@as(usize, @intCast(at)));
}

/// Physically contiguous DMA memory. Returns the handle to map with `shmMap`
/// and writes the physical base to `physOut`. Needs the driver capability.
/// Become the console's foreground: from now on only this process and its
/// children render there; other processes' lines go to the log ring alone.
pub fn consoleClaim() isize {
    return syscall1(abi.number("console_claim"), 0);
}

/// One dword of PCI configuration space, read through the kernel: the two
/// configuration ports are one shared index pair, and the kernel is the one
/// place an access cannot be interleaved with another process's.
pub fn pciRead(location: u32, offset: u8) u32 {
    return @bitCast(@as(i32, @truncate(syscall2(abi.number("pci_read"), location, offset))));
}

pub fn pciWrite(location: u32, offset: u8, value: u32) void {
    _ = syscall3(abi.number("pci_write"), location, offset, value);
}

/// Tell the kernel this process now drives the PCI device, so its table says
/// driven rather than matched and nothing else probes it as free.
pub fn claimDevice(location: lib.pci.Location) isize {
    return syscall3(abi.number("claim_device"), location.bus, location.device, location.function);
}

pub fn releaseDevice(location: lib.pci.Location) isize {
    return syscall3(abi.number("release_device"), location.bus, location.device, location.function);
}

pub fn dmaAlloc(size: usize, physOut: *u32) isize {
    return syscall2(abi.number("dma_alloc"), size, @intFromPtr(physOut));
}

/// Offer a volume the kernel's filesystems can mount, served from here.
/// `info` carries the geometry in and the handles back.
pub fn volumeAttach(name: []const u8, info: *lib.volume.Attach) isize {
    return syscall3(
        abi.number("volume_attach"),
        @intFromPtr(name.ptr),
        name.len,
        @intFromPtr(info),
    );
}

/// Take the next request on a volume this process serves, or answer that
/// there is none. Never blocks: the doorbell is what waits.
pub fn volumeNext(volume: usize, into: *lib.volume.Request) bool {
    return syscall2(abi.number("volume_next"), volume, @intFromPtr(into)) == 1;
}

/// Answer a request, waking whatever asked for it.
pub fn volumeDone(volume: usize, tag: u16, status: lib.volume.Status, sectors: u32) void {
    _ = syscall4(abi.number("volume_done"), volume, tag, @intFromEnum(status), sectors);
}

/// Withdraw a volume, failing everything still waiting on it.
pub fn volumeDetach(volume: usize) void {
    _ = syscall1(abi.number("volume_detach"), volume);
}

pub const KeyReport = abi.KeyReport;
pub const PointerReport = abi.PointerReport;

/// Report keys from a keyboard this process drives. What they mean is
/// worked out where every keyboard's keys are.
pub fn keyPost(keys: []const abi.KeyReport) isize {
    return syscall2(abi.number("key_post"), @intFromPtr(keys.ptr), keys.len);
}

/// Report movement from a pointing device this process drives.
pub fn pointerPost(reports: []const abi.PointerReport) isize {
    return syscall2(abi.number("pointer_post"), @intFromPtr(reports.ptr), reports.len);
}

/// Allow this process to use a range of I/O ports directly. Needs the driver
/// capability; grants last until the process exits.
pub fn ioportGrant(base: u16, count: usize) isize {
    return syscall3(abi.number("ioport_grant"), base, count, 0);
}

/// Say the device has been serviced, so its line may fire again.
pub fn irqAck(handle: u32) isize {
    return syscall1(abi.number("irq_ack"), handle);
}

pub const Pipe = struct { read: u32, write: u32 };

/// Create a pipe. The read end can be passed to `waitMany`.
pub const TtyMode = abi.TtyMode;

/// Choose how the console delivers what is typed, returning the mode that was
/// in effect so a caller can put it back.
pub fn ttyMode(wanted: TtyMode) TtyMode {
    const was = syscall1(abi.number("tty_mode"), @intFromEnum(wanted));
    return if (was < 0) .cooked else @enumFromInt(@as(u32, @intCast(was)));
}

pub fn pipe() ?Pipe {
    var ends: [2]u32 = .{ 0, 0 };
    if (syscall1(abi.number("pipe"), @intFromPtr(&ends)) < 0) return null;
    return .{ .read = ends[0], .write = ends[1] };
}

/// Ask the display adapter for a mode.
pub fn setMode(width: u16, height: u16, bpp: u8) isize {
    return syscall3(abi.number("set_mode"), width, height, bpp);
}

pub fn mkdir(path: []const u8) isize {
    return syscall3(abi.number("mkdir"), @intFromPtr(path.ptr), path.len, 0);
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

/// Flush and unmount everything, and come back.
///
/// For a caller that will finish the shutdown itself: entering a sleep state
/// properly means evaluating the firmware's own methods, which is `platd`'s
/// job. Nothing is mounted afterwards.
pub fn quiesce() isize {
    return syscall0(abi.number("quiesce"));
}

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

/// Make an open file exactly this long.
pub fn ftruncate(handle: usize, size: usize) isize {
    return syscall2(abi.number("ftruncate"), handle, size);
}

/// Attach a volume at a path.
pub fn mount(device: []const u8, path: []const u8, flags: abi.MountFlags) isize {
    return syscall5(
        abi.number("mount"),
        @intFromPtr(device.ptr),
        device.len,
        @intFromPtr(path.ptr),
        path.len,
        @as(u32, @bitCast(flags)),
    );
}

/// Detach the volume at a path, flushing it first.
pub fn unmount(path: []const u8) isize {
    return syscall2(abi.number("unmount"), @intFromPtr(path.ptr), path.len);
}

/// Choose which keyboard layout the keys mean.
pub fn setKeymap(layout: keymaps.Name) isize {
    return syscall1(abi.number("set_keymap"), @intFromEnum(layout));
}

/// Move a file, replacing whatever is at the destination. Within one volume.
pub fn rename(from: []const u8, to: []const u8) isize {
    return syscall4(
        abi.number("rename"),
        @intFromPtr(from.ptr),
        from.len,
        @intFromPtr(to.ptr),
        to.len,
    );
}

/// An event that fires when something happens, for a program with more than
/// one thing to listen to and no business asking each in turn.
pub fn watch(what: abi.Watchable) isize {
    return syscall1(abi.number("watch"), @intFromEnum(what));
}

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
pub const MountFlags = abi.MountFlags;

/// Why a syscall said no, for a tool that has to tell somebody.
pub const reasonFor = abi.reasonFor;
pub const Errno = abi.Errno;
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

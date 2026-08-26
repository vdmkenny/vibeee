//! The syscall ABI, as data.
//!
//! This file is the single source of truth for the system call interface. Three
//! things are generated from it, so they cannot drift apart:
//!
//!   * the kernel dispatcher      (kernel/syscall.zig)
//!   * the reference documentation (tools/gen-syscall-docs.zig → docs/syscalls.md)
//!   * userspace stubs            (src/user/syscall.zig)
//!
//! Deliberately free of handler pointers and kernel imports, so host tools can
//! import it directly. `kernel/syscall.zig` binds each entry to its
//! implementation and fails to compile if any entry is unbound, a syscall
//! cannot be documented without existing, or exist without being documented.
//!
//! Lives in `lib/` because it is the contract *between* the kernel and
//! userspace, not a possession of either. Both compile the same declarations,
//! so a number, a flag layout or a wire format is written once: the dispatcher,
//! the userspace stubs and [`docs/syscalls.md`](../../docs/syscalls.md) are all
//! derived from what is here, and none of them can drift from the others
//! without failing to build.
const std = @import("std");

pub const ArgKind = enum {
    /// Signed machine word.
    int,
    /// Unsigned machine word.
    uint,
    /// Userspace pointer. Always validated against the caller's address space
    /// before use; never dereferenced twice.
    ptr,
    /// Userspace pointer to memory the kernel only reads.
    cptr,
    /// Byte count, paired with the preceding pointer.
    len,
    /// Index into the calling process's handle table.
    handle,
    /// Bitfield; the description names the flags.
    flags,

    pub fn label(self: ArgKind) []const u8 {
        return switch (self) {
            .int => "int",
            .uint => "uint",
            .ptr => "ptr",
            .cptr => "const ptr",
            .len => "len",
            .handle => "handle",
            .flags => "flags",
        };
    }
};

pub const Arg = struct {
    name: []const u8,
    kind: ArgKind,
    desc: []const u8,
};

pub const Err = struct {
    name: []const u8,
    when: []const u8,
};

pub const Syscall = struct {
    number: u32,
    name: []const u8,
    summary: []const u8,
    args: []const Arg = &.{},
    /// What a successful call returns in the result register.
    returns: []const u8 = "0",
    errors: []const Err = &.{},
    /// Notes worth reading before using it. Optional.
    notes: []const u8 = "",
};

/// Standard error numbers. Returned as negative values in the result register,
/// so a caller tests `result < 0`.
pub const Errno = enum(i32) {
    perm = 1,
    noent = 2,
    io = 5,
    badf = 9,
    nomem = 12,
    fault = 14,
    inval = 22,
    exists = 17,
    child = 10,
    busy = 16,
    nospace = 28,
    pipe = 32,
    nosys = 38,
    timedout = 110,

    pub fn value(self: Errno) i32 {
        return -@as(i32, @intFromEnum(self));
    }
};

const E = struct {
    const badf = Err{ .name = "EBADF", .when = "the handle is not open in this process" };
    const noent = Err{ .name = "ENOENT", .when = "no such file or directory" };
    const nomem = Err{ .name = "ENOMEM", .when = "no handle slots free, or the buffer is too small" };
    const io = Err{ .name = "EIO", .when = "the underlying device failed" };
    const fault = Err{ .name = "EFAULT", .when = "a pointer argument is outside the caller's address space" };
    const inval = Err{ .name = "EINVAL", .when = "an argument is out of range" };
    const exists = Err{ .name = "EEXIST", .when = "the name is already registered" };
    const child = Err{ .name = "ECHILD", .when = "the caller has no such child to wait for" };
    const pipe = Err{ .name = "EPIPE", .when = "the far end of the channel has closed" };
    const nospace = Err{ .name = "ENOSPC", .when = "the volume is full" };
    const busy = Err{ .name = "EBUSY", .when = "another process already owns it" };
    const timedout = Err{ .name = "ETIMEDOUT", .when = "the timeout elapsed before anything happened" };
    const perm = Err{ .name = "EPERM", .when = "the operation is not allowed on that object" };
};

/// The number of a syscall, looked up by name at compile time.
///
/// Userspace names calls through this rather than through a list of integers
/// of its own, which would be a second place to edit and a second place to get
/// wrong. A name with no entry is a compile error, so the two sides cannot
/// disagree about a number.
pub fn number(comptime name: []const u8) u32 {
    return comptime blk: {
        for (table) |sc| {
            if (std.mem.eql(u8, sc.name, name)) break :blk sc.number;
        }
        @compileError("no syscall named '" ++ name ++ "'");
    };
}

/// How a blocking call is told how long to wait. Two sentinels rather than a
/// second argument saying which: a caller either polls, waits forever, or
/// bounds the wait, and those are not three different shapes of call.
pub const Timeout = struct {
    pub const poll: u32 = 0;
    pub const forever: u32 = 0xFFFF_FFFF;
};

/// How `spawn` carries a program's arguments across the boundary.
///
/// One length-prefixed block rather than an array of pointers: pointers would
/// each need validating against the caller's address space separately, and one
/// contiguous copy is both simpler and harder to get wrong. Packer and unpacker
/// live together so the format has one definition rather than two that agree
/// until someone changes one.
pub const Argv = struct {
    pub const Error = error{ TooMany, TooLong, Malformed };

    /// Write `args` into `out`, returning the bytes used.
    pub fn pack(args: []const []const u8, out: []u8) Error!usize {
        if (args.len > MAX_ARGS) return error.TooMany;
        if (out.len < 2) return error.TooLong;

        std.mem.writeInt(u16, out[0..2], @intCast(args.len), .little);
        var n: usize = 2;

        for (args) |arg| {
            if (arg.len > 0xFFFF or n + 2 + arg.len > out.len) return error.TooLong;
            std.mem.writeInt(u16, out[n..][0..2], @intCast(arg.len), .little);
            n += 2;
            @memcpy(out[n..][0..arg.len], arg);
            n += arg.len;
        }
        return n;
    }

    /// Read a packed block back, copying the bytes into `storage` and filling
    /// `slices` with views of it. Returns how many arguments there were.
    ///
    /// Copied rather than borrowed because the kernel unpacks a block that a
    /// user process owns, and the child's address space is about to replace it.
    pub fn unpack(input: []const u8, storage: []u8, slices: [][]const u8) Error!usize {
        if (input.len < 2) return error.Malformed;

        const count = std.mem.readInt(u16, input[0..2], .little);
        if (count > slices.len or count > MAX_ARGS) return error.TooMany;

        var pos: usize = 2;
        var used: usize = 0;

        for (0..count) |i| {
            if (pos + 2 > input.len) return error.Malformed;
            const len = std.mem.readInt(u16, input[pos..][0..2], .little);
            pos += 2;

            if (pos + len > input.len) return error.Malformed;
            if (used + len > storage.len) return error.TooLong;

            @memcpy(storage[used..][0..len], input[pos..][0..len]);
            slices[i] = storage[used..][0..len];
            used += len;
            pos += len;
        }
        return count;
    }
};

/// Most arguments a program can be started with. Bounded because the loader
/// copies them onto the new stack before the process exists to own them.
pub const MAX_ARGS = 16;

/// Largest inline channel payload. Small on purpose: anything that does not fit
/// is bulk data and belongs in a shared ring.
pub const MAX_PAYLOAD = 64;

/// What a display owner is told about the screen. Mirrors kernel/display.zig.
pub const DisplayInfo = extern struct {
    width: u16 = 0,
    height: u16 = 0,
    /// Pixels per scanline, which is not the width: a framebuffer is padded to
    /// whatever the hardware finds convenient.
    stride_px: u16 = 0,
    format: u8 = 0,
    buffers: u8 = 1,
    caps: u32 = 0,
    bytes: u32 = 0,
};

/// A pointer event as userspace sees it.
///
/// Position and delta both travel, because a consumer that only wants position
/// should not have to accumulate one, and a consumer that wants motion should
/// not have to difference one. `buttons_changed` distinguishes a click from a
/// drag without comparing against the previous event.
pub const KeyCode = enum(u8) {
    none = 0,

    escape,
    // Number row, left to right.
    n1, n2, n3, n4, n5, n6, n7, n8, n9, n0,
    minus, equal, backspace,

    tab,
    q, w, e, r, t, y, u, i, o, p,
    bracket_left, bracket_right, enter,

    control_left,
    a, s, d, f, g, h, j, k, l,
    semicolon, apostrophe, grave,

    shift_left, backslash,
    z, x, c, v, b, n, m,
    comma, period, slash, shift_right,

    keypad_asterisk,
    alt_left, space, caps_lock,

    f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,

    num_lock, scroll_lock,

    // Keypad.
    kp7, kp8, kp9, kp_minus,
    kp4, kp5, kp6, kp_plus,
    kp1, kp2, kp3, kp0, kp_period,
    kp_enter, kp_slash,

    // Extended (0xE0-prefixed) keys.
    control_right, alt_right,
    home, up, page_up, left, right, end, down, page_down,
    insert, delete,
    super_left, super_right, menu,

    /// The key ISO keyboards have and ANSI ones do not: the extra one beside
    /// the left shift. AZERTY uses it, so it cannot be omitted.
    iso_extra,

    pub fn isModifier(self: KeyCode) bool {
        return switch (self) {
            .shift_left, .shift_right, .control_left, .control_right,
            .alt_left, .alt_right, .super_left, .super_right, .caps_lock,
            => true,
            else => false,
        };
    }
};

/// Keyboard modifier state.
///
/// Shared for the same reason `Buttons` is: the driver sets these bits, the
/// keymap reads them, and the toolkit branches on them, with a syscall in
/// between.
pub const Modifiers = packed struct(u8) {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    /// AltGr, the right Alt key. Distinct from `alt` because layouts use it as
    /// a third symbol level, and Belgian AZERTY depends on it for @ # [ ] { }.
    altgr: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    _reserved: u1 = 0,

    /// Whether a letter should come out uppercase. Caps Lock and Shift cancel
    /// rather than compound.
    pub fn letterShifted(self: Modifiers) bool {
        return self.shift != self.caps_lock;
    }
};

/// Which pointer buttons are held. Defined here because the driver, the
/// kernel input core, the syscall boundary and the toolkit all speak about the
/// same three bits, and three of those are on the far side of a syscall from
/// the fourth.
pub const Buttons = packed struct(u8) {
    left: bool = false,
    right: bool = false,
    middle: bool = false,
    _reserved: u5 = 0,

    pub fn any(self: Buttons) bool {
        return self.left or self.right or self.middle;
    }
};

pub const PointerEvent = extern struct {

    x: i16 = 0,
    y: i16 = 0,
    dx: i16 = 0,
    dy: i16 = 0,
    /// Positive scrolls up.
    wheel: i8 = 0,
    buttons: Buttons = .{},
    buttons_changed: u8 = 0,
    _pad: u8 = 0,

    /// Motion with a button held.
    pub fn isDrag(self: PointerEvent) bool {
        return self.buttons_changed == 0 and self.buttons.any() and
            (self.dx != 0 or self.dy != 0);
    }
};

/// A key event as userspace sees it.
///
/// Both the keycode and the character: a text field wants what was typed, and
/// a shortcut wants which key was pressed regardless of what it produces on
/// the current layout. Sending only one would make one of the two impossible.
pub const KeyEvent = extern struct {
    /// Layout-independent key identity, matching kernel/input.zig KeyCode.
    code: u8 = 0,
    pressed: u8 = 0,
    modifiers: u8 = 0,
    _pad: u8 = 0,
    /// Unicode codepoint the layout produced, or 0 for a key that produces no
    /// character.
    codepoint: u32 = 0,

    pub fn mods(self: KeyEvent) Modifiers {
        return @bitCast(self.modifiers);
    }

    pub fn isPress(self: KeyEvent) bool {
        return self.pressed != 0;
    }
};

/// A channel message as it crosses the boundary.
///
/// Passed by pointer rather than as loose arguments because it carries handles
/// as well as bytes, and five registers do not stretch to both. `extern` so
/// the layout is the same on each side without either having to agree with Zig
/// about padding.
///
/// Handle *numbers* here, not objects. A number means nothing outside the
/// process that owns it, so the kernel translates: it takes a reference to what
/// the sender named and gives the receiver a fresh number for the same object.
pub const Message = extern struct {
    len: u16 = 0,
    handle_count: u16 = 0,
    handles: [MAX_MSG_HANDLES]u32 = @splat(0),
    /// Filled in by the kernel on `recv` with the calling process's id, and
    /// ignored on send.
    ///
    /// A server with many clients on one channel has to know which one is
    /// talking, and a client-supplied identifier could name somebody else. The
    /// kernel already knows, so it says: this is attested rather than claimed,
    /// and it saves inventing per-client channels for the sake of identity.
    sender: u32 = 0,
    data: [MAX_PAYLOAD]u8 = @splat(0),

    pub fn bytes(self: *const Message) []const u8 {
        return self.data[0..@min(self.len, MAX_PAYLOAD)];
    }

    pub fn handleSlice(self: *const Message) []const u32 {
        return self.handles[0..@min(self.handle_count, MAX_MSG_HANDLES)];
    }

    pub fn init(payload: []const u8, send_handles: []const u32) Message {
        var m = Message{};
        const n = @min(payload.len, MAX_PAYLOAD);
        @memcpy(m.data[0..n], payload[0..n]);
        m.len = @intCast(n);

        const h = @min(send_handles.len, MAX_MSG_HANDLES);
        @memcpy(m.handles[0..h], send_handles[0..h]);
        m.handle_count = @intCast(h);
        return m;
    }
};

/// Options for `shm_map`.
pub const MapFlags = packed struct(u32) {
    writable: bool = false,
    _reserved: u31 = 0,
};

/// Most handles one channel message may carry. Four is what the design allows
/// and more than anything needs: a request hands over a ring and its wakeup
/// event, which is two.
pub const MAX_MSG_HANDLES = 4;

/// Options for `spawn`. A packed struct rather than loose bit constants: the
/// bit positions are then stated once, both sides `@bitCast` the same type, and
/// adding an option cannot silently collide with an existing one.
pub const SpawnFlags = packed struct(u32) {
    /// Return the child's id immediately instead of waiting for it to exit.
    detached: bool = false,
    _reserved: u31 = 0,
};

/// Well-known handles, open in every process at start.
/// What a child starts with, passed to `spawn` by pointer.
///
/// A struct rather than more argument registers: the list of things worth
/// deciding about a child only grows, and each one added as an argument is an
/// ABI change. `INHERIT` leaves a stream as the parent's, which for every
/// caller but a terminal emulator is the console.
/// What a process is allowed to do.
///
/// Held per process and intersected at every spawn, so a capability can only
/// ever be dropped going down the process tree. A parent cannot hand out what
/// it does not have, and a child cannot regain what its parent gave up: that
/// is the whole rule, and it is what makes granting one safe to do casually.
pub const Caps = packed struct(u32) {
    /// May take interrupt lines, map device apertures, and be granted I/O
    /// ports. Everything a driver server needs and nothing else should have.
    driver: bool = false,
    /// May take the display away from the console.
    display: bool = false,
    /// May start other programs.
    spawn: bool = false,
    /// May stop other processes.
    kill: bool = false,
    /// May power the machine off or restart it.
    power: bool = false,
    _reserved: u27 = 0,

    /// Everything. What the first process starts with, and what a spawn asks
    /// for when it wants the child to keep whatever the parent had.
    pub const all: Caps = @bitCast(@as(u32, 0xFFFF_FFFF));

    pub fn has(self: Caps, wanted: Caps) bool {
        return @as(u32, @bitCast(self)) & @as(u32, @bitCast(wanted)) == @as(u32, @bitCast(wanted));
    }

    /// What a child ends up with: never more than its parent had.
    pub fn intersect(self: Caps, requested: Caps) Caps {
        return @bitCast(@as(u32, @bitCast(self)) & @as(u32, @bitCast(requested)));
    }
};

pub const Spawn = extern struct {
    /// Leave this stream alone.
    pub const INHERIT: i32 = -1;

    flags: u32 = 0,
    stdin: i32 = INHERIT,
    stdout: i32 = INHERIT,
    stderr: i32 = INHERIT,
    /// What the child may do, intersected with what the caller may do. All
    /// bits set, the default, means the child keeps whatever the parent had.
    caps: u32 = 0xFFFF_FFFF,
};

pub const STDIN: u32 = 0;
pub const STDOUT: u32 = 1;
pub const STDERR: u32 = 2;

/// Flags for `open`.
pub const OpenFlags = packed struct(u32) {
    /// Open a directory for reading entries rather than a file.
    directory: bool = false,
    /// Allow writing. Without it the handle is read-only whatever the volume.
    write: bool = false,
    /// Create the file if it does not exist.
    create: bool = false,
    /// Discard any existing contents.
    truncate: bool = false,
    /// Start every write at the end of the file.
    append: bool = false,
    _reserved: u27 = 0,
};

/// The directory entry `readdir` and `stat` produce.
///
/// Encoded by hand rather than as an `extern struct` so the layout is stated
/// once, here, and neither side has to agree with Zig about padding. The kernel
/// writes it and userspace reads it through this one module, so the format has
/// exactly one definition.
/// How the console hands keystrokes to whoever is reading it.
/// What `watch` will hand back an event for.
///
/// Everything else worth waiting on is already a handle, and `wait_many` takes
/// those directly: a channel's serving end is ready when a call is waiting, a
/// pipe's read end when there are bytes. These three are the happenings with
/// no handle of their own.
pub const Watchable = enum(u32) {
    keys = 0,
    pointer = 1,
    /// A child of this process exited, so `wait` has something to collect.
    children = 2,
};

pub const TtyMode = enum(u32) {
    /// A line at a time, echoed and editable with backspace. What a program
    /// that only wants an answer to a question needs.
    cooked = 0,
    /// Every keystroke as it happens, unechoed, with the keys that produce no
    /// character arriving as the escape sequences a terminal sends for them.
    /// What a program that draws its own input line needs.
    raw = 1,
};

pub const Dirent = struct {
    pub const HEADER = 10; // u32 size, i32 mtime, u8 flags, u8 name_len

    /// Longest name a record can carry, which is what `name_len` being one
    /// byte allows.
    pub const NAME_MAX = 255;

    pub const Flags = packed struct(u8) {
        directory: bool = false,
        _reserved: u7 = 0,
    };

    size: u32 = 0,
    /// Seconds since the Unix epoch, or 0 when the filesystem recorded none.
    mtime: i64 = 0,
    is_dir: bool = false,
    name: []const u8 = "",

    /// Write into `out`, returning the bytes used, or null if it will not fit.
    pub fn encode(self: Dirent, out: []u8) ?usize {
        const total = HEADER + self.name.len;
        if (out.len < total or self.name.len > NAME_MAX) return null;

        std.mem.writeInt(u32, out[0..4], self.size, .little);
        // Signed and 32-bit: FAT cannot express a date outside 1980-2107, so
        // 2038 cannot arise through this path, and a signed field leaves room
        // for a filesystem that can express dates before 1970.
        std.mem.writeInt(i32, out[4..8], @truncate(self.mtime), .little);
        out[8] = @bitCast(Flags{ .directory = self.is_dir });
        out[9] = @intCast(self.name.len);
        @memcpy(out[HEADER..][0..self.name.len], self.name);
        return total;
    }

    /// Read `n` bytes back. Null when the buffer is shorter than it claims.
    pub fn decode(buf: []const u8, n: usize) ?Dirent {
        if (n < HEADER) return null;

        const name_len = buf[9];
        if (HEADER + name_len > n) return null;

        const flags: Flags = @bitCast(buf[8]);
        return .{
            .size = std.mem.readInt(u32, buf[0..4], .little),
            .mtime = std.mem.readInt(i32, buf[4..8], .little),
            .is_dir = flags.directory,
            .name = buf[HEADER..][0..name_len],
        };
    }
};

/// The table. Numbers are permanent once released: append, never renumber.
pub const table = [_]Syscall{
    .{
        .number = 0,
        .name = "exit",
        .summary = "Terminate the calling process.",
        .args = &.{
            .{ .name = "status", .kind = .int, .desc = "Exit status reported to whoever waits for this process." },
        },
        .returns = "does not return",
    },
    .{
        .number = 1,
        .name = "write",
        .summary = "Write bytes to an open handle.",
        .args = &.{
            .{ .name = "handle", .kind = .handle, .desc = "Destination. STDOUT and STDERR go to the console." },
            .{ .name = "buf", .kind = .cptr, .desc = "Bytes to write." },
            .{ .name = "len", .kind = .len, .desc = "Number of bytes." },
        },
        .returns = "bytes written",
        .errors = &.{ E.badf, E.fault },
        .notes = "Short writes are possible; callers must loop.",
    },
    .{
        .number = 2,
        .name = "read",
        .summary = "Read bytes from an open handle.",
        .args = &.{
            .{ .name = "handle", .kind = .handle, .desc = "Source." },
            .{ .name = "buf", .kind = .ptr, .desc = "Where to put the bytes." },
            .{ .name = "len", .kind = .len, .desc = "Maximum bytes to read." },
        },
        .returns = "bytes read, or 0 at end of input",
        .errors = &.{ E.badf, E.fault },
        .notes = "Blocks until input is available. On STDIN, input is line-buffered: a read returns once Enter is pressed, and never mid-line.",
    },
    .{
        .number = 3,
        .name = "yield",
        .summary = "Give up the rest of the current time slice.",
        .notes = "A hint, not a guarantee: the scheduler may immediately pick the same thread again if nothing else is runnable.",
    },
    .{
        .number = 4,
        .name = "sleep_us",
        .summary = "Block the calling thread for at least the given time.",
        .args = &.{
            .{ .name = "usec", .kind = .uint, .desc = "Minimum microseconds to sleep." },
        },
        .notes = "Resolution is bounded by the timer tick, so short sleeps round up.",
    },
    .{
        .number = 5,
        .name = "clock_us",
        .summary = "Read the monotonic clock.",
        .args = &.{
            .{ .name = "out", .kind = .ptr, .desc = "Pointer to a u64 that receives microseconds since boot." },
        },
        .errors = &.{E.fault},
        .notes = "Monotonic and never steps backwards. Not wall-clock time; it is unaffected by clock adjustment.",
    },
    .{
        .number = 6,
        .name = "getpid",
        .summary = "Return the calling process's identifier.",
        .returns = "process id",
    },
    .{
        .number = 7,
        .name = "log",
        .summary = "Write a line to the kernel log.",
        .args = &.{
            .{ .name = "buf", .kind = .cptr, .desc = "Message text, without a trailing newline." },
            .{ .name = "len", .kind = .len, .desc = "Message length." },
        },
        .errors = &.{ E.fault, E.inval },
        .notes = "Separate from write() so diagnostics survive a process losing its console handle. Rate-limited.",
    },
    .{
        .number = 8,
        .name = "shutdown",
        .summary = "Flush all filesystems and stop the machine.",
        .args = &.{
            .{ .name = "action", .kind = .uint, .desc = "0 power off, 1 reboot, 2 halt." },
        },
        .returns = "does not return",
        .errors = &.{E.inval},
        .notes = "Unmounts every filesystem and flushes every device before acting. FAT has no journal, so this is the only way to guarantee written data reached the medium.",
    },
    .{
        .number = 9,
        .name = "sysinfo",
        .summary = "Read a named piece of system information.",
        .args = &.{
            .{ .name = "key", .kind = .cptr, .desc = "Key name, e.g. \"cpu\", \"mem\", \"board\", \"smbios\"." },
            .{ .name = "key_len", .kind = .len, .desc = "Length of the key." },
            .{ .name = "buf", .kind = .ptr, .desc = "Where the value is written." },
            .{ .name = "buf_len", .kind = .len, .desc = "Capacity of the buffer." },
        },
        .returns = "bytes written",
        .errors = &.{ E.fault, E.inval },
        .notes = "Values are text, except \"smbios\" which returns the raw DMI structure table for a userspace decoder. A keyed interface rather than a struct, so adding a value is not an ABI break.",
    },
    .{
        .number = 10,
        .name = "open",
        .summary = "Open a file or directory.",
        .args = &.{
            .{ .name = "path", .kind = .cptr, .desc = "Absolute path." },
            .{ .name = "path_len", .kind = .len, .desc = "Length of the path." },
            .{ .name = "flags", .kind = .flags, .desc = "OpenFlags: bit 0 directory, 1 write, 2 create, 3 truncate, 4 append." },
        },
        .returns = "a handle",
        .errors = &.{ E.fault, E.inval, E.noent, E.nomem },
        .notes = "Read-only. Writing needs cluster allocation in the FAT driver, which is not written yet.",
    },
    .{
        .number = 11,
        .name = "close",
        .summary = "Close a handle.",
        .args = &.{
            .{ .name = "handle", .kind = .handle, .desc = "Handle to release." },
        },
        .errors = &.{E.badf},
        .notes = "Closing a file releases the mount reference it held; a volume with handles still open cannot be unmounted.",
    },
    .{
        .number = 12,
        .name = "seek",
        .summary = "Move a file handle's read position.",
        .args = &.{
            .{ .name = "handle", .kind = .handle, .desc = "An open file." },
            .{ .name = "offset", .kind = .int, .desc = "Displacement, interpreted per `whence`." },
            .{ .name = "whence", .kind = .uint, .desc = "0 from start, 1 from current, 2 from end." },
        },
        .returns = "the new position",
        .errors = &.{ E.badf, E.inval },
    },
    .{
        .number = 13,
        .name = "readdir",
        .summary = "Read the next entry from an open directory.",
        .args = &.{
            .{ .name = "handle", .kind = .handle, .desc = "A directory handle from open() with the directory flag." },
            .{ .name = "buf", .kind = .ptr, .desc = "Receives a DirEntry: u32 size, u8 flags, u8 name_len, then the name." },
            .{ .name = "buf_len", .kind = .len, .desc = "Capacity of the buffer." },
        },
        .returns = "bytes written, or 0 when the directory is exhausted",
        .errors = &.{ E.badf, E.fault, E.nomem },
    },
    .{
        .number = 14,
        .name = "stat",
        .summary = "Describe a path without opening it.",
        .args = &.{
            .{ .name = "path", .kind = .cptr, .desc = "Absolute path." },
            .{ .name = "path_len", .kind = .len, .desc = "Length of the path." },
            .{ .name = "buf", .kind = .ptr, .desc = "Receives the same DirEntry layout readdir() produces." },
            .{ .name = "buf_len", .kind = .len, .desc = "Capacity of the buffer." },
        },
        .returns = "bytes written",
        .errors = &.{ E.fault, E.noent, E.nomem },
    },
    .{
        .number = 15,
        .name = "spawn",
        .summary = "Load and run a program, and wait for it to finish.",
        .args = &.{
            .{ .name = "path", .kind = .cptr, .desc = "Absolute path to an ELF executable." },
            .{ .name = "path_len", .kind = .len, .desc = "Length of the path." },
            .{ .name = "argv", .kind = .cptr, .desc = "Packed arguments: u16 count, then each as u16 length followed by bytes." },
            .{ .name = "argv_len", .kind = .len, .desc = "Length of the packed block." },
            .{ .name = "options", .kind = .cptr, .desc = "A Spawn struct, or 0 for defaults. Bit 0 of its flags returns immediately with the child's id instead of waiting." },
        },
        .returns = "the program's exit status",
        .errors = &.{ E.fault, E.noent, E.inval, E.nomem },
        .notes = "Synchronous: the caller blocks until the child exits. The status is " ++
            "never negative, so a negative result always means the child never ran: a " ++
            "process that was stopped rather than exiting reports 128 plus the reason, " ++
            "137 for killed and 139 for a fault. Deliberately not fork, see " ++
            "design/00-vibeee.md §13. Asynchronous spawn arrives with job control, which " ++
            "needs somewhere to report a finished background job.",
    },
    .{
        .number = 16,
        .name = "chdir",
        .summary = "Change the working directory.",
        .args = &.{
            .{ .name = "path", .kind = .cptr, .desc = "Directory to move to; may be relative." },
            .{ .name = "path_len", .kind = .len, .desc = "Length of the path." },
        },
        .errors = &.{ E.fault, E.noent, E.inval },
        .notes = "The directory must exist. A child started afterwards inherits it.",
    },
    .{
        .number = 17,
        .name = "getcwd",
        .summary = "Read the working directory.",
        .args = &.{
            .{ .name = "buf", .kind = .ptr, .desc = "Receives the absolute path." },
            .{ .name = "buf_len", .kind = .len, .desc = "Capacity of the buffer." },
        },
        .returns = "bytes written",
        .errors = &.{ E.fault, E.nomem },
    },
    .{
        .number = 18,
        .name = "realtime_us",
        .summary = "Read the wall clock.",
        .args = &.{
            .{ .name = "out", .kind = .ptr, .desc = "Pointer to an i64 that receives microseconds since 1970-01-01 UTC." },
        },
        .errors = &.{ E.fault, E.inval },
        .notes = "UTC, never local time. EINVAL until the clock has been set from a source; " ++
            "a machine whose battery-backed clock has failed reports that it does not know the " ++
            "time rather than claiming 1970. Use clock_us for measuring intervals: this one can " ++
            "step when a better source corrects it.",
    },

    // -- IPC (design/00-vibeee.md §6.8) -----------------------------------
    //
    // Four objects and one blocking primitive. Channels carry the small
    // synchronous request and reply; rings carry bulk data; events are what a
    // thread blocks on; the registry is how a client finds a server it did not
    // start. Nothing here blocks except through wait_many and the calls
    // documented as blocking, so a thread's whole set of reasons to stop
    // running is enumerable.
    .{
        .number = 19,
        .name = "event_create",
        .summary = "Create an event.",
        .returns = "handle to the new event",
        .errors = &.{E.nomem},
        .notes = "Events count rather than latch, so a signal delivered before anyone waits is " ++
            "kept and consumed by the next waiter instead of being lost.",
    },
    .{
        .number = 20,
        .name = "event_signal",
        .summary = "Signal an event, releasing one waiter.",
        .args = &.{
            .{ .name = "handle", .kind = .handle, .desc = "The event to signal." },
        },
        .errors = &.{E.badf},
    },
    .{
        .number = 21,
        .name = "wait_many",
        .summary = "Block until one of several events is signalled.",
        .args = &.{
            .{ .name = "handles", .kind = .cptr, .desc = "Array of u32 event handles." },
            .{ .name = "count", .kind = .len, .desc = "How many, at most 8." },
            .{ .name = "timeout_us", .kind = .uint, .desc = "0 to poll, 0xFFFFFFFF to block forever, else microseconds." },
        },
        .returns = "index of the event that fired",
        .errors = &.{ E.badf, E.fault, E.inval, E.timedout },
        .notes = "The only blocking primitive: a server with a channel, a ring and a timer waits " ++
            "in one call rather than one thread each. When several are already signalled the " ++
            "lowest index wins, so priority is argument order.",
    },
    .{
        .number = 22,
        .name = "svc_register",
        .summary = "Create a channel and publish it under a name.",
        .args = &.{
            .{ .name = "name", .kind = .cptr, .desc = "Service name: lowercase, digits, dot and dash." },
            .{ .name = "name_len", .kind = .len, .desc = "Length of the name." },
        },
        .returns = "handle to the serving end of the channel",
        .errors = &.{ E.fault, E.inval, E.nomem, E.exists },
        .notes = "Closing the returned handle withdraws the name and fails every call still " ++
            "waiting on a reply, which is what lets a client tell a crashed server from a slow one.",
    },
    .{
        .number = 23,
        .name = "svc_connect",
        .summary = "Open a channel to a registered service.",
        .args = &.{
            .{ .name = "name", .kind = .cptr, .desc = "Service name." },
            .{ .name = "name_len", .kind = .len, .desc = "Length of the name." },
        },
        .returns = "handle to the calling end of the channel",
        .errors = &.{ E.fault, E.noent, E.nomem },
        .notes = "Clients hold a name rather than a handle to one instance, so reconnecting to a " ++
            "restarted server is a lookup rather than a redesign.",
    },
    .{
        .number = 24,
        .name = "call",
        .summary = "Send a request and block until the server replies.",
        .args = &.{
            .{ .name = "handle", .kind = .handle, .desc = "A channel from svc_connect." },
            .{ .name = "request", .kind = .cptr, .desc = "A Message to send." },
            .{ .name = "reply", .kind = .ptr, .desc = "Receives the reply Message." },
        },
        .returns = "bytes of reply payload",
        .errors = &.{ E.badf, E.fault, E.inval, E.pipe },
        .notes = "Payloads are capped at 64 bytes: anything larger is bulk data and belongs in a " ++
            "shared ring, and the message carries the handle to that ring. Up to four handles " ++
            "travel with a message; the receiver gets fresh numbers for the same objects. " ++
            "EPIPE means the serving end closed.",
    },
    .{
        .number = 25,
        .name = "recv",
        .summary = "Block until a request arrives on a served channel.",
        .args = &.{
            .{ .name = "handle", .kind = .handle, .desc = "A channel from svc_register." },
            .{ .name = "msg", .kind = .ptr, .desc = "Receives the request Message, including any handles." },
            .{ .name = "token", .kind = .ptr, .desc = "Receives a u32 naming this call, to pass to reply()." },
            .{ .name = "timeout_us", .kind = .uint, .desc = "0 to poll, 0xFFFFFFFF to block forever, else microseconds." },
        },
        .returns = "bytes of request payload",
        .notes = "The message's `sender` field is filled in with the calling process's id. A " ++
            "server with many clients on one channel needs to know which is talking, and the " ++
            "kernel is the only party that cannot be lied to about it.",
        .errors = &.{ E.badf, E.fault, E.inval, E.timedout },
    },
    .{
        .number = 26,
        .name = "reply",
        .summary = "Answer a call taken by recv().",
        .args = &.{
            .{ .name = "handle", .kind = .handle, .desc = "The channel the call arrived on." },
            .{ .name = "token", .kind = .uint, .desc = "The token recv() produced." },
            .{ .name = "msg", .kind = .cptr, .desc = "The reply Message, which may carry handles." },
        },
        .errors = &.{ E.badf, E.fault, E.inval },
        .notes = "The token carries a generation, so a reply to a call that has already been " ++
            "abandoned is rejected rather than landing on whichever call inherited the slot.",
    },
    .{
        .number = 27,
        .name = "wait",
        .summary = "Collect a child that has exited.",
        .args = &.{
            .{ .name = "pid", .kind = .uint, .desc = "Which child, or 0 for whichever exits first." },
            .{ .name = "timeout_us", .kind = .uint, .desc = "0 to poll, 0xFFFFFFFF to block forever, else microseconds." },
            .{ .name = "status", .kind = .ptr, .desc = "Receives the child's i32 exit status." },
        },
        .returns = "the process id that exited",
        .errors = &.{ E.fault, E.child, E.timedout },
        .notes = "A process that has exited stays as a corpse until collected, so a status is " ++
            "never lost before its parent can read it. Children of a process that dies are " ++
            "re-parented onto init, which collects them; ECHILD means there is nothing to wait " ++
            "for, now or ever.",
    },
    .{
        .number = 28,
        .name = "shm_create",
        .summary = "Allocate a shared-memory segment.",
        .args = &.{
            .{ .name = "size", .kind = .len, .desc = "Bytes, rounded up to a page." },
        },
        .returns = "handle to the segment",
        .errors = &.{ E.inval, E.nomem },
        .notes = "The segment is zeroed, and is not mapped anywhere until shm_map. Pass the " ++
            "handle over a channel to share it: the segment outlives any one mapping, and its " ++
            "frames are freed only when the last reference goes.",
    },
    .{
        .number = 29,
        .name = "shm_map",
        .summary = "Map a segment into the calling process.",
        .args = &.{
            .{ .name = "handle", .kind = .handle, .desc = "A segment from shm_create or received over a channel." },
            .{ .name = "flags", .kind = .flags, .desc = "Bit 0 set maps it writable." },
        },
        .returns = "address the segment is mapped at",
        .errors = &.{ E.badf, E.nomem },
        .notes = "Mapping the same segment twice returns two addresses onto the same memory. " ++
            "Addresses are not reused, so a process that maps repeatedly will eventually run " ++
            "out of window rather than silently aliasing.",
    },
    .{
        .number = 30,
        .name = "unlink",
        .summary = "Remove a file.",
        .args = &.{
            .{ .name = "path", .kind = .cptr, .desc = "Path to the file." },
            .{ .name = "path_len", .kind = .len, .desc = "Length of the path." },
        },
        .errors = &.{ E.fault, E.noent, E.inval, E.io },
        .notes = "Directories are not removed by this call. Clusters are freed immediately, so a " ++
            "handle still open on the file will read whatever claims them next.",
    },
    .{
        .number = 31,
        .name = "pointer_read",
        .summary = "Read pending pointer events.",
        .args = &.{
            .{ .name = "buf", .kind = .ptr, .desc = "Receives an array of PointerEvent." },
            .{ .name = "buf_len", .kind = .len, .desc = "Capacity in bytes." },
            .{ .name = "timeout_us", .kind = .uint, .desc = "0 to poll, 0xFFFFFFFF to block forever, else microseconds." },
        },
        .returns = "bytes written",
        .errors = &.{ E.fault, E.inval, E.timedout },
        .notes = "Events rather than pollable state: a press and release between two polls would " ++
            "vanish, and the boundaries of a drag would blur. Motion carries the button mask, so " ++
            "a drag is motion with a button already held. Motion may be dropped when the queue " ++
            "fills; a button transition never is.",
    },
    .{
        .number = 32,
        .name = "display_acquire",
        .summary = "Take exclusive ownership of the screen.",
        .args = &.{
            .{ .name = "info", .kind = .ptr, .desc = "Receives a DisplayInfo describing the screen." },
        },
        .returns = "handle to the scanout buffer, mappable with shm_map",
        .errors = &.{ E.fault, E.busy, E.noent, E.nomem },
        .notes = "Exactly one process may own the display: a compositor and the kernel console " ++
            "both drawing into one framebuffer produce a mess neither can recover from. " ++
            "Acquiring stops the console drawing; closing the handle gives it back, cleared. " ++
            "The buffer is an ordinary shared-memory handle, so it maps like any other.",
    },
    .{
        .number = 33,
        .name = "key_read",
        .summary = "Read raw key events, claiming the keyboard.",
        .args = &.{
            .{ .name = "buf", .kind = .ptr, .desc = "Receives an array of KeyEvent." },
            .{ .name = "buf_len", .kind = .len, .desc = "Capacity in bytes." },
            .{ .name = "timeout_us", .kind = .uint, .desc = "0 to poll, 0xFFFFFFFF to block forever, else microseconds." },
        },
        .returns = "bytes written",
        .errors = &.{ E.fault, E.inval, E.timedout },
        .notes = "The first call claims the keyboard: events stop reaching the line discipline " ++
            "and arrive here instead, because a shell reading lines and a compositor reading " ++
            "keys cannot both consume the same keystroke. The claim is released when the " ++
            "process exits. Presses and releases both arrive, with the keycode for shortcuts " ++
            "and the codepoint for text.",
    },
    .{
        .number = 34,
        .name = "kill",
        .summary = "End another process.",
        .args = &.{
            .{ .name = "pid", .kind = .uint, .desc = "Process to end." },
        },
        .returns = "0 on success",
        .errors = &.{ E.noent, E.perm },
        .notes = "There are no signals: this ends the process, it does not ask it to. " ++
            "The process dies at its next return to userspace, so kernel state it holds is " ++
            "unwound rather than abandoned; one blocked or sleeping is woken so that happens " ++
            "at once. Ending `init` is refused, since nothing would collect what it adopts.",
    },
    .{
        .number = 35,
        .name = "pipe",
        .summary = "Create a pipe.",
        .args = &.{
            .{ .name = "out", .kind = .ptr, .desc = "Receives two u32 handles: the read end then the write end." },
        },
        .returns = "0 on success",
        .errors = &.{ E.fault, E.nomem },
        .notes = "Reading blocks until there are bytes, and returns 0 once every writer has " ++
            "closed. Writing blocks while the pipe is full, and fails with EPIPE once every " ++
            "reader has closed. The read end can be passed to wait_many, so a process waiting " ++
            "on a pipe and on something else has one blocking call.",
    },
    .{
        .number = 36,
        .name = "irq_attach",
        .summary = "Take a device interrupt line.",
        .args = &.{
            .{ .name = "gsi", .kind = .uint, .desc = "Global interrupt number, as the firmware describes it." },
        },
        .returns = "a handle",
        .errors = &.{ E.busy, E.inval, E.nomem },
        .notes = "The handle can be passed to wait_many. The line stays masked until the " ++
            "first wait, so a driver may attach before it is ready to service the device. " ++
            "The kernel's own handler masks the line and signals; everything else about the " ++
            "interrupt happens in the driver. Closing the handle gives the line back, masked.",
    },
    .{
        .number = 37,
        .name = "irq_ack",
        .summary = "Say the device has been serviced, so its line may fire again.",
        .args = &.{
            .{ .name = "handle", .kind = .handle, .desc = "A handle from irq_attach." },
        },
        .returns = "0 on success",
        .errors = &.{E.badf},
        .notes = "Acknowledging a line that was not held is not an error: a driver that " ++
            "found nothing to do should say so rather than track whether one was outstanding.",
    },
    .{
        .number = 38,
        .name = "mkdir",
        .summary = "Create a directory.",
        .args = &.{
            .{ .name = "path", .kind = .cptr, .desc = "Absolute or relative path." },
            .{ .name = "path_len", .kind = .len, .desc = "Length of the path." },
        },
        .returns = "0 on success",
        .errors = &.{ E.fault, E.inval, E.exists, E.noent, E.nospace, E.perm },
        .notes = "Only the last component is created; the parent must already exist. " ++
            "The new directory is written with its `.` and `..` already in place.",
    },
    .{
        .number = 39,
        .name = "set_mode",
        .summary = "Ask the display adapter for a mode.",
        .args = &.{
            .{ .name = "width", .kind = .uint, .desc = "Pixels across." },
            .{ .name = "height", .kind = .uint, .desc = "Pixels down." },
            .{ .name = "bpp", .kind = .uint, .desc = "Bits per pixel, or 0 for whatever the adapter prefers." },
        },
        .returns = "0 on success",
        .errors = &.{ E.inval, E.busy, E.perm, E.io },
        .notes = "Refused while something owns the display: changing the mode under a " ++
            "compositor would hand it a buffer of a different shape than the one it is " ++
            "drawing into. EPERM means no backend can drive this adapter, in which case " ++
            "what the firmware set is what there is.",
    },
    .{
        .number = 40,
        .name = "ioport_grant",
        .summary = "Allow this process to use a range of I/O ports directly.",
        .args = &.{
            .{ .name = "base", .kind = .uint, .desc = "First port." },
            .{ .name = "count", .kind = .len, .desc = "How many ports from there." },
        },
        .returns = "0 on success",
        .errors = &.{ E.perm, E.inval, E.nomem },
        .notes = "Needs the driver capability. Granted through the CPU's I/O permission " ++
            "bitmap rather than by mediating each access, so `in` and `out` then run at " ++
            "full speed from Ring 3. Grants accumulate and last until the process exits; " ++
            "there is no revoke, because a driver that no longer wants its ports is a " ++
            "driver that should exit.",
    },
    .{
        .number = 41,
        .name = "map_device",
        .summary = "Map a device's registers into this process.",
        .args = &.{
            .{ .name = "phys", .kind = .uint, .desc = "Physical address of the aperture." },
            .{ .name = "len", .kind = .len, .desc = "Bytes to map, rounded up to a page." },
        },
        .returns = "the address it was mapped at",
        .errors = &.{ E.perm, E.inval, E.nomem },
        .notes = "Needs the driver capability. Mapped uncached, since a write to a " ++
            "register that sat in the cache would never reach the device, and marked as " ++
            "belonging elsewhere so ending the process unmaps it without handing device " ++
            "memory to the page allocator. There is no unmap: a driver that has finished " ++
            "with its device is a driver that should exit.",
    },
    .{
        .number = 42,
        .name = "tty_mode",
        .summary = "Choose how the console delivers what is typed.",
        .args = &.{
            .{ .name = "mode", .kind = .uint, .desc = "A TtyMode: 0 cooked, 1 raw." },
        },
        .returns = "the mode in effect before the call",
        .errors = &.{E.inval},
        .notes = "Raw mode is what a shell drawing its own input line needs: it does its " ++
            "own echoing, so the kernel must not, and it needs the arrow keys, which " ++
            "produce no character and arrive as the escape sequences every terminal " ++
            "sends. The mode belongs to the console rather than to a handle, because " ++
            "there is one keyboard. A program that changes it puts it back.",
    },
    .{
        .number = 43,
        .name = "watch",
        .summary = "An event that fires when something happens.",
        .args = &.{
            .{ .name = "what", .kind = .uint, .desc = "A Watchable: 0 keys, 1 pointer, 2 children." },
        },
        .returns = "an event handle",
        .errors = &.{ E.inval, E.nomem },
        .notes = "For a program with more than one thing to listen to. Each of these can " ++
            "otherwise only be waited for by the call that consumes it, which forces a " ++
            "program watching several into asking each in turn. This hands back the event " ++
            "that call would have waited on, so it goes into a wait_many with everything " ++
            "else and every read afterwards is one that never blocks.",
    },
    .{
        .number = 44,
        .name = "rename",
        .summary = "Move a file or directory, replacing what is already there.",
        .args = &.{
            .{ .name = "from", .kind = .cptr, .desc = "What to move." },
            .{ .name = "from_len", .kind = .len, .desc = "Length of the path." },
            .{ .name = "to", .kind = .cptr, .desc = "Where it goes." },
            .{ .name = "to_len", .kind = .len, .desc = "Length of the path." },
        },
        .errors = &.{ E.fault, E.noent, E.exists, E.inval, E.io, E.perm },
        .notes = "Within one volume: across two this would be a copy and a delete, which " ++
            "takes time proportional to the file and fails differently, so it is refused " ++
            "rather than done silently. Replacing an existing file repoints the record " ++
            "that is already there, so the name means the old content or the new one and " ++
            "never nothing, which is what makes write-then-rename worth doing on FAT. " ++
            "A directory cannot replace or be replaced.",
    },
};

// Numbers must be unique and contiguous from zero: the dispatcher indexes the
// table directly, and a gap would silently dispatch the wrong call.
comptime {
    for (table, 0..) |sc, i| {
        if (sc.number != i) @compileError(
            "syscall table must be contiguous and in order; entry '" ++ sc.name ++ "' is out of place",
        );
    }
}

pub fn find(name: []const u8) ?Syscall {
    for (table) |sc| {
        if (std.mem.eql(u8, sc.name, name)) return sc;
    }
    return null;
}

test "a child never gets more than its parent had" {
    const parent = Caps{ .spawn = true, .display = true };

    // Asking for everything keeps what the parent has, and no more.
    const kept = parent.intersect(Caps.all);
    try std.testing.expect(kept.has(.{ .spawn = true, .display = true }));
    try std.testing.expect(!kept.has(.{ .driver = true }));

    // Asking for something the parent lacks does not conjure it.
    const asked = parent.intersect(.{ .driver = true, .spawn = true });
    try std.testing.expect(asked.has(.{ .spawn = true }));
    try std.testing.expect(!asked.has(.{ .driver = true }));
}

test "capabilities only ever shrink down the tree" {
    var caps = Caps.all;
    // Three generations, each dropping one.
    caps = caps.intersect(.{ .spawn = true, .kill = true, .display = true });
    caps = caps.intersect(.{ .spawn = true, .kill = true });
    caps = caps.intersect(.{ .spawn = true });

    try std.testing.expect(caps.has(.{ .spawn = true }));
    try std.testing.expect(!caps.has(.{ .kill = true }));
    try std.testing.expect(!caps.has(.{ .display = true }));
}

test "holding several is all of them, not any of them" {
    const caps = Caps{ .spawn = true };
    try std.testing.expect(!caps.has(.{ .spawn = true, .kill = true }));
    try std.testing.expect(Caps.all.has(.{ .spawn = true, .kill = true }));
}

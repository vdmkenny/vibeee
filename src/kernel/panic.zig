//! Panic and exception reporting.
//!
//! The Eee PC 701 has **no serial port**. A kernel fault therefore leaves the
//! machine by exactly one route: a photograph of the screen. That single fact
//! justifies more effort here than a panic handler usually deserves.
//!
//! The screen is split. On the left, enough plain text to recognise the fault
//! at a glance. On the right, a QR code carrying the same information in a
//! form a phone can decode — so the register values and backtrace addresses
//! reach a symboliser without being transcribed by hand from a photo.
//!
//! design/00-vibeee.md §6.9 describes the wider ladder; the persistent panic
//! ring (survives warm reboot) lands in M1, and its page is already reserved
//! here so the address never moves.

const std = @import("std");
const console = @import("console.zig");
const hal = @import("hal.zig");
const qr = @import("qr.zig");

/// Physical page reserved for the panic ring, in low memory below the kernel
/// where no boot path writes, so a warm reboot preserves it.
pub const PANIC_RING_PHYS: u32 = 0x7000;
pub const PANIC_RING_MAGIC: u32 = 0x50414E43; // 'PANC'

/// Panic screen palette. Blue is the convention for "the machine stopped", and
/// being visually unmistakable matters: it must be obvious across a room, and
/// obviously different from an ordinary boot failure.
const BG: console.Color = .blue;
const FG: console.Color = .white;
const DIM: console.Color = .light_cyan;

const EXCEPTION_NAMES = [_][]const u8{
    "divide by zero",
    "debug",
    "non-maskable interrupt",
    "breakpoint",
    "overflow",
    "bound range exceeded",
    "invalid opcode",
    "device not available",
    "double fault",
    "coprocessor segment overrun",
    "invalid TSS",
    "segment not present",
    "stack-segment fault",
    "general protection fault",
    "page fault",
    "reserved",
    "x87 floating-point exception",
    "alignment check",
    "machine check",
    "SIMD floating-point exception",
    "virtualization exception",
    "control protection exception",
};

pub const MAX_BACKTRACE = 5;
pub const MAX_REGS = 8;

pub const Reg = struct { name: []const u8, value: usize };

/// What the panic screen renders and the QR payload encodes.
///
/// Deliberately architecture-neutral: the trap vector, the register names and
/// the fault-address semantics all differ per architecture, so the arch layer
/// fills this in and everything below here is portable.
pub const Report = struct {
    /// Trap/exception number, or NO_VECTOR for a software panic.
    vector: u32 = NO_VECTOR,
    error_code: u32 = 0,
    /// Faulting data address, where the architecture reports one.
    fault_addr: usize = 0,
    /// Program counter, stack pointer, frame pointer.
    pc: usize = 0,
    sp: usize = 0,
    fp: usize = 0,
    /// Named registers, rendered in order. Architecture's choice which.
    regs: [MAX_REGS]Reg = @splat(Reg{ .name = "", .value = 0 }),
    regs_len: usize = 0,
    /// Set when the fault came from user mode.
    from_user: bool = false,
    /// True when `error_code` follows the x86 page-fault bitfield layout.
    decode_page_fault: bool = false,
    message: []const u8 = "",
    trace: [MAX_BACKTRACE]usize = @splat(0),
    trace_len: usize = 0,

    pub const NO_VECTOR: u32 = 0xFFFF_FFFF;

    pub fn addReg(self: *Report, reg_name: []const u8, value: usize) void {
        if (self.regs_len >= MAX_REGS) return;
        self.regs[self.regs_len] = .{ .name = reg_name, .value = value };
        self.regs_len += 1;
    }

    fn name(self: *const Report) []const u8 {
        if (self.vector < EXCEPTION_NAMES.len) return EXCEPTION_NAMES[self.vector];
        if (self.message.len > 0) return self.message;
        return "unknown fault";
    }
};

/// Report a fault the architecture layer has already decoded.
pub fn report(r: *Report) noreturn {
    if (r.trace_len == 0) collectBacktrace(r, r.fp);
    render(r);
}

/// Zig's panic entry point. Signature is fixed by std.debug.FullPanic.
pub fn kpanic(msg: []const u8, first_trace_addr: ?usize) noreturn {
    var r = Report{
        .message = msg,
        .pc = first_trace_addr orelse @returnAddress(),
        .fp = @frameAddress(),
    };
    collectBacktrace(&r, @frameAddress());
    render(&r);
}

/// Frame-pointer walk. Valid because the kernel keeps frame pointers
/// specifically so this works (see build.zig).
pub fn collectBacktrace(r: *Report, start_fp: usize) void {
    var ebp = start_fp;
    while (r.trace_len < MAX_BACKTRACE) {
        if (ebp < 0x1000 or ebp > 0x8000_0000 or (ebp & 3) != 0) break;
        const frame: [*]const usize = @ptrFromInt(ebp);
        const next = frame[0];
        const ret = frame[1];
        if (ret == 0) break;
        r.trace[r.trace_len] = ret;
        r.trace_len += 1;
        if (next <= ebp) break; // the stack grows down; anything else is garbage
        ebp = next;
    }
}

// ---------------------------------------------------------------------------
// QR payload
// ---------------------------------------------------------------------------

/// Compact, pipe-separated, uppercase hex. Deliberately human-readable once
/// scanned — no decoder tool required to make sense of it:
///
///   VBE1|<vec>|<err>|<cr2>|<eip>|<esp>|<ebp>|<bt>,<bt>,...
fn buildPayload(r: *const Report, buf: []u8) []const u8 {
    var w: usize = 0;

    const put = struct {
        fn str(b: []u8, p: *usize, s: []const u8) void {
            for (s) |c| {
                if (p.* < b.len) {
                    b[p.*] = c;
                    p.* += 1;
                }
            }
        }
        fn hex(b: []u8, p: *usize, value: u32, digits: usize) void {
            const table = "0123456789ABCDEF";
            var i = digits;
            while (i > 0) {
                i -= 1;
                if (p.* < b.len) {
                    b[p.*] = table[(value >> @intCast(i * 4)) & 0xF];
                    p.* += 1;
                }
            }
        }
    };

    put.str(buf, &w, "VBE1|");
    put.hex(buf, &w, r.vector, 2);
    put.str(buf, &w, "|");
    put.hex(buf, &w, r.error_code, 8);
    put.str(buf, &w, "|");
    put.hex(buf, &w, r.fault_addr, 8);
    put.str(buf, &w, "|");
    put.hex(buf, &w, r.pc, 8);
    put.str(buf, &w, "|");
    put.hex(buf, &w, r.sp, 8);
    put.str(buf, &w, "|");
    put.hex(buf, &w, r.fp, 8);
    put.str(buf, &w, "|");
    for (r.trace[0..r.trace_len], 0..) |addr, i| {
        if (i > 0) put.str(buf, &w, ",");
        put.hex(buf, &w, addr, 8);
    }
    return buf[0..w];
}

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

fn render(r: *const Report) noreturn {
    console.fill(BG, FG);

    var payload_buf: [qr.MAX_PAYLOAD]u8 = undefined;
    const payload = buildPayload(r, &payload_buf);

    // Encode first: the QR's width decides how much room the text gets, and a
    // failed encode must not cost us the text half of the screen.
    var code: qr.Code = undefined;
    const have_qr = if (qr.encode(payload, &code)) |_| true else |_| false;

    const quiet = 4;
    const qr_cols: usize = if (have_qr) @as(usize, code.size) + 2 * quiet else 0;
    const text_width: usize = console.width() - qr_cols - 1;

    drawText(r, text_width);
    if (have_qr) drawQr(&code, console.width() - qr_cols, 1, quiet);


    hal.halt();
}

fn drawText(r: *const Report, width: usize) void {
    console.moveTo(0, 1);
    console.setColor(.black, .light_grey);
    console.writeString(" VIBEEE STOPPED ");
    console.setColor(FG, BG);
    console.putChar('\n');
    console.putChar('\n');

    console.printf(" {s}\n", .{r.name()});
    if (r.vector != Report.NO_VECTOR) {
        console.printf(" vector {d}, error {x:0>8}\n", .{ r.vector, r.error_code });
    }
    console.putChar('\n');

    // A page fault's cause is a bitfield that says far more than the raw number;
    // decode it rather than making the reader remember which bit is which.
    if (r.decode_page_fault) {
        const ec = r.error_code;
        console.printf(" address  {x:0>8}\n", .{r.fault_addr});
        console.printf(" cause    {s}\n", .{
            if (ec & 1 != 0) "protection violation" else "not present",
        });
        console.printf("          while {s} in {s}\n", .{
            if (ec & 2 != 0) "writing" else "reading",
            if (ec & 4 != 0) "user mode" else "kernel mode",
        });
        console.putChar('\n');
    }

    console.setColor(DIM, BG);
    console.printf(" pc  {x:0>8}  sp  {x:0>8}\n", .{ r.pc, r.sp });
    // Two register columns per line, in whatever order the architecture chose.
    for (r.regs[0..r.regs_len], 0..) |reg, i| {
        console.printf(" {s: <3} {x:0>8} ", .{ reg.name, reg.value });
        if (i % 2 == 1) console.putChar('\n');
    }
    if (r.regs_len % 2 == 1) console.putChar('\n');
    console.setColor(FG, BG);
    console.putChar('\n');

    if (r.trace_len > 0) {
        console.writeString(" backtrace\n");
        console.setColor(DIM, BG);
        for (r.trace[0..r.trace_len]) |addr| {
            console.printf("   {x:0>8}\n", .{addr});
        }
        console.setColor(FG, BG);
    }

    _ = width;
    console.moveTo(1, console.height() - 3);
    console.setColor(DIM, BG);
    console.writeString("Scan the code for the full dump,");
    console.moveTo(1, console.height() - 2);
    console.writeString("or photograph the whole screen.");
    console.setColor(FG, BG);
}

const DARK: console.Color = .black;
const LIGHT: console.Color = .light_grey;

/// Render the QR.
///
/// Two paths, because the right answer differs by output device.
///
/// With a framebuffer, modules are drawn as plain rectangles. That depends on
/// no glyph at all, which matters: a font that lacks the block characters
/// substitutes a notdef box, producing a symbol that looks like a QR code and
/// does not scan — the worst possible failure for a diagnostic whose only job
/// is to be read off a photograph. Drawing pixels also gives exactly square
/// modules at whatever scale fits.
///
/// In text mode there are no pixels, so the upper-half-block character is used
/// to pack two module rows into one cell. That is safe there specifically:
/// the VGA ROM font is CP437, which always carries it.
fn drawQr(code: *const qr.Code, origin_col: usize, origin_row: usize, quiet: usize) void {
    const span = @as(usize, code.size) + 2 * quiet;

    if (console.hasPixels()) {
        drawQrPixels(code, origin_col, origin_row, quiet, span);
        return;
    }

    var cell_row: usize = 0;
    while (cell_row * 2 < span) : (cell_row += 1) {
        var x: usize = 0;
        while (x < span) : (x += 1) {
            const top = moduleAt(code, x, cell_row * 2, quiet);
            const bottom = moduleAt(code, x, cell_row * 2 + 1, quiet);
            console.putAt(
                origin_col + x,
                origin_row + cell_row,
                console.BLOCK_UPPER_HALF,
                if (top) DARK else LIGHT,
                if (bottom) DARK else LIGHT,
            );
        }
    }
}

fn drawQrPixels(code: *const qr.Code, origin_col: usize, origin_row: usize, quiet: usize, span: usize) void {
    const screen = console.pixelSize();
    const cell = console.cellSize();

    const x0 = origin_col * cell.width;
    const y0 = origin_row * cell.height;

    // Largest whole number of pixels per module that still fits. Whole pixels
    // matter: a fractional scale makes some modules a pixel wider than others,
    // which is exactly the distortion a decoder is least tolerant of.
    const across = (screen.width -| x0) / span;
    const down = (screen.height -| y0) / span;
    const scale = @max(@as(usize, 2), @min(across, down));

    console.fillPixelRect(x0, y0, span * scale, span * scale, LIGHT);

    var my: usize = 0;
    while (my < span) : (my += 1) {
        var mx: usize = 0;
        while (mx < span) : (mx += 1) {
            if (!moduleAt(code, mx, my, quiet)) continue;
            console.fillPixelRect(x0 + mx * scale, y0 + my * scale, scale, scale, DARK);
        }
    }
}

/// Module lookup in quiet-zone coordinates. Outside the symbol is light, which
/// is what makes the quiet zone a quiet zone.
fn moduleAt(code: *const qr.Code, x: usize, y: usize, quiet: usize) bool {
    if (x < quiet or y < quiet) return false;
    const mx = x - quiet;
    const my = y - quiet;
    if (mx >= code.size or my >= code.size) return false;
    return code.get(mx, my);
}

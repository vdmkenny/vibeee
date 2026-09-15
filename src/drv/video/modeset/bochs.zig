//! The display adapter every emulator has.
//!
//! Bochs defined a small interface for setting a mode without calling a video
//! BIOS: two I/O ports, one naming a register and one carrying its value, and
//! a mode is four numbers written through them. QEMU, VirtualBox and the rest
//! all implement it, which makes it the one adapter a machine that is not a
//! machine can be relied on to have.
//!
//! Worth driving for a reason beyond convenience. A display left as firmware
//! set it cannot be put back after the adapter has been powered down and up,
//! so a machine with no modeset backend refuses to suspend to memory at all;
//! without this that would be every emulator, and the whole of the suspend
//! path would only ever be exercised on the hardware it is hardest to
//! exercise on.

const std = @import("std");
const hal = @import("../../../kernel/hal.zig");
const lib = @import("lib");
const pci = @import("../../bus/pci.zig");
const probe = @import("../../../kernel/probe.zig");
const modeset = @import("modeset.zig");

const Error = modeset.Error;
const Mode = modeset.Mode;
const Framebuffer = modeset.Framebuffer;

/// Who implements the interface, and under what identity.
///
/// Two vendors rather than one, so the table is a list of pairs rather than a
/// vendor and a list of parts: these are the same adapter wearing different
/// badges.
const Adapter = struct { vendor: u16, device: u16, name: []const u8 };

const adapters = [_]Adapter{
    .{ .vendor = 0x1234, .device = 0x1111, .name = "QEMU and Bochs" },
    .{ .vendor = 0x80EE, .device = 0xBEEF, .name = "VirtualBox" },
};

pub fn fits(dev: probe.Device) probe.Confidence {
    for (adapters) |one| {
        if (dev.vendor == one.vendor and dev.device == one.device) return .exact;
    }
    return .no;
}

/// The two ports: which register, and what is in it.
const INDEX: u16 = 0x01CE;
const VALUE: u16 = 0x01CF;

const Register = enum(u16) {
    /// Which revision of the interface this is, as a number the adapter
    /// answers with and nothing writes.
    id = 0,
    width = 1,
    height = 2,
    depth = 3,
    enable = 4,
    /// Which sixty-four kilobyte slice the window at 0xA0000 shows. Of no
    /// use here: everything below reads pixels through the aperture.
    bank = 5,
    /// The size of the picture in memory, which is not the size on the
    /// screen: the scanline stride comes from the first of these.
    virtual_width = 6,
    virtual_height = 7,
    /// Where in that picture the screen starts.
    x_offset = 8,
    y_offset = 9,
};

/// The enable register, which is more than an enable.
const Enable = packed struct(u16) {
    on: bool = false,
    /// Answer with the largest mode this adapter takes, rather than set one:
    /// while this is on, reading the three size registers reads limits.
    limits: bool = false,
    _2: u3 = 0,
    wide_palette: bool = false,
    /// Where the pixels are read from: the aperture the base address names,
    /// rather than the sixty-four kilobyte window every VGA has at 0xA0000.
    linear: bool = false,
    /// Leave what is in the framebuffer alone across the change. Not asked
    /// for: the old mode's pixels reinterpreted at a new width are a sheared
    /// copy of the last screen, and a cleared one is honest.
    keep_pixels: bool = false,
    _8: u8 = 0,
};

/// What the identity register answers, lowest revision first. Anything in
/// this range speaks the interface; anything else is something else.
const ID_BASE: u16 = 0xB0C0;
const ID_TOP: u16 = 0xB0C5;

/// The only depth this system draws at. The console and the compositor both
/// write whole words per pixel, so a mode at any other depth would be a
/// screen full of the right pixels in the wrong colours.
const DEPTH: u8 = 32;

/// The plain VGA registers underneath, which the mode registers above do not
/// reach.
///
/// The adapter is a VGA with the Bochs interface bolted on, and two things
/// the VGA half holds decide whether anything is drawn at all: whether the
/// attribute controller is showing a picture or still waiting to be
/// programmed, and whether the sequencer has the screen switched off. A
/// machine that has just been powered up has both against it, so they are
/// said here rather than left to whatever ran before.
const Vga = struct {
    /// Reading this resets the attribute controller's one-bit state: it
    /// takes an index and a value through the same port and alternates
    /// between them, and nothing else says which it is expecting.
    const status = 0x3DA;
    const attribute = 0x3C0;
    const misc_out = 0x3C2;
    const sequencer_index = 0x3C4;
    const sequencer_data = 0x3C5;

    /// Written into the attribute controller's index port. Below the index
    /// it carries the bit that says the palette is in use and a picture is
    /// being drawn from it, rather than being written to.
    const Attribute = packed struct(u8) {
        index: u5 = 0,
        showing: bool = false,
        _6: u2 = 0,
    };

    /// The first sequencer register. Only one bit of it matters here.
    const Clocking = packed struct(u8) {
        eight_dot_characters: bool = false,
        _1: u1 = 0,
        shift_load_every_other: bool = false,
        dot_clock_halved: bool = false,
        _4: u1 = 0,
        screen_off: bool = false,
        _6: u2 = 0,
    };

    /// Where the adapter answers and whether its memory is readable. A part
    /// fresh from reset answers on the monochrome addresses, which is not
    /// where anything here looks for it.
    const Misc = packed struct(u8) {
        colour_addresses: bool = false,
        memory_enabled: bool = false,
        clock: u2 = 0,
        _4: u1 = 0,
        page_high: bool = false,
        negative_hsync: bool = false,
        negative_vsync: bool = false,
    };

    /// Undo everything a reset leaves in the way of a picture.
    fn show() void {
        hal.outb(misc_out, @bitCast(Misc{ .colour_addresses = true, .memory_enabled = true }));

        hal.outb(sequencer_index, 1);
        var clocking: Clocking = @bitCast(hal.inb(sequencer_data));
        clocking.screen_off = false;
        hal.outb(sequencer_data, @bitCast(clocking));

        _ = hal.inb(status);
        hal.outb(attribute, @bitCast(Attribute{ .showing = true }));
    }
};

fn write(register: Register, value: u16) void {
    hal.outw(INDEX, @intFromEnum(register));
    hal.outw(VALUE, value);
}

fn read(register: Register) u16 {
    hal.outw(INDEX, @intFromEnum(register));
    return hal.inw(VALUE);
}

fn setEnable(value: Enable) void {
    write(.enable, @bitCast(value));
}

fn speaks() bool {
    const id = read(.id);
    return id >= ID_BASE and id <= ID_TOP;
}

/// Whether the adapter takes a mode this size, asked before anything is
/// changed: the alternative is finding out by setting it, and an adapter that
/// refused one has already let go of the mode it had.
fn takes(want: Mode) bool {
    setEnable(.{ .limits = true });
    defer setEnable(.{});
    return read(.width) >= want.width and read(.height) >= want.height and read(.depth) >= DEPTH;
}

/// Where the adapter reads its pixels from, as the first base address names
/// it.
fn aperture(dev: probe.Device) ?u32 {
    const window: lib.pci.MemoryBar = @bitCast(pci.configRead32(dev.location, lib.pci.BAR0_OFFSET));
    const upper = pci.configRead32(dev.location, lib.pci.BAR0_OFFSET + 4);
    return lib.pci.memoryWindowBase(window, upper);
}

pub fn set(dev: probe.Device, want: Mode) Error!Framebuffer {
    if (comptime !hal.available) return error.Unsupported;
    if (want.bpp != Mode.adapter_choice and want.bpp != DEPTH) return error.Unsupported;

    if (!speaks()) return error.Hardware;
    const lfb = aperture(dev) orelse return error.Hardware;
    if (!takes(want)) return error.Unsupported;

    // Off while it changes, which is what the interface asks for: the
    // registers are read as a set when it comes back on, and one read
    // mid-write would be a mode nobody asked for.
    setEnable(.{});
    write(.width, want.width);
    write(.height, want.height);
    write(.depth, DEPTH);
    // No panning and no picture larger than the screen, so the stride is the
    // width and the screen starts at the first pixel.
    write(.virtual_width, want.width);
    write(.x_offset, 0);
    write(.y_offset, 0);
    setEnable(.{ .on = true, .linear = true });
    Vga.show();

    // Read back rather than assumed. The stride especially: an adapter is
    // entitled to round the picture's width up, and a caller drawing at the
    // width it asked for would shear every row it wrote.
    return .{
        .phys = lfb,
        .pitch = @as(u32, read(.virtual_width)) * (DEPTH / 8),
        .width = read(.width),
        .height = read(.height),
        .bpp = DEPTH,
    };
}

pub fn inspect(dev: probe.Device, w: *std.Io.Writer) void {
    if (comptime !hal.available) return;

    w.print("id      {x:0>4}\n", .{read(.id)}) catch return;
    if (!speaks()) {
        w.print("nothing answering on {x:0>4}\n", .{INDEX}) catch {};
        return;
    }
    const on: Enable = @bitCast(read(.enable));
    w.print("mode    {d}x{d} at {d} bits\n", .{ read(.width), read(.height), read(.depth) }) catch {};
    w.print("stride  {d} pixels\n", .{read(.virtual_width)}) catch {};
    w.print("at      {d},{d}\n", .{ read(.x_offset), read(.y_offset) }) catch {};
    w.print("on      {}, linear {}\n", .{ on.on, on.linear }) catch {};
    w.print("pixels  {x:0>8}\n", .{aperture(dev) orelse 0}) catch {};
}

const testing = std.testing;

test "the plain VGA registers are the shape the hardware reads" {
    try testing.expectEqual(@as(u8, 0x20), @as(u8, @bitCast(Vga.Attribute{ .showing = true })));
    try testing.expectEqual(@as(u8, 0x20), @as(u8, @bitCast(Vga.Clocking{ .screen_off = true })));
    try testing.expectEqual(@as(u8, 0x03), @as(u8, @bitCast(Vga.Misc{
        .colour_addresses = true,
        .memory_enabled = true,
    })));
}

test "the enable register is the shape the interface reads" {
    try testing.expectEqual(@as(u16, 0x01), @as(u16, @bitCast(Enable{ .on = true })));
    try testing.expectEqual(@as(u16, 0x02), @as(u16, @bitCast(Enable{ .limits = true })));
    try testing.expectEqual(@as(u16, 0x20), @as(u16, @bitCast(Enable{ .wide_palette = true })));
    try testing.expectEqual(@as(u16, 0x40), @as(u16, @bitCast(Enable{ .linear = true })));
    try testing.expectEqual(@as(u16, 0x80), @as(u16, @bitCast(Enable{ .keep_pixels = true })));
    try testing.expectEqual(@as(u16, 0x41), @as(u16, @bitCast(Enable{ .on = true, .linear = true })));
    try testing.expectEqual(@as(u16, 0), @as(u16, @bitCast(Enable{})));
}

test "only the adapters that speak the interface are claimed" {
    const seen = struct {
        fn of(vendor: u16, device: u16) probe.Confidence {
            return fits(.{
                .bus = "pci",
                .location = .{ .bus = 0, .device = 2, .function = 0 },
                .vendor = vendor,
                .device = device,
                .class = 0x03,
                .subclass = 0x00,
                .prog_if = 0,
                .description = "display controller",
            });
        }
    }.of;

    try testing.expectEqual(probe.Confidence.exact, seen(0x1234, 0x1111));
    try testing.expectEqual(probe.Confidence.exact, seen(0x80EE, 0xBEEF));
    // The machine this is all for, which has its own backend.
    try testing.expectEqual(probe.Confidence.no, seen(0x8086, 0x2592));
    try testing.expectEqual(probe.Confidence.no, seen(0x1234, 0x1112));
}

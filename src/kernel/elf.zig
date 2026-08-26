//! Minimal 32-bit ELF loader.
//!
//! Handles exactly what a statically linked, non-relocatable executable needs:
//! walk the program headers and copy each PT_LOAD segment into the target
//! address space. No dynamic linking, no relocations, no interpreter, the
//! system links everything statically (design/00-vibeee.md §10.5), so those
//! cases cannot arise.
//!
//! Segment contents are written through the kernel's linear map rather than by
//! switching to the target address space, so loading never disturbs the
//! currently running process.

const std = @import("std");
const hal = @import("hal.zig");
const pmm = @import("pmm.zig");

pub const Error = error{
    NotElf,
    WrongClass,
    WrongMachine,
    NotExecutable,
    Malformed,
    OutOfMemory,
};

const ELF_MAGIC = "\x7fELF";

const ELFCLASS32 = 1;
const ELFDATA2LSB = 1;
const format = @import("lib").elf;

const Header = format.Header;
const ProgramHeader = format.ProgramHeader;

pub const Loaded = struct {
    entry: usize,
    /// Highest address used by any segment, rounded up to a page. Where a heap
    /// would start.
    brk: usize,
};

/// Load `image` into `space`. Returns the entry point.
pub fn load(space: *hal.AddressSpace, image: []const u8) Error!Loaded {
    if (image.len < @sizeOf(Header)) return error.NotElf;

    const hdr: *align(1) const Header = @ptrCast(image.ptr);
    if (!Header.identifies(image)) return error.NotElf;
    if (hdr.class != .bits32 or hdr.data != .little) return error.WrongClass;
    if (hdr.machine != .x86) return error.WrongMachine;
    if (hdr.type != .executable) return error.NotExecutable;
    if (hdr.phentsize != @sizeOf(ProgramHeader)) return error.Malformed;

    var brk: usize = 0;

    for (0..hdr.phnum) |i| {
        const off = hdr.phoff + i * @sizeOf(ProgramHeader);
        if (off + @sizeOf(ProgramHeader) > image.len) return error.Malformed;

        const ph: *align(1) const ProgramHeader = @ptrCast(image.ptr + off);
        if (ph.type != .load or ph.memsz == 0) continue;

        // A segment must not claim more file bytes than it has, nor extend into
        // the kernel half, a crafted header is otherwise a way to have the
        // kernel copy attacker bytes wherever it likes.
        if (ph.filesz > ph.memsz) return error.Malformed;
        if (ph.offset + ph.filesz > image.len) return error.Malformed;
        if (ph.vaddr >= hal.KERNEL_BASE) return error.Malformed;
        if (@as(u64, ph.vaddr) + ph.memsz > hal.KERNEL_BASE) return error.Malformed;

        try loadSegment(space, image, ph);

        const end = ph.vaddr + ph.memsz;
        if (end > brk) brk = end;
    }

    if (hdr.entry == 0 or hdr.entry >= hal.KERNEL_BASE) return error.Malformed;

    return .{
        .entry = hdr.entry,
        .brk = std.mem.alignForward(usize, brk, hal.PAGE_SIZE),
    };
}

fn loadSegment(space: *hal.AddressSpace, image: []const u8, ph: *align(1) const ProgramHeader) Error!void {
    const writable = ph.flags.writable;

    const first = std.mem.alignBackward(usize, ph.vaddr, hal.PAGE_SIZE);
    const last = std.mem.alignForward(usize, ph.vaddr + ph.memsz, hal.PAGE_SIZE);

    var page = first;
    while (page < last) : (page += hal.PAGE_SIZE) {
        const phys = pmm.allocFrame() catch return error.OutOfMemory;
        const dest: [*]u8 = @ptrFromInt(hal.physToVirt(phys));

        // Zero first: .bss is the part of memsz beyond filesz, and a page that
        // straddles the boundary needs both halves handled.
        @memset(dest[0..hal.PAGE_SIZE], 0);

        // Copy whatever part of this page the file actually covers.
        const page_start = page;
        const page_end = page + hal.PAGE_SIZE;
        const seg_file_end = ph.vaddr + ph.filesz;

        const copy_start = @max(page_start, ph.vaddr);
        const copy_end = @min(page_end, seg_file_end);
        if (copy_end > copy_start) {
            const src_off = ph.offset + (copy_start - ph.vaddr);
            const len = copy_end - copy_start;
            @memcpy(dest[copy_start - page_start ..][0..len], image[src_off..][0..len]);
        }

        try space.map(page, phys, .{ .writable = writable });
    }
}

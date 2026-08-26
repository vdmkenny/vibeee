//! file, what something is rather than what it is called.
//!
//! FAT has no type beyond the name, and a name is a claim rather than a fact:
//! anything can be called `.TXT`. What a file holds is decided by looking at
//! it, which is also the only way to tell a program built for this machine
//! from one built for another.

const sys = @import("sys");
const elf = @import("lib").elf;
const out = @import("ulib").out;
const str = @import("ulib").str;

/// Enough to reach every signature this recognises, and enough of a text file
/// to judge it by.
var head: [512]u8 = @splat(0);

pub fn run(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: file <path>...\n");
        out.flush();
        return;
    }

    for (args) |path| {
        out.pad(path, 14);
        describe(path);
        out.byte('\n');
    }
    out.flush();
}

fn describe(path: []const u8) void {
    // A directory opens only as one, which is the same question the kernel
    // would answer, asked the way a caller can.
    const dir = sys.open(path, .{ .directory = true });
    if (dir >= 0) {
        _ = sys.close(@intCast(dir));
        out.text("directory");
        return;
    }

    const handle = sys.open(path, .{});
    if (handle < 0) {
        out.text("cannot open");
        return;
    }
    defer _ = sys.close(@intCast(handle));

    const n = sys.read(@intCast(handle), &head);
    if (n <= 0) {
        out.text("empty");
        return;
    }
    classify(head[0..@intCast(n)]);
}

/// What a file starts with, for the kinds worth knowing on this machine.
const Signature = struct {
    magic: []const u8,
    name: []const u8,
};

const signatures = [_]Signature{
    .{ .magic = "EZI1", .name = "vibeee compressed rootfs" },
    .{ .magic = "PANC", .name = "vibeee panic record" },
    .{ .magic = "\x89PNG\r\n\x1a\n", .name = "png image" },
    .{ .magic = "\xFF\xD8\xFF", .name = "jpeg image" },
    .{ .magic = "BM", .name = "bmp image" },
    .{ .magic = "STARTFONT", .name = "bdf font" },
};

/// The signatures first, then the shape of the bytes.
fn classify(bytes: []const u8) void {
    if (elf.Header.identify(bytes)) |ident| return describeElf(ident);

    for (signatures) |sig| {
        if (str.startsWith(bytes, sig.magic)) return out.text(sig.name);
    }

    // A boot sector is a signature in the last two bytes of the first sector
    // rather than the first, which is why it is not one of the above.
    if (bytes.len >= 512 and bytes[510] == 0x55 and bytes[511] == 0xAA) {
        return out.text("boot sector");
    }

    out.text(if (looksLikeText(bytes)) "text" else "data");
}

/// Which machine an ELF file was built for, which is the part worth reporting:
/// a program for another architecture is one this cannot run, and is otherwise
/// indistinguishable from one it can.
fn describeElf(ident: elf.Ident) void {
    out.text("elf ");
    out.text(switch (ident.class) {
        .bits32 => "32-bit ",
        .bits64 => "64-bit ",
        else => "",
    });
    out.text(ident.machine.name());
    out.text(" program");
}

/// Whether the bytes read as text. Tab, newline and carriage return are the
/// only control characters a text file carries; a NUL settles it outright,
/// and anything else that is not printable counts against it.
fn looksLikeText(bytes: []const u8) bool {
    var odd: usize = 0;
    for (bytes) |b| {
        if (b == 0) return false;
        switch (b) {
            '\t', '\n', '\r' => {},
            // Printable ASCII, then anything a UTF-8 sequence is made of.
            0x20...0x7E, 0x80...0xFF => {},
            else => odd += 1,
        }
    }
    // A stray control byte in an otherwise readable file is still a text file;
    // a scattering of them is not.
    return odd * 32 <= bytes.len;
}

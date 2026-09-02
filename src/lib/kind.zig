//! What a file is.
//!
//! Two doors onto one answer, because the two questions a system asks are
//! not the same question. A listing drawing an icon per row asks about
//! hundreds of files while a cursor moves, and cannot afford a disk seek for
//! each: it asks the name. Something about to open a file, or report on one,
//! can afford to read it, and the bytes are the only thing that cannot lie:
//! FAT keeps no type, and anything at all can be called `.TXT`.
//!
//! Before this, the two doors were two answers: the shell's `file` read
//! bytes and the file manager read suffixes, and nothing made them agree
//! about what a picture was.
//!
//! Pure and host-tested. Nothing here opens anything; a caller brings either
//! a name or a mouthful of bytes.

const std = @import("std");
const elf = @import("elf.zig");

/// What sort of thing a kind is, for a caller that has to do something with
/// every file rather than only the ones it understands: a listing draws one
/// icon per family, whatever this build can actually open.
pub const Family = enum {
    directory,
    picture,
    text,
    program,
    archive,
    audio,
    video,
    font,
    document,
    /// This system's own formats, and a medium's own structure.
    system,
    /// Bytes with no shape this knows, and nothing at all.
    data,
};

/// What something is, at the grain the system acts on: which icon a listing
/// draws, which program opens it, whether a preview can show it.
///
/// Wider than what this build can open, on purpose. A machine that says
/// "data" about a file every other system calls a zip is a machine that
/// looks broken; naming it costs a few bytes of table and is the difference
/// between "I cannot open this" and "I have no idea what this is".
pub const Kind = enum {
    directory,
    /// Nothing in it, which is worth saying rather than guessing at.
    empty,
    /// Readable as words.
    text,
    /// Bytes with no shape this knows.
    data,

    // Pictures. The first four are the ones a decoder here opens.
    png,
    jpeg,
    bmp,
    gif,
    tiff,
    webp,
    icon,

    /// A program, for this machine or another. `Reading` says which.
    program,
    dos_program,
    java_class,

    // Things with other things inside them.
    zip,
    gzip,
    bzip2,
    xz,
    seven_zip,
    rar,
    tar,
    ar,
    /// The compressed root filesystem the loader carries.
    rootfs,

    // Sound and moving pictures, none of which this build plays or shows.
    wav,
    ogg,
    flac,
    mp3,
    midi,
    matroska,
    mp4,
    avi,

    font,
    opentype,
    web_font,

    pdf,
    hero,
    sqlite,

    /// The first sector of a medium something can boot from.
    boot_sector,
    /// A panic kept for the next boot.
    panic_record,
    /// Doom's data, which is on this machine and worth naming rather than
    /// reporting as bytes with no shape.
    wad,

    /// Whether a decoder in this build can be pointed at it. Narrower than
    /// the picture family: a TIFF is a picture nobody here can open.
    pub fn opens(self: Kind) bool {
        return switch (self) {
            .png, .jpeg, .bmp, .gif => true,
            else => false,
        };
    }

    /// Whether it can be shown as words.
    pub fn isText(self: Kind) bool {
        return self == .text;
    }

    /// What sort of thing it is, for a caller drawing one icon per file.
    pub fn family(self: Kind) Family {
        return switch (self) {
            .directory => .directory,
            .png, .jpeg, .bmp, .gif, .tiff, .webp, .icon => .picture,
            .text => .text,
            .program, .dos_program, .java_class => .program,
            .zip, .gzip, .bzip2, .xz, .seven_zip, .rar, .tar, .ar => .archive,
            .wav, .ogg, .flac, .mp3, .midi => .audio,
            .matroska, .mp4, .avi => .video,
            .font, .opentype, .web_font => .font,
            .pdf, .hero => .document,
            .rootfs, .panic_record, .boot_sector, .sqlite, .wad => .system,
            .data, .empty => .data,
        };
    }

    /// What to call it, in the words a person would use.
    pub fn says(self: Kind) []const u8 {
        return switch (self) {
            .directory => "directory",
            .empty => "empty",
            .text => "text",
            .data => "data",

            .png => "png image",
            .jpeg => "jpeg image",
            .bmp => "bmp image",
            .gif => "gif image",
            .tiff => "tiff image",
            .webp => "webp image",
            .icon => "icon image",

            .program => "program",
            .dos_program => "dos or windows program",
            .java_class => "java class",

            .zip => "zip archive",
            .gzip => "gzip stream",
            .bzip2 => "bzip2 stream",
            .xz => "xz stream",
            .seven_zip => "7z archive",
            .rar => "rar archive",
            .tar => "tar archive",
            .ar => "ar archive",
            .rootfs => "vibeee compressed rootfs",

            .wav => "wav sound",
            .ogg => "ogg stream",
            .flac => "flac sound",
            .mp3 => "mp3 sound",
            .midi => "midi score",
            .matroska => "matroska video",
            .mp4 => "mp4 video",
            .avi => "avi video",

            .font => "bdf font",
            .opentype => "opentype font",
            .web_font => "web font",

            .pdf => "pdf document",
            .hero => "character journal",
            .sqlite => "sqlite database",

            .boot_sector => "boot sector",
            .panic_record => "vibeee panic record",
            .wad => "doom data",
        };
    }
};

/// The kind, and whatever more the bytes gave up. A program is the one thing
/// here whose kind alone is not much use: what matters about it is whether
/// this machine can run it.
pub const Reading = struct {
    kind: Kind,
    /// Set when `kind` is `.program`.
    program: ?elf.Ident = null,

    /// The whole answer as a sentence, which is what a report wants and what
    /// a listing never asks for. Never longer than `SAYS_MAX`.
    pub fn says(self: Reading, into: *[SAYS_MAX]u8) []const u8 {
        const ident = self.program orelse return self.kind.says();

        // A program's class, machine and purpose, in that order, because the
        // machine is what decides whether it will run here.
        const width = switch (ident.class) {
            .bits32 => "32-bit ",
            .bits64 => "64-bit ",
            else => "",
        };
        const purpose = switch (ident.kind) {
            .relocatable => " object",
            .executable => " executable",
            .shared => " shared object",
            .core => " core dump",
            else => "",
        };
        return std.fmt.bufPrint(into, "elf {s}{s}{s}", .{
            width,
            ident.machine.name(),
            purpose,
        }) catch self.kind.says();
    }
};

/// Enough for the longest sentence `Reading.says` can build.
pub const SAYS_MAX: usize = 48;

// ---------------------------------------------------------------------------
// By the bytes
// ---------------------------------------------------------------------------

/// How much of a file is enough to know it. A boot sector's mark is in the
/// last two bytes of the first sector, which is the deepest anything here
/// looks.
pub const ENOUGH: usize = 512;

/// What a file is marked with. Most formats mark their front; a few mark a
/// little way in, and a few name their container at the front and what is
/// inside it a few bytes later.
const Signature = struct {
    magic: []const u8,
    kind: Kind,
    /// Where `magic` sits.
    at: usize = 0,
    /// A second mark that must also be there. What tells a wav from an avi:
    /// both are RIFF, and the four bytes at eight say which.
    then: ?[]const u8 = null,
    then_at: usize = 0,
};

/// Ordered so a container is only claimed once what is inside it has had its
/// chance: the RIFF and ISO-media forms come before anything that would
/// match their outer four bytes.
const signatures = [_]Signature{
    // This system's own.
    .{ .magic = "EZI1", .kind = .rootfs },
    .{ .magic = "PANC", .kind = .panic_record },

    // Pictures.
    .{ .magic = "\x89PNG\r\n\x1a\n", .kind = .png },
    .{ .magic = "\xFF\xD8\xFF", .kind = .jpeg },
    .{ .magic = "BM", .kind = .bmp },
    .{ .magic = "GIF8", .kind = .gif },
    .{ .magic = "II*\x00", .kind = .tiff },
    .{ .magic = "MM\x00*", .kind = .tiff },
    .{ .magic = "RIFF", .then = "WEBP", .then_at = 8, .kind = .webp },
    .{ .magic = "\x00\x00\x01\x00", .kind = .icon },

    // Programs this machine cannot run, which are worth telling apart from
    // bytes with no shape.
    .{ .magic = "MZ", .kind = .dos_program },
    .{ .magic = "\xCA\xFE\xBA\xBE", .kind = .java_class },

    // Things with other things inside them.
    .{ .magic = "PK\x03\x04", .kind = .zip },
    .{ .magic = "PK\x05\x06", .kind = .zip },
    .{ .magic = "\x1F\x8B", .kind = .gzip },
    .{ .magic = "BZh", .kind = .bzip2 },
    .{ .magic = "\xFD7zXZ\x00", .kind = .xz },
    .{ .magic = "7z\xBC\xAF\x27\x1C", .kind = .seven_zip },
    .{ .magic = "Rar!\x1A\x07", .kind = .rar },
    .{ .magic = "!<arch>\n", .kind = .ar },
    // A tar names itself two hundred and fifty-seven bytes in, which is why
    // a mouthful of a file rather than a handful is what this reads.
    .{ .magic = "ustar", .at = 257, .kind = .tar },

    // Sound and moving pictures.
    .{ .magic = "RIFF", .then = "WAVE", .then_at = 8, .kind = .wav },
    .{ .magic = "RIFF", .then = "AVI ", .then_at = 8, .kind = .avi },
    .{ .magic = "OggS", .kind = .ogg },
    .{ .magic = "fLaC", .kind = .flac },
    .{ .magic = "ID3", .kind = .mp3 },
    .{ .magic = "MThd", .kind = .midi },
    .{ .magic = "\x1A\x45\xDF\xA3", .kind = .matroska },
    .{ .magic = "ftyp", .at = 4, .kind = .mp4 },

    // Fonts.
    .{ .magic = "STARTFONT", .kind = .font },
    .{ .magic = "OTTO", .kind = .opentype },
    .{ .magic = "\x00\x01\x00\x00", .kind = .opentype },
    .{ .magic = "true", .kind = .opentype },
    .{ .magic = "wOFF", .kind = .web_font },
    .{ .magic = "wOF2", .kind = .web_font },

    // The rest.
    .{ .magic = "%PDF-", .kind = .pdf },
    .{ .magic = "hero 1", .kind = .hero },
    .{ .magic = "SQLite format 3\x00", .kind = .sqlite },
    .{ .magic = "IWAD", .kind = .wad },
    .{ .magic = "PWAD", .kind = .wad },
};

/// Whether `magic` is at `at`.
fn marked(bytes: []const u8, magic: []const u8, at: usize) bool {
    if (bytes.len < at + magic.len) return false;
    return std.mem.eql(u8, bytes[at..][0..magic.len], magic);
}

/// What the bytes say it is. The certain door: give it the first `ENOUGH`
/// bytes of the file, or all of it when it is shorter.
pub fn fromBytes(bytes: []const u8) Reading {
    if (bytes.len == 0) return .{ .kind = .empty };

    if (elf.Header.identify(bytes)) |ident| {
        return .{ .kind = .program, .program = ident };
    }

    for (signatures) |signature| {
        if (!marked(bytes, signature.magic, signature.at)) continue;
        if (signature.then) |second| {
            if (!marked(bytes, second, signature.then_at)) continue;
        }
        return .{ .kind = signature.kind };
    }

    // A boot sector is marked in the last two bytes of its first sector
    // rather than the first, which is why it is not one of the above.
    if (bytes.len >= 512 and bytes[510] == 0x55 and bytes[511] == 0xAA) {
        return .{ .kind = .boot_sector };
    }

    return .{ .kind = if (looksLikeText(bytes)) .text else .data };
}

/// Whether the bytes read as words. Tab, newline and carriage return are the
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
    // A stray control byte in an otherwise readable file is still a text
    // file; a scattering of them is not.
    return odd * 32 <= bytes.len;
}

// ---------------------------------------------------------------------------
// By the name
// ---------------------------------------------------------------------------

/// The suffixes worth knowing, folded for case: a volume written on another
/// machine holds `README.TXT` as readily as `readme.txt`.
///
/// Lists rather than rules, because there is no rule: `notes.zig` is text and
/// `notes.bin` is not, and nothing about either name says why.
const suffixes = [_]struct { suffix: []const u8, kind: Kind }{
    .{ .suffix = "png", .kind = .png },
    .{ .suffix = "jpg", .kind = .jpeg },
    .{ .suffix = "jpeg", .kind = .jpeg },
    .{ .suffix = "bmp", .kind = .bmp },
    .{ .suffix = "gif", .kind = .gif },
    .{ .suffix = "wad", .kind = .wad },
    .{ .suffix = "bdf", .kind = .font },
    .{ .suffix = "hero", .kind = .hero },

    .{ .suffix = "txt", .kind = .text },
    .{ .suffix = "md", .kind = .text },
    .{ .suffix = "zig", .kind = .text },
    .{ .suffix = "c", .kind = .text },
    .{ .suffix = "h", .kind = .text },
    .{ .suffix = "cfg", .kind = .text },
    .{ .suffix = "conf", .kind = .text },
    .{ .suffix = "log", .kind = .text },
    .{ .suffix = "json", .kind = .text },
    .{ .suffix = "asm", .kind = .text },
    .{ .suffix = "s", .kind = .text },
    .{ .suffix = "sh", .kind = .text },
    .{ .suffix = "man", .kind = .text },
    .{ .suffix = "ini", .kind = .text },
    .{ .suffix = "csv", .kind = .text },
    .{ .suffix = "html", .kind = .text },
};

/// What the name says it is, or null when the name says nothing. The cheap
/// door: no seek, no read, and wrong whenever somebody has misnamed a file,
/// which is why anything that can afford to read uses `fromBytes` instead.
pub fn fromName(name: []const u8) ?Kind {
    const dot = std.mem.lastIndexOfScalar(u8, name, '.') orelse return null;
    const suffix = name[dot + 1 ..];
    if (suffix.len == 0) return null;

    for (suffixes) |known| {
        if (std.ascii.eqlIgnoreCase(suffix, known.suffix)) return known.kind;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn elfBytes(class: elf.Class, machine: elf.Machine, kind: elf.Type) [elf.IDENT_LEN]u8 {
    var image: [elf.IDENT_LEN]u8 = @splat(0);
    @memcpy(image[0..4], "\x7fELF");
    image[4] = @intFromEnum(class);
    image[5] = @intFromEnum(elf.Data.little);
    std.mem.writeInt(u16, image[16..18], @intFromEnum(kind), .little);
    std.mem.writeInt(u16, image[18..20], @intFromEnum(machine), .little);
    return image;
}

test "a program says which machine it is for and what it is" {
    var room: [SAYS_MAX]u8 = undefined;

    const ours = elfBytes(.bits32, .x86, .executable);
    const reading = fromBytes(&ours);
    try std.testing.expectEqual(Kind.program, reading.kind);
    try std.testing.expectEqualStrings("elf 32-bit x86 executable", reading.says(&room));

    // One this machine cannot run reads as plainly as one it can, which is
    // the whole reason the machine is named.
    const theirs = elfBytes(.bits64, .aarch64, .shared);
    try std.testing.expectEqualStrings("elf 64-bit aarch64 shared object", fromBytes(&theirs).says(&room));

    const object = elfBytes(.bits32, .arm, .relocatable);
    try std.testing.expectEqualStrings("elf 32-bit arm object", fromBytes(&object).says(&room));
}

test "the signatures are read from the front" {
    try std.testing.expectEqual(Kind.png, fromBytes("\x89PNG\r\n\x1a\nrest").kind);
    try std.testing.expectEqual(Kind.jpeg, fromBytes("\xFF\xD8\xFF\xE0more").kind);
    try std.testing.expectEqual(Kind.bmp, fromBytes("BM and the rest").kind);
    try std.testing.expectEqual(Kind.gif, fromBytes("GIF89a").kind);
    try std.testing.expectEqual(Kind.wad, fromBytes("IWAD\x00\x00").kind);
    try std.testing.expectEqual(Kind.rootfs, fromBytes("EZI1....").kind);
}

test "the containers are told apart by what is inside them" {
    // Three formats share the same first four bytes; the four at eight say
    // which of them it is, and RIFF alone is none of them.
    try std.testing.expectEqual(Kind.wav, fromBytes("RIFF\x00\x00\x00\x00WAVEfmt ").kind);
    try std.testing.expectEqual(Kind.avi, fromBytes("RIFF\x00\x00\x00\x00AVI LIST").kind);
    try std.testing.expectEqual(Kind.webp, fromBytes("RIFF\x00\x00\x00\x00WEBPVP8 ").kind);
    try std.testing.expectEqual(Kind.data, fromBytes("RIFF\x00\x00\x00\x00WHAT????").kind);
}

test "a mark a little way in is still a mark" {
    // A tar says so two hundred and fifty-seven bytes in and nowhere else.
    var tape: [512]u8 = @splat(0);
    @memcpy(tape[0..9], "notes.txt");
    @memcpy(tape[257..262], "ustar");
    try std.testing.expectEqual(Kind.tar, fromBytes(&tape).kind);

    // ISO media names its brand at four.
    try std.testing.expectEqual(Kind.mp4, fromBytes("\x00\x00\x00\x18ftypmp42").kind);
}

test "formats this build cannot open are still named" {
    try std.testing.expectEqual(Kind.zip, fromBytes("PK\x03\x04rest").kind);
    try std.testing.expectEqual(Kind.gzip, fromBytes("\x1F\x8B\x08\x00").kind);
    try std.testing.expectEqual(Kind.pdf, fromBytes("%PDF-1.4").kind);
    try std.testing.expectEqual(Kind.hero, fromBytes("hero 1\nname cinaed").kind);
    try std.testing.expectEqual(Kind.sqlite, fromBytes("SQLite format 3\x00rest").kind);
    try std.testing.expectEqual(Kind.dos_program, fromBytes("MZ\x90\x00").kind);
    try std.testing.expectEqual(Kind.matroska, fromBytes("\x1A\x45\xDF\xA3rest").kind);
    try std.testing.expectEqual(Kind.opentype, fromBytes("OTTOrest").kind);

    // Named, and still not something to point a decoder at.
    try std.testing.expect(!Kind.tiff.opens());
    try std.testing.expectEqual(Family.picture, Kind.tiff.family());
    try std.testing.expectEqual(Family.archive, Kind.zip.family());
    try std.testing.expectEqual(Family.audio, Kind.flac.family());
}

test "every kind belongs to a family and says something" {
    for (std.enums.values(Kind)) |one| {
        _ = one.family();
        try std.testing.expect(one.says().len > 0);
    }
}

test "a boot sector is known by its last two bytes, not its first" {
    var sector: [512]u8 = @splat(0);
    sector[510] = 0x55;
    sector[511] = 0xAA;
    try std.testing.expectEqual(Kind.boot_sector, fromBytes(&sector).kind);

    // The same mark inside a shorter run is not one.
    try std.testing.expectEqual(Kind.data, fromBytes(sector[0..64]).kind);
}

test "words are text and bytes are data" {
    try std.testing.expectEqual(Kind.text, fromBytes("hello\nthere\t42\r\n").kind);
    try std.testing.expectEqual(Kind.data, fromBytes("\x01\x02\x03\x04\x05\x06").kind);
    // A NUL settles it whatever else is there.
    try std.testing.expectEqual(Kind.data, fromBytes("readable except\x00for this").kind);
    try std.testing.expectEqual(Kind.empty, fromBytes("").kind);
}

test "the name is read folded, and says nothing when it says nothing" {
    try std.testing.expectEqual(@as(?Kind, .png), fromName("holiday.PNG"));
    try std.testing.expectEqual(@as(?Kind, .jpeg), fromName("a.b.jpeg"));
    try std.testing.expectEqual(@as(?Kind, .text), fromName("README.TXT"));
    try std.testing.expectEqual(@as(?Kind, null), fromName("makefile"));
    try std.testing.expectEqual(@as(?Kind, null), fromName("archive."));
    try std.testing.expectEqual(@as(?Kind, null), fromName("photo.raw"));
}

test "the two doors agree wherever both can answer" {
    try std.testing.expect(fromName("x.png").?.opens());
    try std.testing.expect(fromBytes("\x89PNG\r\n\x1a\n").kind.opens());
    try std.testing.expect(fromName("notes.txt").?.isText());
    try std.testing.expect(fromBytes("notes").kind.isText());
}

test "a kind says what it is, and a reading with no more to add says the same" {
    var room: [SAYS_MAX]u8 = undefined;
    try std.testing.expectEqualStrings("png image", fromBytes("\x89PNG\r\n\x1a\n").says(&room));
    try std.testing.expectEqualStrings("text", fromBytes("words").says(&room));
    try std.testing.expectEqualStrings("empty", fromBytes("").says(&room));
}

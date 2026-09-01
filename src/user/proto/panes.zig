//! What the Settings window is divided into.
//!
//! Here rather than inside that program because two things need the list: the
//! program, which draws a rail of them, and the launcher, which offers each
//! one by name so somebody looking for the wallpaper can type "display"
//! instead of opening Settings and hunting. A second list in the launcher
//! would be a list that goes stale the first time a section is added.
//!
//! The names are the words on the rail, and the same words the program
//! accepts on its command line, so `settings audio` and the launcher's Audio
//! entry are the same request.

const std = @import("std");
const icons = @import("eui").icon;

pub const Section = enum {
    display,
    input,
    audio,
    power,
    help,
    about,

    pub fn parse(name: []const u8) ?Section {
        for (std.enums.values(Section)) |which| {
            if (std.mem.eql(u8, which.title(), name) or std.mem.eql(u8, @tagName(which), name)) return which;
        }
        return null;
    }

    pub fn title(self: Section) []const u8 {
        return switch (self) {
            .display => "Display",
            .input => "Input",
            .audio => "Audio",
            .power => "Power",
            .help => "Help",
            .about => "About",
        };
    }

    /// The picture on the rail, and beside the launcher's entry for it.
    pub fn icon(self: Section) icons.Icon {
        return switch (self) {
            .display => .display,
            .input => .keyboard,
            .audio => .speaker,
            .power => .battery,
            .help => .help,
            .about => .about,
        };
    }

    /// What to say the entry is, where a bare section name would not be
    /// enough on its own: "Help" in a list of programs says nothing about
    /// what it is help with.
    pub fn says(self: Section) []const u8 {
        return switch (self) {
            .display => "Display",
            .input => "Keyboard and input",
            .audio => "Sound",
            .power => "Battery and power",
            .help => "Keyboard shortcuts",
            .about => "About this computer",
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "a section is found by its own name and by the word on the rail" {
    try testing.expectEqual(@as(?Section, .audio), Section.parse("audio"));
    try testing.expectEqual(@as(?Section, .audio), Section.parse("Audio"));
    try testing.expectEqual(@as(?Section, .about), Section.parse("About"));
    try testing.expectEqual(@as(?Section, null), Section.parse("nothing"));
}

test "every section says something and says it once" {
    for (std.enums.values(Section)) |which| {
        try testing.expect(which.title().len > 0);
        try testing.expect(which.says().len > 0);
    }

    // Two entries in a launcher that read the same are two entries nobody can
    // choose between.
    for (std.enums.values(Section)) |a| {
        for (std.enums.values(Section)) |b| {
            if (a == b) continue;
            try testing.expect(!std.mem.eql(u8, a.says(), b.says()));
        }
    }
}

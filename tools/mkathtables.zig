//! Transcribes the AR5212 family's register tables from the pinned
//! reference into a Zig source file.
//!
//! The tables are the reverse-engineered heart of the radio: which register
//! takes which value in which mode, and what the analog banks hold. They are
//! data, not code, and the one thing worse than carrying them is typing
//! them: a digit wrong in a bank value programs the radio blind with no way
//! to tell. So they are read out of the reference's own C initialiser file
//! by this program, run by `make athtables`, and the generated file is never
//! edited by hand. The reference's pin is recorded in third_party/ath_hal.
//!
//! Only the tables the driver uses are emitted, and each is checked for the
//! column count the driver expects, so a reference revision that reshapes
//! a table is noticed here rather than on the machine.

const std = @import("std");

const MAX_COLUMNS = 6;

/// One C array as the reference declares it: `static const uint32_t
/// name[][columns] = { { ... }, ... };`.
const Table = struct {
    name: []const u8,
    columns: usize,
    rows: std.ArrayList([MAX_COLUMNS]u32) = .empty,
};

/// What the driver wants each table as.
const Kind = enum {
    /// A register and one value per mode column.
    mode,
    /// A register and one value.
    common,
    /// A register and one value per band.
    gain,
};

const Wanted = struct {
    source: []const u8,
    group: []const u8,
    field: []const u8,
    kind: Kind,
};

/// The generic tables every radio of the family is written with, then the
/// ones for the radios this system drives.
const WANTED = [_]Wanted{
    .{ .source = "ar5212Modes", .group = "family", .field = "modes", .kind = .mode },
    .{ .source = "ar5212Common", .group = "family", .field = "common", .kind = .common },
    .{ .source = "ar5212Modes_2425", .group = "rf2425", .field = "modes", .kind = .mode },
    .{ .source = "ar5212Common_2425", .group = "rf2425", .field = "common", .kind = .common },
    .{ .source = "ar5212BB_RfGain_2425", .group = "rf2425", .field = "gain", .kind = .gain },
    .{ .source = "ar5212Bank1_2425", .group = "rf2425", .field = "bank1", .kind = .common },
    .{ .source = "ar5212Bank2_2425", .group = "rf2425", .field = "bank2", .kind = .mode },
    .{ .source = "ar5212Bank3_2425", .group = "rf2425", .field = "bank3", .kind = .mode },
    .{ .source = "ar5212Bank6_2425", .group = "rf2425", .field = "bank6", .kind = .mode },
    .{ .source = "ar5212Bank7_2425", .group = "rf2425", .field = "bank7", .kind = .mode },
    .{ .source = "ar5212Bank6_2417", .group = "rf2417", .field = "bank6", .kind = .mode },
};

const GROUPS = [_][]const u8{ "family", "rf2425", "rf2417" };

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const cwd = std.Io.Dir.cwd();

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        std.debug.print("usage: mkathtables <ar5212.ini> <out.zig>\n", .{});
        return error.Usage;
    }

    const source = try cwd.readFileAlloc(io, args[1], gpa, .limited(4 << 20));
    defer gpa.free(source);

    var tables: std.ArrayList(Table) = .empty;
    defer {
        for (tables.items) |*t| t.rows.deinit(gpa);
        tables.deinit(gpa);
    }
    try parse(gpa, source, &tables);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try emit(gpa, &out, tables.items, std.fs.path.basename(args[1]));
    try cwd.writeFile(io, .{ .sub_path = args[2], .data = out.items });

    std.debug.print("{s}: {d} tables read, {d} written\n", .{ args[1], tables.items.len, WANTED.len });
}

/// Read every array in the file. The preprocessor conditionals around them
/// are ignored: a table is wanted by name, whatever build it was meant for.
fn parse(gpa: std.mem.Allocator, source: []const u8, tables: *std.ArrayList(Table)) !void {
    const DECLARATION = "static const uint32_t ";
    var current: ?*Table = null;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, DECLARATION)) {
            const rest = line[DECLARATION.len..];
            const open = std.mem.indexOfScalar(u8, rest, '[') orelse return error.BadDeclaration;
            const name = rest[0..open];
            // `[][N]`: the row count is left to the initialiser, the column
            // count is written.
            const second = std.mem.indexOfScalarPos(u8, rest, open + 2, '[') orelse return error.BadDeclaration;
            const close = std.mem.indexOfScalarPos(u8, rest, second, ']') orelse return error.BadDeclaration;
            const columns = try std.fmt.parseInt(usize, rest[second + 1 .. close], 10);
            if (columns == 0 or columns > MAX_COLUMNS) return error.BadDeclaration;
            try tables.append(gpa, .{ .name = name, .columns = columns });
            current = &tables.items[tables.items.len - 1];
            continue;
        }
        const table = current orelse continue;
        if (std.mem.startsWith(u8, line, "};")) {
            current = null;
            continue;
        }
        if (line.len == 0 or line[0] != '{') continue;

        var row: [MAX_COLUMNS]u32 = @splat(0);
        var count: usize = 0;
        var it = std.mem.tokenizeAny(u8, line, "{}, \t");
        while (it.next()) |token| {
            if (count == MAX_COLUMNS) return error.RowTooWide;
            row[count] = try std.fmt.parseInt(u32, token, 0);
            count += 1;
        }
        if (count != table.columns) return error.RowWidth;
        try table.rows.append(gpa, row);
    }
}

fn find(tables: []const Table, name: []const u8) ?*const Table {
    for (tables) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return null;
}

fn emit(gpa: std.mem.Allocator, out: *std.ArrayList(u8), tables: []const Table, source_name: []const u8) !void {
    try out.print(gpa,
        \\//! The AR5212 family's register tables, transcribed from {s} in the
        \\//! pinned reference by `make athtables`. Do not edit.
        \\//!
        \\//! Each row is a register and what to write there. A mode row carries
        \\//! one value per mode column, a common row one value, a gain row one
        \\//! per band; the analog banks are mode rows whose register is the
        \\//! bank's shift register. The pin the numbers came from is recorded in
        \\//! third_party/ath_hal/COMMIT.
        \\
        \\/// The mode columns, in the reference's order.
        \\pub const Mode = enum(u3) {{ a = 0, turbo = 1, b = 2, g = 3, turbo_g = 4 }};
        \\
        \\/// The band columns of a gain table.
        \\pub const Band = enum(u1) {{ ghz5 = 0, ghz2 = 1 }};
        \\
        \\pub const ModeRow = struct {{
        \\    register: u16,
        \\    values: [5]u32,
        \\
        \\    pub fn value(self: ModeRow, mode: Mode) u32 {{
        \\        return self.values[@intFromEnum(mode)];
        \\    }}
        \\}};
        \\
        \\pub const CommonRow = struct {{
        \\    register: u16,
        \\    value: u32,
        \\}};
        \\
        \\pub const GainRow = struct {{
        \\    register: u16,
        \\    values: [2]u32,
        \\
        \\    pub fn value(self: GainRow, band: Band) u32 {{
        \\        return self.values[@intFromEnum(band)];
        \\    }}
        \\}};
        \\
    , .{source_name});

    for (GROUPS) |group| {
        try out.print(gpa, "\npub const {s} = struct {{\n", .{group});
        for (WANTED) |want| {
            if (!std.mem.eql(u8, want.group, group)) continue;
            const table = find(tables, want.source) orelse {
                std.debug.print("{s}: table {s} is not in the reference\n", .{ source_name, want.source });
                return error.MissingTable;
            };
            const expected: usize = switch (want.kind) {
                .mode => 6,
                .common => 2,
                .gain => 3,
            };
            if (table.columns != expected) {
                std.debug.print("{s}: table {s} has {d} columns, the driver expects {d}\n", .{ source_name, want.source, table.columns, expected });
                return error.TableShape;
            }
            const row_type = switch (want.kind) {
                .mode => "ModeRow",
                .common => "CommonRow",
                .gain => "GainRow",
            };
            try out.print(gpa, "    /// {s}: {d} rows.\n    pub const {s} = [_]{s}{{\n", .{ want.source, table.rows.items.len, want.field, row_type });
            for (table.rows.items) |row| {
                if (row[0] > std.math.maxInt(u16)) return error.RegisterOutOfRange;
                switch (want.kind) {
                    .common => try out.print(gpa, "        .{{ .register = 0x{x:0>4}, .value = 0x{x:0>8} }},\n", .{ row[0], row[1] }),
                    .mode => try out.print(gpa, "        .{{ .register = 0x{x:0>4}, .values = .{{ 0x{x:0>8}, 0x{x:0>8}, 0x{x:0>8}, 0x{x:0>8}, 0x{x:0>8} }} }},\n", .{ row[0], row[1], row[2], row[3], row[4], row[5] }),
                    .gain => try out.print(gpa, "        .{{ .register = 0x{x:0>4}, .values = .{{ 0x{x:0>8}, 0x{x:0>8} }} }},\n", .{ row[0], row[1], row[2] }),
                }
            }
            try out.appendSlice(gpa, "    };\n");
        }
        try out.appendSlice(gpa, "};\n");
    }
}

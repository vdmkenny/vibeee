//! The menu editor behind `make menuconfig`: the menus entered, the cursor,
//! the dialog open, what each key does, and drawing all of it the way Linux's
//! menuconfig does. The terminal and files belong to the tool, which acts on
//! the `Effect` a key returns.

const std = @import("std");
const lib = @import("lib");
const options = @import("options.zig");
const dotconfig = @import("dotconfig.zig");
const screen_mod = @import("screen.zig");
const Key = @import("keys.zig").Key;

const Config = options.Config;
const Option = options.Option;
const Screen = screen_mod.Screen;
const Rect = screen_mod.Rect;
const Style = screen_mod.Style;
const Writer = std.Io.Writer;

/// The smallest terminal the layout fits, as Linux's menuconfig requires.
pub const MIN_COLS = 80;
pub const MIN_ROWS = 19;

const MAX_DEPTH = 8;
const MAX_ROWS = 64;

/// A line being typed: a value, a file name, a search.
pub const Field = lib.Bounded(u8, 255);

/// What the tool does after a key.
pub const Effect = union(enum) {
    none,
    /// Write the configuration to the file, then call `saved`.
    save: []const u8,
    /// Read a configuration from the file, then call `loaded`.
    load: []const u8,
    /// Leave without saving.
    quit,
    /// Write the configuration to the file, then leave.
    save_and_quit: []const u8,
};

pub const Button = enum { select, exit, help, save, load };

/// One line of a menu.
pub const Row = struct {
    item: Item,
    /// How many options this one sits under within its menu.
    depth: u8,

    pub const Item = union(enum) {
        option: Option,
        menu: *const options.Menu,
    };

    fn prompt(self: Row) []const u8 {
        return switch (self.item) {
            .option => |option| options.about(option).prompt,
            .menu => |menu| menu.title,
        };
    }

    /// The option a row sets: its own, or its menu's toggle.
    fn setting(self: Row) ?Option {
        return switch (self.item) {
            .option => |one| one,
            .menu => |menu| menu.toggle,
        };
    }
};

pub const Rows = lib.Bounded(Row, MAX_ROWS);

/// The rows of `menu` as `config` offers them.
pub fn rowsOf(config: *const Config, menu: *const options.Menu) Rows {
    var rows: Rows = .{};
    addRows(config, menu.entries, 0, &rows);
    return rows;
}

fn addRows(config: *const Config, entries: []const options.Entry, depth: u8, rows: *Rows) void {
    for (entries) |*entry| switch (entry.*) {
        .option => |nested| {
            if (!options.offered(config, nested.option)) continue;
            rows.append(.{ .item = .{ .option = nested.option }, .depth = depth }) catch return;
            const value = options.get(config, nested.option);
            if (value == .flag and value.flag) addRows(config, nested.under, depth + 1, rows);
        },
        .menu => |*menu| {
            if (menu.toggle) |toggle| {
                if (!options.offered(config, toggle)) continue;
            }
            rows.append(.{ .item = .{ .menu = menu }, .depth = depth }) catch return;
        },
    };
}

/// The letter a row answers to: the first letter of its prompt that is not a
/// command key.
fn hotkey(prompt: []const u8) ?usize {
    for (prompt, 0..) |c, at| {
        if (!std.ascii.isAlphabetic(c)) continue;
        if (std.mem.indexOfScalar(u8, "YyNnHh", c) == null) return at;
    }
    return null;
}

const Level = struct {
    menu: *const options.Menu,
    cursor: usize = 0,
    /// The first row shown.
    top: usize = 0,
};

/// What a line being typed is for.
const Purpose = union(enum) {
    value: Option,
    save,
    load,
    search,
};

const Dialog = union(enum) {
    text: Text,
    choice: Choice,
    input: Input,
    /// Leaving with unsaved changes: save first?
    leave: Answer,
    message: []const u8,
};

/// A scrolling text: help, or search results.
const Text = struct {
    title: []const u8,
    body: Page,
    scroll: usize = 0,
    /// The choice list help was opened from, to go back to.
    back: ?Choice = null,
};

const Choice = struct { option: Option, cursor: usize };

const Input = struct {
    purpose: Purpose,
    field: Field,
    cursor: usize,
    /// Where Tab has moved to, off the field.
    on_buttons: ?enum { ok, help } = null,
};

const Answer = enum { yes, no };

/// Room for help and search results.
const Page = lib.Bounded(u8, 8192);

fn writeText(text: []const u8, out: *Writer) Writer.Error!void {
    try out.writeAll(text);
}

/// What `write` writes to a writer, its last argument, as a page.
fn pageOf(comptime write: anytype, args: anytype) Page {
    var page: Page = .{};
    var out: Writer = .fixed(&page.items);
    @call(.auto, write, args ++ .{&out}) catch {};
    page.len = out.end;
    return page;
}

pub const Editor = struct {
    config: Config,
    /// As last loaded or saved.
    saved: Config,
    /// Where Save and Load start from.
    path: Field = .{},
    levels: [MAX_DEPTH]Level = undefined,
    depth: usize = 0,
    button: Button = .select,
    /// The first Escape of Escape Escape.
    escaped: bool = false,
    dialog: ?Dialog = null,
    /// Rows the list showed when last drawn, for paging.
    page: usize = 10,

    pub fn init(config: Config, path: []const u8) Editor {
        var editor: Editor = .{ .config = config, .saved = config };
        _ = editor.path.set(path);
        editor.levels[0] = .{ .menu = &options.root };
        return editor;
    }

    fn here(self: *Editor) *Level {
        return &self.levels[self.depth];
    }

    pub fn changed(self: *const Editor) bool {
        return !self.config.eql(&self.saved);
    }

    /// The tool wrote the configuration.
    pub fn wasSaved(self: *Editor) void {
        self.saved = self.config;
    }

    /// The tool read a configuration.
    pub fn wasLoaded(self: *Editor, config: Config) void {
        self.config = config;
        self.saved = config;
        self.depth = 0;
        self.levels[0] = .{ .menu = &options.root };
    }

    /// The tool could not do what it was asked.
    pub fn failed(self: *Editor, message: []const u8) void {
        self.dialog = .{ .message = message };
    }

    pub fn press(self: *Editor, pressed: Key) Effect {
        if (pressed == .interrupt) return .quit;
        if (pressed == .escape) {
            if (!self.escaped) {
                self.escaped = true;
                return .none;
            }
            self.escaped = false;
            return self.back();
        }
        self.escaped = false;
        if (self.dialog) |*dialog| return self.pressInDialog(dialog, pressed);
        return self.pressInList(pressed);
    }

    /// Escape Escape, or Exit: close the dialog, leave the menu, or leave.
    fn back(self: *Editor) Effect {
        if (self.dialog) |dialog| {
            self.dialog = switch (dialog) {
                .text => |text| if (text.back) |choice| .{ .choice = choice } else null,
                else => null,
            };
            return .none;
        }
        if (self.depth > 0) {
            self.depth -= 1;
            self.button = .select;
            return .none;
        }
        if (!self.changed()) return .quit;
        self.dialog = .{ .leave = .yes };
        return .none;
    }

    fn pressInList(self: *Editor, pressed: Key) Effect {
        const rows = rowsOf(&self.config, self.here().menu);
        const cursor = &self.here().cursor;
        cursor.* = @min(cursor.*, rows.len -| 1);
        switch (pressed) {
            .up => cursor.* -|= 1,
            .down => cursor.* = @min(cursor.* + 1, rows.len -| 1),
            .page_up => cursor.* -|= self.page,
            .page_down => cursor.* = @min(cursor.* + self.page, rows.len -| 1),
            .home => cursor.* = 0,
            .end => cursor.* = rows.len -| 1,
            .tab, .right => self.button = cycle(Button, self.button, 1),
            .back_tab, .left => self.button = cycle(Button, self.button, -1),
            .enter => return self.activate(rows),
            .char => |c| switch (c) {
                ' ' => self.toggleOrOpen(rows, false),
                'y', 'Y' => self.setFlag(rows, true),
                'n', 'N' => self.setFlag(rows, false),
                '?', 'h', 'H' => self.openHelp(rows),
                '/' => self.openInput(.search, ""),
                else => self.jump(rows, c),
            },
            else => {},
        }
        return .none;
    }

    fn activate(self: *Editor, rows: Rows) Effect {
        switch (self.button) {
            .select => self.toggleOrOpen(rows, true),
            .exit => return self.back(),
            .help => self.openHelp(rows),
            .save => self.openInput(.save, self.path.slice()),
            .load => self.openInput(.load, self.path.slice()),
        }
        return .none;
    }

    fn current(self: *Editor, rows: Rows) ?Row {
        return rows.at(self.here().cursor);
    }

    /// Space toggles an option or opens what it holds; Enter also enters a
    /// menu that is an option.
    fn toggleOrOpen(self: *Editor, rows: Rows, enter: bool) void {
        const row = self.current(rows) orelse return;
        switch (row.item) {
            .menu => |menu| {
                if (menu.toggle) |toggle| {
                    if (!enter) return self.flip(toggle);
                    if (!options.get(&self.config, toggle).flag) return;
                }
                if (self.depth + 1 == MAX_DEPTH) return;
                self.depth += 1;
                self.levels[self.depth] = .{ .menu = menu };
                self.button = .select;
            },
            .option => |option| switch (options.kindOf(option)) {
                .flag => self.flip(option),
                .choice => self.dialog = .{ .choice = .{ .option = option, .cursor = options.get(&self.config, option).choice } },
                .number => {
                    var digits: [10]u8 = undefined;
                    self.openInput(.{ .value = option }, std.fmt.bufPrint(&digits, "{d}", .{options.get(&self.config, option).number}) catch unreachable);
                },
                .text => self.openInput(.{ .value = option }, options.get(&self.config, option).text),
            },
        }
    }

    fn flip(self: *Editor, option: Option) void {
        _ = options.set(&self.config, option, .{ .flag = !options.get(&self.config, option).flag });
    }

    fn setFlag(self: *Editor, rows: Rows, on: bool) void {
        const option = (self.current(rows) orelse return).setting() orelse return;
        if (options.kindOf(option) == .flag) _ = options.set(&self.config, option, .{ .flag = on });
    }

    /// Move to the next row whose hotkey is `c`, wrapping.
    fn jump(self: *Editor, rows: Rows, c: u21) void {
        if (c > 0x7f) return;
        const wanted = std.ascii.toLower(@intCast(c));
        const start = self.here().cursor;
        for (1..rows.len + 1) |step| {
            const at = (start + step) % rows.len;
            const prompt = rows.slice()[at].prompt();
            const key_at = hotkey(prompt) orelse continue;
            if (std.ascii.toLower(prompt[key_at]) == wanted) {
                self.here().cursor = at;
                return;
            }
        }
    }

    fn openInput(self: *Editor, purpose: Purpose, initial: []const u8) void {
        var field: Field = .{};
        _ = field.set(initial);
        self.dialog = .{ .input = .{ .purpose = purpose, .field = field, .cursor = field.len } };
    }

    fn openHelp(self: *Editor, rows: Rows) void {
        const row = self.current(rows) orelse return;
        const option = row.setting() orelse {
            self.dialog = .{ .text = .{ .title = row.prompt(), .body = pageOf(writeText, .{"There is no help available for this option."}) } };
            return;
        };
        self.openHelpFor(option);
    }

    fn pressInDialog(self: *Editor, dialog: *Dialog, pressed: Key) Effect {
        switch (dialog.*) {
            .text => |*text| switch (pressed) {
                .up => text.scroll -|= 1,
                .down => text.scroll += 1,
                .page_up => text.scroll -|= self.page,
                .page_down => text.scroll += self.page,
                .home => text.scroll = 0,
                .enter => return self.back(),
                .char => |c| if (c == 'q' or c == 'e' or c == 'x') return self.back(),
                else => {},
            },
            .message => if (pressed == .enter or pressed == .char) {
                self.dialog = null;
            },
            .leave => |*answer| switch (pressed) {
                .tab, .back_tab, .left, .right => answer.* = if (answer.* == .yes) .no else .yes,
                .char => |c| switch (c) {
                    'y', 'Y' => return self.leave(.yes),
                    'n', 'N' => return self.leave(.no),
                    else => {},
                },
                .enter => return self.leave(answer.*),
                else => {},
            },
            .choice => |*choice| {
                const count = options.choices(choice.option).len;
                switch (pressed) {
                    .up => choice.cursor -|= 1,
                    .down => choice.cursor = @min(choice.cursor + 1, count - 1),
                    .home => choice.cursor = 0,
                    .end => choice.cursor = count - 1,
                    .enter => self.choose(choice.*),
                    .char => |c| switch (c) {
                        ' ' => self.choose(choice.*),
                        '?', 'h', 'H' => {
                            const one = options.choices(choice.option)[choice.cursor];
                            self.dialog = .{ .text = .{ .title = one.prompt, .body = pageOf(writeText, .{one.help}), .back = choice.* } };
                        },
                        else => {},
                    },
                    else => {},
                }
            },
            .input => |*input| return self.pressInInput(input, pressed),
        }
        return .none;
    }

    fn choose(self: *Editor, choice: Choice) void {
        _ = options.set(&self.config, choice.option, .{ .choice = choice.cursor });
        self.dialog = null;
    }

    fn leave(self: *Editor, answer: Answer) Effect {
        self.dialog = null;
        return switch (answer) {
            .yes => .{ .save_and_quit = self.path.slice() },
            .no => .quit,
        };
    }

    fn pressInInput(self: *Editor, input: *Input, pressed: Key) Effect {
        if (input.on_buttons) |*button| {
            switch (pressed) {
                .tab, .right => {
                    input.on_buttons = if (button.* == .ok) .help else null;
                },
                .back_tab, .left => {
                    input.on_buttons = if (button.* == .help) .ok else null;
                },
                .enter => return if (button.* == .ok) self.submit(input.*) else self.inputHelp(input.*),
                else => {},
            }
            return .none;
        }
        const field = &input.field;
        switch (pressed) {
            .left => input.cursor -|= 1,
            .right => input.cursor = @min(input.cursor + 1, field.len),
            .home => input.cursor = 0,
            .end => input.cursor = field.len,
            .backspace => if (input.cursor > 0) {
                field.remove(input.cursor - 1);
                input.cursor -= 1;
            },
            .delete => field.remove(input.cursor),
            .tab => input.on_buttons = .ok,
            .back_tab => input.on_buttons = .help,
            .enter => return self.submit(input.*),
            .char => |c| if (c >= ' ' and c <= '~') {
                field.insert(input.cursor, @intCast(c)) catch return .none;
                input.cursor += 1;
            },
            else => {},
        }
        return .none;
    }

    fn inputHelp(self: *Editor, input: Input) Effect {
        switch (input.purpose) {
            .value => |option| self.openHelpFor(option),
            else => self.dialog = null,
        }
        return .none;
    }

    fn openHelpFor(self: *Editor, option: Option) void {
        self.dialog = .{ .text = .{ .title = options.about(option).prompt, .body = pageOf(describe, .{ &self.config, option }) } };
    }

    fn submit(self: *Editor, input: Input) Effect {
        const typed = input.field.slice();
        self.dialog = null;
        switch (input.purpose) {
            .value => |option| {
                const value: options.Value = switch (options.kindOf(option)) {
                    .number => .{ .number = std.fmt.parseInt(u32, typed, 10) catch return self.invalid() },
                    .text => .{ .text = typed },
                    else => unreachable,
                };
                if (!options.set(&self.config, option, value)) return self.invalid();
            },
            .save, .load => {
                if (typed.len == 0) return .none;
                _ = self.path.set(typed);
                return if (input.purpose == .save) .{ .save = self.path.slice() } else .{ .load = self.path.slice() };
            },
            .search => self.dialog = .{ .text = .{ .title = "Search Results", .body = pageOf(search, .{ &self.config, typed }) } },
        }
        return .none;
    }

    fn invalid(self: *Editor) Effect {
        self.dialog = .{ .message = "You have made an invalid entry." };
        return .none;
    }

    // -----------------------------------------------------------------------
    // Drawing
    // -----------------------------------------------------------------------

    pub fn draw(self: *Editor, screen: *Screen) void {
        screen.fill(screen.whole(), ' ', .backdrop);
        screen.cursor = null;
        _ = screen.text(1, 0, ".config - vibeee Configuration", .backdrop, screen.cols - 2);
        screen.fill(.{ .x = 1, .y = 1, .w = screen.cols - 2, .h = 1 }, '─', .backdrop);

        if (screen.cols < MIN_COLS or screen.rows < MIN_ROWS) {
            _ = screen.paragraph(.{ .x = 1, .y = 3, .w = screen.cols - 2, .h = 3 }, "Your display is too small to run menuconfig. It must be at least 19 lines by 80 columns.", .backdrop);
            return;
        }
        self.drawMenu(screen);
        if (self.dialog) |*dialog| self.drawDialog(dialog, screen);
    }

    fn drawMenu(self: *Editor, screen: *Screen) void {
        const outer = screen.whole().centred(screen.cols - 5, screen.rows - 4);
        const menu = self.here().menu;
        screen.dialog(outer, menu.title);

        const used = screen.paragraph(.{ .x = outer.x + 2, .y = outer.y + 1, .w = outer.w - 4, .h = 4 }, INSTRUCTIONS, .dialog);
        const list: Rect = .{ .x = outer.x + 2, .y = outer.y + 1 + @min(used, 4), .w = outer.w - 4, .h = outer.h - 4 - @min(used, 4) };
        screen.box(list);

        const rows = rowsOf(&self.config, menu);
        const level = self.here();
        level.cursor = @min(level.cursor, rows.len -| 1);
        const visible: usize = @intCast(list.h - 2);
        self.page = visible;
        level.top = scrolled(level.top, level.cursor, visible, rows.len);

        for (rows.slice()[level.top..@min(rows.len, level.top + visible)], level.top..) |row, index| {
            const y = list.y + 1 + @as(i32, @intCast(index - level.top));
            const selected = index == level.cursor;
            var room: [256]u8 = undefined;
            const line = rowText(&self.config, row, &room);
            const x = list.x + 2;
            if (selected) screen.fill(.{ .x = list.x + 1, .y = y, .w = list.w - 2, .h = 1 }, ' ', .selected);
            _ = screen.text(x, y, line.text, if (selected) .selected else .dialog, list.w - 4);
            if (line.key_at) |at| screen.paint(x + @as(i32, @intCast(at)), y, if (selected) .key_selected else .key);
        }
        if (level.top > 0) _ = screen.text(list.x + list.w - 8, list.y, "^(-)", .key, 4);
        if (level.top + visible < rows.len) _ = screen.text(list.x + list.w - 8, list.y + list.h - 1, "v(+)", .key, 4);

        screen.divider(outer, outer.y + outer.h - 3);
        drawButtons(screen, outer, outer.y + outer.h - 2, Button, if (self.dialog == null) self.button else null);
    }

    fn drawDialog(self: *Editor, dialog: *Dialog, screen: *Screen) void {
        switch (dialog.*) {
            .text => |*text| {
                const area = screen.whole().centred(@min(screen.cols - 4, 76), screen.rows - 4);
                screen.dialog(area, text.title);
                const body: Rect = .{ .x = area.x + 2, .y = area.y + 2, .w = area.w - 4, .h = area.h - 5 };
                var lines = screen_mod.wrap(text.body.slice(), @intCast(body.w));
                var count: usize = 0;
                while (lines.next()) |_| count += 1;
                text.scroll = @min(text.scroll, count -| @as(usize, @intCast(body.h)));
                lines = screen_mod.wrap(text.body.slice(), @intCast(body.w));
                var index: usize = 0;
                while (lines.next()) |line| : (index += 1) {
                    if (index < text.scroll or index >= text.scroll + @as(usize, @intCast(body.h))) continue;
                    _ = screen.text(body.x, body.y + @as(i32, @intCast(index - text.scroll)), line, .dialog, body.w);
                }
                screen.divider(area, area.y + area.h - 3);
                drawButtons(screen, area, area.y + area.h - 2, enum { exit }, .exit);
            },
            .message => |message| {
                const area = screen.whole().centred(60, 7);
                screen.dialog(area, "");
                _ = screen.paragraph(.{ .x = area.x + 2, .y = area.y + 1, .w = area.w - 4, .h = 2 }, message, .dialog);
                screen.divider(area, area.y + area.h - 3);
                drawButtons(screen, area, area.y + area.h - 2, enum { ok }, .ok);
            },
            .leave => |answer| {
                const area = screen.whole().centred(60, 8);
                screen.dialog(area, "");
                _ = screen.paragraph(.{ .x = area.x + 2, .y = area.y + 1, .w = area.w - 4, .h = 3 }, "Do you wish to save your new configuration?\n(Press <Esc><Esc> to continue configuring.)", .dialog);
                screen.divider(area, area.y + area.h - 3);
                drawButtons(screen, area, area.y + area.h - 2, enum { yes, no }, switch (answer) {
                    .yes => .yes,
                    .no => .no,
                });
            },
            .choice => |choice| {
                const values = options.choices(choice.option);
                const height: i32 = @intCast(values.len + 9);
                const area = screen.whole().centred(@min(screen.cols - 4, 60), @min(screen.rows - 4, height));
                screen.dialog(area, options.about(choice.option).prompt);
                _ = screen.paragraph(.{ .x = area.x + 2, .y = area.y + 1, .w = area.w - 4, .h = 2 }, "Use the arrow keys to move and <Space> to select. <?> gives help on the highlighted value.", .dialog);
                const list: Rect = .{ .x = area.x + 2, .y = area.y + 3, .w = area.w - 4, .h = area.h - 6 };
                screen.box(list);
                const visible: usize = @intCast(list.h - 2);
                const top = scrolled(0, choice.cursor, visible, values.len);
                const chosen = options.get(&self.config, choice.option).choice;
                for (values[top..@min(values.len, top + visible)], top..) |one, index| {
                    const y = list.y + 1 + @as(i32, @intCast(index - top));
                    const style: Style = if (index == choice.cursor) .selected else .dialog;
                    if (index == choice.cursor) screen.fill(.{ .x = list.x + 1, .y = y, .w = list.w - 2, .h = 1 }, ' ', .selected);
                    _ = screen.text(list.x + 2, y, if (index == chosen) "(X) " else "( ) ", style, 4);
                    _ = screen.text(list.x + 6, y, one.prompt, style, list.w - 8);
                }
                screen.divider(area, area.y + area.h - 3);
                drawButtons(screen, area, area.y + area.h - 2, enum { select, help }, .select);
            },
            .input => |input| {
                const area = screen.whole().centred(@min(screen.cols - 4, 70), 11);
                screen.dialog(area, switch (input.purpose) {
                    .value => |option| options.about(option).prompt,
                    .save => "Save Configuration",
                    .load => "Load Configuration",
                    .search => "Search Configuration Parameter",
                });
                _ = screen.paragraph(.{ .x = area.x + 2, .y = area.y + 1, .w = area.w - 4, .h = 3 }, switch (input.purpose) {
                    .value => |option| if (options.kindOf(option) == .number)
                        "Please enter a decimal value. Use the <Tab> key to move from the input field to the buttons below it."
                    else
                        "Please enter a string value. Use the <Tab> key to move from the input field to the buttons below it.",
                    .save => "Enter a file name to save this configuration to. Leave blank to abort.",
                    .load => "Enter the name of the configuration file to load. Leave blank to abort.",
                    .search => "Enter a string to search for, with or without CONFIG_.",
                }, .dialog);
                const box: Rect = .{ .x = area.x + 2, .y = area.y + 4, .w = area.w - 4, .h = 3 };
                screen.box(box);
                const room = box.w - 2;
                const typed = input.field.slice();
                const start = input.cursor -| @as(usize, @intCast(room - 1));
                _ = screen.text(box.x + 1, box.y + 1, typed[start..], .dialog, room);
                if (input.on_buttons == null) screen.cursor = .{ .x = box.x + 1 + @as(i32, @intCast(input.cursor - start)), .y = box.y + 1 };
                screen.divider(area, area.y + area.h - 3);
                drawButtons(screen, area, area.y + area.h - 2, enum { ok, help }, if (input.on_buttons) |button| switch (button) {
                    .ok => .ok,
                    .help => .help,
                } else null);
            },
        }
    }
};

const INSTRUCTIONS =
    "Arrow keys navigate the menu. <Enter> selects submenus --->. Highlighted letters are hotkeys. " ++
    "Pressing <Y> includes, <N> excludes. Press <Esc><Esc> to exit, <?> for Help, </> for Search. " ++
    "Legend: [*] included  [ ] excluded";

fn cycle(comptime T: type, value: T, by: i2) T {
    const count: i32 = @intCast(std.enums.values(T).len);
    const at = @mod(@as(i32, @intFromEnum(value)) + by, count);
    return @enumFromInt(at);
}

/// The first row to show so the cursor is on screen and no space is wasted.
fn scrolled(top: usize, cursor: usize, visible: usize, count: usize) usize {
    var first = top;
    if (cursor < first) first = cursor;
    if (visible > 0 and cursor >= first + visible) first = cursor + 1 - visible;
    return @min(first, count -| visible);
}

/// The buttons of `Buttons`, an enum whose tags are their labels, centred on
/// row `y` of `area`.
fn drawButtons(screen: *Screen, area: Rect, y: i32, comptime Buttons: type, selected: ?Buttons) void {
    const values = comptime std.enums.values(Buttons);
    const WIDTH = 8;
    const GAP = 4;
    const total: i32 = @intCast(values.len * WIDTH + (values.len - 1) * GAP);
    var x = area.x + @divTrunc(area.w - total, 2);
    inline for (values) |button| {
        const label = comptime centredLabel(@tagName(button));
        const active = selected == button;
        _ = screen.text(x, y, "<", if (active) .selected else .dialog, 1);
        _ = screen.text(x + 1, y, label, if (active) .selected else .dialog, WIDTH - 2);
        _ = screen.text(x + WIDTH - 1, y, ">", if (active) .selected else .dialog, 1);
        const key_at = std.mem.indexOfNone(u8, label, " ") orelse 0;
        screen.paint(x + 1 + @as(i32, @intCast(key_at)), y, if (active) .key_selected else .button_key);
        x += WIDTH + GAP;
    }
}

/// A tag as a six-character label: capitalised and centred, as ` Exit ` is.
fn centredLabel(comptime tag: []const u8) []const u8 {
    return comptime blk: {
        var out: [6]u8 = @splat(' ');
        const left = (6 - tag.len) / 2;
        for (tag, left..) |c, at| out[at] = if (at == left) std.ascii.toUpper(c) else c;
        const frozen = out;
        break :blk &frozen;
    };
}

/// A row as it is drawn, and where its hotkey is.
fn rowText(config: *const Config, row: Row, room: []u8) struct { text: []const u8, key_at: ?usize } {
    var out: Writer = .fixed(room);
    const prompt_at = rowWrite(config, row, &out) catch return .{ .text = out.buffered(), .key_at = null };
    return .{ .text = out.buffered(), .key_at = if (hotkey(row.prompt())) |key| prompt_at + key else null };
}

/// Write a row. Returns where its prompt starts.
fn rowWrite(config: *const Config, row: Row, out: *Writer) Writer.Error!usize {
    if (row.setting()) |one| switch (options.get(config, one)) {
        .flag => |on| try out.writeAll(if (on) "[*] " else "[ ] "),
        .number => |n| try out.print("({d}) ", .{n}),
        .text => |bytes| try out.print("({s}) ", .{bytes}),
        .choice => try out.writeAll("    "),
    } else try out.writeAll("    ");

    for (0..row.depth) |_| try out.writeAll("  ");
    const prompt_at = out.end;
    try out.writeAll(row.prompt());
    switch (row.item) {
        .menu => try out.writeAll("  --->"),
        .option => |one| if (options.kindOf(one) == .choice) {
            try out.print(" ({s})  --->", .{options.choices(one)[options.get(config, one).choice].prompt});
        },
    }
    return prompt_at;
}

/// An option's help, as Linux's menuconfig lays it out.
pub fn describe(config: *const Config, option: Option, out: *Writer) Writer.Error!void {
    const about = options.about(option);
    try out.print("{s}:\n\n{s}\n\n", .{ dotconfig.symbol(option), about.help });
    try symbolInfo(config, option, out);
}

fn symbolInfo(config: *const Config, option: Option, out: *Writer) Writer.Error!void {
    const about = options.about(option);
    const name = dotconfig.symbol(option)["CONFIG_".len..];
    try out.print("Symbol: {s} [=", .{name});
    try valueWrite(config, option, out);
    try out.print("]\nType  : {s}\nPrompt: {s}\n  Location:\n", .{ typeName(option), about.prompt });
    var menus: [MAX_DEPTH]*const options.Menu = undefined;
    const path = locate(&options.root, option, &menus, 0) orelse 0;
    for (menus[0..path], 2..) |menu, indent| {
        for (0..indent) |_| try out.writeAll("  ");
        try out.print("-> {s}\n", .{menu.title});
    }
    const needs = options.dependsOn(option);
    if (needs.len > 0) {
        try out.writeAll("  Depends on: ");
        for (needs, 0..) |needed, index| {
            if (index > 0) try out.writeAll(" && ");
            try out.print("{s} [=", .{dotconfig.symbol(needed)["CONFIG_".len..]});
            try valueWrite(config, needed, out);
            try out.writeByte(']');
        }
        try out.writeByte('\n');
    }
}

fn typeName(option: Option) []const u8 {
    return switch (options.kindOf(option)) {
        .flag => "bool",
        .choice => "choice",
        .number => "integer",
        .text => "string",
    };
}

fn valueWrite(config: *const Config, option: Option, out: *Writer) Writer.Error!void {
    switch (options.get(config, option)) {
        .flag => |on| try out.writeAll(if (on) "y" else "n"),
        .choice => |index| try out.writeAll(options.choices(option)[index].tag),
        .number => |n| try out.print("{d}", .{n}),
        .text => |bytes| try out.writeAll(bytes),
    }
}

/// The menus from the root down to the one holding `option`. Returns how many.
fn locate(menu: *const options.Menu, option: Option, path: *[MAX_DEPTH]*const options.Menu, depth: usize) ?usize {
    if (depth == MAX_DEPTH) return null;
    path[depth] = menu;
    return inEntries(menu.entries, option, path, depth);
}

fn inEntries(entries: []const options.Entry, option: Option, path: *[MAX_DEPTH]*const options.Menu, depth: usize) ?usize {
    for (entries) |*entry| switch (entry.*) {
        .option => |nested| {
            if (nested.option == option) return depth + 1;
            if (inEntries(nested.under, option, path, depth)) |found| return found;
        },
        .menu => |*sub| {
            if (sub.toggle == option) return depth + 1;
            if (locate(sub, option, path, depth + 1)) |found| return found;
        },
    };
    return null;
}

/// Every option whose symbol or prompt holds `wanted`, described.
pub fn search(config: *const Config, wanted_raw: []const u8, out: *Writer) Writer.Error!void {
    const wanted = if (std.ascii.startsWithIgnoreCase(wanted_raw, "CONFIG_")) wanted_raw["CONFIG_".len..] else wanted_raw;
    var found = false;
    for (std.enums.values(Option)) |option| {
        const matches = std.ascii.indexOfIgnoreCase(dotconfig.symbol(option), wanted) != null or
            std.ascii.indexOfIgnoreCase(options.about(option).prompt, wanted) != null;
        if (!matches) continue;
        try symbolInfo(config, option, out);
        try out.writeByte('\n');
        found = true;
    }
    if (!found) try out.writeAll("No matches found.\n");
}

const testing = std.testing;

fn pressAll(editor: *Editor, keys: []const Key) Effect {
    var last: Effect = .none;
    for (keys) |one| last = editor.press(one);
    return last;
}

test "the top menu lists its submenus, and a menu that is an option only while on" {
    var config: Config = .{};
    var rows = rowsOf(&config, &options.root);
    try testing.expectEqual(@as(usize, 5), rows.len);
    try testing.expectEqualStrings("Desktop (eeewm)", rows.slice()[3].prompt());

    const services = rows.slice()[2].item.menu;
    rows = rowsOf(&config, services);
    try testing.expectEqualStrings("Device manager (devmgd)", rows.slice()[0].prompt());
    try testing.expectEqual(@as(u8, 1), rows.slice()[1].depth);
    try testing.expectEqual(@as(u8, 2), rows.slice()[2].depth);

    config.devmgd = false;
    rows = rowsOf(&config, services);
    try testing.expectEqual(@as(usize, 3), rows.len);
}

test "keys toggle, enter and leave menus" {
    var editor: Editor = .init(.{}, ".config");
    // Down to Services, in.
    try testing.expectEqual(Effect.none, pressAll(&editor, &.{ .down, .down, .enter }));
    try testing.expectEqual(@as(usize, 1), editor.depth);
    // Networking is the second row; off, and time goes with it.
    _ = pressAll(&editor, &.{ .down, .{ .char = 'n' } });
    try testing.expect(!editor.config.netd);
    try testing.expect(editor.changed());
    _ = pressAll(&editor, &.{.{ .char = ' ' }});
    try testing.expect(editor.config.netd);
    // Escape Escape leaves the menu, and again asks whether to save.
    _ = pressAll(&editor, &.{ .{ .char = 'n' }, .escape, .escape });
    try testing.expectEqual(@as(usize, 0), editor.depth);
    try testing.expectEqual(Effect.none, pressAll(&editor, &.{ .escape, .escape }));
    try testing.expectEqual(Answer.yes, editor.dialog.?.leave);
    const effect = editor.press(.enter);
    try testing.expectEqualStrings(".config", effect.save_and_quit);
}

test "leaving without changes asks nothing" {
    var editor: Editor = .init(.{}, ".config");
    try testing.expectEqual(Effect.quit, pressAll(&editor, &.{ .escape, .escape }));
}

test "a choice opens a list, and the value chosen is set" {
    var editor: Editor = .init(.{}, ".config");
    _ = editor.press(.enter);
    try testing.expectEqual(Option.cpu, editor.dialog.?.choice.option);
    _ = pressAll(&editor, &.{ .up, .up, .enter });
    try testing.expectEqual(options.Processor.pentium2, editor.config.cpu);
    try testing.expect(editor.dialog == null);
}

test "a number is typed, and one out of range is refused" {
    var editor: Editor = .init(.{}, ".config");
    // Image, then Home partition size, the fourth row.
    _ = pressAll(&editor, &.{ .down, .enter, .down, .down, .down, .enter });
    try testing.expectEqualStrings("16", editor.dialog.?.input.field.slice());
    _ = pressAll(&editor, &.{ .backspace, .backspace, .{ .char = '6' }, .{ .char = '4' }, .enter });
    try testing.expectEqual(@as(u16, 64), editor.config.home_mb);

    _ = pressAll(&editor, &.{ .enter, .backspace, .backspace, .{ .char = '1' }, .enter });
    try testing.expectEqual(@as(u16, 64), editor.config.home_mb);
    try testing.expect(editor.dialog.? == .message);
    _ = editor.press(.enter);
    try testing.expect(editor.dialog == null);
}

test "Save asks for a file name and hands it to the tool" {
    var editor: Editor = .init(.{}, ".config");
    editor.config.hero = true;
    _ = pressAll(&editor, &.{ .tab, .tab, .tab, .enter });
    try testing.expect(editor.dialog.? == .input);
    const effect = pressAll(&editor, &.{ .backspace, .{ .char = '2' }, .enter });
    try testing.expectEqualStrings(".confi2", effect.save);
    editor.wasSaved();
    try testing.expect(!editor.changed());
}

test "hotkeys jump to the next row starting with the letter" {
    var editor: Editor = .init(.{}, ".config");
    _ = editor.press(.{ .char = 'e' });
    try testing.expectEqual(@as(usize, 4), editor.here().cursor);
    _ = editor.press(.{ .char = 'p' });
    try testing.expectEqual(@as(usize, 0), editor.here().cursor);
}

test "help names the symbol, its value, where it is and what it depends on" {
    var room: [2048]u8 = undefined;
    var out: Writer = .fixed(&room);
    try describe(&.{}, .timed, &out);
    const text = out.buffered();
    try testing.expect(std.mem.startsWith(u8, text, "CONFIG_TIMED:\n\nSets the clock over SNTP.\n\n"));
    try testing.expect(std.mem.indexOf(u8, text, "Symbol: TIMED [=y]\nType  : bool\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "    -> vibeee Configuration\n      -> Services\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "Depends on: DEVMGD [=y] && NETD [=y]\n") != null);
}

test "search finds options by symbol or prompt" {
    var room: [4096]u8 = undefined;
    var out: Writer = .fixed(&room);
    try search(&.{}, "config_web", &out);
    try testing.expect(std.mem.indexOf(u8, out.buffered(), "Symbol: WEB [=n]") != null);
    out = .fixed(&room);
    try search(&.{}, "nothing like it", &out);
    try testing.expectEqualStrings("No matches found.\n", out.buffered());
}

test "the menu draws at the smallest size, and says so below it" {
    var cells: [MIN_COLS * MIN_ROWS]screen_mod.Cell = undefined;
    var screen = Screen.init(&cells, MIN_COLS, MIN_ROWS);
    var editor: Editor = .init(.{}, ".config");
    editor.draw(&screen);
    var found = false;
    var y: i32 = 0;
    while (y < screen.rows) : (y += 1) {
        var room: [MIN_COLS * 4]u8 = undefined;
        var len: usize = 0;
        for (screen.cells[@intCast(y * screen.cols)..][0..MIN_COLS]) |cell| len += std.unicode.utf8Encode(cell.char, room[len..]) catch unreachable;
        if (std.mem.indexOf(u8, room[0..len], "Services  --->") != null) found = true;
    }
    try testing.expect(found);

    for ([_]Dialog{
        .{ .message = "x" },
        .{ .leave = .yes },
        .{ .choice = .{ .option = .cpu, .cursor = 12 } },
        .{ .input = .{ .purpose = .save, .field = .{}, .cursor = 0 } },
    }) |dialog| {
        editor.dialog = dialog;
        editor.draw(&screen);
    }
    editor.dialog = null;
    _ = editor.press(.{ .char = '?' });
    editor.draw(&screen);

    var small_cells: [20 * 5]screen_mod.Cell = undefined;
    var small = Screen.init(&small_cells, 20, 5);
    editor.draw(&small);
}

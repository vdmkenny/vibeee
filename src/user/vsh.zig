//! vsh, the vibeee shell.
//!
//! Deliberately small. Line editing lives in the kernel's line discipline, so
//! everything here is parsing and dispatch: split a line into words, run a
//! builtin or spawn a program, report what happened.
//!
//! Redirection and pipes both work by handing a command the handles it starts
//! with. A builtin runs inside the shell and follows the shell's own writer; a
//! program is given the handles at spawn. The stages of a pipeline run at once
//! and the shell waits on all of them, because a stage that ran to completion
//! before the next started would fill the pipe and stop.
//!
//! The shell is a supervised service, not the root of userspace: `init` starts
//! it and restarts it when it exits. That is what makes `exit` meaningful on a
//! machine with only one shell.

const manual = @import("manual");
const sys = @import("sys");
const cfg = @import("tools/cfg.zig");
const complete = @import("ulib").complete;
const font = @import("lib").font;
const platform = @import("proto").platform;
const ink = @import("ulib").ink;
const registry = @import("tools/registry.zig");
const dir_mod = @import("ulib").dir;
const edit = @import("ulib").edit;
const out = @import("ulib").out;
const str = @import("ulib").str;

const MAX_LINE = 256;
const MAX_WORDS = 16;

/// Where programs are looked up when a command has no path separator.
const BIN_DIR = "/bin/";

/// The multicall binary, tried when no program of the given name exists.
const TOOLS_PATH = "/bin/tools";

/// Where a session starts, and where `cd` with no argument goes back to.
/// A constant until there are environment variables for it to be `HOME` in.
const HOME = "/home";

const Builtin = struct {
    name: []const u8,
    summary: []const u8,
    /// What it did, in the shape a program reports it: nought when it worked.
    /// A builtin that cannot fail says so by always returning nought, which is
    /// still worth saying: the prompt colours itself from this.
    run: *const fn (words: []const []const u8) u8,
};

const builtins = [_]Builtin{
    .{ .name = "help", .summary = manual.summaryOf("help"), .run = &cmdHelp },
    .{ .name = "cd", .summary = manual.summaryOf("cd"), .run = &cmdCd },
    .{ .name = "pwd", .summary = manual.summaryOf("pwd"), .run = &cmdPwd },
    .{ .name = "echo", .summary = manual.summaryOf("echo"), .run = &cmdEcho },
    .{ .name = "clear", .summary = manual.summaryOf("clear"), .run = &cmdClear },
    .{ .name = "exit", .summary = manual.summaryOf("exit"), .run = &cmdExit },
    .{ .name = "off", .summary = manual.summaryOf("off"), .run = &cmdPowerOff },
    .{ .name = "reboot", .summary = manual.summaryOf("reboot"), .run = &cmdReboot },
};

export fn _start() callconv(.c) noreturn {
    shellMain();
}

fn shellMain() noreturn {
    // The console stops being a broadcast and becomes this conversation:
    // from here on, only the shell and what it starts render; services'
    // lines go to the ring, where `log` reads them.
    _ = sys.consoleClaim();

    out.text("vibeee shell. 'help' for builtins, 'tools' for system tools.\n");
    out.flush();

    editor.sources = &completion;

    // A session belongs where the user's things are. Not fatal if it is
    // missing: a shell that refused to start because a directory was gone
    // would be a shell that could not be used to put it back.
    _ = sys.chdir(HOME);

    var cwd: [256]u8 = @splat(0);
    // Room for the path, the arrow's three bytes, and the escapes that colour
    // it, which are part of the prompt because the editor redraws it whole.
    var prompt_buf: [cwd.len + 32]u8 = undefined;

    while (true) {
        var prompt = str.Builder{ .buf = &prompt_buf };
        const dir_len = sys.getcwd(&cwd);
        if (dir_len > 0) prompt.text(shortened(cwd[0..@intCast(dir_len)]));
        prompt.byte(' ');

        // The one coloured mark on the line, and the only thing that says this
        // is a prompt rather than output. It carries what became of the last
        // command, which is the only report of it a shell with no `$?` can
        // give. Plain again straight after, so what gets typed is not green.
        ink.append(&prompt, if (last_status == 0) .accent else .bad);
        ink.appendGlyph(&prompt, font.glyphs.arrow_right);
        ink.appendPlain(&prompt);
        prompt.byte(' ');

        const text = editor.read(prompt.done()) orelse continue;

        var words: [MAX_WORDS][]const u8 = undefined;
        const count = str.splitWords(text, &words);
        if (count == 0) continue;

        runLine(words[0..count]);
    }
}

/// The one line being edited, kept here because its history outlives any one
/// prompt and it is far too large for a stack.
var editor: edit.Editor = .{};

/// What the last thing to run made of itself.
///
/// Kept because the prompt is drawn from it: an arrow in the failure colour
/// says the last command did not work, which is the thing a shell without a
/// `$?` has no other way to tell anybody.
var last_status: u8 = 0;

/// What a name that is not a program at all reports. Chosen to match what a
/// shell has always said for it, so a script comparing against it is not
/// surprised by this one.
const NOT_FOUND: u8 = 127;

// ---------------------------------------------------------------------------
// Completion
// ---------------------------------------------------------------------------

/// What a command offers after its own name, for the commands whose arguments
/// are words rather than files. A row per command: adding one is adding a row,
/// which is the point of keeping them in a table.
const Subcommands = struct {
    command: []const u8,
    words: []const []const u8,
};

const subcommands = [_]Subcommands{
    .{ .command = "display", .words = &.{ "native", "regs" } },
    .{ .command = "kill", .words = &.{} },
};

/// Everything that can be run: the builtins, the commands the tools binary
/// answers to, and whatever is in `/bin`.
///
/// `/bin` rather than the working directory, because that is where programs
/// live and a bare name is resolved there. A program installed today completes
/// because it is in the directory, not because anybody listed it.
fn offerCommands(ctx: complete.Context, into: *complete.Collector) void {
    _ = ctx;
    for (builtins) |b| into.offer(b.name);
    for (registry.names) |name| into.offer(name);
    listInto(BIN_DIR, "", into, .any);
}

/// The names in the current directory, for the arguments that are files.
fn offerFiles(ctx: complete.Context, into: *complete.Collector) void {
    offerEntries(ctx, into, .any);
}

/// Only the directories, for a command that can go nowhere else.
fn offerDirectories(ctx: complete.Context, into: *complete.Collector) void {
    offerEntries(ctx, into, .directories);
}

/// The words a particular command takes after its name.
fn offerSubcommands(ctx: complete.Context, into: *complete.Collector) void {
    for (subcommands) |entry| {
        if (!str.eql(entry.command, ctx.command)) continue;
        for (entry.words) |word| into.offer(word);
    }
}

const Which = enum { any, directories };

/// Read the current directory once and offer what is in it. Shared by every
/// source that answers with a name from the filesystem.
/// Offer what is in the directory the word names, rather than what is in the
/// working directory.
///
/// A half-typed path is a directory and a prefix, and only the prefix is being
/// completed. Listing the working directory instead means `/home/read` matches
/// nothing, because the entries there are called `readme.txt` and not
/// `/home/readme.txt`, which is what was typed.
///
/// What is offered is therefore the whole word as it would become, path and
/// all: the collector compares against what was typed, so a candidate has to
/// be spelled the same way.
fn offerEntries(ctx: complete.Context, into: *complete.Collector, which: Which) void {
    const cut = lastSeparator(ctx.word);

    // Everything up to and including the separator, kept exactly as typed so
    // the completion reads as a continuation of it.
    const typed_dir = if (cut) |at| ctx.word[0 .. at + 1] else "";
    const where = if (cut) |at| (if (at == 0) "/" else ctx.word[0..at]) else ".";

    listInto(where, typed_dir, into, which);
}

/// Offer what is in `where`, each spelled with `typed_dir` in front of it so a
/// candidate reads as a continuation of what was typed.
fn listInto(where: []const u8, typed_dir: []const u8, into: *complete.Collector, which: Which) void {
    var names: [dir_mod.MAX * 16]u8 = undefined;
    var listing = dir_mod.Listing{};
    dir_mod.read(where, &names, &listing) catch return;

    for (listing.items()) |entry| {
        if (which == .directories and !entry.is_dir) continue;

        var buf: [edit.LINE_MAX]u8 = undefined;
        var candidate = str.Builder{ .buf = &buf };
        candidate.text(typed_dir);
        candidate.text(entry.name);
        // A directory is not a finished answer: the slash is what lets the
        // next tab go into it rather than stopping at its name.
        if (entry.is_dir) candidate.byte('/');

        into.offer(candidate.done());
    }
}

fn lastSeparator(word: []const u8) ?usize {
    var i = word.len;
    while (i > 0) {
        i -= 1;
        if (word[i] == '/') return i;
    }
    return null;
}

/// Where candidates come from, in the order they are asked. A command with no
/// row of its own falls to the file source, because a filename is what most
/// arguments are.
/// Only the commands that want something other than a filename are listed.
/// Everything else, including a program installed today, completes filenames
/// because that is what the last source says to do when nothing claimed it.
const completion = [_]complete.Source{
    .{ .when = .command, .offer = &offerCommands },
    .{ .when = .named, .command = "cd", .offer = &offerDirectories },
    .{ .when = .named, .command = "mount", .offer = &offerDirectories },
    .{ .when = .named, .command = "unmount", .offer = &offerDirectories },
    .{ .when = .named, .command = "cfg", .offer = &cfg.offer },
    .{ .when = .named, .command = "display", .offer = &offerSubcommands },
    .{ .when = .otherwise, .offer = &offerFiles },
};

/// Where a command's output goes.
const Redirect = struct {
    path: []const u8 = "",
    append: bool = false,

    fn active(self: Redirect) bool {
        return self.path.len > 0;
    }
};

/// Pull a trailing `> file` or `>> file` off the word list.
///
/// Parsed here rather than in the tokenizer because `>` is shell syntax, not
/// an argument: a command must never see it, and the file it names is the
/// shell's business to open.
fn takeRedirect(words: []const []const u8, into: *Redirect) []const []const u8 {
    if (words.len < 2) return words;

    const marker = words[words.len - 2];
    const append = str.eql(marker, ">>");
    if (!append and !str.eql(marker, ">")) return words;

    into.* = .{ .path = words[words.len - 1], .append = append };
    return words[0 .. words.len - 2];
}

/// Most stages anyone types. Past this the line is a mistake rather than a
/// pipeline, and saying so beats running some of it.
const MAX_STAGES = 8;

/// Split a line on `|`. Zero when a stage is empty or there are too many,
/// both of which are the line being wrong rather than a command to run.
fn splitStages(words: []const []const u8, stages: [][]const []const u8) usize {
    var count: usize = 0;
    var start: usize = 0;

    for (0..words.len + 1) |i| {
        const end = i == words.len;
        if (!end and !str.eql(words[i], "|")) continue;
        if (i == start or count == stages.len) return 0;

        stages[count] = words[start..i];
        count += 1;
        start = i + 1;
    }
    return count;
}

fn runLine(words: []const []const u8) void {
    var redirect: Redirect = .{};
    const command = takeRedirect(words, &redirect);
    if (command.len == 0) {
        out.text("vsh: nothing to redirect\n");
        out.flush();
        return;
    }

    var stages: [MAX_STAGES][]const []const u8 = undefined;
    const count = splitStages(command, &stages);
    if (count == 0) {
        out.text("vsh: a pipeline needs a command on both sides of every |\n");
        out.flush();
        return;
    }

    if (!redirect.active()) {
        if (count == 1) {
            run(command, sys.Spawn.INHERIT);
        } else {
            runPipeline(stages[0..count], sys.Spawn.INHERIT);
        }
        return;
    }

    // Truncate unless appending, so `>` replaces a file rather than leaving
    // the tail of whatever was longer.
    const handle = sys.open(redirect.path, .{
        .write = true,
        .create = true,
        .truncate = !redirect.append,
        .append = redirect.append,
    });
    if (handle < 0) {
        out.text("vsh: ");
        out.text(redirect.path);
        out.text(": cannot open for writing\n");
        out.flush();
        return;
    }

    // The file is the last stage's output, whether there is one stage or six.
    if (count == 1) {
        out.redirectTo(@intCast(handle));
        run(command, @intCast(handle));
        out.redirectTo(sys.STDOUT);
    } else {
        runPipeline(stages[0..count], @intCast(handle));
    }

    _ = sys.close(@intCast(handle));
}

/// Run every stage at once, each reading what the one before it writes.
///
/// The shell closes its own copy of each pipe end as soon as the stage that
/// needs it has started. A reader only sees end of file when every writer has
/// let go, and the shell holding a spare copy is a writer that never will.
fn runPipeline(stages: []const []const []const u8, last_out: i32) void {
    var pids: [MAX_STAGES]u32 = undefined;
    var started: usize = 0;
    var feed: i32 = sys.Spawn.INHERIT;

    for (stages, 0..) |stage, i| {
        const last = i + 1 == stages.len;

        var sink: i32 = last_out;
        var next_feed: i32 = sys.Spawn.INHERIT;
        if (!last) {
            const conduit = sys.pipe() orelse {
                out.text("vsh: no pipe available\n");
                break;
            };
            sink = @intCast(conduit.write);
            next_feed = @intCast(conduit.read);
        }

        const pid = spawnStage(stage, feed, sink);

        if (feed != sys.Spawn.INHERIT) _ = sys.close(@intCast(feed));
        if (!last) _ = sys.close(@intCast(sink));
        feed = next_feed;

        if (pid) |id| {
            pids[started] = id;
            started += 1;
        } else if (!last) {
            // Nothing will read what the rest write, so stop here rather than
            // leaving stages blocked on a pipe with no other end.
            _ = sys.close(@intCast(feed));
            feed = sys.Spawn.INHERIT;
            break;
        }
    }

    if (feed != sys.Spawn.INHERIT) _ = sys.close(@intCast(feed));

    // Every stage is waited for, so none is left behind as a zombie and the
    // prompt does not come back while output is still arriving. A pipeline is
    // reported by its last stage, which is the one whose output was wanted.
    for (pids[0..started], 0..) |id, i| {
        const exited = sys.wait(id, sys.FOREVER);
        if (i + 1 == started) {
            last_status = if (exited) |e| @truncate(@as(u32, @bitCast(e.status))) else 0;
        }
    }
    out.flush();
}

/// Start one stage of a pipeline, detached so the next can start beside it.
fn spawnStage(words: []const []const u8, from: i32, into: i32) ?u32 {
    for (builtins) |b| {
        if (!str.eql(b.name, words[0])) continue;
        // A builtin is the shell itself and cannot be a stage: it has no
        // process of its own to give the pipe to.
        out.text("vsh: ");
        out.text(b.name);
        out.text(" is a builtin and cannot be part of a pipeline\n");
        return null;
    }

    const status = spawnProgram(words, .{
        .flags = @bitCast(sys.SpawnFlags{ .detached = true }),
        .stdin = from,
        .stdout = into,
    });
    if (status < 0) {
        out.text("vsh: ");
        out.text(words[0]);
        out.text(": not found\n");
        return null;
    }
    return @intCast(status);
}

/// Run a command, sending its output to `into`.
///
/// A builtin runs inside the shell and follows the shell's writer, which the
/// caller has already pointed at the file. A program is its own process with
/// its own writer, so the only thing that reaches it is the handle it starts
/// with.
fn run(words: []const []const u8, into: i32) void {
    for (builtins) |b| {
        if (str.eql(b.name, words[0])) {
            last_status = b.run(words);
            out.flush();
            return;
        }
    }

    const status = spawnProgram(words, .{ .stdout = into });
    last_status = if (status < 0) NOT_FOUND else @truncate(@as(usize, @intCast(status)));

    if (status < 0) {
        out.text("vsh: ");
        out.text(words[0]);
        out.text(": not found\n");
    } else if (status != 0) {
        // Reporting a non-zero status matters without a `$?` to inspect.
        out.text("vsh: exit status ");
        out.decimal(@intCast(status));
        out.text("\n");
    }
    out.flush();
}

/// Start a program by name, with the streams it should have.
///
/// A name is looked for as a program first and then as a command inside the
/// multicall binary. FAT has no symlinks, so the usual argv[0] trick is
/// unavailable and the shell does the dispatch instead, which is cheaper than
/// shipping a copy of the same image under every command name.
fn spawnProgram(words: []const []const u8, streams: sys.Spawn) isize {
    var path_buf: [MAX_LINE]u8 = undefined;
    const path = resolvePath(words[0], &path_buf);

    const direct = sys.spawnStreams(path, words, streams);
    if (direct >= 0) return direct;

    var argv: [MAX_WORDS + 1][]const u8 = undefined;
    argv[0] = "tools";
    for (words, 0..) |w, i| argv[1 + i] = w;
    return sys.spawnStreams(TOOLS_PATH, argv[0 .. words.len + 1], streams);
}

/// The working directory as a prompt should show it: `~` where the path
/// begins at home, because that is most of them and the full path is noise
/// in the one place there is least room for it.
fn shortened(path: []const u8) []const u8 {
    if (str.eql(path, HOME)) return "~";
    if (!str.startsWith(path, HOME) or path[HOME.len] != '/') return path;

    var shown = str.Builder{ .buf = &short_buf };
    shown.byte('~');
    shown.text(path[HOME.len..]);
    return shown.done();
}

var short_buf: [256]u8 = @splat(0);

/// Turn a bare command name into a path. A name with a slash in it is already
/// one and is left alone.
fn resolvePath(name: []const u8, buf: []u8) []const u8 {
    if (name.len > 0 and name[0] == '/') return name;

    var path = str.Builder{ .buf = buf };
    path.text(BIN_DIR);
    path.text(name);
    return path.done();
}




// ---------------------------------------------------------------------------
// Builtins
// ---------------------------------------------------------------------------

fn cmdHelp(_: []const []const u8) u8 {
    out.text("builtins:\n");
    for (builtins) |b| {
        out.text("  ");
        out.pad(b.name, 10);
        out.text(b.summary);
        out.text("\n");
    }
    out.text("\nanything else runs as a program from ");
    out.text(BIN_DIR);
    out.text(", or as a command in ");
    out.text(TOOLS_PATH);
    out.text("\n");
    return 0;
}

fn cmdCd(words: []const []const u8) u8 {
    // Bare `cd` goes home, which is where a session starts.
    const target = if (words.len > 1) words[1] else HOME;
    if (sys.chdir(target) < 0) {
        out.text("cd: ");
        out.text(target);
        out.text(": no such directory\n");
        return 1;
    }
    return 0;
}

fn cmdPwd(_: []const []const u8) u8 {
    var buf: [256]u8 = [_]u8{0} ** 256;
    const n = sys.getcwd(&buf);
    if (n > 0) {
        out.text(buf[0..@intCast(n)]);
        out.byte('\n');
    }
    return 0;
}

fn cmdEcho(words: []const []const u8) u8 {
    for (words[1..], 0..) |w, i| {
        if (i > 0) out.text(" ");
        out.text(w);
    }
    out.text("\n");
    return 0;
}

/// Form feed, which the console reads as "clear". No escape sequences: the
/// line discipline does not parse ANSI, and a single byte with a meaning that
/// predates ANSI does the job.
fn cmdClear(_: []const []const u8) u8 {
    out.byte(0x0C);
    out.flush();
    return 0;
}

fn cmdExit(_: []const []const u8) u8 {
    // There is nothing to exit *to*, this is the only shell, but init
    // supervises it with `restart = always`, so exiting gets a fresh one. That
    // is the useful meaning here: it is how you recover a wedged shell.
    out.flush();
    sys.exit(0);
    return 0;
}

/// Ask `platd`, and fall back to the kernel's own way only when there is no
/// service to ask.
///
/// The service evaluates the firmware's methods, which is what makes a power
/// off actually happen on a machine whose BIOS expects `_PTS` first. The
/// kernel's path is a pattern match on the raw table and is what there is
/// when nothing is serving: worse, and better than nothing.
///
/// It is not tried after the service answered: by then the firmware has been
/// asked properly, and a second, cruder write is the last thing a machine
/// mid-transition needs. Writing the sleep registers twice is how one goes
/// dark without going off.
fn requestPower(tag: platform.Tag, fallback: usize) u8 {
    platform.ask(tag) catch |err| {
        switch (err) {
            error.NoService => sys.shutdown(fallback),
            error.End => {},
            else => {
                out.text("the firmware refused\n");
                out.flush();
            },
        }
        return 1;
    };

    // Only reached if the service answered at all, which means it did not
    // happen: a power off that works never gets as far as a reply.
    out.text("nothing happened\n");
    out.flush();
    return 1;
}

fn cmdPowerOff(_: []const []const u8) u8 {
    out.flush();
    return requestPower(.power_off, sys.POWER_OFF);
}

fn cmdReboot(_: []const []const u8) u8 {
    out.flush();
    return requestPower(.reboot, sys.REBOOT);
}

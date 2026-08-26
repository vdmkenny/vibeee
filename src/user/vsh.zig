//! vsh, the vibeee shell.
//!
//! Deliberately small. Line editing lives in the kernel's line discipline, so
//! everything here is parsing and dispatch: split a line into words, run a
//! builtin or spawn a program, report what happened.
//!
//! Output redirection works; pipes do not. A pipe needs a kernel object that
//! does not exist yet and handle reassignment at spawn to go with it, and a
//! shell that pretended otherwise would fail in ways that looked like shell
//! bugs. Redirection needs neither: the shell opens the file itself and copies
//! what the command produced.
//!
//! The shell is a supervised service, not the root of userspace: `init` starts
//! it and restarts it when it exits. That is what makes `exit` meaningful on a
//! machine with only one shell.

const sys = @import("sys");
const out = @import("ulib").out;
const str = @import("ulib").str;

const MAX_LINE = 256;
const MAX_WORDS = 16;

/// Where programs are looked up when a command has no path separator.
const BIN_DIR = "/";

/// The multicall binary, tried when no program of the given name exists.
const TOOLS_PATH = "/TOOLS";

const Builtin = struct {
    name: []const u8,
    summary: []const u8,
    run: *const fn (words: []const []const u8) void,
};

const builtins = [_]Builtin{
    .{ .name = "help", .summary = "list builtins", .run = &cmdHelp },
    .{ .name = "cd", .summary = "change directory", .run = &cmdCd },
    .{ .name = "pwd", .summary = "print working directory", .run = &cmdPwd },
    .{ .name = "echo", .summary = "print arguments", .run = &cmdEcho },
    .{ .name = "clear", .summary = "clear the screen", .run = &cmdClear },
    .{ .name = "exit", .summary = "restart the shell", .run = &cmdExit },
    .{ .name = "off", .summary = "flush everything and power down", .run = &cmdPowerOff },
    .{ .name = "reboot", .summary = "flush everything and restart", .run = &cmdReboot },
};

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\ xorl %ebp, %ebp
        \\ call shellMain
        \\ hlt
    );
}

export fn shellMain() callconv(.c) noreturn {
    out.text("vibeee shell. 'help' for builtins, 'tools' for system tools.\n");
    out.flush();

    var line: [MAX_LINE]u8 = undefined;

    var cwd: [256]u8 = [_]u8{0} ** 256;

    while (true) {
        const dir_len = sys.getcwd(&cwd);
        if (dir_len > 0) out.name(cwd[0..@intCast(dir_len)]);
        out.text(" $ ");
        out.flush();

        const n = sys.read(sys.STDIN, &line);
        if (n <= 0) continue;

        var text = line[0..@intCast(n)];
        if (text.len > 0 and text[text.len - 1] == '\n') text = text[0 .. text.len - 1];

        var words: [MAX_WORDS][]const u8 = undefined;
        const count = str.splitWords(text, &words);
        if (count == 0) continue;

        runLine(words[0..count]);
    }
}

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

fn runLine(words: []const []const u8) void {
    var redirect: Redirect = .{};
    const command = takeRedirect(words, &redirect);
    if (command.len == 0) {
        out.text("vsh: nothing to redirect\n");
        out.flush();
        return;
    }

    if (!redirect.active()) {
        run(command);
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

    out.redirectTo(@intCast(handle));
    run(command);
    out.redirectTo(sys.STDOUT);

    _ = sys.close(@intCast(handle));
}

fn run(words: []const []const u8) void {
    for (builtins) |b| {
        if (str.eql(b.name, words[0])) {
            b.run(words);
            out.flush();
            return;
        }
    }

    // Not a builtin: look for a program of that name.
    var path_buf: [MAX_LINE]u8 = undefined;
    const path = resolvePath(words[0], &path_buf);

    var status = sys.spawn(path, words);

    // Not a program either: it may be a command inside the multicall binary.
    // FAT has no symlinks, so the usual argv[0] trick is unavailable and the
    // shell does the dispatch instead, cheaper than shipping a copy of the
    // same 12 KiB image under every command name.
    if (status < 0) {
        var argv: [MAX_WORDS + 1][]const u8 = undefined;
        argv[0] = "tools";
        for (words, 0..) |w, i| argv[1 + i] = w;
        status = sys.spawn(TOOLS_PATH, argv[0 .. words.len + 1]);
    }

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

/// Turn a bare command name into a path.
///
/// Names are upper-cased because the filesystem is FAT and stores short names
/// that way; typing `tools` should find `/TOOLS`.
fn resolvePath(name: []const u8, buf: []u8) []const u8 {
    if (name.len > 0 and name[0] == '/') return name;

    var n: usize = 0;
    for (BIN_DIR) |c| {
        buf[n] = c;
        n += 1;
    }
    for (name) |c| {
        if (n >= buf.len) break;
        buf[n] = if (c >= 'a' and c <= 'z') c - 32 else c;
        n += 1;
    }
    return buf[0..n];
}




// ---------------------------------------------------------------------------
// Builtins
// ---------------------------------------------------------------------------

fn cmdHelp(_: []const []const u8) void {
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
}

fn cmdCd(words: []const []const u8) void {
    // Bare `cd` goes home, which here is the root: there are no user
    // directories to have a home in yet.
    const target = if (words.len > 1) words[1] else "/";
    if (sys.chdir(target) < 0) {
        out.text("cd: ");
        out.text(target);
        out.text(": no such directory\n");
    }
}

fn cmdPwd(_: []const []const u8) void {
    var buf: [256]u8 = [_]u8{0} ** 256;
    const n = sys.getcwd(&buf);
    if (n > 0) {
        out.name(buf[0..@intCast(n)]);
        out.byte('\n');
    }
}

fn cmdEcho(words: []const []const u8) void {
    for (words[1..], 0..) |w, i| {
        if (i > 0) out.text(" ");
        out.text(w);
    }
    out.text("\n");
}

/// Form feed, which the console reads as "clear". No escape sequences: the
/// line discipline does not parse ANSI, and a single byte with a meaning that
/// predates ANSI does the job.
fn cmdClear(_: []const []const u8) void {
    out.byte(0x0C);
    out.flush();
}

fn cmdExit(_: []const []const u8) void {
    // There is nothing to exit *to*, this is the only shell, but init
    // supervises it with `restart = always`, so exiting gets a fresh one. That
    // is the useful meaning here: it is how you recover a wedged shell.
    out.flush();
    sys.exit(0);
}

fn cmdPowerOff(_: []const []const u8) void {
    out.flush();
    sys.shutdown(sys.POWER_OFF);
}

fn cmdReboot(_: []const []const u8) void {
    out.flush();
    sys.shutdown(sys.REBOOT);
}

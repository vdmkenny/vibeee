//! man, the manual: what a command is for and how it is held.
//!
//! Pages are plain text under /doc, one file per name, written for this
//! system rather than inherited from another one. The reading is the shared
//! viewer's; this resolves a name to its page and lists what exists when
//! asked for nothing.

const sys = @import("sys");
const dir = @import("ulib").dir;
const out = @import("ulib").out;
const pager = @import("ulib").pager;
const str = @import("ulib").str;

/// Where the pages live.
const DOC = "/doc";

/// A page is a screenful or three; the manual that outgrows this deserves
/// the truncation notice it gets.
var text: [16 * 1024]u8 = @splat(0);

pub fn run(args: []const []const u8) void {
    if (args.len == 0) {
        list();
        return;
    }

    var path_buf: [64]u8 = @splat(0);
    var path = str.Builder{ .buf = &path_buf };
    path.text(DOC);
    path.byte('/');
    path.text(args[0]);

    const handle = sys.open(path.done(), .{});
    if (handle < 0) {
        out.text("man: no page called ");
        out.text(args[0]);
        out.text("; `man` alone lists them\n");
        out.flush();
        return;
    }
    defer _ = sys.close(@intCast(handle));

    var filled: usize = 0;
    while (filled < text.len) {
        const n = sys.read(@intCast(handle), text[filled..]);
        if (n <= 0) break;
        filled += @intCast(n);
    }

    var title_buf: [64]u8 = @splat(0);
    var title = str.Builder{ .buf = &title_buf };
    title.text("man ");
    title.text(args[0]);

    pager.view(.{
        .title = title.done(),
        .text = text[0..filled],
        .truncated = filled == text.len,
    });
}

/// Every page there is, one name per line: the index a reader starts from.
fn list() void {
    var names: [2048]u8 = @splat(0);
    var listing = dir.Listing{};
    dir.read(DOC, &names, &listing) catch {
        out.text("man: no manual on this filesystem\n");
        out.flush();
        return;
    };

    var pages: usize = 0;
    for (listing.items()) |entry| {
        if (!entry.is_dir) pages += 1;
    }
    if (pages == 0) {
        // A directory with nothing in it means the same as no directory:
        // this build was made without the manual.
        out.text("man: no manual on this filesystem\n");
        out.flush();
        return;
    }

    out.text("the manual: `man <name>` for any of\n");
    for (listing.items()) |entry| {
        if (entry.is_dir) continue;
        out.text("  ");
        out.text(entry.name);
        out.byte('\n');
    }
    out.flush();
}

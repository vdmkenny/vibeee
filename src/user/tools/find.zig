//! find, where something is.
//!
//! `ls` and `tree` answer what is somewhere. This answers the other question:
//! given a name, or a piece of one, where in a tree does it live.
//!
//! Matching is a substring of the name, folded, for the same reason `grep`
//! matches a substring: a pattern language nobody implemented the whole of is
//! worse than an honest one everybody can predict. Folded because FAT stores
//! short names upper-cased, so a search that respected case would miss what it
//! was looking for on this system's own filesystem.

const out = @import("ulib").out;
const str = @import("lib").str;
const walk = @import("ulib").walk;

/// Beside the search rather than on its frame: a walk carries a listing per
/// level, which is far more than a user stack should hold.
var walker: walk.Walk = .{};

var wanted: []const u8 = "";
var matched: usize = 0;

pub fn run(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: find <name> [where]\n");
        out.flush();
        return;
    }

    wanted = args[0];
    matched = 0;
    const root = if (args.len > 1) args[1] else ".";

    const seen = walker.each(root, {}, show);

    out.decimal(matched);
    out.text(if (matched == 1) " match" else " matches");
    if (seen.cut) {
        out.text(", stopped ");
        out.decimal(walk.MAX_DEPTH);
        out.text(" deep");
    }
    out.byte('\n');
    out.flush();
}

fn show(_: void, _: usize, found: walk.Found) void {
    // A directory that would not open and a listing held short are worth
    // knowing about during a search: what was not looked at is the difference
    // between a name that is not there and one that was never reached.
    const it = switch (found) {
        .name => |name| name,
        .unreadable => return out.fault("find", "", "a directory would not open"),
        .more => return out.fault("find", "", "a directory held more than was looked at"),
    };

    if (!str.containsFold(it.name, wanted)) return;
    out.text(it.path);
    if (it.is_dir) out.byte('/');
    out.byte('\n');
    matched += 1;
}

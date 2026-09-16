//! icon, the picture a program carries for the launcher.

const eui_icon = @import("eui").icon;
const notes = @import("ulib").notes;
const out = @import("ulib").out;

pub fn run(args: []const []const u8) void {
    if (args.len == 0) {
        out.text("usage: icon <program>...\n");
        out.flush();
        return;
    }

    for (args) |path| {
        if (args.len > 1) {
            out.text(path);
            out.byte('\n');
        }
        const picture = notes.read(eui_icon.Note, path) orelse {
            out.flush();
            out.fault("icon", path, "carries no icon");
            continue;
        };
        for (eui_icon.unpack(&picture)) |row| {
            out.text(&row);
            out.byte('\n');
        }
    }
    out.flush();
}

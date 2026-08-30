//! resolve: a name to its address, and where the answer came from.
//!
//! The question every networked tool asks, standing alone so the path can
//! be inspected: the hosts table answers first, then the DNS servers the
//! lease or the configuration named. Asking is the diagnostic; the time
//! and the source tell the story.
//!
//!   resolve <name> [name...]

const lib = @import("lib");
const out = @import("ulib").out;
const sock = @import("ulib").sock;
const sys = @import("sys");

pub fn run(args: []const []const u8) void {
    if (args.len == 0) {
        say("usage: resolve <name> [name...]\n");
        return;
    }

    for (args) |name| {
        const before = sys.clockMicros();
        const answer = sock.resolve(name) catch |err| {
            out.text(name);
            out.text(": ");
            out.text(switch (err) {
                error.NoService => "the network service is not answering",
                else => "not known",
            });
            out.byte('\n');
            out.flush();
            continue;
        };
        const took: u64 = @intCast(sys.clockMicros() - before);

        out.text(name);
        out.text("  ");
        var field: [15]u8 = @splat(0);
        out.text(lib.ipv4.text(answer.addr, &field));
        switch (answer.source) {
            .hosts => out.text("  from /etc/hosts"),
            .dns => {
                out.text("  from dns, ");
                out.decimal(@intCast(took / 1000));
                out.text(" ms");
            },
        }
        out.byte('\n');
        out.flush();
    }
}

fn say(text: []const u8) void {
    out.text(text);
    out.flush();
}

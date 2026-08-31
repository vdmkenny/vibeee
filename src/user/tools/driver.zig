//! driver: what the device manager matched, and the levers over it.
//!
//! The manager owns which driver drives which device; this is its
//! listing and its verbs. A standalone driver process can be stopped and
//! started; a rescan reads `/lib/drivers` again, which is how a driver
//! dropped onto a running machine comes alive.
//!
//!   driver              the bindings
//!   driver stop <name>  stop a standalone driver process
//!   driver start <name> start it again
//!   driver rescan       read the manifests again, bind anything new

const lib = @import("lib");
const ink = @import("ulib").ink;
const out = @import("ulib").out;
const proto = @import("proto").devices;
const str = @import("ulib").str;

pub fn run(args: []const []const u8) void {
    if (args.len == 0) return list();

    if (str.eql(args[0], "rescan")) {
        var reply = proto.Rep{};
        proto.call(.{ .tag = .rescan }, &reply) catch return say("driver: refused\n");
        return say("rescanned\n");
    }
    if (args.len == 2 and (str.eql(args[0], "stop") or str.eql(args[0], "start"))) {
        const tag: proto.Tag = if (str.eql(args[0], "stop")) .stop else .start;
        const req = proto.Req.named(tag, args[1]) orelse return say("driver: bad name\n");
        var reply = proto.Rep{};
        proto.call(req, &reply) catch {
            say("driver: refused; a service's driver has no process to control\n");
            return;
        };
        return say("done\n");
    }

    say("usage: driver [stop <name> | start <name> | rescan]\n");
}

fn list() void {
    var index: u32 = 0;
    var any = false;
    while (true) : (index += 1) {
        var reply = proto.Rep{};
        proto.call(.{ .tag = .list, .index = index }, &reply) catch |err| {
            if (err == error.End) break;
            say("driver: the device manager is not answering\n");
            return;
        };
        const info = reply.body.driver;
        any = true;

        ink.write(.key, info.nameSlice());
        out.text("  at ");
        var place: [8]u8 = undefined;
        out.text(lib.pci.spell(@bitCast(info.location), &place));
        out.text("  ");
        switch (info.state) {
            .assigned => {
                out.text("assigned to ");
                out.text(info.serviceSlice());
            },
            .running => out.text("running"),
            .stopped => out.text("stopped"),
        }
        out.byte('\n');
    }
    if (!any) say("no drivers bound; /lib/drivers holds the manifests\n");
    out.flush();
}

fn say(text: []const u8) void {
    out.text(text);
    out.flush();
}

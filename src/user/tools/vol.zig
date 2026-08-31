//! vol: how loud the machine is.
//!
//! Reads and nudges the default sink's volume, which is the hardware's
//! own attenuator when the sink is hardware. Ports and links have their
//! own volumes; those belong to `patch`.
//!
//!   vol            say the volume
//!   vol 80         set it, in percent
//!   vol +5 | -5    nudge it
//!   vol mute       toggle silence

const audiograph = @import("lib").audiograph;
const out = @import("ulib").out;
const proto = @import("proto").audio;
const sound = @import("ulib").sound;
const str = @import("ulib").str;

pub fn run(args: []const []const u8) void {
    var reply = proto.Rep{};
    proto.call(.{ .tag = .get_master }, &reply) catch {
        say("vol: the sound service is not answering\n");
        return;
    };
    const current = reply.body.volume;

    if (args.len == 0) {
        show(current);
        return;
    }

    var wanted: u32 = current.percent;
    var mute = current.muted != 0;
    const arg = args[0];

    if (str.eql(arg, "mute")) {
        mute = !mute;
    } else if (arg.len > 1 and (arg[0] == '+' or arg[0] == '-')) {
        const step: u32 = @intCast(str.toUnsigned(arg[1..]));
        wanted = if (arg[0] == '+') @min(wanted + step, 100) else wanted -| step;
        mute = false;
    } else if (arg.len > 0 and arg[0] >= '0' and arg[0] <= '9') {
        wanted = @intCast(@min(str.toUnsigned(arg), 100));
        mute = false;
    } else {
        say("usage: vol [percent | +n | -n | mute]\n");
        return;
    }

    const sink = sound.defaultPort(.sink) catch {
        say("vol: no default sink\n");
        return;
    };
    proto.call(.{
        .tag = .set_volume,
        .a = sink,
        .b = wanted,
        .dir = @intFromBool(mute),
    }, &reply) catch {
        say("vol: refused\n");
        return;
    };
    show(.{ .percent = @intCast(wanted), .muted = @intFromBool(mute) });
}

fn show(volume: proto.VolumeInfo) void {
    out.text("volume ");
    out.decimal(volume.percent);
    out.text("%");
    if (volume.muted != 0) out.text(", muted");
    out.byte('\n');
    out.flush();
}

fn say(text: []const u8) void {
    out.text(text);
    out.flush();
}

comptime {
    _ = audiograph;
}

//! tone: a sine through the sound graph, and the proof it carries.
//!
//! The simplest possible client: one node, one output port, frames from
//! the shared generator. What it proves is everything beneath it, the
//! ring, the mix, the engine and the codec, which is why it exists as a
//! tool rather than waiting for a media player to need all of that at
//! once.
//!
//!   tone              one second of concert pitch
//!   tone 1000         a chosen frequency
//!   tone 1000 250     and a chosen length, in milliseconds

const audio = @import("lib").audio;
const out = @import("ulib").out;
const proto = @import("proto").audio;
const sound = @import("ulib").sound;
const str = @import("ulib").str;
const sys = @import("sys");

pub fn run(args: []const []const u8) void {
    var hertz: u32 = 440;
    var ms: u32 = 1000;
    if (args.len > 0) hertz = @intCast(@min(str.toUnsigned(args[0]), 20000));
    if (args.len > 1) ms = @intCast(@min(str.toUnsigned(args[1]), 10_000));
    if (hertz == 0 or ms == 0) {
        say("usage: tone [hertz] [milliseconds]\n");
        return;
    }

    const port = sound.Port.output("tone", "out") catch |err| {
        say(switch (err) {
            error.NoService => "tone: the sound service is not answering\n",
            else => "tone: refused; is there a sound device?\n",
        });
        return;
    };
    defer port.close();

    var generator = audio.Tone.at(hertz, proto.SHAPE, 12000);
    var left = proto.SHAPE.bytesPerMs(ms);
    var chunk: [2048]u8 = undefined;

    while (left > 0) {
        const want = @min(left, chunk.len);
        generator.fill(chunk[0..want], proto.SHAPE);

        var sent: usize = 0;
        while (sent < want) {
            const n = port.write(chunk[sent..want]);
            sent += n;
            // A full ring waits for the engine, never spins: the service
            // signals the port event as each period drains.
            if (n == 0) _ = sys.eventWait(port.waitHandle(), sys.FOREVER);
        }
        left -= want;
    }

    // Written is not heard: the ring drains at the speed of sound. The
    // wait is the tail of the tone.
    while (!port.drained()) {
        _ = sys.eventWait(port.waitHandle(), 200_000);
    }
}

fn say(text: []const u8) void {
    out.text(text);
    out.flush();
}

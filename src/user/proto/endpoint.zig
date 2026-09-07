//! One end of a service that answers a request with a reply.
//!
//! Every service on this system that answers questions works the same way: a
//! caller connects by name, sends a request as bytes, and takes back a reply
//! at least as long as its own type, whose first field says what happened.
//! Written out once per service, that sequence drifted. Some clients checked
//! the reply's length and some did not; a request too short to be one was
//! refused by one server, answered as `unknown` by another, and read past its
//! end by a third.
//!
//! The service's own module says what its messages look like and what its
//! statuses mean. Everything about carrying them is here.

const std = @import("std");
const sys = @import("sys");

/// The two ends of one service.
///
/// `Rep` must open with a `status` field whose type carries a `check` method,
/// since only the service knows what its statuses mean. `Error` is what that
/// returns; the two ways the conversation itself fails are added here, so a
/// service naming its own answers does not have to name those as well.
pub fn Endpoint(
    comptime service_name: []const u8,
    comptime Req: type,
    comptime Rep: type,
    comptime Error: type,
) type {
    return struct {
        pub const SERVICE = service_name;

        /// What a call answers with: whatever the statuses mean, and the two
        /// ways the conversation itself fails.
        pub const CallError = Error || error{ NoService, Refused };

        /// Ask, opening a channel for this one question.
        pub fn call(request: Req, into: *Rep) CallError!void {
            const channel = sys.svcConnect(SERVICE) catch return error.NoService;
            defer sys.close(channel);
            return callOn(channel, request, into);
        }

        /// Ask on a channel the caller keeps open, which is what a walk over a
        /// table uses: asking one service the same question once per row is
        /// then one connection rather than one per answer.
        pub fn callOn(channel: u32, request: Req, into: *Rep) CallError!void {
            var reply = sys.Message{};
            return exchange(channel, request, into, &reply);
        }

        /// The same, keeping the handles the reply carries. A reply short of
        /// them is refused: half a grant is nothing to hold.
        pub fn callTaking(channel: u32, request: Req, into: *Rep, handles: []u32) CallError!void {
            var reply = sys.Message{};
            try exchange(channel, request, into, &reply);

            const got = reply.handleSlice();
            if (got.len < handles.len) return error.Refused;
            @memcpy(handles, got[0..handles.len]);
        }

        fn exchange(channel: u32, request: Req, into: *Rep, reply: *sys.Message) CallError!void {
            const message = sys.Message.init(std.mem.asBytes(&request), &.{});
            if (sys.callMsg(channel, &message, reply) < 0) return error.Refused;

            const bytes = reply.bytes();
            if (bytes.len < @sizeOf(Rep)) return error.Refused;
            into.* = @as(*const Rep, @ptrCast(@alignCast(bytes.ptr))).*;

            return into.status.check();
        }

        /// The request in a message, or nothing when the message is too short
        /// to hold one. A truncated request is not a request, and the server
        /// that reads one anyway reads whatever follows it in the payload.
        pub fn requestIn(message: *const sys.Message) ?*const Req {
            const bytes = message.bytes();
            if (bytes.len < @sizeOf(Req)) return null;
            return @ptrCast(@alignCast(bytes.ptr));
        }

        /// Answer one request.
        pub fn answer(channel: u32, token: u32, reply: *const Rep) void {
            var message = sys.Message.init(std.mem.asBytes(reply), &.{});
            _ = sys.replyMsg(channel, token, &message);
        }

        /// Answer one request, handing over handles with it.
        pub fn answerWith(channel: u32, token: u32, reply: *const Rep, handles: []const u32) void {
            var message = sys.Message.init(std.mem.asBytes(reply), handles);
            _ = sys.replyMsg(channel, token, &message);
        }

        comptime {
            if (@sizeOf(Rep) > sys.MAX_PAYLOAD) {
                @compileError(SERVICE ++ ": a reply must fit one payload");
            }
            if (@sizeOf(Req) > sys.MAX_PAYLOAD) {
                @compileError(SERVICE ++ ": a request must fit one payload");
            }
        }
    };
}

# echat

An IRC client. Not part of the system: it is built on its own and installed
into `/home`, like everything else in `apps/`.

## What is here

    irc.zig                the engine, as one namespace
    irc/line.zig           line parsing, rendering and framing
    irc/support.zig        RPL_ISUPPORT and what depends on it
    irc/session.zig        connecting and staying connected
    irc/vectors.zig        generated from the reference test cases

The engine is protocol only. It opens no socket, waits for nothing and
allocates nothing: lines go in as bytes and come out as bytes. So all of it
runs on the host, and `make echat` tests it against the same vectors other
implementations use.

The client sits on top. It owns the connections, the buffers and the window,
and asks the engine what the bytes mean. Up to four networks at once, each
with its own socket; the wait sleeps on all of them, so a line arriving wakes
the window rather than a timer finding it.

Commands are `/server`, `/join`, `/part`, `/nick`, `/topic`, `/me`, `/msg` and
`/quit`. Anything else typed after a slash goes as written, so a network's own
commands work without this client knowing each one.

It reaches a network on 6667. TLS is not written yet: `std.crypto.tls` is the
one to use when it is, and the connection belongs with `netd`, which owns the
network, rather than in each program that wants one.

## The protocol

RFC 1459's line grammar, extended by IRCv3 message tags:

    ['@' tags SPACE] [':' source SPACE] command *(SPACE param) [SPACE ':' trailing]

Parsing happens in place. Tag escapes are two bytes for one, so unescaping
only ever shrinks and the parsed fields point into the buffer the line arrived
in. No copy, no allocation.

Registration is a negotiation. The client requests the capability list at
version 302, which allows capability values, replies split across lines, and
capabilities that appear or disappear while connected. It requests what it
both wants and was offered, authenticates if it has credentials, and only then
lets registration finish.

What it requests, and what each is used for:

    account-notify      who is logged in as whom, on change
    account-tag         and on each message
    away-notify         away and back, pushed rather than polled
    batch               which batch a run of lines belongs to
    cap-notify          capabilities added and removed while connected
    chghost             a host changing under a name already on screen
    echo-message        our own messages echoed back, so one path draws them all
    extended-join       the account and real name on a join
    invite-notify       invites, seen by the channel
    message-tags        tags generally, including the message id and client tags
    multi-prefix        all of a name's membership prefixes, not just the first
    sasl                account authentication
    server-time         when a line was sent, not when it arrived
    setname             a real name changing
    standard-replies    failures worded the same way across networks
    userhost-in-names   the full mask in the member list

Authentication uses SASL: `PLAIN` with a password, `EXTERNAL` where the
transport already presented a certificate. The response is sent in 400-byte
pieces, and one that fills a piece exactly is followed by an empty piece so
the server knows where it ended.

Networks differ in their dialect, so nothing assumes the defaults. `RPL_ISUPPORT`
decides which characters start a channel, which prefixes map to which
membership modes, whether two names are equal, and whether a letter on a
`MODE` line takes the next parameter.

## Testing

    make echat

Runs the engine against `third_party/irc-parser-tests`, transcribed into
`irc/vectors.zig` by `make irctests`. That covers 60 cases: splitting a line
into atoms, rendering atoms back into a line, and splitting a source into nick,
user and host. The rest of the tests play a server against the session, from
the opening lines through to a connection that stopped answering.

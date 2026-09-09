//! WPA2 with a pre-shared key: the supplicant's arithmetic, and the frames
//! it speaks.
//!
//! Pure and host-tested, since every number here is either the standard's
//! own or a property that can be checked against it: the pairwise master
//! key from a passphrase, the pairwise transient key from the two nonces,
//! the integrity code on a key frame, the unwrapping of the group key, and
//! the counter-mode cipher that protects every data frame after. The
//! standard library carries the hashes and the block cipher; what is here is
//! the way 802.11 puts them together, which nothing in the library knows.
//!
//! The handshake is a value: a station hands it each key frame it receives
//! and gets back the frame to send, or nothing, or a refusal. It never
//! touches a radio, so a test can play the access point.

const std = @import("std");
const ieee80211 = @import("ieee80211.zig");
const mac = @import("mac.zig");
const wifi = @import("wifi.zig");

const HmacSha1 = std.crypto.auth.hmac.HmacSha1;
const Aes128 = std.crypto.core.aes.Aes128;

/// Overwrite a value's bytes where it lies, so that whatever held a
/// secret no longer does.
///
/// Not `@memset`, which a compiler is free to drop when it can see that
/// nothing reads the bytes again: the whole point here is that something
/// might, later, from a core dump, a reused buffer or a value the caller
/// only thought it had finished with. Written over the value rather than
/// over a slice of it because that is the mistake this kind of code makes:
/// the field that was scrubbed is not the field that held the key.
pub fn scrub(value: anytype) void {
    std.crypto.secureZero(u8, @volatileCast(std.mem.asBytes(value)));
}

/// The pairwise master key: what the passphrase becomes, and what both
/// sides hold before a word is exchanged. The same bytes configuration
/// holds when a slot stores the derived key instead of the words.
pub const Pmk = [wifi.Psk.KEY_BYTES]u8;

const NONCE_LEN = 32;
pub const Nonce = [NONCE_LEN]u8;

/// The pairwise master key from a passphrase and the network's name, by
/// the standard's own derivation: four thousand and ninety-six rounds of
/// the password-based function over the name.
pub fn derive(passphrase: []const u8, ssid: []const u8) Pmk {
    var out: Pmk = undefined;
    // The parameters are the standard's and fixed, so the derivation cannot
    // be asked for something it refuses.
    std.crypto.pwhash.pbkdf2(&out, passphrase, ssid, 4096, HmacSha1) catch unreachable;
    return out;
}

/// The master key a configured secret gives on a network: a passphrase is
/// derived against the name, a stored key is itself, and no secret is no
/// key, which is what an open network has.
pub fn pmkOf(psk: wifi.Psk, ssid: wifi.Ssid) ?Pmk {
    return switch (psk) {
        .none => null,
        .passphrase => |words| derive(words.slice(), ssid.slice()),
        .key => |key| key,
    };
}

/// The pairwise transient key: three sixteen-byte keys, for the integrity
/// code on key frames, for unwrapping the group key, and for the data.
pub const Ptk = struct {
    kck: [16]u8,
    kek: [16]u8,
    tk: [16]u8,
};

/// The pairwise transient key from the master key and what the two sides
/// said: the standard's pseudo-random function over the addresses and the
/// nonces, each pair in numerical order so both sides compute the same.
pub fn ptkOf(pmk: Pmk, aa: mac.Address, spa: mac.Address, anonce: Nonce, snonce: Nonce) Ptk {
    var data: [12 + 2 * NONCE_LEN]u8 = undefined;
    const addresses_in_order = std.mem.lessThan(u8, &aa, &spa);
    @memcpy(data[0..6], if (addresses_in_order) &aa else &spa);
    @memcpy(data[6..12], if (addresses_in_order) &spa else &aa);
    const nonces_in_order = std.mem.lessThan(u8, &anonce, &snonce);
    @memcpy(data[12..][0..NONCE_LEN], if (nonces_in_order) &anonce else &snonce);
    @memcpy(data[12 + NONCE_LEN ..][0..NONCE_LEN], if (nonces_in_order) &snonce else &anonce);

    // Forty-eight bytes from three turns of the function, the third cut short.
    var out: [3 * HmacSha1.mac_length]u8 = undefined;
    for (0..3) |turn| {
        var h = HmacSha1.init(&pmk);
        h.update("Pairwise key expansion");
        h.update(&[_]u8{0});
        h.update(&data);
        h.update(&[_]u8{@intCast(turn)});
        h.final(out[turn * HmacSha1.mac_length ..][0..HmacSha1.mac_length]);
    }
    return .{ .kck = out[0..16].*, .kek = out[16..32].*, .tk = out[32..48].* };
}

/// The integrity code on a key frame: the first sixteen bytes of the
/// keyed hash over the whole frame with the code's own field zeroed.
pub fn micOf(kck: [16]u8, frame: []const u8) [16]u8 {
    var whole: [HmacSha1.mac_length]u8 = undefined;
    HmacSha1.create(&whole, frame, &kck);
    return whole[0..16].*;
}

// ---------------------------------------------------------------------------
// The key wrap, for the group key that travels inside a key frame
// ---------------------------------------------------------------------------

/// The value the wrap starts from and the unwrap must find again.
const WRAP_CHECK = [_]u8{0xA6} ** 8;

/// Wrap `plain`, a whole number of eight-byte blocks, under `kek`, into
/// `into`, which takes eight bytes more. What the access point does to the
/// group key; here so the unwrap has something to be tested against.
pub fn wrap(kek: [16]u8, plain: []const u8, into: []u8) ?[]u8 {
    if (plain.len < 16 or plain.len % 8 != 0 or into.len < plain.len + 8) return null;
    const n = plain.len / 8;
    const out = into[0 .. plain.len + 8];
    var a: [8]u8 = WRAP_CHECK;
    const r = out[8..];
    @memcpy(r, plain);

    const enc = Aes128.initEnc(kek);
    for (0..6) |j| {
        for (1..n + 1) |i| {
            var block: [16]u8 = undefined;
            @memcpy(block[0..8], &a);
            @memcpy(block[8..16], r[(i - 1) * 8 ..][0..8]);
            var sealed: [16]u8 = undefined;
            enc.encrypt(&sealed, &block);
            a = sealed[0..8].*;
            fold(&a, n * j + i);
            @memcpy(r[(i - 1) * 8 ..][0..8], sealed[8..16]);
        }
    }
    @memcpy(out[0..8], &a);
    return out;
}

/// Unwrap what `wrap` made, under the same key, into `into`, which takes
/// eight bytes less. Null when the key is wrong or the wrapping torn, which
/// the check value tells apart from a key that merely differs by nothing.
pub fn unwrap(kek: [16]u8, wrapped: []const u8, into: []u8) ?[]u8 {
    if (wrapped.len < 24 or wrapped.len % 8 != 0 or into.len < wrapped.len - 8) return null;
    const n = wrapped.len / 8 - 1;
    const r = into[0 .. n * 8];
    var a: [8]u8 = wrapped[0..8].*;
    @memcpy(r, wrapped[8..]);

    const dec = Aes128.initDec(kek);
    var j: usize = 6;
    while (j > 0) {
        j -= 1;
        var i: usize = n;
        while (i > 0) : (i -= 1) {
            fold(&a, n * j + i);
            var block: [16]u8 = undefined;
            @memcpy(block[0..8], &a);
            @memcpy(block[8..16], r[(i - 1) * 8 ..][0..8]);
            var plain: [16]u8 = undefined;
            dec.decrypt(&plain, &block);
            a = plain[0..8].*;
            @memcpy(r[(i - 1) * 8 ..][0..8], plain[8..16]);
        }
    }
    if (!std.crypto.timing_safe.eql([8]u8, a, WRAP_CHECK)) return null;
    return r;
}

/// Fold the step count into the running value, as the eight big-endian
/// bytes the wrap counts in.
fn fold(a: *[8]u8, step: usize) void {
    var counted: [8]u8 = undefined;
    std.mem.writeInt(u64, &counted, step, .big);
    for (a, counted) |*byte, count| byte.* ^= count;
}

// ---------------------------------------------------------------------------
// Counter mode with a CBC message code: the cipher under every data frame
// ---------------------------------------------------------------------------

/// AES in the counter-with-CBC-MAC construction, with the eight-byte code
/// and two-byte length the standard fixes for 802.11.
/// The cipher this key exchange's traffic is sealed under: counter mode
/// with a chained code over the same key, in the shape 802.11 fixes for
/// it. An eight-byte code and a thirteen-byte nonce are what the standard
/// names, and what the library's own construction takes.
pub const Ccm = struct {
    pub const MIC = Aead.tag_length;
    pub const NONCE = Aead.nonce_length;

    const Aead = std.crypto.aead.aes_ccm.Aes128Ccm8;

    /// Seal `plain` under `key` and `nonce`, binding `aad` without
    /// encrypting it: the ciphertext followed by the code, into `into`.
    pub fn seal(key: [16]u8, nonce: [NONCE]u8, aad: []const u8, plain: []const u8, into: []u8) ?usize {
        if (into.len < plain.len + MIC or plain.len > std.math.maxInt(u16) or aad.len >= 0xFF00) return null;

        var code: [MIC]u8 = undefined;
        Aead.encrypt(into[0..plain.len], &code, plain, aad, nonce, key);
        @memcpy(into[plain.len..][0..MIC], &code);
        return plain.len + MIC;
    }

    /// Open what `seal` made, into `into`; null when the code does not
    /// match, in which case nothing of the plaintext is to be believed.
    pub fn open(key: [16]u8, nonce: [NONCE]u8, aad: []const u8, sealed: []const u8, into: []u8) ?usize {
        if (sealed.len < MIC) return null;
        const body = sealed[0 .. sealed.len - MIC];
        if (into.len < body.len or aad.len >= 0xFF00) return null;

        const code: [MIC]u8 = sealed[body.len..][0..MIC].*;
        Aead.decrypt(into[0..body.len], body, code, aad, nonce, key) catch {
            @memset(into[0..body.len], 0);
            return null;
        };
        return body.len;
    }
};

// ---------------------------------------------------------------------------
// The counter-mode protocol on a frame: nonce, bound header, packet number
// ---------------------------------------------------------------------------

/// The protection on a data frame: eight bytes of packet number and key
/// index between the header and the payload, the payload sealed, the code
/// at the end.
pub const Ccmp = struct {
    pub const HEADER = 8;
    pub const MIC = Ccm.MIC;
    /// A packet number, forty-eight bits, never repeated under one key.
    pub const Pn = u48;

    /// The byte of the cipher's header that names the key: the extended
    /// form's flag, which this cipher always sets, and the key's index.
    const KeyByte = packed struct(u8) {
        _0: u5 = 0,
        extended_iv: bool = true,
        key_index: u2 = 0,
    };

    /// What `unprotect` found: how long the plaintext is, and the number
    /// the frame carried, for the replay check the caller keeps.
    pub const Opened = struct { len: usize, pn: Pn, key_index: u2 };

    /// Write the frame with its header, the cipher's own header, and the
    /// payload sealed under `tk`, into `into`.
    pub fn protect(tk: [16]u8, head: ieee80211.Header, pn: Pn, key_index: u2, payload: []const u8, into: []u8) ?usize {
        var sealed_head = head;
        sealed_head.control.protected = true;
        const written = sealed_head.write(into) orelse return null;
        if (into.len < written + HEADER + payload.len + MIC) return null;

        writeCipherHeader(into[written..][0..HEADER], pn, key_index);

        var bound: [BOUND_MAX]u8 = undefined;
        const aad = boundHeader(sealed_head, &bound);
        const sealed = Ccm.seal(tk, nonceOf(sealed_head, pn), aad, payload, into[written + HEADER ..]) orelse return null;
        return written + HEADER + sealed;
    }

    /// Which key a protected frame names, so the caller can pick it
    /// before opening the frame.
    pub fn keyIndexOf(frame: []const u8) ?u2 {
        const head = ieee80211.Header.parse(frame) orelse return null;
        if (!head.control.protected or frame.len < head.len + HEADER) return null;
        const key_byte: KeyByte = @bitCast(frame[head.len + 3]);
        return key_byte.key_index;
    }

    /// The plaintext of a protected frame, into `into`, or null for one that
    /// was torn or sealed under another key.
    pub fn unprotect(tk: [16]u8, frame: []const u8, into: []u8) ?Opened {
        const head = ieee80211.Header.parse(frame) orelse return null;
        if (!head.control.protected or head.control.kind != .data or
            head.control.more_fragments or head.sequence.fragment != 0) return null;
        if (head.qos) |qos| {
            if (qos.amsdu) return null;
        }
        if (frame.len < head.len + HEADER + MIC) return null;

        const cipher_head = frame[head.len..][0..HEADER];
        const key_byte: KeyByte = @bitCast(cipher_head[3]);
        if (!key_byte.extended_iv or key_byte._0 != 0 or cipher_head[2] != 0) return null;
        const pn = pnOf(cipher_head);

        var bound: [BOUND_MAX]u8 = undefined;
        const aad = boundHeader(head, &bound);
        const len = Ccm.open(tk, nonceOf(head, pn), aad, frame[head.len + HEADER ..], into) orelse return null;
        return .{ .len = len, .pn = pn, .key_index = key_byte.key_index };
    }

    /// The cipher's header: the packet number's two low bytes, a byte
    /// reserved, the key byte, and the four high bytes, least significant
    /// first throughout.
    fn writeCipherHeader(into: *[HEADER]u8, pn: Pn, key_index: u2) void {
        var number: [6]u8 = undefined;
        std.mem.writeInt(Pn, &number, pn, .little);
        into[0..2].* = number[0..2].*;
        into[2] = 0;
        into[3] = @bitCast(KeyByte{ .key_index = key_index });
        into[4..8].* = number[2..6].*;
    }

    fn pnOf(head: *const [HEADER]u8) Pn {
        var number: [6]u8 = undefined;
        number[0..2].* = head[0..2].*;
        number[2..6].* = head[4..8].*;
        return std.mem.readInt(Pn, &number, .little);
    }

    /// The nonce: the frame's priority, the sender's address and the
    /// packet number, which is what makes every frame's cipher stream its
    /// own.
    fn nonceOf(head: ieee80211.Header, pn: Pn) [Ccm.NONCE]u8 {
        var nonce: [Ccm.NONCE]u8 = undefined;
        nonce[0] = if (head.qos) |qos| qos.tid else 0;
        @memcpy(nonce[1..7], &head.addr2);
        std.mem.writeInt(Pn, nonce[7..13], pn, .big);
        return nonce;
    }

    const BOUND_MAX = 32;

    /// The header as the code binds it: the parts that do not change
    /// between the sender and the receiver, with the retry, power and
    /// more-data bits cleared and the sequence number masked, since a
    /// retransmission carries the same code.
    fn boundHeader(head: ieee80211.Header, into: *[BOUND_MAX]u8) []const u8 {
        var control = head.control;
        control.retry = false;
        control.power_management = false;
        control.more_data = false;
        control.protected = true;
        if (control.kind == .data) {
            // A data frame is bound by whether it carries a
            // quality-of-service word and by nothing else its subtype
            // said: the three low bits are masked, the flag that says
            // there is a word is kept.
            control.subtype &= @intFromEnum(ieee80211.DataSubtype.qos_data);
            // And on one that does carry it, the order bit says a
            // high-throughput word follows rather than anything about
            // ordering, so it is not bound either.
            if (head.qos != null) control.order = false;
        }

        std.mem.writeInt(u16, into[0..2], @bitCast(control), .little);
        @memcpy(into[2..8], &head.addr1);
        @memcpy(into[8..14], &head.addr2);
        @memcpy(into[14..20], &head.addr3);
        const sequence = ieee80211.SequenceControl{ .fragment = head.sequence.fragment };
        std.mem.writeInt(u16, into[20..22], @bitCast(sequence), .little);
        var at: usize = 22;
        if (head.addr4) |fourth| {
            @memcpy(into[at..][0..6], &fourth);
            at += 6;
        }
        if (head.qos) |qos| {
            const tid_only = ieee80211.QosControl{ .tid = qos.tid };
            std.mem.writeInt(u16, into[at..][0..2], @bitCast(tid_only), .little);
            at += 2;
        }
        return into[0..at];
    }
};

// ---------------------------------------------------------------------------
// Key frames: what the four-way handshake is made of
// ---------------------------------------------------------------------------

/// The key information word of a key frame.
pub const KeyInfo = packed struct(u16) {
    /// Two names the hash and the wrap this file implements.
    version: u3 = 2,
    pairwise: bool = false,
    key_index: u2 = 0,
    install: bool = false,
    ack: bool = false,
    mic: bool = false,
    secure: bool = false,
    err: bool = false,
    request: bool = false,
    encrypted: bool = false,
    smk: bool = false,
    _14: u2 = 0,
};

/// A key frame, parsed. The key data stays in the frame it came in.
pub const KeyFrame = struct {
    info: KeyInfo,
    key_length: u16,
    replay: u64,
    nonce: Nonce,
    /// Where the sender's numbering under the key it is handing over has
    /// got to, so a receiver starts counting from there rather than from
    /// nothing and a frame already in the air is not taken twice.
    rsc: Ccmp.Pn,
    mic: [16]u8,
    data: []const u8,
    /// How much of the buffer the frame declared itself to be. A frame
    /// arrives inside another, and what carried it may be padded to a
    /// length of its own; everything past this belongs to the carrier.
    len: usize,

    /// Where each field sits: the 802.1X header, then the descriptor.
    const At = struct {
        const version = 0;
        const packet_type = 1;
        const body_length = 2;
        const descriptor = 4;
        const info = 5;
        const key_length = 7;
        const replay = 9;
        const nonce = 17;
        const iv = 49;
        const rsc = 65;
        const id = 73;
        const mic = 81;
        const data_length = 97;
        const data = 99;
    };

    /// The 802.1X header and the descriptor's fixed part: everything
    /// before the key data.
    pub const HEAD = At.data;
    /// Where the integrity code sits in the frame.
    pub const MIC_AT = At.mic;
    const VERSION: u8 = 2;
    const KEY_PACKET: u8 = 3;
    const RSN_DESCRIPTOR: u8 = 2;

    pub fn parse(frame: []const u8) ?KeyFrame {
        if (frame.len < HEAD) return null;
        if (frame[At.version] != 1 and frame[At.version] != 2) return null;
        if (frame[At.packet_type] != KEY_PACKET or frame[At.descriptor] != RSN_DESCRIPTOR) return null;
        // One extent, checked once and used for everything after: the
        // frame is as long as its own header says, the key data fills the
        // rest of it exactly, and both fit in what arrived. Two lengths
        // agreeing separately with the buffer but not with each other is
        // a frame whose integrity code covers something other than what
        // was read out of it.
        //
        // Lengths off the air, summed wider than they are: a length near
        // the top of sixteen bits must fail the check, not wrap past it.
        const body_len: usize = std.mem.readInt(u16, frame[At.body_length..][0..2], .big);
        const len = At.descriptor + body_len;
        if (len > frame.len) return null;
        const data_len: usize = std.mem.readInt(u16, frame[At.data_length..][0..2], .big);
        if (HEAD + data_len != len) return null;
        return .{
            .info = @bitCast(std.mem.readInt(u16, frame[At.info..][0..2], .big)),
            .key_length = std.mem.readInt(u16, frame[At.key_length..][0..2], .big),
            .replay = std.mem.readInt(u64, frame[At.replay..][0..8], .big),
            .nonce = frame[At.nonce..][0..NONCE_LEN].*,
            .rsc = std.mem.readInt(Ccmp.Pn, frame[At.rsc..][0..6], .little),
            .mic = frame[At.mic..][0..16].*,
            .data = frame[At.data..][0..data_len],
            .len = len,
        };
    }

    /// What a key frame being written says.
    pub const Said = struct {
        info: KeyInfo,
        key_length: u16 = 0,
        replay: u64,
        nonce: Nonce = @splat(0),
        /// Where the sender's numbering under the key it is handing over
        /// has got to. Only a frame carrying a group key has one.
        rsc: Ccmp.Pn = 0,
        data: []const u8 = &.{},
    };

    /// Write a key frame with a zero integrity code, which `sign` fills
    /// once the rest is in place. Returns the frame's length.
    pub fn write(into: []u8, said: Said) ?usize {
        const len = HEAD + said.data.len;
        if (into.len < len or said.data.len > std.math.maxInt(u16)) return null;
        @memset(into[0..len], 0);
        into[At.version] = VERSION;
        into[At.packet_type] = KEY_PACKET;
        std.mem.writeInt(u16, into[At.body_length..][0..2], @intCast(len - At.descriptor), .big);
        into[At.descriptor] = RSN_DESCRIPTOR;
        std.mem.writeInt(u16, into[At.info..][0..2], @bitCast(said.info), .big);
        std.mem.writeInt(u16, into[At.key_length..][0..2], said.key_length, .big);
        std.mem.writeInt(u64, into[At.replay..][0..8], said.replay, .big);
        @memcpy(into[At.nonce..][0..NONCE_LEN], &said.nonce);
        std.mem.writeInt(Ccmp.Pn, into[At.rsc..][0..6], said.rsc, .little);
        std.mem.writeInt(u16, into[At.data_length..][0..2], @intCast(said.data.len), .big);
        @memcpy(into[At.data..][0..said.data.len], said.data);
        return len;
    }

    /// Put the integrity code into a written frame.
    pub fn sign(frame: []u8, kck: [16]u8) void {
        @memset(frame[MIC_AT..][0..16], 0);
        const code = micOf(kck, frame);
        @memcpy(frame[MIC_AT..][0..16], &code);
    }

    /// Whether this frame's integrity code is the one `kck` gives it.
    ///
    /// Over exactly what the frame said it was, which is not always what
    /// arrived: a key frame travels inside a data frame, and a link that
    /// pads its frames to a length of its own would otherwise have that
    /// padding hashed and a correctly signed frame refused.
    pub fn verify(self: KeyFrame, frame: []const u8, kck: [16]u8) bool {
        if (frame.len < self.len) return false;
        var copy: [HEAD + KEY_DATA_MAX]u8 = undefined;
        if (self.len > copy.len) return false;
        @memcpy(copy[0..self.len], frame[0..self.len]);
        @memset(copy[MIC_AT..][0..16], 0);
        const code = micOf(kck, copy[0..self.len]);
        return std.crypto.timing_safe.eql([16]u8, code, self.mic);
    }
};

/// The most key data a frame is given room for here: an RSN element and a
/// wrapped group key, with room to spare for what an access point adds.
pub const KEY_DATA_MAX = 256;

/// The group temporal key as message three delivers it.
pub const Gtk = struct {
    index: u2,
    key: [16]u8,
};

// ---------------------------------------------------------------------------
// The keys an association is protected by, and the numbering under them
// ---------------------------------------------------------------------------

/// One installed key.
pub const Key = struct {
    bytes: [16]u8,
    /// Replay identity: identical key bytes keep this generation, even
    /// when installed under another group index.
    generation: u32,
    /// Where the sender's numbering had got to when it handed the key
    /// over: nought for the pairwise key, which this station proved and
    /// which nothing has been sent under yet, and the access point's own
    /// count for a group key it has been using all along.
    from: Ccmp.Pn = 0,
};

/// The keys an association is protected by.
pub const Keys = struct {
    /// This station's own, which only it and the access point hold.
    pairwise: Key,
    /// The one it replaced, kept until a frame arrives under the new one.
    ///
    /// A rekey finishes on a frame this station sends, and the access
    /// point installs its own side only once that frame arrives. Anything
    /// it sends in between, its own last message again among them, is
    /// still under the key being replaced, and a station that had thrown
    /// that key away could not read it.
    previous: ?Key = null,
    /// The room's, by the index the access point gives each. A renewal
    /// brings the next index while frames under the last are still in the
    /// air, so both are kept.
    group: [4]?Key = @splat(null),

    /// The group key a frame names, if the access point has given one
    /// under that index.
    pub fn groupKey(self: Keys, index: u2) ?Key {
        return self.group[index];
    }

    /// Wipe the keys. An association that has ended leaves its keys in
    /// whatever held them, and a value in a service's static state is not
    /// a stack frame about to be reused: forgetting where a key was is
    /// not the same as destroying it.
    pub fn erase(self: *Keys) void {
        scrub(self);
    }
};

/// Two live TX generations: changing to the new key must not forget the
/// old key's last PN, since a rekey M4 retry still uses that key.
pub const TxNumbering = struct {
    current: struct { generation: u32 = 0, pn: Ccmp.Pn = 0 } = .{},
    previous: struct { generation: u32 = 0, pn: Ccmp.Pn = 0 } = .{},

    pub fn next(self: *TxNumbering, key: Key) ?Ccmp.Pn {
        if (self.previous.generation == key.generation) {
            if (self.previous.pn == std.math.maxInt(Ccmp.Pn)) return null;
            self.previous.pn += 1;
            return self.previous.pn;
        }
        if (self.current.generation != key.generation) {
            self.previous = .{ .generation = self.current.generation, .pn = self.current.pn };
            self.current = .{ .generation = key.generation };
        }
        if (self.current.pn == std.math.maxInt(Ccmp.Pn)) return null;
        self.current.pn += 1;
        return self.current.pn;
    }
};

/// The numbering a receiver keeps under an association's keys.
///
/// A packet number is never used twice under one key, so a frame numbered
/// at or below one already accepted is a copy of a frame already
/// delivered. Delivering it again is what a replay is, and the only thing
/// that stops one is the receiver remembering where it has got to. The
/// count is per key, and per traffic class under the pairwise key, since
/// the classes are numbered apart from each other and a busy one must not
/// shut a quiet one out.
pub const Numbering = struct {
    /// How many traffic classes a frame can name. The quality-of-service
    /// field holds sixteen; the eight user priorities are what a station
    /// sees, and anything above them is counted with the last.
    pub const CLASSES = 8;

    pairwise: [CLASSES]Seen = @splat(.{}),
    /// The count under the key the current one replaced, kept apart from
    /// it: two keys are numbered independently, and one set of counters
    /// shared between them would have each frame reset the other's.
    superseded: [CLASSES]Seen = @splat(.{}),
    group: [4]Seen = @splat(.{}),
    /// Whether anything has yet arrived under the current pairwise key.
    /// Once something has, the one it replaced is finished with.
    current_heard: u32 = 0,
    /// Whether anything at all has arrived sealed under a key of this
    /// association, and which installation that was. This station's own
    /// traffic counts, and so does the room's: the group key arrives
    /// wrapped under the pairwise one, so a group frame that opens is as
    /// much proof that the access point finished the exchange as a frame
    /// addressed here. Once something has, nothing the cell says in the
    /// clear is believed.
    sealed_heard: u32 = 0,
    generation: u32 = 0,

    const Seen = struct {
        generation: u32 = 0,
        pn: Ccmp.Pn = 0,

        /// Whether this number is a new one under this key, remembering
        /// it when it is. A key installed since the last frame starts the
        /// count again, from wherever its sender had got to.
        fn accept(self: *Seen, key: Key, pn: Ccmp.Pn) bool {
            if (self.generation != key.generation) self.* = .{ .generation = key.generation, .pn = key.from };
            self.pn = @max(self.pn, key.from);
            if (pn <= self.pn) return false;
            self.pn = pn;
            return true;
        }
    };

    /// Forget everything. A new association counts from the start.
    pub fn clear(self: *Numbering) void {
        self.* = .{};
    }

    /// The plaintext of a protected frame, header and all, written into
    /// `into`.
    ///
    /// Null for a frame that arrived unprotected, was sealed under a key
    /// this station does not hold, did not verify, or carries a number
    /// already seen. A caller with keys has no business reading a frame
    /// this refuses: on a protected association everything is protected,
    /// and what is not is either somebody else's or nobody's.
    pub fn open(self: *Numbering, keys: Keys, frame: []const u8, into: []u8) ?[]const u8 {
        const head = ieee80211.Header.parse(frame) orelse return null;
        if (!head.control.protected or head.len >= into.len) return null;
        if (self.generation != keys.pairwise.generation) {
            // Move the actual counters, not just the key, across a rekey.
            if (keys.previous) |before| {
                if (before.generation == self.generation) self.superseded = self.pairwise;
            } else self.superseded = @splat(.{});
            self.pairwise = @splat(.{});
            self.generation = keys.pairwise.generation;
        }

        const named = Ccmp.keyIndexOf(frame) orelse return null;
        const group = mac.isGroup(head.addr1);
        // The pairwise key is always the first: a frame to this station
        // naming another index is not one it has a key for.
        if (!group and named != 0) return null;

        @memcpy(into[0..head.len], frame[0..head.len]);
        if (group) {
            const history = self.group;
            for (keys.group, 0..) |slot, index| {
                if (slot) |key| {
                    for (history) |seen| {
                        if (seen.generation == key.generation and
                            (self.group[index].generation != key.generation or self.group[index].pn < seen.pn))
                            self.group[index] = seen;
                    }
                }
            }
            const key = keys.groupKey(named) orelse return null;
            const got = Ccmp.unprotect(key.bytes, frame, into[head.len..]) orelse return null;
            // KeyID is not authenticated by CCMP. Aliases must share the
            // highest accepted PN, including an index installed later.
            for (self.group) |seen| {
                if (seen.generation == key.generation and got.pn <= seen.pn) return null;
            }
            if (!self.group[named].accept(key, got.pn)) return null;
            for (keys.group, 0..) |slot, index| {
                if (slot) |alias| {
                    if (alias.generation == key.generation) self.group[index] = self.group[named];
                }
            }
            self.sealed_heard = keys.pairwise.generation;
            return into[0 .. head.len + got.len];
        }

        // This station's own key, and the one it replaced. A rekey
        // finishes on a frame this station sends, so until one arrives
        // under the new key the access point is still speaking under the
        // old, its own last message among them. The moment one does, the
        // old key is finished with for good.
        const class = classOf(head);
        if (Ccmp.unprotect(keys.pairwise.bytes, frame, into[head.len..])) |got| {
            if (!self.pairwise[class].accept(keys.pairwise, got.pn)) return null;
            if (self.current_heard != keys.pairwise.generation) {
                self.current_heard = keys.pairwise.generation;
                self.superseded = @splat(.{});
            }
            self.sealed_heard = keys.pairwise.generation;
            return into[0 .. head.len + got.len];
        }
        if (self.current_heard == keys.pairwise.generation) return null;
        const before = keys.previous orelse return null;
        const got = Ccmp.unprotect(before.bytes, frame, into[head.len..]) orelse return null;
        if (!self.superseded[class].accept(before, got.pn)) return null;
        self.sealed_heard = keys.pairwise.generation;
        return into[0 .. head.len + got.len];
    }

    fn classOf(head: ieee80211.Header) usize {
        const qos = head.qos orelse return 0;
        return @min(qos.tid, CLASSES - 1);
    }
};

/// The key-data encapsulations this station reads: the group key, under
/// the standard's own vendor prefix.
const KDE_OUI = [_]u8{ 0x00, 0x0F, 0xAC };
const KDE_GTK: u8 = 1;

/// The byte after the group key's prefix: which key index it takes, and
/// whether the access point transmits with it.
const GtkFlags = packed struct(u8) {
    key_id: u2 = 0,
    transmit: bool = false,
    _3: u5 = 0,
};

/// The group key from a key frame's unwrapped data, or null when none is
/// there.
pub fn gtkOf(data: []const u8) ?Gtk {
    var rest = data;
    var gtk: ?Gtk = null;
    while (rest.len != 0) {
        if (rest[0] == 0xDD and (rest.len == 1 or rest[1] == 0)) {
            for (rest[1..]) |byte| if (byte != 0) return null;
            break;
        }
        if (rest.len < 2 or rest[1] > rest.len - 2) return null;
        const len: usize = rest[1];
        const payload = rest[2..][0..len];
        if (rest[0] == 0xDD and len >= 4 and
            std.mem.eql(u8, payload[0..3], &KDE_OUI) and payload[3] == KDE_GTK)
        {
            if (gtk != null or len != 22) return null;
            const flags: GtkFlags = @bitCast(payload[4]);
            if (flags._3 != 0 or payload[5] != 0) return null;
            gtk = .{ .index = flags.key_id, .key = payload[6..22].* };
        }
        rest = rest[2 + len ..];
    }
    return gtk;
}

/// Write a group-key encapsulation, for an access point, or a test
/// playing one.
pub fn writeGtk(into: []u8, gtk: Gtk) ?usize {
    const len = 2 + 4 + 2 + 16;
    if (into.len < len) return null;
    into[0] = @intFromEnum(ieee80211.ElementId.vendor);
    into[1] = len - 2;
    @memcpy(into[2..5], &KDE_OUI);
    into[5] = KDE_GTK;
    into[6] = @bitCast(GtkFlags{ .key_id = gtk.index, .transmit = true });
    into[7] = 0;
    @memcpy(into[8..24], &gtk.key);
    return len;
}

// ---------------------------------------------------------------------------
// The handshake
// ---------------------------------------------------------------------------

/// The key exchange, from the station's side. Given each key frame the
/// access point sends, it answers with the frame to send back, and holds
/// the keys to install: the pairwise key the four-way exchange proves, and
/// the group keys, which the access point renews for as long as the
/// station stays.
pub const Handshake = struct {
    pmk: Pmk,
    station: mac.Address,
    ap: mac.Address,
    /// The nonce this exchange offers, and the seed the chain of them is
    /// drawn from. The caller draws the seed, because a value cannot ask
    /// for randomness and stay one.
    snonce: Nonce,
    seed: Nonce,
    /// The security element this station offered when it associated, sent
    /// again in message two so the access point can see it was not
    /// changed.
    rsn: []const u8,
    ap_rsn: ieee80211.Rsn.Transcript,
    /// The pairwise key the exchange has proved: the one a signed frame
    /// from the access point checked out under.
    ptk: ?Ptk = null,
    /// The pairwise key the latest first message proposes, and the nonce
    /// that message carried. A first message is unsigned, so anyone can
    /// send one, and nothing is taken on its word: it becomes the key once
    /// a third message verifies under it and names the same nonce.
    candidate: ?Ptk = null,
    candidate_anonce: Nonce = @splat(0),
    candidate_replay: u64 = 0,
    proved_anonce: Nonce = @splat(0),
    third_data: [32]u8 = @splat(0),
    third_rsc: Ccmp.Pn = 0,
    last_group: ?[32]u8 = null,
    /// The group keys, by the index the access point gives each.
    group: [4]?Key = @splat(null),
    /// The highest counter an authenticated frame has carried. Only a
    /// frame that verified moves it: a first message is unsigned, and
    /// letting one set this would let anyone wind it back and make an old
    /// signed frame fresh again.
    replay: u64 = 0,
    /// How many keys have been installed, which is what names each one.
    installs: u32 = 0,
    /// Which installation the pairwise key in hand is.
    pairwise_at: u32 = 0,
    /// The pairwise key it replaced, for as long as the access point may
    /// still be speaking under it.
    was: ?Key = null,
    /// Whether the nonce is spent. Renewed between exchanges, not within
    /// one: an access point that did not hear the second message sends
    /// its first again and expects the same answer.
    spent: bool = false,
    /// Key frames that arrived signed and whose integrity code did not
    /// check out under any key this station holds.
    ///
    /// Counted because such a frame is otherwise invisible: it is not
    /// answered, it changes nothing, and the exchange it belongs to ends
    /// in a timeout like any other. Yet it is the ordinary shape of the
    /// commonest fault there is, a passphrase that is not the network's.
    /// An exchange that ends with several of these and no keys is a
    /// different thing from one where the access point never spoke, and
    /// the person typing the password deserves to be told which.
    mic_failures: u32 = 0,
    /// Whether a third message has ever arrived, whatever became of it.
    /// An exchange that ended without one ended at the far end, which is
    /// what a secret the access point does not share looks like; one that
    /// ended with several is this station refusing them, which is a fault
    /// on this side and a different thing to be told.
    seen_third: bool = false,
    done: bool = false,
    confirmed: u32 = 0,
    /// Identifies exactly the reply in `into`, never a previous answer.
    response: ?Response = null,

    pub const Response = struct {
        kind: enum { m2, m4, group2 },
        replay: u64,
        generation: u32,
    };

    pub const Outcome = union(enum) {
        /// Not a frame of this handshake, one already answered, or one that
        /// did not verify: nothing an unverified frame says changes
        /// anything, and refusing on its word would let anyone end a join.
        ignored,
        /// The frame to send back, this long, in the buffer given. The keys
        /// may have changed with it.
        reply: usize,
        /// A verified frame that carried nothing this station can use. The
        /// keys are not to be used.
        refused,
    };

    /// The keys, once the exchange is done.
    pub fn keys(self: *const Handshake) ?Keys {
        const ptk = self.ptk orelse return null;
        if (!self.done) return null;
        return .{
            .pairwise = .{ .bytes = ptk.tk, .generation = self.pairwise_at },
            .previous = self.was,
            .group = self.group,
        };
    }

    /// Whether the access point has opened the exchange. An exchange
    /// opened and never finished is what a wrong key looks like.
    pub fn begun(self: *const Handshake) bool {
        return self.candidate != null or self.ptk != null;
    }

    /// Wipe every secret this exchange holds: the master key, the
    /// transient keys, the group keys, the nonces and the frames written
    /// through them.
    ///
    /// An exchange that ends leaves its keys in the value that was
    /// holding it, and that value is a service's static state rather than
    /// a frame about to be reused, so setting it aside is not the same as
    /// destroying what was in it. Called on every path that ends an
    /// association, whether it ended well or badly. The erased handshake
    /// is finished: it is not one that can be answered again.
    pub fn erase(self: *Handshake) void {
        scrub(self);
    }

    /// Whether the access point ever answered this station's second
    /// message.
    pub fn answered(self: *const Handshake) bool {
        return self.seen_third;
    }

    /// Answer a key frame from the access point.
    pub fn answer(self: *Handshake, frame: []const u8, into: []u8) Outcome {
        self.response = null;
        const key = KeyFrame.parse(frame) orelse return .ignored;
        if (!key.info.ack or key.info.version != 2 or key.info.key_index != 0 or key.info.err or key.info.request or
            key.info.smk or key.info._14 != 0) return .ignored;
        if (!std.mem.allEqual(u8, frame[KeyFrame.At.iv..KeyFrame.At.rsc], 0) or
            !std.mem.allEqual(u8, frame[KeyFrame.At.rsc + 6 .. KeyFrame.At.mic], 0)) return .ignored;
        if (!key.info.mic and (!std.mem.allEqual(u8, &key.mic, 0) or key.rsc != 0)) return .ignored;

        // The group key handshake stands apart from the pairwise one.
        // Message one: the access point's nonce, and nothing signed yet.
        // Message three: signed, with the keys to install inside it.
        if (!key.info.pairwise) return self.renewal(frame, key, into);
        if (!key.info.mic and !key.info.install and !key.info.secure and !key.info.encrypted)
            return self.first(key, into);
        if (key.info.mic and key.info.install and key.info.secure and key.info.encrypted)
            return self.third(frame, key, into);
        return .ignored;
    }

    fn first(self: *Handshake, key: KeyFrame, into: []u8) Outcome {
        if (key.key_length != 16 or key.replay <= self.replay or
            std.mem.allEqual(u8, &key.nonce, 0)) return .ignored;
        // M1 may carry only the optional PMKID KDE, not arbitrary key data.
        if (key.data.len != 0 and (key.data.len != 22 or
            !std.mem.eql(u8, key.data[0..6], &.{ 0xDD, 20, 0, 0x0F, 0xAC, 4 }))) return .ignored;
        if (self.candidate != null and key.replay < self.candidate_replay) return .ignored;
        if (self.candidate != null and key.replay == self.candidate_replay and
            !std.mem.eql(u8, &key.nonce, &self.candidate_anonce)) return .ignored;
        if (self.spent) {
            self.installs += 1;
            self.snonce = nonceAfter(self.seed, self.installs);
            self.spent = false;
        }
        const candidate = ptkOf(self.pmk, self.ap, self.station, key.nonce, self.snonce);
        self.candidate = candidate;
        self.candidate_anonce = key.nonce;
        self.candidate_replay = key.replay;

        // Echo the proposal counter without advancing authenticated replay.
        const len = KeyFrame.write(into, .{
            .info = .{ .pairwise = true, .mic = true },
            .replay = key.replay,
            .nonce = self.snonce,
            .data = self.rsn,
        }) orelse return .refused;
        KeyFrame.sign(into[0..len], candidate.kck);
        self.response = .{ .kind = .m2, .replay = key.replay, .generation = self.pairwise_at };
        return .{ .reply = len };
    }

    fn third(self: *Handshake, frame: []const u8, key: KeyFrame, into: []u8) Outcome {
        self.seen_third = true;
        // An access point that did not hear the answer sends its message
        // again, with the counter it spent or with the next one. Either
        // way it is answered under the key already proved, and nothing is
        // installed a second time: reinstalling a key that is in use
        // restarts the numbering underneath it, which is exactly what an
        // attacker replaying this frame is fishing for.
        const repeat = if (self.ptk) |ptk| key.verify(frame, ptk.kck) else false;
        // Only two pairwise generations can be live. Do not retire the
        // previous one on the strength of another exchange alone.
        if (!repeat and self.done and self.confirmed != self.pairwise_at) return .ignored;
        if (key.replay < self.replay or (!repeat and key.replay == self.replay)) return .ignored;
        const ptk = if (repeat) self.ptk.? else self.candidate orelse return .ignored;
        if (!key.verify(frame, ptk.kck)) {
            // Signed, and not by anybody whose key this station holds.
            // Counted, because from here to a timeout nothing else says
            // that frames arrived at all.
            self.mic_failures +|= 1;
            return .ignored;
        }
        // The nonce this message names must be the one the exchange was
        // opened with: a signed third message belonging to some other
        // exchange is not an answer to this one.
        if (!std.crypto.timing_safe.eql(Nonce, key.nonce, if (repeat) self.proved_anonce else self.candidate_anonce)) return .ignored;
        if (!repeat and key.replay <= self.candidate_replay) return .ignored;
        if (!key.info.encrypted) return .refused;
        // The only cipher this station offers takes a sixteen-byte key.
        if (key.key_length != 16) return .refused;

        var plain: [KEY_DATA_MAX]u8 = undefined;
        const data = unwrap(ptk.kek, key.data, &plain) orelse return .refused;
        const gtk = gtkOf(data) orelse return .refused;
        var it = ieee80211.elements(data);
        var found_rsn = false;
        while (it.next()) |element| {
            if (element.id != .rsn) continue;
            if (found_rsn or self.ap_rsn.len == 0 or
                !std.mem.eql(u8, element.payload, self.ap_rsn.slice())) return .refused;
            found_rsn = true;
        }
        if (!found_rsn) return .refused;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        if (repeat) {
            if (self.last_group != null or key.rsc != self.third_rsc or
                !std.mem.eql(u8, &digest, &self.third_data)) return .ignored;
            self.replay = key.replay;
            return self.fourth(ptk, key, into);
        }
        if (self.ptk) |had| {
            if (std.crypto.timing_safe.eql([16]u8, had.tk, ptk.tk)) return .ignored;
        }
        if (self.was) |had| {
            if (std.crypto.timing_safe.eql([16]u8, had.bytes, ptk.tk)) return .ignored;
        }

        // Proved: the frame that checked out under the candidate is what
        // makes it the key.
        self.installs += 1;
        self.was = if (self.ptk) |had| .{ .bytes = had.tk, .generation = self.pairwise_at } else null;
        self.pairwise_at = self.installs;
        self.ptk = ptk;
        self.proved_anonce = key.nonce;
        self.third_data = digest;
        self.third_rsc = key.rsc;
        self.last_group = null;
        self.candidate = null;
        self.putGroup(gtk.index, gtk.key, key.rsc);
        self.replay = key.replay;
        self.done = true;
        self.spent = true;
        return self.fourth(ptk, key, into);
    }

    /// The last frame of the exchange: signed, secure, carrying nothing.
    fn fourth(self: *Handshake, ptk: Ptk, key: KeyFrame, into: []u8) Outcome {
        const len = KeyFrame.write(into, .{
            .info = .{ .pairwise = true, .mic = true, .secure = true },
            .replay = key.replay,
        }) orelse return .refused;
        KeyFrame.sign(into[0..len], ptk.kck);
        self.response = .{ .kind = .m4, .replay = key.replay, .generation = self.pairwise_at };
        return .{ .reply = len };
    }

    /// The group key handshake, after the exchange: the access point sends
    /// its next group key under the pairwise one, and is answered so that it
    /// knows the key was taken. The key goes in under its own index, next
    /// to the one still in use.
    fn renewal(self: *Handshake, frame: []const u8, key: KeyFrame, into: []u8) Outcome {
        if (!self.done) return .ignored;
        if (!key.info.mic or !key.info.secure or !key.info.encrypted or key.info.install or
            key.key_length != 16) return .ignored;
        const ptk = self.ptk.?;
        if (!key.verify(frame, ptk.kck)) {
            // The room's key, signed by somebody who does not hold it.
            self.mic_failures +|= 1;
            return .ignored;
        }

        // One the access point is sending again because it did not hear
        // the answer is answered again, and nothing is installed twice.
        if (key.replay < self.replay) return .ignored;

        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(frame[0..key.len], &digest, .{});
        if (key.replay == self.replay) {
            const last = self.last_group orelse return .ignored;
            if (!std.mem.eql(u8, &last, &digest)) return .ignored;
            return self.took(ptk, key, into);
        }

        var plain: [KEY_DATA_MAX]u8 = undefined;
        const data = unwrap(ptk.kek, key.data, &plain) orelse return .refused;
        const gtk = gtkOf(data) orelse return .refused;
        self.putGroup(gtk.index, gtk.key, key.rsc);
        self.replay = key.replay;
        self.last_group = digest;
        return self.took(ptk, key, into);
    }

    /// Put a group key in under its index.
    ///
    /// A key is named by the installation it is, and a receiver that sees
    /// a new name starts its count again from where the sender says it
    /// has got to. So the same bytes handed over a second time must keep
    /// the name they had: an access point renewing a key to the value it
    /// already held is not starting again, and taking it as a fresh key
    /// would wind the count back to where frames already delivered are,
    /// and let every one of them be delivered again.
    fn putGroup(self: *Handshake, index: u2, bytes: [16]u8, from: Ccmp.Pn) void {
        for (self.group) |slot| {
            if (slot) |had| {
                if (std.crypto.timing_safe.eql([16]u8, had.bytes, bytes)) {
                    var same = had;
                    same.from = @max(had.from, from);
                    for (&self.group) |*alias| {
                        if (alias.*) |key| {
                            if (key.generation == had.generation) alias.* = same;
                        }
                    }
                    self.group[index] = same;
                    return;
                }
            }
        }
        self.installs += 1;
        self.group[index] = .{ .bytes = bytes, .generation = self.installs, .from = from };
    }

    /// The answer to an RSN group key: signed, secure, with no key data.
    fn took(self: *Handshake, ptk: Ptk, key: KeyFrame, into: []u8) Outcome {
        const len = KeyFrame.write(into, .{
            .info = .{ .mic = true, .secure = true },
            .replay = key.replay,
        }) orelse return .refused;
        KeyFrame.sign(into[0..len], ptk.kck);
        self.response = .{ .kind = .group2, .replay = key.replay, .generation = self.pairwise_at };
        return .{ .reply = len };
    }
};

/// The nonce for the exchange numbered `count`, from the seed the caller
/// drew.
///
/// A nonce is spent when an exchange finishes with it. One reused across
/// exchanges lets an access point's earlier first message be replayed into
/// the same candidate key, and answered with the same bytes on the air.
/// Derived rather than drawn, because a value cannot ask for randomness
/// and stay one; the chain is a keyed hash of the drawn seed, so each link
/// is as unguessable as the seed and none of them says what the seed was.
fn nonceAfter(seed: Nonce, count: u32) Nonce {
    var counted: [4]u8 = undefined;
    std.mem.writeInt(u32, &counted, count, .big);

    var out: Nonce = undefined;
    for (0..NONCE_LEN / 16) |half| {
        var h = HmacSha1.init(&seed);
        h.update("SNonce");
        h.update(&counted);
        h.update(&[_]u8{@intCast(half)});
        var whole: [HmacSha1.mac_length]u8 = undefined;
        h.final(&whole);
        @memcpy(out[half * 16 ..][0..16], whole[0..16]);
    }
    return out;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var out: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch unreachable;
    return out;
}

test "the master key from a passphrase is the standard's own" {
    // The two vectors the standard gives, in its annex on the derivation.
    try testing.expectEqualSlices(u8, &hex("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e"), &derive("password", "IEEE"));
    try testing.expectEqualSlices(u8, &hex("0dc0d6eb90555ed6419756b9a15ec3e3209b63df707dd508d14581f8982721af"), &derive("ThisIsAPassword", "ThisIsASSID"));

    // A configured secret resolves the same way, whichever spelling it
    // took: the words are derived, a key is itself, nothing is nothing.
    const name = wifi.Ssid.of("IEEE").?;
    const from_words = pmkOf(wifi.Psk.parse("password").?, name).?;
    try testing.expectEqualSlices(u8, &derive("password", "IEEE"), &from_words);
    const from_key = pmkOf(wifi.Psk.parse("f42c6fc52df0ebef9ebb4b90b38a5f902e83fe1b135a70e23aed762e9710a12e").?, name).?;
    try testing.expectEqualSlices(u8, &from_words, &from_key);
    try testing.expectEqual(@as(?Pmk, null), pmkOf(.none, name));
}

test "both sides reach one transient key whichever way round they are" {
    const pmk = derive("password", "IEEE");
    const aa = mac.Address{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
    const spa = mac.Address{ 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B };
    const anonce: Nonce = @splat(0x11);
    const snonce: Nonce = @splat(0x22);
    const ours = ptkOf(pmk, aa, spa, anonce, snonce);
    const theirs = ptkOf(pmk, spa, aa, snonce, anonce);
    try testing.expectEqualSlices(u8, &ours.kck, &theirs.kck);
    try testing.expectEqualSlices(u8, &ours.tk, &theirs.tk);
    // A different nonce is a different key.
    const other = ptkOf(pmk, aa, spa, anonce, @splat(0x23));
    try testing.expect(!std.mem.eql(u8, &ours.tk, &other.tk));
}

test "the key wrap is the one in the standard, both ways" {
    // RFC 3394, the first vector: a sixteen-byte key under a sixteen-byte one.
    const kek = hex("000102030405060708090A0B0C0D0E0F");
    const plain = hex("00112233445566778899AABBCCDDEEFF");
    var wrapped: [24]u8 = undefined;
    try testing.expectEqualSlices(u8, &hex("1FA68B0A8112B447AEF34BD8FB5A7B829D3E862371D2CFE5"), wrap(kek, &plain, &wrapped).?);
    var back: [16]u8 = undefined;
    try testing.expectEqualSlices(u8, &plain, unwrap(kek, &wrapped, &back).?);
    // Under the wrong key the check value does not come back.
    var wrong = kek;
    wrong[0] ^= 1;
    try testing.expectEqual(@as(?[]u8, null), unwrap(wrong, &wrapped, &back));
}

test "counter mode with the chained code matches its own standard" {
    // RFC 3610, packet vector one.
    const key = hex("C0C1C2C3C4C5C6C7C8C9CACBCCCDCECF");
    const nonce = hex("00000003020100A0A1A2A3A4A5");
    const aad = hex("0001020304050607");
    const plain = hex("08090A0B0C0D0E0F101112131415161718191A1B1C1D1E");
    var sealed: [plain.len + Ccm.MIC]u8 = undefined;
    try testing.expectEqual(@as(?usize, sealed.len), Ccm.seal(key, nonce, &aad, &plain, &sealed));
    try testing.expectEqualSlices(u8, &hex("588C979A61C663D2F066D0C2C0F989806D5F6B61DAC38417E8D12CFDF926E0"), &sealed);

    var opened: [plain.len]u8 = undefined;
    try testing.expectEqual(@as(?usize, plain.len), Ccm.open(key, nonce, &aad, &sealed, &opened));
    try testing.expectEqualSlices(u8, &plain, &opened);
    // One bit of ciphertext turned is a code that does not match, and
    // nothing of the plaintext given back.
    sealed[3] ^= 1;
    try testing.expectEqual(@as(?usize, null), Ccm.open(key, nonce, &aad, &sealed, &opened));
}

test "a data frame protected here is read back here, and by nobody else" {
    const tk = hex("c97c1f67ce371185514a8a19f2bdd52f");
    var head = ieee80211.Header{
        .control = ieee80211.FrameControl.data(.data),
        .addr1 = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .addr2 = .{ 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B },
        .addr3 = .{ 0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF },
        .sequence = .{ .sequence = 42 },
    };
    head.control.to_ds = true;
    const payload = "the quick brown fox";
    var frame: [128]u8 = undefined;
    const len = Ccmp.protect(tk, head, 0x0000_0000_0007, 0, payload, &frame).?;
    try testing.expectEqual(@as(usize, 24 + 8 + payload.len + 8), len);
    // The frame says it is protected, and the number is where a reader
    // looks for it.
    try testing.expect(ieee80211.Header.parse(frame[0..len]).?.control.protected);

    var plain: [64]u8 = undefined;
    const opened = Ccmp.unprotect(tk, frame[0..len], &plain).?;
    try testing.expectEqual(@as(usize, payload.len), opened.len);
    try testing.expectEqual(@as(Ccmp.Pn, 7), opened.pn);
    try testing.expectEqualStrings(payload, plain[0..opened.len]);

    // The header is bound: a frame readdressed after sealing is refused.
    frame[4] ^= 1;
    try testing.expectEqual(@as(?Ccmp.Opened, null), Ccmp.unprotect(tk, frame[0..len], &plain));
}

test "the handshake, with the test playing the access point" {
    const ssid = "home network";
    const pmk = derive("correct horse battery", ssid);
    const ap = mac.Address{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
    const station = mac.Address{ 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B };
    const anonce: Nonce = @splat(0xA1);
    const snonce: Nonce = @splat(0x5B);
    const rsn = [_]u8{ 0x30, 0x14 } ++ ieee80211.Rsn.psk_ccmp;

    var handshake = Handshake{ .pmk = pmk, .station = station, .ap = ap, .snonce = snonce, .seed = snonce, .rsn = &rsn, .ap_rsn = ieee80211.Rsn.Transcript.of(rsn[2..]).? };
    var frame: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    var reply: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;

    // Message one: the access point's nonce, unsigned.
    const one = KeyFrame.write(&frame, .{ .info = .{ .pairwise = true, .ack = true }, .key_length = 16, .replay = 1, .nonce = anonce }).?;
    const two = switch (handshake.answer(frame[0..one], &reply)) {
        .reply => |n| n,
        else => return error.TestUnexpectedResult,
    };
    // Message two carries the station's nonce and element, signed with
    // the key the access point derives the same way.
    const ptk = ptkOf(pmk, ap, station, anonce, snonce);
    const second = KeyFrame.parse(reply[0..two]).?;
    try testing.expectEqualSlices(u8, &snonce, &second.nonce);
    try testing.expectEqualSlices(u8, &rsn, second.data);
    try testing.expect(second.verify(reply[0..two], ptk.kck));
    try testing.expectEqual(@as(?Keys, null), handshake.keys());

    // Message three: the group key wrapped under the key-encryption key,
    // signed, and asking for the keys to be installed.
    const gtk = Gtk{ .index = 1, .key = hex("0f0e0d0c0b0a09080706050403020100") };
    var data: [64]u8 = @splat(0);
    var used: usize = 0;
    @memcpy(data[0..rsn.len], &rsn);
    used += rsn.len;
    used += writeGtk(data[used..], gtk).?;
    // Padded to the wrap's block, the way the standard pads key data.
    if (used % 8 != 0) {
        data[used] = 0xDD;
        used += 8 - used % 8;
    }
    var wrapped: [72]u8 = undefined;
    const sealed = wrap(ptk.kek, data[0..used], &wrapped).?;
    const three = KeyFrame.write(&frame, .{
        .info = .{ .pairwise = true, .ack = true, .mic = true, .install = true, .secure = true, .encrypted = true },
        .key_length = 16,
        .replay = 2,
        .nonce = anonce,
        .rsc = 9,
        .data = sealed,
    }).?;
    KeyFrame.sign(frame[0..three], ptk.kck);

    const four = switch (handshake.answer(frame[0..three], &reply)) {
        .reply => |n| n,
        else => return error.TestUnexpectedResult,
    };
    const fourth = KeyFrame.parse(reply[0..four]).?;
    try testing.expect(fourth.verify(reply[0..four], ptk.kck));
    try testing.expect(fourth.info.secure);
    try testing.expectEqual(@as(usize, 0), fourth.data.len);

    const keys = handshake.keys().?;
    try testing.expectEqualSlices(u8, &ptk.tk, &keys.pairwise.bytes);
    try testing.expectEqualSlices(u8, &gtk.key, &keys.groupKey(1).?.bytes);
    try testing.expectEqual(@as(?Key, null), keys.groupKey(2));
    // The group key arrives with the number the access point has reached
    // under it, so this station's count starts where that one left off.
    try testing.expectEqual(@as(Ccmp.Pn, 9), keys.groupKey(1).?.from);
    try testing.expectEqual(@as(Ccmp.Pn, 0), keys.pairwise.from);

    // The same message three again is answered again, because an access
    // point that did not hear the answer is waiting for one. What it is
    // not is a reason to derive or install anything a second time.
    const before = handshake.keys().?;
    try testing.expect(handshake.answer(frame[0..three], &reply) == .reply);
    const after = handshake.keys().?;
    try testing.expectEqualSlices(u8, &before.pairwise.bytes, &after.pairwise.bytes);
    try testing.expectEqual(before.pairwise.generation, after.pairwise.generation);
    try testing.expectEqualSlices(u8, &before.groupKey(1).?.bytes, &after.groupKey(1).?.bytes);
    try testing.expectEqual(before.groupKey(1).?.generation, after.groupKey(1).?.generation);
    // A message three signed with the wrong key says nothing: it is not
    // the access point's to say, and the keys stay.
    var forged = frame;
    forged[9 + 7] = 9;
    try testing.expectEqual(Handshake.Outcome.ignored, handshake.answer(forged[0..three], &reply));
    try testing.expect(handshake.keys() != null);
}

test "a signed frame that does not check out is counted, not merely ignored" {
    const cell = TestCell.home();
    // This station holds a different secret from the cell's, which is
    // what a mistyped passphrase is: it answers the first message under
    // the key it derives, and nothing the cell signs after that checks
    // out. From here to a timeout, these frames are the only evidence
    // that anything arrived at all.
    var mistyped = cell;
    mistyped.pmk = derive("not the password", "home network");
    var handshake = mistyped.handshake();
    var frame: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    var reply: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    const gtk = Gtk{ .index = 1, .key = hex("0f0e0d0c0b0a09080706050403020100") };

    try testing.expect(handshake.answer(frame[0..cell.messageOne(1, &frame)], &reply) == .reply);
    try testing.expectEqual(
        Handshake.Outcome.ignored,
        handshake.answer(frame[0..cell.messageThree(2, gtk, &frame)], &reply),
    );
    try testing.expectEqual(@as(u32, 1), handshake.mic_failures);
    try testing.expectEqual(@as(?Keys, null), handshake.keys());
    // The exchange was opened and no keys came of it, which is the shape
    // a wrong secret has on the air. The count is what separates it from
    // a cell that never answered at all.
    try testing.expect(handshake.begun());
}

/// Key data carrying `gtk` alone, wrapped under `kek` the way a key frame
/// carries it.
fn wrappedGtk(kek: [16]u8, gtk: Gtk, into: []u8) []const u8 {
    var data: [64]u8 = @splat(0);
    var used = writeGtk(&data, gtk).?;
    if (used % 8 != 0) {
        data[used] = 0xDD;
        used += 8 - used % 8;
    }
    return wrap(kek, data[0..used], into).?;
}

/// A cell the test plays: it opens the exchange with message one and
/// finishes it with message three, so a station arrives past its exchange.
const TestCell = struct {
    pmk: Pmk,
    ap: mac.Address = .{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
    station: mac.Address = .{ 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B },
    anonce: Nonce = @splat(0xA1),
    snonce: Nonce = @splat(0x5B),
    rsn: [2 + ieee80211.Rsn.psk_ccmp.len]u8 = [_]u8{ 0x30, 0x14 } ++ ieee80211.Rsn.psk_ccmp,

    /// Derived at run time: the derivation is deliberately slow, and far
    /// too slow for the compiler's comptime budget.
    fn home() TestCell {
        return .{ .pmk = derive("correct horse battery", "home network") };
    }

    fn ptk(self: TestCell) Ptk {
        return ptkOf(self.pmk, self.ap, self.station, self.anonce, self.snonce);
    }

    fn handshake(self: *const TestCell) Handshake {
        return .{ .pmk = self.pmk, .station = self.station, .ap = self.ap, .snonce = self.snonce, .seed = self.snonce, .rsn = &self.rsn, .ap_rsn = ieee80211.Rsn.Transcript.of(self.rsn[2..]).? };
    }

    fn messageOne(self: TestCell, replay: u64, into: []u8) usize {
        return KeyFrame.write(into, .{
            .info = .{ .pairwise = true, .ack = true },
            .key_length = 16,
            .replay = replay,
            .nonce = self.anonce,
        }).?;
    }

    fn messageThree(self: TestCell, replay: u64, gtk: Gtk, into: []u8) usize {
        var wrapped: [72]u8 = undefined;
        var data: [48]u8 = @splat(0);
        @memcpy(data[0..self.rsn.len], &self.rsn);
        const used = self.rsn.len + writeGtk(data[self.rsn.len..], gtk).?;
        data[used] = 0xDD;
        const sealed = wrap(self.ptk().kek, &data, &wrapped).?;
        const len = KeyFrame.write(into, .{
            .info = .{ .pairwise = true, .ack = true, .mic = true, .install = true, .secure = true, .encrypted = true },
            .key_length = 16,
            .replay = replay,
            .nonce = self.anonce,
            .data = sealed,
        }).?;
        KeyFrame.sign(into[0..len], self.ptk().kck);
        return len;
    }

    fn groupMessage(self: TestCell, replay: u64, gtk: Gtk, into: []u8) usize {
        var wrapped: [72]u8 = undefined;
        const sealed = wrappedGtk(self.ptk().kek, gtk, &wrapped);
        const len = KeyFrame.write(into, .{
            .info = .{ .ack = true, .mic = true, .secure = true, .encrypted = true },
            .key_length = 16,
            .replay = replay,
            .data = sealed,
        }).?;
        KeyFrame.sign(into[0..len], self.ptk().kck);
        return len;
    }
};

test "a first message anyone could have sent does not unseat the exchange" {
    const cell = TestCell.home();
    var handshake = cell.handshake();
    var frame: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    var reply: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    const gtk = Gtk{ .index = 1, .key = hex("0f0e0d0c0b0a09080706050403020100") };

    try testing.expect(handshake.answer(frame[0..cell.messageOne(1, &frame)], &reply) == .reply);
    try testing.expect(handshake.begun());
    // Somebody else's first message, with a nonce of their own: answered,
    // since nothing tells it apart, but the real third message will not
    // check out under the key it proposes.
    var other = cell;
    other.anonce = @splat(0xEE);
    try testing.expect(handshake.answer(frame[0..other.messageOne(5, &frame)], &reply) == .reply);
    try testing.expectEqual(Handshake.Outcome.ignored, handshake.answer(frame[0..cell.messageThree(2, gtk, &frame)], &reply));
    try testing.expectEqual(@as(?Keys, null), handshake.keys());

    // The access point, unanswered, opens the exchange again, and this
    // time it goes through.
    try testing.expect(handshake.answer(frame[0..cell.messageOne(6, &frame)], &reply) == .reply);
    try testing.expect(handshake.answer(frame[0..cell.messageThree(7, gtk, &frame)], &reply) == .reply);
    const keys = handshake.keys().?;
    try testing.expectEqualSlices(u8, &cell.ptk().tk, &keys.pairwise.bytes);
    try testing.expectEqualSlices(u8, &gtk.key, &keys.groupKey(1).?.bytes);
}

test "the group key is renewed after the exchange, and the one in use is kept" {
    const cell = TestCell.home();
    var handshake = cell.handshake();
    var frame: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    var reply: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    const first = Gtk{ .index = 1, .key = hex("0f0e0d0c0b0a09080706050403020100") };
    const next = Gtk{ .index = 2, .key = hex("00112233445566778899aabbccddeeff") };

    // Before the exchange is done a group message is nobody's to send.
    try testing.expectEqual(Handshake.Outcome.ignored, handshake.answer(frame[0..cell.groupMessage(1, next, &frame)], &reply));

    try testing.expect(handshake.answer(frame[0..cell.messageOne(1, &frame)], &reply) == .reply);
    try testing.expect(handshake.answer(frame[0..cell.messageThree(2, first, &frame)], &reply) == .reply);

    const len = switch (handshake.answer(frame[0..cell.groupMessage(3, next, &frame)], &reply)) {
        .reply => |n| n,
        else => return error.TestUnexpectedResult,
    };
    // Answered under the pairwise key. RSN reserves KeyInfo's index bits;
    // the GTK index belongs only in the authenticated KDE.
    const said = KeyFrame.parse(reply[0..len]).?;
    try testing.expect(said.verify(reply[0..len], cell.ptk().kck));
    try testing.expect(!said.info.pairwise and said.info.secure and said.info.mic);
    try testing.expectEqual(@as(u2, 0), said.info.key_index);

    const keys = handshake.keys().?;
    try testing.expectEqualSlices(u8, &first.key, &keys.groupKey(1).?.bytes);
    try testing.expectEqualSlices(u8, &next.key, &keys.groupKey(2).?.bytes);

    // The same renewal again is one the access point is sending because it
    // did not hear the answer: answered again, and installed no second
    // time, which the key's generation says.
    try testing.expect(handshake.answer(frame[0..cell.groupMessage(3, next, &frame)], &reply) == .reply);
    try testing.expectEqual(keys.groupKey(2).?.generation, handshake.keys().?.groupKey(2).?.generation);
    // One from before, or one signed by somebody else, is nothing.
    try testing.expectEqual(Handshake.Outcome.ignored, handshake.answer(frame[0..cell.groupMessage(2, next, &frame)], &reply));
    var other = cell;
    other.anonce = @splat(0xEE);
    try testing.expectEqual(Handshake.Outcome.ignored, handshake.answer(frame[0..other.groupMessage(4, next, &frame)], &reply));
}

test "an exchange that is erased leaves none of its keys behind" {
    const cell = TestCell.home();
    var handshake = cell.handshake();
    var frame: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    var reply: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    const gtk = Gtk{ .index = 1, .key = hex("0f0e0d0c0b0a09080706050403020100") };

    try testing.expect(handshake.answer(frame[0..cell.messageOne(1, &frame)], &reply) == .reply);
    try testing.expect(handshake.answer(frame[0..cell.messageThree(2, gtk, &frame)], &reply) == .reply);
    try testing.expect(handshake.keys() != null);
    try testing.expect(!std.mem.allEqual(u8, std.mem.asBytes(&handshake), 0));

    handshake.erase();

    // Nothing of the master key, the transient keys, the group keys or
    // the nonces survives: an exchange that has ended leaves a value
    // behind, and a value in a service's static state is not a frame
    // about to be reused.
    try testing.expectEqual(@as(?Keys, null), handshake.keys());
    try testing.expect(std.mem.allEqual(u8, std.mem.asBytes(&handshake), 0));
}

test "an unsigned first message cannot wind the counter back for a signed one" {
    const cell = TestCell.home();
    var handshake = cell.handshake();
    var frame: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    var reply: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    const first = Gtk{ .index = 1, .key = hex("0f0e0d0c0b0a09080706050403020100") };
    const next = Gtk{ .index = 2, .key = hex("00112233445566778899aabbccddeeff") };

    try testing.expect(handshake.answer(frame[0..cell.messageOne(10, &frame)], &reply) == .reply);
    try testing.expect(handshake.answer(frame[0..cell.messageThree(11, first, &frame)], &reply) == .reply);
    // A renewal the access point really sent, recorded off the air by
    // somebody listening.
    var recorded: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    const old = cell.groupMessage(12, next, &recorded);
    try testing.expect(handshake.answer(recorded[0..old], &reply) == .reply);
    try testing.expect(handshake.answer(frame[0..cell.groupMessage(13, first, &frame)], &reply) == .reply);
    const settled = handshake.keys().?;

    // Anyone can send a first message: it carries no proof of where it
    // came from. One naming a counter far below the exchange's must not
    // make the recorded renewal fresh again, which would put a key the
    // access point has finished with back into use.
    try testing.expectEqual(Handshake.Outcome.ignored, handshake.answer(frame[0..cell.messageOne(1, &frame)], &reply));
    try testing.expectEqual(Handshake.Outcome.ignored, handshake.answer(recorded[0..old], &reply));

    const after = handshake.keys().?;
    try testing.expectEqualSlices(u8, &settled.pairwise.bytes, &after.pairwise.bytes);
    try testing.expectEqualSlices(u8, &settled.groupKey(2).?.bytes, &after.groupKey(2).?.bytes);
    try testing.expectEqual(settled.groupKey(2).?.generation, after.groupKey(2).?.generation);
}

test "a nonce is spent by the exchange that used it, and not within one" {
    const cell = TestCell.home();
    var handshake = cell.handshake();
    var frame: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    var reply: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    const gtk = Gtk{ .index = 1, .key = hex("0f0e0d0c0b0a09080706050403020100") };

    // An access point that did not hear the second message sends its
    // first again, and expects the answer it was waiting for.
    const two = switch (handshake.answer(frame[0..cell.messageOne(1, &frame)], &reply)) {
        .reply => |n| n,
        else => return error.TestUnexpectedResult,
    };
    const offered = KeyFrame.parse(reply[0..two]).?.nonce;
    const again = switch (handshake.answer(frame[0..cell.messageOne(2, &frame)], &reply)) {
        .reply => |n| n,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqualSlices(u8, &offered, &KeyFrame.parse(reply[0..again]).?.nonce);

    // The exchange finishes, and the next one starts from a nonce of its
    // own: one used twice lets an access point's earlier first message be
    // replayed into the same key and answered with the same bytes.
    try testing.expect(handshake.answer(frame[0..cell.messageThree(3, gtk, &frame)], &reply) == .reply);
    const rekey = switch (handshake.answer(frame[0..cell.messageOne(4, &frame)], &reply)) {
        .reply => |n| n,
        else => return error.TestUnexpectedResult,
    };
    const drawn = KeyFrame.parse(reply[0..rekey]).?.nonce;
    try testing.expect(!std.mem.eql(u8, &offered, &drawn));
}

test "a third message naming another exchange's nonce is not an answer to this one" {
    const cell = TestCell.home();
    var handshake = cell.handshake();
    var frame: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    var reply: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    const gtk = Gtk{ .index = 1, .key = hex("0f0e0d0c0b0a09080706050403020100") };

    try testing.expect(handshake.answer(frame[0..cell.messageOne(1, &frame)], &reply) == .reply);
    // The same cell, opening a second exchange with a nonce of its own,
    // then finishing the first one. The key derived for the first is not
    // the key this message is signed under, and its nonce says so.
    var second = cell;
    second.anonce = @splat(0xEE);
    try testing.expectEqual(Handshake.Outcome.ignored, handshake.answer(frame[0..second.messageThree(2, gtk, &frame)], &reply));
    try testing.expectEqual(@as(?Keys, null), handshake.keys());
}

test "a frame numbered where one has already been is not delivered twice" {
    const tk = hex("000102030405060708090a0b0c0d0e0f");
    const keys = Keys{
        .pairwise = .{ .bytes = tk, .generation = 1 },
        .group = .{ null, .{ .bytes = hex("0f0e0d0c0b0a09080706050403020100"), .generation = 2, .from = 40 }, null, null },
    };
    const head = ieee80211.Header{
        .control = .{ .kind = .data, .from_ds = true },
        .addr1 = mac.Address{ 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B },
        .addr2 = mac.Address{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .addr3 = mac.Address{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
    };
    var frame: [128]u8 = undefined;
    var opened: [128]u8 = undefined;
    var numbering = Numbering{};

    const at_five = Ccmp.protect(tk, head, 5, 0, "hello there", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..at_five], &opened) != null);
    // The same frame again, byte for byte, is the same frame.
    try testing.expectEqual(@as(?[]const u8, null), numbering.open(keys, frame[0..at_five], &opened));
    // And one numbered below it is older still.
    const at_four = Ccmp.protect(tk, head, 4, 0, "hello there", &frame).?;
    try testing.expectEqual(@as(?[]const u8, null), numbering.open(keys, frame[0..at_four], &opened));
    // Onward from there is new.
    const at_six = Ccmp.protect(tk, head, 6, 0, "hello there", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..at_six], &opened) != null);

    // Nothing is protected by an unprotected frame, whatever it carries.
    var plain: [128]u8 = @splat(0);
    const bare = head.write(&plain).?;
    try testing.expectEqual(@as(?[]const u8, null), numbering.open(keys, plain[0 .. bare + 16], &opened));

    // The room's key counts on its own, and from where the access point
    // said it had got to: everything at or below that is already in the
    // air and not for this station to take again.
    var to_room = head;
    to_room.addr1 = mac.broadcast;
    const group = keys.group[1].?.bytes;
    const stale = Ccmp.protect(group, to_room, 30, 1, "everybody", &frame).?;
    try testing.expectEqual(@as(?[]const u8, null), numbering.open(keys, frame[0..stale], &opened));
    const fresh = Ccmp.protect(group, to_room, 41, 1, "everybody", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..fresh], &opened) != null);
    // A key put in under the same index is a fresh start.
    var renewed = keys;
    renewed.group[1] = .{ .bytes = group, .generation = 3, .from = 0 };
    try testing.expect(numbering.open(renewed, frame[0..stale], &opened) != null);
}

test "a key frame is signed over what it said it was, not over what carried it" {
    const cell = TestCell.home();
    var handshake = cell.handshake();
    var frame: [KeyFrame.HEAD + KEY_DATA_MAX + 8]u8 = @splat(0);
    var reply: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;

    // A link that pads its frames to a length of its own leaves bytes
    // past the key frame's own end. They are not part of it.
    const len = cell.messageOne(1, &frame);
    try testing.expect(handshake.answer(frame[0 .. len + 6], &reply) == .reply);

    const gtk = Gtk{ .index = 1, .key = hex("0f0e0d0c0b0a09080706050403020100") };
    const three = cell.messageThree(2, gtk, &frame);
    @memset(frame[three..][0..6], 0xAA);
    try testing.expect(handshake.answer(frame[0 .. three + 6], &reply) == .reply);
    try testing.expect(handshake.keys() != null);
}

test "the same group key handed over again is the same key, not a fresh count" {
    const cell = TestCell.home();
    var handshake = cell.handshake();
    var frame: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    var reply: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    const gtk = Gtk{ .index = 1, .key = hex("0f0e0d0c0b0a09080706050403020100") };

    try testing.expect(handshake.answer(frame[0..cell.messageOne(1, &frame)], &reply) == .reply);
    try testing.expect(handshake.answer(frame[0..cell.messageThree(2, gtk, &frame)], &reply) == .reply);
    const installed = handshake.keys().?.groupKey(1).?;

    // An access point renewing the key to the value it already held. Its
    // message is authentic and its counter is fresh, so it is answered;
    // what it must not do is name a new key, because a receiver told the
    // key is new starts counting again from what the message says, which
    // is behind every frame already delivered under it.
    try testing.expect(handshake.answer(frame[0..cell.groupMessage(3, gtk, &frame)], &reply) == .reply);
    const after = handshake.keys().?.groupKey(1).?;
    try testing.expectEqual(installed.generation, after.generation);
    try testing.expectEqualSlices(u8, &installed.bytes, &after.bytes);

    // A different key under the same index is a different key.
    const next = Gtk{ .index = 1, .key = hex("00112233445566778899aabbccddeeff") };
    try testing.expect(handshake.answer(frame[0..cell.groupMessage(4, next, &frame)], &reply) == .reply);
    try testing.expect(handshake.keys().?.groupKey(1).?.generation != installed.generation);
}

test "the key a rekey replaces is read until the new one is heard" {
    const first = hex("000102030405060708090a0b0c0d0e0f");
    const second = hex("0f0e0d0c0b0a09080706050403020100");
    const keys = Keys{
        .pairwise = .{ .bytes = second, .generation = 3 },
        .previous = .{ .bytes = first, .generation = 1 },
    };
    const head = ieee80211.Header{
        .control = .{ .kind = .data, .from_ds = true },
        .addr1 = mac.Address{ 0x06, 0x07, 0x08, 0x09, 0x0A, 0x0B },
        .addr2 = mac.Address{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
        .addr3 = mac.Address{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 },
    };
    var frame: [128]u8 = undefined;
    var opened: [128]u8 = undefined;
    var numbering = Numbering{};

    // The exchange that proves a new key finishes on a frame this station
    // sends, and the access point installs its own side only when that
    // frame arrives. Until then it is still speaking under the old key,
    // its own last message among them.
    const old_at_five = Ccmp.protect(first, head, 5, 0, "still the old key", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..old_at_five], &opened) != null);
    // And the old key is numbered on its own: a frame it has already
    // delivered is not delivered twice.
    try testing.expectEqual(@as(?[]const u8, null), numbering.open(keys, frame[0..old_at_five], &opened));

    // The moment one arrives under the new key, the old one is finished
    // with for good.
    const new_at_one = Ccmp.protect(second, head, 1, 0, "the new key", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..new_at_one], &opened) != null);
    const old_at_six = Ccmp.protect(first, head, 6, 0, "too late", &frame).?;
    try testing.expectEqual(@as(?[]const u8, null), numbering.open(keys, frame[0..old_at_six], &opened));
}

test "a key frame whose lengths run past sixteen bits is refused, not summed past them" {
    var frame: [KeyFrame.HEAD]u8 = @splat(0);
    frame[0] = 2;
    frame[1] = 3;
    frame[4] = 2;
    std.mem.writeInt(u16, frame[2..4], 0xFFFF, .big);
    try testing.expectEqual(@as(?KeyFrame, null), KeyFrame.parse(&frame));
    std.mem.writeInt(u16, frame[2..4], KeyFrame.HEAD - 4, .big);
    std.mem.writeInt(u16, frame[97..99], 0xFFFF, .big);
    try testing.expectEqual(@as(?KeyFrame, null), KeyFrame.parse(&frame));
    std.mem.writeInt(u16, frame[97..99], 0, .big);
    try testing.expect(KeyFrame.parse(&frame) != null);
}

test "old RX history survives rekey and GTK does not prove the pairwise generation" {
    const old = Key{ .bytes = @splat(1), .generation = 1 };
    const fresh = Key{ .bytes = @splat(2), .generation = 3 };
    const gtk = Key{ .bytes = @splat(3), .generation = 2 };
    var keys = Keys{ .pairwise = old, .group = .{ null, gtk, null, null } };
    var numbering = Numbering{};
    var frame: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var head = ieee80211.Header{ .control = .{ .kind = .data, .from_ds = true }, .addr1 = @splat(2), .addr2 = @splat(4) };
    var n = Ccmp.protect(old.bytes, head, 9, 0, "old", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..n], &out) != null);
    keys.previous = old;
    keys.pairwise = fresh;
    try testing.expect(numbering.open(keys, frame[0..n], &out) == null);
    n = Ccmp.protect(old.bytes, head, 10, 0, "old", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..n], &out) != null);
    head.addr1 = mac.broadcast;
    n = Ccmp.protect(gtk.bytes, head, 1, 1, "group", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..n], &out) != null);
    try testing.expect(numbering.current_heard != fresh.generation);
    head.addr1 = @splat(2);
    n = Ccmp.protect(old.bytes, head, 11, 0, "old", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..n], &out) != null);
    n = Ccmp.protect(fresh.bytes, head, 1, 0, "new", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..n], &out) != null);
    try testing.expectEqual(fresh.generation, numbering.current_heard);
    n = Ccmp.protect(old.bytes, head, 12, 0, "old", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..n], &out) == null);
}

test "TX numbering retains both generations across M4 retry and never wraps" {
    var numbering = TxNumbering{};
    const old = Key{ .bytes = @splat(1), .generation = 1 };
    const fresh = Key{ .bytes = @splat(2), .generation = 2 };
    try testing.expectEqual(@as(Ccmp.Pn, 1), numbering.next(old).?);
    try testing.expectEqual(@as(Ccmp.Pn, 2), numbering.next(old).?);
    try testing.expectEqual(@as(Ccmp.Pn, 1), numbering.next(fresh).?);
    try testing.expectEqual(@as(Ccmp.Pn, 3), numbering.next(old).?);
    try testing.expectEqual(@as(Ccmp.Pn, 2), numbering.next(fresh).?);
    numbering.previous.pn = std.math.maxInt(Ccmp.Pn);
    try testing.expect(numbering.next(old) == null);
}

test "GTK aliases cannot replay by changing the unauthenticated KeyID" {
    const cell = TestCell.home();
    var shake = cell.handshake();
    var frame: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    var gtk = Gtk{ .index = 1, .key = @splat(7) };
    _ = shake.answer(frame[0..cell.messageOne(1, &frame)], &out);
    _ = shake.answer(frame[0..cell.messageThree(2, gtk, &frame)], &out);
    var numbering = Numbering{};
    const head = ieee80211.Header{ .control = .{ .kind = .data, .from_ds = true }, .addr1 = mac.broadcast, .addr2 = cell.ap };
    var recorded: [128]u8 = undefined;
    const n = Ccmp.protect(gtk.key, head, 20, 1, "recorded", &recorded).?;
    try testing.expect(numbering.open(shake.keys().?, recorded[0..n], &out) != null);
    const generation = shake.keys().?.groupKey(1).?.generation;
    gtk.index = 2;
    _ = shake.answer(frame[0..cell.groupMessage(3, gtk, &frame)], &out);
    try testing.expectEqual(generation, shake.keys().?.groupKey(2).?.generation);
    recorded[ieee80211.Header.MIN + 3] = 0xA0;
    try testing.expect(numbering.open(shake.keys().?, recorded[0..n], &out) == null);
    // Replace the original index and receive on it before using the alias.
    const next = Gtk{ .index = 1, .key = @splat(8) };
    _ = shake.answer(frame[0..cell.groupMessage(4, next, &frame)], &out);
    const fresh = Ccmp.protect(next.key, head, 1, 1, "replacement", &frame).?;
    try testing.expect(numbering.open(shake.keys().?, frame[0..fresh], &out) != null);
    try testing.expect(numbering.open(shake.keys().?, recorded[0..n], &out) == null);
    const alias = Ccmp.protect(gtk.key, head, 21, 2, "fresh alias", &frame).?;
    try testing.expect(numbering.open(shake.keys().?, frame[0..alias], &out) != null);
}

test "M3 validates retained AP RSN on first install and retransmission" {
    const cell = TestCell.home();
    var shake = cell.handshake();
    var frame: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    const gtk = Gtk{ .index = 1, .key = @splat(7) };
    _ = shake.answer(frame[0..cell.messageOne(1, &frame)], &out);
    var changed = cell;
    changed.rsn[changed.rsn.len - 1] ^= 1;
    try testing.expectEqual(Handshake.Outcome.refused, shake.answer(frame[0..changed.messageThree(2, gtk, &frame)], &out));
    try testing.expect(shake.keys() == null);
    try testing.expect(shake.answer(frame[0..cell.messageThree(2, gtk, &frame)], &out) == .reply);
    const generation = shake.keys().?.pairwise.generation;
    try testing.expectEqual(Handshake.Outcome.refused, shake.answer(frame[0..changed.messageThree(3, gtk, &frame)], &out));
    try testing.expectEqual(generation, shake.keys().?.pairwise.generation);
    const n = cell.messageThree(3, gtk, &frame);
    frame[KeyFrame.At.nonce] ^= 1;
    KeyFrame.sign(frame[0..n], cell.ptk().kck);
    try testing.expectEqual(Handshake.Outcome.ignored, shake.answer(frame[0..n], &out));
    _ = cell.messageThree(3, gtk, &frame);
    frame[KeyFrame.At.key_length + 1] = 32;
    KeyFrame.sign(frame[0..n], cell.ptk().kck);
    try testing.expectEqual(Handshake.Outcome.refused, shake.answer(frame[0..n], &out));
}

test "GTK KDEs have exact lengths reserved bits and unique identity" {
    var data: [64]u8 = @splat(0);
    const n = writeGtk(&data, .{ .index = 1, .key = @splat(1) }).?;
    try testing.expect(gtkOf(data[0..n]) != null);
    data[1] += 1;
    try testing.expect(gtkOf(data[0 .. n + 1]) == null);
    data[1] -= 1;
    data[7] = 1;
    try testing.expect(gtkOf(data[0..n]) == null);
    data[7] = 0;
    data[6] |= 0x80;
    try testing.expect(gtkOf(data[0..n]) == null);
    data[6] &= 0x7F;
    @memcpy(data[n..][0..n], data[0..n]);
    try testing.expect(gtkOf(data[0 .. 2 * n]) == null);
    data[n] = 0xDD;
    data[n + 1] = 0;
    data[n + 2] = 1;
    try testing.expect(gtkOf(data[0 .. n + 3]) == null);
}

test "message types and equal-counter retransmits cannot be interchanged" {
    const cell = TestCell.home();
    const gtk = Gtk{ .index = 1, .key = @splat(7) };
    var shake = cell.handshake();
    var frame: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    const n = cell.messageOne(1, &frame);
    frame[KeyFrame.At.info] |= 0x04; // Error flag, not M1.
    try testing.expectEqual(Handshake.Outcome.ignored, shake.answer(frame[0..n], &out));
    try testing.expect(!shake.begun());
    _ = shake.answer(frame[0..cell.messageOne(1, &frame)], &out);
    _ = shake.answer(frame[0..cell.messageThree(2, gtk, &frame)], &out);
    try testing.expectEqual(Handshake.Outcome.ignored, shake.answer(frame[0..cell.groupMessage(2, gtk, &frame)], &out));
    _ = shake.answer(frame[0..cell.groupMessage(3, gtk, &frame)], &out);
    const other = Gtk{ .index = 2, .key = @splat(8) };
    try testing.expectEqual(Handshake.Outcome.ignored, shake.answer(frame[0..cell.groupMessage(3, other, &frame)], &out));
    try testing.expectEqual(Handshake.Outcome.ignored, shake.answer(frame[0..cell.messageThree(3, gtk, &frame)], &out));
}

test "initial GTK traffic cannot certify PTK and malformed CCMP cannot consume replay" {
    const keys = Keys{
        .pairwise = .{ .bytes = @splat(1), .generation = 1 },
        .group = .{ null, .{ .bytes = @splat(2), .generation = 2 }, null, null },
    };
    var numbering = Numbering{};
    var head = ieee80211.Header{ .control = .{ .kind = .data, .from_ds = true }, .addr1 = mac.broadcast };
    var frame: [128]u8 = undefined;
    var out: [128]u8 = undefined;
    var n = Ccmp.protect(keys.group[1].?.bytes, head, 1, 1, "group", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..n], &out) != null);
    try testing.expectEqual(@as(u32, 0), numbering.current_heard);
    head.addr1 = @splat(2);
    head.control.more_fragments = true;
    n = Ccmp.protect(keys.pairwise.bytes, head, 5, 0, "fragment", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..n], &out) == null);
    head.control.more_fragments = false;
    head.control.subtype = @intFromEnum(ieee80211.DataSubtype.qos_data);
    head.qos = .{ .amsdu = true };
    n = Ccmp.protect(keys.pairwise.bytes, head, 5, 0, "aggregate", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..n], &out) == null);
    head.qos.?.amsdu = false;
    n = Ccmp.protect(keys.pairwise.bytes, head, 5, 0, "valid", &frame).?;
    try testing.expect(numbering.open(keys, frame[0..n], &out) != null);
}

test "AP transcript may differ from the station offer and is independently owned" {
    var cell = TestCell.home();
    cell.rsn[cell.rsn.len - 2] = 0x80; // AP offers optional PMF, station does not.
    var shake = cell.handshake();
    const offered = [_]u8{ 0x30, 0x14 } ++ ieee80211.Rsn.psk_ccmp;
    shake.rsn = &offered;
    var frame: [512]u8 = undefined;
    var out: [512]u8 = undefined;
    const two = shake.answer(frame[0..cell.messageOne(1, &frame)], &out).reply;
    try testing.expectEqualSlices(u8, &offered, KeyFrame.parse(out[0..two]).?.data);
    try testing.expect(shake.answer(frame[0..cell.messageThree(2, .{ .index = 1, .key = @splat(7) }, &frame)], &out) == .reply);
}

test "idempotent GTK install can raise but never lower its replay floor" {
    const cell = TestCell.home();
    var shake = cell.handshake();
    shake.putGroup(1, @splat(7), 10);
    const generation = shake.group[1].?.generation;
    shake.putGroup(2, @splat(7), 20);
    shake.putGroup(1, @splat(7), 0);
    try testing.expectEqual(generation, shake.group[2].?.generation);
    try testing.expectEqual(@as(Ccmp.Pn, 20), shake.group[1].?.from);
    var seen = Numbering.Seen{ .generation = generation, .pn = 15 };
    try testing.expect(!seen.accept(shake.group[1].?, 19));
    try testing.expect(seen.accept(shake.group[2].?, 21));
}

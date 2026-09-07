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
        if (!head.control.protected) return null;
        if (frame.len < head.len + HEADER + MIC) return null;

        const cipher_head = frame[head.len..][0..HEADER];
        const key_byte: KeyByte = @bitCast(cipher_head[3]);
        if (!key_byte.extended_iv) return null;
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
    /// Which installation this is. A key put in under an index another
    /// key already had is a different key, and the numbering under it
    /// starts again; a receiver tells the two apart by this rather than
    /// by comparing bytes, since the same bytes handed over twice are
    /// still a fresh start.
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
    /// The room's, by the index the access point gives each. A renewal
    /// brings the next index while frames under the last are still in the
    /// air, so both are kept.
    group: [4]?Key = @splat(null),

    /// The group key a frame names, if the access point has given one
    /// under that index.
    pub fn groupKey(self: Keys, index: u2) ?Key {
        return self.group[index];
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
    group: [4]Seen = @splat(.{}),

    const Seen = struct {
        generation: u32 = 0,
        pn: Ccmp.Pn = 0,

        /// Whether this number is a new one under this key, remembering
        /// it when it is. A key installed since the last frame starts the
        /// count again, from wherever its sender had got to.
        fn accept(self: *Seen, key: Key, pn: Ccmp.Pn) bool {
            if (self.generation != key.generation) self.* = .{ .generation = key.generation, .pn = key.from };
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

        const named = Ccmp.keyIndexOf(frame) orelse return null;
        const group = mac.isGroup(head.addr1);
        // The pairwise key is always the first: a frame to this station
        // naming another index is not one it has a key for.
        const key = if (group) (keys.groupKey(named) orelse return null) else if (named == 0) keys.pairwise else return null;

        @memcpy(into[0..head.len], frame[0..head.len]);
        const got = Ccmp.unprotect(key.bytes, frame, into[head.len..]) orelse return null;

        const seen = if (group) &self.group[named] else &self.pairwise[classOf(head)];
        if (!seen.accept(key, got.pn)) return null;
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
    var it = ieee80211.elements(data);
    while (it.next()) |element| {
        if (element.id != .vendor or element.payload.len < 4 + 2 + 16) continue;
        if (!std.mem.eql(u8, element.payload[0..3], &KDE_OUI) or element.payload[3] != KDE_GTK) continue;
        const flags: GtkFlags = @bitCast(element.payload[4]);
        return .{ .index = flags.key_id, .key = element.payload[6..22].* };
    }
    return null;
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
    /// The pairwise key the exchange has proved: the one a signed frame
    /// from the access point checked out under.
    ptk: ?Ptk = null,
    /// The pairwise key the latest first message proposes, and the nonce
    /// that message carried. A first message is unsigned, so anyone can
    /// send one, and nothing is taken on its word: it becomes the key once
    /// a third message verifies under it and names the same nonce.
    candidate: ?Ptk = null,
    candidate_anonce: Nonce = @splat(0),
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
    /// Whether the nonce is spent. Renewed between exchanges, not within
    /// one: an access point that did not hear the second message sends
    /// its first again and expects the same answer.
    spent: bool = false,
    done: bool = false,

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
            .group = self.group,
        };
    }

    /// Whether the access point has opened the exchange. An exchange
    /// opened and never finished is what a wrong key looks like.
    pub fn begun(self: *const Handshake) bool {
        return self.candidate != null or self.ptk != null;
    }

    /// Answer a key frame from the access point.
    pub fn answer(self: *Handshake, frame: []const u8, into: []u8) Outcome {
        const key = KeyFrame.parse(frame) orelse return .ignored;
        if (!key.info.ack or key.info.version != 2) return .ignored;

        // The group key handshake stands apart from the pairwise one.
        // Message one: the access point's nonce, and nothing signed yet.
        // Message three: signed, with the keys to install inside it.
        if (!key.info.pairwise) return self.renewal(frame, key, into);
        if (!key.info.mic) return self.first(key, into);
        if (key.info.install) return self.third(frame, key, into);
        return .ignored;
    }

    fn first(self: *Handshake, key: KeyFrame, into: []u8) Outcome {
        if (self.spent) {
            self.installs += 1;
            self.snonce = nonceAfter(self.seed, self.installs);
            self.spent = false;
        }
        const candidate = ptkOf(self.pmk, self.ap, self.station, key.nonce, self.snonce);
        self.candidate = candidate;
        self.candidate_anonce = key.nonce;

        // The counter is echoed, not taken: this frame carries no proof of
        // where it came from, so nothing it says is remembered.
        const len = KeyFrame.write(into, .{
            .info = .{ .pairwise = true, .mic = true },
            .replay = key.replay,
            .nonce = self.snonce,
            .data = self.rsn,
        }) orelse return .refused;
        KeyFrame.sign(into[0..len], candidate.kck);
        return .{ .reply = len };
    }

    fn third(self: *Handshake, frame: []const u8, key: KeyFrame, into: []u8) Outcome {
        // An access point that did not hear the answer sends its message
        // again, with the counter it spent or with the next one. Either
        // way it is answered under the key already proved, and nothing is
        // installed a second time: reinstalling a key that is in use
        // restarts the numbering underneath it, which is exactly what an
        // attacker replaying this frame is fishing for.
        if (self.ptk) |ptk| {
            if (key.replay >= self.replay and key.verify(frame, ptk.kck)) {
                self.replay = key.replay;
                return fourth(ptk, key, into);
            }
        }
        if (key.replay <= self.replay) return .ignored;
        const ptk = self.candidate orelse return .ignored;
        if (!key.verify(frame, ptk.kck)) return .ignored;
        // The nonce this message names must be the one the exchange was
        // opened with: a signed third message belonging to some other
        // exchange is not an answer to this one.
        if (!std.crypto.timing_safe.eql(Nonce, key.nonce, self.candidate_anonce)) return .ignored;
        if (!key.info.encrypted) return .refused;
        // The only cipher this station offers takes a sixteen-byte key.
        if (key.key_length != 16) return .refused;

        var plain: [KEY_DATA_MAX]u8 = undefined;
        const data = unwrap(ptk.kek, key.data, &plain) orelse return .refused;
        const gtk = gtkOf(data) orelse return .refused;

        // Proved: the frame that checked out under the candidate is what
        // makes it the key.
        self.installs += 1;
        self.pairwise_at = self.installs;
        self.ptk = ptk;
        self.candidate = null;
        self.installs += 1;
        self.group[gtk.index] = .{ .bytes = gtk.key, .generation = self.installs, .from = key.rsc };
        self.replay = key.replay;
        self.done = true;
        self.spent = true;
        return fourth(ptk, key, into);
    }

    /// The last frame of the exchange: signed, secure, carrying nothing.
    fn fourth(ptk: Ptk, key: KeyFrame, into: []u8) Outcome {
        const len = KeyFrame.write(into, .{
            .info = .{ .pairwise = true, .mic = true, .secure = true },
            .replay = key.replay,
        }) orelse return .refused;
        KeyFrame.sign(into[0..len], ptk.kck);
        return .{ .reply = len };
    }

    /// The group key handshake, after the exchange: the access point sends
    /// its next group key under the pairwise one, and is answered so that it
    /// knows the key was taken. The key goes in under its own index, next
    /// to the one still in use.
    fn renewal(self: *Handshake, frame: []const u8, key: KeyFrame, into: []u8) Outcome {
        if (!self.done) return .ignored;
        if (!key.info.mic or !key.info.secure or !key.info.encrypted) return .ignored;
        const ptk = self.ptk.?;
        if (!key.verify(frame, ptk.kck)) return .ignored;

        // One the access point is sending again because it did not hear
        // the answer is answered again, and nothing is installed twice.
        if (key.replay == self.replay) return self.took(ptk, key, into);
        if (key.replay < self.replay) return .ignored;

        var plain: [KEY_DATA_MAX]u8 = undefined;
        const data = unwrap(ptk.kek, key.data, &plain) orelse return .refused;
        const gtk = gtkOf(data) orelse return .refused;
        self.installs += 1;
        self.group[gtk.index] = .{ .bytes = gtk.key, .generation = self.installs, .from = key.rsc };
        self.replay = key.replay;
        return self.took(ptk, key, into);
    }

    /// The answer to a group key: signed, secure, carrying nothing but the
    /// index of the key it is about.
    fn took(_: *Handshake, ptk: Ptk, key: KeyFrame, into: []u8) Outcome {
        const len = KeyFrame.write(into, .{
            .info = .{ .mic = true, .secure = true, .key_index = key.info.key_index },
            .replay = key.replay,
        }) orelse return .refused;
        KeyFrame.sign(into[0..len], ptk.kck);
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

    var handshake = Handshake{ .pmk = pmk, .station = station, .ap = ap, .snonce = snonce, .seed = snonce, .rsn = &rsn };
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
        return .{ .pmk = self.pmk, .station = self.station, .ap = self.ap, .snonce = self.snonce, .seed = self.snonce, .rsn = &self.rsn };
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
        const sealed = wrappedGtk(self.ptk().kek, gtk, &wrapped);
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
            .info = .{ .ack = true, .mic = true, .secure = true, .encrypted = true, .key_index = gtk.index },
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
    // Answered under the pairwise key, naming the index taken.
    const said = KeyFrame.parse(reply[0..len]).?;
    try testing.expect(said.verify(reply[0..len], cell.ptk().kck));
    try testing.expect(!said.info.pairwise and said.info.secure and said.info.mic);
    try testing.expectEqual(@as(u2, 2), said.info.key_index);

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
    try testing.expect(handshake.answer(frame[0..cell.messageOne(1, &frame)], &reply) == .reply);
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

test "a key frame whose lengths run past sixteen bits is refused, not summed past them" {
    var frame: [KeyFrame.HEAD]u8 = @splat(0);
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

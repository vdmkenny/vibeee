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
        // A QoS frame is bound as plain QoS data, whatever else its
        // subtype said.
        if (head.qos != null) control.subtype = @intFromEnum(ieee80211.DataSubtype.qos_data);

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
    mic: [16]u8,
    data: []const u8,

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
        // Lengths off the air, summed wider than they are: a length near
        // the top of sixteen bits must fail the check, not wrap past it.
        const body_len: usize = std.mem.readInt(u16, frame[At.body_length..][0..2], .big);
        if (body_len + At.descriptor > frame.len) return null;
        const data_len: usize = std.mem.readInt(u16, frame[At.data_length..][0..2], .big);
        if (HEAD + data_len > frame.len) return null;
        return .{
            .info = @bitCast(std.mem.readInt(u16, frame[At.info..][0..2], .big)),
            .key_length = std.mem.readInt(u16, frame[At.key_length..][0..2], .big),
            .replay = std.mem.readInt(u64, frame[At.replay..][0..8], .big),
            .nonce = frame[At.nonce..][0..NONCE_LEN].*,
            .mic = frame[At.mic..][0..16].*,
            .data = frame[At.data..][0..data_len],
        };
    }

    /// Write a key frame with a zero integrity code, which `sign` fills
    /// once the rest is in place. Returns the frame's length.
    pub fn write(into: []u8, info: KeyInfo, key_length: u16, replay: u64, nonce: Nonce, data: []const u8) ?usize {
        const len = HEAD + data.len;
        if (into.len < len or data.len > std.math.maxInt(u16)) return null;
        @memset(into[0..len], 0);
        into[At.version] = VERSION;
        into[At.packet_type] = KEY_PACKET;
        std.mem.writeInt(u16, into[At.body_length..][0..2], @intCast(len - At.descriptor), .big);
        into[At.descriptor] = RSN_DESCRIPTOR;
        std.mem.writeInt(u16, into[At.info..][0..2], @bitCast(info), .big);
        std.mem.writeInt(u16, into[At.key_length..][0..2], key_length, .big);
        std.mem.writeInt(u64, into[At.replay..][0..8], replay, .big);
        @memcpy(into[At.nonce..][0..NONCE_LEN], &nonce);
        std.mem.writeInt(u16, into[At.data_length..][0..2], @intCast(data.len), .big);
        @memcpy(into[At.data..][0..data.len], data);
        return len;
    }

    /// Put the integrity code into a written frame.
    pub fn sign(frame: []u8, kck: [16]u8) void {
        @memset(frame[MIC_AT..][0..16], 0);
        const code = micOf(kck, frame);
        @memcpy(frame[MIC_AT..][0..16], &code);
    }

    /// Whether a frame's integrity code is the one `kck` gives it.
    pub fn verify(frame: []const u8, kck: [16]u8) bool {
        if (frame.len < HEAD) return false;
        var copy: [HEAD + KEY_DATA_MAX]u8 = undefined;
        if (frame.len > copy.len) return false;
        @memcpy(copy[0..frame.len], frame);
        @memset(copy[MIC_AT..][0..16], 0);
        const code = micOf(kck, copy[0..frame.len]);
        return std.crypto.timing_safe.eql([16]u8, code, frame[MIC_AT..][0..16].*);
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
    /// This station's nonce, drawn fresh by whoever starts the handshake.
    snonce: Nonce,
    /// The RSN element this station offered when it associated, sent again
    /// in message two so the access point can see it was not changed.
    rsn: []const u8,

    /// The pairwise key the exchange has proved: the one a signed frame
    /// from the access point checked out under.
    ptk: ?Ptk = null,
    /// The pairwise key the latest first message proposes. A first message
    /// is unsigned, so anyone can send one, and nothing is taken on its
    /// word: it becomes the key once a third message verifies under it.
    candidate: ?Ptk = null,
    /// The group keys, by the index the access point gives each. A renewal
    /// brings the next index while frames under the last are still in the
    /// air, so both are kept.
    group: [4]?[16]u8 = @splat(null),
    replay: u64 = 0,
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
    pub const Keys = struct {
        tk: [16]u8,
        group: [4]?[16]u8,

        /// The group key a frame names, if the access point has given one
        /// under that index.
        pub fn groupKey(self: Keys, index: u2) ?[16]u8 {
            return self.group[index];
        }
    };

    pub fn keys(self: *const Handshake) ?Keys {
        if (!self.done) return null;
        return .{ .tk = self.ptk.?.tk, .group = self.group };
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
        const candidate = ptkOf(self.pmk, self.ap, self.station, key.nonce, self.snonce);
        self.candidate = candidate;
        self.replay = key.replay;

        const len = KeyFrame.write(into, .{ .pairwise = true, .mic = true }, 0, key.replay, self.snonce, self.rsn) orelse return .refused;
        KeyFrame.sign(into[0..len], candidate.kck);
        return .{ .reply = len };
    }

    fn third(self: *Handshake, frame: []const u8, key: KeyFrame, into: []u8) Outcome {
        // An access point that did not hear the answer sends its frame
        // again. Most carry a fresh counter for it; one that reuses the
        // counter it already spent is answered rather than ignored, since
        // ignoring it leaves the access point waiting for an answer.
        //
        // Answered, and no more than that: the keys are not derived again
        // and nothing is installed a second time. Reinstalling a key that
        // is already in use restarts the numbering underneath it, which is
        // exactly what an attacker replaying this frame is fishing for.
        if (self.done and key.replay == self.replay) {
            const ptk = self.ptk.?;
            if (!KeyFrame.verify(frame, ptk.kck)) return .ignored;
            return fourth(ptk, key, into);
        }
        if (key.replay <= self.replay) return .ignored;
        const ptk = self.candidate orelse return .ignored;
        if (!KeyFrame.verify(frame, ptk.kck)) return .ignored;
        if (!key.info.encrypted) return .refused;

        var plain: [KEY_DATA_MAX]u8 = undefined;
        const data = unwrap(ptk.kek, key.data, &plain) orelse return .refused;
        const gtk = gtkOf(data) orelse return .refused;

        // Proved: the frame that checked out under the candidate is what
        // makes it the key.
        self.ptk = ptk;
        self.candidate = null;
        self.group[gtk.index] = gtk.key;
        self.replay = key.replay;
        self.done = true;
        return fourth(ptk, key, into);
    }

    /// The last frame of the exchange: signed, secure, carrying nothing.
    fn fourth(ptk: Ptk, key: KeyFrame, into: []u8) Outcome {
        const len = KeyFrame.write(into, .{ .pairwise = true, .mic = true, .secure = true }, 0, key.replay, @splat(0), &.{}) orelse return .refused;
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
        if (key.replay <= self.replay) return .ignored;
        const ptk = self.ptk.?;
        if (!KeyFrame.verify(frame, ptk.kck)) return .ignored;

        var plain: [KEY_DATA_MAX]u8 = undefined;
        const data = unwrap(ptk.kek, key.data, &plain) orelse return .refused;
        const gtk = gtkOf(data) orelse return .refused;
        self.group[gtk.index] = gtk.key;
        self.replay = key.replay;

        const len = KeyFrame.write(into, .{ .mic = true, .secure = true, .key_index = key.info.key_index }, 0, key.replay, @splat(0), &.{}) orelse return .refused;
        KeyFrame.sign(into[0..len], ptk.kck);
        return .{ .reply = len };
    }
};

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

    var handshake = Handshake{ .pmk = pmk, .station = station, .ap = ap, .snonce = snonce, .rsn = &rsn };
    var frame: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;
    var reply: [KeyFrame.HEAD + KEY_DATA_MAX]u8 = undefined;

    // Message one: the access point's nonce, unsigned.
    const one = KeyFrame.write(&frame, .{ .pairwise = true, .ack = true }, 16, 1, anonce, &.{}).?;
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
    try testing.expect(KeyFrame.verify(reply[0..two], ptk.kck));
    try testing.expectEqual(@as(?Handshake.Keys, null), handshake.keys());

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
    const three = KeyFrame.write(&frame, .{ .pairwise = true, .ack = true, .mic = true, .install = true, .secure = true, .encrypted = true }, 16, 2, anonce, sealed).?;
    KeyFrame.sign(frame[0..three], ptk.kck);

    const four = switch (handshake.answer(frame[0..three], &reply)) {
        .reply => |n| n,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(KeyFrame.verify(reply[0..four], ptk.kck));
    const fourth = KeyFrame.parse(reply[0..four]).?;
    try testing.expect(fourth.info.secure);
    try testing.expectEqual(@as(usize, 0), fourth.data.len);

    const keys = handshake.keys().?;
    try testing.expectEqualSlices(u8, &ptk.tk, &keys.tk);
    try testing.expectEqualSlices(u8, &gtk.key, &keys.groupKey(1).?);
    try testing.expectEqual(@as(?[16]u8, null), keys.groupKey(2));

    // The same message three again is answered again, because an access
    // point that did not hear the answer is waiting for one. What it is
    // not is a reason to derive or install anything a second time.
    const before = handshake.keys().?;
    try testing.expect(handshake.answer(frame[0..three], &reply) == .reply);
    const after = handshake.keys().?;
    try testing.expectEqualSlices(u8, &before.tk, &after.tk);
    try testing.expectEqualSlices(u8, &before.groupKey(1).?, &after.groupKey(1).?);
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
        return .{ .pmk = self.pmk, .station = self.station, .ap = self.ap, .snonce = self.snonce, .rsn = &self.rsn };
    }

    fn messageOne(self: TestCell, replay: u64, into: []u8) usize {
        return KeyFrame.write(into, .{ .pairwise = true, .ack = true }, 16, replay, self.anonce, &.{}).?;
    }

    fn messageThree(self: TestCell, replay: u64, gtk: Gtk, into: []u8) usize {
        var wrapped: [72]u8 = undefined;
        const sealed = wrappedGtk(self.ptk().kek, gtk, &wrapped);
        const len = KeyFrame.write(into, .{ .pairwise = true, .ack = true, .mic = true, .install = true, .secure = true, .encrypted = true }, 16, replay, self.anonce, sealed).?;
        KeyFrame.sign(into[0..len], self.ptk().kck);
        return len;
    }

    fn groupMessage(self: TestCell, replay: u64, gtk: Gtk, into: []u8) usize {
        var wrapped: [72]u8 = undefined;
        const sealed = wrappedGtk(self.ptk().kek, gtk, &wrapped);
        const len = KeyFrame.write(into, .{ .ack = true, .mic = true, .secure = true, .encrypted = true, .key_index = gtk.index }, 16, replay, @splat(0), sealed).?;
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
    try testing.expectEqual(@as(?Handshake.Keys, null), handshake.keys());

    // The access point, unanswered, opens the exchange again, and this
    // time it goes through.
    try testing.expect(handshake.answer(frame[0..cell.messageOne(6, &frame)], &reply) == .reply);
    try testing.expect(handshake.answer(frame[0..cell.messageThree(7, gtk, &frame)], &reply) == .reply);
    const keys = handshake.keys().?;
    try testing.expectEqualSlices(u8, &cell.ptk().tk, &keys.tk);
    try testing.expectEqualSlices(u8, &gtk.key, &keys.groupKey(1).?);
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
    try testing.expect(KeyFrame.verify(reply[0..len], cell.ptk().kck));
    const said = KeyFrame.parse(reply[0..len]).?;
    try testing.expect(!said.info.pairwise and said.info.secure and said.info.mic);
    try testing.expectEqual(@as(u2, 2), said.info.key_index);

    const keys = handshake.keys().?;
    try testing.expectEqualSlices(u8, &first.key, &keys.groupKey(1).?);
    try testing.expectEqualSlices(u8, &next.key, &keys.groupKey(2).?);

    // A renewal replayed, or one signed by somebody else, changes nothing.
    try testing.expectEqual(Handshake.Outcome.ignored, handshake.answer(frame[0..cell.groupMessage(3, next, &frame)], &reply));
    var other = cell;
    other.anonce = @splat(0xEE);
    try testing.expectEqual(Handshake.Outcome.ignored, handshake.answer(frame[0..other.groupMessage(4, next, &frame)], &reply));
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

//! Lobby protocol v1 client (the cart side of `badge lobby`), generic over
//! a cart serial port (`lib/cart_serial.zig`: `Badge(.{})` on the badge,
//! `Virtual(.{})` in host tests). The protocol is the fork firmware's
//! (`/home/exedev/sycl-badge-fork` branch `feature/cart-serial` at 13ffec9,
//! `fork/CART_SERIAL.md` section "Lobby protocol v1"); this is our own
//! implementation of it for carts on the pinned SDK, which has no
//! `cart.lobby`. docs/LOCKSTEP_N.md.
//!
//! Framing: each frame is a body (`type: u8` + payload, at most 250 bytes)
//! COBS-encoded, then one 0x00. A receiver drops a frame that fails to
//! decode or is too long and carries on at the next 0x00; a sender writes a
//! lone 0x00 whenever it (re)connects; empty frames are ignored.
//!
//! The client: HELLO (game id, name, max players) when the port connects
//! and again whenever `connected()` goes false -> true; WELCOME gives this
//! badge its player id; ROSTER (after every join and leave) the room; SEND
//! / DATA carry the game's bytes (to one player, 0xFF everyone else, 0xFE
//! everyone including the sender); PING / PONG; LEAVE; ERROR. `poll`
//! returns one event at a time. A frame is written whole or not at all
//! (`send` returns false when the transmit ring lacks room: try again on
//! the next pump). No allocation, no clock.
const std = @import("std");

pub const version: u8 = 1;
/// The longest frame body (type + payload).
pub const max_body: usize = 250;
/// The longest SEND / DATA data.
pub const max_data: usize = 240;
/// Player ids are 0..max_players-1, at most 16.
pub const max_players: usize = 16;
pub const game_len = 8;
pub const name_len = 12;

/// SEND `to`: every other player in the room.
pub const to_others: u8 = 0xFF;
/// SEND `to`: every player including the sender (self-echo: the sender
/// gets DATA(from = itself) at its place in the room's order).
pub const to_all: u8 = 0xFE;

/// Message types.
pub const T = struct {
    // cart -> host
    pub const hello: u8 = 0x01;
    pub const send: u8 = 0x02;
    pub const ping: u8 = 0x03;
    pub const leave: u8 = 0x04;
    // host -> cart
    pub const welcome: u8 = 0x81;
    pub const roster: u8 = 0x82;
    pub const data: u8 = 0x83;
    pub const pong: u8 = 0x84;
    pub const err: u8 = 0x8F;
};

/// ERROR codes.
pub const Err = struct {
    pub const unsupported_version: u8 = 1;
    pub const no_room: u8 = 2;
    pub const not_joined: u8 = 3;
    pub const malformed: u8 = 4;
};

/// `s` zero-padded (or cut) to `n` bytes: game ids and names.
pub fn pad(comptime n: usize, s: []const u8) [n]u8 {
    var out: [n]u8 = @splat(0);
    const k = @min(n, s.len);
    @memcpy(out[0..k], s[0..k]);
    return out;
}

/// The text of a padded field (up to the first 0).
pub fn unpad(field: []const u8) []const u8 {
    return field[0 .. std.mem.indexOfScalar(u8, field, 0) orelse field.len];
}

// ---- COBS -------------------------------------------------------------------

/// The longest COBS encoding of `n` bytes (without the trailing 0).
pub fn cobs_max(n: usize) usize {
    return n + n / 254 + 1;
}

/// The longest wire frame: an encoded 250-byte body and its 0x00.
pub const max_frame: usize = cobs_max(max_body) + 1;

/// COBS-encode `src` into `dst` (at least `cobs_max(src.len)` long); the
/// encoded length. No trailing 0.
pub fn cobs_encode(src: []const u8, dst: []u8) usize {
    var code_at: usize = 0;
    var out: usize = 1;
    var code: u8 = 1;
    for (src, 0..) |b, i| {
        if (b == 0) {
            dst[code_at] = code;
            code_at = out;
            out += 1;
            code = 1;
            continue;
        }
        dst[out] = b;
        out += 1;
        code += 1;
        if (code == 0xFF) {
            dst[code_at] = code;
            // A full block at the very end needs no empty block after it.
            if (i + 1 == src.len) return out;
            code_at = out;
            out += 1;
            code = 1;
        }
    }
    dst[code_at] = code;
    return out;
}

/// Decode one COBS frame (without its trailing 0) into `dst`; the decoded
/// length, or null when it is malformed (a 0 inside, a block past the end)
/// or longer than `dst`.
pub fn cobs_decode(src: []const u8, dst: []u8) ?usize {
    var i: usize = 0;
    var out: usize = 0;
    while (i < src.len) {
        const code = src[i];
        if (code == 0) return null;
        i += 1;
        const n: usize = code - 1;
        if (i + n > src.len or out + n > dst.len) return null;
        for (src[i..][0..n]) |b| {
            if (b == 0) return null;
            dst[out] = b;
            out += 1;
        }
        i += n;
        if (code != 0xFF and i < src.len) {
            if (out >= dst.len) return null;
            dst[out] = 0;
            out += 1;
        }
    }
    return out;
}

/// Encode `body` as a wire frame (COBS + 0x00) into `dst`; the length.
pub fn encode_frame(body: []const u8, dst: []u8) usize {
    const n = cobs_encode(body, dst);
    dst[n] = 0;
    return n + 1;
}

/// The streaming frame receiver: bytes in, decoded bodies out.
pub const Decoder = struct {
    buf: [max_frame]u8 = undefined,
    len: u16 = 0,
    /// The frame in progress is too long: skip to the next 0x00.
    skipping: bool = false,
    /// Frames dropped (too long, malformed).
    dropped: u32 = 0,

    pub fn reset(d: *Decoder) void {
        d.len = 0;
        d.skipping = false;
    }

    /// One byte; at a frame's end the decoded body is written to `out`
    /// and its length returned (empty frames and bad ones return null).
    pub fn push(d: *Decoder, byte: u8, out: *[max_body]u8) ?usize {
        if (byte != 0) {
            if (d.skipping) return null;
            if (d.len == d.buf.len) {
                d.skipping = true;
                d.dropped +%= 1;
                return null;
            }
            d.buf[d.len] = byte;
            d.len += 1;
            return null;
        }
        const n = d.len;
        const skipped = d.skipping;
        d.reset();
        if (skipped or n == 0) return null;
        const m = cobs_decode(d.buf[0..n], out) orelse {
            d.dropped +%= 1;
            return null;
        };
        if (m == 0) return null;
        return m;
    }
};

// ---- the client ---------------------------------------------------------------

pub const Options = struct {
    /// The game id: rooms with different ids never mix. Bump its last
    /// character when the game's wire changes (SNOUTDM1 -> SNOUTDM2).
    game: [game_len]u8,
    /// The player's name, shown in every roster.
    name: [name_len]u8 = pad(name_len, "SNOUTY"),
    /// 2-16 (0 = the host's default): the room size, if this badge opens it.
    max_players: u8 = 16,
};

pub const State = enum(u8) {
    /// Stock firmware (`os_flags` bit 1 clear): hide multiplayer.
    unsupported,
    /// No host program has the port open: "START BADGE LOBBY ON THE LAPTOP".
    disconnected,
    /// Connected, not in a room (after `leave`).
    idle,
    /// HELLO sent, no WELCOME yet.
    joining,
    /// In a room.
    joined,
};

pub const Welcome = struct { you: u8, room: u8, max_players: u8 };
pub const Data = struct { from: u8, bytes: []const u8 };
pub const Error = struct { code: u8, message: []const u8 };

/// What `poll` reports. Slices point into the client and stay valid until
/// the next `poll`.
pub const Event = union(enum) {
    /// WELCOME: this badge is player `you`.
    joined: Welcome,
    /// ROSTER: `present` / `name` changed.
    roster,
    data: Data,
    pong: u32,
    err: Error,
    /// The host program went away (`connected()` went false).
    lost,
};

pub const Stats = struct {
    frames_in: u32 = 0,
    frames_out: u32 = 0,
    bytes_in: u32 = 0,
    bytes_out: u32 = 0,
    /// Writes refused because the transmit ring lacked room.
    tx_full: u32 = 0,
    /// Frames that decoded but made no sense (short, unknown version).
    bad: u32 = 0,
    hellos: u32 = 0,
};

pub fn Client(comptime P: type) type {
    return struct {
        const Self = @This();

        port: P,
        opts: Options,
        opened: bool = false,
        unsupported: bool = false,
        was_connected: bool = false,
        /// Join a room whenever connected (cleared by `leave`).
        want_join: bool = true,
        in_room: bool = false,
        welcomed: bool = false,
        flush_due: bool = false,
        hello_due: bool = false,
        leave_due: bool = false,

        you: u8 = 0,
        room: u8 = 0,
        room_size: u8 = 0,
        /// Player ids in the room (bit per id), this badge included.
        present: u16 = 0,
        names: [max_players][name_len]u8 = @splat(@splat(0)),

        dec: Decoder = .{},
        body: [max_body]u8 = undefined,
        chunk: [64]u8 = undefined,
        chunk_pos: u8 = 0,
        chunk_len: u8 = 0,
        stats: Stats = .{},

        pub fn init(port: P, opts: Options) Self {
            return .{ .port = port, .opts = opts };
        }

        pub fn state(self: *const Self) State {
            if (self.unsupported) return .unsupported;
            if (!self.was_connected) return .disconnected;
            if (self.welcomed) return .joined;
            return if (self.want_join) .joining else .idle;
        }

        /// This badge's player id once joined.
        pub fn me(self: *const Self) ?u8 {
            return if (self.welcomed) self.you else null;
        }

        /// A player's name ("" when absent).
        pub fn name(self: *const Self, id: u8) []const u8 {
            if (id >= max_players or self.present & (@as(u16, 1) << @intCast(id)) == 0) return "";
            return unpad(&self.names[id]);
        }

        /// Leave the room (LEAVE); `join` enters again.
        pub fn leave(self: *Self) void {
            self.want_join = false;
            self.hello_due = false;
            if (self.in_room) self.leave_due = true;
            self.in_room = false;
            self.welcomed = false;
            self.present = 0;
            _ = self.flush_control();
        }

        pub fn join(self: *Self) void {
            if (self.want_join) return;
            self.want_join = true;
            self.leave_due = false;
            if (self.was_connected) self.hello_due = true;
            _ = self.flush_control();
        }

        /// Run the port: follow the connection, send what is due (the
        /// flush byte, HELLO, LEAVE), then return the next event from the
        /// receive ring (null: nothing waiting). Call until null.
        pub fn poll(self: *Self) ?Event {
            if (self.unsupported) return null;
            if (!self.opened) {
                if (!self.port.open()) {
                    self.unsupported = true;
                    return null;
                }
                self.opened = true;
            }
            const up = self.port.connected();
            if (!up) {
                if (self.was_connected) {
                    self.was_connected = false;
                    self.lose_room();
                    return .lost;
                }
                return null;
            }
            if (!self.was_connected) {
                // (Re)connected: the other end may hold a partial frame of
                // ours and we one of theirs.
                self.was_connected = true;
                self.dec.reset();
                self.chunk_pos = 0;
                self.chunk_len = 0;
                self.flush_due = true;
                self.leave_due = false;
                self.hello_due = self.want_join;
            }
            if (!self.flush_control()) return null;
            while (true) {
                if (self.chunk_pos == self.chunk_len) {
                    const n = self.port.read(&self.chunk);
                    if (n == 0) return null;
                    self.stats.bytes_in +%= @intCast(n);
                    self.chunk_pos = 0;
                    self.chunk_len = @intCast(n);
                }
                while (self.chunk_pos < self.chunk_len) {
                    const b = self.chunk[self.chunk_pos];
                    self.chunk_pos += 1;
                    if (self.dec.push(b, &self.body)) |n| {
                        self.stats.frames_in +%= 1;
                        if (self.handle(self.body[0..n])) |ev| return ev;
                    }
                }
            }
        }

        fn lose_room(self: *Self) void {
            self.in_room = false;
            self.welcomed = false;
            self.present = 0;
            self.hello_due = false;
            self.flush_due = false;
            self.leave_due = false;
        }

        /// Send the flush byte, LEAVE and HELLO in that order; false while
        /// one of them still waits for room.
        fn flush_control(self: *Self) bool {
            if (!self.was_connected) return true;
            if (self.flush_due) {
                if (self.port.space() < 1) return self.full();
                _ = self.port.write(&.{0});
                self.stats.bytes_out +%= 1;
                self.flush_due = false;
            }
            if (self.leave_due) {
                if (!self.write_body(&.{T.leave})) return false;
                self.leave_due = false;
            }
            if (self.hello_due) {
                if (!self.write_body(&self.hello_body())) return false;
                self.hello_due = false;
                self.in_room = true;
                self.welcomed = false;
                self.stats.hellos +%= 1;
            }
            return true;
        }

        fn full(self: *Self) bool {
            self.stats.tx_full +%= 1;
            return false;
        }

        /// The HELLO body: type, version, game, name, max players (23 bytes).
        pub fn hello_body(self: *const Self) [23]u8 {
            var b: [23]u8 = undefined;
            b[0] = T.hello;
            b[1] = version;
            @memcpy(b[2..10], &self.opts.game);
            @memcpy(b[10..22], &self.opts.name);
            b[22] = self.opts.max_players;
            return b;
        }

        /// Write one frame whole, or nothing (false: no room now).
        pub fn write_body(self: *Self, body: []const u8) bool {
            std.debug.assert(body.len >= 1 and body.len <= max_body);
            var f: [max_frame]u8 = undefined;
            const n = encode_frame(body, &f);
            if (self.port.space() < n) return self.full();
            const w = self.port.write(f[0..n]);
            std.debug.assert(w == n);
            self.stats.frames_out +%= 1;
            self.stats.bytes_out +%= @intCast(n);
            return true;
        }

        /// SEND `data` (at most 240 bytes) to player `to`, `to_others` or
        /// `to_all`. False when not joined or the ring lacks room (nothing
        /// was written; try again).
        pub fn send(self: *Self, to: u8, data: []const u8) bool {
            if (!self.welcomed or !self.flush_control()) return false;
            std.debug.assert(data.len <= max_data);
            var b: [2 + max_data]u8 = undefined;
            b[0] = T.send;
            b[1] = to;
            @memcpy(b[2..][0..data.len], data);
            return self.write_body(b[0 .. 2 + data.len]);
        }

        /// To every other player in the room.
        pub fn broadcast(self: *Self, data: []const u8) bool {
            return self.send(to_others, data);
        }

        /// To every player including this one (self-echo).
        pub fn broadcast_echo(self: *Self, data: []const u8) bool {
            return self.send(to_all, data);
        }

        /// PING the host program (PONG echoes `token`). Works joined or not.
        pub fn ping(self: *Self, token: u32) bool {
            if (!self.was_connected or !self.flush_control()) return false;
            var b: [5]u8 = undefined;
            b[0] = T.ping;
            std.mem.writeInt(u32, b[1..5], token, .little);
            return self.write_body(&b);
        }

        fn bad(self: *Self) ?Event {
            self.stats.bad +%= 1;
            return null;
        }

        fn handle(self: *Self, b: []const u8) ?Event {
            switch (b[0]) {
                T.welcome => {
                    if (b.len < 5) return self.bad();
                    if (b[1] != version or !self.in_room or b[2] >= max_players) return self.bad();
                    self.you = b[2];
                    self.room = b[3];
                    self.room_size = b[4];
                    self.welcomed = true;
                    self.present = @as(u16, 1) << @intCast(b[2]);
                    return .{ .joined = .{ .you = b[2], .room = b[3], .max_players = b[4] } };
                },
                T.roster => {
                    if (b.len < 2 or !self.welcomed) return self.bad();
                    const count: usize = b[1];
                    if (count > max_players or b.len < 2 + count * (1 + name_len)) return self.bad();
                    var mask: u16 = 0;
                    for (0..count) |i| {
                        const e = b[2 + i * (1 + name_len) ..][0 .. 1 + name_len];
                        if (e[0] >= max_players) continue;
                        mask |= @as(u16, 1) << @intCast(e[0]);
                        @memcpy(&self.names[e[0]], e[1..]);
                    }
                    self.present = mask;
                    return .roster;
                },
                T.data => {
                    if (b.len < 2) return self.bad();
                    if (!self.welcomed) return null;
                    return .{ .data = .{ .from = b[1], .bytes = b[2..] } };
                },
                T.pong => {
                    if (b.len < 5) return self.bad();
                    return .{ .pong = std.mem.readInt(u32, b[1..5], .little) };
                },
                T.err => {
                    if (b.len < 2) return self.bad();
                    // SEND or LEAVE before WELCOME: the host lost us (it
                    // restarted between our HELLO and now); join again.
                    if (b[1] == Err.not_joined and self.want_join and !self.hello_due) {
                        self.hello_due = true;
                        self.welcomed = false;
                        self.present = 0;
                    }
                    return .{ .err = .{ .code = b[1], .message = b[2..] } };
                },
                else => return null, // unknown types are ignored (v1 rule)
            }
        }
    };
}

test "cobs round trip, every length to 300 with zeros sprinkled" {
    var src: [300]u8 = undefined;
    var enc: [cobs_max(300)]u8 = undefined;
    var dec: [300]u8 = undefined;
    for (0..301) |n| {
        for (src[0..n], 0..) |*b, i| b.* = if (i % 37 == 5) 0 else @truncate(i *% 7 +% 1);
        const e = cobs_encode(src[0..n], &enc);
        try std.testing.expect(e <= cobs_max(n));
        try std.testing.expect(std.mem.indexOfScalar(u8, enc[0..e], 0) == null);
        const d = cobs_decode(enc[0..e], &dec).?;
        try std.testing.expectEqualSlices(u8, src[0..n], dec[0..d]);
    }
}

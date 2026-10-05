//! Badge-to-badge link over the UART header (docs/LINK.md).
//!
//! The SYCL Badge V2's "UART" header (J4, JST-SH 1.0 mm, 3 pins) carries
//! pin 1 = GPIO28, pin 2 = GND, pin 3 = GPIO29, each signal through 100 R.
//! A 3-pin cable joins two badges either crossed (pin 1 to pin 3) or
//! straight (pin 1 to pin 1). The link works with both: while searching,
//! each badge drives one of its two pins high (an idle UART line) and
//! listens on the other, flipping which at random until it hears the
//! partner's idle line. Then it runs a 1 Mbaud 8N1 UART on those pins
//! (PIO2 on the badge, lib/link_rp2350.zig), says HELLO, and is connected.
//! Outputs only ever drive high while searching, and a badge only sends
//! while its receive line is high (the partner drives it, so the partner is
//! not driving our transmit wire), so two outputs never fight.
//!
//! On the wire: SLIP-framed packets `kind, body..., crc8, END`. The link
//! answers HELLO, KEEPALIVE and PING itself; DATA packets (up to
//! `max_payload` bytes) queue for the cart (`recv`).
//!
//! Receive buffering is the PIO's 8-entry FIFO, emptied by `poll`, so a
//! burst longer than 8 wire bytes between two polls loses bytes (the CRC
//! drops that packet). Keep packets small (a DATA packet of n bytes is
//! n + 3 wire bytes plus one per 0xC0/0xDB byte) and poll often: at least
//! once per frame, and in a loop while waiting for the partner. `send`
//! keeps polling while it waits for transmit FIFO room.
//!
//! `Link(Port)`: the Port is the hardware (lib/link_rp2350.zig), the null
//! port (wasm simulator: state `.unavailable`) or the virtual cable for
//! host tests (lib/link_virtual.zig). Port interface:
//!   available: bool                      (decl) false: the link never runs
//!   fn search(p, drive: Pin) void        SIO: drive `drive` high, the
//!                                        other pin an input (pull-down)
//!   fn read(p, pin: Pin) bool            pin level
//!   fn probe(p, pin: Pin) bool           searching only: is something
//!                                        driving this input high? (pulls
//!                                        it low for a moment first: an
//!                                        RP2350 pad with its pull-down can
//!                                        float latched high, erratum E9)
//!   fn uart_start(p, tx: Pin) void       UART, tx on `tx`, rx on the other
//!   fn uart_put(p, byte: u8) bool        false: transmit FIFO full
//!   fn uart_get(p) ?u8
//!   fn take_framing_errors(p) u32        count since the last call
const std = @import("std");

/// Header pin 1 (GPIO28) and pin 3 (GPIO29).
pub const Pin = enum(u1) {
    a,
    b,
    pub fn other(p: Pin) Pin {
        return if (p == .a) .b else .a;
    }
};

pub const State = enum { unavailable, searching, handshake, connected };

/// Our transmit pin: `.normal` sends on pin 1 (GPIO28, the "TX" of the
/// silkscreen), `.swapped` on pin 3.
pub const Mode = enum(u8) { normal = 0, swapped = 1 };

/// Equal modes on both badges mean a crossed cable, different modes a
/// straight one.
pub const Cable = enum { unknown, crossed, straight };

pub const baud: u32 = 1_000_000;
pub const max_payload = 12;
/// Bump when the wire format changes; a partner with another version is
/// reported (`partner_version`) but still connects.
pub const protocol_version: u8 = 1;

pub const Kind = enum(u8) {
    hello = 0x01,
    keepalive = 0x02,
    ping = 0x03,
    pong = 0x04,
    data = 0x10,
    _,
};

/// Timing (microseconds), adjustable in one place.
pub const timing = struct {
    /// Searching: stay in one mode for a random time in this range.
    pub const dwell_min: u64 = 40_000;
    pub const dwell_max: u64 = 120_000;
    /// Searching: the listen pin must read high at two polls this far apart
    /// (and never low between) before we lock.
    pub const lock_span: u64 = 5_000;
    /// Searching: at most one probe of the listen pin this often (each one
    /// briefly pulls against the partner's driver).
    pub const probe_every: u64 = 1_000;
    /// Handshake: HELLO period, and give up (search again) after this long.
    pub const hello_every: u64 = 20_000;
    pub const handshake_timeout: u64 = 1_500_000;
    /// Connected: keepalive period; nothing heard for `peer_timeout` means
    /// the partner went away (search again).
    pub const keepalive_every: u64 = 250_000;
    pub const peer_timeout: u64 = 2_000_000;
    /// Connected: the receive line read low at two polls this far
    /// apart (never high between): the cable is out, search again. An idle
    /// UART line is high and a byte holds it low for at most 9 us.
    pub const line_low_drop: u64 = 30_000;
};

const slip_end: u8 = 0xC0;
const slip_esc: u8 = 0xDB;
const slip_esc_end: u8 = 0xDC;
const slip_esc_esc: u8 = 0xDD;

/// CRC-8, polynomial 0x07, init 0.
pub fn crc8(bytes: []const u8) u8 {
    var c: u8 = 0;
    for (bytes) |byte| {
        c ^= byte;
        for (0..8) |_| c = if (c & 0x80 != 0) (c << 1) ^ 0x07 else c << 1;
    }
    return c;
}

pub const Stats = struct {
    tx_packets: u32 = 0,
    rx_packets: u32 = 0,
    crc_errors: u32 = 0,
    /// Frames longer than a packet can be (lost END byte).
    overlong: u32 = 0,
    framing_errors: u32 = 0,
    /// DATA packets dropped because the receive queue was full.
    queue_drops: u32 = 0,
    /// Raw bytes out of the UART, before framing.
    rx_bytes: u32 = 0,
    /// Times the search locked, and handshakes that then timed out.
    locks: u32 = 0,
    handshake_timeouts: u32 = 0,
};

pub const Packet = struct {
    len: u8 = 0,
    bytes: [max_payload]u8 = undefined,
    pub fn slice(p: *const Packet) []const u8 {
        return p.bytes[0..p.len];
    }
};

pub fn Link(comptime Port: type) type {
    return struct {
        const Self = @This();
        const queue_len = 8;
        const frame_max = 1 + max_payload + 1;

        port: Port,
        /// The cart's id, sent in HELLO so a partner can tell which cart it
        /// is talking to (`partner_app`).
        app: u8,
        /// The cart's own protocol version, sent in the high nibble of
        /// HELLO's version byte (the low nibble is `protocol_version`); 0
        /// sends exactly `protocol_version`, as before it existed.
        /// lib/lockstep.zig sets it from `G.version`.
        app_version: u4 = 0,
        state: State,
        mode: Mode = .normal,
        rng: u32,

        // Searching.
        dwell_until: u64 = 0,
        high_since: ?u64 = null,
        last_probe: u64 = 0,

        // Handshake / connected.
        state_since: u64 = 0,
        last_hello: u64 = 0,
        last_tx: u64 = 0,
        last_rx: u64 = 0,
        low_since: ?u64 = null,
        /// Random per lock; the partner's changes when its link restarts.
        nonce: u16 = 0,
        partner_nonce: u16 = 0,

        // What the partner told us in its last HELLO. `partner_version` is
        // the raw byte: its app version in the high nibble, the link's
        // `protocol_version` in the low one.
        partner_mode: Mode = .normal,
        partner_app: u8 = 0,
        partner_version: u8 = 0,
        /// Counts handshakes that completed: a cart restarts its protocol
        /// when this changes (the partner may have restarted).
        session: u32 = 0,

        // Ping.
        ping_id: u8 = 0,
        ping_sent: ?u64 = null,
        /// Round trip of the last answered `ping` (us), 0 before any.
        rtt_us: u32 = 0,

        // Receive.
        frame: [frame_max]u8 = undefined,
        frame_len: u8 = 0,
        frame_escaped: bool = false,
        frame_overlong: bool = false,
        queue: [queue_len]Packet = undefined,
        queue_head: u8 = 0,
        queue_count: u8 = 0,

        /// Bytes taken from the FIFO while `send` waited for room, parsed
        /// on the next `poll`.
        pending: [64]u8 = undefined,
        pending_len: u8 = 0,

        stats: Stats = .{},

        /// `seed` picks the search timing: give each badge a different one
        /// (cart.rand()). Searching starts on the first `poll`.
        pub fn init(port: Port, app: u8, seed: u32) Self {
            return .{
                .port = port,
                .app = app,
                .state = if (Port.available) .searching else .unavailable,
                .rng = if (seed == 0) 0x9E3779B9 else seed,
            };
        }

        pub fn connected(self: *const Self) bool {
            return self.state == .connected;
        }

        pub fn cable(self: *const Self) Cable {
            if (self.state != .connected) return .unknown;
            return if (self.mode == self.partner_mode) .crossed else .straight;
        }

        /// Run the link: search, handshake, empty the receive FIFO, answer
        /// the partner, send keepalives. Cheap when idle; call at least once
        /// per frame and in a loop while waiting for the partner.
        pub fn poll(self: *Self, now: u64) void {
            switch (self.state) {
                .unavailable => return,
                .searching => return self.poll_search(now),
                .handshake, .connected => {},
            }
            self.receive(now);
            if (self.state == .searching) return;
            self.stats.framing_errors += self.port.take_framing_errors();
            if (self.state == .handshake) {
                // No line-drop check here: with a straight cable the partner
                // may still be searching in the mode that leaves our receive
                // line undriven; it locks within a dwell or two.
                if (now -% self.state_since >= timing.handshake_timeout) {
                    self.stats.handshake_timeouts += 1;
                    return self.start_search(now);
                }
                if (now -% self.last_hello >= timing.hello_every) {
                    self.last_hello = now;
                    self.send_hello(now, true);
                }
            } else {
                if (self.line_dropped(now)) return self.start_search(now);
                if (now -% self.last_rx >= timing.peer_timeout) return self.start_search(now);
                if (now -% self.last_tx >= timing.keepalive_every) self.send_packet(now, .keepalive, &.{});
            }
        }

        /// Queue a DATA packet. False when not connected or `payload` is too
        /// long; otherwise it is on the wire (or in the transmit FIFO).
        pub fn send(self: *Self, now: u64, payload: []const u8) bool {
            if (self.state != .connected or payload.len > max_payload) return false;
            self.send_packet(now, .data, payload);
            return true;
        }

        /// Next DATA packet from the partner, oldest first.
        pub fn recv(self: *Self) ?Packet {
            if (self.queue_count == 0) return null;
            const p = self.queue[self.queue_head];
            self.queue_head = (self.queue_head + 1) % queue_len;
            self.queue_count -= 1;
            return p;
        }

        /// Measure the round trip: the partner's link answers when it next
        /// polls; `rtt_us` holds the result. Ignored while one is out
        /// (for up to a second).
        pub fn ping(self: *Self, now: u64) void {
            if (self.state != .connected) return;
            if (self.ping_sent) |t| if (now -% t < 1_000_000) return;
            self.ping_id +%= 1;
            self.ping_sent = now;
            self.send_packet(now, .ping, &.{self.ping_id});
        }

        /// Drop the link and search again (after a cart borrowed the pins,
        /// e.g. the port's self test).
        pub fn restart(self: *Self, now: u64) void {
            if (self.state != .unavailable) self.start_search(now);
        }

        // ---- searching ----

        fn start_search(self: *Self, now: u64) void {
            self.state = .searching;
            self.frame_len = 0;
            self.frame_escaped = false;
            self.frame_overlong = false;
            self.queue_count = 0;
            self.ping_sent = null;
            self.enter_mode(now, self.mode);
        }

        fn enter_mode(self: *Self, now: u64, mode: Mode) void {
            self.mode = mode;
            self.high_since = null;
            self.dwell_until = now + timing.dwell_min + self.random() % (timing.dwell_max - timing.dwell_min);
            self.port.search(self.tx_pin());
        }

        fn poll_search(self: *Self, now: u64) void {
            if (self.dwell_until == 0) return self.enter_mode(now, self.mode);
            if (now -% self.last_probe < timing.probe_every) return;
            self.last_probe = now;
            if (self.port.probe(self.tx_pin().other())) {
                const since = self.high_since orelse now;
                self.high_since = since;
                if (now -% since >= timing.lock_span) return self.lock(now);
            } else {
                self.high_since = null;
            }
            if (now >= self.dwell_until) {
                self.enter_mode(now, if (self.random() & 1 == 0) .normal else .swapped);
            }
        }

        fn lock(self: *Self, now: u64) void {
            self.port.uart_start(self.tx_pin());
            self.stats.locks += 1;
            self.state = .handshake;
            self.state_since = now;
            self.last_hello = now -% timing.hello_every;
            self.last_rx = now;
            self.low_since = null;
            self.nonce = @truncate(self.random());
        }

        fn tx_pin(self: *const Self) Pin {
            return if (self.mode == .normal) .a else .b;
        }

        fn line_dropped(self: *Self, now: u64) bool {
            if (self.port.read(self.tx_pin().other())) {
                self.low_since = null;
                return false;
            }
            const since = self.low_since orelse now;
            self.low_since = since;
            return now -% since >= timing.line_low_drop;
        }

        fn random(self: *Self) u32 {
            var x = self.rng;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            self.rng = x;
            return x;
        }

        // ---- sending ----

        fn send_hello(self: *Self, now: u64, need_reply: bool) void {
            // Handshake HELLOs wait for the partner to drive our receive
            // line: until then it may be driving our transmit wire.
            if (self.state == .handshake and !self.port.read(self.tx_pin().other())) return;
            self.send_packet(now, .hello, &.{
                @intFromBool(need_reply),                            @backingInt(self.mode),     self.app,
                protocol_version | (@as(u8, self.app_version) << 4), @truncate(self.nonce >> 8), @truncate(self.nonce),
            });
        }

        fn send_packet(self: *Self, now: u64, kind: Kind, body: []const u8) void {
            // HELLO opens with END: it flushes whatever half frame the
            // partner picked up while the lines were changing hands.
            if (kind == .hello) self.put(slip_end);
            const k = @backingInt(kind);
            self.put_escaped(k);
            var crc_buf: [1 + max_payload]u8 = undefined;
            crc_buf[0] = k;
            for (body, 0..) |byte, i| {
                self.put_escaped(byte);
                crc_buf[1 + i] = byte;
            }
            self.put_escaped(crc8(crc_buf[0 .. 1 + body.len]));
            self.put(slip_end);
            self.last_tx = now;
            self.stats.tx_packets += 1;
        }

        fn put_escaped(self: *Self, byte: u8) void {
            switch (byte) {
                slip_end => {
                    self.put(slip_esc);
                    self.put(slip_esc_end);
                },
                slip_esc => {
                    self.put(slip_esc);
                    self.put(slip_esc_esc);
                },
                else => self.put(byte),
            }
        }

        /// The UART drains a byte every 10 us whatever the partner does, so
        /// this wait is bounded; keep receiving meanwhile.
        fn put(self: *Self, byte: u8) void {
            while (!self.port.uart_put(byte)) self.drain_fifo();
        }

        // ---- receiving ----

        /// Move received bytes into the frame parser without acting on
        /// them (safe inside `put`).
        fn drain_fifo(self: *Self) void {
            while (self.port.uart_get()) |byte| {
                if (self.pending_len < self.pending.len) {
                    self.pending[self.pending_len] = byte;
                    self.pending_len += 1;
                }
            }
        }

        fn receive(self: *Self, now: u64) void {
            // Parsing may send (replies), which may append to `pending`.
            var i: u8 = 0;
            while (i < self.pending_len) : (i += 1) self.parse(now, self.pending[i]);
            self.pending_len = 0;
            while (self.port.uart_get()) |byte| self.parse(now, byte);
        }

        fn parse(self: *Self, now: u64, byte: u8) void {
            self.stats.rx_bytes += 1;
            if (byte == slip_end) {
                if (self.frame_overlong) {
                    self.stats.overlong += 1;
                } else if (self.frame_len >= 2) {
                    self.handle_frame(now, self.frame[0..self.frame_len]);
                }
                self.frame_len = 0;
                self.frame_escaped = false;
                self.frame_overlong = false;
                return;
            }
            var b = byte;
            if (self.frame_escaped) {
                self.frame_escaped = false;
                b = switch (byte) {
                    slip_esc_end => slip_end,
                    slip_esc_esc => slip_esc,
                    else => byte,
                };
            } else if (byte == slip_esc) {
                self.frame_escaped = true;
                return;
            }
            if (self.frame_len == frame_max) {
                self.frame_overlong = true;
                return;
            }
            self.frame[self.frame_len] = b;
            self.frame_len += 1;
        }

        fn handle_frame(self: *Self, now: u64, f: []const u8) void {
            const body = f[1 .. f.len - 1];
            if (crc8(f[0 .. f.len - 1]) != f[f.len - 1]) {
                self.stats.crc_errors += 1;
                return;
            }
            self.stats.rx_packets += 1;
            self.last_rx = now;
            switch (@as(Kind, @fromBackingInt(@intCast(f[0])))) {
                .hello => {
                    if (body.len < 6) return;
                    const need_reply = body[0] != 0;
                    const nonce = @as(u16, body[4]) << 8 | body[5];
                    self.partner_mode = if (body[1] == 1) .swapped else .normal;
                    self.partner_app = body[2];
                    self.partner_version = body[3];
                    // Our link just locked, or the partner's restarted (a
                    // new nonce): a new session either way.
                    if (self.state == .handshake or nonce != self.partner_nonce) {
                        self.session +%= 1;
                        self.partner_nonce = nonce;
                        self.state = .connected;
                        self.low_since = null;
                        self.queue_count = 0;
                        self.ping_sent = null;
                    }
                    if (need_reply) self.send_hello(now, false);
                },
                .keepalive => {},
                .ping => if (body.len >= 1) self.send_packet(now, .pong, body[0..1]),
                .pong => if (body.len >= 1 and body[0] == self.ping_id) {
                    if (self.ping_sent) |t| self.rtt_us = @intCast(@min(now -% t, std.math.maxInt(u32)));
                    self.ping_sent = null;
                },
                .data => {
                    if (self.state != .connected) return;
                    if (self.queue_count == queue_len) {
                        self.stats.queue_drops += 1;
                        return;
                    }
                    const slot = &self.queue[(self.queue_head + self.queue_count) % queue_len];
                    slot.len = @intCast(body.len);
                    @memcpy(slot.bytes[0..body.len], body);
                    self.queue_count += 1;
                },
                _ => {},
            }
        }
    };
}

/// The link carts use: PIO2 on the badge, `.unavailable` in the simulator.
/// `var l = link.Badge.init(.{}, app_id, cart.rand());`
pub const Badge = Link(rp2350.Port);
/// The badge port's own extras: `self_test`, `regs` (diagnostics).
pub const rp2350 = @import("link_rp2350.zig");

/// The port for builds with no link hardware (the wasm simulator).
pub const NullPort = struct {
    pub const available = false;
    pub fn search(_: *NullPort, _: Pin) void {}
    pub fn read(_: *NullPort, _: Pin) bool {
        return false;
    }
    pub fn probe(_: *NullPort, _: Pin) bool {
        return false;
    }
    pub fn uart_start(_: *NullPort, _: Pin) void {}
    pub fn uart_put(_: *NullPort, _: u8) bool {
        return true;
    }
    pub fn uart_get(_: *NullPort) ?u8 {
        return null;
    }
    pub fn take_framing_errors(_: *NullPort) u32 {
        return 0;
    }
};

test "crc8 check value" {
    try std.testing.expectEqual(@as(u8, 0xF4), crc8("123456789"));
}

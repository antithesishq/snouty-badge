//! ComLynx over the badge link cable (docs/CABLE.md; lib/link.zig,
//! docs/LINK.md at the root): two badges, each emulating its own Lynx, the
//! ComLynx frames of each console carried to the other's wire. Generic over
//! the link (`Net(link.Badge)` on the badge, a link over
//! lib/link_virtual.zig in the host tests); no cart-api, no clock (callers
//! pass `now` in microseconds), no allocation. frontend/cable.zig is the
//! badge glue, frontend/cable_screen.zig the LINK screen.
//!
//! The party branch's frontend/lynxnet.zig does the same over the USB
//! lobby; it is not reused here: its messages (an 8-byte header, up to 240
//! bytes) do not fit the cable's 12-byte packets, and it leans on the
//! lobby's rooms, ids and self-echo. This file keeps its ideas (echo local,
//! relay delivery keeping each batch's spacing, restart on GO with a
//! power-on stagger) in a format sized for the cable.
//!
//! **Transport.** The cable drops a packet whose CRC fails (and the link
//! queues 8 packets at most), so ComLynx bytes travel on a small
//! go-back-N channel: every reliable packet carries a 4-bit sequence
//! number and the 4-bit cumulative ack of the other direction in byte 0;
//! `window` packets at most are unacknowledged; a gap makes the receiver
//! send one NAK (resend from the ack at once), silence for `rto_us` makes
//! the sender resend the window, and `give_up` timeouts in a row restart
//! the link (a fresh session on both badges). A one-byte packet is a bare
//! ack (or NAK), sent when nothing else carries the ack.
//!
//! Packets (byte 0 = seq << 4 | ack; byte 1 the type):
//!
//! - `'H'` hello: `crc u32` (the ROM's CRC32), `ready u8`, `version u8`.
//!   On every new session and whenever `ready` changes.
//! - `'G'` go, from the host (the badge with the larger link nonce) once
//!   both are ready with the same ROM: `crc u32`. The host restarts its
//!   console linked at once, the guest `stagger_frames` badge frames after
//!   it hears GO (two Lynxes switched on the same tick mirror each other
//!   and never elect a master: docs/COMLYNX.md section 7.10).
//! - `'L'` leave: the partner left the LINK screen or the link.
//! - `batch` (0x02): `bit16 u16` (the sender's bit time / 16 ticks), then
//!   2 entries; `frames` (0x01): 3 entries. An entry is 3 bytes: `data
//!   u8`, `w u16` = 9th bit << 15 | kind << 13 (0 frame, 1 break on, 2
//!   break off) | offset in 8 us units from the batch's first frame. A
//!   batch is what the UART sent in one badge frame (split when the bit
//!   time changes or the offset would pass 65 ms).
//!
//! **Timing: relay delivery.** A batch's first frame goes on this
//! console's wire when the batch arrives (at the current emulated time,
//! `Lynx.time()`), the others at their offsets after it: the spacing of
//! the sender's frames is kept, the delay is up to a badge frame of
//! batching plus the time until this badge's next pump (about one to two
//! frames, 17-33 ms). Warbirds with 2 players tolerates ~50 ms one way
//! (docs/COMLYNX.md section 5.3). The timestamped mode (T + D, the party's
//! default) is not used: with one heartbeat a badge frame the two badges'
//! unrelated vsync phases need D of two frames plus margin (~38 ms) to
//! avoid alternate stalls, more delay than relay delivery and stutter
//! besides. The echo is local (`Port.echo = .local`): Warbirds needs its
//! own frames back within ~0.5 ms.
const std = @import("std");
const core = @import("core");

const comlynx = core.comlynx;
const Lynx = core.Lynx;

/// The HELLO app byte (lib/lockstep.zig `apps.lynx`; this file imports no
/// lib so the host tests can build it on their own).
pub const app_id: u8 = 'X';
/// This protocol's version (in 'H'): another Snouty Lynx with another
/// version is reported, never linked.
pub const version: u8 = 1;
/// lib/link.zig `max_payload` (frontend/cable.zig checks it).
pub const max_payload = 12;
/// Unacknowledged packets at most: with the bare acks this keeps a burst
/// within the link's 8-packet queue between two polls.
pub const window = 7;
/// Resend the window after this long without an ack. The partner reads
/// the cable between the slices of its frame and all through its pump, so
/// an ack is late by a few ms at most (the gap between its pump's end and
/// its next update, or a slice of a slow frame).
pub const rto_us: u64 = 12_000;
/// Timeouts in a row before the link restarts (~1 s).
pub const give_up = 25;
/// Badge frames between GO and the guest's restart.
pub const stagger_frames = 7;

pub const Type = struct {
    pub const frames: u8 = 0x01;
    pub const batch: u8 = 0x02;
    pub const hello: u8 = 'H';
    pub const go: u8 = 'G';
    pub const leave: u8 = 'L';
};

/// 16 MHz ticks per microsecond, and the offset unit (8 us).
const tick_per_us: u64 = 16;
const off_ticks: u64 = 8 * tick_per_us;
const max_off: u64 = 0x1FFF;
const entry_len = 3;

/// What the LINK screen shows.
pub const Status = enum {
    /// No link hardware (the wasm simulator).
    unavailable,
    /// No partner on the cable (or it has not opened its LINK screen).
    searching,
    /// The partner runs another cart (`Net.partner_app`).
    wrong_cart,
    /// A Snouty Lynx; its hello has not arrived yet.
    connecting,
    /// The partner left its LINK screen.
    partner_left,
    /// Another Snouty Lynx version.
    other_version,
    /// Another ROM (`partner_crc` against `crc`).
    rom_mismatch,
    /// Same ROM: the ready flags decide (GO when both are).
    same_rom,
    /// GO: restarting linked.
    linked,
};

pub const Stats = struct {
    pkts_out: u32 = 0,
    pkts_in: u32 = 0,
    acks_out: u32 = 0,
    resends: u32 = 0,
    timeouts: u32 = 0,
    naks: u32 = 0,
    /// Reliable packets thrown away (duplicates, out of order).
    discarded: u32 = 0,
    frames_out: u32 = 0,
    frames_in: u32 = 0,
    /// Frames due before this console's clock (moved to now).
    late: u32 = 0,
    /// Frames refused by a full wire.
    refused: u32 = 0,
    /// Link restarts after `give_up` timeouts.
    restarts: u32 = 0,
};

pub fn Net(comptime Link: type) type {
    return struct {
        const Self = @This();

        link: *Link,
        /// This badge's ROM CRC32 (romsrc.crc; 0 for an embedded ROM).
        crc: u32,
        /// The link session the channel below belongs to.
        session: u32 = 0,

        // ---- the reliable channel ----
        tx: [window][max_payload]u8 = undefined,
        tx_len: [window]u8 = @splat(0),
        /// Slot of the oldest unacknowledged packet and its sequence.
        tx_head: u8 = 0,
        tx_base: u8 = 0,
        /// Packets queued (unacknowledged), and how many of them went out
        /// since the last go-back.
        tx_n: u8 = 0,
        tx_sent: u8 = 0,
        /// When the oldest one was last sent, or the last ack moved.
        tx_at: u64 = 0,
        timeouts_in_row: u8 = 0,
        rx_next: u8 = 0,
        ack_due: bool = false,
        nak_due: bool = false,
        nak_sent: bool = false,

        // ---- the partner ----
        partner_app: u8 = 0,
        /// Its 'H' (null: none this session).
        partner_crc: ?u32 = null,
        partner_version: u8 = 0,
        partner_ready: bool = false,
        partner_left: bool = false,
        host: bool = false,

        // ---- this badge ----
        ready: bool = false,
        hello_due: bool = false,
        go_due: bool = false,
        /// GO came (or went): the console restarts linked; `attached` once
        /// it has, with `port`.
        linked: bool = false,
        attached: bool = false,
        restart_in: ?u32 = null,
        port: ?*comlynx.Port = null,

        // ---- ComLynx batches ----
        /// The current outgoing batch's first frame time and bit time
        /// (null: the next frame starts one).
        batch_t0: ?u64 = null,
        batch_bit: u32 = 0,
        /// The incoming batch's anchor on this console's clock and bit time.
        rx_anchor: u64 = 0,
        rx_bit: u32 = 256,

        stats: Stats = .{},

        pub fn init(link: *Link, crc: u32) Self {
            return .{ .link = link, .crc = crc, .session = link.session, .hello_due = true };
        }

        pub fn my_id(self: *const Self) u8 {
            return if (self.host) 0 else 1;
        }

        pub fn status(self: *const Self) Status {
            if (self.linked) return .linked;
            switch (self.link.state) {
                .unavailable => return .unavailable,
                .searching, .handshake => return .searching,
                .connected => {},
            }
            if (self.partner_app != app_id) return .wrong_cart;
            if (self.partner_left) return .partner_left;
            const crc = self.partner_crc orelse return .connecting;
            if (self.partner_version != version) return .other_version;
            if (crc != self.crc) return .rom_mismatch;
            return .same_rom;
        }

        pub fn set_ready(self: *Self, ready: bool) void {
            if (self.ready == ready) return;
            self.ready = ready;
            self.hello_due = true;
        }

        // ---- per badge frame ----

        /// Before the frame: service the cable. True when the console must
        /// restart linked now: the caller finds the port's memory and calls
        /// `restart` (or `leave` when it has none).
        pub fn before_frame(self: *Self, now: u64, l: *Lynx) bool {
            self.service(now, l);
            const k = self.restart_in orelse return false;
            if (k > 0) {
                self.restart_in = k - 1;
                return false;
            }
            self.restart_in = null;
            return self.linked;
        }

        /// After the frame: what the UART sent goes out.
        pub fn after_frame(self: *Self, now: u64, l: *Lynx) void {
            if (self.attached) l.link_sync();
            self.service(now, l);
        }

        /// One linked frame in `slices` pieces with the cable serviced
        /// between them (`now_fn` gives the time in microseconds): what
        /// the UART sent so far goes out and what came goes on the wire
        /// mid-frame, so a hop costs a slice of batching instead of a
        /// frame. The console steps exactly as `step_frame` would.
        pub fn step_frame(self: *Self, now_fn: anytype, l: *Lynx, pad: u16, slices: u32) void {
            l.begin_frame(pad);
            const t0 = l.time();
            // A frame can start late (the one before ran on past its end
            // through a sprite run): then the slices are empty.
            const span = l.frame_end_time() -| t0;
            var i: u32 = 1;
            while (i < slices) : (i += 1) {
                l.run_to(t0 + span * i / slices);
                self.after_frame(now_fn(), l);
            }
            l.finish_frame();
        }

        /// Power on again with the port (GO): the console's clock restarts.
        pub fn restart(self: *Self, l: *Lynx, port: *comlynx.Port) void {
            port.* = .{ .id = self.my_id(), .echo = .local };
            self.port = port;
            // Out of line: main.zig's boot shares the one copy.
            @call(.never_inline, Lynx.init_in_place, .{ l, l.cart });
            l.attach_link(port);
            self.attached = true;
            self.batch_t0 = null;
            // A batch begun before the restart is on the old clock: its
            // remaining frames arrive late (now) rather than a minute ahead.
            self.rx_anchor = 0;
        }

        /// Off the link (the partner or the cable went, or `leave`): the
        /// console plays on unlinked (the UART stub again). The caller
        /// takes the port's memory back.
        pub fn unlink(self: *Self, l: *Lynx) void {
            if (self.attached) l.attach_link(null);
            self.linked = false;
            self.attached = false;
            self.restart_in = null;
            self.port = null;
            self.ready = false;
            self.go_due = false;
        }

        /// Say goodbye (best effort, up to ~5 ms of waiting for the ack)
        /// and unlink. The caller stops servicing the cable after this.
        pub fn leave(self: *Self, now_fn: anytype, l: *Lynx) void {
            if (self.status() != .searching and self.partner_app == app_id and self.queue(&[_]u8{ 0, Type.leave })) {
                const t0 = now_fn();
                while (self.tx_n > 0 and self.link.connected() and now_fn() -% t0 < 5_000) self.service(now_fn(), l);
            }
            self.unlink(l);
        }

        /// Everything the cable needs: read it, resend, send what is due.
        /// Cheap when idle; the glue calls it in a loop while linked.
        pub noinline fn service(self: *Self, now: u64, l: *Lynx) void {
            self.drain(now, l);
            if (self.tx_sent > 0 and now -% self.tx_at >= rto_us) {
                self.stats.timeouts += 1;
                self.stats.resends += self.tx_sent;
                self.tx_sent = 0;
                self.timeouts_in_row += 1;
                if (self.timeouts_in_row >= give_up) {
                    self.stats.restarts += 1;
                    self.timeouts_in_row = 0;
                    self.link.restart(now);
                    self.drain(now, l);
                    return;
                }
            }
            if (self.link.connected() and self.partner_app == app_id) {
                if (self.hello_due) {
                    var b: [8]u8 = .{ 0, Type.hello, 0, 0, 0, 0, @intFromBool(self.ready), version };
                    std.mem.writeInt(u32, b[2..6], self.crc, .little);
                    if (self.queue(&b)) self.hello_due = false;
                }
                self.check_go();
                if (self.go_due) {
                    var b: [6]u8 = .{ 0, Type.go, 0, 0, 0, 0 };
                    std.mem.writeInt(u32, b[2..6], self.crc, .little);
                    if (self.queue(&b)) self.go_due = false;
                }
                self.queue_frames();
            }
            self.send_pending(now, l);
            if (self.ack_due or self.nak_due) {
                const b = [1]u8{self.rx_next | @as(u8, if (self.nak_due) 0x10 else 0)};
                if (self.link.send(now, &b)) self.stats.acks_out += 1;
                self.ack_due = false;
                self.nak_due = false;
            }
        }

        fn check_go(self: *Self) void {
            if (!self.host or self.linked or !self.ready or !self.partner_ready) return;
            if (self.status() != .same_rom) return;
            self.linked = true;
            self.go_due = true;
            self.restart_in = 0;
        }

        // ---- the channel ----

        /// Queue a reliable packet (byte 0 is filled in when it goes out).
        fn queue(self: *Self, bytes: []const u8) bool {
            if (self.tx_n == window) return false;
            const slot = (self.tx_head + self.tx_n) % window;
            @memcpy(self.tx[slot][0..bytes.len], bytes);
            self.tx_len[slot] = @intCast(bytes.len);
            self.tx_n += 1;
            return true;
        }

        fn send_pending(self: *Self, now: u64, l: *Lynx) void {
            while (self.tx_sent < self.tx_n and self.link.connected()) {
                const slot = (self.tx_head + self.tx_sent) % window;
                const seq = (self.tx_base + self.tx_sent) & 15;
                self.tx[slot][0] = seq << 4 | self.rx_next;
                if (!self.link.send(now, self.tx[slot][0..self.tx_len[slot]])) return;
                self.stats.pkts_out += 1;
                if (self.tx_sent == 0) self.tx_at = now;
                self.tx_sent += 1;
                self.ack_due = false;
                self.nak_due = false;
                // Read between packets: the link parks bytes that arrive
                // while it waits for transmit room in a 64-byte buffer.
                self.drain(now, l);
            }
        }

        fn reset_channel(self: *Self) void {
            self.tx_head = 0;
            self.tx_base = 0;
            self.tx_n = 0;
            self.tx_sent = 0;
            self.timeouts_in_row = 0;
            self.rx_next = 0;
            self.ack_due = false;
            self.nak_due = false;
            self.nak_sent = false;
            self.partner_crc = null;
            self.partner_ready = false;
            self.partner_left = false;
            self.go_due = false;
        }

        noinline fn drain(self: *Self, now: u64, l: *Lynx) void {
            self.link.poll(now);
            if (self.link.session != self.session or !self.link.connected()) {
                if (self.link.session != self.session or self.partner_crc != null) {
                    // A new session (the partner restarted, the cable was
                    // replugged) or the cable is out: the old exchange and
                    // any linked game are over.
                    self.session = self.link.session;
                    self.reset_channel();
                    if (self.linked) self.unlink(l);
                    self.hello_due = self.link.connected();
                }
            }
            if (!self.link.connected()) return;
            self.partner_app = self.link.partner_app;
            if (self.partner_app != app_id) return;
            if (self.link.nonce == self.link.partner_nonce) {
                // Nobody can be host: lock again with new nonces.
                self.link.restart(now);
                return;
            }
            self.host = self.link.nonce > self.link.partner_nonce;
            while (self.link.recv()) |p| self.on_packet(now, l, p.slice());
        }

        noinline fn on_packet(self: *Self, now: u64, l: *Lynx, b: []const u8) void {
            if (b.len == 0) return;
            self.stats.pkts_in += 1;
            self.on_ack(now, b[0] & 15);
            if (b.len == 1) {
                if (b[0] & 0x10 != 0 and self.tx_n > 0) {
                    self.stats.naks += 1;
                    self.go_back();
                }
                return;
            }
            const seq = b[0] >> 4;
            if (seq != self.rx_next) {
                self.stats.discarded += 1;
                self.ack_due = true;
                // Ahead of what we expect: a packet went missing.
                if ((seq -% self.rx_next) & 15 < 8 and !self.nak_sent) {
                    self.nak_due = true;
                    self.nak_sent = true;
                }
                return;
            }
            self.rx_next = (self.rx_next + 1) & 15;
            self.nak_sent = false;
            self.ack_due = true;
            self.on_message(l, b[1], b[2..]);
        }

        fn go_back(self: *Self) void {
            if (self.tx_sent > 0) self.stats.resends += self.tx_sent;
            self.tx_sent = 0;
        }

        fn on_ack(self: *Self, now: u64, ack: u8) void {
            const k = (ack -% self.tx_base) & 15;
            if (k == 0 or k > self.tx_n) return;
            self.tx_base = ack;
            self.tx_head = @intCast((self.tx_head + k) % window);
            self.tx_n -= k;
            self.tx_sent -|= k;
            self.tx_at = now;
            self.timeouts_in_row = 0;
        }

        fn on_message(self: *Self, l: *Lynx, t: u8, body: []const u8) void {
            switch (t) {
                Type.hello => if (body.len >= 6) {
                    self.partner_crc = std.mem.readInt(u32, body[0..4], .little);
                    self.partner_ready = body[4] != 0;
                    self.partner_version = body[5];
                    self.partner_left = false;
                },
                Type.go => if (body.len >= 4 and !self.linked) {
                    if (std.mem.readInt(u32, body[0..4], .little) != self.crc) return;
                    self.linked = true;
                    self.restart_in = stagger_frames;
                },
                Type.leave => {
                    self.partner_left = true;
                    self.partner_ready = false;
                    if (self.linked) self.unlink(l);
                },
                Type.batch => if (body.len >= 2) {
                    self.rx_bit = @as(u32, std.mem.readInt(u16, body[0..2], .little)) * 16;
                    self.rx_anchor = l.time();
                    self.deliver(l, body[2..]);
                },
                Type.frames => self.deliver(l, body),
                else => {},
            }
        }

        fn deliver(self: *Self, l: *Lynx, entries: []const u8) void {
            // Not switched on yet (the guest's stagger): not on the wire.
            if (!self.attached) return;
            var i: usize = 0;
            while (i + entry_len <= entries.len) : (i += entry_len) {
                const w = std.mem.readInt(u16, entries[i + 1 ..][0..2], .little);
                const kind: comlynx.Kind = switch ((w >> 13) & 3) {
                    1 => .break_on,
                    2 => .break_off,
                    else => .frame,
                };
                const late = l.link_deliver(.{
                    .start = self.rx_anchor + @as(u64, w & 0x1FFF) * off_ticks,
                    .bit_ticks = self.rx_bit,
                    .data = entries[i],
                    .ninth = w & 0x8000 != 0,
                    .kind = kind,
                    .src = self.my_id() ^ 1,
                }) orelse {
                    self.stats.refused += 1;
                    continue;
                };
                if (late > 0) self.stats.late += 1;
                self.stats.frames_in += 1;
            }
        }

        /// What the UART sent, in packets, while the window has room; the
        /// rest waits in the port's queue (in order) for the next call.
        noinline fn queue_frames(self: *Self) void {
            if (!self.attached) return;
            const p = self.port orelse return;
            while (p.out_len > 0 and self.tx_n < window) {
                var b: [max_payload]u8 = undefined;
                const f0 = p.peek(0);
                var k: usize = 2;
                if (self.batch_t0 == null or f0.bit_ticks != self.batch_bit or (f0.time -| self.batch_t0.?) / off_ticks > max_off) {
                    self.batch_t0 = f0.time;
                    self.batch_bit = f0.bit_ticks;
                    b[1] = Type.batch;
                    std.mem.writeInt(u16, b[2..4], @intCast(@min(f0.bit_ticks / 16, 0xFFFF)), .little);
                    k = 4;
                } else b[1] = Type.frames;
                var n: u32 = 0;
                while (n < p.out_len and k + entry_len <= max_payload) : (n += 1) {
                    const f = p.peek(n);
                    if (f.bit_ticks != self.batch_bit) break;
                    const off = (f.time -| self.batch_t0.?) / off_ticks;
                    if (off > max_off) break;
                    const kind: u16 = switch (f.kind) {
                        .frame => 0,
                        .break_on => 1,
                        .break_off => 2,
                    };
                    b[k] = f.data;
                    std.mem.writeInt(u16, b[k + 1 ..][0..2], @as(u16, @intCast(off)) | kind << 13 | @as(u16, @intFromBool(f.ninth)) << 15, .little);
                    k += entry_len;
                }
                _ = self.queue(b[0..k]);
                p.drop(n);
                self.stats.frames_out += n;
            }
            // Everything this frame sent is queued: the next frame's first
            // frame opens a new batch.
            if (p.out_len == 0) self.batch_t0 = null;
        }
    };
}

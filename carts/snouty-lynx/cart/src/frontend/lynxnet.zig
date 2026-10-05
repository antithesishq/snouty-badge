//! ComLynx over the lobby (docs/COMLYNX.md sections 7 and 10): the
//! console's `comlynx.Port` carried by lib/party.zig (lobby protocol v1
//! over the fork firmware's cart serial ring). Generic over the client
//! type, so the host tests run it over lib/party_virtual.zig; no cart-api,
//! no clock (time is the console's own), no allocation.
//!
//! Wire format (the payload of one SEND / DATA, little-endian):
//!
//! - `'F'` frames: `seq: u8`, `t_end: u32` (the sender's link time at the
//!   end of what this message covers, in microseconds: its heartbeat),
//!   `bit16: u16` (the sender's bit time / 16 ticks), then 4 bytes per
//!   ComLynx frame: `back: u16` (microseconds from its start bit back to
//!   `t_end`), `data: u8`, `flags: u8` (bit 0 the 9th bit, bit 1 a
//!   TXBRK on, bit 2 TXBRK off). One message per badge frame (empty = a
//!   heartbeat), split at 240 bytes (58 frames).
//! - `'R'` ready: `ready: u8`, `d_ms: u8` (the D this console asks for),
//!   `crc: u32` (its ROM's CRC32). Sent on every roster change and twice
//!   a second until the game starts.
//! - `'G'` go, from the host (the lowest id present): `d_ms: u8` (0 =
//!   relay mode), `crc: u32`. Sent to everyone including the host (0xFE);
//!   every console that gets it restarts its Lynx linked (games look for
//!   the other consoles at power on), player k after `stagger_frames` x k
//!   badge frames: two Lynxes switched on the same tick mirror each other
//!   (a ROM that elects a master from a free-running timer elects the same
//!   on both), real ones never are.
//!
//! Echo: a console hears its own frames at once (`Port.echo = .local`),
//! never through the relay: Warbirds needs its echo within ~0.5 ms
//! (section 5), far below any relay's round trip. So frames go with
//! `to = 0xFF` (everyone else); the self-echo the lobby offers (0xFE)
//! would only be thrown away.
//!
//! Modes (agreed in GO):
//!
//! - **relay** (D = 0): a peer's frames go on this console's wire when
//!   they arrive (at the start of the badge frame that drains them),
//!   keeping their spacing. No stalls; the delay is the relay's plus up
//!   to a frame of batching; consoles may see near-simultaneous frames of
//!   two peers in different orders.
//! - **timestamped** (D > 0): link time counts from GO on every console;
//!   a peer frame stamped T goes on the wire at exactly T + D of this
//!   console's link time, and a console never runs a badge frame that
//!   would end past min(peer heartbeat) + D: it stalls (skips stepping)
//!   until the peers' heartbeats catch up. Every console then sees every
//!   peer frame at the same link time whatever the network jitter, as
//!   long as one-way latency + a frame stays below D.
//!
//! Leaving: a player missing from a ROSTER is a console unplugged (its
//! frames stop; an open break of its closes). A rejoin (LEAVE then a new
//! join, maybe with another id) is an unplug and a new console.
const std = @import("std");
const core = @import("core");
/// lib/party.zig's limits (the client type comes in as a parameter, so
/// this file needs no import of it and host tests can drive it through
/// lib/party_host.zig).
const party = struct {
    pub const max_data: usize = 240;
    pub const max_players: usize = 16;
    pub const game_len = 8;
};

const comlynx = core.comlynx;
const Lynx = core.Lynx;

pub const Mode = enum(u8) { relay, timestamped };

/// Microseconds in 16 MHz ticks.
const tick_per_us: u64 = 16;

pub const Msg = struct {
    pub const frames: u8 = 'F';
    pub const ready: u8 = 'R';
    pub const go: u8 = 'G';
};
pub const header_len = 8;
pub const entry_len = 4;
pub const max_entries = (party.max_data - header_len) / entry_len;

/// How far a frame may run past its end (a sprite run that started before
/// it: the CPU sleeps through Suzy's whole list): the stall test's margin.
pub const overrun_ticks: u64 = 4 * 1000 * tick_per_us;

/// Badge frames between the restarts of consecutive player ids after GO.
pub const stagger_frames = 7;

pub const Stats = struct {
    msgs_out: u32 = 0,
    msgs_in: u32 = 0,
    frames_out: u32 = 0,
    frames_in: u32 = 0,
    /// Badge frames not stepped (timestamped: waiting for heartbeats).
    stalls: u32 = 0,
    /// Frames due before this console's clock (moved to now).
    late: u32 = 0,
    /// Sends refused (the transmit ring full); retried next frame.
    tx_full: u32 = 0,
    leavers: u32 = 0,
};

pub fn Net(comptime Client: type) type {
    return struct {
        const Self = @This();

        client: *Client,
        port: *comlynx.Port,
        /// The ROM's CRC32 (rooms are per ROM: the game id carries it too).
        crc: u32,
        /// D this console asks for in ms (0 = relay mode).
        want_d_ms: u8 = 0,
        ready: bool = false,

        /// Linked: GO came, the console was restarted with the port.
        linked: bool = false,
        mode: Mode = .relay,
        d_ticks: u64 = 0,
        /// Link time (ticks since GO) = `link_base` + `Lynx.time()` - `t0`
        /// (the restart sets the console's clock back to 0).
        link_base: u64 = 0,
        t0: u64 = 0,
        /// After GO: badge frames until this console restarts linked
        /// (null: restarted, `attached`).
        restart_in: ?u32 = null,
        attached: bool = false,
        /// GO arrived: restart the console before its next frame.
        go_due: bool = false,
        go_d_ms: u8 = 0,
        /// Players in the room (bit per id), and those that said ready
        /// (with this ROM).
        present: u16 = 0,
        peers_ready: u16 = 0,
        peer_d_ms: [party.max_players]u8 = @splat(0),
        /// Each peer's last heartbeat in link ticks (null: none yet).
        peer_time: [party.max_players]?u64 = @splat(null),
        seq: u8 = 0,
        /// Frames the UART sent that did not fit in a message yet.
        pend: [comlynx.out_cap]comlynx.TxFrame = undefined,
        pend_len: u32 = 0,
        ready_left: u8 = 0,
        stats: Stats = .{},

        pub fn init(client: *Client, port: *comlynx.Port, crc: u32) Self {
            return .{ .client = client, .port = port, .crc = crc };
        }

        /// The lobby game id for a ROM: "LX" + 6 hex digits of its CRC32,
        /// so only consoles running the same ROM share a room.
        pub fn game_id(crc: u32) [party.game_len]u8 {
            var g: [party.game_len]u8 = undefined;
            g[0] = 'L';
            g[1] = 'X';
            const hex = "0123456789ABCDEF";
            var i: usize = 0;
            while (i < 6) : (i += 1) g[2 + i] = hex[(crc >> @intCast(20 - 4 * i)) & 0xF];
            return g;
        }

        pub fn me(self: *const Self) ?u8 {
            return self.client.me();
        }

        /// The host: the lowest id present.
        pub fn host(self: *const Self) ?u8 {
            if (self.present == 0) return null;
            return @intCast(@ctz(self.present));
        }

        pub fn player_count(self: *const Self) u8 {
            return @popCount(self.present);
        }

        /// Every present player is ready with this ROM (two at least).
        pub fn all_ready(self: *const Self) bool {
            const mine: u16 = if (self.me()) |m| @as(u16, 1) << @intCast(m) else 0;
            const r = self.peers_ready | (if (self.ready) mine else 0);
            return self.player_count() >= 2 and r & self.present == self.present;
        }

        fn link_now(self: *const Self, l: *const Lynx) u64 {
            return self.link_base + (l.time() -| self.t0);
        }

        /// A link time on this console's clock (`Lynx.time()`).
        fn local(self: *const Self, link: u64) u64 {
            return self.t0 + (link -| self.link_base);
        }

        // ---- per badge frame ----

        /// Before the frame: run the client, take every message (drain the
        /// ring every frame: the relay drops a badge that stops reading).
        /// True when the console was restarted linked (GO): the caller
        /// redraws / resets what depends on a boot.
        pub fn before_frame(self: *Self, l: *Lynx) bool {
            while (self.client.poll()) |ev| switch (ev) {
                .joined => {
                    self.ready_left = 0;
                },
                .roster => self.on_roster(l),
                .data => |d| self.on_data(l, d.from, d.bytes),
                .lost => self.on_roster(l),
                .pong, .err => {},
            };
            // The lobby's own present set (the client's) after the events.
            if (!self.linked and self.client.state() == .joined) {
                if (self.ready_left == 0) {
                    self.send_ready();
                    self.ready_left = 30;
                } else self.ready_left -= 1;
            }
            if (self.go_due) {
                self.go_due = false;
                self.start_link(l, self.go_d_ms);
            }
            if (self.restart_in) |k| {
                if (k > 0) {
                    self.restart_in = k - 1;
                    return false;
                }
                self.restart_in = null;
                self.restart(l);
                return true;
            }
            return false;
        }

        /// May the next badge frame run (timestamped: every peer's
        /// heartbeat within D of its end)? Counts a stall when not.
        pub fn can_step(self: *Self, l: *const Lynx) bool {
            if (!self.linked or self.mode == .relay) return true;
            // A frame may run on past its end by a sprite run (the CPU
            // sleeps through Suzy's list): up to ~4 ms.
            const end = self.link_now(l) + core.ticks_per_frame + 1 + overrun_ticks;
            const m = self.me() orelse return true;
            var it = self.present & ~(@as(u16, 1) << @intCast(m));
            while (it != 0) : (it &= it - 1) {
                const p: usize = @ctz(it);
                const t = self.peer_time[p] orelse {
                    self.stats.stalls += 1;
                    return false;
                };
                if (end > t + self.d_ticks) {
                    self.stats.stalls += 1;
                    return false;
                }
            }
            return true;
        }

        /// After the frame (stepped or not): what the UART sent goes out
        /// as one message (a heartbeat when empty).
        pub fn after_frame(self: *Self, l: *Lynx) void {
            if (!self.linked) return;
            if (self.attached) l.link_sync();
            while (self.attached) {
                const f = self.port.take() orelse break;
                if (self.pend_len == self.pend.len) break;
                self.pend[self.pend_len] = f;
                self.pend_len += 1;
            }
            const t_end = self.link_now(l);
            var first: u32 = 0;
            while (true) {
                const n = @min(self.pend_len - first, max_entries);
                if (!self.send_frames(t_end, self.pend[first..][0..n])) {
                    self.stats.tx_full += 1;
                    break;
                }
                first += n;
                if (first == self.pend_len) break;
            }
            // Keep what did not go (next frame, in order).
            std.mem.copyForwards(comlynx.TxFrame, self.pend[0 .. self.pend_len - first], self.pend[first..self.pend_len]);
            self.pend_len -= first;
        }

        fn send_frames(self: *Self, t_end: u64, fs: []const comlynx.TxFrame) bool {
            var b: [party.max_data]u8 = undefined;
            b[0] = Msg.frames;
            b[1] = self.seq;
            const te_us: u32 = @truncate(t_end / tick_per_us);
            std.mem.writeInt(u32, b[2..6], te_us, .little);
            const bit16: u16 = if (fs.len > 0) @intCast(@min(fs[0].bit_ticks / 16, 0xFFFF)) else 16;
            std.mem.writeInt(u16, b[6..8], bit16, .little);
            var k: usize = header_len;
            for (fs) |f| {
                // f.time is on this console's clock; t_end is link time.
                const back_us = (t_end -| (self.link_base + (f.time -| self.t0))) / tick_per_us;
                std.mem.writeInt(u16, b[k..][0..2], @intCast(@min(back_us, 0xFFFF)), .little);
                b[k + 2] = f.data;
                b[k + 3] = @as(u8, @intFromBool(f.ninth)) | switch (f.kind) {
                    .frame => @as(u8, 0),
                    .break_on => 2,
                    .break_off => 4,
                };
                k += entry_len;
            }
            if (!self.client.broadcast(b[0..k])) return false;
            self.seq +%= 1;
            self.stats.msgs_out += 1;
            self.stats.frames_out += @intCast(fs.len);
            return true;
        }

        // ---- lobby ----

        pub fn set_ready(self: *Self, ready: bool) void {
            self.ready = ready;
            self.ready_left = 0;
        }

        fn send_ready(self: *Self) void {
            var b: [7]u8 = undefined;
            b[0] = Msg.ready;
            b[1] = @intFromBool(self.ready);
            b[2] = self.want_d_ms;
            std.mem.writeInt(u32, b[3..7], self.crc, .little);
            _ = self.client.broadcast(&b);
        }

        /// The host starts the game for everyone (itself through its own
        /// echo, so all restart on the same message). False unless this
        /// console is the host and all are ready.
        pub fn start(self: *Self, d_ms: u8) bool {
            if (self.linked or self.me() == null or self.me() != self.host() or !self.all_ready()) return false;
            var b: [6]u8 = undefined;
            b[0] = Msg.go;
            b[1] = d_ms;
            std.mem.writeInt(u32, b[2..6], self.crc, .little);
            return self.client.broadcast_echo(&b);
        }

        fn on_roster(self: *Self, l: *Lynx) void {
            const now = self.client.present;
            const gone = self.present & ~now;
            self.present = now;
            self.peers_ready &= now;
            var it = gone;
            while (it != 0) : (it &= it - 1) {
                const p: u5 = @intCast(@ctz(it));
                self.peer_time[p] = null;
                self.stats.leavers += 1;
                // Its frames stop; a break it held ends now.
                if (self.linked) self.port.close_break(p, l.mikey.now);
            }
            // A new roster: say where we stand at once.
            self.ready_left = 0;
        }

        fn on_data(self: *Self, l: *Lynx, from: u8, bytes: []const u8) void {
            if (bytes.len == 0) return;
            self.stats.msgs_in += 1;
            switch (bytes[0]) {
                Msg.ready => if (bytes.len >= 7 and from < party.max_players) {
                    const crc = std.mem.readInt(u32, bytes[3..7], .little);
                    const bit = @as(u16, 1) << @intCast(from);
                    if (bytes[1] != 0 and crc == self.crc) self.peers_ready |= bit else self.peers_ready &= ~bit;
                    self.peer_d_ms[from] = bytes[2];
                },
                Msg.go => if (bytes.len >= 6 and !self.linked) {
                    const crc = std.mem.readInt(u32, bytes[2..6], .little);
                    if (crc != self.crc) return;
                    self.go_due = true;
                    self.go_d_ms = bytes[1];
                },
                Msg.frames => if (self.linked and bytes.len >= header_len and from < party.max_players) self.on_frames(l, from, bytes),
                else => {},
            }
        }

        fn on_frames(self: *Self, l: *Lynx, from: u8, b: []const u8) void {
            const te_us = std.mem.readInt(u32, b[2..6], .little);
            const bit_ticks: u32 = @as(u32, std.mem.readInt(u16, b[6..8], .little)) * 16;
            const t_end = @as(u64, te_us) * tick_per_us;
            self.peer_time[from] = t_end;
            // Not switched on yet: not on the wire.
            if (!self.attached) return;
            const n = (b.len - header_len) / entry_len;
            // Relay mode: the batch's spacing, from now (its first frame
            // goes on the wire at once).
            var first_back: u64 = 0;
            if (n > 0) first_back = @as(u64, std.mem.readInt(u16, b[header_len..][0..2], .little)) * tick_per_us;
            for (0..n) |i| {
                const e = b[header_len + i * entry_len ..][0..entry_len];
                const back = @as(u64, std.mem.readInt(u16, e[0..2], .little)) * tick_per_us;
                const kind: comlynx.Kind = if (e[3] & 2 != 0) .break_on else if (e[3] & 4 != 0) .break_off else .frame;
                const at = switch (self.mode) {
                    .relay => l.time() + (first_back -| back),
                    .timestamped => self.local((t_end -| back) + self.d_ticks),
                };
                const late = l.link_deliver(.{ .start = at, .bit_ticks = bit_ticks, .data = e[2], .ninth = e[3] & 1 != 0, .kind = kind, .src = from }) orelse continue;
                if (late > 0) self.stats.late += 1;
                self.stats.frames_in += 1;
            }
        }

        /// GO: link time starts now; this console restarts linked
        /// `stagger_frames` x its id frames later (`restart`).
        fn start_link(self: *Self, l: *Lynx, d_ms: u8) void {
            self.mode = if (d_ms == 0) .relay else .timestamped;
            self.d_ticks = @as(u64, d_ms) * 1000 * tick_per_us;
            self.link_base = 0;
            self.t0 = l.time();
            self.peer_time = @splat(null);
            self.pend_len = 0;
            self.linked = true;
            self.attached = false;
            self.restart_in = stagger_frames * @as(u32, self.me() orelse 0);
        }

        /// Power on again with the port (the clock restarts at 0).
        fn restart(self: *Self, l: *Lynx) void {
            self.link_base = self.link_now(l);
            self.port.* = .{ .id = self.me() orelse 0, .echo = .local };
            l.init_in_place(l.cart);
            l.attach_link(self.port);
            self.t0 = l.time();
            self.attached = true;
        }

        /// Leave the link (and the room's game): the console keeps
        /// running unlinked.
        pub fn unlink(self: *Self, l: *Lynx) void {
            if (!self.linked) return;
            if (self.attached) l.attach_link(null);
            self.linked = false;
            self.attached = false;
            self.restart_in = null;
            self.ready = false;
        }
    };
}

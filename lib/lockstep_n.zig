//! Deterministic lockstep for up to 16 badges over the laptop's `badge
//! lobby` relay (docs/LOCKSTEP_N.md). The N-player sibling of
//! lib/lockstep.zig (two badges on the link cable), with the same game
//! side `G`, generalised: `simulate(w, in: *const [16]u8, present: u16)`
//! and `hand_over(w, slot)` for each player that leaves.
//!
//! The transport is lobby protocol v1 (lib/party.zig over
//! lib/cart_serial.zig): reliable, lossless, and one order per room (the
//! relay queues each frame to every recipient before it looks at the next,
//! and the ROSTER that removes a player comes after every frame that
//! player got to the relay). Nothing is resent and nothing acknowledged:
//! every badge broadcasts its human's input byte for each tick,
//! `delay` ticks ahead, and a tick runs when every present player's byte
//! for it is in. Because the order is one, a leave needs no agreement:
//! the leaver's last tick is the last input of theirs anyone received,
//! the same everywhere, and from the next tick `G.hand_over` gives the
//! slot to the game's AI.
//!
//! The lobby: host = the lowest present player id; the host's rules (1 to
//! 8 bytes) and input delay; each player's pick and ready flag; GO (the
//! host) carries the race id, the delay, a seed, the participants and
//! their picks. A badge that joins during a race waits in the lobby for
//! the next one. Every `check_every` ticks each badge broadcasts its World
//! hash and compares the others' with its own: any difference is `desync`
//! on every badge. A player silent for `G.stall_drop_ms` while the others
//! wait for its input is dropped (DROP, then every other badge's ACK
//! fixes the tick; section 4.5 of the doc); a dropped badge that wakes up
//! sees `dropped`.
//!
//! Generic over the port `B` (`cart_serial.Badge(.{})` on the badge,
//! `cart_serial.Virtual(.{})` in host tests); the port is owned by value
//! inside `client`. No allocation, no clock (callers pass `now` in
//! microseconds), no floats. Carts import this module only and reach the
//! lobby client as `lockstep_n.party` (a separate `party` module on the
//! same file would be one file in two modules).
const std = @import("std");
pub const party = @import("party.zig");

/// Game ids (HELLO `game`, 8 bytes): rooms with different ids never mix.
/// Bump the last character when a game's wire changes.
pub const games = struct {
    pub const snoutenstein = party.pad(party.game_len, "SNOUTDM1");
};

pub const max_slots = 16;
/// The input delay a race may use, in ticks (GO carries it).
pub const max_delay: u32 = 30;
/// Ticks of input held per slot: at most 2 * delay + 2 are ever in flight
/// past the tick being stepped (62 at delay 30).
const ring_len: u32 = 64;
/// Ticks one INPUT frame may carry.
pub const max_batch: u32 = 16;

pub const timing = struct {
    /// `state()` says `.waiting` once `step` has had no inputs this long.
    pub const waiting_after: u64 = 500_000;
    /// Lobby: PING the relay this often (round trip, for `suggested_delay`).
    pub const ping_every: u64 = 500_000;
    /// A drop still unresolved after this many stall-drop times ends the
    /// race as a desync (two badges proposed it and nobody else is left
    /// to tell them the order; section 4.5).
    pub const drop_give_up: u64 = 2;
};

/// Kinds of the DATA payloads (the first byte). Below 0x80: INPUT.
pub const K = struct {
    /// host: kind, rules[rules_len]
    pub const setup: u8 = 0x80;
    /// all: kind, pick (bits 0-6) | ready (bit 7), version, rtt (2 ms units)
    pub const pick: u8 = 0x81;
    /// host: kind, race id, version, delay, seed u32, mask u16, rules,
    /// one pick per set bit of mask in slot order
    pub const go: u8 = 0x82;
    /// all: kind, race id (this badge left that race)
    pub const quit: u8 = 0x83;
    /// proposer: kind, race id, slot, tick u32 (the proposer's next tick
    /// from the slot)
    pub const drop: u8 = 0x84;
    /// all but the proposer: kind, race id, slot, cut u32
    pub const ack: u8 = 0x85;
    /// all racing: kind, epoch u16, hash u32
    pub const hash: u8 = 0x86;
};

pub const State = enum(u8) {
    /// Stock firmware: "NEEDS PARTY FIRMWARE" (grey the PARTY entry).
    unsupported,
    /// No `badge lobby` on the laptop: "START BADGE LOBBY ON THE LAPTOP".
    disconnected,
    /// Out of the room (`exit`).
    idle,
    /// HELLO sent, no WELCOME yet.
    joining,
    /// In the room's lobby (picks, rules, GO; `match_running` while
    /// others race).
    lobby,
    /// A race runs; `step` advances it.
    racing,
    /// Racing, but `step` has had no inputs for `timing.waiting_after`.
    waiting,
    /// World hashes differ: `step` stops. Until `leave`.
    desync,
    /// The others dropped this badge (it was silent too long). Until `leave`.
    dropped,
};

const Phase = enum(u8) { unsupported, disconnected, idle, joining, lobby, racing, desync, dropped };

pub const Stats = struct {
    input_frames_sent: u32 = 0,
    input_frames_recv: u32 = 0,
    ticks_recv: u32 = 0,
    control_sent: u32 = 0,
    control_recv: u32 = 0,
    checks_ok: u32 = 0,
    /// `step` calls that found an input missing.
    stalls: u32 = 0,
    pumps: u32 = 0,
    /// Sends put off because the transmit ring was full.
    tx_waits: u32 = 0,
    drops_proposed: u32 = 0,
    acks_sent: u32 = 0,
    /// Frames that broke the protocol (ends the race as a desync).
    bad: u32 = 0,
};

const Check = struct { epoch: u32 = 0, hash: u32 = 0 };

fn bit(s: anytype) u16 {
    return @as(u16, 1) << @intCast(s);
}

fn lowest(mask: u16) ?u4 {
    return if (mask == 0) null else @intCast(@ctz(mask));
}

/// `B`: the port (`cart_serial.Badge(.{})`, or `.Virtual(.{})` in tests).
/// `G`: the game, a namespace with
///   World: type
///   fn simulate(w: *World, in: *const [16]u8, present: u16) void
///   fn hash(w: *const World) u32                every check_every ticks
///   fn hand_over(w: *World, slot: u4) void      a player left: AI
///   rules_len: comptime_int (1..8)              host's rules bytes
///   input_delay: u32 (1..30)                    the default delay
/// and optionally
///   check_every: u32 = 32                       ticks between hashes
///   pause_bit: ?u8 = null                       press edge toggles paused
///   fn can_pause(w: *const World) bool          = true
///   fn picks_ok(picks: *const [16]u8, mask: u16) bool = true
///   pick_bits: u8 = 7                           pick values < 1 << pick_bits
///   version: u8 = 0                             another one: not raced with
///   stall_drop_ms: u32 = 3000                   silent this long: dropped
///   min_players: u8 = 2                         humans GO needs
///   send_every: u32 = 1                         ticks per INPUT frame
pub fn LockstepN(comptime B: type, comptime G: type) type {
    return struct {
        const Self = @This();

        pub const Client = party.Client(B);
        pub const World = G.World;
        pub const rules_len: comptime_int = G.rules_len;
        pub const default_delay: u32 = G.input_delay;
        pub const check_every: u32 = if (@hasDecl(G, "check_every")) G.check_every else 32;
        pub const pause_bit: ?u8 = if (@hasDecl(G, "pause_bit")) G.pause_bit else null;
        pub const pick_bits: u8 = if (@hasDecl(G, "pick_bits")) G.pick_bits else 7;
        pub const version: u8 = if (@hasDecl(G, "version")) G.version else 0;
        pub const stall_drop_us: u64 = @as(u64, if (@hasDecl(G, "stall_drop_ms")) G.stall_drop_ms else 3000) * 1000;
        pub const min_players: u8 = if (@hasDecl(G, "min_players")) G.min_players else 2;
        pub const send_every: u32 = if (@hasDecl(G, "send_every")) G.send_every else 1;
        /// The largest delay a race may use: a badge runs at most delay + 1
        /// ticks ahead of another, and each badge keeps one unchecked hash
        /// per player, so the delay stays below check_every - 1.
        pub const delay_cap: u32 = @min(max_delay, check_every - 2);
        const pick_mask: u8 = @intCast((@as(u16, 1) << @intCast(pick_bits)) - 1);
        const own_slots = 4;

        comptime {
            if (rules_len < 1 or rules_len > 8) @compileError("lockstep_n: rules_len must be 1 to 8");
            if (default_delay < 1 or default_delay > max_delay) @compileError("lockstep_n: input_delay must be 1 to 30");
            if (check_every < 4 or check_every - 2 < default_delay) @compileError("lockstep_n: check_every must be at least input_delay + 2 and 4");
            if (pick_bits < 1 or pick_bits > 7) @compileError("lockstep_n: pick_bits must be 1 to 7");
            if (send_every < 1 or send_every > max_batch) @compileError("lockstep_n: send_every must be 1 to 16");
            if (min_players < 1 or min_players > max_slots) @compileError("lockstep_n: min_players must be 1 to 16");
        }

        pub const Rules = [rules_len]u8;

        /// The agreed race (GO).
        pub const Race = struct {
            id: u8 = 0,
            delay: u8 = default_delay,
            seed: u32 = 1,
            /// The participants (slots), as GO named them.
            mask: u16 = 0,
            rules: Rules = @splat(0),
            /// Participants' picks by slot (0 elsewhere).
            picks: [max_slots]u8 = @splat(0),
        };

        client: Client,
        phase: Phase = .disconnected,
        now: u64 = 0,
        entropy: u32,

        // ---- lobby ----
        /// The roster as last handled (joins and leaves are its changes).
        roster: u16 = 0,
        /// Host: the rules and delay it offers. Others: the host's SETUP.
        offer: Rules = @splat(0),
        heard: Rules = @splat(0),
        heard_from: ?u4 = null,
        delay_choice: u8 = default_delay,
        pick: u8 = pick_mask,
        ready: bool = false,
        /// Each player's last PICK byte (pick | ready << 7), 2 ms rtt.
        peer_pick: [max_slots]u8 = @splat(0),
        peer_rtt: [max_slots]u8 = @splat(0),
        /// Players heard from (a PICK) since they joined; on another version.
        peer_heard: u16 = 0,
        peer_other_version: u16 = 0,
        setup_due: bool = false,
        pick_due: bool = false,
        go_due: bool = false,
        quit_due: bool = false,
        quit_id: u8 = 0,
        /// The last race id GO used in this room (0: none).
        race_id: u8 = 0,
        /// The last GO's participants still in it, as seen here.
        match_mask: u16 = 0,
        /// Round trips to the relay (us), the last four PONGs.
        rtt_samples: [4]u32 = @splat(0),
        rtt_i: u8 = 0,
        last_ping: u64 = 0,

        // ---- the race ----
        race: Race = .{},
        started: bool = false,
        delay: u32 = default_delay,
        /// The next tick `step` runs (paused ticks included).
        tick: u32 = 0,
        /// Local inputs held for ticks < local_hi, sent for < sent_hi.
        local_hi: u32 = 0,
        sent_hi: u32 = 0,
        local: [ring_len]u8 = @splat(0),
        /// Each player's inputs held for ticks < hi[s].
        hi: [max_slots]u32 = @splat(0),
        remote: [max_slots][ring_len]u8 = @splat(@splat(0)),
        /// When each player's last frame arrived (us, truncated).
        heard_at: [max_slots]u32 = @splat(0),
        /// Participants still played by their human at `tick` (this badge
        /// included); `bots` = the race's other participants.
        humans: u16 = 0,
        /// Leavers whose last human tick is fixed: human until `cut`.
        cut_set: u16 = 0,
        cut: [max_slots]u32 = @splat(0),
        /// Drops this badge proposed, waiting for an ACK; their floors (no
        /// tick at or past one runs until it is resolved); DROPs and ACKs
        /// to send.
        drop_pending: u16 = 0,
        drop_floor: [max_slots]u32 = @splat(0),
        drop_since: u32 = 0,
        drop_due: u16 = 0,
        ack_due: u16 = 0,
        /// Humans whose byte had the pause bit last tick.
        prev_pause: u16 = 0,
        /// The agreed pause (from the input bytes): ticks still run, but
        /// `simulate` is not called.
        paused: bool = false,
        stall_since: ?u64 = null,
        own: [own_slots]Check = @splat(.{}),
        peer: [max_slots]Check = @splat(.{}),
        /// The next own hash epoch to broadcast.
        hash_next: u32 = 1,
        desync_tick: u32 = 0,

        stats: Stats = .{},

        /// `port`: `cart_serial.Badge(.{}){}` on the badge. `opts.game`:
        /// the game id (`games`). `entropy`: `cart.rand()` (seeds GO).
        pub fn init(port: B, opts: party.Options, entropy: u32) Self {
            return .{ .client = Client.init(port, opts), .entropy = entropy | 1 };
        }

        // ---- per frame ---------------------------------------------------

        /// Read the port, handle every frame, send what is due. Callable
        /// from anywhere and as often as the cart likes (the top of
        /// `update`, band hooks, the loop to 14 ms while `busy`); it
        /// touches only the port and this struct, never the World. Drains
        /// the receive ring: the relay removes a player whose queue
        /// overflows, so a badge must pump every frame, long ones included.
        pub fn pump(self: *Self, now: u64) void {
            self.now = now;
            self.stats.pumps +%= 1;
            while (self.client.poll()) |ev| self.on_event(ev);
            self.follow_client();
            if (self.phase == .racing) self.watch_stalls();
            if (self.phase == .lobby and self.client.state() == .joined and now -% self.last_ping >= timing.ping_every) {
                if (self.client.ping(@truncate(now))) self.last_ping = now;
            }
            self.send_due();
        }

        pub fn state(self: *const Self) State {
            return switch (self.phase) {
                .unsupported => .unsupported,
                .disconnected => .disconnected,
                .idle => .idle,
                .joining => .joining,
                .lobby => .lobby,
                .racing => if (self.stall_since) |s|
                    (if (self.now -% s >= timing.waiting_after) .waiting else .racing)
                else
                    .racing,
                .desync => .desync,
                .dropped => .dropped,
            };
        }

        /// A race runs: pump in a loop to ~14 ms into the frame.
        pub fn busy(self: *const Self) bool {
            return self.phase == .racing;
        }

        /// Pump in a loop after drawing: a race runs, or the badge is
        /// joining a room.
        pub fn wants_pump(self: *const Self) bool {
            return self.busy() or self.phase == .joining;
        }

        /// This badge's player id (0 before WELCOME).
        pub fn local_slot(self: *const Self) u4 {
            return @intCast(self.client.you & 15);
        }

        /// The room's players (bit per id), this badge included.
        pub fn present(self: *const Self) u16 {
            return self.client.present;
        }

        /// The lowest present id, which hosts the lobby.
        pub fn host_slot(self: *const Self) ?u4 {
            return lowest(self.client.present);
        }

        pub fn is_host(self: *const Self) bool {
            return self.phase == .lobby and self.host_slot() == self.local_slot();
        }

        /// A player's roster name ("" when absent).
        pub fn name(self: *const Self, slot: u4) []const u8 {
            return self.client.name(slot);
        }

        /// Participants of the race played by their human at the next tick.
        pub fn humans_mask(self: *const Self) u16 {
            return self.humans;
        }

        /// Participants handed to the AI so far.
        pub fn bots_mask(self: *const Self) u16 {
            return self.race.mask & ~self.humans;
        }

        /// In the lobby while other players of this room race: "MATCH IN
        /// PROGRESS, n/16"; the next GO includes this badge.
        pub fn match_running(self: *const Self) bool {
            return self.phase == .lobby and self.match_mask & self.client.present & ~bit(self.local_slot()) != 0;
        }

        // ---- lobby -------------------------------------------------------

        /// Host: the rules to offer (ignored elsewhere).
        pub fn set_rules(self: *Self, r: Rules) void {
            if (std.mem.eql(u8, &r, &self.offer)) return;
            self.offer = r;
            if (self.is_host()) self.setup_due = true;
        }

        /// Host: the race's input delay in ticks (clamped to 1..delay_cap).
        pub fn set_delay(self: *Self, d: u32) void {
            self.delay_choice = @intCast(std.math.clamp(d, 1, delay_cap));
        }

        /// The delay GO will carry (this badge's choice when it hosts).
        pub fn delay_offer(self: *const Self) u32 {
            return self.delay_choice;
        }

        /// In a race (until `leave`) the agreed rules; in the lobby the
        /// host's offer, or the host's SETUP (null until heard).
        pub fn rules(self: *const Self) ?Rules {
            switch (self.phase) {
                .racing, .desync, .dropped => return self.race.rules,
                else => {},
            }
            if (self.host_slot() == self.local_slot()) return self.offer;
            if (self.heard_from != null and self.heard_from == self.host_slot()) return self.heard;
            return null;
        }

        /// This badge's pick (low `pick_bits` bits) and ready flag.
        pub fn set_pick(self: *Self, pick: u8, ready: bool) void {
            const p = pick & pick_mask;
            if (p == self.pick and ready == self.ready) return;
            self.pick = p;
            self.ready = ready;
            self.pick_due = true;
        }

        /// A player's pick (null until heard since it joined).
        pub fn peer_pick_of(self: *const Self, slot: u4) ?u8 {
            if (slot == self.local_slot()) return self.pick;
            if (self.peer_heard & bit(slot) == 0) return null;
            return self.peer_pick[slot] & pick_mask;
        }

        /// The players ready in this lobby (this badge included), on this
        /// version.
        pub fn ready_mask(self: *const Self) u16 {
            var m: u16 = 0;
            const ok = self.client.present & self.peer_heard & ~self.peer_other_version;
            for (0..max_slots) |s| {
                if (ok & bit(s) != 0 and self.peer_pick[s] & 0x80 != 0) m |= bit(s);
            }
            m &= ~bit(self.local_slot());
            if (self.ready) m |= bit(self.local_slot());
            return m;
        }

        /// Players in this room on another `G.version` (never raced with).
        pub fn other_version_mask(self: *const Self) u16 {
            return self.peer_other_version & self.client.present;
        }

        /// Host: GO may start a race of the ready players (at least
        /// `min_players`, `G.picks_ok`).
        pub fn can_go(self: *const Self) bool {
            if (!self.is_host() or !self.ready) return false;
            const mask = self.ready_mask();
            if (@popCount(mask) < min_players) return false;
            const ps = self.picks_of(mask);
            return if (@hasDecl(G, "picks_ok")) G.picks_ok(&ps, mask) else true;
        }

        fn picks_of(self: *const Self, mask: u16) [max_slots]u8 {
            var p: [max_slots]u8 = @splat(0);
            for (0..max_slots) |s| {
                if (mask & bit(s) == 0) continue;
                p[s] = if (s == self.local_slot()) self.pick else self.peer_pick[s] & pick_mask;
            }
            return p;
        }

        /// Host: start a race of the ready players. False unless `can_go`.
        pub fn go(self: *Self, now: u64) bool {
            if (!self.can_go()) return false;
            var id = self.race_id +% 1;
            if (id == 0) id = 1;
            const mask = self.ready_mask();
            var x: u32 = self.entropy ^ @as(u32, @truncate(now)) ^ (@as(u32, id) *% 0x9E37_79B9);
            x ^= x >> 16;
            x *%= 0x85EB_CA6B;
            x ^= x >> 13;
            x *%= 0xC2B2_AE35;
            x ^= x >> 16;
            self.entropy = x;
            const r: Race = .{
                .id = id,
                .delay = self.delay_choice,
                .seed = if (x == 0) 1 else x,
                .mask = mask,
                .rules = self.offer,
                .picks = self.picks_of(mask),
            };
            self.on_go_race(r);
            self.go_due = true;
            self.send_due();
            return true;
        }

        /// True once per race start: reset the World from `rules()`,
        /// `picks()`, `participants()` and `seed()` before the first `step`.
        pub fn take_started(self: *Self) bool {
            const s = self.started;
            self.started = false;
            return s;
        }

        pub fn picks(self: *const Self) [max_slots]u8 {
            return self.race.picks;
        }
        pub fn seed(self: *const Self) u32 {
            return self.race.seed;
        }
        pub fn participants(self: *const Self) u16 {
            return self.race.mask;
        }

        /// The worst round trip this badge measured to the relay (us; 0:
        /// none yet).
        pub fn rtt_us(self: *const Self) u32 {
            var m: u32 = 0;
            for (self.rtt_samples) |s| m = @max(m, s);
            return m;
        }

        /// An input delay for the room from everyone's round trips to the
        /// relay: a byte from badge a reaches badge b in about (rtt_a +
        /// rtt_b) / 2, so ceil(worst pair / 16.7 ms) + 1 ticks. The default
        /// delay until anyone has measured.
        pub fn suggested_delay(self: *const Self) u32 {
            var m1: u32 = 0;
            var m2: u32 = 0;
            const mine = self.rtt_us();
            for (0..max_slots) |s| {
                const v: u32 = if (s == self.local_slot()) mine else if (self.client.present & self.peer_heard & bit(s) != 0) @as(u32, self.peer_rtt[s]) * 2000 else continue;
                if (v > m1) {
                    m2 = m1;
                    m1 = v;
                } else if (v > m2) m2 = v;
            }
            if (m1 == 0) return default_delay;
            const one_way = (m1 + m2) / 2;
            return std.math.clamp((one_way + 16_666) / 16_667 + 1, 1, delay_cap);
        }

        /// Leave the race (pause QUIT, results done, after desync or
        /// dropped): back to the lobby; the others hear QUIT (they hand the
        /// slot to the AI from the tick after the last input they have).
        /// Clears this badge's ready flag.
        pub fn leave(self: *Self, now: u64) void {
            _ = now;
            switch (self.phase) {
                .racing, .desync, .dropped => {},
                else => return,
            }
            if (self.phase != .dropped) {
                self.quit_due = true;
                self.quit_id = self.race.id;
            }
            self.match_mask &= ~bit(self.local_slot());
            self.phase = .lobby;
            self.end_race();
            self.ready = false;
            self.pick_due = true;
            self.send_due();
        }

        /// Leave the room altogether (LEAVE); `enter` joins again.
        pub fn exit(self: *Self, now: u64) void {
            self.leave(now);
            self.client.leave();
            self.phase = .idle;
        }

        pub fn enter(self: *Self) void {
            self.client.join();
        }

        // ---- racing ------------------------------------------------------

        /// This frame's input byte (all 8 bits are the game's): the input
        /// for tick `local_hi`, at most delay + 1 past the next tick to
        /// step (while `step` is stalled further bytes are dropped). Goes
        /// out at once (or every `send_every` ticks).
        pub fn submit(self: *Self, now: u64, byte: u8) void {
            self.now = now;
            if (self.phase != .racing) return;
            if (self.local_hi < self.tick + self.delay + 1) {
                self.local[self.local_hi % ring_len] = byte;
                self.local_hi += 1;
            }
            self.send_due();
        }

        /// Run the next tick if every present player's byte for it is in:
        /// leavers whose last tick has passed go to the AI first
        /// (`G.hand_over`), pause edges toggle `paused`, then (unless
        /// paused) `G.simulate(w, &inputs, humans)`. Ticks need no wall
        /// clock: a slow `simulate` only slows everyone down.
        pub fn step(self: *Self, w: *World) bool {
            if (self.phase != .racing) return false;
            const t = self.tick;
            const me = self.local_slot();
            var ready_to_run = t < self.local_hi;
            var leaving: u16 = 0;
            if (ready_to_run) {
                var m = self.drop_pending;
                while (lowest(m)) |s| : (m &= m - 1) {
                    if (self.drop_floor[s] <= t) ready_to_run = false;
                }
                m = self.humans & ~bit(me);
                while (lowest(m)) |s| : (m &= m - 1) {
                    if (self.cut_set & bit(s) != 0 and self.cut[s] <= t) {
                        leaving |= bit(s);
                    } else if (self.hi[s] <= t) ready_to_run = false;
                }
            }
            if (!ready_to_run) {
                if (self.stall_since == null) self.stall_since = self.now;
                self.stats.stalls +%= 1;
                return false;
            }
            self.stall_since = null;
            var m = leaving;
            while (lowest(m)) |s| : (m &= m - 1) {
                G.hand_over(w, s);
                self.humans &= ~bit(s);
                self.peer[s] = .{};
            }
            var in: [max_slots]u8 = @splat(0);
            const i = t % ring_len;
            in[me] = self.local[i];
            m = self.humans & ~bit(me);
            while (lowest(m)) |s| : (m &= m - 1) in[s] = self.remote[s][i];
            if (pause_bit) |pb| {
                var now_p: u16 = 0;
                m = self.humans;
                while (lowest(m)) |s| : (m &= m - 1) {
                    if (in[s] & pb != 0) now_p |= bit(s);
                }
                const edge = now_p & ~self.prev_pause != 0;
                self.prev_pause = now_p;
                const pausable = if (@hasDecl(G, "can_pause")) G.can_pause(w) else true;
                if (!pausable) self.paused = false else if (edge) self.paused = !self.paused;
            }
            if (!self.paused) G.simulate(w, &in, self.humans);
            self.tick = t + 1;
            if (self.tick % check_every == 0) self.take_hash(w);
            return true;
        }

        fn take_hash(self: *Self, w: *const World) void {
            const e = self.tick / check_every;
            const h = G.hash(w);
            self.own[e % own_slots] = .{ .epoch = e, .hash = h };
            var m = self.humans & ~bit(self.local_slot());
            while (lowest(m)) |s| : (m &= m - 1) {
                if (self.peer[s].epoch == e) self.compare(s);
            }
        }

        fn own_hash(self: *const Self, e: u32) ?u32 {
            const c = self.own[e % own_slots];
            return if (c.epoch == e and e != 0) c.hash else null;
        }

        fn compare(self: *Self, s: u4) void {
            const p = self.peer[s];
            const mine = self.own_hash(p.epoch) orelse return;
            self.peer[s] = .{};
            if (mine == p.hash) {
                self.stats.checks_ok +%= 1;
                return;
            }
            self.found_desync();
        }

        fn found_desync(self: *Self) void {
            if (self.phase != .racing) return;
            self.phase = .desync;
            self.desync_tick = self.tick;
            self.stall_since = null;
        }

        // ---- following the client -------------------------------------------

        fn follow_client(self: *Self) void {
            switch (self.client.state()) {
                .unsupported => self.phase = .unsupported,
                .disconnected => if (self.phase != .disconnected) {
                    self.end_race();
                    self.phase = .disconnected;
                },
                .idle => self.phase = .idle,
                .joining => if (self.phase != .joining) {
                    self.end_race();
                    self.phase = .joining;
                },
                .joined => {},
            }
        }

        fn end_race(self: *Self) void {
            self.paused = false;
            self.stall_since = null;
            self.started = false;
            self.drop_pending = 0;
            self.drop_due = 0;
            self.ack_due = 0;
        }

        /// WELCOME: a new room. Everything known about the last one goes.
        fn new_room(self: *Self) void {
            self.end_race();
            self.phase = .lobby;
            self.roster = bit(self.local_slot());
            self.heard_from = null;
            self.peer_heard = 0;
            self.peer_other_version = 0;
            self.race_id = 0;
            self.match_mask = 0;
            self.ready = false;
            self.quit_due = false;
            self.go_due = false;
            self.pick_due = true;
            self.setup_due = true;
            self.humans = 0;
        }

        fn on_event(self: *Self, ev: party.Event) void {
            switch (ev) {
                .joined => self.new_room(),
                .roster => self.on_roster(self.client.present),
                .data => |d| self.on_data(d.from, d.bytes),
                .pong => |token| {
                    self.rtt_samples[self.rtt_i % 4] = @as(u32, @truncate(self.now)) -% token;
                    self.rtt_i +%= 1;
                    const q: u8 = @intCast(@min(self.rtt_us() / 2000, 255));
                    if (q != self.peer_rtt[self.local_slot()]) {
                        self.peer_rtt[self.local_slot()] = q;
                        self.pick_due = true;
                    }
                },
                .err, .lost => {},
            }
        }

        fn on_roster(self: *Self, now_present: u16) void {
            const old = self.roster;
            const old_host = lowest(old);
            self.roster = now_present;
            const gone = old & ~now_present;
            const came = now_present & ~old;
            var m = gone;
            while (lowest(m)) |s| : (m &= m - 1) {
                self.peer_heard &= ~bit(s);
                self.peer_other_version &= ~bit(s);
                self.match_mask &= ~bit(s);
                self.leaver(s);
            }
            if (came != 0) self.pick_due = true;
            const host = lowest(now_present);
            if (host == self.local_slot() and (came != 0 or old_host != host)) self.setup_due = true;
            m = came;
            while (lowest(m)) |s| : (m &= m - 1) {
                self.peer_heard &= ~bit(s);
                self.peer_other_version &= ~bit(s);
            }
            if (self.phase == .racing) self.check_pending();
        }

        /// A participant's inputs end here (QUIT, ROSTER): human until the
        /// inputs this badge has, the same on every badge. A drop this
        /// badge proposed is left to its ACK.
        fn leaver(self: *Self, s: u4) void {
            if (self.phase != .racing) return;
            if (s == self.local_slot() or self.humans & bit(s) == 0) return;
            if (self.cut_set & bit(s) != 0 or self.drop_pending & bit(s) != 0) return;
            self.set_cut(s, self.hi[s]);
        }

        fn set_cut(self: *Self, s: u4, c: u32) void {
            self.cut[s] = c;
            self.cut_set |= bit(s);
            if (c < self.tick) self.bad();
        }

        fn bad(self: *Self) void {
            self.stats.bad +%= 1;
            self.found_desync();
        }

        fn on_data(self: *Self, from: u8, p: []const u8) void {
            if (from >= max_slots or p.len == 0) return;
            const s: u4 = @intCast(from);
            if (s == self.local_slot()) return; // a self-echo: our own frame
            self.heard_at[s] = @truncate(self.now);
            const k = p[0];
            // Inputs and hashes come only from a race: a badge that joined
            // during one learns it is running from them (it missed GO).
            if (k < 0x80 or k == K.hash) {
                if (self.phase != .racing or self.race.mask & bit(s) == 0) self.match_mask |= bit(s);
            }
            if (k < 0x80) return self.on_input(s, p);
            self.stats.control_recv +%= 1;
            switch (k) {
                K.setup => {
                    if (p.len < 1 + rules_len) return;
                    if (lowest(self.client.present) != s) return;
                    @memcpy(&self.heard, p[1..][0..rules_len]);
                    self.heard_from = s;
                },
                K.pick => {
                    if (p.len < 4) return;
                    self.peer_pick[s] = p[1];
                    self.peer_heard |= bit(s);
                    self.match_mask &= ~bit(s); // in the lobby
                    if (p[2] != version) self.peer_other_version |= bit(s) else self.peer_other_version &= ~bit(s);
                    self.peer_rtt[s] = p[3];
                },
                K.go => self.on_go(p),
                K.quit => {
                    if (p.len < 2) return;
                    if (p[1] == self.race_id) self.match_mask &= ~bit(s);
                    if (self.phase == .racing and p[1] == self.race.id) self.leaver(s);
                },
                K.drop => {
                    if (p.len < 7) return;
                    const slot = p[2];
                    if (slot >= max_slots) return;
                    if (p[1] == self.race_id) self.match_mask &= ~bit(slot);
                    if (self.phase != .racing or p[1] != self.race.id) return;
                    const d: u4 = @intCast(slot);
                    if (d == self.local_slot()) {
                        self.phase = .dropped;
                        self.stall_since = null;
                        return;
                    }
                    if (self.race.mask & bit(d) == 0) return;
                    // A proposer of the same drop waits for an ACK: it
                    // cannot tell whose DROP the relay ordered first.
                    if (self.drop_pending & bit(d) != 0) return;
                    if (self.cut_set & bit(d) == 0) self.set_cut(d, self.hi[d]);
                    self.ack_due |= bit(d);
                },
                K.ack => {
                    if (p.len < 7) return;
                    const slot = p[2];
                    if (slot >= max_slots or self.phase != .racing or p[1] != self.race.id) return;
                    const d: u4 = @intCast(slot);
                    if (self.drop_pending & bit(d) == 0) return;
                    self.drop_pending &= ~bit(d);
                    self.set_cut(d, std.mem.readInt(u32, p[3..7], .little));
                },
                K.hash => {
                    if (p.len < 7 or self.phase != .racing) return;
                    if (self.humans & bit(s) == 0 or (self.cut_set | self.drop_pending) & bit(s) != 0) return;
                    const e16 = std.mem.readInt(u16, p[1..3], .little);
                    const base = self.tick / check_every;
                    const diff: i16 = @bitCast(e16 -% @as(u16, @truncate(base)));
                    const e_signed = @as(i64, base) + diff;
                    if (e_signed <= 0) return;
                    self.peer[s] = .{ .epoch = @intCast(e_signed), .hash = std.mem.readInt(u32, p[3..7], .little) };
                    self.compare(s);
                },
                else => {},
            }
        }

        fn on_input(self: *Self, s: u4, p: []const u8) void {
            if (self.phase != .racing) return;
            if (self.humans & bit(s) == 0 or self.cut_set & bit(s) != 0) return;
            self.stats.input_frames_recv +%= 1;
            if (p.len < 2 or p[0] != @as(u8, @truncate(self.hi[s])) & 0x7F) return self.bad();
            for (p[1..]) |b| {
                if (self.hi[s] - self.tick >= ring_len) return self.bad();
                self.remote[s][self.hi[s] % ring_len] = b;
                self.hi[s] += 1;
            }
            self.stats.ticks_recv +%= @intCast(p.len - 1);
        }

        fn on_go(self: *Self, p: []const u8) void {
            const head = 10;
            if (p.len < head + rules_len) return;
            if (p[2] != version) return;
            var r: Race = .{
                .id = p[1],
                .delay = @intCast(std.math.clamp(p[3], 1, delay_cap)),
                .seed = std.mem.readInt(u32, p[4..8], .little),
                .mask = std.mem.readInt(u16, p[8..10], .little),
            };
            @memcpy(&r.rules, p[head..][0..rules_len]);
            var at: usize = head + rules_len;
            if (p.len < at + @popCount(r.mask)) return;
            for (0..max_slots) |s| {
                if (r.mask & bit(s) == 0) continue;
                r.picks[s] = p[at] & pick_mask;
                at += 1;
            }
            self.on_go_race(r);
        }

        /// A GO (heard, or this badge's own): every participant is racing
        /// now, so their ready flags go.
        fn on_go_race(self: *Self, r: Race) void {
            self.race_id = r.id;
            self.match_mask = r.mask;
            var m = r.mask;
            while (lowest(m)) |s| : (m &= m - 1) self.peer_pick[s] &= 0x7F;
            if (r.mask & bit(self.local_slot()) == 0) return;
            if (self.phase != .lobby) {
                // Named while not in the lobby: the others hand our slot
                // over at once.
                self.quit_due = true;
                self.quit_id = r.id;
                return;
            }
            self.ready = false;
            self.begin_race(r);
        }

        fn begin_race(self: *Self, r: Race) void {
            self.race = r;
            self.phase = .racing;
            self.delay = r.delay;
            self.tick = 0;
            self.local_hi = r.delay;
            self.sent_hi = r.delay;
            self.local = @splat(0);
            self.hi = @splat(r.delay);
            self.remote = @splat(@splat(0));
            self.heard_at = @splat(@truncate(self.now));
            self.humans = r.mask;
            self.cut_set = 0;
            self.end_race();
            self.prev_pause = 0;
            self.own = @splat(.{});
            self.peer = @splat(.{});
            self.hash_next = 1;
            self.started = true;
            // Named but already gone from the room: human for no tick.
            var m = r.mask & ~self.client.present;
            while (lowest(m)) |s| : (m &= m - 1) self.set_cut(s, r.delay);
        }

        /// Stall-drop: a participant whose input this badge lacks, silent
        /// for `stall_drop_us`, is suspect; the lowest participant that is
        /// not suspect proposes the drop.
        fn watch_stalls(self: *Self) void {
            const me = self.local_slot();
            const now32: u32 = @truncate(self.now);
            var suspect: u16 = 0;
            var m = self.humans & ~self.cut_set & ~bit(me);
            while (lowest(m)) |s| : (m &= m - 1) {
                if (self.hi[s] <= self.tick and now32 -% self.heard_at[s] >= stall_drop_us) suspect |= bit(s);
            }
            const live = self.humans & ~self.cut_set & ~suspect;
            if (suspect != 0 and lowest(live) == me) {
                m = suspect & ~self.drop_pending;
                while (lowest(m)) |s| : (m &= m - 1) {
                    self.drop_pending |= bit(s);
                    self.drop_floor[s] = self.hi[s];
                    self.drop_due |= bit(s);
                    self.drop_since = now32;
                    self.stats.drops_proposed +%= 1;
                }
            }
            self.check_pending_with(suspect);
            if (self.drop_pending != 0 and now32 -% self.drop_since >= timing.drop_give_up * stall_drop_us) {
                // Nobody left to say where the relay put the DROP.
                self.found_desync();
            }
        }

        fn check_pending(self: *Self) void {
            self.check_pending_with(0);
        }

        /// A proposed drop with no other live participant left to ACK it
        /// is this badge's alone to decide.
        fn check_pending_with(self: *Self, suspect: u16) void {
            var m = self.drop_pending;
            while (lowest(m)) |s| : (m &= m - 1) {
                const ackers = self.humans & ~self.cut_set & ~suspect & ~bit(s) & ~bit(self.local_slot()) & self.client.present & ~self.drop_pending;
                if (ackers != 0) continue;
                self.drop_pending &= ~bit(s);
                self.set_cut(s, self.hi[s]);
            }
        }

        // ---- sending -----------------------------------------------------

        fn control(self: *Self, msg: []const u8) bool {
            if (!self.client.broadcast(msg)) {
                self.stats.tx_waits +%= 1;
                return false;
            }
            self.stats.control_sent +%= 1;
            return true;
        }

        fn send_due(self: *Self) void {
            if (self.client.state() != .joined) return;
            if (self.go_due) {
                var b: [10 + rules_len + max_slots]u8 = undefined;
                const r = &self.race;
                b[0] = K.go;
                b[1] = r.id;
                b[2] = version;
                b[3] = r.delay;
                std.mem.writeInt(u32, b[4..8], r.seed, .little);
                std.mem.writeInt(u16, b[8..10], r.mask, .little);
                @memcpy(b[10..][0..rules_len], &r.rules);
                var at: usize = 10 + rules_len;
                for (0..max_slots) |s| {
                    if (r.mask & bit(s) == 0) continue;
                    b[at] = r.picks[s];
                    at += 1;
                }
                if (!self.control(b[0..at])) return;
                self.go_due = false;
            }
            // After a GO of ours, so a race we left at once follows it.
            if (self.quit_due) {
                if (!self.control(&.{ K.quit, self.quit_id })) return;
                self.quit_due = false;
            }
            switch (self.phase) {
                .racing => self.send_race(),
                .lobby => {
                    if (self.setup_due and lowest(self.client.present) == self.local_slot()) {
                        var b: [1 + rules_len]u8 = undefined;
                        b[0] = K.setup;
                        @memcpy(b[1..], &self.offer);
                        if (!self.control(&b)) return;
                    }
                    self.setup_due = false;
                    if (self.pick_due) {
                        const pb = self.pick | (@as(u8, @intFromBool(self.ready)) << 7);
                        if (!self.control(&.{ K.pick, pb, version, self.peer_rtt[self.local_slot()] })) return;
                        self.pick_due = false;
                    }
                },
                else => {},
            }
        }

        fn send_race(self: *Self) void {
            const full = self.local_hi >= self.tick + self.delay + 1;
            while (self.sent_hi < self.local_hi) {
                var n = self.local_hi - self.sent_hi;
                if (n < send_every and !full and self.stall_since == null) break;
                n = @min(n, max_batch);
                var b: [1 + max_batch]u8 = undefined;
                b[0] = @as(u8, @truncate(self.sent_hi)) & 0x7F;
                for (0..n) |k| b[1 + k] = self.local[(self.sent_hi + @as(u32, @intCast(k))) % ring_len];
                if (!self.client.broadcast(b[0 .. 1 + n])) {
                    self.stats.tx_waits +%= 1;
                    return;
                }
                self.sent_hi += n;
                self.stats.input_frames_sent +%= 1;
            }
            // A hash after the inputs that led to it, so a leaver's last
            // hash is never past its last input.
            while (self.own_hash(self.hash_next)) |h| {
                if (self.sent_hi < self.hash_next * check_every) break;
                var b: [7]u8 = undefined;
                b[0] = K.hash;
                std.mem.writeInt(u16, b[1..3], @truncate(self.hash_next), .little);
                std.mem.writeInt(u32, b[3..7], h, .little);
                if (!self.control(&b)) return;
                self.hash_next += 1;
            }
            if (self.hash_next * check_every <= self.tick and self.own_hash(self.hash_next) == null) {
                // Overwritten while the ring was full: skip it.
                self.hash_next = self.tick / check_every + 1;
            }
            var m = self.drop_due;
            while (lowest(m)) |s| : (m &= m - 1) {
                var b: [7]u8 = .{ K.drop, self.race.id, s, 0, 0, 0, 0 };
                std.mem.writeInt(u32, b[3..7], self.drop_floor[s], .little);
                if (!self.control(&b)) return;
                self.drop_due &= ~bit(s);
            }
            m = self.ack_due;
            while (lowest(m)) |s| : (m &= m - 1) {
                var b: [7]u8 = .{ K.ack, self.race.id, s, 0, 0, 0, 0 };
                std.mem.writeInt(u32, b[3..7], self.cut[s], .little);
                if (!self.control(&b)) return;
                self.ack_due &= ~bit(s);
                self.stats.acks_sent +%= 1;
            }
        }
    };
}

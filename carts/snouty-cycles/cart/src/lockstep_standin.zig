//! STAND-IN for the shared `lib/lockstep.zig` (not landed when Track L was
//! built). Same API as the lead's contract: `Lockstep(L, G)` with pump /
//! state / submit / step / leave / take_started / role, a SETUP/PICK/GO
//! lobby carrying `[G.rules_len]u8` rules and a u8 pick, and 5-byte input
//! packets that are always 8 wire bytes. It is Snouty GC's tested
//! `net.zig` (branch gc/present) made generic over the game; delete this
//! file and point `net.zig` at `lib/lockstep.zig` once that lands.
//!
//! `G` supplies:
//!   World                         the lockstep state `step` advances
//!   simulate(w: *World, in: [2]u8) one agreed tick (slot 0 host, 1 guest)
//!   hash(w: *const World) u32     every `check_every` ticks
//!   hand_over(w: *World, slot: u1) the partner left: its slot goes to the AI
//!   rules_len, app_id, input_delay, pause_bit: ?u8
//!
//! Generic over the link (`link.Badge` on the badge, a link over
//! lib/link_virtual.zig in host tests), owned by value. No cart API, no
//! clock (the caller passes `now` in microseconds), no floats.
const std = @import("std");

/// A World hash is taken every this many ticks.
pub const check_every: u32 = 32;
const ring_len = 16;
const check_slots = 4;

pub const timing = struct {
    pub const min_gap: u64 = 12_000;
    pub const resend: u64 = 20_000;
    pub const lobby_every: u64 = 50_000;
    pub const ctrl_gap: u64 = 20_000;
    pub const go_every: u64 = 100_000;
    pub const waiting_after: u64 = 500_000;
    pub const peer_stalled: u64 = 25_000;
};

pub const State = enum(u8) { offline, searching, wrong_cart, lobby, racing, waiting, peer_left, desync };
pub const Left = enum(u8) { none, unplugged, restarted, quit };
pub const Role = enum(u8) { none, host, guest };

/// A badge's pick: a value and a ready flag (on the wire: value bits 0-6,
/// ready bit 7).
pub const Pick = struct {
    value: u8 = 0,
    ready: bool = false,
    fn encode(p: Pick) u8 {
        return (p.value & 0x7F) | (@as(u8, @intFromBool(p.ready)) << 7);
    }
    fn decode(b: u8) Pick {
        return .{ .value = b & 0x7F, .ready = b & 0x80 != 0 };
    }
};

const Msg = enum(u8) {
    /// host: kind | page (0xB0 + page), race id, rules[2 page], rules[2 page + 1]
    setup = 0xB0,
    /// both: kind, race id, pick
    pick = 0xA2,
    /// host: kind, new race id, digest (crc8 of the rules)
    go = 0xA3,
    quit = 0xA4,
    desync = 0xA5,
    _,
};
pub const input_len = 5;
const data_kind: u8 = 0x10;

pub fn crc8(bytes: []const u8) u8 {
    var c: u8 = 0;
    for (bytes) |byte| {
        c ^= byte;
        for (0..8) |_| c = if (c & 0x80 != 0) (c << 1) ^ 0x07 else c << 1;
    }
    return c;
}

fn slip_special(b: u8) bool {
    return b == 0xC0 or b == 0xDB;
}

/// Byte 0 is n mod 64 plus two salt bits, chosen so the link's CRC is not
/// a SLIP special byte; input bytes are below 0xC0 and the check piece is
/// 7 bits, so the packet is always 5 + 3 = 8 wire bytes.
pub fn encode_input(n: u32, ins: [3]u8, check: u8) [input_len]u8 {
    var p = [input_len]u8{ @as(u8, @truncate(n)) & 0x3F, ins[0], ins[1], ins[2], check & 0x7F };
    for ([_]u8{ 0x00, 0x40, 0x80 }) |salt| {
        p[0] = (p[0] & 0x3F) | salt;
        var buf: [1 + input_len]u8 = undefined;
        buf[0] = data_kind;
        @memcpy(buf[1..], &p);
        if (!slip_special(crc8(&buf))) break;
    }
    return p;
}

fn piece(h: u32, i: u32) u8 {
    return @truncate((h >> @intCast(7 * i)) & 0x7F);
}

pub const Stats = struct {
    inputs_sent: u32 = 0,
    inputs_recv: u32 = 0,
    inputs_stale: u32 = 0,
    old_windows: u32 = 0,
    control_sent: u32 = 0,
    control_recv: u32 = 0,
    checks_ok: u32 = 0,
    go_resends: u32 = 0,
    stalls: u32 = 0,
    /// Frames this badge sat out to let a partner behind it catch up.
    skips: u32 = 0,
    pumps: u32 = 0,
};

/// Time sync: a badge more than `sync_lead` ticks ahead of its partner's
/// estimated tick sits out one frame in `sync_every` steps.
pub const sync_lead: u32 = 1;
pub const sync_every: u32 = 6;

const Phase = enum(u8) { offline, searching, wrong_cart, lobby, racing, peer_left, desync };
const Check = struct { epoch: u32 = 0, hash: u32 = 0 };

pub fn Lockstep(comptime L: type, comptime G: type) type {
    const N = G.rules_len;
    const pages = (N + 1) / 2;
    const delay: u32 = G.input_delay;
    const lead_max: u32 = delay + 1;
    const check_lag: u32 = 2 * delay + 4;
    return struct {
        const Self = @This();
        pub const Rules = [N]u8;

        link: L,
        phase: Phase,
        role: Role = .none,
        left: Left = .none,
        session: u32 = 0,
        now: u64 = 0,

        offer: Rules = @splat(0),
        heard: Rules = @splat(0),
        heard_pages: u8 = 0,
        pick: Pick = .{},
        peer_pick: ?Pick = null,
        race_id: u8 = 0,
        /// The agreed race (from `take_started`): rules and seed.
        race_rules: Rules = @splat(0),
        seed: u32 = 1,
        started: bool = false,
        turn: u8 = 0,
        quit_next: bool = false,
        ctrl_wait: u64 = timing.ctrl_gap,
        last_tx: u64 = 0,

        tick: u32 = 0,
        local_hi: u32 = delay,
        remote_hi: u32 = delay,
        peer_need: u32 = delay,
        peer_top: u32 = 0,
        peer_top_at: u64 = 0,
        local: [ring_len]u8 = @splat(0),
        remote: [ring_len]u8 = @splat(0),
        prev: [2]u8 = .{ 0, 0 },
        /// Paused by a pause-bit edge in either human's byte (agreed).
        paused: bool = false,
        peer_started: bool = false,
        handed_over: bool = false,
        dirty: bool = false,
        alt: bool = false,
        stall_since: ?u64 = null,
        checks: [check_slots]Check = @splat(.{}),
        desync_tick: u32 = 0,
        /// This frame was sat out (time sync): the caller must not retry.
        skipped: bool = false,
        steps_since_skip: u32 = 0,
        stats: Stats = .{},

        pub fn init(l: L) Self {
            return .{ .link = l, .phase = if (l.state == .unavailable) .offline else .searching };
        }

        pub fn pump(self: *Self, now: u64) void {
            self.now = now;
            self.stats.pumps +%= 1;
            if (self.phase == .offline) return;
            self.link.poll(now);
            self.follow_link(now);
            while (self.link.recv()) |p| self.handle(p.slice());
            self.send_due(now);
        }

        pub fn state(self: *const Self) State {
            return switch (self.phase) {
                .offline => .offline,
                .searching => .searching,
                .wrong_cart => .wrong_cart,
                .lobby => .lobby,
                .racing => if (self.stall_since) |s|
                    (if (self.now -% s >= timing.waiting_after) .waiting else .racing)
                else
                    .racing,
                .peer_left => .peer_left,
                .desync => .desync,
            };
        }

        /// Racing with the partner: pump in a loop until late in the frame.
        pub fn busy(self: *const Self) bool {
            return self.phase == .racing;
        }

        pub fn local_slot(self: *const Self) u1 {
            return if (self.role == .guest) 1 else 0;
        }

        pub fn partner_app(self: *const Self) u8 {
            return self.link.partner_app;
        }

        // ---- lobby ----

        pub fn set_rules(self: *Self, r: Rules) void {
            if (self.role != .host or self.phase != .lobby) return;
            if (std.mem.eql(u8, &r, &self.offer)) return;
            self.offer = r;
            self.ctrl_wait = timing.ctrl_gap;
        }

        /// The host's own rules, or the guest's once every page is heard.
        pub fn rules(self: *const Self) ?Rules {
            if (self.role == .host) return self.offer;
            return if (self.heard_pages == (1 << pages) - 1) self.heard else null;
        }

        pub fn set_pick(self: *Self, value: u8, ready: bool) void {
            const p = Pick{ .value = value & 0x7F, .ready = ready };
            if (std.meta.eql(p, self.pick)) return;
            self.pick = p;
            self.ctrl_wait = timing.ctrl_gap;
        }

        pub fn can_go(self: *const Self) bool {
            if (self.phase != .lobby or self.role != .host or !self.pick.ready) return false;
            const pp = self.peer_pick orelse return false;
            return pp.ready;
        }

        pub fn go(self: *Self, now: u64) bool {
            if (!self.can_go()) return false;
            var id = self.race_id +% 1;
            if (id == 0) id = 1;
            self.race_id = id;
            self.race_rules = self.offer;
            self.seed = self.seed_of(id);
            self.begin_race(now);
            return true;
        }

        pub fn take_started(self: *Self) bool {
            const s = self.started;
            self.started = false;
            return s;
        }

        pub fn leave(self: *Self, now: u64) void {
            _ = now;
            switch (self.phase) {
                .racing, .peer_left, .desync => {},
                else => return,
            }
            self.pick.ready = false;
            self.peer_pick = null;
            self.paused = false;
            self.stall_since = null;
            self.left = .none;
            self.started = false;
            if (self.link.connected() and self.link.session == self.session) {
                self.phase = .lobby;
                self.quit_next = true;
                self.ctrl_wait = timing.ctrl_gap;
            } else {
                self.phase = .searching;
            }
        }

        // ---- racing ----

        pub fn submit(self: *Self, now: u64, byte: u8) void {
            switch (self.phase) {
                .racing, .peer_left => {},
                else => return,
            }
            if (self.local_hi < self.tick + lead_max) {
                self.local[self.local_hi % ring_len] = byte;
                self.local_hi += 1;
                self.dirty = true;
            }
            self.send_due(now);
        }

        pub fn step(self: *Self, w: *G.World) bool {
            const solo = self.phase == .peer_left;
            self.skipped = false;
            if (self.phase != .racing and !solo) return false;
            const t = self.tick;
            // Time sync. The faster badge's frames run it ahead of its
            // partner until it eats the whole input delay (the partner's
            // inputs then arrive just in time, and any late packet is a
            // stall); the host also starts first. The partner's newest tick
            // is its tick + delay while it runs, so a tick past that + 1
            // means we lead: sit out a frame now and then.
            if (!solo and self.peer_started and self.peer_top >= delay and t > self.peer_top - delay + sync_lead and
                self.steps_since_skip >= sync_every)
            {
                self.steps_since_skip = 0;
                self.skipped = true;
                self.stats.skips +%= 1;
                return false;
            }
            if (t >= self.local_hi or (!solo and t >= self.remote_hi)) {
                if (self.stall_since == null) self.stall_since = self.now;
                self.stats.stalls +%= 1;
                return false;
            }
            self.stall_since = null;
            self.steps_since_skip +|= 1;
            const me = self.local_slot();
            var in: [2]u8 = undefined;
            in[me] = self.local[t % ring_len];
            in[me ^ 1] = if (solo) 0 else self.remote[t % ring_len];
            if (solo and !self.handed_over) {
                self.handed_over = true;
                G.hand_over(w, me ^ 1);
            }
            if (G.pause_bit) |pb| {
                const edge = ((in[0] & ~self.prev[0]) | (in[1] & ~self.prev[1])) & pb != 0;
                if (edge) self.paused = !self.paused;
            }
            self.prev = in;
            if (!self.paused) G.simulate(w, in);
            self.tick = t + 1;
            if (self.tick % check_every == 0) {
                const e = self.tick / check_every;
                self.checks[e % check_slots] = .{ .epoch = e, .hash = G.hash(w) };
            }
            return true;
        }

        // ---- link state ----

        fn follow_link(self: *Self, now: u64) void {
            const up = self.link.connected();
            switch (self.phase) {
                .offline, .peer_left, .desync => {},
                .racing => {
                    if (!up) return self.peer_gone(.unplugged);
                    if (self.link.session != self.session) return self.peer_gone(.restarted);
                },
                .searching, .lobby, .wrong_cart => {
                    if (!up) {
                        self.phase = .searching;
                        return;
                    }
                    if (self.phase == .searching or self.link.session != self.session) self.new_session(now);
                },
            }
        }

        fn new_session(self: *Self, now: u64) void {
            self.session = self.link.session;
            self.race_id = 0;
            self.peer_pick = null;
            self.heard_pages = 0;
            self.quit_next = false;
            self.turn = 0;
            self.role = .none;
            if (self.link.partner_app != G.app_id) {
                self.phase = .wrong_cart;
                return;
            }
            const me = self.link.nonce;
            const them = self.link.partner_nonce;
            if (me == them) {
                self.link.restart(now);
                self.phase = .searching;
                return;
            }
            self.role = if (me > them) .host else .guest;
            self.phase = .lobby;
            self.ctrl_wait = timing.ctrl_gap;
        }

        fn peer_gone(self: *Self, why: Left) void {
            self.phase = .peer_left;
            self.left = why;
            self.stall_since = null;
        }

        fn seed_of(self: *const Self, id: u8) u32 {
            const a = self.link.nonce;
            const b = self.link.partner_nonce;
            var x: u32 = (@as(u32, @max(a, b)) << 16 | @min(a, b)) ^ (@as(u32, id) *% 0x9E37_79B9);
            x ^= x >> 16;
            x *%= 0x85EB_CA6B;
            x ^= x >> 13;
            x *%= 0xC2B2_AE35;
            x ^= x >> 16;
            return if (x == 0) 1 else x;
        }

        fn begin_race(self: *Self, now: u64) void {
            self.phase = .racing;
            self.left = .none;
            self.tick = 0;
            self.local_hi = delay;
            self.remote_hi = delay;
            self.peer_need = delay;
            self.peer_top = 0;
            self.peer_top_at = now;
            self.local = @splat(0);
            self.remote = @splat(0);
            self.prev = .{ 0, 0 };
            self.paused = false;
            self.peer_started = self.role == .guest;
            self.handed_over = false;
            self.dirty = false;
            self.stall_since = null;
            self.checks = @splat(.{});
            self.peer_pick = null;
            self.started = true;
            self.ctrl_wait = timing.ctrl_gap;
        }

        // ---- receiving ----

        fn handle(self: *Self, p: []const u8) void {
            if (p.len == input_len) return self.on_input(p);
            if (p.len < 2) return;
            self.stats.control_recv +%= 1;
            const id = p[1];
            const k = p[0];
            if (k & 0xF0 == @backingInt(Msg.setup)) {
                if (p.len < 4) return;
                self.on_lobby_msg(id);
                const page = k & 0x0F;
                if (self.phase == .lobby and self.role == .guest and page < pages) {
                    self.heard[2 * page] = p[2];
                    if (2 * page + 1 < N) self.heard[2 * page + 1] = p[3];
                    self.heard_pages |= @as(u8, 1) << @intCast(page);
                }
                return;
            }
            switch (@as(Msg, @fromBackingInt(k))) {
                .pick => {
                    if (p.len < 3) return;
                    self.on_lobby_msg(id);
                    if (self.phase == .lobby) self.peer_pick = Pick.decode(p[2]);
                },
                .go => {
                    if (p.len < 3) return;
                    self.on_go(id, p[2]);
                },
                .quit => self.on_lobby_msg(id),
                .desync => if (self.phase == .racing and id == self.race_id) self.found_desync(),
                else => {},
            }
        }

        fn on_lobby_msg(self: *Self, id: u8) void {
            if (self.phase == .racing and id == self.race_id) self.peer_gone(.quit);
        }

        fn on_go(self: *Self, id: u8, digest: u8) void {
            if (self.role != .guest or self.phase != .lobby or id == self.race_id or id == 0) return;
            const r = self.rules() orelse return;
            if (crc8(&r) != digest) return;
            self.race_id = id;
            self.race_rules = r;
            self.seed = self.seed_of(id);
            self.begin_race(self.now);
        }

        fn on_input(self: *Self, p: []const u8) void {
            if (self.phase != .racing) return;
            self.stats.inputs_recv +%= 1;
            const base = self.remote_hi;
            var d: i32 = @intCast((@as(u32, p[0] & 0x3F) -% base) & 0x3F);
            if (d >= 32) d -= 64;
            const n_signed = @as(i64, base) + d;
            if (n_signed < delay) return;
            const n: u32 = @intCast(n_signed);
            self.peer_started = true;
            if (n > self.peer_top) {
                self.peer_top = n;
                self.peer_top_at = self.now;
            }
            if (n - delay > self.peer_need) self.peer_need = n - delay;
            const before = self.remote_hi;
            var k: u32 = 0;
            while (k < 3) : (k += 1) {
                const t = n - 2 + k;
                if (t == self.remote_hi and self.remote_hi - self.tick < ring_len) {
                    self.remote[t % ring_len] = p[3 - k];
                    self.remote_hi += 1;
                }
            }
            if (self.remote_hi == before) self.stats.inputs_stale +%= 1;
            self.verify(n, p[4]);
        }

        fn check_of(self: *const Self, e: u32) ?u32 {
            const c = self.checks[e % check_slots];
            return if (c.epoch == e) c.hash else null;
        }

        fn check_byte(self: *const Self, n: u32) u8 {
            if (n < check_lag + check_every) return 0;
            const m = n - check_lag;
            const h = self.check_of(m / check_every) orelse return 0;
            return piece(h, m % 4);
        }

        fn verify(self: *Self, n: u32, c: u8) void {
            if (n < check_lag + check_every) return;
            const m = n - check_lag;
            const h = self.check_of(m / check_every) orelse return;
            if (piece(h, m % 4) == c & 0x7F) {
                self.stats.checks_ok +%= 1;
                return;
            }
            self.found_desync();
        }

        fn found_desync(self: *Self) void {
            self.phase = .desync;
            self.desync_tick = self.tick;
            self.stall_since = null;
            self.ctrl_wait = timing.ctrl_gap;
        }

        // ---- sending ----

        fn send_due(self: *Self, now: u64) void {
            const since = now -% self.last_tx;
            switch (self.phase) {
                .lobby => if (since >= self.ctrl_wait) self.send_lobby(now),
                .desync => if (since >= self.ctrl_wait) {
                    self.send_control(now, &.{ @backingInt(Msg.desync), self.race_id });
                    self.ctrl_wait = timing.lobby_every;
                },
                .racing => {
                    if (!self.peer_started) {
                        // Host: GO (with a SETUP page between, in case the
                        // guest missed one) until the guest's first input.
                        if (since >= self.ctrl_wait) {
                            if (self.turn % (pages + 1) == 0) {
                                self.stats.go_resends +%= 1;
                                self.send_control(now, &.{ @backingInt(Msg.go), self.race_id, crc8(&self.race_rules) });
                            } else {
                                self.send_page(now, self.turn % (pages + 1) - 1, &self.race_rules);
                            }
                            self.turn +%= 1;
                            self.ctrl_wait = timing.lobby_every;
                        }
                        return;
                    }
                    if ((self.dirty and since >= timing.min_gap) or since >= timing.resend) self.send_inputs(now);
                },
                else => {},
            }
        }

        fn send_control(self: *Self, now: u64, msg: []const u8) void {
            _ = self.link.send(now, msg);
            self.last_tx = now;
            self.stats.control_sent +%= 1;
        }

        fn send_page(self: *Self, now: u64, page: u8, r: *const Rules) void {
            const b1 = if (2 * page + 1 < N) r[2 * page + 1] else 0;
            self.send_control(now, &.{ @backingInt(Msg.setup) | page, self.race_id, r[2 * page], b1 });
        }

        fn send_lobby(self: *Self, now: u64) void {
            if (self.quit_next) {
                self.quit_next = false;
                self.send_control(now, &.{ @backingInt(Msg.quit), self.race_id });
            } else if (self.role == .host and self.turn % (pages + 1) != pages) {
                self.send_page(now, self.turn % (pages + 1), &self.offer);
            } else {
                self.send_control(now, &.{ @backingInt(Msg.pick), self.race_id, self.pick.encode() });
            }
            if (self.role == .host) self.turn +%= 1;
            self.ctrl_wait = timing.lobby_every;
        }

        fn send_inputs(self: *Self, now: u64) void {
            if (self.local_hi < 3) return;
            const newest = self.local_hi - 3;
            var b = newest;
            // The partner may lack ticks older than our newest window:
            // it is stalled (its newest tick still), or we are so far
            // ahead that our window starts 3 past the oldest tick it may
            // lack (`peer_need`, a lower bound). With an input delay of 3
            // our newest tick can be 8 past what it holds (the host starts
            // first and runs the 3 free ticks), more than a window, and a
            // gap left alone comes back every few frames. Then alternate a
            // window from `peer_need` with the newest.
            const behind = self.peer_need + 3 <= newest or now -% self.peer_top_at >= timing.peer_stalled;
            if (self.peer_need < newest and self.local_hi - self.peer_need < ring_len and behind) {
                self.alt = !self.alt;
                if (self.alt) {
                    b = self.peer_need;
                    self.stats.old_windows +%= 1;
                }
            }
            const n = b + 2;
            const p = encode_input(n, .{
                self.local[n % ring_len],
                self.local[(n - 1) % ring_len],
                self.local[(n - 2) % ring_len],
            }, self.check_byte(n));
            _ = self.link.send(now, &p);
            self.last_tx = now;
            self.dirty = false;
            self.stats.inputs_sent +%= 1;
        }
    };
}

//! TEST ONLY: carts/snouty-gc/cart/src/net.zig as of 90683be4 (tag
//! snouty-gc/m4-hw, verified on two badges), verbatim below this header.
//! net_compat_test.zig runs it against the lib/lockstep.zig wrapper to show
//! the wire is byte-identical. Never imported by the cart.
//!
//! Two-badge lockstep over lib/link.zig (SPEC 7, docs/NET.md). New for
//! Snouty GC (M4 Track A).
//!
//! Both badges run the same deterministic `World` (`sim.simulate` is pure
//! in `(World, inputs)`). They agree on a setup in a small lobby (the host
//! is the badge whose link HELLO nonce is higher; it sends SETUP and GO,
//! both send PICK), then exchange only their human's input byte, one per
//! tick, two ticks ahead (`input_delay`). `step` advances the World by one
//! tick only when it holds both humans' bytes for that tick, and nothing
//! but those bytes and the agreed setup reaches `simulate`.
//!
//! The input packet is 5 payload bytes, 8 on the wire, always: the PIO
//! receive FIFO holds 8 bytes, so one whole packet survives a badge that
//! polls only once a frame. It carries the newest of three consecutive
//! ticks (low 6 bits), the three input bytes and one 7-bit check piece; a
//! packet lost to the FIFO or the CRC is covered by the repeats, and a
//! badge that sees its partner stalled resends the ticks the partner needs
//! (the partner's newest tick bounds what it holds), so no retransmit
//! protocol is needed. The check pieces are 7-bit slices of a 32-bit hash
//! of the World, taken every `check_every` ticks: a mismatch is `desync`.
//!
//! Generic over the link (`Net(link.Badge)` on the badge, a link over
//! lib/link_virtual.zig in the host tests); the link is owned by value.
//! No cart API, no clock (main passes `now`), no floats.
const std = @import("std");
const world = @import("world.zig");
const sim = @import("sim.zig");

const World = world.World;

/// The HELLO `app` byte of Snouty GC (link.Badge.init(.., app_id, ..)).
pub const app_id: u8 = 'G';

/// Input delay in ticks (SPEC 7.2): the byte sampled on frame f drives
/// tick f + 2.
pub const input_delay: u32 = 2;
/// A World hash is taken every this many ticks.
pub const check_every: u32 = 32;
/// Packets whose newest tick n has n - check_lag in epoch e carry pieces
/// of epoch e's hash; the lag makes sure both badges have taken it
/// (a badge's newest tick is at most its partner's tick + 2 * delay + 1).
pub const check_lag: u32 = 2 * input_delay + 4;
/// Local inputs submitted past the next tick to step: delay + 1 (the
/// byte of this frame is for tick T + delay, after this frame's step).
const lead_max: u32 = input_delay + 1;
/// Input rings (local and remote). The local ring holds what the partner
/// may still need (at most 6 ticks back), the remote one what we have not
/// stepped yet (at most 6 ticks ahead).
const ring_len = 16;
const check_slots = 4;

/// Timing in microseconds, adjustable in one place.
pub const timing = struct {
    /// Racing: an input packet goes out when a new local input is
    /// submitted (once a frame) but never sooner than this after the last
    /// packet, and at least this often while nothing new is submitted (a
    /// stall: the partner may need a lost tick). One packet a frame keeps
    /// the partner's 8-byte receive FIFO from overflowing.
    pub const min_gap: u64 = 12_000;
    pub const resend: u64 = 20_000;
    /// Lobby: one control message this often (the host alternates SETUP
    /// and PICK); after a change or a state switch the next goes after
    /// `ctrl_gap` instead.
    pub const lobby_every: u64 = 50_000;
    pub const ctrl_gap: u64 = 20_000;
    /// Host: GO again this often until the guest's first input arrives.
    pub const go_every: u64 = 100_000;
    /// `state()` says `.waiting` once `step` has had no inputs this long
    /// (30 frames).
    pub const waiting_after: u64 = 500_000;
    /// The partner's newest tick has not moved for this long: it is
    /// stalled on a tick of ours it lacks (a running badge's newest moves
    /// every frame), so every other packet carries the oldest tick it may
    /// need instead of the newest three.
    pub const peer_stalled: u64 = 25_000;
};

pub const State = enum(u8) {
    /// No link hardware (the wasm simulator): LINK shows NO LINK.
    offline,
    /// The link is searching or handshaking (cable out, partner off).
    searching,
    /// Connected to a badge running another cart (`link.partner_app`).
    wrong_cart,
    /// Connected, in the lobby: rules (host), picks, GO.
    lobby,
    /// A race is running; `step` advances it.
    racing,
    /// Racing, but `step` has had no partner input for `waiting_after`.
    waiting,
    /// The partner went away (or left the race): `step` goes on solo with
    /// the AI driving its car. Until `leave`.
    peer_left,
    /// The World hashes differ: `step` stops. Until `leave`.
    desync,
};

/// Why the partner left the race (`peer_left`).
pub const Left = enum(u8) { none, unplugged, restarted, quit };

pub const Role = enum(u8) { none, host, guest };

/// No racer picked yet.
pub const no_racer: u8 = 0xFF;

/// What the host chooses (SPEC 7.3). `crews` is the AI count (4, 2 or 0);
/// on the wire: track bits 0-3, crews bits 4-6, mode bit 7 (gc).
pub const Rules = struct {
    mode: world.Mode = .race,
    track: u8 = 0,
    crews: u8 = 4,

    pub fn encode(r: Rules) u8 {
        const gc: u8 = @intFromBool(r.mode == .gc);
        return (r.track & 0x0F) | (@as(u8, @min(r.crews, 7)) << 4) | (gc << 7);
    }
    pub fn decode(b: u8) Rules {
        return .{ .track = b & 0x0F, .crews = (b >> 4) & 7, .mode = if (b & 0x80 != 0) .gc else .race };
    }
};

/// A badge's racer choice: on the wire racer bits 0-2 (7 = none), ready bit 7.
pub const Pick = struct {
    racer: u8 = no_racer,
    ready: bool = false,

    pub fn encode(p: Pick) u8 {
        const r: u8 = if (p.racer < world.car_count) p.racer else 7;
        return r | (@as(u8, @intFromBool(p.ready)) << 7);
    }
    pub fn decode(b: u8) Pick {
        const r = b & 7;
        return .{ .racer = if (r < world.car_count) r else no_racer, .ready = b & 0x80 != 0 };
    }
};

/// The agreed race (GO): id, rules, the two humans' racers in slot order
/// (0 = host, 1 = guest) and the seed both derive from the link nonces.
pub const Race = struct {
    id: u8 = 0,
    rules: Rules = .{},
    racers: [2]u8 = .{ no_racer, no_racer },
    seed: u32 = 1,
};

/// Control messages: DATA packets with this kind byte first, never 5
/// bytes long (a 5-byte packet is an input packet).
pub const Msg = enum(u8) {
    /// host: kind, race id, rules
    setup = 0xA1,
    /// both: kind, race id, pick
    pick = 0xA2,
    /// host: kind, new race id, rules, racers (host bits 0-2, guest 4-6)
    go = 0xA3,
    /// both: kind, race id (this badge left that race)
    quit = 0xA4,
    /// both: kind, race id (this badge found a desync in that race; the
    /// partner may not get the check piece that shows it, as this badge
    /// stops sending inputs)
    desync = 0xA5,
    _,
};
pub const input_len = 5;

/// lib/link.zig's DATA kind byte and CRC (net_test checks they match):
/// the input packet picks its salt bits so its CRC never needs escaping.
pub const data_kind: u8 = 0x10;
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

/// The input packet for the three ticks n-2, n-1, n: `ins` = inputs for
/// n, n-1, n-2; `check` a 7-bit piece. Byte 0 is n mod 64 plus two salt
/// bits, chosen so the link's CRC is not a SLIP special byte (the three
/// salts 0, 0x40, 0x80 give three different CRCs and only two are
/// special); no other byte can be special (inputs never have both Start
/// and Select, `sanitize`; check < 0x80), so the packet is always
/// 5 + 3 = 8 wire bytes.
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

/// Start+Select is the OS chord: the cart sees neither (input.zig does the
/// same), which also keeps 0xC0 and 0xDB out of input bytes.
pub fn sanitize(byte: u8) u8 {
    return if (byte & 0xC0 == 0xC0) byte & 0x3F else byte;
}

const start_bit: u8 = 0x40;

/// 32-bit hash of every World field by reflection (padding is never read,
/// so equal Worlds hash equal on both badges). About 700 fields: a few
/// tens of microseconds on the badge, once every `check_every` ticks.
pub fn world_hash(w: *const World) u32 {
    var h: u32 = 0x811C_9DC5;
    mix(World, w, &h);
    h ^= h >> 16;
    h *%= 0x85EB_CA6B;
    h ^= h >> 13;
    h *%= 0xC2B2_AE35;
    h ^= h >> 16;
    return h;
}

fn feed(h: *u32, x: u32) void {
    h.* = std.math.rotl(u32, h.* ^ x, 5) *% 0x9E37_79B1;
}

fn mix(comptime T: type, v: *const T, h: *u32) void {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                const I = @Int(.unsigned, @bitSizeOf(T));
                return mix(I, &@as(I, @bitCast(v.*)), h);
            }
            inline for (s.field_names, s.field_types) |name, F| mix(F, &@field(v.*, name), h);
        },
        .array => |a| for (v) |*x| mix(a.child, x, h),
        .@"enum" => feed(h, @backingInt(v.*)),
        .bool => feed(h, @intFromBool(v.*)),
        .int => {
            const bits = @bitSizeOf(T);
            if (bits > 32) @compileError("world_hash: field wider than 32 bits");
            const U = @Int(.unsigned, bits);
            feed(h, @as(U, @bitCast(v.*)));
        },
        else => @compileError("world_hash: unsupported field type " ++ @typeName(T)),
    }
}

/// The 7-bit piece i (0..3) of a hash.
fn piece(h: u32, i: u32) u8 {
    return @truncate((h >> @intCast(7 * i)) & 0x7F);
}

pub const Stats = struct {
    /// Input packets sent and received (repeats included).
    inputs_sent: u32 = 0,
    inputs_recv: u32 = 0,
    /// Input packets that brought no new tick (everything already held).
    inputs_stale: u32 = 0,
    /// Sends of an older window for a stalled partner.
    old_windows: u32 = 0,
    control_sent: u32 = 0,
    control_recv: u32 = 0,
    /// Check pieces compared (equal) and GOs re-sent.
    checks_ok: u32 = 0,
    go_resends: u32 = 0,
    /// `step` calls that found no inputs; pumps.
    stalls: u32 = 0,
    pumps: u32 = 0,
};

const Phase = enum(u8) { offline, searching, wrong_cart, lobby, racing, peer_left, desync };

const Check = struct { epoch: u32 = 0, hash: u32 = 0 };

pub fn Net(comptime L: type) type {
    return struct {
        const Self = @This();

        link: L,
        phase: Phase,
        role: Role = .none,
        /// Why the partner left (`peer_left`).
        left: Left = .none,
        /// The link session this lobby / race belongs to.
        session: u32 = 0,
        /// `now` of the last pump (us).
        now: u64 = 0,

        // ---- lobby ----
        /// Host: the rules it offers. Guest: the last SETUP heard (`heard_rules`).
        offer: Rules = .{},
        heard: Rules = .{},
        heard_rules: bool = false,
        /// This badge's pick, and the partner's last PICK this lobby (null
        /// until heard, and again after each race).
        pick: Pick = .{},
        peer_pick: ?Pick = null,
        /// The last race this badge joined this session (0: none yet).
        /// Every control message carries it.
        race_id: u8 = 0,
        /// The agreed race (valid from `take_started`).
        race: Race = .{},
        started: bool = false,
        /// The next lobby message: SETUP or PICK (host alternates); QUIT
        /// first after leaving a race.
        turn: u1 = 0,
        quit_next: bool = false,
        /// Wait after `last_tx` before the next control message.
        ctrl_wait: u64 = timing.ctrl_gap,
        /// Last packet this layer sent (any kind).
        last_tx: u64 = 0,

        // ---- lockstep ----
        /// The next tick `step` runs (lockstep ticks, paused ones included).
        tick: u32 = 0,
        /// Inputs held: local for ticks < local_hi, remote for < remote_hi.
        local_hi: u32 = input_delay,
        remote_hi: u32 = input_delay,
        /// Lower bound of the partner's remote_hi (what it holds of ours):
        /// the newest tick it sent minus the delay. Exact while it is
        /// stalled (`timing.peer_stalled` since `peer_top_at`).
        peer_need: u32 = input_delay,
        peer_top: u32 = 0,
        peer_top_at: u64 = 0,
        local: [ring_len]u8 = @splat(0),
        remote: [ring_len]u8 = @splat(0),
        /// Both input bytes of the last stepped tick (Start edges).
        prev: [2]u8 = .{ 0, 0 },
        /// Paused by a Start press of either human (agreed: it comes from
        /// the input bytes of a tick). `step` keeps running ticks, without
        /// simulating them, so the lockstep and the checks go on.
        paused: bool = false,
        /// Host: the guest's first input arrived (until then GO repeats).
        peer_started: bool = false,
        /// peer_left: the partner's car went to its AI (`step` did it).
        handed_over: ?u8 = null,
        /// A new local input not yet sent; the window the next packet to a
        /// stalled partner carries (oldest or newest, alternating).
        dirty: bool = false,
        alt: bool = false,
        /// `step` found no inputs since this time (null: it found some).
        stall_since: ?u64 = null,
        checks: [check_slots]Check = @splat(.{}),
        /// Lockstep tick at which `desync` was found.
        desync_tick: u32 = 0,

        stats: Stats = .{},

        /// `link` = `link.Badge.init(.{}, net.app_id, cart.rand())`.
        pub fn init(l: L) Self {
            const unavailable = l.state == .unavailable;
            return .{ .link = l, .phase = if (unavailable) .offline else .searching };
        }

        // ---- per frame -----------------------------------------------------

        /// Run the link and this layer: poll, follow the link state, read
        /// packets, send what is due. Call it often: at the top of every
        /// update, between the floor bands and the HUD passes, and in a loop
        /// while waiting or in the lobby (docs/NET.md).
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

        /// The input slot this badge drives: 0 for the host, 1 for the guest.
        pub fn local_slot(self: *const Self) u1 {
            return if (self.role == .guest) 1 else 0;
        }

        /// The car this badge drives (car i is racer i), once racing.
        pub fn local_car(self: *const Self) u8 {
            return self.race.racers[self.local_slot()];
        }

        // ---- lobby ---------------------------------------------------------

        /// Host: the rules to offer (ignored on the guest).
        pub fn set_rules(self: *Self, r: Rules) void {
            if (self.role != .host or self.phase != .lobby) return;
            if (std.meta.eql(r, self.offer)) return;
            self.offer = r;
            self.ctrl_wait = timing.ctrl_gap;
        }

        /// The rules on show: the host's own, or what the guest last heard.
        pub fn rules(self: *const Self) ?Rules {
            if (self.role == .host) return self.offer;
            return if (self.heard_rules) self.heard else null;
        }

        /// This badge's racer and ready flag (both badges). The select greys
        /// `peer_racer()`; on a clash the host's pick wins (no GO until the
        /// guest picks another).
        pub fn set_pick(self: *Self, racer: u8, ready: bool) void {
            const p = Pick{ .racer = if (racer < world.car_count) racer else no_racer, .ready = ready and racer < world.car_count };
            if (std.meta.eql(p, self.pick)) return;
            self.pick = p;
            self.ctrl_wait = timing.ctrl_gap;
        }

        /// The partner's racer (no_racer until heard).
        pub fn peer_racer(self: *const Self) u8 {
            return if (self.peer_pick) |p| p.racer else no_racer;
        }

        /// Host: both badges are ready on different racers.
        pub fn can_go(self: *const Self) bool {
            if (self.phase != .lobby or self.role != .host) return false;
            if (!self.pick.ready or self.pick.racer >= world.car_count) return false;
            const pp = self.peer_pick orelse return false;
            return pp.ready and pp.racer < world.car_count and pp.racer != self.pick.racer;
        }

        /// Host: start the race (both badges run the countdown from lockstep
        /// tick 0). False when `can_go` is not.
        pub fn go(self: *Self, now: u64) bool {
            if (!self.can_go()) return false;
            var id = self.race_id +% 1;
            if (id == 0) id = 1;
            self.race = .{ .id = id, .rules = self.offer, .racers = .{ self.pick.racer, self.peer_pick.?.racer }, .seed = self.seed_of(id) };
            self.race_id = id;
            self.begin_race(now);
            return true;
        }

        /// True once per race start (both badges): reset the World with
        /// `world_setup()` before the first `step`.
        pub fn take_started(self: *Self) bool {
            const s = self.started;
            self.started = false;
            return s;
        }

        /// The agreed setup for `sim.reset`, CREWS included (L3).
        pub fn world_setup(self: *const Self) world.Setup {
            return .{
                .track = self.race.rules.track,
                .seed = self.race.seed,
                .humans = self.race.racers,
                .mode = self.race.rules.mode,
                .crews = self.race.rules.crews,
            };
        }

        /// Leave the race (pause QUIT, results done, after peer_left or
        /// desync): back to the lobby, the partner hears QUIT. Also clears
        /// this badge's ready flag.
        pub fn leave(self: *Self, now: u64) void {
            switch (self.phase) {
                .racing, .peer_left, .desync => {},
                else => return,
            }
            _ = now;
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

        // ---- racing --------------------------------------------------------

        /// This frame's buttons (`input.race_byte()`, or the autopilot's):
        /// call it once a frame. They become the input for tick
        /// `local_hi`, at most delay + 1 ticks past the next tick to step
        /// (while `step` is stalled the frame's buttons are dropped), and
        /// go out at once.
        pub fn submit(self: *Self, now: u64, byte: u8) void {
            switch (self.phase) {
                .racing, .peer_left => {},
                else => return,
            }
            const b = sanitize(byte);
            if (self.local_hi < self.tick + lead_max) {
                self.local[self.local_hi % ring_len] = b;
                self.local_hi += 1;
                self.dirty = true;
            }
            self.send_due(now);
        }

        /// Run the next lockstep tick if both inputs are here: Start edges
        /// toggle `paused`, then (unless paused) `sim.simulate(w, inputs)`.
        /// After `peer_left` the partner's car goes to its AI first
        /// (`Car.human = no_human`, the only World write outside simulate;
        /// the partner is gone, so no agreement is needed) and the race goes
        /// on solo. At most one successful call a frame (the World runs at
        /// the frame rate; one input is submitted a frame): call it after
        /// `submit`, and while it returns false keep pumping and retry in the
        /// frame's waiting loop.
        pub fn step(self: *Self, w: *World) bool {
            const solo = self.phase == .peer_left;
            if (self.phase != .racing and !solo) return false;
            const t = self.tick;
            if (t >= self.local_hi or (!solo and t >= self.remote_hi)) {
                if (self.stall_since == null) self.stall_since = self.now;
                self.stats.stalls +%= 1;
                return false;
            }
            self.stall_since = null;
            const me = self.local_slot();
            var in: [2]u8 = undefined;
            in[me] = self.local[t % ring_len];
            in[me ^ 1] = if (solo) 0 else self.remote[t % ring_len];
            if (solo and self.handed_over == null) {
                for (&w.cars, 0..) |*c, i| {
                    if (c.human != me ^ 1) continue;
                    c.human = world.no_human;
                    self.handed_over = @intCast(i);
                }
            }
            const edge = ((in[0] & ~self.prev[0]) | (in[1] & ~self.prev[1])) & start_bit != 0;
            self.prev = in;
            if (w.phase == .finished) self.paused = false else if (edge) self.paused = !self.paused;
            if (!self.paused) sim.simulate(w, in);
            self.tick = t + 1;
            if (self.tick % check_every == 0) {
                const e = self.tick / check_every;
                self.checks[e % check_slots] = .{ .epoch = e, .hash = world_hash(w) };
            }
            return true;
        }

        // ---- link state ----------------------------------------------------

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
            self.heard_rules = false;
            self.pick.ready = false;
            self.quit_next = false;
            self.turn = 0;
            self.role = .none;
            if (self.link.partner_app != app_id) {
                self.phase = .wrong_cart;
                return;
            }
            const me = self.link.nonce;
            const them = self.link.partner_nonce;
            if (me == them) {
                // Who hosts is undecided (1 in 65536): lock again, new nonces.
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
            self.local_hi = input_delay;
            self.remote_hi = input_delay;
            self.peer_need = input_delay;
            self.peer_top = 0;
            self.peer_top_at = now;
            self.local = @splat(0);
            self.remote = @splat(0);
            self.prev = .{ 0, 0 };
            self.paused = false;
            self.peer_started = self.role == .guest;
            self.handed_over = null;
            self.dirty = false;
            self.stall_since = null;
            self.checks = @splat(.{});
            self.peer_pick = null;
            self.started = true;
            self.ctrl_wait = timing.ctrl_gap;
        }

        // ---- receiving -----------------------------------------------------

        fn handle(self: *Self, p: []const u8) void {
            if (p.len == input_len) return self.on_input(p);
            if (p.len < 2) return;
            self.stats.control_recv +%= 1;
            const id = p[1];
            switch (@as(Msg, @fromBackingInt(@intCast(p[0])))) {
                .setup => {
                    if (p.len < 3) return;
                    self.on_lobby_msg(id);
                    if (self.phase == .lobby and self.role == .guest) {
                        self.heard = Rules.decode(p[2]);
                        self.heard_rules = true;
                    }
                },
                .pick => {
                    if (p.len < 3) return;
                    self.on_lobby_msg(id);
                    if (self.phase == .lobby) self.peer_pick = Pick.decode(p[2]);
                },
                .go => {
                    if (p.len < 4) return;
                    self.on_go(id, p[2], p[3]);
                },
                .quit => self.on_lobby_msg(id),
                .desync => if (self.phase == .racing and id == self.race_id) self.found_desync(),
                _ => {},
            }
        }

        /// The partner sends control messages only from the lobby, with the
        /// last race it joined: our race id means it left our race.
        fn on_lobby_msg(self: *Self, id: u8) void {
            if (self.phase == .racing and id == self.race_id) self.peer_gone(.quit);
        }

        fn on_go(self: *Self, id: u8, rules_b: u8, racers_b: u8) void {
            if (self.role != .guest or self.phase != .lobby or id == self.race_id or id == 0) return;
            const host_r = racers_b & 7;
            const guest_r = (racers_b >> 4) & 7;
            if (host_r >= world.car_count or guest_r >= world.car_count or host_r == guest_r) return;
            self.race_id = id;
            self.race = .{ .id = id, .rules = Rules.decode(rules_b), .racers = .{ host_r, guest_r }, .seed = self.seed_of(id) };
            self.begin_race(self.now);
        }

        fn on_input(self: *Self, p: []const u8) void {
            if (self.phase != .racing) return;
            self.stats.inputs_recv +%= 1;
            // The newest tick from its low 6 bits: within 32 of remote_hi.
            const base = self.remote_hi;
            var d: i32 = @intCast((@as(u32, p[0] & 0x3F) -% base) & 0x3F);
            if (d >= 32) d -= 64;
            const n_signed = @as(i64, base) + d;
            if (n_signed < input_delay) return;
            const n: u32 = @intCast(n_signed);
            self.peer_started = true;
            // The partner's local_hi <= its tick + delay + 1, so it has
            // stepped (and holds our inputs) up to at least n - delay.
            if (n > self.peer_top) {
                self.peer_top = n;
                self.peer_top_at = self.now;
            }
            if (n - input_delay > self.peer_need) self.peer_need = n - input_delay;
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

        /// The check byte of a packet whose newest tick is n.
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

        // ---- sending -------------------------------------------------------

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
                        // Host: GO until the guest's first input shows it started.
                        if (since >= self.ctrl_wait) {
                            if (self.ctrl_wait == timing.go_every) self.stats.go_resends +%= 1;
                            self.send_control(now, &.{ @backingInt(Msg.go), self.race.id, self.race.rules.encode(), self.race.racers[0] | (self.race.racers[1] << 4) });
                            self.ctrl_wait = timing.go_every;
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

        fn send_lobby(self: *Self, now: u64) void {
            if (self.quit_next) {
                self.quit_next = false;
                self.send_control(now, &.{ @backingInt(Msg.quit), self.race_id });
            } else if (self.role == .host and self.turn == 0) {
                self.send_control(now, &.{ @backingInt(Msg.setup), self.race_id, self.offer.encode() });
            } else {
                self.send_control(now, &.{ @backingInt(Msg.pick), self.race_id, self.pick.encode() });
            }
            if (self.role == .host) self.turn ^= 1;
            self.ctrl_wait = timing.lobby_every;
        }

        fn send_inputs(self: *Self, now: u64) void {
            if (self.local_hi < 3) return;
            const newest = self.local_hi - 3;
            var b = newest;
            // A stalled partner lacks a tick we sent (lost packets), at least
            // peer_need. Alternate a window from there with the newest: its
            // own newest tick may be lost too, so peer_need may be low (then
            // our newest ticks are what it lacks, and the newest window also
            // tells it what we lack).
            if (self.peer_need < newest and self.local_hi - self.peer_need < ring_len and
                now -% self.peer_top_at >= timing.peer_stalled)
            {
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

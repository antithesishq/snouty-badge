//! Two-badge lockstep for Snouty GC (SPEC 7, docs/NET.md): GC's names over
//! the shared lib/lockstep.zig (root docs/LOCKSTEP.md), which was extracted
//! from this file's M4 version (net_m4.zig, kept for the wire-compatibility
//! test).
//!
//! M6 (LINK BATTLE, SPEC 8.3): the host's rules are five bytes (mode,
//! track or arena, CREWS, LIVES, TIME) in lockstep's paged SETUP
//! (docs/LOCKSTEP.md 4.3), and the game's protocol version is 1
//! (`Game.version`). An M4 to M5.1 badge (version 0, one rules byte) and
//! this one see each other as WRONG VERSION (or, for M4, which ignores
//! the version, as a lobby partner that never answers): they never race,
//! so they never desync. `GameV0` keeps the M5.1 wire (one rules byte,
//! version 0) for net_compat_test.zig, which proves it is still M4's byte
//! for byte and that v0 and v1 badges never start a race.
//!
//! What is GC's here: the rules bytes (mode, track, crews, lives, time),
//! the pick byte (racer, 7 = none), the World setup, the hand-over (the
//! partner's car to its AI), Start as the pause bit and no pausing a
//! finished race. Everything else (lobby, input packets, stalls, checks)
//! is lockstep's. No cart API, no clock (main passes `now`), no floats.
const std = @import("std");
const lockstep = @import("lockstep");
const world = @import("world.zig");
const sim = @import("sim.zig");
const tuning = @import("tuning.zig");
const track = @import("track.zig");

/// The HELLO `app` byte of Snouty GC (link.Badge.init(.., app_id, ..)).
pub const app_id: u8 = lockstep.apps.gc;

/// Input delay in ticks (SPEC 7.2): the byte sampled on frame f drives
/// tick f + 2.
pub const input_delay: u32 = 2;
/// A World hash is taken every this many ticks.
pub const check_every: u32 = 32;
/// The Start bit of the race byte (input.zig): the lockstep's pause bit.
const start_bit: u8 = 0x40;

pub const timing = lockstep.timing;
pub const State = lockstep.State;
pub const Left = lockstep.Left;
pub const Role = lockstep.Role;
pub const Stats = lockstep.Stats;
pub const Msg = lockstep.Msg;
pub const input_len = lockstep.input_len;
pub const data_kind = lockstep.data_kind;
pub const crc8 = lockstep.crc8;
pub const encode_input = lockstep.encode_input;
pub const sanitize = lockstep.sanitize;

/// No racer picked yet.
pub const no_racer: u8 = 0xFF;
/// The pick value for no racer (3 bits on the wire).
const none_pick: u8 = 7;

/// What the host chooses (SPEC 7.3, 8.3). `mode` is LINK RACE (`race`),
/// LINK GC (`gc`) or LINK BATTLE (`battle`); `track` indexes
/// `track.tracks`, or in battle `track.arenas`; `crews` is the AI count
/// (4, 2 or 0); `lives` (1, 3, 5, 9; 0 INF) and `minutes` (2, 3, 5; 0
/// NONE) are battle's and ride along in every mode.
///
/// On the wire (version 1, `encode`): five bytes, mode (0 race, 1 gc, 2
/// battle), track, crews, lives, minutes; lockstep's paged SETUP keeps
/// them off the SLIP bytes. Version 0 (`encode_v0`, M4 to M5.1): one byte,
/// track bits 0-3, crews bits 4-6, mode bit 7 (gc).
pub const Rules = struct {
    mode: world.Mode = .race,
    track: u8 = 0,
    crews: u8 = 4,
    lives: u8 = 3,
    minutes: u8 = 3,

    pub const len = 5;

    pub fn encode(r: Rules) [len]u8 {
        const m: u8 = switch (r.mode) {
            .gc => 1,
            .battle => 2,
            else => 0,
        };
        return .{ m, r.track, @min(r.crews, 7), r.lives, r.minutes };
    }

    /// Any bytes decode to rules the cart can run (an unknown mode is a
    /// race, a value off the menus' rows its default), so a partner build
    /// with other rows cannot reset the World into something odd; both
    /// badges decode the same bytes, so they still agree.
    pub fn decode(b: [len]u8) Rules {
        return .{
            .mode = switch (b[0]) {
                1 => .gc,
                2 => .battle,
                else => .race,
            },
            .track = b[1],
            .crews = @min(b[2], 7),
            .lives = if (std.mem.indexOfScalar(u8, &tuning.battle_lives_opts, b[3]) != null) b[3] else 3,
            .minutes = if (std.mem.indexOfScalar(u8, &tuning.battle_minutes_opts, b[4]) != null) b[4] else 3,
        };
    }

    /// The M4 to M5.1 rules byte (LINK RACE and LINK GC only).
    pub fn encode_v0(r: Rules) u8 {
        const gc: u8 = @intFromBool(r.mode == .gc);
        return (r.track & 0x0F) | (@as(u8, @min(r.crews, 7)) << 4) | (gc << 7);
    }
    pub fn decode_v0(b: u8) Rules {
        return .{ .track = b & 0x0F, .crews = (b >> 4) & 7, .mode = if (b & 0x80 != 0) .gc else .race };
    }
};

/// A badge's racer choice: on the wire racer bits 0-2 (7 = none), ready bit 7.
pub const Pick = struct {
    racer: u8 = no_racer,
    ready: bool = false,

    pub fn encode(p: Pick) u8 {
        const r: u8 = if (p.racer < world.car_count) p.racer else none_pick;
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

/// The World setup of an agreed race (both badges compute the same).
pub fn setup_of(r: Race) world.Setup {
    const battle = r.rules.mode == .battle;
    const n: u8 = @intCast(if (battle) track.arenas.len else track.tracks.len);
    var s: world.Setup = .{
        .track = r.rules.track % n,
        .seed = r.seed,
        .humans = r.racers,
        .mode = r.rules.mode,
        .crews = r.rules.crews,
    };
    if (battle) {
        s.lives = r.rules.lives;
        s.minutes = r.rules.minutes;
    }
    return s;
}

/// 32-bit hash of every World field by reflection (lockstep.hash_fields:
/// padding is never read, so equal Worlds hash equal on both badges).
pub fn world_hash(w: *const world.World) u32 {
    return lockstep.hash_fields(world.World, w);
}

/// GC as lockstep's game (docs/LOCKSTEP.md section 1): version 1, five
/// rules bytes (M6, LINK BATTLE).
pub const Game = struct {
    pub const World = world.World;
    pub const rules_len = Rules.len;
    pub const version: u4 = 1;
    pub const input_delay: u32 = net_input_delay;
    pub const check_every: u32 = net_check_every;
    pub const pause_bit: ?u8 = start_bit;
    pub const pick_bits: u8 = 3;

    pub fn simulate(w: *world.World, in: [2]u8) void {
        sim.simulate(w, in);
    }
    pub fn hash(w: *const world.World) u32 {
        return world_hash(w);
    }
    /// The partner's car goes to its AI (`Car.human = no_human`).
    pub fn hand_over(w: *world.World, slot: u1) void {
        for (&w.cars) |*c| {
            if (c.human == slot) c.human = world.no_human;
        }
    }
    /// Both humans on real racers, and different ones.
    pub fn picks_ok(host: u8, guest: u8) bool {
        return host < world.car_count and guest < world.car_count and host != guest;
    }
    /// A finished race is never paused.
    pub fn can_pause(w: *const world.World) bool {
        return w.phase != .finished;
    }
};

/// The M4 to M5.1 game (version 0, one rules byte: LINK RACE and LINK GC):
/// its wire is M4's byte for byte (net_compat_test.zig). Not used by the
/// cart; the tests run it against M4 and against `Game`.
pub const GameV0 = struct {
    pub const World = world.World;
    pub const rules_len = 1;
    pub const version: u4 = 0;
    pub const input_delay = Game.input_delay;
    pub const check_every = Game.check_every;
    pub const pause_bit = Game.pause_bit;
    pub const pick_bits = Game.pick_bits;
    pub const simulate = Game.simulate;
    pub const hash = Game.hash;
    pub const hand_over = Game.hand_over;
    pub const picks_ok = Game.picks_ok;
    pub const can_pause = Game.can_pause;
};
const net_input_delay = input_delay;
const net_check_every = check_every;

/// RESUME in the link pause menu (main.zig's `link_pause_frame`; net_test
/// drives the same code): the Start edge the cart sends for the player.
/// `step` toggles `paused` on a Start edge between two bytes it runs, and
/// `submit` drops a frame's byte while `step` is stalled, so an edge sent
/// for one frame can be lost and the race stays paused. Instead Start is
/// held on every byte until `paused` turns off (`settle`), after one kept
/// byte without Start if the last kept byte had it (the player's own
/// Start may still be down). That gives exactly one rising edge in the
/// bytes kept: holding never toggles twice. If the partner resumes first,
/// the hold ends and, unless a held Start was already kept, sends no edge.
pub const Resume = struct {
    /// RESUME (or B) was picked and `paused` has not turned off yet.
    pending: bool = false,
    /// Since `pending` began a byte without Start was kept (or the last
    /// kept byte had none): the next kept Start is an edge.
    armed: bool = false,
    /// The last byte `submit` kept had Start.
    last_start: bool = false,

    /// RESUME picked (again picks are no-ops while one is pending).
    pub fn request(r: *Resume) void {
        if (r.pending) return;
        r.pending = true;
        r.armed = !r.last_start;
    }

    /// The byte to submit this frame: `pad` (the player's buttons) unless
    /// a resume is pending, then nothing until armed and Start after.
    pub fn byte(r: *const Resume, pad: u8) u8 {
        if (!r.pending) return pad;
        return if (r.armed) start_bit else 0;
    }

    /// After every `submit` of a race or pause frame: the byte offered and
    /// whether it was kept.
    pub fn took(r: *Resume, b: u8, kept: bool) void {
        if (!kept) return;
        r.last_start = sanitize(b) & start_bit != 0;
        if (r.pending and !r.last_start) r.armed = true;
    }

    /// After the frame's `step`s: once `paused` is off (this edge or the
    /// partner's landed, or the race can no longer pause) the hold ends.
    pub fn settle(r: *Resume, paused: bool) void {
        if (!paused) r.pending = false;
    }
};

/// GC's lockstep over link type `L` (the cart's: version 1).
pub fn Net(comptime L: type) type {
    return NetOf(L, Game);
}

/// The same over game `G` (`Game`, or `GameV0` in the compatibility tests).
pub fn NetOf(comptime L: type, comptime G: type) type {
    return struct {
        const Self = @This();
        pub const Ls = lockstep.Lockstep(L, G);
        const v0 = G.rules_len == 1;

        fn encode(r: Rules) Ls.Rules {
            return if (v0) .{r.encode_v0()} else r.encode();
        }
        fn decode(b: Ls.Rules) Rules {
            return if (v0) Rules.decode_v0(b[0]) else Rules.decode(b);
        }

        /// The lockstep (its `link`, `role`, `left`, `paused`, `stats`).
        ls: Ls,

        /// `link` = `link.Badge.init(.{}, net.app_id, cart.rand())`.
        pub fn init(l: L) Self {
            var n: Self = .{ .ls = Ls.init(l) };
            // M4's host offered the default Rules before any set_rules.
            n.ls.offer = encode(.{});
            return n;
        }

        /// Run the link and the lockstep (docs/NET.md section 3 has the
        /// pump points).
        pub fn pump(self: *Self, now: u64) void {
            self.ls.pump(now);
        }

        pub fn state(self: *const Self) State {
            return self.ls.state();
        }

        /// A race runs (racing, waiting or peer_left).
        pub fn busy(self: *const Self) bool {
            return self.ls.busy();
        }

        /// Pump in a loop after drawing: a race runs (`busy`) or the link
        /// is handshaking (a HELLO is 10 wire bytes, more than the 8-byte
        /// receive FIFO). False while searching and in a settled lobby.
        pub fn wants_pump(self: *const Self) bool {
            return self.ls.wants_pump();
        }

        /// The input slot this badge drives: 0 for the host, 1 for the guest.
        pub fn local_slot(self: *const Self) u1 {
            return self.ls.local_slot();
        }

        /// The agreed race (valid from `take_started`).
        pub fn race(self: *const Self) Race {
            const r = &self.ls.race;
            return .{ .id = r.id, .rules = decode(r.rules), .racers = r.picks, .seed = r.seed };
        }

        /// The car this badge drives (car i is racer i), once racing.
        pub fn local_car(self: *const Self) u8 {
            return self.ls.race.picks[self.local_slot()];
        }

        /// peer_left: the partner's car, once `step` gave it to its AI.
        pub fn handed_over(self: *const Self) ?u8 {
            return if (self.ls.handed_over) self.ls.race.picks[self.local_slot() ^ 1] else null;
        }

        // ---- lobby ---------------------------------------------------------

        /// Host: the rules to offer (ignored on the guest).
        pub fn set_rules(self: *Self, r: Rules) void {
            self.ls.set_rules(encode(r));
        }

        /// The rules on show: the host's own, or what the guest last heard.
        pub fn rules(self: *const Self) ?Rules {
            const r = self.ls.rules() orelse return null;
            return decode(r);
        }

        /// This badge's racer and ready flag (both badges). The select greys
        /// `peer_racer()`; on a clash the host's pick wins (no GO until the
        /// guest picks another).
        pub fn set_pick(self: *Self, racer: u8, ready: bool) void {
            const ok = racer < world.car_count;
            self.ls.set_pick(if (ok) racer else none_pick, ready and ok);
        }

        /// The partner's last PICK this lobby (null until heard).
        pub fn peer_pick(self: *const Self) ?Pick {
            const b = self.ls.peer_pick_byte orelse return null;
            return Pick.decode(b);
        }

        /// The partner's racer (no_racer until heard).
        pub fn peer_racer(self: *const Self) u8 {
            return if (self.peer_pick()) |p| p.racer else no_racer;
        }

        /// Host: both badges are ready on different racers.
        pub fn can_go(self: *const Self) bool {
            return self.ls.can_go();
        }

        /// Host: start the race. False when `can_go` is not.
        pub fn go(self: *Self, now: u64) bool {
            return self.ls.go(now);
        }

        /// True once per race start (both badges): reset the World with
        /// `world_setup()` before the first `step`.
        pub fn take_started(self: *Self) bool {
            return self.ls.take_started();
        }

        /// The agreed setup for `sim.reset`, CREWS included (L3); M6 LINK
        /// BATTLE: the arena, LIVES and TIME.
        pub fn world_setup(self: *const Self) world.Setup {
            return setup_of(self.race());
        }

        /// Leave the race: back to the lobby, the partner hears QUIT.
        pub fn leave(self: *Self, now: u64) void {
            self.ls.leave(now);
        }

        // ---- racing --------------------------------------------------------

        /// This frame's race byte, once a frame (docs/NET.md section 3).
        /// False: the byte was dropped (the local ring is full while
        /// `step` is stalled; nothing is sent for it). `Resume` needs to
        /// know: the pause edge is taken against the last byte kept.
        pub fn submit(self: *Self, now: u64, byte: u8) bool {
            const before = self.ls.local_hi;
            self.ls.submit(now, byte);
            return self.ls.local_hi != before;
        }

        /// The next lockstep tick if both inputs are here (at most one
        /// success a frame).
        pub fn step(self: *Self, w: *world.World) bool {
            return self.ls.step(w);
        }
    };
}

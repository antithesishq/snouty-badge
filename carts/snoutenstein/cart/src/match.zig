//! Deathmatch rules (M7 two badges, M8 up to 16 players; SPEC.md section
//! 19): every present player in one arena, one tick at a time from each
//! slot's input byte. Pure over `World`, fixed point only, no cart-api, no
//! clock: every badge runs it in lockstep (`lib/lockstep.zig` for the
//! two-badge cable, `lib/lockstep_n.zig` for a party; glue in
//! `deathmatch.zig`) and must stay bit-equal.
//!
//! `World` is the campaign's GameState (doors, bugs, projectiles, pickup
//! bits, the PRNG) plus `state.Match` (the players, frags, teams, timers).
//! The campaign code works on `GameState.player`, so `step_n` swaps each
//! player into that slot in turn: movement, pickups, the weapon, and each
//! bug's tick against the player it targets (the nearest living one). The
//! campaign path (`sim.step`) is untouched by all of this.
//!
//! Tick order: bot inputs (from the World as the tick starts); hurt
//! flashes, death views and respawns; movement and pickups; doors; bugs
//! (BUGS ON); projectiles; every weapon from the same positions, their
//! damage applied after all fired (a double frag is possible); deaths,
//! frags and the frag limit; pickup timers. Wherever the present players
//! go one after another (respawns, movement, weapon damage), the order
//! starts at present player `tick mod count` and wraps, so no slot is
//! always first.
//!
//! The M7 two-badge path is `step` / `init_rules` / `G`: the same core with
//! slots 0 and 1 present. A party uses `step_n` / `init_n` / `GN`.
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const projectiles = @import("projectiles.zig");
const bot = @import("bot.zig");

const Fixed = fixed.Fixed;
const GameState = state.GameState;
const Match = state.Match;
const Player = state.Player;
const Buttons = state.Buttons;
const Level = levels.Level;

pub const max_players = state.max_players;

pub const World = struct {
    gs: GameState,
    m: Match,
};

comptime {
    // Hashed raw (`hash`): no padding between the two halves either.
    if (@sizeOf(World) != @sizeOf(GameState) + @sizeOf(Match)) @compileError("match.World has padding");
}

// ---------------------------------------------------------------- tuning

/// Weapon damage to a player is the bug damage times this: the zapper's 3
/// becomes 18, so a full-HP kill takes 6 zapper hits (5 leave 10 HP).
pub const pvp_scale: i16 = 6;
/// Cells per tick sideways while B is held (between back 0.03 and walk 0.045).
pub const strafe_speed: Fixed = fixed.from_float(0.035);
/// The death view: 2 s, then a respawn.
pub const death_ticks: u8 = 120;
/// Spawn protection after a respawn (the HUD blinks Iris, as for the
/// campaign's death grace).
pub const spawn_grace: u8 = 60;
/// A taken pickup comes back after 20 s; a dead bug (BUGS ON) too.
pub const pickup_respawn: u16 = 1200;
pub const bug_respawn: u16 = 1200;
/// A bug respawns only when no living player is this near its cell.
pub const bug_respawn_clear: Fixed = fixed.from_int(4);
/// Players never walk closer than this (centre to centre) to each other.
pub const body: Fixed = 2 * sim.radius;
/// The lobby's FRAGS row (M7 offered the first four).
pub const frag_limits = [5]u8{ 5, 10, 15, 20, 25 };
/// The lobby's TEAMS row: FFA, 2 teams, 4 teams (`Match.teams`).
pub const team_modes = [3]u8{ 0, 2, 4 };

// ---------------------------------------------------------------- rules and input

/// The host's lobby choice. On the wire (`encode2`, 2 bytes; the M7 cable
/// sends byte 0 alone, `encode`):
///
/// - byte 0: bits 0-1 arena, bits 2-3 frag index bits 0-1, bit 4 bugs,
///   bit 5 frag index bit 2 (index 4 = 25 frags; M7 never set it), bits
///   6-7 zero. For M7's values this is M7's byte unchanged.
/// - byte 1: bits 0-1 team mode index (`team_modes`: 0 FFA, 1 two
///   teams, 2 four teams), bits 2-7 reserved (zero).
///
/// The input delay is not a rule: LockstepN carries it in its GO message.
/// Out-of-range fields decode to the defaults (arena 0, FFA; a frag index
/// past the table to the last entry).
pub const Rules = struct {
    arena: u8 = 0,
    /// Index into `frag_limits`.
    frags: u8 = 1,
    bugs: bool = false,
    /// 0 (FFA), 2 or 4.
    teams: u8 = 0,

    pub fn encode(r: Rules) u8 {
        return (r.arena & 3) | ((r.frags & 3) << 2) | (@as(u8, @intFromBool(r.bugs)) << 4) | (((r.frags >> 2) & 1) << 5);
    }
    pub fn decode(b: u8) Rules {
        const a = b & 3;
        const f: u8 = ((b >> 2) & 3) | (((b >> 5) & 1) << 2);
        return .{
            .arena = if (a < levels.arena_indices.len) a else 0,
            .frags = @min(f, frag_limits.len - 1),
            .bugs = b & 0x10 != 0,
        };
    }
    pub fn encode2(r: Rules) [2]u8 {
        const t: u8 = switch (r.teams) {
            2 => 1,
            4 => 2,
            else => 0,
        };
        return .{ r.encode(), t };
    }
    pub fn decode2(b: [2]u8) Rules {
        var r = decode(b[0]);
        const t = b[1] & 3;
        r.teams = if (t < team_modes.len) team_modes[t] else 0;
        return r;
    }
    pub fn frag_limit(r: Rules) u8 {
        return frag_limits[@min(r.frags, frag_limits.len - 1)];
    }
};

/// The input byte the badges exchange: Up, Down, Left, Right, A, B,
/// Start, Select from bit 0. Start and Select never come together (the OS
/// chord; the lockstep's sanitize clears both), so a byte is never 0xC0
/// or 0xDB. Start is the lockstep's pause bit; the sim ignores it.
pub const bit_start: u8 = 0x40;
pub const bit_select: u8 = 0x80;

pub fn byte_of(b: Buttons) u8 {
    var x: u8 = 0;
    if (b.up) x |= 0x01;
    if (b.down) x |= 0x02;
    if (b.left) x |= 0x04;
    if (b.right) x |= 0x08;
    if (b.a) x |= 0x10;
    if (b.b) x |= 0x20;
    if (b.start) x |= bit_start;
    if (b.select) x |= bit_select;
    if (x & 0xC0 == 0xC0) x &= 0x3F;
    return x;
}

pub fn buttons_of(x: u8) Buttons {
    return .{
        .up = x & 0x01 != 0,
        .down = x & 0x02 != 0,
        .left = x & 0x04 != 0,
        .right = x & 0x08 != 0,
        .a = x & 0x10 != 0,
        .b = x & 0x20 != 0,
        .start = x & bit_start != 0,
        .select = x & bit_select != 0,
    };
}

/// The game side of the two-badge lockstep (lib/lockstep.zig): the World,
/// the agreed rules as one byte (`Rules.encode`), no picks beyond the
/// ready flag. A thin adapter over the N-player core with slots 0 and 1
/// present. Pure, so the host tests run it over the virtual cable.
pub const G = struct {
    pub const World = match_world;
    pub const rules_len = 1;
    pub const input_delay: u32 = 2;
    pub const check_every: u32 = 32;
    /// Start toggles the pause on both badges on the same tick.
    pub const pause_bit: ?u8 = bit_start;
    /// No racer-style picks: the lobby sends pick 0 with the ready flag
    /// (pick_bits and picks_ok keep their defaults).
    /// A finished match does not pause (the results take Start).
    pub fn can_pause(w: *const match_world) bool {
        return !w.m.over;
    }
    pub fn simulate(w: *match_world, in: [2]u8) void {
        step(w, &levels.all[w.gs.level], .{ buttons_of(in[0]), buttons_of(in[1]) });
    }
    pub fn hash(w: *const match_world) u32 {
        return world_hash(w);
    }
    /// The partner left mid-match: a forfeit win for the one who stayed
    /// (`hand_over` with one human left).
    pub fn hand_over(w: *match_world, slot: u1) void {
        match_hand_over(w, slot);
    }
};

/// The game side of the party lockstep (`lib/lockstep_n.zig`, LockstepN):
/// up to 16 slots, one input byte each per tick, the rules as 2 bytes
/// (`Rules.encode2`). The lead wires it; LockstepN may read any of these.
pub const GN = struct {
    pub const World = match_world;
    pub const game_id = "SNOUTDM1";
    pub const max_players = state.max_players;
    /// Arena, frag limit, bugs, teams (`Rules.encode2`). The input delay
    /// is LockstepN's (its GO message), not a rule.
    pub const rules_len = 2;
    pub const check_every: u32 = 32;
    pub const pause_bit: ?u8 = bit_start;
    pub fn can_pause(w: *const match_world) bool {
        return !w.m.over;
    }
    /// A fresh match from the lobby: the rules bytes, the slots in it, each
    /// slot's team (ignored in FFA; null = slot mod team count) and the GO
    /// seed.
    pub fn start(w: *match_world, rules: [rules_len]u8, present: u16, team: ?*const [state.max_players]u8, seed: u32) void {
        init_party(w, Rules.decode2(rules), present, team, seed);
    }
    /// One tick: `in[slot]` for every slot of `present` (the others, and
    /// slots handed over to bots, are ignored).
    pub fn simulate(w: *match_world, in: *const [state.max_players]u8, present: u16) void {
        var b: [state.max_players]Buttons = @splat(.{});
        for (0..state.max_players) |i| {
            if ((present >> @intCast(i)) & 1 == 1) b[i] = buttons_of(in[i]);
        }
        step_n(w, &levels.all[w.gs.level], &b);
    }
    pub fn hash(w: *const match_world) u32 {
        return world_hash(w);
    }
    /// A leaver (or a dropped badge): bot.zig plays the slot from this
    /// tick on, its frags stay; one human (or one team's humans) left
    /// ends the match as a forfeit.
    pub fn hand_over(w: *match_world, slot: u8) void {
        match_hand_over(w, slot);
    }
};
const match_world = World;
const world_hash = hash;
const match_hand_over = hand_over;

pub fn arena_level(arena: u8) *const Level {
    return &levels.all[levels.arena_indices[arena]];
}

// ---------------------------------------------------------------- setup

/// A fresh two-player match (M7: slots 0 and 1) on `level`
/// (`levels.all[level_index]`).
pub fn init(w: *World, level: *const Level, level_index: u8, rules: Rules, seed: u32) void {
    init_n(w, level, level_index, rules, 0b11, null, seed);
}

/// A fresh match for the slots in `present` on `level`: the campaign's
/// `sim.init` for doors, pickups and bugs (cleared when BUGS is off). In a
/// team mode `team[slot] % teams` is each slot's team (null: slot mod team
/// count). Start positions: the present slots in order are dealt over the
/// spawns from a seeded offset, spread by a stride of spawns / players
/// (so two players on six spawns start three apart); once every spawn is
/// taken, the rest go where a respawn would (`pick_spawn`).
pub fn init_n(w: *World, level: *const Level, level_index: u8, rules: Rules, present: u16, team: ?*const [max_players]u8, seed: u32) void {
    std.debug.assert(level.pickups.len <= state.max_match_pickups);
    std.debug.assert(present != 0);
    sim.init(&w.gs, level, level_index, seed);
    if (!rules.bugs) {
        for (&w.gs.enemies) |*e| e.* = .{};
    }
    const absent: Player = .{ .x = 0, .y = 0, .angle = 0, .hp = 0, .ammo_zapper = 0, .rewind_meter = 0 };
    w.m = .{
        .players = @splat(absent),
        .present = present,
        .teams = rules.teams,
        .arena = rules.arena,
        .frag_limit = rules.frag_limit(),
        .bugs = rules.bugs,
    };
    const m = &w.m;
    if (m.teams != 0) {
        for (0..max_players) |i| {
            const t: u8 = if (team) |tt| tt[i] else @intCast(i);
            m.team[i] = t % m.teams;
        }
    }
    const n: u32 = @popCount(present);
    const ns: u32 = @intCast(spawn_count(level));
    const stride: u32 = if (n < ns) ns / n else 1;
    const offset: u32 = mix(seed) % ns;
    var k: u32 = 0;
    for (0..max_players) |i| {
        if (!m.is_present(i)) continue;
        const sp = if (k < ns) spawn_at(level, (offset + k * stride) % ns) else pick_spawn(level, m, i);
        m.players[i] = fresh(sp);
        k += 1;
    }
    w.gs.player = m.players[first_present(m)];
}

/// `init` from the lobby's rules (the arena picks the level): the M7
/// two-player match.
pub fn init_rules(w: *World, rules: Rules, seed: u32) void {
    init(w, arena_level(rules.arena), levels.arena_indices[rules.arena], rules, seed);
}

/// `init_n` from the lobby's rules: a party match.
pub fn init_party(w: *World, rules: Rules, present: u16, team: ?*const [max_players]u8, seed: u32) void {
    init_n(w, arena_level(rules.arena), levels.arena_indices[rules.arena], rules, present, team, seed);
}

fn mix(a: u32) u32 {
    var x = a *% 0x9E37_79B9;
    x ^= x >> 16;
    x *%= 0x85EB_CA6B;
    x ^= x >> 13;
    return x;
}

fn fresh(sp: levels.Spawn) Player {
    return .{
        .x = fixed.from_int(sp.x) + fixed.half,
        .y = fixed.from_int(sp.y) + fixed.half,
        .angle = sp.angle,
    };
}

fn spawn_count(level: *const Level) usize {
    return @max(level.spawns.len, 1);
}

/// Spawn `i`; a level without spawns has one, its start.
fn spawn_at(level: *const Level, i: usize) levels.Spawn {
    if (level.spawns.len == 0) return .{ .x = level.start_x, .y = level.start_y, .angle = level.start_angle };
    return level.spawns[i];
}

fn spawn_centre(sp: levels.Spawn) [2]Fixed {
    return .{ fixed.from_int(sp.x) + fixed.half, fixed.from_int(sp.y) + fixed.half };
}

/// The spawn whose centre is farthest from (x, y); the first wins a tie.
pub fn farthest_spawn(level: *const Level, x: Fixed, y: Fixed) levels.Spawn {
    var best: usize = 0;
    var best_d: i64 = -1;
    for (0..spawn_count(level)) |i| {
        const c = spawn_centre(spawn_at(level, i));
        const d = dist2(c[0] - x, c[1] - y);
        if (d > best_d) {
            best = i;
            best_d = d;
        }
    }
    return spawn_at(level, best);
}

/// Where slot `me` (re)spawns: the spawn whose distance to the nearest
/// living foe is largest (any spawn when no foe lives), skipping spawns a
/// living player stands on (within `body`) unless all are; ties go to the
/// lowest index.
pub fn pick_spawn(level: *const Level, m: *const Match, me: usize) levels.Spawn {
    const ns = spawn_count(level);
    var best: usize = 0;
    var best_d: i64 = -1;
    var best_any: usize = 0;
    var best_any_d: i64 = -1;
    for (0..ns) |k| {
        const c = spawn_centre(spawn_at(level, k));
        var near_foe: i64 = std.math.maxInt(i64);
        var taken = false;
        for (0..max_players) |j| {
            if (j == me or !m.alive(j)) continue;
            const d = dist2(m.players[j].x - c[0], m.players[j].y - c[1]);
            if (d < sq(body)) taken = true;
            if (m.foes(me, j) and d < near_foe) near_foe = d;
        }
        if (near_foe > best_any_d) {
            best_any = k;
            best_any_d = near_foe;
        }
        if (!taken and near_foe > best_d) {
            best = k;
            best_d = near_foe;
        }
    }
    return spawn_at(level, if (best_d >= 0) best else best_any);
}

/// A leaver (the lockstep's hand-over): bot.zig plays `slot` from now on
/// (its frags stay). When one human is left, or (team modes) every human
/// left is on one team, the match ends as a forfeit win for them.
pub fn hand_over(w: *World, slot: usize) void {
    const m = &w.m;
    if (m.over or slot >= max_players or !m.is_present(slot) or m.is_bot(slot)) return;
    m.bots |= @as(u16, 1) << @intCast(slot);
    const humans = m.present & ~m.bots;
    if (humans == 0) {
        finish(m, state.no_one, true);
        return;
    }
    const h0: usize = @ctz(humans);
    if (m.teams == 0) {
        if (@popCount(humans) == 1) finish(m, @intCast(h0), true);
        return;
    }
    for (0..max_players) |i| {
        if ((humans >> @intCast(i)) & 1 == 1 and m.team[i] != m.team[h0]) return;
    }
    finish(m, state.team_win | m.team[h0], true);
}

/// M7's name for the two-badge hand-over: `gone` left, the other wins.
pub fn forfeit(w: *World, gone: u1) void {
    hand_over(w, gone);
}

fn finish(m: *Match, winner: u8, by_forfeit: bool) void {
    m.over = true;
    m.forfeit = by_forfeit;
    m.winner = winner;
}

/// FNV-1a over the raw World (no padding anywhere, state.zig asserts it).
pub fn hash(w: *const World) u32 {
    var h: u32 = 2166136261;
    for (std.mem.asBytes(w)) |byte| {
        h ^= byte;
        h *%= 16777619;
    }
    return h;
}

/// `rival.png` cell for another player `r` seen from `viewer`: 0 front
/// (it faces the viewer, within 45 degrees), 1 its right side (it faces
/// screen right), 2 back, 3 left side, 4 down (the death view).
pub fn rival_cell(viewer: *const Player, r: *const Player, dead: bool) u8 {
    if (dead) return 4;
    const to_viewer = fixed.atan2(viewer.y - r.y, viewer.x - r.x);
    const rel = fixed.angle_diff(r.angle, to_viewer);
    const q: i32 = fixed.deg(45);
    if (rel > -q and rel < q) return 0;
    if (rel > 3 * q or rel < -3 * q) return 2;
    return if (rel > 0) 3 else 1;
}

pub fn alive(m: *const Match, slot: usize) bool {
    return m.alive(slot);
}

fn first_present(m: *const Match) usize {
    return @ctz(m.present);
}

/// The present slots in this tick's order: from present player `tick mod
/// count`, wrapping. Returns the count.
fn tick_order(m: *const Match, tick: u32, out: *[max_players]u8) usize {
    var all: [max_players]u8 = undefined;
    var n: usize = 0;
    for (0..max_players) |i| {
        if (!m.is_present(i)) continue;
        all[n] = @intCast(i);
        n += 1;
    }
    if (n == 0) return 0;
    const first = tick % @as(u32, @intCast(n));
    for (0..n) |k| out[k] = all[(first + k) % n];
    return n;
}

// ---------------------------------------------------------------- step

/// One two-player tick (M7): `in[0]` is the host's buttons, `in[1]` the
/// guest's. A finished match takes no input and does not move.
pub fn step(w: *World, level: *const Level, in: [2]Buttons) void {
    var all: [max_players]Buttons = @splat(.{});
    all[0] = in[0];
    all[1] = in[1];
    step_n(w, level, &all);
}

/// One tick: `in[slot]` for each present human slot; bot slots
/// (`Match.bots`) get bot.zig's input instead, absent slots are ignored.
pub fn step_n(w: *World, level: *const Level, in_raw: *const [max_players]Buttons) void {
    const s = &w.gs;
    const m = &w.m;
    if (m.over) return;
    var in = in_raw.*;
    if (m.bots != 0) {
        for (0..max_players) |i| {
            if (m.is_bot(i) and m.is_present(i)) in[i] = bot.think(w, level, i);
        }
    }
    var order: [max_players]u8 = undefined;
    const n = tick_order(m, s.tick, &order);
    s.last_locked = 0;
    for (&m.hurt) |*h| h.* -|= 1;
    for (order[0..n]) |i| {
        if (m.dead[i] == 0) continue;
        m.dead[i] -= 1;
        if (m.dead[i] == 0) respawn(w, level, i);
    }

    for (order[0..n]) |i| move(w, level, i, in[i]);

    doors(w, level);
    if (m.bugs) bugs(w, level);
    projectiles.update_match(s, level, m, pvp_scale);

    // Every weapon from the same positions; damage lands after all fired.
    var pending: [max_players][max_players]i16 = @splat(@splat(0));
    for (order[0..n]) |i| {
        if (!m.alive(i)) continue;
        var rivals: [max_players]sim.Rival = undefined;
        var nr: usize = 0;
        for (0..max_players) |j| {
            if (!m.foes(i, j) or !m.alive(j)) continue;
            rivals[nr] = .{ .x = m.players[j].x, .y = m.players[j].y, .alive = true, .slot = @intCast(j) };
            nr += 1;
        }
        var shot: sim.Shot = .{ .rivals = rivals[0..nr], .tag = i + 1 };
        swap_in(w, i);
        sim.update_weapon(s, level, in[i], &shot);
        swap_out(w, i);
        if (shot.fired) m.shots[i] +%= 1;
        for (rivals[0..nr]) |r| pending[i][r.slot] = r.damage;
    }
    for (order[0..n]) |i| {
        var hit = false;
        for (0..max_players) |j| {
            const d = pending[i][j];
            if (d > 0 and sim.damage_slot(m, j, d * pvp_scale, i)) hit = true;
        }
        if (hit) m.hits[i] +%= 1;
    }

    var died = false;
    for (0..max_players) |i| {
        if (m.is_present(i) and m.dead[i] == 0 and m.players[i].hp <= 0) {
            die(w, i);
            died = true;
        }
    }
    if (died) check_over(m);
    tick_pickups(w, level);
    for (order[0..n]) |i| m.players[i].prev = in[i];
    s.tick +%= 1;
    s.player = m.players[first_present(m)];
    s.hurt = 0;
}

fn swap_in(w: *World, i: usize) void {
    w.gs.player = w.m.players[i];
    w.gs.hurt = w.m.hurt[i];
}

fn swap_out(w: *World, i: usize) void {
    w.m.players[i] = w.gs.player;
    w.m.hurt[i] = w.gs.hurt;
}

/// Doors stay open while any present player (a body too) stands in them.
fn doors(w: *World, level: *const Level) void {
    const m = &w.m;
    const p0 = first_present(m);
    var others: [max_players]Player = undefined;
    var n: usize = 0;
    for (p0 + 1..max_players) |i| {
        if (!m.is_present(i)) continue;
        others[n] = m.players[i];
        n += 1;
    }
    w.gs.player = m.players[p0];
    sim.update_doors(&w.gs, level, others[0..n]);
}

/// Turn or strafe (B held), walk, keep clear of the other players, then
/// the pickups under the player.
fn move(w: *World, level: *const Level, i: usize, b: Buttons) void {
    const s = &w.gs;
    const m = &w.m;
    if (!m.alive(i)) return;
    swap_in(w, i);
    const p = &s.player;
    if (p.grace > 0) p.grace -= 1;
    var fwd: Fixed = 0;
    var side: Fixed = 0;
    if (b.b) {
        if (b.left) side = -strafe_speed;
        if (b.right) side = strafe_speed;
    } else {
        if (b.left) p.angle -%= sim.turn_speed;
        if (b.right) p.angle +%= sim.turn_speed;
    }
    if (b.up) fwd = sim.walk_speed;
    if (b.down) fwd = -sim.back_speed;
    if (p.frozen > 0) {
        p.frozen -= 1;
        fwd = 0;
        side = 0;
    }
    if (fwd != 0 or side != 0) {
        // Right of the facing is the facing plus a quarter turn: (-sin, cos).
        const c = fixed.cos(p.angle);
        const sn = fixed.sin(p.angle);
        const x0 = p.x;
        const y0 = p.y;
        _ = sim.move_circle(s, level, &p.x, &p.y, fixed.mul(c, fwd) - fixed.mul(sn, side), fixed.mul(sn, fwd) + fixed.mul(c, side), sim.radius, .player);
        // A step that ends inside another living player's body and closer
        // than before is undone (stepping apart is always allowed).
        for (0..max_players) |j| {
            if (j == i or !m.alive(j)) continue;
            const o = &m.players[j];
            const now = dist2(p.x - o.x, p.y - o.y);
            if (now < sq(body) and now < dist2(x0 - o.x, y0 - o.y)) {
                p.x = x0;
                p.y = y0;
                break;
            }
        }
    }
    const cx = fixed.to_int(p.x);
    const cy = fixed.to_int(p.y);
    const np = @min(level.pickups.len, state.max_match_pickups);
    for (level.pickups[0..np], 0..) |pk, k| {
        if (pk.x != cx or pk.y != cy or !state.pickup_present(s, k)) continue;
        sim.apply_pickup(p, pk.kind);
        state.take_pickup(s, k);
        m.pickup_timer[k] = pickup_respawn;
    }
    swap_out(w, i);
}

/// The nearest living player to (x, y); the lowest slot on a tie, the
/// first present slot when none lives.
fn target(m: *const Match, x: Fixed, y: Fixed) usize {
    var best: usize = first_present(m);
    var best_d: i64 = std.math.maxInt(i64);
    for (0..max_players) |i| {
        if (!m.alive(i)) continue;
        const d = dist2(m.players[i].x - x, m.players[i].y - y);
        if (d < best_d) {
            best = i;
            best_d = d;
        }
    }
    return best;
}

/// BUGS ON: each bug's tick against its target; dead bugs respawn after
/// `bug_respawn` at their level cell once no player is near it.
fn bugs(w: *World, level: *const Level) void {
    const s = &w.gs;
    const m = &w.m;
    for (level.enemies, 0..) |def, i| {
        const e = &s.enemies[i];
        if (e.state == .dead) {
            const t = &m.bug_timer[i];
            if (t.* == 0) {
                t.* = bug_respawn;
            } else {
                t.* -= 1;
                if (t.* == 0) {
                    const x = fixed.from_int(def.x) + fixed.half;
                    const y = fixed.from_int(def.y) + fixed.half;
                    if (clear_of_players(m, x, y)) {
                        e.* = .{ .x = x, .y = y, .kind = def.kind, .state = .idle, .hp = sim.stats(def.kind).hp, .frame = sim.frame_idle };
                    } else {
                        t.* = 1; // try again next tick
                    }
                }
            }
            continue;
        }
        const t = target(m, e.x, e.y);
        swap_in(w, t);
        const hp0 = s.player.hp;
        ai.update_enemy(s, level, i);
        if (s.player.hp < hp0) m.last_hit[t] = state.by_bug;
        swap_out(w, t);
    }
}

fn clear_of_players(m: *const Match, x: Fixed, y: Fixed) bool {
    for (0..max_players) |i| {
        if (m.alive(i) and dist2(m.players[i].x - x, m.players[i].y - y) < sq(bug_respawn_clear)) return false;
    }
    return true;
}

/// At 0 HP: the death view, and the frag to whoever hurt the player last
/// (-1 for a self-frag, nothing for a bug); team frags follow.
fn die(w: *World, i: usize) void {
    const m = &w.m;
    m.dead[i] = death_ticks;
    m.deaths[i] +%= 1;
    m.players[i].frozen = 0;
    const k = m.last_hit[i];
    if (k == i) {
        m.frags[i] -= 1;
        if (m.teams != 0) m.team_frags[m.team[i]] -= 1;
    } else if (k < max_players and m.foes(k, i)) {
        m.frags[k] += 1;
        if (m.teams != 0) m.team_frags[m.team[k]] += 1;
    }
    m.victim = @intCast(i);
    m.killer = k;
    m.kill_tick = w.gs.tick;
}

/// The frag limit: per player in FFA, per team in team modes. The top
/// score at or past it wins; a shared top score is a draw.
fn check_over(m: *Match) void {
    const lim: i16 = m.frag_limit;
    var top: i16 = std.math.minInt(i16);
    var who: u8 = state.no_one;
    var shared = false;
    if (m.teams == 0) {
        for (0..max_players) |i| {
            if (!m.is_present(i)) continue;
            consider(m.frags[i], @intCast(i), &top, &who, &shared);
        }
    } else {
        for (0..m.teams) |t| consider(m.team_frags[t], state.team_win | @as(u8, @intCast(t)), &top, &who, &shared);
    }
    if (top < lim) return;
    finish(m, if (shared) state.no_one else who, false);
}

fn consider(score: i16, id: u8, top: *i16, who: *u8, shared: *bool) void {
    if (score > top.*) {
        top.* = score;
        who.* = id;
        shared.* = false;
    } else if (score == top.*) {
        shared.* = true;
    }
}

/// After the death view: full HP and the starting loadout at `pick_spawn`,
/// with a moment of spawn protection.
fn respawn(w: *World, level: *const Level, i: usize) void {
    const m = &w.m;
    const prev = m.players[i].prev;
    m.players[i] = fresh(pick_spawn(level, m, i));
    m.players[i].prev = prev;
    m.players[i].grace = spawn_grace;
    m.last_hit[i] = state.no_one;
}

fn tick_pickups(w: *World, level: *const Level) void {
    const s = &w.gs;
    const m = &w.m;
    const n = @min(level.pickups.len, state.max_match_pickups);
    for (m.pickup_timer[0..n], 0..) |*t, k| {
        if (t.* == 0) continue;
        t.* -= 1;
        if (t.* == 0) s.pickups[k / 32] |= @as(u32, 1) << @intCast(k % 32);
    }
}

fn sq(a: Fixed) i64 {
    return @as(i64, a) * a;
}
fn dist2(dx: Fixed, dy: Fixed) i64 {
    return sq(dx) + sq(dy);
}

// ---------------------------------------------------------------- tests

const testing = std.testing;
const level_parse = @import("level_parse.zig");

// Two spawns facing each other down a 10-cell hall, a charge and a hotfix
// off to the side, a plain door to a closet.
const hall_src =
    \\111111111111
    \\1P........P1
    \\1..........1
    \\1...%..+...1
    \\11111D111111
    \\1....a.....1
    \\111111111111
;

fn hall(st: *level_parse.Parsed) !Level {
    return level_parse.parse_level(st, "hall", hall_src, 0);
}

fn new_world(w: *World, L: *const Level, bugs_on: bool) void {
    init(w, L, 0, .{ .bugs = bugs_on, .frags = 0 }, 1234);
}

fn run(w: *World, L: *const Level, in: [2]Buttons, n: usize) void {
    for (0..n) |_| step(w, L, in);
}

const idle = [2]Buttons{ .{}, .{} };

test "spawns face into the room and the players start apart" {
    var st: level_parse.Parsed = undefined;
    const L = try hall(&st);
    try testing.expectEqual(@as(usize, 2), L.spawns.len);
    try testing.expectEqual(@as(fixed.Angle, 0), L.spawns[0].angle); // east, down the hall
    try testing.expectEqual(fixed.deg(180), L.spawns[1].angle); // west
    var w: World = undefined;
    new_world(&w, &L, false);
    try testing.expectEqual(fixed.from_float(1.5), w.m.players[0].x);
    try testing.expectEqual(fixed.from_float(10.5), w.m.players[1].x);
    try testing.expectEqual(@as(u8, 5), w.m.frag_limit);
    // BUGS OFF: the gnat is gone.
    try testing.expect(!sim.living(&w.gs.enemies[0]));
    new_world(&w, &L, true);
    try testing.expect(sim.living(&w.gs.enemies[0]));
}

test "the rival's billboard cell follows its facing" {
    // Viewer at the west looking east at the rival 5 cells away.
    const v: Player = .{ .x = fixed.from_int(1), .y = fixed.from_int(1), .angle = 0 };
    var r: Player = .{ .x = fixed.from_int(6), .y = fixed.from_int(1), .angle = fixed.deg(180) };
    try testing.expectEqual(@as(u8, 0), rival_cell(&v, &r, false)); // facing the viewer
    r.angle = 0;
    try testing.expectEqual(@as(u8, 2), rival_cell(&v, &r, false)); // walking away
    r.angle = fixed.deg(90); // south: screen right for an east-looking viewer
    try testing.expectEqual(@as(u8, 1), rival_cell(&v, &r, false));
    r.angle = fixed.deg(270);
    try testing.expectEqual(@as(u8, 3), rival_cell(&v, &r, false));
    try testing.expectEqual(@as(u8, 4), rival_cell(&v, &r, true));
}

test "input bytes round-trip and never carry Start with Select" {
    for (0..256) |i| {
        const x: u8 = @intCast(i);
        const b = byte_of(buttons_of(x));
        if (x & 0xC0 == 0xC0) {
            try testing.expectEqual(x & 0x3F, b);
        } else {
            try testing.expectEqual(x, b);
        }
        try testing.expect(b != 0xC0 and b != 0xDB);
    }
    const r: Rules = .{ .arena = 1, .frags = 3, .bugs = true };
    try testing.expectEqual(r, Rules.decode(r.encode()));
    try testing.expectEqual(@as(u8, 20), r.frag_limit());
}

test "hold B and Left/Right strafes without turning" {
    var st: level_parse.Parsed = undefined;
    const L = try hall(&st);
    var w: World = undefined;
    new_world(&w, &L, false);
    const y0 = w.m.players[0].y;
    const a0 = w.m.players[0].angle;
    // Facing east, strafe right = south.
    run(&w, &L, .{ .{ .b = true, .right = true }, .{} }, 10);
    try testing.expectEqual(a0, w.m.players[0].angle);
    try testing.expectEqual(fixed.from_float(1.5), w.m.players[0].x);
    try testing.expectEqual(y0 + 10 * strafe_speed, w.m.players[0].y);
    // Strafe left back north, then into the north wall: it stops at the radius.
    run(&w, &L, .{ .{ .b = true, .left = true }, .{} }, 60);
    try testing.expectEqual(fixed.from_int(1) + sim.radius, w.m.players[0].y);
    // Without B, Left turns.
    step(&w, &L, .{ .{ .left = true }, .{} });
    try testing.expectEqual(a0 -% sim.turn_speed, w.m.players[0].angle);
    // Strafe and walk together: both components, still one move.
    new_world(&w, &L, false);
    step(&w, &L, .{ .{ .b = true, .right = true, .up = true }, .{} });
    try testing.expectEqual(fixed.from_float(1.5) + sim.walk_speed, w.m.players[0].x);
    try testing.expectEqual(fixed.from_float(1.5) + strafe_speed, w.m.players[0].y);
}

test "six zapper hits frag, the killer scores, the victim respawns far away" {
    var st: level_parse.Parsed = undefined;
    const L = try hall(&st);
    var w: World = undefined;
    new_world(&w, &L, false);
    const fire = [2]Buttons{ .{ .a = true }, .{} };
    step(&w, &L, fire);
    try testing.expectEqual(@as(i16, 100 - 3 * pvp_scale), w.m.players[1].hp);
    try testing.expectEqual(@as(u8, 0), w.m.last_hit[1]);
    try testing.expectEqual(sim.hurt_ticks, w.m.hurt[1]);
    try testing.expectEqual(@as(u16, 1), w.m.shots[0]);
    try testing.expectEqual(@as(u16, 1), w.m.hits[0]);
    // Five hits leave 10 HP; the sixth (60 ticks later) frags.
    run(&w, &L, fire, 4 * 12 + 11);
    try testing.expectEqual(@as(i16, 10), w.m.players[1].hp);
    try testing.expectEqual(@as(u8, 0), w.m.dead[1]);
    step(&w, &L, fire);
    try testing.expectEqual(@as(i16, 0), w.m.players[1].hp);
    try testing.expectEqual(death_ticks, w.m.dead[1]);
    try testing.expectEqual(@as(i16, 1), w.m.frags[0]);
    try testing.expectEqual(@as(i16, 0), w.m.frags[1]);
    try testing.expectEqual(@as(u8, 1), w.m.victim);
    try testing.expectEqual(@as(u8, 0), w.m.killer);
    try testing.expectEqual(w.gs.tick - 1, w.m.kill_tick);
    // The corpse is no target: more shots miss.
    const hits = w.m.hits[0];
    run(&w, &L, fire, 30);
    try testing.expectEqual(hits, w.m.hits[0]);
    // The dead player's input does nothing during the death view.
    const x_dead = w.m.players[1].x;
    run(&w, &L, .{ .{}, .{ .up = true } }, 20);
    try testing.expectEqual(x_dead, w.m.players[1].x);
    // Respawn after 2 s: full HP, fresh zapper, at the spawn farthest from
    // player 0 (who stands at the west spawn: the east one).
    var n: usize = 0;
    while (w.m.dead[1] > 0) : (n += 1) step(&w, &L, idle);
    try testing.expect(n < death_ticks);
    try testing.expectEqual(@as(i16, 100), w.m.players[1].hp);
    try testing.expectEqual(@as(u8, 40), w.m.players[1].ammo_zapper);
    try testing.expectEqual(state.Weapon.zapper, w.m.players[1].weapon);
    try testing.expectEqual(fixed.from_float(10.5), w.m.players[1].x);
    try testing.expectEqual(spawn_grace - 1, w.m.players[1].grace); // the respawn tick moved too
    // Spawn protection: a shot lands no damage.
    step(&w, &L, fire);
    try testing.expectEqual(@as(i16, 100), w.m.players[1].hp);
}

test "the respawn picks the spawn farthest from the opponent" {
    const src =
        \\1111111111
        \\1P......P1
        \\1........1
        \\1........1
        \\1P......P1
        \\1111111111
    ;
    var st: level_parse.Parsed = undefined;
    const L = try level_parse.parse_level(&st, "four", src, 0);
    try testing.expectEqual(@as(usize, 4), L.spawns.len);
    // Opponent near the south-east corner: the north-west spawn.
    const sp = farthest_spawn(&L, fixed.from_float(7.9), fixed.from_float(4.2));
    try testing.expectEqual(@as(u8, 1), sp.x);
    try testing.expectEqual(@as(u8, 1), sp.y);
    const sp2 = farthest_spawn(&L, fixed.from_float(2.0), fixed.from_float(1.2));
    try testing.expectEqual(@as(u8, 8), sp2.x);
    try testing.expectEqual(@as(u8, 4), sp2.y);
}

test "a Debugger burst at point-blank is a self-frag" {
    var st: level_parse.Parsed = undefined;
    const L = try hall(&st);
    var w: World = undefined;
    new_world(&w, &L, false);
    const p = &w.m.players[0];
    p.has_debugger = true;
    p.ammo_debugger = 9;
    p.weapon = .debugger;
    p.angle = fixed.deg(180); // facing the west wall, 0.5 cells away
    p.hp = 50; // a burst is 12 * 6 = 72
    step(&w, &L, .{ .{ .a = true }, .{} });
    var n: usize = 0;
    while (w.m.dead[0] == 0) : (n += 1) {
        try testing.expect(n < 20);
        step(&w, &L, idle);
    }
    try testing.expectEqual(@as(i16, -1), w.m.frags[0]);
    try testing.expectEqual(@as(u8, 0), w.m.killer);
    try testing.expectEqual(@as(u8, 0), w.m.victim);
    try testing.expectEqual(@as(u16, 0), w.m.hits[0]);
}

test "a Debugger bolt bursts on the other player and frags with splash" {
    var st: level_parse.Parsed = undefined;
    const L = try hall(&st);
    var w: World = undefined;
    new_world(&w, &L, false);
    const p = &w.m.players[0];
    p.has_debugger = true;
    p.ammo_debugger = 9;
    p.weapon = .debugger;
    w.m.players[1].hp = 60;
    step(&w, &L, .{ .{ .a = true }, .{} });
    var n: usize = 0;
    while (w.m.dead[1] == 0) : (n += 1) {
        try testing.expect(n < 120);
        step(&w, &L, idle);
    }
    try testing.expectEqual(@as(i16, 1), w.m.frags[0]);
    try testing.expectEqual(@as(u16, 1), w.m.hits[0]);
    try testing.expectEqual(@as(i16, 100), w.m.players[0].hp); // 9 cells away from the burst
}

test "a taken pickup comes back 20 s later" {
    var st: level_parse.Parsed = undefined;
    const L = try hall(&st);
    var w: World = undefined;
    new_world(&w, &L, false);
    // Player 0 walks onto the charge at (4, 3).
    const p = &w.m.players[0];
    p.x = fixed.from_float(4.5);
    p.y = fixed.from_float(2.6);
    p.angle = fixed.deg(90);
    step(&w, &L, .{ .{ .up = true }, .{} });
    while (state.pickup_present(&w.gs, 0)) step(&w, &L, .{ .{ .up = true }, .{} });
    try testing.expectEqual(@as(u8, 48), w.m.players[0].ammo_zapper);
    try testing.expectEqual(pickup_respawn - 1, w.m.pickup_timer[0]); // counted on the pickup tick
    // Stepping off and back on does nothing until it respawns.
    run(&w, &L, .{ .{ .down = true }, .{} }, 30);
    run(&w, &L, idle, pickup_respawn - 32);
    try testing.expect(!state.pickup_present(&w.gs, 0));
    step(&w, &L, idle);
    try testing.expect(state.pickup_present(&w.gs, 0));
    try testing.expectEqual(@as(u16, 0), w.m.pickup_timer[0]);
    try testing.expectEqual(@as(u8, 48), w.m.players[0].ammo_zapper);
}

test "players cannot walk through each other" {
    var st: level_parse.Parsed = undefined;
    const L = try hall(&st);
    var w: World = undefined;
    new_world(&w, &L, false);
    run(&w, &L, .{ .{ .up = true }, .{ .up = true } }, 200);
    const gap = w.m.players[1].x - w.m.players[0].x;
    try testing.expect(gap >= body - sim.walk_speed);
    try testing.expect(gap < body + sim.walk_speed);
    try testing.expectEqual(w.m.players[0].y, w.m.players[1].y);
}

test "a bug chases and bites the nearer player, a door holds for player 1" {
    var st: level_parse.Parsed = undefined;
    const L = try hall(&st);
    var w: World = undefined;
    new_world(&w, &L, true);
    // Player 1 stands in the doorway above the gnat; player 0 far away.
    w.m.players[1].x = fixed.from_float(5.5);
    w.m.players[1].y = fixed.from_float(4.5);
    w.gs.doors[0] = .{ .open = 255, .timer = 1, .phase = sim.door_open };
    var n: usize = 0;
    while (w.m.players[1].hp == 100 and n < 600) : (n += 1) step(&w, &L, idle);
    try testing.expect(w.m.players[1].hp < 100);
    try testing.expectEqual(state.by_bug, w.m.last_hit[1]);
    try testing.expectEqual(@as(i16, 100), w.m.players[0].hp);
    try testing.expectEqual(@as(u8, sim.door_open), w.gs.doors[0].phase);
}

test "a bug frag scores nobody; bugs respawn after 20 s" {
    var st: level_parse.Parsed = undefined;
    const L = try hall(&st);
    var w: World = undefined;
    new_world(&w, &L, true);
    w.m.players[1].hp = 1;
    w.m.last_hit[1] = state.by_bug;
    w.m.players[1].hp = 0;
    step(&w, &L, idle);
    try testing.expectEqual(death_ticks, w.m.dead[1]);
    try testing.expectEqual(@as(i16, 0), w.m.frags[0]);
    try testing.expectEqual(@as(i16, 0), w.m.frags[1]);
    try testing.expectEqual(state.by_bug, w.m.killer);
    // Kill the gnat by hand; it comes back at its cell after bug_respawn.
    sim.damage_enemy(&w.gs, 0, 99);
    while (w.gs.enemies[0].state != .dead) step(&w, &L, idle);
    run(&w, &L, idle, bug_respawn); // the timer starts the tick after the death frame
    try testing.expect(!sim.living(&w.gs.enemies[0]));
    step(&w, &L, idle);
    try testing.expect(sim.living(&w.gs.enemies[0]));
    try testing.expectEqual(fixed.from_float(5.5), w.gs.enemies[0].x);
}

test "the frag limit ends the match; a finished match does not move" {
    var st: level_parse.Parsed = undefined;
    const L = try hall(&st);
    var w: World = undefined;
    new_world(&w, &L, false);
    w.m.frags[0] = 4;
    w.m.players[1].hp = 18;
    step(&w, &L, .{ .{ .a = true }, .{} });
    try testing.expect(w.m.over);
    try testing.expectEqual(@as(u8, 0), w.m.winner);
    try testing.expectEqual(@as(i16, 5), w.m.frags[0]);
    const h = hash(&w);
    run(&w, &L, .{ .{ .up = true, .a = true }, .{ .up = true } }, 50);
    try testing.expectEqual(h, hash(&w));
    // Forfeit: the stayer wins.
    new_world(&w, &L, false);
    forfeit(&w, 0);
    try testing.expect(w.m.over and w.m.forfeit);
    try testing.expectEqual(@as(u8, 1), w.m.winner);
}

test "a double frag at the limit is a draw" {
    var st: level_parse.Parsed = undefined;
    const L = try hall(&st);
    var w: World = undefined;
    new_world(&w, &L, false);
    w.m.frags[0] = 4;
    w.m.frags[1] = 4;
    w.m.players[0].hp = 18;
    w.m.players[1].hp = 18;
    step(&w, &L, .{ .{ .a = true }, .{ .a = true } });
    try testing.expect(w.m.over);
    try testing.expectEqual(state.no_one, w.m.winner);
    try testing.expectEqual([2]i16{ 5, 5 }, w.m.frags[0..2].*);
}

test "both arenas run a long random match with bugs, the same twice" {
    for (0..levels.arena_indices.len) |ai_| {
        var hs: [2]u32 = undefined;
        for (&hs) |*h| {
            var w: World = undefined;
            init_rules(&w, .{ .arena = @intCast(ai_), .frags = 3, .bugs = true }, 77);
            try testing.expect(w.m.players[0].x != w.m.players[1].x or w.m.players[0].y != w.m.players[1].y);
            var x: u32 = 5;
            for (0..6000) |_| {
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                // Mostly walking and shooting, now and then strafing.
                const in = [2]Buttons{ buttons_of(@truncate((x & 0x3B) | 0x01)), buttons_of(@truncate(((x >> 8) & 0x3B) | 0x01)) };
                step(&w, arena_level(@intCast(ai_)), in);
            }
            try testing.expect(w.m.shots[0] > 0 and w.m.shots[1] > 0);
            h.* = hash(&w);
        }
        try testing.expectEqual(hs[0], hs[1]);
    }
}

test "G: the lockstep's simulate is step on the arena, hand_over a forfeit" {
    var a: World = undefined;
    var b: World = undefined;
    init_rules(&a, .{ .arena = 1, .bugs = true }, 3);
    b = a;
    for (0..200) |i| {
        const x: u8 = @truncate(i *% 37);
        G.simulate(&a, .{ x & 0x3F, (x >> 1) & 0x3F });
        step(&b, arena_level(1), .{ buttons_of(x & 0x3F), buttons_of((x >> 1) & 0x3F) });
    }
    try testing.expectEqual(G.hash(&a), G.hash(&b));
    try testing.expectEqual(@as(u32, 200), a.gs.tick);
    G.hand_over(&a, 1);
    try testing.expect(a.m.over and a.m.forfeit);
    try testing.expectEqual(@as(u8, 0), a.m.winner);
    try testing.expectEqual(@as(?u8, bit_start), G.pause_bit);
}

test "the same inputs give the same World, whatever was in memory" {
    var st: level_parse.Parsed = undefined;
    const L = try hall(&st);
    var a: World = undefined;
    var b: World = undefined;
    @memset(std.mem.asBytes(&a), 0xAA);
    @memset(std.mem.asBytes(&b), 0x55);
    new_world(&a, &L, true);
    new_world(&b, &L, true);
    var x: u32 = 99;
    for (0..3000) |_| {
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        const in = [2]Buttons{ buttons_of(@truncate(x)), buttons_of(@truncate(x >> 8)) };
        step(&a, &L, in);
        step(&b, &L, in);
    }
    try testing.expectEqual(hash(&a), hash(&b));
    try testing.expect(std.mem.eql(u8, std.mem.asBytes(&a), std.mem.asBytes(&b)));
}

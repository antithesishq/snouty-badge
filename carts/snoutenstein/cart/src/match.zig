//! Deathmatch rules (M7, SPEC.md section 19): two players in one arena,
//! one tick at a time from both players' input bytes. Pure over `World`,
//! fixed point only, no cart-api, no clock: both badges run it in lockstep
//! (`lib/lockstep.zig`, glue in `deathmatch.zig`) and must stay bit-equal.
//!
//! `World` is the campaign's GameState (doors, bugs, projectiles, pickup
//! bits, the PRNG) plus `state.Match` (the two players, frags, timers).
//! The campaign code works on `GameState.player`, so `step` swaps each
//! player into that slot in turn: movement, pickups, the weapon, and each
//! bug's tick against the player it targets (the nearer living one). The
//! campaign path (`sim.step`) is untouched by all of this.
//!
//! Tick order: hurt flashes, death views and respawns; movement and
//! pickups (the first mover alternates by tick parity); doors; bugs
//! (BUGS ON); projectiles; both weapons from the same positions, their
//! damage applied after both fired (a double frag is possible); deaths,
//! frags and the frag limit; pickup timers.
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const projectiles = @import("projectiles.zig");

const Fixed = fixed.Fixed;
const GameState = state.GameState;
const Match = state.Match;
const Player = state.Player;
const Buttons = state.Buttons;
const Level = levels.Level;

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
/// The lobby's FRAGS row.
pub const frag_limits = [4]u8{ 5, 10, 15, 20 };

// ---------------------------------------------------------------- rules and input

/// The host's lobby choice, one byte on the wire: arena bits 0-1, frag
/// limit index bits 2-3, bugs bit 4.
pub const Rules = struct {
    arena: u8 = 0,
    frags: u8 = 1,
    bugs: bool = false,

    pub fn encode(r: Rules) u8 {
        return (r.arena & 3) | ((r.frags & 3) << 2) | (@as(u8, @intFromBool(r.bugs)) << 4);
    }
    pub fn decode(b: u8) Rules {
        const a = b & 3;
        return .{ .arena = if (a < levels.arena_indices.len) a else 0, .frags = (b >> 2) & 3, .bugs = b & 0x10 != 0 };
    }
    pub fn frag_limit(r: Rules) u8 {
        return frag_limits[r.frags & 3];
    }
};

/// The input byte both badges exchange: Up, Down, Left, Right, A, B,
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

pub fn arena_level(arena: u8) *const Level {
    return &levels.all[levels.arena_indices[arena]];
}

// ---------------------------------------------------------------- setup

/// A fresh match on `level` (`levels.all[level_index]`): the campaign's
/// `sim.init` for doors, pickups and bugs (cleared when BUGS is off),
/// player 0 on the first spawn, player 1 on the spawn farthest from it.
pub fn init(w: *World, level: *const Level, level_index: u8, rules: Rules, seed: u32) void {
    std.debug.assert(level.pickups.len <= state.max_match_pickups);
    sim.init(&w.gs, level, level_index, seed);
    if (!rules.bugs) {
        for (&w.gs.enemies) |*e| e.* = .{};
    }
    const sp0 = spawn_at(level, 0);
    w.m = .{
        .players = .{ fresh(sp0), fresh(sp0) },
        .arena = rules.arena,
        .frag_limit = rules.frag_limit(),
        .bugs = rules.bugs,
    };
    w.m.players[1] = fresh(farthest_spawn(level, w.m.players[0].x, w.m.players[0].y));
    w.gs.player = w.m.players[0];
}

/// `init` from the lobby's rules (the arena picks the level).
pub fn init_rules(w: *World, rules: Rules, seed: u32) void {
    init(w, arena_level(rules.arena), levels.arena_indices[rules.arena], rules, seed);
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

/// The spawn whose centre is farthest from (x, y); the first wins a tie.
pub fn farthest_spawn(level: *const Level, x: Fixed, y: Fixed) levels.Spawn {
    var best: usize = 0;
    var best_d: i64 = -1;
    for (0..spawn_count(level)) |i| {
        const sp = spawn_at(level, i);
        const d = dist2(fixed.from_int(sp.x) + fixed.half - x, fixed.from_int(sp.y) + fixed.half - y);
        if (d > best_d) {
            best = i;
            best_d = d;
        }
    }
    return spawn_at(level, best);
}

/// The other badge left (the lockstep's hand-over): the match ends, the
/// player who stayed wins by forfeit.
pub fn forfeit(w: *World, gone: u1) void {
    if (w.m.over) return;
    w.m.over = true;
    w.m.forfeit = true;
    w.m.winner = gone ^ 1;
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

/// `rival.png` cell for the other player `r` seen from `viewer`: 0 front
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
    return m.dead[slot] == 0 and m.players[slot].hp > 0;
}

// ---------------------------------------------------------------- step

/// One tick. `in[0]` is the host's buttons, `in[1]` the guest's. A
/// finished match takes no input and does not move.
pub fn step(w: *World, level: *const Level, in: [2]Buttons) void {
    const s = &w.gs;
    const m = &w.m;
    if (m.over) return;
    s.last_locked = 0;
    for (&m.hurt) |*h| h.* -|= 1;
    for (0..2) |i| {
        if (m.dead[i] == 0) continue;
        m.dead[i] -= 1;
        if (m.dead[i] == 0) respawn(w, level, @intCast(i));
    }

    const first: u1 = @truncate(s.tick);
    move(w, level, first, in[first]);
    move(w, level, first ^ 1, in[first ^ 1]);

    s.player = m.players[0];
    sim.update_doors(s, level, &m.players[1]);
    if (m.bugs) bugs(w, level);
    projectiles.update_match(s, level, m, pvp_scale);

    // Both weapons from the same positions; damage lands after both fired.
    var rivals: [2]sim.Rival = undefined;
    for (0..2) |i| {
        const o = &m.players[i ^ 1];
        rivals[i] = .{ .x = o.x, .y = o.y, .alive = alive(m, i ^ 1), .tag = @intCast(i + 1) };
        if (!alive(m, i)) continue;
        swap_in(w, i);
        sim.update_weapon(s, level, in[i], &rivals[i]);
        swap_out(w, i);
        if (rivals[i].fired) m.shots[i] +%= 1;
    }
    for (0..2) |i| {
        const d = rivals[i].damage;
        if (d > 0 and sim.damage_slot(m, @intCast(i ^ 1), d * pvp_scale, @intCast(i))) m.hits[i] +%= 1;
    }

    var died = false;
    for (0..2) |i| {
        if (m.dead[i] == 0 and m.players[i].hp <= 0) {
            die(w, @intCast(i));
            died = true;
        }
    }
    if (died) check_over(m);
    tick_pickups(w, level);
    m.players[0].prev = in[0];
    m.players[1].prev = in[1];
    s.tick +%= 1;
    s.player = m.players[0];
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

/// Turn or strafe (B held), walk, keep clear of the other player, then
/// the pickups under the player.
fn move(w: *World, level: *const Level, i: u1, b: Buttons) void {
    const s = &w.gs;
    const m = &w.m;
    if (!alive(m, i)) return;
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
        const o = &m.players[i ^ 1];
        if (alive(m, i ^ 1)) {
            const now = dist2(p.x - o.x, p.y - o.y);
            if (now < sq(body) and now < dist2(x0 - o.x, y0 - o.y)) {
                p.x = x0;
                p.y = y0;
            }
        }
    }
    const cx = fixed.to_int(p.x);
    const cy = fixed.to_int(p.y);
    const n = @min(level.pickups.len, state.max_match_pickups);
    for (level.pickups[0..n], 0..) |pk, k| {
        if (pk.x != cx or pk.y != cy or !state.pickup_present(s, k)) continue;
        sim.apply_pickup(p, pk.kind);
        state.take_pickup(s, k);
        m.pickup_timer[k] = pickup_respawn;
    }
    swap_out(w, i);
}

/// The nearer living player to (x, y); player 0 on a tie or when neither lives.
fn target(m: *const Match, x: Fixed, y: Fixed) usize {
    const a0 = alive(m, 0);
    const a1 = alive(m, 1);
    if (a0 != a1) return if (a0) 0 else 1;
    const d0 = dist2(m.players[0].x - x, m.players[0].y - y);
    const d1 = dist2(m.players[1].x - x, m.players[1].y - y);
    return if (d1 < d0) 1 else 0;
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
    for (0..2) |i| {
        if (alive(m, i) and dist2(m.players[i].x - x, m.players[i].y - y) < sq(bug_respawn_clear)) return false;
    }
    return true;
}

/// At 0 HP: the death view, and the frag to whoever hurt the player last
/// (-1 for a self-frag, nothing for a bug).
fn die(w: *World, i: u1) void {
    const m = &w.m;
    m.dead[i] = death_ticks;
    m.deaths[i] +%= 1;
    m.players[i].frozen = 0;
    const k = m.last_hit[i];
    if (k == i) {
        m.frags[i] -= 1;
    } else if (k == i ^ 1) {
        m.frags[k] += 1;
    }
    m.victim = i;
    m.killer = k;
    m.kill_tick = w.gs.tick;
}

fn check_over(m: *Match) void {
    const lim: i16 = m.frag_limit;
    const r0 = m.frags[0] >= lim;
    const r1 = m.frags[1] >= lim;
    if (!r0 and !r1) return;
    m.over = true;
    if (r0 and r1) {
        m.winner = if (m.frags[0] > m.frags[1]) 0 else if (m.frags[1] > m.frags[0]) 1 else state.no_one;
    } else {
        m.winner = if (r0) 0 else 1;
    }
}

/// After the death view: full HP and the starting loadout at the spawn
/// farthest from the other player, with a moment of spawn protection.
fn respawn(w: *World, level: *const Level, i: u1) void {
    const m = &w.m;
    const o = &m.players[i ^ 1];
    const prev = m.players[i].prev;
    m.players[i] = fresh(farthest_spawn(level, o.x, o.y));
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
    w.m.frags = .{ 4, 4 };
    w.m.players[0].hp = 18;
    w.m.players[1].hp = 18;
    step(&w, &L, .{ .{ .a = true }, .{ .a = true } });
    try testing.expect(w.m.over);
    try testing.expectEqual(state.no_one, w.m.winner);
    try testing.expectEqual([2]i16{ 5, 5 }, w.m.frags);
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

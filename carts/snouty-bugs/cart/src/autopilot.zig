//! Bots that fly the ship (PLAN.md M7 "Probe (track D)"): the difficulty
//! probe's stand-ins for a player, and the dodger is the seed of M8's
//! attract-mode autopilot (SPEC.md 8.1). A bot only returns a
//! `cart.Controls`; `main.update` feeds it through the normal input path,
//! so history logs it like any other input and rewinds replay it exactly.
//!
//! Bots never touch the World and never draw from the world rng (the
//! noise is a hash of the tick). The dodger keeps a little state of its
//! own outside the World (the enemy positions it saw on the previous tick,
//! to estimate their velocities, and the move it committed to); it is
//! reset whenever the tick it is given is not the next one (a new game, a
//! rewind), so the same game always gets the same controls.
//!
//!   1 turret: holds A, never moves.
//!   2 sweep:  holds A; up 40 ticks, still 20, down 40, still 20 (the M2 sweep).
//!   3 dodger: holds A; every `replan_every` ticks picks the cheapest of 25
//!             short moves (a 5x5 grid of target offsets) by a danger map
//!             built from the straight-line paths of every enemy bullet and
//!             enemy over the next `lookahead` ticks, nearer ticks weighted
//!             more, plus small pulls toward crates, toward lining up a
//!             shot and toward the left-center, plus a little noise; then
//!             flies that move until the next plan. It stands in for a
//!             decent human, so it has human limits (`skill` below).
const cart = @import("cart-api");
const world = @import("world.zig");
const player = @import("player.zig");
const bullets = @import("bullets.zig");
const pickups = @import("pickups.zig");

pub const Bot = enum(u8) { off = 0, turret = 1, sweep = 2, dodger = 3 };

const no_buttons: cart.Controls = @bitCast(@as(u16, 0));

/// The controls bot `bot` (a `Bot` value; unknown values press nothing)
/// wants for the tick `tick` about to be simulated.
/// Never inlined, nor is `dodge`: their frames then live on the stack only
/// while they run, not in `main.update`'s, which already holds a World
/// temporary at a new game (the wasm shadow stack is 14.7 KB).
pub noinline fn controls(bot: u8, tick: u32) cart.Controls {
    var c = no_buttons;
    switch (bot) {
        @backingInt(Bot.turret) => c.a = true,
        @backingInt(Bot.sweep) => {
            c.a = true;
            const phase = tick % 120;
            if (phase < 40) c.up = true else if (phase >= 60 and phase < 100) c.down = true;
        },
        @backingInt(Bot.dodger) => c = dodge(tick),
        else => {},
    }
    return c;
}

// ---------------------------------------------------------------- dodger
//
// Skill: the one knob. 0 = a beginner, 1 = sharp. The dodger never sees
// drag, acceleration, turns, splits or re-aims coming (it extrapolates
// straight lines), and at the default 0.5 it never notices a quarter of
// the bullets, does not see the others until they are 12 ticks old (a
// 200 ms reaction time), re-plans every 7 ticks (committing to its move
// in between), looks 22 ticks ahead and adds up to 0.3 of noise to every
// move's cost (a near miss costs about 1). The derived constants can be
// set directly. Of these the missed share moves the hit count most.
pub const skill: f32 = 0.5;
/// Ticks a bullet must have flown before the dodger reacts to it (20 at
/// skill 0, 4 at skill 1).
const reaction: u32 = @intFromFloat(@round(20 - 16 * skill));
/// Share of bullets the dodger never notices (attention: a busy screen
/// hides some), drawn once per bullet from a hash of its slot and spawn
/// tick (0.5 at skill 0, none at skill 1).
const miss_rate: f32 = 0.5 * (1 - skill);
/// Ticks between plans (10 at skill 0, 4 at skill 1).
const replan_every: u32 = @intFromFloat(@round(10 - 6 * skill));
/// Ticks of foresight (14 at skill 0, 30 at skill 1).
const lookahead: f32 = 14 + 16 * skill;
/// Cost noise per move and plan (0.6 at skill 0, none at skill 1).
const noise: f32 = 0.6 * (1 - skill);

// The other knobs. Cost units: a bullet grazing the soft margin in the
// next few ticks costs up to 1; a predicted hit adds `hit_cost`.

/// Ship speed per axis (player.zig `speed`); the diagonal is not
/// normalised, so each axis moves independently.
const ship_speed: f32 = 1.5;
/// Ship cell bounds (player.zig `min_x` .. `max_y`).
const ship_min_x: f32 = 0;
const ship_max_x: f32 = 104;
const ship_min_y: f32 = 10;
const ship_max_y: f32 = 101;
/// Where the dodger likes to sit (cell top-left): the spawn point.
const home_x: f32 = 16;
const home_y: f32 = 52;

/// Candidate target offsets from the current cell position, per axis.
const offsets = [5]f32{ -24, -12, 0, 12, 24 };
const n_cand = offsets.len * offsets.len;
/// The middle candidate: stay.
const stay = n_cand / 2;
/// Predicted ticks, as fractions of `lookahead`; consecutive pairs are the
/// segments a path is tested on.
const sample_frac = [6]f32{ 0, 0.14, 0.3, 0.5, 0.75, 1 };
const sample_t: [sample_frac.len]f32 = blk: {
    var t: [sample_frac.len]f32 = undefined;
    for (&t, sample_frac) |*v, f| v.* = @round(f * lookahead);
    break :blk t;
};
const n_seg = sample_t.len - 1;
/// Weight of each segment: 1 / (1 + t_start / 5), near ticks count more.
const seg_weight: [n_seg]f32 = blk: {
    var w: [n_seg]f32 = undefined;
    for (&w, 0..) |*v, k| v.* = 1 / (1 + sample_t[k] / 5);
    break :blk w;
};
/// Soft margin around the hitbox for each segment: 3 + 0.2 * t_end px.
/// The farther ahead, the less a prediction is worth trusting.
const seg_margin: [n_seg]f32 = blk: {
    var m: [n_seg]f32 = undefined;
    for (&m, 0..) |*v, k| v.* = 3 + 0.2 * sample_t[k + 1];
    break :blk m;
};
/// Extra cost of a predicted overlap with the real hitbox, per segment weight.
const hit_cost: f32 = 6;
/// Pad (px) on the hard half-extents (a predicted hit).
const hard_pad: f32 = 0.5;
/// Pull toward home: per squared px of the target's distance from it.
const home_x_cost: f32 = 0.00005;
const home_y_cost: f32 = 0.0003;
/// Walls trap: a target within `edge_px` of the top or bottom bound, or
/// `edge_px_x` of the left one, costs up to `edge_cost`.
const edge_cost: f32 = 0.6;
const edge_px: f32 = 20;
const edge_px_x: f32 = 12;
/// Reward for a target that lines the nose up with an enemy ahead
/// (big ones, the boss and midboss, count more).
const aim_reward: f32 = 0.2;
const aim_reward_big: f32 = 0.4;
/// Reward for a target near a crate (L1 px over which it fades out), and
/// the crate's predicted drift (pickups.zig `drift`) over `crate_lead` ticks.
const crate_reward: f32 = 1.2;
const crate_range: f32 = 100;
const crate_lead: f32 = 15;
const crate_drift: f32 = 0.5;
/// A small bonus for staying put, so equal options do not dither.
const stay_bonus: f32 = 0.01;
/// Enemy velocities above this (px per tick, per axis) are slot reuse or
/// a teleport, not motion.
const max_enemy_speed: f32 = 4;

const n_enemies = @typeInfo(@FieldType(world.World, "enemies")).array.len;

// Dodger state outside the World (see the file comment).
var prev_x: [n_enemies]f32 = @splat(0);
var prev_y: [n_enemies]f32 = @splat(0);
var prev_live: [n_enemies]bool = @splat(false);
var enemy_vx: [n_enemies]f32 = @splat(0);
var enemy_vy: [n_enemies]f32 = @splat(0);
var prev_tick: u32 = 0;
var have_prev: bool = false;
/// The committed move: its target (cell top-left) and the tick it was
/// planned on.
var target_x: f32 = 0;
var target_y: f32 = 0;
var plan_tick: u32 = 0;
var have_plan: bool = false;

// Per-call scratch (module level, not on the stack).
/// Hitbox center x of the candidates in column i (x offset i) and center
/// y of those in row j (y offset j), at each sample tick: candidate
/// c = j * 5 + i moves the two axes independently.
var col_x: [offsets.len][sample_t.len]f32 = undefined;
var row_y: [offsets.len][sample_t.len]f32 = undefined;
var danger: [n_cand]f32 = undefined;

fn sign(v: f32) f32 {
    return if (v > 0) 1 else if (v < 0) -1 else 0;
}

fn clamp(v: f32, lo: f32, hi: f32) f32 {
    return @min(@max(v, lo), hi);
}

/// A hash of the tick and a candidate in [0, 1].
fn hash01(a: u32, b: u32) f32 {
    var h = a *% 0x9E3779B1 ^ b *% 0x85EBCA77;
    h ^= h >> 15;
    h *%= 0x2C1B3C6D;
    h ^= h >> 12;
    return @as(f32, @floatFromInt(h & 1023)) / 1023.0;
}

/// Velocity of each live enemy from its position on the previous tick.
fn track_enemies(tick: u32) void {
    if (have_prev and tick == prev_tick) return;
    const consecutive = have_prev and tick == prev_tick +% 1;
    if (!consecutive) have_plan = false;
    for (world.w.enemies, 0..) |e, i| {
        const live = e.live();
        var vx: f32 = 0;
        var vy: f32 = 0;
        if (live and consecutive and prev_live[i]) {
            vx = e.x - prev_x[i];
            vy = e.y - prev_y[i];
            if (@abs(vx) > max_enemy_speed or @abs(vy) > max_enemy_speed) {
                vx = 0;
                vy = 0;
            }
        }
        enemy_vx[i] = vx;
        enemy_vy[i] = vy;
        prev_x[i] = e.x;
        prev_y[i] = e.y;
        prev_live[i] = live;
    }
    prev_tick = tick;
    have_prev = true;
}

/// The part of the segment s in [0, 1] where |a + (b - a) s| < r (soft
/// radius 1) and where it is < `rh` (hard), as [lo, hi) pairs; empty when
/// lo >= hi.
const Spans = struct { lo: f32, hi: f32, hard_lo: f32, hard_hi: f32 };

fn spans(a: f32, b: f32, rh: f32) Spans {
    const d = b - a;
    if (@abs(d) < 1e-6) {
        const soft: f32 = if (@abs(a) < 1) 1 else 0;
        const hard: f32 = if (@abs(a) < rh) 1 else 0;
        return .{ .lo = 0, .hi = soft, .hard_lo = 0, .hard_hi = hard };
    }
    const inv = 1 / d;
    const s0 = (-1 - a) * inv;
    const s1 = (1 - a) * inv;
    const h0 = (-rh - a) * inv;
    const h1 = (rh - a) * inv;
    return .{
        .lo = @max(@min(s0, s1), 0),
        .hi = @min(@max(s0, s1), 1),
        .hard_lo = @max(@min(h0, h1), 0),
        .hard_hi = @min(@max(h0, h1), 1),
    };
}

/// Adds one moving object's danger to every candidate. (px, py) are its
/// predicted centers at the sample ticks; (hx, hy) the half-extents of
/// its box plus the ship's hitbox (a center inside them is a hit); (cx,
/// cy) the ship's hitbox center now.
///
/// Per segment, in units of the soft box (hard box + margin), the
/// relative path of each column (x) and each row (y) is a line; the
/// candidate's path is inside the soft box while both are within 1, an
/// interval of the segment. Its depth there (the max norm at the
/// interval's middle) gives the cost, and an overlap with the hard box
/// adds `hit_cost`. Exact for boxes, and only 10 divisions a segment.
fn add_threat(px: *const [sample_t.len]f32, py: *const [sample_t.len]f32, hx: f32, hy: f32, cx: f32, cy: f32) void {
    // Whole path out of reach of every candidate: skip it.
    const reach = offsets[offsets.len - 1] + hx + seg_margin[n_seg - 1];
    const reach_y = offsets[offsets.len - 1] + hy + seg_margin[n_seg - 1];
    var lo_x = px[0];
    var hi_x = px[0];
    var lo_y = py[0];
    var hi_y = py[0];
    for (px[1..], py[1..]) |x, y| {
        lo_x = @min(lo_x, x);
        hi_x = @max(hi_x, x);
        lo_y = @min(lo_y, y);
        hi_y = @max(hi_y, y);
    }
    if (hi_x < cx - reach or lo_x > cx + reach or hi_y < cy - reach_y or lo_y > cy + reach_y) return;

    for (0..n_seg) |k| {
        const m = seg_margin[k];
        const ax = hx + m;
        const ay = hy + m;
        // Segment out of reach of every candidate at its end tick: skip.
        const r = @min(ship_speed * sample_t[k + 1], offsets[offsets.len - 1]);
        if (@max(px[k], px[k + 1]) < cx - r - ax or @min(px[k], px[k + 1]) > cx + r + ax or
            @max(py[k], py[k + 1]) < cy - r - ay or @min(py[k], py[k + 1]) > cy + r + ay) continue;
        const inv_ax = 1 / ax;
        const inv_ay = 1 / ay;
        const wgt = seg_weight[k];
        var cu: [offsets.len]Spans = undefined;
        var col_u0: [offsets.len]f32 = undefined;
        var col_du: [offsets.len]f32 = undefined;
        var any_col = false;
        for (0..offsets.len) |i| {
            col_u0[i] = (px[k] - col_x[i][k]) * inv_ax;
            col_du[i] = (px[k + 1] - col_x[i][k + 1]) * inv_ax - col_u0[i];
            cu[i] = spans(col_u0[i], col_u0[i] + col_du[i], (hx + hard_pad) * inv_ax);
            any_col = any_col or cu[i].lo < cu[i].hi;
        }
        if (!any_col) continue;
        for (0..offsets.len) |j| {
            const v0 = (py[k] - row_y[j][k]) * inv_ay;
            const dv = (py[k + 1] - row_y[j][k + 1]) * inv_ay - v0;
            const rv = spans(v0, v0 + dv, (hy + hard_pad) * inv_ay);
            if (rv.lo >= rv.hi) continue;
            for (0..offsets.len) |i| {
                const lo = @max(cu[i].lo, rv.lo);
                const hi = @min(cu[i].hi, rv.hi);
                if (lo >= hi) continue;
                const mid = (lo + hi) / 2;
                const d = @max(@abs(col_u0[i] + col_du[i] * mid), @abs(v0 + dv * mid));
                var cost = wgt * (1 - d * d);
                if (@max(cu[i].hard_lo, rv.hard_lo) < @min(cu[i].hard_hi, rv.hard_hi)) cost += wgt * hit_cost;
                danger[j * offsets.len + i] += cost;
            }
        }
    }
}

/// Flies the committed move, re-planning when it is due. Never inlined
/// (see `controls`).
noinline fn dodge(tick: u32) cart.Controls {
    track_enemies(tick);
    if (!have_plan or tick -% plan_tick >= replan_every) plan(tick);
    const p = &world.w.player;
    var out = no_buttons;
    out.a = true;
    const dx = target_x - p.x;
    const dy = target_y - p.y;
    const deadband = ship_speed / 2;
    if (dx > deadband) out.right = true else if (dx < -deadband) out.left = true;
    if (dy > deadband) out.down = true else if (dy < -deadband) out.up = true;
    return out;
}

/// Picks the move to commit to until the next plan.
fn plan(tick: u32) void {
    const p = &world.w.player;
    const hb = player.hitbox();
    const half_w = hb[2] / 2;
    const half_h = hb[3] / 2;
    const cx = hb[0] + half_w;
    const cy = hb[1] + half_h;

    // Candidate paths: each axis moves toward its (clamped) target at
    // ship speed and stops there.
    for (offsets, 0..) |o, i| {
        const dx = clamp(p.x + o, ship_min_x, ship_max_x) - p.x;
        const dy = clamp(p.y + o, ship_min_y, ship_max_y) - p.y;
        for (sample_t, 0..) |t, k| {
            const step = ship_speed * t;
            col_x[i][k] = cx + sign(dx) * @min(step, @abs(dx));
            row_y[i][k] = cy + sign(dy) * @min(step, @abs(dy));
        }
    }
    danger = @splat(0);

    var px: [sample_t.len]f32 = undefined;
    var py: [sample_t.len]f32 = undefined;
    for (world.w.enemy_bullets, 0..) |b, i| {
        if (!b.active or b.age < reaction) continue;
        if (hash01(@intCast(i), tick -% @as(u32, @intCast(b.age))) < miss_rate) continue;
        predict_bullet(b, &px, &py);
        const bb = bullets.hitbox(b);
        add_threat(&px, &py, half_w + bb[2] / 2, half_h + bb[3] / 2, cx, cy);
    }
    for (world.w.enemies, 0..) |e, i| {
        if (!e.live()) continue;
        const s = e.size();
        const ex = e.x + s[0] / 2;
        const ey = e.y + s[1] / 2;
        for (sample_t, 0..) |t, k| {
            px[k] = ex + enemy_vx[i] * t;
            py[k] = ey + enemy_vy[i] * t;
        }
        add_threat(&px, &py, half_w + s[0] / 2, half_h + s[1] / 2, cx, cy);
    }

    // Preferences at each candidate's target.
    var best: usize = stay;
    var best_cost: f32 = 0;
    for (0..n_cand) |c| {
        const tx = clamp(p.x + offsets[c % offsets.len], ship_min_x, ship_max_x);
        const ty = clamp(p.y + offsets[c / offsets.len], ship_min_y, ship_max_y);
        var cost = danger[c];
        cost += home_x_cost * (tx - home_x) * (tx - home_x) + home_y_cost * (ty - home_y) * (ty - home_y);
        cost += edge_cost * (@max(0, 1 - (ty - ship_min_y) / edge_px) + @max(0, 1 - (ship_max_y - ty) / edge_px) +
            @max(0, 1 - (tx - ship_min_x) / edge_px_x));
        cost -= aim_bonus(tx, ty);
        cost -= crate_bonus(tx, ty);
        cost += noise * hash01(tick, @intCast(c));
        if (c == stay) cost -= stay_bonus;
        if (c == 0 or cost < best_cost) {
            best = c;
            best_cost = cost;
        }
    }

    target_x = clamp(p.x + offsets[best % offsets.len], ship_min_x, ship_max_x);
    target_y = clamp(p.y + offsets[best / offsets.len], ship_min_y, ship_max_y);
    plan_tick = tick;
    have_plan = true;
}

/// Predicted centers of an enemy bullet at the sample ticks: straight
/// lines from its velocity now. Drag, acceleration, turns, splits and
/// re-aims are not foreseen (a human reads a bullet's direction, not its
/// program).
fn predict_bullet(b: bullets.EnemyBullet, px: *[sample_t.len]f32, py: *[sample_t.len]f32) void {
    for (sample_t, 0..) |t, k| {
        px[k] = b.x + b.vx * t;
        py[k] = b.y + b.vy * t;
    }
}

/// The nose line (bolts leave at cell y + 12) crosses an enemy ahead.
fn aim_bonus(tx: f32, ty: f32) f32 {
    const nose_y = ty + 12;
    var bonus: f32 = 0;
    for (world.w.enemies) |e| {
        if (!e.live()) continue;
        const s = e.size();
        if (e.x + s[0] < tx + 36) continue;
        if (@abs(e.y + s[1] / 2 - nose_y) >= s[1] / 2 + 2) continue;
        bonus = @max(bonus, if (s[1] >= 32) aim_reward_big else aim_reward);
    }
    return bonus;
}

/// Nearness of the ship cell's center at the target to a crate's center
/// where the crate will be in `crate_lead` ticks.
fn crate_bonus(tx: f32, ty: f32) f32 {
    const half: f32 = pickups.size / 2;
    const scx = tx + player.cell_w / 2;
    const scy = ty + player.cell_h / 2;
    var bonus: f32 = 0;
    for (world.w.pickups) |k| {
        if (!k.active) continue;
        const kx = k.x + half - crate_drift * crate_lead;
        const ky = k.y + half;
        const d = @abs(kx - scx) + @abs(ky - scy);
        bonus = @max(bonus, crate_reward * (1 - @min(d / crate_range, 1)));
    }
    return bonus;
}

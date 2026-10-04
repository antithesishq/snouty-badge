//! Bots that fly the ship (PLAN.md M7 "Probe (track D)"): the difficulty
//! probe's stand-ins for a player, and the dodger is the seed of M8's
//! attract-mode autopilot (SPEC.md 8.1). A bot only returns a
//! `cart.Controls`; `main.update` feeds it through the normal input path,
//! so history logs it like any other input and rewinds replay it exactly.
//!
//! Bots never touch the World and never draw from the world rng (any
//! jitter is a hash of the tick). The dodger keeps a little state of its
//! own outside the World (the enemy positions it saw on the previous tick,
//! to estimate their velocities); it is reset whenever the tick it is
//! given is not the next one (a new game, a rewind), so the same game
//! always gets the same controls.
//!
//!   1 turret: holds A, never moves.
//!   2 sweep:  holds A; up 40 ticks, still 20, down 40, still 20 (the M2 sweep).
//!   3 dodger: holds A; picks, every tick, the cheapest of 25 short moves
//!             (a 5x5 grid of target offsets) by a danger map built from
//!             the predicted paths of every enemy bullet and enemy over the
//!             next 30 ticks, nearer ticks weighted more, plus small pulls
//!             toward crates, toward lining up a shot, and toward the
//!             left-center of the field.
const cart = @import("cart-api");
const world = @import("world.zig");
const player = @import("player.zig");
const bullets = @import("bullets.zig");
const pickups = @import("pickups.zig");

pub const Bot = enum(u8) { off = 0, turret = 1, sweep = 2, dodger = 3 };

const no_buttons: cart.Controls = @bitCast(@as(u16, 0));

/// The controls bot `bot` (a `Bot` value; unknown values press nothing)
/// wants for the tick `tick` about to be simulated.
pub fn controls(bot: u8, tick: u32) cart.Controls {
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
// Knobs, all in one place. Cost units: a bullet grazing the soft margin
// in the next 3 ticks costs up to 1; a predicted hit adds `hit_cost`.

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
/// Predicted ticks; consecutive pairs are the segments a path is tested on.
const sample_t = [7]f32{ 0, 3, 6, 10, 15, 21, 30 };
const n_seg = sample_t.len - 1;
/// Weight of each segment: 1 / (1 + t_start / 5), near ticks count more.
const seg_weight = [n_seg]f32{ 1.0, 0.625, 0.4545, 0.3333, 0.25, 0.1923 };
/// Soft margin around the hitbox for each segment: 3 + 0.2 * t_end px.
/// The farther ahead, the less a prediction is worth trusting.
const seg_margin = [n_seg]f32{ 3.6, 4.2, 5.0, 6.0, 7.2, 9.0 };
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
/// Tie-break jitter, a hash of the tick (re-drawn every 16 ticks).
const jitter: f32 = 0.04;
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

// Per-call scratch (module level, not on the stack).
/// Hitbox center of each candidate at each sample tick.
var cand_x: [n_cand][sample_t.len]f32 = undefined;
var cand_y: [n_cand][sample_t.len]f32 = undefined;
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

/// Adds one moving object's danger to every candidate. (px, py) are its
/// predicted centers at the sample ticks; (hx, hy) the half-extents of
/// its box plus the ship's hitbox (a center inside them is a hit); (cx,
/// cy) the ship's hitbox center now.
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
        // Soft-to-hard rescale of the normalized distance.
        const sx = ax / (hx + hard_pad);
        const sy = ay / (hy + hard_pad);
        const wgt = seg_weight[k];
        for (0..n_cand) |c| {
            // Relative path over the segment in margin-normalized units;
            // its closest point to the origin.
            const r_u0 = (px[k] - cand_x[c][k]) * inv_ax;
            const r_v0 = (py[k] - cand_y[c][k]) * inv_ay;
            const du = (px[k + 1] - cand_x[c][k + 1]) * inv_ax - r_u0;
            const dv = (py[k + 1] - cand_y[c][k + 1]) * inv_ay - r_v0;
            const dd = du * du + dv * dv;
            var s: f32 = 0;
            if (dd > 0) s = clamp(-(r_u0 * du + r_v0 * dv) / dd, 0, 1);
            // Boxes, not ellipses: the max norm at that point (corners
            // count; an ellipse lets a big body clip the ship).
            const qu = @abs(r_u0 + du * s);
            const qv = @abs(r_v0 + dv * s);
            const d = @max(qu, qv);
            if (d >= 1) continue;
            var cost = wgt * (1 - d * d);
            if (qu * sx < 1 and qv * sy < 1) cost += wgt * hit_cost;
            danger[c] += cost;
        }
    }
}

fn dodge(tick: u32) cart.Controls {
    track_enemies(tick);
    const p = &world.w.player;
    const hb = player.hitbox();
    const half_w = hb[2] / 2;
    const half_h = hb[3] / 2;
    const cx = hb[0] + half_w;
    const cy = hb[1] + half_h;

    // Candidate paths: each axis moves toward its (clamped) target at
    // ship speed and stops there.
    for (0..n_cand) |c| {
        const dx = clamp(p.x + offsets[c % offsets.len], ship_min_x, ship_max_x) - p.x;
        const dy = clamp(p.y + offsets[c / offsets.len], ship_min_y, ship_max_y) - p.y;
        for (sample_t, 0..) |t, k| {
            const step = ship_speed * t;
            cand_x[c][k] = cx + sign(dx) * @min(step, @abs(dx));
            cand_y[c][k] = cy + sign(dy) * @min(step, @abs(dy));
        }
        danger[c] = 0;
    }

    var px: [sample_t.len]f32 = undefined;
    var py: [sample_t.len]f32 = undefined;
    for (world.w.enemy_bullets) |b| {
        if (!b.active) continue;
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
        cost += jitter * hash01(tick >> 4, @intCast(c));
        if (c == stay) cost -= stay_bonus;
        if (c == 0 or cost < best_cost) {
            best = c;
            best_cost = cost;
        }
    }

    var out = no_buttons;
    out.a = true;
    const dx = clamp(p.x + offsets[best % offsets.len], ship_min_x, ship_max_x) - p.x;
    const dy = clamp(p.y + offsets[best / offsets.len], ship_min_y, ship_max_y) - p.y;
    const deadband = ship_speed / 2;
    if (dx > deadband) out.right = true else if (dx < -deadband) out.left = true;
    if (dy > deadband) out.down = true else if (dy < -deadband) out.up = true;
    return out;
}

/// Predicted centers of an enemy bullet at the sample ticks. Straight
/// lines, plus drag and acceleration when the bullet engine has them
/// (PLAN.md M7; turns, splits and re-aims are not foreseen: the dodger is
/// a decent player, not an oracle).
fn predict_bullet(b: bullets.EnemyBullet, px: *[sample_t.len]f32, py: *[sample_t.len]f32) void {
    const E = bullets.EnemyBullet;
    var drag: f32 = 1;
    var ax: f32 = 0;
    var ay: f32 = 0;
    if (comptime @hasField(E, "drag")) drag = b.drag;
    if (comptime @hasField(E, "ax")) ax = b.ax;
    if (comptime @hasField(E, "ay")) ay = b.ay;
    if (drag == 1) {
        for (sample_t, 0..) |t, k| {
            const acc = 0.5 * t * (t + 1);
            px[k] = b.x + b.vx * t + ax * acc;
            py[k] = b.y + b.vy * t + ay * acc;
        }
        return;
    }
    // Per tick v *= drag then x += v: after t ticks the path is
    // v * (d + d^2 + ... + d^t); d^t by a running product.
    var dt: f32 = 1;
    var t_prev: f32 = 0;
    for (sample_t, 0..) |t, k| {
        var n = t - t_prev;
        while (n > 0) : (n -= 1) dt *= drag;
        t_prev = t;
        const travel = drag * (1 - dt) / (1 - drag);
        const acc = 0.5 * t * (t + 1);
        px[k] = b.x + b.vx * travel + ax * acc;
        py[k] = b.y + b.vy * travel + ay * acc;
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

//! Ship: movement, banking, the weapon (M6: fuzzer, assert, bisect at
//! levels 1..5), the trail ring and the forks (ghost ships replaying it),
//! the retry shield, invulnerability, score, and the M7 power loss
//! (`on_rewound_hit`). The ship state is
//! `world.w.player`; the rewind stock and the rewind fuel are
//! meta-state kept in `main.zig` (PLAN.md M5: a rewind moves the World's
//! clock, so anything spent from inside the World would be refunded).
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");
const input = @import("input.zig");
const bullets = @import("bullets.zig");
const enemies = @import("enemies.zig");
const rng = @import("rng.zig");
const world = @import("world.zig");
const rank = @import("rank.zig");

pub const cell_w = 32;
pub const cell_h = 24;

// Hard-coded until the real ship sheet reports its own (PLAN.md M1).
// M7: 4x4 (was 6x6 at (14, 9)), same center.
const hitbox_off = [2]f32{ 15, 10 };
const thruster_off = [2]i32{ -6, 8 };
pub const hitbox_size: f32 = 4;

const speed: f32 = 1.5;
const min_x: f32 = 0;
const max_x: f32 = 104;
const min_y: f32 = 10;
const max_y: f32 = 125 - cell_h;
const spawn_x: f32 = 16;
const spawn_y: f32 = 64 - cell_h / 2;

const fire_interval: u32 = 6;
const bank_hold: u32 = 6;
pub const invuln_ticks: u32 = 120;
const score_cap: u32 = 999_999;

pub const Pose = enum(u32) { level = 0, up = 1, down = 2 };

/// The three weapons (PLAN.md M6 "Numbers"); the crate kinds 0..2 match.
pub const Weapon = enum(u8) { fuzzer, assert, bisect };
pub const max_level: u8 = 5;
pub const max_forks: u8 = 3;
/// Ghost k (1-based) replays the trail `fork_delay * k` ticks back.
pub const fork_delay: u32 = 24;
pub const trail_len = 80;
/// Ticks of `FLAKY, RETRYING` and of invulnerability after the shield pops.
pub const retry_ticks: u32 = 60;

/// One tick of the ship's history: the floor of its cell top-left and
/// whether it fired a volley that tick.
pub const TrailEntry = struct {
    x: u8 = 0,
    y: u8 = 0,
    fired: bool = false,
};

/// Ship state, stored in `world.w.player`. Defaults are the spawn values.
pub const State = struct {
    x: f32 = spawn_x,
    y: f32 = spawn_y,
    pose: Pose = .level,
    pose_age: u32 = 0,
    fire_cooldown: u32 = 0,
    invuln: u32 = 0,
    score: u32 = 0,
    /// Bullets grazed this game (each also scored 1 point). Rewound with
    /// the World; `main.zig` pays fuel for it against a meta high water.
    grazes: u32 = 0,
    /// Score at which the next extra rewind is due. The stock itself is
    /// meta (`main.zig` grants it, live only), but the threshold replays.
    next_rewind_score: u32 = 10_000,
    /// Ticks left of the `GO!` pop after a rewind resume.
    go_pop: u32 = 0,
    // M6 powerups: everything a crate grants lives here, in the World.
    weapon: Weapon = .fuzzer,
    level: u8 = 1,
    /// Ghost ships, 0..3.
    forks: u8 = 0,
    /// The retry shield, 0..1.
    shield: u8 = 0,
    /// Core hours crates collected (monotonic); `main.zig` pays fuel for
    /// them against a meta high water.
    cores: u32 = 0,
    /// Memory Leak beetles shot down by bolts this game; every second one
    /// drops a crate (PLAN.md M7).
    beetle_kills: u32 = 0,
    /// Hits taken in the endless probe mode (`debug_hits`); 0 otherwise.
    probe_hits: u32 = 0,
    /// Ticks left of the `FLAKY, RETRYING` pop after the shield took a hit.
    retry_pop: u32 = 0,
    /// The ship's position every tick, at `trail[tick % 80]`, recorded
    /// whether or not a fork exists (so a fork has history at once).
    trail: [trail_len]TrailEntry = @splat(.{}),
};

pub fn update() void {
    const p = &world.w.player;
    if (input.held(.left)) p.x -= speed;
    if (input.held(.right)) p.x += speed;
    if (input.held(.up)) p.y -= speed;
    if (input.held(.down)) p.y += speed;
    p.x = @min(@max(p.x, min_x), max_x);
    p.y = @min(@max(p.y, min_y), max_y);

    // Banking: a pose must be held for bank_hold ticks before it can change,
    // so tapping the stick does not flicker the sprite.
    const want: Pose = if (input.held(.up) and !input.held(.down))
        .up
    else if (input.held(.down) and !input.held(.up))
        .down
    else
        .level;
    p.pose_age +|= 1;
    if (want != p.pose and p.pose_age >= bank_hold) {
        p.pose = want;
        p.pose_age = 0;
    }

    if (p.fire_cooldown > 0) p.fire_cooldown -= 1;
    var fired = false;
    if (input.held(.a) and p.fire_cooldown == 0) {
        fire_volley(p.x, p.y);
        p.fire_cooldown = fire_interval;
        fired = true;
    }
    const t = world.w.game_tick;
    p.trail[t % trail_len] = .{
        .x = @intFromFloat(@floor(p.x)),
        .y = @intFromFloat(@floor(p.y)),
        .fired = fired,
    };
    // The ghosts fire after the ship, so its volley has the pool first.
    var k: u32 = 1;
    while (k <= p.forks) : (k += 1) {
        if (t < fork_delay * k) continue;
        const e = p.trail[(t - fork_delay * k) % trail_len];
        if (e.fired) fire_volley(@floatFromInt(e.x), @floatFromInt(e.y));
    }

    if (p.invuln > 0) p.invuln -= 1;
    if (p.go_pop > 0) p.go_pop -= 1;
    if (p.retry_pop > 0) p.retry_pop -= 1;
}

const zap_speed: f32 = 4.0;
const beam_speed: f32 = 6.0;
const seeker_speed: f32 = 3.5;

fn sin256(a: i32) f32 {
    return enemies.sin_table[@as(u8, @truncate(@as(u32, @bitCast(a))))];
}

/// Velocity at `angle` 1/256 turns from straight right. Angle 0 is exactly
/// (speed, 0), so the level-1 zap moves exactly as the M5 zapper did.
fn velocity(v: f32, angle: i32) [2]f32 {
    if (angle == 0) return .{ v, 0 };
    return .{ v * sin256(angle + 64), v * sin256(angle) };
}

fn zap(x: f32, y: f32, angle: i32) void {
    const v = velocity(zap_speed, angle);
    _ = bullets.spawn_bolt(.{ .kind = .zap, .x = x + 28, .y = y + 8, .vx = v[0], .vy = v[1] });
}

/// One volley of the current weapon from a ship (or ghost) whose cell
/// top-left is (x, y): PLAN.md M6 "Numbers". Every bolt's hitbox center
/// starts at the nose, (x + 36, y + 12) plus the level's offsets.
fn fire_volley(x: f32, y: f32) void {
    const p = &world.w.player;
    switch (p.weapon) {
        .fuzzer => switch (p.level) {
            0, 1 => zap(x, y, 0),
            2 => {
                zap(x, y - 3, 0);
                zap(x, y + 3, 0);
            },
            3 => for ([_]i32{ 0, 8, -8 }) |a| zap(x, y, a),
            4 => for ([_]i32{ 0, 8, -8, 16, -16 }) |a| zap(x, y, a),
            else => for ([_]i32{ 0, 8, -8, 16, -16 }) |a| zap(x, y, a + rng.range(-4, 4)),
        },
        .assert => {
            const dmg: u8 = switch (p.level) {
                0, 1, 2 => 1,
                3, 4 => 2,
                else => 3,
            };
            const offsets: []const f32 = switch (p.level) {
                0, 1, 2 => &.{0},
                3, 4 => &.{ -4, 4 },
                else => &.{ 0, -6, 6 },
            };
            for (offsets) |dy| {
                _ = bullets.spawn_bolt(.{
                    .kind = .beam,
                    .damage = dmg,
                    .x = x + 36 - bullets.beam_len / 2,
                    .y = y + 12 - bullets.beam_h / 2 + dy,
                    .vx = beam_speed,
                });
            }
        },
        .bisect => {
            const lvl: u32 = @max(p.level, 1);
            const gain = 0.08 + 0.04 * @as(f32, @floatFromInt(lvl - 1));
            var i: u32 = 0;
            while (i < lvl) : (i += 1) {
                // 0, +10, -10, +20, -20 (1/256 turns).
                const step: i32 = @intCast((i + 1) / 2);
                const a: i32 = if (i % 2 == 1) 10 * step else -10 * step;
                const v = velocity(seeker_speed, a);
                _ = bullets.spawn_bolt(.{ .kind = .seeker, .x = x + 28, .y = y + 8, .vx = v[0], .vy = v[1], .gain = gain });
            }
        },
    }
}

/// Raiden's power loss (PLAN.md M7), charged in the World at the resume of
/// an auto rewind (normal and hardcore) and on each probe hit: one weapon
/// level (not below 1), one fork, and +80 rank mercy. Not on a hold-B
/// rewind, not on a retry-shield pop.
pub fn on_rewound_hit() void {
    const p = &world.w.player;
    p.level = @max(1, p.level -| 1);
    p.forks -|= 1;
    world.w.mercy +|= rank.mercy_per_hit;
}

/// The trail entry ghost `k` (1-based) stands on in the tick just
/// simulated, or null before there is that much history.
pub fn ghost_entry(k: u32) ?TrailEntry {
    const p = &world.w.player;
    if (world.w.game_tick == 0) return null;
    const last = world.w.game_tick - 1;
    if (last < fork_delay * k) return null;
    return p.trail[(last - fork_delay * k) % trail_len];
}

/// The forks: the ship cell in the ship's current pose at each ghost's
/// trail entry, checkerboard-dithered, no thruster, farthest first.
pub fn draw_ghosts() void {
    const p = &world.w.player;
    var k: u32 = p.forks;
    while (k >= 1) : (k -= 1) {
        const e = ghost_entry(k) orelse continue;
        draw.draw_sprite(gfx.ship, cell_w, cell_h, @backingInt(p.pose), e.x, e.y, .{ .skip_odd = true });
    }
}

pub fn invulnerable() bool {
    return world.w.player.invuln > 0;
}

/// Hitbox as [x, y, w, h].
pub fn hitbox() [4]f32 {
    const p = &world.w.player;
    return .{ p.x + hitbox_off[0], p.y + hitbox_off[1], hitbox_size, hitbox_size };
}

/// Center of the hitbox, in whole pixels.
pub fn hitbox_center() [2]i32 {
    const hb = hitbox();
    return .{ @intFromFloat(@floor(hb[0] + hb[2] / 2)), @intFromFloat(@floor(hb[1] + hb[3] / 2)) };
}

pub fn add_score(points: u32) void {
    const p = &world.w.player;
    p.score = @min(p.score + points, score_cap);
}

pub fn draw_ship(tick: u32) void {
    const p = &world.w.player;
    const ix: i32 = @intFromFloat(@floor(p.x));
    const iy: i32 = @intFromFloat(@floor(p.y));
    // Blink while invulnerable: drawn every other tick.
    if (p.invuln == 0 or tick % 2 == 0) {
        draw.draw_sprite(gfx.thruster, 8, 8, (tick / 3) % 4, ix + thruster_off[0], iy + thruster_off[1], .{});
        draw.draw_sprite(gfx.ship, cell_w, cell_h, @backingInt(p.pose), ix, iy, .{});
    }
    // The retry shield: `hud.png` cell 1 (12x8) centered above the cell.
    if (p.shield > 0) draw.draw_sprite(gfx.hud, 12, 8, 1, ix + 10, iy - 6, .{});
    if (p.invuln > 0) {
        const hb = hitbox();
        // 1 px dot at the hitbox center.
        cart.hline(.{
            .x = @as(i32, @intFromFloat(hb[0])) + 2,
            .y = @as(i32, @intFromFloat(hb[1])) + 2,
            .len = 1,
            .color = draw.cream,
        });
    }
}

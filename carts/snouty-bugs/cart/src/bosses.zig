//! The bosses (PLAN.md M7, track B2): every boss's movement, fire
//! program and drawing, dispatched from `enemies.update` and
//! `enemies.draw_enemy` for `.boss` enemies. `Enemy.variant` is the
//! `BossId`. Moved out of `enemies.zig` unchanged at the start of M7
//! phase 2 (only the Heisenbug exists so far).
const gfx = @import("gfx");
const draw = @import("draw.zig");
const enemies = @import("enemies.zig");
const fx = @import("fx.zig");
const patterns = @import("patterns.zig");
const pickups = @import("pickups.zig");
const player = @import("player.zig");
const rank = @import("rank.zig");
const rng = @import("rng.zig");
const waves = @import("waves.zig");

const Enemy = enemies.Enemy;

// Boss (SPEC.md section 7, PLAN.md "Gameplay numbers for M3"); its HP is in boss_hp.zig.
const boss_speed: f32 = 1.0;
const boss_stop_x: f32 = 104;
const boss_bob_amplitude: f32 = 32;
const boss_bob_period: u32 = 240;
const boss_min_y: f32 = 8;
const boss_max_y: f32 = 80;
const boss_teleport_every: u32 = 300;
const boss_flicker: u32 = 20;
const boss_vanish: u32 = 20;
const boss_min_x = 96;
const boss_max_x = 112;
const boss_min_base_y = 24;
const boss_max_base_y = 56;
const boss_fire_phase_len: u32 = 240;
const boss_fire_phases = 3;
const boss_ring_n = 12;
const boss_ring_every: u32 = 40;
const boss_ring_step: u8 = 11;
const boss_ring_speed: f32 = 0.8;
const boss_stream_every: u32 = 60;
const boss_stream_n = 3;
const boss_stream_gap: u32 = 8;
const boss_stream_speed: f32 = 1.5;
const boss_spread_every: u32 = 90;
const boss_spread_n = 5;
const boss_spread_step = 12;
const boss_spread_speed: f32 = 0.6;
const boss_spiral_every: u32 = 4;
const boss_spiral_step: u8 = 8;
const boss_spiral_speed: f32 = 1.0;
const boss_dying: u32 = 60;
const boss_blast_every: u32 = 10;
/// Small death explosions are centered this far inside the 48x48 cell.
const boss_blast_margin = 8;
const boss_frame_ticks = 6;
const boss_idle_frames = 4;
const boss_flicker_cell = 4;

/// Enter to x 104, then fight: bob on the sine table, fire, and every 300
/// fighting ticks teleport (flicker 20, vanished 20, reappear at a random
/// x and bob line). Dying: 60 ticks of small explosions, then the big one.
pub fn update(e: *Enemy) void {
    switch (e.phase) {
        .enter => {
            e.x -= boss_speed;
            if (e.x <= boss_stop_x) {
                e.x = boss_stop_x;
                e.phase = .fight;
                e.timer = 0;
            }
        },
        .fight => {
            const i = (e.timer % boss_bob_period) * 256 / boss_bob_period;
            const y = e.base_y + boss_bob_amplitude * enemies.sin_table[i];
            e.y = @min(@max(y, boss_min_y), boss_max_y);
            // Each change of fire phase drops a crate (PLAN.md M6).
            if (e.fire_tick > 0 and e.fire_tick % boss_fire_phase_len == 0) {
                const c = e.center();
                pickups.spawn_drop(c[0], c[1]);
            }
            boss_fire(e);
            e.fire_tick += 1;
            e.timer += 1;
            if (e.timer >= boss_teleport_every) {
                e.phase = .flicker;
                e.timer = 0;
            }
        },
        .flicker => {
            e.timer += 1;
            if (e.timer >= boss_flicker) {
                e.phase = .vanished;
                e.timer = 0;
            }
        },
        .vanished => {
            e.timer += 1;
            if (e.timer >= boss_vanish) {
                e.x = @floatFromInt(rng.range(boss_min_x, boss_max_x));
                e.base_y = @floatFromInt(rng.range(boss_min_base_y, boss_max_base_y));
                e.y = e.base_y;
                e.phase = .fight;
                e.timer = 0;
            }
        },
        .dying => {
            if (e.timer >= boss_dying) {
                const c = e.center();
                fx.spawn(.big_explosion, @intFromFloat(@floor(c[0])), @intFromFloat(@floor(c[1])));
                player.add_score(e.points());
                e.active = false;
                waves.boss_cleared();
                return;
            }
            if (e.timer % boss_blast_every == 0) {
                const ox = rng.range(boss_blast_margin, 48 - boss_blast_margin);
                const oy = rng.range(boss_blast_margin, 48 - boss_blast_margin);
                const bx: i32 = @intFromFloat(@floor(e.x));
                const by: i32 = @intFromFloat(@floor(e.y));
                fx.spawn(.explosion, bx + ox, by + oy);
                e.flash = 2;
            }
            e.timer += 1;
        },
        else => {},
    }
}

/// The three fire phases, 240 fighting ticks each, cycling.
fn boss_fire(e: *Enemy) void {
    const c = e.center();
    const local = e.fire_tick % boss_fire_phase_len;
    switch ((e.fire_tick / boss_fire_phase_len) % boss_fire_phases) {
        0 => if (local % rank.interval(boss_ring_every) == 0) {
            patterns.ring(c[0], c[1], boss_ring_n, e.ring_phase, .{ .speed = boss_ring_speed, .source = .boss });
            e.ring_phase +%= boss_ring_step;
        },
        1 => {
            const k = local % rank.interval(boss_stream_every);
            if (k % boss_stream_gap == 0 and k / boss_stream_gap < boss_stream_n) {
                patterns.aimed(c[0], c[1], .{ .speed = boss_stream_speed, .shape = .needle, .source = .boss });
            }
            if (local % rank.interval(boss_spread_every) == 0) {
                patterns.fan(c[0], c[1], boss_spread_n, boss_spread_step, .{ .speed = boss_spread_speed, .source = .boss });
            }
        },
        else => if (local % rank.interval(boss_spiral_every) == 0) {
            patterns.at_angle(c[0], c[1], e.spiral_angle, .{ .speed = boss_spiral_speed, .source = .boss });
            e.spiral_angle +%= boss_spiral_step;
        },
    }
}

/// The boss cell at (x, y). `own` already merges the hit flash; the
/// flicker ghost ignores it.
pub fn draw_boss(e: Enemy, x: i32, y: i32, opts: draw.SpriteOpts, own: draw.SpriteOpts) void {
    switch (e.phase) {
        .flicker => draw.draw_sprite(gfx.boss, 48, 48, boss_flicker_cell, x, y, .{ .flash_white = opts.flash_white, .skip_odd = true }),
        else => draw.draw_sprite(gfx.boss, 48, 48, (e.age / boss_frame_ticks) % boss_idle_frames, x, y, own),
    }
}

//! First-person weapon overlay: `weapons.png` 48x32, cell `weapon * 3 +
//! frame`, at x 56 with its bottom at y 104 plus the walk bob. Drawn
//! before the status bar, which covers the rows that sink below 104
//! (ASSETS.md section 10: the sleeve never lifts off the bottom edge).
//! The M9 arsenal weapons (4-7) are code-drawn rect art (fx.zig) in the
//! same 48 x 32 box, held by the zapper cell's paw.
const cart = @import("cart-api");
const gfx = @import("gfx");
const fixed = @import("../fixed.zig");
const arsenal = @import("../arsenal.zig");
const fx = @import("fx.zig");
const state = @import("../state.zig");
const sim = @import("../sim.zig");
const blit = @import("blit.zig");

pub const x: i32 = 56;
pub const w: u32 = 48;
pub const h: u32 = 32;
/// Resting top: bottom row exactly on y 103.
pub const rest_y: i32 = 104 - @as(i32, h);
pub const bob_period: u32 = 32;
/// Peak-to-peak bob is 4 px (SPEC.md 4, +-2 around rest_y + 2), and only
/// downward from rest_y, so no gap opens under the sleeve.
pub const bob_depth: i32 = 4;

/// Render-only bob phase, 0..bob_period-1. Advances while moving; when
/// the player stops it runs on to the nearest rest point (phase 0).
var phase: u32 = 0;

/// 0 idle, 1 first fire/swing frame, 2 second.
pub fn frame_for(wp: state.Weapon, cooldown: u8) u32 {
    const r: u32 = sim.fire_rate(wp);
    const c: u32 = cooldown;
    if (c > r * 2 / 3) return 1;
    if (c > r / 3) return 2;
    return 0;
}

/// Triangle wave 0..bob_depth..0 over bob_period ticks.
fn bob_offset(p: u32) i32 {
    const half = bob_period / 2;
    const d: u32 = if (p < half) p else bob_period - p; // 0..half
    return @intCast(d * @as(u32, bob_depth) / half);
}

/// Call once per displayed tick. `moving` = the player walked this tick.
pub fn draw(s: *const state.GameState, moving: bool) void {
    if (moving) {
        phase = (phase + 1) % bob_period;
    } else if (phase != 0) {
        // Settle to rest by the shorter way round.
        phase = if (phase < bob_period / 2) phase - 1 else (phase + 1) % bob_period;
    }
    const wp = s.player.weapon;
    if (@backingInt(wp) >= 4) return draw_arsenal(wp, frame_for(wp, s.player.fire_cooldown), rest_y + bob_offset(phase));
    const cell_index: u32 = @as(u32, @backingInt(wp)) * 3 + frame_for(wp, s.player.fire_cooldown);
    blit.cell(gfx.weapons, w, h, cell_index, x, rest_y + bob_offset(phase), .{});
}

// ---------------------------------------------------------------- M9 arsenal

/// Deathmatch: the shown player's Garbage Collector spin-up (`Match.gc_spin`,
/// 0 .. `arsenal.gc_spinup`); the caller sets it before `draw`.
pub var gc_spin: u8 = 0;
/// Render-only blade angle of the Garbage Collector.
var blade: fixed.Angle = 0;

const ro = fx.ro;
const rb = fx.rb;

/// FUZZER: a chunky coral blaster with a glyph window of random bits.
const fuzzer_art = [_]fx.Rect{
    ro(17, 11, 15, 13, fx.c_coral), ro(21, 3, 7, 8, fx.c_steel), ro(22, 0, 5, 4, fx.c_dsteel), ro(19, 9, 11, 2, fx.c_iris),
    ro(20, 14, 9, 6, fx.c_black),   rb(23, 1, 3, 2, fx.c_black), rb(29, 12, 2, 11, fx.c_red),  rb(19, 22, 11, 1, fx.c_diris),
};
/// FORK BOMB: a round bomb with a ":(" face and a lit fuse.
const bomb_art = [_]fx.Rect{
    ro(18, 9, 13, 14, fx.c_diris), ro(16, 11, 17, 10, fx.c_diris), ro(20, 7, 9, 18, fx.c_diris), ro(22, 4, 5, 3, fx.c_steel),
    ro(25, 1, 2, 3, fx.c_gold),    rb(20, 10, 3, 2, fx.c_iris),    rb(19, 12, 2, 3, fx.c_iris),  rb(21, 14, 2, 2, fx.c_coral),
    rb(27, 14, 2, 2, fx.c_coral),  rb(22, 19, 6, 1, fx.c_coral),   rb(21, 20, 1, 1, fx.c_coral), rb(28, 20, 1, 1, fx.c_coral),
};
/// SHIP IT: a shipping crate with a launch tube; `nose` = the loaded rocket.
const ship_art = [_]fx.Rect{
    ro(14, 7, 21, 17, fx.c_brown), ro(16, 1, 17, 7, fx.c_steel), rb(14, 12, 21, 1, fx.c_dbrown), rb(14, 18, 21, 1, fx.c_dbrown),
    rb(18, 2, 13, 5, fx.c_black),  rb(17, 19, 8, 4, fx.c_white), rb(19, 20, 4, 2, fx.c_coral),   rb(14, 7, 2, 2, fx.c_steel),
    rb(33, 7, 2, 2, fx.c_steel),   rb(14, 22, 2, 2, fx.c_steel), rb(33, 22, 2, 2, fx.c_steel),
};
const ship_nose = [_]fx.Rect{ rb(22, 3, 5, 4, fx.c_red), rb(23, 3, 2, 1, fx.c_white) };
/// GARBAGE COLLECTOR: a shredder drum; the blades are drawn by `blades`.
const gc_art = [_]fx.Rect{
    ro(15, 4, 19, 16, fx.c_iris),  ro(17, 2, 15, 20, fx.c_iris),  ro(13, 6, 23, 12, fx.c_iris), ro(21, 21, 7, 4, fx.c_steel),
    rb(17, 5, 15, 14, fx.c_black), rb(16, 7, 17, 10, fx.c_black),
};
const gc_hub = [_]fx.Rect{rb(23, 11, 3, 3, fx.c_gold)};

fn put(px: i32, py: i32, c: u4) void {
    if (px < 0 or px >= cart.screen_width or py < 0 or py >= 104) return;
    cart.framebuffer[@intCast(px)][@intCast(py)] = fx.px(c);
}

/// `n` random `sz`-pixel squares in the box (x, y, w, h) from `colours`.
fn sparkle(bx: i32, by: i32, bw: u32, bh: u32, n: u32, sz: i32, colours: []const u4) void {
    for (0..n) |_| {
        const v = fx.noise();
        const px = bx + @as(i32, @intCast(v % bw));
        const py = by + @as(i32, @intCast((v >> 8) % bh));
        fx.fill(px, px + sz, py, py + sz, 104, 0, fx.px(colours[(v >> 16) % colours.len]));
    }
}

/// Three blades around the drum centre (cx, cy), `len` px long.
fn blades(cx: f32, cy: f32, a: fixed.Angle, c: u4) void {
    for (0..3) |k| {
        const t = a +% @as(fixed.Angle, @intCast(k)) *% 21845;
        const dx = fixed.to_f32(fixed.cos(t));
        const dy = fixed.to_f32(fixed.sin(t));
        var d: f32 = 1.5;
        while (d < 7.5) : (d += 0.7) put(@intFromFloat(@floor(cx + dx * d)), @intFromFloat(@floor(cy + dy * d)), c);
    }
}

/// SHIP IT muzzle burst: x0, x1 (box), height above the tube, colour.
const burst = [_][4]u8{ .{ 15, 34, 3, fx.c_orange }, .{ 21, 28, 11, fx.c_orange }, .{ 19, 30, 6, fx.c_gold }, .{ 23, 26, 3, fx.c_white } };

const bits = [_]u4{ fx.c_green, fx.c_cyan, fx.c_white, fx.c_coral };
const fire = [_]u4{ fx.c_orange, fx.c_gold, fx.c_white };

/// Arsenal view models: `frame` 0 idle, 1 and 2 the fire frames.
fn draw_arsenal(wp: state.Weapon, frame: u32, y0: i32) void {
    var oy = y0;
    var ox = x;
    switch (wp) {
        .fuzzer => {
            // Recoil, and a muzzle spray of random bit pellets.
            oy += @intCast(frame & 1);
            fx.screen(&fuzzer_art, ox, oy);
            const firing = frame != 0;
            for (0..6) |i| {
                const on = if (firing) fx.noise() & 1 == 1 else (@as(u8, 0b100110) >> @intCast(i)) & 1 == 1;
                if (on) put(ox + 21 + 2 * @as(i32, @intCast(i % 3)), oy + 15 + 2 * @as(i32, @intCast(i / 3)), fx.c_green);
            }
            if (firing) sparkle(ox + 13, oy - 12, 23, 12, 12, 2, &bits);
        },
        .fork_bomb => {
            // Frame 1: thrown (empty paw); frame 2: the next one comes up.
            if (frame == 1) {
                oy += 4;
            } else {
                const by = oy + @as(i32, if (frame == 2) 8 else 0);
                fx.screen(&bomb_art, ox, by);
                sparkle(ox + 24, by - 2, 5, 3, 3, 1, &fire);
            }
        },
        .ship_it => {
            oy += @as(i32, if (frame == 1) 3 else if (frame == 2) 1 else 0); // recoil
            fx.screen(&ship_art, ox, oy);
            if (frame == 0) fx.screen(&ship_nose, ox, oy);
            if (frame == 1) {
                // A star-shaped burst out of the tube.
                for (burst) |q| fx.fill(ox + q[0], ox + q[1], oy - q[2], oy + 3, 104, 0, fx.px(@intCast(q[3])));
                sparkle(ox + 15, oy - 12, 19, 7, 10, 2, &fire);
            } else if (frame == 2) {
                sparkle(ox + 17, oy - 8, 15, 8, 8, 2, &[_]u4{ fx.c_grey, fx.c_steel });
            }
        },
        else => {
            // Spins with the spin-up; shakes and throws sparks while shredding.
            const spin: u32 = @min(gc_spin, arsenal.gc_spinup);
            const speed: u32 = 500 + spin * 5000 / arsenal.gc_spinup;
            blade +%= @intCast(speed);
            if (spin == arsenal.gc_spinup) ox += @as(i32, @intCast(fx.noise() & 1));
            fx.screen(&gc_art, ox, oy);
            const cx: f32 = @floatFromInt(ox + 24);
            const cy: f32 = @floatFromInt(oy + 12);
            if (spin * 2 > arsenal.gc_spinup) blades(cx, cy, blade -% 3000, fx.c_steel);
            blades(cx, cy, blade, if (spin == arsenal.gc_spinup) fx.c_white else fx.c_grey);
            fx.screen(&gc_hub, ox, oy);
            if (frame != 0) sparkle(ox + 14, oy + 1, 21, 20, 8, 1, &fire);
        },
    }
    blit.cell(gfx.weapons, w, h, 3, x, oy, .{ .from_row = 24 });
}

//! A stand-in deathmatch player (M7) for the host tests, the previews and
//! the bench, and (M8) the player a party leaver hands its slot to
//! (`match.hand_over`). Reads only the World, so every badge running the
//! same match computes the same bot input; fixed point only, no cart-api.
//!
//! Its target is the nearest visible living foe (another team's player in
//! a team mode): the `look` nearest living foes by distance are tested for
//! line of sight, nearest first, so 16 bots cost at most 16 x `look` rays
//! a tick. With a target it turns to face it, fires once aimed, keeps
//! 1.5..3 cells away and now and then strafes. Otherwise it walks, turning
//! away from walls (which way changes every 1.5 s) and every few seconds
//! toward the nearest foe's bearing. Out of ammo it presses Select until a
//! weapon with ammo comes up.
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");
const match = @import("match.zig");

const Fixed = fixed.Fixed;
const Buttons = state.Buttons;

fn has_ammo(p: *const state.Player) bool {
    return switch (p.weapon) {
        .swatter => true,
        .zapper => p.ammo_zapper > 0,
        .spray => p.ammo_spray > 0,
        .debugger => p.ammo_debugger > 0,
        .fuzzer, .fork_bomb, .ship_it, .gc => false, // M9: Track C
    };
}

fn mix(a: u32) u32 {
    var x = a *% 0x9E37_79B9;
    x ^= x >> 15;
    x *%= 0x85EB_CA6B;
    x ^= x >> 13;
    return x;
}

fn steer(b: *Buttons, d: i16) void {
    const dead_zone: i16 = @intCast(sim.turn_speed / 2);
    if (d > dead_zone) b.right = true else if (d < -dead_zone) b.left = true;
}

/// Line-of-sight tests per bot per tick (the nearest living foes first).
pub const look = 3;

pub fn think(w: *const match.World, level: *const levels.Level, slot: usize) Buttons {
    const m = &w.m;
    const me = &m.players[slot];
    var b: Buttons = .{};
    if (!m.alive(slot)) return b;
    const t = w.gs.tick;
    const salt: u32 = @intCast(slot);
    if (!has_ammo(me)) b.select = t & 1 == 0;
    // The `look` nearest living foes, nearest first (lower slot on a tie).
    var near: [look]u8 = undefined;
    var near_d: [look]i64 = undefined;
    var nn: usize = 0;
    for (0..state.max_players) |j| {
        if (!m.foes(slot, j) or !m.alive(j)) continue;
        const o = &m.players[j];
        const dx: i64 = o.x - me.x;
        const dy: i64 = o.y - me.y;
        const d2 = dx * dx + dy * dy;
        var k: usize = nn;
        while (k > 0 and near_d[k - 1] > d2) : (k -= 1) {
            if (k < look) {
                near[k] = near[k - 1];
                near_d[k] = near_d[k - 1];
            }
        }
        if (k < look) {
            near[k] = @intCast(j);
            near_d[k] = d2;
            if (nn < look) nn += 1;
        }
    }
    var target: ?usize = null;
    for (near[0..nn]) |j| {
        const o = &m.players[j];
        if (sim.line_of_sight(&w.gs, level, me.x, me.y, o.x, o.y)) {
            target = j;
            break;
        }
    }
    if (target) |j| {
        const o = &m.players[j];
        const d = fixed.angle_diff(fixed.atan2(o.y - me.y, o.x - me.x), me.angle);
        const ad: i32 = if (d < 0) -@as(i32, d) else d;
        const dx: i64 = o.x - me.x;
        const dy: i64 = o.y - me.y;
        const d2 = dx * dx + dy * dy;
        const far: i64 = 3 * @as(i64, fixed.one);
        const close: i64 = fixed.from_float(1.5);
        if (d2 > far * far) b.up = true else if (d2 < close * close) b.down = true;
        if (ad < fixed.deg(10) and (t / 40 +% salt) % 3 == 0) {
            b.b = true;
            if ((t / 40) & 1 == 0) b.left = true else b.right = true;
        } else {
            steer(&b, d);
        }
        if (ad < fixed.deg(5)) b.a = true;
        return b;
    }
    const ahead = sim.wall_distance(&w.gs, level, me.x, me.y, me.angle);
    if (ahead < fixed.one) {
        if (mix(t / 90 +% salt *% 7) & 1 == 0) b.right = true else b.left = true;
        return b;
    }
    b.up = true;
    if (nn > 0 and (t / 120 +% salt) % 2 == 0) {
        const o = &m.players[near[0]];
        steer(&b, fixed.angle_diff(fixed.atan2(o.y - me.y, o.x - me.x), me.angle));
    }
    return b;
}

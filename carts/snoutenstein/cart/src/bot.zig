//! A stand-in deathmatch player (M7) for the host tests, the previews and
//! the bench: there is no second human (and no cable) there. Reads only
//! the World, so two badges running the same match compute the same bot
//! input; fixed point only, no cart-api.
//!
//! With the other player in sight it turns to face it, fires once aimed,
//! keeps 1.5..3 cells away and now and then strafes. Otherwise it walks,
//! turning away from walls (which way changes every 1.5 s) and every few
//! seconds toward the other player's bearing. Out of ammo it presses
//! Select until a weapon with ammo comes up.
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

pub fn think(w: *const match.World, level: *const levels.Level, slot: u1) Buttons {
    const m = &w.m;
    const me = &m.players[slot];
    var b: Buttons = .{};
    if (!match.alive(m, slot)) return b;
    const t = w.gs.tick;
    if (!has_ammo(me)) b.select = t & 1 == 0;
    const o = &m.players[slot ^ 1];
    const want = fixed.atan2(o.y - me.y, o.x - me.x);
    const d = fixed.angle_diff(want, me.angle);
    const ad: i32 = if (d < 0) -@as(i32, d) else d;
    const see = match.alive(m, slot ^ 1) and sim.line_of_sight(&w.gs, level, me.x, me.y, o.x, o.y);
    if (see) {
        const dx: i64 = o.x - me.x;
        const dy: i64 = o.y - me.y;
        const d2 = dx * dx + dy * dy;
        const far: i64 = 3 * @as(i64, fixed.one);
        const near: i64 = fixed.from_float(1.5);
        if (d2 > far * far) b.up = true else if (d2 < near * near) b.down = true;
        if (ad < fixed.deg(10) and (t / 40 +% slot) % 3 == 0) {
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
        if (mix(t / 90 +% @as(u32, slot) *% 7) & 1 == 0) b.right = true else b.left = true;
        return b;
    }
    b.up = true;
    if ((t / 120 +% slot) % 2 == 0) steer(&b, d);
    return b;
}

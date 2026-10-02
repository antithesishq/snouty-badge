//! Driving by the centerline (SPEC 5.3): the rivals and the attract
//! autopilot steer toward a look-ahead sample with a lane offset and
//! throttle by the curvature ahead. Integer-only, no cart API. M1 ships
//! the SNOUTY character only (the lap test and attract); M2 adds the rivals.
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const sim = @import("sim.zig");

pub const Character = struct {
    /// Lane offset from the centerline, world px (positive = right of travel).
    lane: i32 = 0,
    /// Samples ahead to aim at.
    lookahead: u8 = 6,
    /// Curvature window: the heading change over the next `curve_ahead`
    /// samples sets the speed target: top speed at 0, `min_speed_pct` at
    /// `full_brake_turn` turn units and beyond.
    curve_ahead: u8 = 8,
    full_brake_turn: i32 = 14000,
    min_speed_pct: u8 = 72,
    /// Use the tight turn when the steering error exceeds this.
    tight_turn: i32 = 3000,
    /// Top speed scale in 1/256 (the character's own cap, applied by easing off A).
    speed_pct: u8 = 255,
};

pub const snouty = Character{};

/// One tick of buttons for machine `m` (machine index `i` picks the character).
pub fn drive(m: *const world.Machine, i: usize) world.Buttons {
    _ = i;
    return drive_as(m, &snouty);
}

pub fn drive_as(m: *const world.Machine, c: *const Character) world.Buttons {
    var b: world.Buttons = .{};
    const t = sim.current;
    const target = t.sample((@as(usize, m.progress) + c.lookahead) & 255);
    // Lane offset along the target's right vector.
    const tx = fixed.cos(target.tangent);
    const ty = fixed.sin(target.tangent);
    const gx = @as(i32, target.x) + ((-ty * c.lane) >> fixed.Q);
    const gy = @as(i32, target.y) + ((tx * c.lane) >> fixed.Q);
    var dx = gx - (m.x >> fixed.Q);
    var dy = gy - (m.y >> fixed.Q);
    dx = ((dx + 512) & 1023) - 512;
    dy = ((dy + 512) & 1023) - 512;
    const want = fixed.atan2(dy, dx);
    const err = fixed.turn_diff(m.heading, want);
    if (err > 400) b.right = true;
    if (err < -400) b.left = true;
    // Speed target from the curvature ahead: sum of |turn| over the window.
    var curve: i32 = 0;
    var k: usize = 0;
    while (k < c.curve_ahead) : (k += 1) {
        const a = t.sample((@as(usize, m.progress) + k) & 255).tangent;
        const bb = t.sample((@as(usize, m.progress) + k + 1) & 255).tangent;
        curve += @intCast(@abs(fixed.turn_diff(a, bb)));
    }
    const cap = @divTrunc(tuning.top_speed * @as(i32, c.speed_pct), 255);
    const slow = @min(curve, c.full_brake_turn);
    const pct: i32 = 255 - @divTrunc((255 - @as(i32, c.min_speed_pct)) * slow, c.full_brake_turn);
    const want_spd = @divTrunc(cap * pct, 255);
    const spd = sim.speed(m);
    b.a = spd < want_spd;
    // Brake when well over the target; tight turn on a big heading error.
    if (spd > want_spd + @divTrunc(want_spd, 6)) b.down = true;
    if (@abs(err) > c.tight_turn and spd > @divTrunc(tuning.top_speed, 4)) b.down = true;
    return b;
}

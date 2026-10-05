//! The "uniforms" every program reads (SPEC.md section 1), built once per
//! tick from the hand (hand.zig): the field cells glide toward the newest
//! frame and are upsampled into field.f; a punch records where and when it
//! landed, fires the flash and kicks the palette phase. No cart API.
const std = @import("std");
const config = @import("config.zig");
const field = @import("field.zig");
const hand_mod = @import("hand.zig");
const math = @import("math.zig");

pub const U = struct {
    /// Ticks since start (1/60 s) and the same in seconds (wraps hourly).
    tick: u32 = 0,
    t: f32 = 0,
    hand: hand_mod.Hand = .{},
    /// The hand in surface pixels (80x64; the outer cell centres at +-1).
    hx: f32 = 40,
    hy: f32 = 32,
    /// Smoothed cell values (row-major, row 0 top), their sum / 9, and
    /// the per-cell presence and nearness behind them.
    cells: [9]f32 = @splat(0),
    presence: [9]f32 = @splat(0),
    near: [9]f32 = @splat(0),
    total: f32 = 0,
    /// Smoothed speed of the hand (units/s, x/y and z combined).
    energy: f32 = 0,
    /// Ticks since the last punch (large when none) and where it was.
    punch_age: u32 = 100_000,
    punch_x: f32 = 40,
    punch_y: f32 = 32,
    /// White flash 0..1 and the palette phase offset (turns).
    flash: f32 = 0,
    kick: f32 = 0,
    /// The current program's parameter, 0..config.param_max.
    param: u8 = config.param_default,
};

pub var u: U = .{};
var kick_target: f32 = 0;

pub fn reset() void {
    u = .{};
    kick_target = 0;
    field.f = @splat(@splat(0));
}

/// Surface x, y of a hand position.
pub fn to_surface(x: f32, y: f32) [2]f32 {
    return .{ 40.0 + x * 26.67, 32.0 - y * 21.33 };
}

/// One tick, after hand.update.
pub fn update(param: u8) void {
    const hd = hand_mod.hand;
    u.tick +%= 1;
    u.t = @as(f32, @floatFromInt(u.tick % (60 * 3600))) / 60.0;
    u.hand = hd;
    u.param = param;
    const s = to_surface(hd.x, hd.y);
    u.hx = s[0];
    u.hy = s[1];

    const c = &hand_mod.cells;
    var total: f32 = 0;
    for (0..9) |i| {
        u.presence[i] += (c.presence[i] - u.presence[i]) * config.field_glide;
        u.near[i] += (c.near[i] - u.near[i]) * config.field_glide;
        const target = c.presence[i] * (config.field_base + (1.0 - config.field_base) * c.near[i]);
        u.cells[i] += (target - u.cells[i]) * config.field_glide;
        total += u.cells[i];
    }
    u.total = total / 9.0;
    field.build(&u.cells);

    const speed = @abs(hd.vx) + @abs(hd.vy) + @abs(hd.vz);
    u.energy += (math.clampf(speed, 0, 8) - u.energy) * 0.1;

    u.punch_age +|= 1;
    if (hd.punch) {
        u.punch_age = 0;
        u.punch_x = u.hx;
        u.punch_y = u.hy;
        u.flash = 1.0;
        kick_target += config.kick_turns;
    }
    u.flash *= config.flash_decay;
    if (u.flash < 0.004) u.flash = 0;
    u.kick += (kick_target - u.kick) * config.kick_ease;
    // Keep both small (only the fraction matters to a palette).
    if (kick_target > 16) {
        kick_target -= 16;
        u.kick -= 16;
    }
}

test "uniforms: punch fires the flash and kicks the palette; cells glide" {
    const t = std.testing;
    math.init_tables();
    field.init();
    hand_mod.reset();
    reset();
    hand_mod.cells.presence[4] = 1;
    hand_mod.cells.near[4] = 1;
    hand_mod.hand.punch = true;
    update(4);
    try t.expectEqual(@as(u32, 0), u.punch_age);
    try t.expect(u.flash > 0.8);
    try t.expect(u.cells[4] > 0.2 and u.cells[4] < 0.5);
    hand_mod.hand.punch = false;
    for (0..60) |_| update(4);
    try t.expect(u.cells[4] > 0.99);
    try t.expect(field.f[40][32] > 250);
    try t.expectEqual(@as(f32, 0), u.flash);
    try t.expectApproxEqAbs(config.kick_turns, u.kick, 0.01);
    try t.expectEqual(@as(u32, 60), u.punch_age);
}

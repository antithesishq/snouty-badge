//! Enemy pool and per-kind movement programs. M1 has only the gnat.
const gfx = @import("gfx");
const draw = @import("draw.zig");

pub const Kind = enum { gnat };

pub const Enemy = struct {
    active: bool = false,
    kind: Kind = .gnat,
    /// Ticks before the enemy appears (used to space out strings).
    delay: u32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    base_y: f32 = 0,
    age: u32 = 0,
    hp: u8 = 1,
    /// Ticks of white hit flash left.
    flash: u8 = 0,

    /// Spawned and on the field (collidable, drawn).
    pub fn live(e: Enemy) bool {
        return e.active and e.delay == 0;
    }

    pub fn size(e: Enemy) [2]f32 {
        return switch (e.kind) {
            .gnat => .{ 8, 8 },
        };
    }

    pub fn points(e: Enemy) u32 {
        return switch (e.kind) {
            .gnat => 10,
        };
    }
};

pub var pool: [24]Enemy = @splat(.{});

/// sin(2 pi i / 256) for i in 0..256, built at comptime (no libm at runtime).
pub const sin_table: [256]f32 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]f32 = undefined;
    for (&t, 0..) |*v, i| {
        const a: f32 = @as(f32, @floatFromInt(i)) * (2.0 * std_pi / 256.0);
        v.* = @sin(a);
    }
    break :blk t;
};
const std_pi: f32 = 3.14159265358979;

const gnat_speed: f32 = 1.0;
const gnat_amplitude: f32 = 8.0;
const gnat_period: u32 = 40;
pub const gnat_spawn_x: f32 = 168.0;
const string_len = 5;
const string_spacing = 12;

pub fn reset() void {
    pool = @splat(.{});
}

fn alloc() ?*Enemy {
    for (&pool) |*e| {
        if (!e.active) return e;
    }
    return null;
}

/// Spawns a string of 5 gnats at spawn x, wobbling around `y`, 12 ticks apart.
pub fn spawn_gnat_string(y: f32) void {
    for (0..string_len) |i| {
        const e = alloc() orelse return;
        e.* = .{
            .active = true,
            .kind = .gnat,
            .delay = @intCast(i * string_spacing),
            .x = gnat_spawn_x,
            .y = y,
            .base_y = y,
            .hp = 1,
        };
    }
}

pub fn update() void {
    for (&pool) |*e| {
        if (!e.active) continue;
        if (e.delay > 0) {
            e.delay -= 1;
            continue;
        }
        if (e.flash > 0) e.flash -= 1;
        switch (e.kind) {
            .gnat => {
                e.x -= gnat_speed;
                const phase = (e.age % gnat_period) * 256 / gnat_period;
                e.y = e.base_y + gnat_amplitude * sin_table[phase];
                if (e.x < -8.0) e.active = false;
            },
        }
        e.age += 1;
    }
}

pub fn draw_enemies() void {
    for (pool) |e| {
        if (!e.live()) continue;
        const x: i32 = @intFromFloat(@floor(e.x));
        const y: i32 = @intFromFloat(@floor(e.y));
        switch (e.kind) {
            .gnat => draw.draw_sprite(gfx.bugs_small, 8, 8, (e.age / 4) % 2, x, y, .{ .flash_white = e.flash > 0 }),
        }
    }
}

pub fn live_count() u32 {
    var n: u32 = 0;
    for (pool) |e| n += @intFromBool(e.live());
    return n;
}

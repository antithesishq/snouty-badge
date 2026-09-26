//! Spark and explosion pool (fx_small.png: 0-4 explosion, 5-7 spark).
const gfx = @import("gfx");
const draw = @import("draw.zig");

pub const Kind = enum { explosion, spark };

const Fx = struct {
    active: bool = false,
    kind: Kind = .explosion,
    x: i32 = 0,
    y: i32 = 0,
    age: u32 = 0,
};

var pool: [16]Fx = @splat(.{});

fn first_frame(kind: Kind) u32 {
    return switch (kind) {
        .explosion => 0,
        .spark => 5,
    };
}

fn frame_count(kind: Kind) u32 {
    return switch (kind) {
        .explosion => 5,
        .spark => 3,
    };
}

fn ticks_per_frame(kind: Kind) u32 {
    return switch (kind) {
        .explosion => 3,
        .spark => 2,
    };
}

pub fn reset() void {
    pool = @splat(.{});
}

/// Spawns an effect centered on (cx, cy). Dropped if the pool is full.
pub fn spawn(kind: Kind, cx: i32, cy: i32) void {
    for (&pool) |*f| {
        if (f.active) continue;
        f.* = .{ .active = true, .kind = kind, .x = cx - 8, .y = cy - 8 };
        return;
    }
}

pub fn update() void {
    for (&pool) |*f| {
        if (!f.active) continue;
        f.age += 1;
        if (f.age >= frame_count(f.kind) * ticks_per_frame(f.kind)) f.active = false;
    }
}

pub fn draw_fx() void {
    for (pool) |f| {
        if (!f.active) continue;
        const frame = first_frame(f.kind) + f.age / ticks_per_frame(f.kind);
        draw.draw_sprite(gfx.fx_small, 16, 16, frame, f.x, f.y, .{});
    }
}

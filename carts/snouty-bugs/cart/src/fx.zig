//! Spark and explosion pool, `world.w.fx` (fx_small.png: 0-4 explosion,
//! 5-7 spark; fx_big.png: 0-5 big explosion).
const gfx = @import("gfx");
const draw = @import("draw.zig");
const world = @import("world.zig");

pub const Kind = enum { explosion, spark, big_explosion };

pub const Fx = struct {
    active: bool = false,
    kind: Kind = .explosion,
    /// Cell top-left.
    x: i32 = 0,
    y: i32 = 0,
    age: u32 = 0,
};

fn first_frame(kind: Kind) u32 {
    return switch (kind) {
        .explosion => 0,
        .spark => 5,
        .big_explosion => 0,
    };
}

fn frame_count(kind: Kind) u32 {
    return switch (kind) {
        .explosion => 5,
        .spark => 3,
        .big_explosion => 6,
    };
}

fn ticks_per_frame(kind: Kind) u32 {
    return switch (kind) {
        .explosion => 3,
        .spark => 2,
        .big_explosion => 4,
    };
}

fn half_size(kind: Kind) i32 {
    return switch (kind) {
        .explosion, .spark => 8,
        .big_explosion => 16,
    };
}

/// Spawns an effect centered on (cx, cy). Dropped if the pool is full,
/// except the big explosion, which takes the last slot rather than vanish.
pub fn spawn(kind: Kind, cx: i32, cy: i32) void {
    const h = half_size(kind);
    const f: Fx = .{ .active = true, .kind = kind, .x = cx - h, .y = cy - h };
    for (&world.w.fx) |*slot| {
        if (slot.active) continue;
        slot.* = f;
        return;
    }
    if (kind == .big_explosion) world.w.fx[world.w.fx.len - 1] = f;
}

pub fn update() void {
    for (&world.w.fx) |*f| {
        if (!f.active) continue;
        f.age += 1;
        if (f.age >= frame_count(f.kind) * ticks_per_frame(f.kind)) f.active = false;
    }
}

pub fn draw_fx() void {
    for (world.w.fx) |f| {
        if (!f.active) continue;
        const frame = first_frame(f.kind) + f.age / ticks_per_frame(f.kind);
        switch (f.kind) {
            .explosion, .spark => draw.draw_sprite(gfx.fx_small, 16, 16, frame, f.x, f.y, .{}),
            .big_explosion => draw.draw_sprite(gfx.fx_big, 32, 32, frame, f.x, f.y, .{}),
        }
    }
}

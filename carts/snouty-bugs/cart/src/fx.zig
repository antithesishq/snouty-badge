//! Spark and explosion pool, `world.w.fx` (fx_small.png: 0-4 explosion,
//! 5-7 spark; fx_big.png: 0-5 big explosion), the bomb ring and the bomb
//! background flash (both derived from `world.w.player.bomb_timer`).
const cart = @import("cart-api");
const gfx = @import("gfx");
const draw = @import("draw.zig");
const player = @import("player.zig");
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

/// Ticks of bomb (counting down from 30) during which the flash replaces
/// the background: 30, 29, 28, 27.
const flash_last_timer: u32 = player.bomb_ticks - 3;

/// The background, or the flat cream flash for the first 4 ticks of a bomb.
pub fn draw_bg_or_flash() void {
    const t = world.w.player.bomb_timer;
    if (t >= flash_last_timer) {
        cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = cart.screen_height, .fill_color = draw.cream });
    } else {
        draw.draw_bg();
    }
}

/// Two expanding rings from the hitbox center while a bomb is active:
/// Anti-White at r = (30 - bomb_timer) * 7, Coral at r - 3.
pub fn draw_bomb_ring() void {
    const t = world.w.player.bomb_timer;
    if (t == 0) return;
    const c = player.hitbox_center();
    const r: i32 = @intCast((player.bomb_ticks - t) * 7);
    ring(c, r, draw.anti_white);
    if (r >= 3) ring(c, r - 3, draw.coral);
}

fn ring(c: [2]i32, r: i32, color: cart.DisplayColor) void {
    cart.oval(.{
        .x = c[0] - r,
        .y = c[1] - r,
        .width = @intCast(2 * r + 1),
        .height = @intCast(2 * r + 1),
        .stroke_color = color,
    });
}

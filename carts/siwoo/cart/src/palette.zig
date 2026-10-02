//! Colour helpers (from demosnout's palette.zig): 0x00RRGGBB to a
//! framebuffer pixel through `cart.Pixel.from_color`, so the wasm byte
//! swap is respected, and an RGB888 blend.
const std = @import("std");
const cart = @import("cart-api");

/// 0x00RRGGBB to a framebuffer pixel.
pub fn pixel(rgb: u32) cart.Pixel {
    return .from_color(.rgb(rgb));
}

/// Blend two 0x00RRGGBB colours, f in 0..256 (256 = all b).
pub fn mix_rgb(a: u32, b: u32, f: u32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const ca = (a >> shift) & 0xff;
        const cb = (b >> shift) & 0xff;
        const c = (ca * (256 - f) + cb * f) >> 8;
        out |= c << shift;
    }
    return out;
}

/// Fully saturated hue, h in turns (0 red, 1/3 green, 2/3 blue), as
/// 0x00RRGGBB: the piecewise-linear HSV wheel at S = V = 1.
pub fn hue(h: f32) u32 {
    const x = (h - @floor(h)) * 6.0;
    const sector: u32 = @min(5, @as(u32, @intFromFloat(x)));
    const f: u32 = @intFromFloat((x - @as(f32, @floatFromInt(sector))) * 255.0);
    const up = f;
    const down = 255 - f;
    const rgb: [3]u32 = switch (sector) {
        0 => .{ 255, up, 0 },
        1 => .{ down, 255, 0 },
        2 => .{ 0, 255, up },
        3 => .{ 0, down, 255 },
        4 => .{ up, 0, 255 },
        else => .{ 255, 0, down },
    };
    return (rgb[0] << 16) | (rgb[1] << 8) | rgb[2];
}

test "mix_rgb and hue" {
    try std.testing.expectEqual(@as(u32, 0x000000), mix_rgb(0x000000, 0xffffff, 0));
    try std.testing.expectEqual(@as(u32, 0xffffff), mix_rgb(0x000000, 0xffffff, 256));
    try std.testing.expectEqual(@as(u32, 0x7f7f7f), mix_rgb(0x000000, 0xffffff, 128));
    try std.testing.expectEqual(@as(u32, 0xff0000), hue(0.0));
    try std.testing.expectEqual(@as(u32, 0x00ff00), hue(1.0 / 3.0));
    try std.testing.expectEqual(@as(u32, 0xff0000), hue(1.0));
}

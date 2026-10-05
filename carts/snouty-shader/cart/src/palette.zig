//! Cosine palettes (Inigo Quilez, "palettes"): colour(t) = a + b cos(2 pi
//! (c t + d)) per channel. Each program turns one into its 256-entry LUT
//! of spread RGB565 colours every frame (`Lut`, 256 x ~40 cycles), so
//! cycling, the punch flash and the palette kick cost nothing per pixel.
const std = @import("std");
const math = @import("math.zig");
const surface = @import("surface.zig");

pub const Lut = [256]u32;

pub const Cosine = struct {
    name: []const u8,
    a: [3]f32,
    b: [3]f32,
    c: [3]f32,
    d: [3]f32,
};

pub const all = [_]Cosine{
    .{ .name = "SPECTRUM", .a = .{ 0.5, 0.5, 0.5 }, .b = .{ 0.5, 0.5, 0.5 }, .c = .{ 1, 1, 1 }, .d = .{ 0.0, 0.33, 0.67 } },
    .{ .name = "EMBER", .a = .{ 0.5, 0.5, 0.5 }, .b = .{ 0.5, 0.5, 0.5 }, .c = .{ 1, 1, 1 }, .d = .{ 0.0, 0.10, 0.20 } },
    .{ .name = "LAGOON", .a = .{ 0.5, 0.5, 0.5 }, .b = .{ 0.5, 0.5, 0.5 }, .c = .{ 1, 1, 1 }, .d = .{ 0.30, 0.20, 0.20 } },
    .{ .name = "LIME", .a = .{ 0.5, 0.5, 0.5 }, .b = .{ 0.5, 0.5, 0.5 }, .c = .{ 1, 1, 0.5 }, .d = .{ 0.80, 0.90, 0.30 } },
    .{ .name = "DUSK", .a = .{ 0.5, 0.5, 0.5 }, .b = .{ 0.5, 0.5, 0.5 }, .c = .{ 1, 0.7, 0.4 }, .d = .{ 0.0, 0.15, 0.20 } },
    .{ .name = "CANDY", .a = .{ 0.5, 0.5, 0.5 }, .b = .{ 0.5, 0.5, 0.5 }, .c = .{ 2, 1, 0 }, .d = .{ 0.50, 0.20, 0.25 } },
    .{ .name = "COPPER", .a = .{ 0.8, 0.5, 0.4 }, .b = .{ 0.2, 0.4, 0.2 }, .c = .{ 2, 1, 1 }, .d = .{ 0.0, 0.25, 0.25 } },
    .{ .name = "NEON", .a = .{ 0.45, 0.25, 0.55 }, .b = .{ 0.55, 0.5, 0.45 }, .c = .{ 1, 1, 1 }, .d = .{ 0.85, 0.15, 0.55 } },
};

pub const count = all.len;

pub const Rgb = [3]f32;

/// The palette at `t` (turns of the cosine; any real), channels 0..1.
pub fn at(p: *const Cosine, t: f32) Rgb {
    var out: Rgb = undefined;
    for (0..3) |i| out[i] = math.clamp01(p.a[i] + p.b[i] * math.cos_turns(p.c[i] * t + p.d[i]));
    return out;
}

/// `c` scaled by `bright` (0..~2, clamped per channel) and blended toward
/// white by `flash` (0..1), as a spread RGB565 colour.
pub fn pack(c: Rgb, bright: f32, flash: f32) u32 {
    var ch: [3]u32 = undefined;
    for (0..3) |i| {
        const v = math.clamp01(c[i] * bright);
        const f = v + (1.0 - v) * flash;
        ch[i] = @intFromFloat(f * 255.0);
    }
    return surface.spread_rgb(ch[0], ch[1], ch[2]);
}

test "palette: every palette stays in range and varies" {
    for (&all) |*p| {
        var lo: f32 = 1;
        var hi: f32 = 0;
        for (0..64) |i| {
            const c = at(p, @as(f32, @floatFromInt(i)) / 64.0);
            for (c) |v| {
                try std.testing.expect(v >= 0 and v <= 1);
                lo = @min(lo, v);
                hi = @max(hi, v);
            }
        }
        try std.testing.expect(hi - lo > 0.4);
    }
    try std.testing.expectEqual(surface.spread_rgb(255, 255, 255), pack(.{ 0, 0, 0 }, 1, 1));
}

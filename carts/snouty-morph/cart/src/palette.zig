//! 256-entry palettes and colour mixing (copied from demosnout), for the
//! plasma and the shade ramps. Built at init() or per frame, never at
//! comptime (Adrian's Mac Zig runs out of memory on big comptime loops).
//! Every entry goes through `cart.Pixel.from_color`, so the wasm byte swap
//! is respected; `lerp` decodes through `to_color` for the same reason.
const std = @import("std");
const cart = @import("cart-api");

pub const Palette = [256]cart.Pixel;

/// A key colour at palette index `pos`, as 0x00RRGGBB.
pub const Key = struct { pos: u8, rgb: u32 };

/// Piecewise-linear gradient through `keys` in RGB888, then quantised to
/// RGB565. Keys are sorted by `pos`, the first at 0 and the last at 255.
pub fn gradient(keys: []const Key) Palette {
    std.debug.assert(keys.len >= 2 and keys[0].pos == 0 and keys[keys.len - 1].pos == 255);
    var out: Palette = undefined;
    var k: usize = 0;
    for (0..256) |i| {
        while (k + 2 < keys.len and i > keys[k + 1].pos) k += 1;
        const a = keys[k];
        const b = keys[k + 1];
        const span: u32 = @as(u32, b.pos) - a.pos;
        const f: u32 = if (span == 0) 0 else ((@as(u32, @intCast(i)) - a.pos) * 256) / span;
        out[i] = pixel(mix_rgb(a.rgb, b.rgb, f));
    }
    return out;
}

/// out[i] = p[(i + n) mod 256]: shifts the colours down by n (palette cycling).
pub fn rotate(p: *const Palette, n: u8) Palette {
    var out: Palette = undefined;
    for (0..256) |i| out[i] = p[(i + n) & 255];
    return out;
}

/// Per-entry blend, t = 0 gives a, 255 gives b (per channel in RGB565).
pub fn lerp(a: *const Palette, b: *const Palette, t: u8) Palette {
    var out: Palette = undefined;
    const w: u32 = t;
    for (0..256) |i| {
        const ca = a[i].to_color();
        const cb = b[i].to_color();
        out[i] = .from_color(.{
            .r = @intCast(mix_chan(ca.r, cb.r, w)),
            .g = @intCast(mix_chan(ca.g, cb.g, w)),
            .b = @intCast(mix_chan(ca.b, cb.b, w)),
        });
    }
    return out;
}

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

/// Blend two channel values, w in 0..255 (255 = all b), rounded.
fn mix_chan(a: u32, b: u32, w: u32) u32 {
    return (a * (255 - w) + b * w + 127) / 255;
}

test "gradient hits its keys and interpolates" {
    const p = gradient(&.{
        .{ .pos = 0, .rgb = 0x000000 },
        .{ .pos = 128, .rgb = 0xff0000 },
        .{ .pos = 255, .rgb = 0xffffff },
    });
    try std.testing.expectEqual(pixel(0x000000), p[0]);
    try std.testing.expectEqual(pixel(0xff0000), p[128]);
    try std.testing.expectEqual(pixel(0xffffff), p[255]);
    const mid = p[64].to_color();
    try std.testing.expect(mid.r >= 14 and mid.r <= 17);
    try std.testing.expectEqual(@as(u6, 0), mid.g);
    // Monotonic red ramp over the first segment.
    for (1..129) |i| try std.testing.expect(p[i].to_color().r >= p[i - 1].to_color().r);
}

test "rotate and lerp" {
    var a: Palette = undefined;
    for (&a, 0..) |*e, i| e.* = .from_color(.{ .r = @intCast(i & 31), .g = 0, .b = 0 });
    const r = rotate(&a, 3);
    try std.testing.expectEqual(a[3], r[0]);
    try std.testing.expectEqual(a[2], r[255]);
    const black = gradient(&.{ .{ .pos = 0, .rgb = 0 }, .{ .pos = 255, .rgb = 0 } });
    const white = gradient(&.{ .{ .pos = 0, .rgb = 0xffffff }, .{ .pos = 255, .rgb = 0xffffff } });
    try std.testing.expectEqual(black[7], lerp(&black, &white, 0)[7]);
    try std.testing.expectEqual(white[7], lerp(&black, &white, 255)[7]);
    const half = lerp(&black, &white, 128)[7].to_color();
    try std.testing.expectEqual(@as(u5, 16), half.r);
    try std.testing.expectEqual(@as(u6, 32), half.g);
}

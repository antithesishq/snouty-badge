//! Part 1, Plasma (5 bars, 10 s): the classic sum-of-sines plasma at half
//! resolution. Each frame fills an 80x64 index field with four integer
//! sines: one of x, one of y, one of x + y (each precomputed per column,
//! row or diagonal for the frame) and one of the distance from a centre
//! that wanders on a Lissajous path (a distance table filled at init()).
//! The field is upscaled 2x through a palette that rotates one step per
//! frame and cross-fades between three cyclic gradients (fire, ocean,
//! candy) every 200 frames (3.3 s). No floats per pixel; the palettes all
//! pass through black, which gives the dark bands their contrast.
const cart = @import("cart-api");
const math = @import("../math.zig");
const palette = @import("../palette.zig");
const fx = @import("../fx.zig");

pub const name: []const u8 = "Plasma";

const w = 80;
const h = 64;
/// Distance table size: the field plus the wander range of the centre.
const dw = w + 40;
const dh = h + 32;

var dist: [dw][dh]u8 = undefined;
var field: fx.Indices = undefined;
var bases: [3]palette.Palette = undefined;

/// Frames per palette: held for `hold`, then blended into the next.
const period = 200;
const hold = 130;

pub fn init() void {
    // Distance from the table's centre, in half pixels (max ~154).
    for (&dist, 0..) |*col, x| for (col, 0..) |*d, y| {
        const fx_: f32 = @as(f32, @floatFromInt(x)) - dw / 2;
        const fy: f32 = @as(f32, @floatFromInt(y)) - dh / 2;
        d.* = @intFromFloat(@min(255.0, @sqrt(fx_ * fx_ + fy * fy) * 2.0));
    };
    // Cyclic gradients (index 255 wraps to 0), each with a black point.
    bases[0] = palette.gradient(&.{
        .{ .pos = 0, .rgb = 0x000000 },
        .{ .pos = 36, .rgb = 0x3c0006 },
        .{ .pos = 76, .rgb = 0xa81400 },
        .{ .pos = 112, .rgb = 0xff6a00 },
        .{ .pos = 140, .rgb = 0xffd040 },
        .{ .pos = 160, .rgb = 0xfff8d0 },
        .{ .pos = 184, .rgb = 0xffa020 },
        .{ .pos = 212, .rgb = 0xb02000 },
        .{ .pos = 238, .rgb = 0x300008 },
        .{ .pos = 255, .rgb = 0x000000 },
    });
    bases[1] = palette.gradient(&.{
        .{ .pos = 0, .rgb = 0x000008 },
        .{ .pos = 40, .rgb = 0x001848 },
        .{ .pos = 84, .rgb = 0x00589c },
        .{ .pos = 124, .rgb = 0x10b0e0 },
        .{ .pos = 150, .rgb = 0xd8fcff },
        .{ .pos = 174, .rgb = 0x40d0c0 },
        .{ .pos = 206, .rgb = 0x006878 },
        .{ .pos = 236, .rgb = 0x001430 },
        .{ .pos = 255, .rgb = 0x000008 },
    });
    bases[2] = palette.gradient(&.{
        .{ .pos = 0, .rgb = 0x080010 },
        .{ .pos = 40, .rgb = 0x40005c },
        .{ .pos = 82, .rgb = 0xc02890 },
        .{ .pos = 120, .rgb = 0xff80b0 },
        .{ .pos = 148, .rgb = 0xfff0a8 },
        .{ .pos = 176, .rgb = 0x60e8d0 },
        .{ .pos = 208, .rgb = 0x2848b0 },
        .{ .pos = 236, .rgb = 0x100838 },
        .{ .pos = 255, .rgb = 0x080010 },
    });
}

pub fn enter() void {}

pub fn render(t: u32, fb: cart.FramebufferPtr) void {
    // Per-frame terms: sine of x, of y, of x + y.
    var sx: [w]i32 = undefined;
    var sy: [h]i32 = undefined;
    var sd: [w + h]i32 = undefined;
    for (&sx, 0..) |*v, x| v.* = math.isin(@as(u32, @intCast(x * 19)) +% t *% 5);
    for (&sy, 0..) |*v, y| v.* = math.isin(@as(u32, @intCast(y * 23)) -% t *% 7);
    for (&sd, 0..) |*v, k| v.* = math.isin(@as(u32, @intCast(k * 9)) +% t *% 3);
    // The wandering centre: offsets into the distance table.
    const ox: usize = @intCast(20 + ((math.isin(t *% 4) * 20) >> 15));
    const oy: usize = @intCast(16 + ((math.icos(t *% 3 +% 100) * 16) >> 15));
    const ring_t: u32 = t *% 11;

    for (&field, 0..) |*col, x| {
        const dcol = &dist[x + ox];
        const ax = sx[x];
        for (col, 0..) |*v, y| {
            const r = math.isin(@as(u32, dcol[y + oy]) * 26 -% ring_t);
            const sum = ax + sy[y] + sd[x + y] + r;
            // Four Q15 sines sum to +-4 * 32767; >> 9 spans the palette
            // twice, and the u8 wrap is seamless because it is cyclic.
            v.* = @truncate(@as(u32, @bitCast(sum >> 9)));
        }
    }

    const seg = (t / period) % 3;
    const within = t % period;
    const blend: u8 = if (within < hold) 0 else @intCast(((within - hold) * 255) / (period - hold - 1));
    const mixed = palette.lerp(&bases[seg], &bases[(seg + 1) % 3], blend);
    const pal = palette.rotate(&mixed, @truncate(t));
    fx.upscale2x(&field, &pal, fb);
}

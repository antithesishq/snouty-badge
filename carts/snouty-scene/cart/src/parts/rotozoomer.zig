//! Part 3, Rotozoomer (5 bars, 10 s): the Snouty sprite tiled to infinity,
//! rotating one full turn over the part while it breathes in and out and
//! pans on a Lissajous path. On every beat (30 frames) the zoom kicks in by
//! 5% and relaxes over a few frames, so the motion is cut to the clock.
//!
//! The method is the classic one. The 32x32 texture (`gen/textures.zig`,
//! magenta key already dark navy) is converted once at init() into a flat
//! [1024]cart.Pixel. Per frame, f32 set-up gives the screen-to-texture
//! affine map as four 16.16 steps (du/dx, dv/dx, du/dy, dv/dy) and the
//! texture coordinate of pixel (0, 0); `frame_params` is pure and
//! host-tested. Per pixel it is two wrapping adds, two shifts, two ands, one
//! load and one store: the texel index is ((v >> 16) & 31) * 32 +
//! ((u >> 16) & 31), and the `& 31` wrap tiles the plane. Columns are the
//! framebuffer's fast axis, so the inner loop walks down a column with the
//! y steps. No filtering: hard texels are the look.
const cart = @import("cart-api");
const math = @import("../math.zig");
const textures = @import("../gen/textures.zig");

pub const name: []const u8 = "Rotozoomer";

const width = 160;
const height = 128;
const tex_size = 32;

var tex: [tex_size * tex_size]cart.Pixel = undefined;

// Tuning knobs (frames; turns).
const turn_period: f32 = 600; // one full rotation over the part
const wobble_amp: f32 = 0.05;
const wobble_period: f32 = 180;
const zoom_mid: f32 = 1.0; // texels per screen pixel
const zoom_amp: f32 = 0.6;
const zoom_period: f32 = 240;
const beat_frames = 30;
const kick_frames = 6;
const kick_amp: f32 = 0.05;
const pan_amp_u: f32 = 48; // texels
const pan_amp_v: f32 = 40;
const pan_period_u: f32 = 700;
const pan_period_v: f32 = 460;

/// One frame's affine map, 16.16 fixed point (wrapping): texture (u, v) of
/// screen pixel (0, 0) and the steps per screen x and y.
pub const Params = struct {
    u0: u32,
    v0: u32,
    du_dx: u32,
    dv_dx: u32,
    du_dy: u32,
    dv_dy: u32,
};

fn fixed(x: f32) u32 {
    const r: i32 = @intFromFloat(if (x >= 0) x * 65536.0 + 0.5 else x * 65536.0 - 0.5);
    return @bitCast(r);
}

pub fn frame_params(t: u32) Params {
    const tf: f32 = @floatFromInt(t);
    const angle = tf / turn_period + wobble_amp * math.sin_turns(tf / wobble_period);
    var zoom = zoom_mid + zoom_amp * math.sin_turns(tf / zoom_period);
    const beat = t % beat_frames;
    if (beat < kick_frames) {
        const k: f32 = @as(f32, @floatFromInt(kick_frames - beat)) / kick_frames;
        zoom *= 1.0 - kick_amp * k; // zoom in: fewer texels per pixel
    }
    const c = math.cos_turns(angle) * zoom;
    const s = math.sin_turns(angle) * zoom;
    // Texture point shown at the screen centre, drifting on a Lissajous.
    const cu = 16 + pan_amp_u * math.sin_turns(tf / pan_period_u);
    const cv = 16 + pan_amp_v * math.sin_turns(tf / pan_period_v + 0.25);
    const hx: f32 = width / 2;
    const hy: f32 = height / 2;
    // (u, v) = centre + R(angle) * zoom * (x - hx, y - hy).
    return .{
        .u0 = fixed(cu - c * hx + s * hy),
        .v0 = fixed(cv - s * hx - c * hy),
        .du_dx = fixed(c),
        .dv_dx = fixed(s),
        .du_dy = fixed(-s),
        .dv_dy = fixed(c),
    };
}

/// Index into the flat 32x32 texture of 16.16 coordinates (u, v), wrapped.
pub inline fn texel_index(u: u32, v: u32) u32 {
    return ((v >> 11) & (31 << 5)) | ((u >> 16) & 31);
}

/// The navy that replaced the sprite sheet's magenta key: these texels are
/// the background, recoloured every frame.
const key: u16 = 0x4102;
/// Background texels, as indices into `tex`.
var bg_texels: [tex_size * tex_size]u16 = undefined;
var bg_count: u32 = 0;

pub fn init() void {
    bg_count = 0;
    for (textures.snouty, 0..) |row, y| for (row, 0..) |v, x| {
        const i = y * tex_size + x;
        tex[i] = cart.Pixel.from_color(@bitCast(v));
        if (v == key) {
            bg_texels[bg_count] = @intCast(i);
            bg_count += 1;
        }
    };
}

fn to_color(r: f32, g: f32, b: f32) cart.DisplayColor {
    return .{
        .r = @intFromFloat(@min(31.0, @max(0.0, r * 31.0 + 0.5))),
        .g = @intFromFloat(@min(63.0, @max(0.0, g * 63.0 + 0.5))),
        .b = @intFromFloat(@min(31.0, @max(0.0, b * 31.0 + 0.5))),
    };
}

/// Background hues, cycled over the part: all on the cool side (navy,
/// teal, pine, slate) so the purple and orange sprite stays on top.
const bg_keys = [_]u32{ 0x14306a, 0x0c4a58, 0x0e4a2c, 0x1a3448 };

fn channel(rgb: u32, shift: u5) f32 {
    return @as(f32, @floatFromInt((rgb >> shift) & 0xff)) / 255.0;
}

/// Key colour at phase `h` (turns, one turn through all keys), times `l`.
fn bg_color(h: f32, l: f32) cart.DisplayColor {
    const n: f32 = bg_keys.len;
    const f = math.fract(h) * n;
    const i: usize = @min(bg_keys.len - 1, @as(usize, @intFromFloat(f)));
    const w = f - @as(f32, @floatFromInt(i));
    const k0 = bg_keys[i];
    const k1 = bg_keys[(i + 1) % bg_keys.len];
    return to_color(
        l * (channel(k0, 16) * (1 - w) + channel(k1, 16) * w),
        l * (channel(k0, 8) * (1 - w) + channel(k1, 8) * w),
        l * (channel(k0, 0) * (1 - w) + channel(k1, 0) * w),
    );
}

/// Recolours the background texels for frame t: a 2x2 checker per tile in
/// two shades of a slowly cycling dark hue, the light shade flashing on the
/// beat. 1024 texels per frame at most, next to nothing beside the fill.
fn paint_background(t: u32) void {
    const tf: f32 = @floatFromInt(t);
    const hue = tf / 600.0;
    const beat = t % beat_frames;
    var flash: f32 = 0;
    if (beat < kick_frames) flash = 0.5 * @as(f32, @floatFromInt(kick_frames - beat)) / kick_frames;
    const a = cart.Pixel.from_color(bg_color(hue, 0.85 + flash));
    const b = cart.Pixel.from_color(bg_color(hue, 0.45));
    for (bg_texels[0..bg_count]) |i| {
        const cell = ((i >> 4) ^ (i >> 9)) & 1; // x >> 4 ^ y >> 4
        tex[i] = if (cell == 0) a else b;
    }
}

pub fn enter() void {}

pub fn render(t: u32, fb: cart.FramebufferPtr) void {
    paint_background(t);
    const p = frame_params(t);
    var cu = p.u0;
    var cv = p.v0;
    for (fb) |*col| {
        var u = cu;
        var v = cv;
        for (col) |*px| {
            px.* = tex[texel_index(u, v)];
            u +%= p.du_dy;
            v +%= p.dv_dy;
        }
        cu +%= p.du_dx;
        cv +%= p.dv_dx;
    }
}

test "rotozoomer: texel index wraps and tiles" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 0), texel_index(0, 0));
    try std.testing.expectEqual(@as(u32, 5 * 32 + 3), texel_index(3 << 16, 5 << 16));
    try std.testing.expectEqual(texel_index(3 << 16, 5 << 16), texel_index(35 << 16 | 0xffff, 37 << 16));
    // Negative coordinates wrap: -1 is texel 31.
    try std.testing.expectEqual(@as(u32, 31 * 32 + 31), texel_index(@bitCast(@as(i32, -1)), @bitCast(@as(i32, -65536))));
}

test "rotozoomer: frame 0 map is unrotated, zoom 1 minus the beat kick" {
    const std = @import("std");
    const p = frame_params(0);
    // Angle 0, zoom 1 * (1 - 0.05): x steps along u, y along v.
    try std.testing.expectEqual(fixed(0.95), p.du_dx);
    try std.testing.expectEqual(@as(u32, 0), p.dv_dx);
    try std.testing.expectEqual(@as(u32, 0), p.du_dy);
    try std.testing.expectEqual(fixed(0.95), p.dv_dy);
    // Deterministic.
    try std.testing.expectEqual(frame_params(123), frame_params(123));
    // Rotation keeps the step length: at t 600 (a beat) the zoom is 1 * 0.95.
    const q = frame_params(600);
    const qc: f32 = @floatFromInt(@as(i32, @bitCast(q.du_dx)));
    const qs: f32 = @floatFromInt(@as(i32, @bitCast(q.dv_dx)));
    try std.testing.expectApproxEqAbs(@as(f32, 0.95 * 65536.0), @sqrt(qc * qc + qs * qs), 16.0);
    try std.testing.expectEqual(q.du_dx, q.dv_dy);
    try std.testing.expectEqual(q.dv_dx, 0 -% q.du_dy);
}

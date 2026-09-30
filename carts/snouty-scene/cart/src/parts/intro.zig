//! Part 0, Intro (3 bars, 6 s): a 3D starfield warp. 120 stars fly at the
//! viewer, the speed ramping up quadratically, and each is drawn as a
//! streak from where it is to where it was a few frames ago, so points turn
//! into long warp lines by the end. "ANTITHESIS PRESENTS" fades in at
//! 1.5 s (frame 90); SNOUTY / SCENE slams in at 3 s (frame 180), shrinking
//! from 6x to 2x over 10 frames, then lands with a background flash and a
//! short shake and stays until the fade-out.
//!
//! All star maths is fixed point (i32), the stars are seeded from rng.zig
//! with a constant in enter(), and the state advances once per render(), so
//! frame t is the same on wasm, thumb and after any jump into the part.
const cart = @import("cart-api");
const rng = @import("../rng.zig");
const palette = @import("../palette.zig");
const fx = @import("../fx.zig");
const text = @import("../text.zig");

pub const name: []const u8 = "Intro";

const star_count = 120;
/// World units: x in +-spread_x, y in +-spread_y, z in near..far.
const spread_x = 2400;
const spread_y = 1900;
const far = 4096;
const near = 24;
/// Focal length in pixels (world units at z are scaled by focal / z).
const focal = 96;
const cx = 80;
const cy = 64;

const presents_at = 90;
const title_at = 180;
const slam_frames = 10;
const land_at = title_at + slam_frames;

/// The night gradient behind the stars (top and bottom rows), public so the
/// Ending can cross-fade into exactly this frame 0 (the seamless loop cut).
pub const bg_top: u32 = 0x010208;
pub const bg_bottom: u32 = 0x0c0620;

const Star = struct { x: i32, y: i32, z: i32 };

var stars: [star_count]Star = undefined;
var random: rng.Xorshift = .init(1);
/// Brightness ramp for the streaks, dim blue to white.
var shades: [32]cart.Pixel = undefined;

pub fn init() void {
    for (&shades, 0..) |*s, i| {
        const f: u32 = @intCast((i * 256) / (shades.len - 1));
        s.* = palette.pixel(palette.mix_rgb(0x182040, 0xf4f8ff, f));
    }
}

pub fn enter() void {
    random = .init(0x5ce4e);
    for (&stars) |*s| respawn(s, @intCast(near + 32 + random.below(far - near - 32)));
}

fn respawn(s: *Star, z: i32) void {
    s.x = @as(i32, @intCast(random.below(2 * spread_x))) - spread_x;
    s.y = @as(i32, @intCast(random.below(2 * spread_y))) - spread_y;
    s.z = z;
}

/// World units per frame the stars travel at frame t: 10, rising to ~118.
fn speed(t: u32) i32 {
    return @intCast(10 + (t * t) / 1200);
}

/// How many frames back the tail reaches: 1 at the start, 7 at the end.
fn trail(t: u32) i32 {
    return @intCast(1 + t / 60);
}

pub fn render(t: u32, fb: cart.FramebufferPtr) void {
    // Background: deep night gradient, flashing on the title's landing.
    var top: u32 = bg_top;
    var bottom: u32 = bg_bottom;
    if (t >= land_at and t < land_at + 12) {
        const f: u32 = (land_at + 12 - t) * 16; // 192 .. 16
        top = palette.mix_rgb(top, 0x6040a0, f);
        bottom = palette.mix_rgb(bottom, 0xff80c0, f);
    }
    fx.vgradient(fb, top, bottom);

    draw_stars(fb, t, 256);

    if (t >= presents_at) {
        const f: u32 = @min((t - presents_at) * 12, 256);
        const str = "ANTITHESIS PRESENTS";
        text.shadowed(str, text.centre_x(str, 1), 28, .rgb(palette.mix_rgb(0x000000, 0xb8c4e8, f)), 1);
    }
    if (t >= title_at) title(t);
}

/// Advances every star one frame at the speed of frame t and draws its
/// streak; `bright` (0..256) is the streaks' opacity over the frame, 256 as
/// in render().
fn draw_stars(fb: cart.FramebufferPtr, t: u32, bright: u32) void {
    const v = speed(t);
    const len = v * trail(t);
    for (&stars) |*s| {
        s.z -= v;
        if (s.z <= near) respawn(s, far - @as(i32, @intCast(random.below(256))));
        const hx = project(s.x, s.z, cx);
        const hy = project(s.y, s.z, cy);
        if (hx < -40 or hx >= 200 or hy < -40 or hy >= 168) {
            respawn(s, far - @as(i32, @intCast(random.below(256))));
            continue;
        }
        const tz = @min(s.z + len, far);
        streak(fb, hx, hy, project(s.x, tz, cx), project(s.y, tz, cy), s.z, bright);
    }
}

/// The stars of frame 0 exactly as render(0) draws them (enter() first),
/// blended over the frame with opacity `bright` (0..256), for the Ending's last
/// frames: at 256, over `fx.vgradient(fb, bg_top, bg_bottom)`, this is the
/// Intro's frame 0 pixel for pixel, so the loop closes without a cut.
/// The timeline calls enter() again when the Intro starts.
pub fn first_frame_stars(fb: cart.FramebufferPtr, bright: u32) void {
    enter();
    draw_stars(fb, 0, bright);
}

inline fn project(w: i32, z: i32, c: i32) i32 {
    return c + @divTrunc(w * focal, z);
}

/// A line from the head (hx, hy) to the tail, bright at the head and
/// dimming along the tail; brightness also falls with depth. Clipped per
/// pixel; at most 160 steps.
fn streak(fb: cart.FramebufferPtr, hx: i32, hy: i32, tx: i32, ty: i32, z: i32, bright: u32) void {
    const depth: i32 = @max(0, 31 - @divTrunc(z * 22, far)); // 9 far .. 31 near
    const dx = tx - hx;
    const dy = ty - hy;
    const n: i32 = @min(160, @max(@as(i32, @intCast(@abs(dx))), @as(i32, @intCast(@abs(dy)))));
    if (n == 0) {
        plot(fb, hx, hy, shades[@intCast(depth)], bright);
        return;
    }
    // 16.16 stepping from head to tail.
    const sx = @divTrunc(dx * 65536, n);
    const sy = @divTrunc(dy * 65536, n);
    var x: i32 = hx * 65536 + 32768;
    var y: i32 = hy * 65536 + 32768;
    var i: i32 = 0;
    while (i <= n) : (i += 1) {
        const b = depth - @divTrunc(depth * i, n + 1);
        plot(fb, x >> 16, y >> 16, shades[@intCast(b)], bright);
        x += sx;
        y += sy;
    }
}

/// Stores `px`, or with `alpha` < 256 blends it over what is there.
inline fn plot(fb: cart.FramebufferPtr, x: i32, y: i32, px: cart.Pixel, alpha: u32) void {
    if (x < 0 or x >= fx.width or y < 0 or y >= fx.height) return;
    const dst = &fb[@intCast(x)][@intCast(y)];
    dst.* = if (alpha >= 256) px else blend(dst.*, px, alpha);
}

fn blend(under: cart.Pixel, over: cart.Pixel, alpha: u32) cart.Pixel {
    const a = under.to_color();
    const b = over.to_color();
    return .from_color(.{
        .r = @intCast((@as(u32, a.r) * (256 - alpha) + @as(u32, b.r) * alpha) >> 8),
        .g = @intCast((@as(u32, a.g) * (256 - alpha) + @as(u32, b.g) * alpha) >> 8),
        .b = @intCast((@as(u32, a.b) * (256 - alpha) + @as(u32, b.b) * alpha) >> 8),
    });
}

/// SNOUTY over SCENE at 2x (a 12-character line would not fit 160 px at
/// 2x), slamming in from 6x.
fn title(t: u32) void {
    const k = t - title_at;
    const scale: u32 = if (k < slam_frames) 2 + (4 * (slam_frames - k)) / slam_frames else 2;
    // Shake for 10 frames after landing, alternating, decaying.
    var shake: i32 = 0;
    if (t >= land_at and t < land_at + 10) {
        const a: i32 = @intCast((land_at + 10 - t) / 3);
        shake = if (t % 2 == 0) a else -a;
    }
    const s: i32 = @intCast(scale);
    const line1 = "SNOUTY";
    const line2 = "SCENE";
    const white: u32 = 0xffffff;
    // White while slamming, settling into gold and pink after landing.
    const settle: u32 = if (t < land_at) 0 else @min((t - land_at) * 16, 256);
    text.shadowed(line1, text.centre_x(line1, scale), 64 - 4 * s - 10 + shake, .rgb(palette.mix_rgb(white, 0xffd850, settle)), scale);
    text.shadowed(line2, text.centre_x(line2, scale), 64 - 4 * s + 10 + shake, .rgb(palette.mix_rgb(white, 0xff5ab0, settle)), scale);
}

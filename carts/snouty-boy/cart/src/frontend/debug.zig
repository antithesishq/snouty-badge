//! FPS and step_frame microseconds overlay (SPEC.md section 14). Owner: track C.
//! Allocation-free and std.fmt-free. Line 1: average and maximum
//! `step_frame` time over the last 60 frames; line 2: frames per second from
//! `micros_since_boot` deltas between `update()` calls, over 60 frames,
//! then the scrubber's page-store use in KB and its keyframe count.
//! In wasm builds `micros_since_boot` is an upstream stub that adds 1000 per
//! call (so the overlay shows 1000us and 500 fps in the simulator and in
//! preview.mjs); only hardware numbers mean anything.
const cart = @import("cart-api");

pub var enabled: bool = @import("tuning.zig").debug_overlay;

/// Set by the rewind self-check (frontend/rewind.zig, `self_check`) when a
/// replayed keyframe differs from the recorded one. The overlay is then
/// drawn on red, even when disabled in the menu.
pub var alarm: bool = false;

/// Page-store pool use and keyframe count, kept current by
/// frontend/rewind.zig after every keyframe.
pub var pool_kb: u32 = 0;
pub var keyframes: u32 = 0;

const window = 60;

var step_samples: [window]u32 = @splat(0);
var step_idx: usize = 0;
var step_count: u32 = 0;
/// Last `step_frame` duration in microseconds.
pub var last_step_us: u32 = 0;

var frame_deltas: [window]u32 = @splat(0);
var frame_idx: usize = 0;
var frame_count: u32 = 0;
var last_frame_us: u64 = 0;
var have_last_frame: bool = false;

/// Call once at the top of every `update()`.
pub fn frame_tick(now_us: u64) void {
    if (have_last_frame) {
        frame_deltas[frame_idx] = @truncate(now_us -% last_frame_us);
        frame_idx = (frame_idx + 1) % window;
        frame_count +|= 1;
    }
    last_frame_us = now_us;
    have_last_frame = true;
}

/// Record one `step_frame` duration.
pub fn record(step_us: u32) void {
    step_samples[step_idx] = step_us;
    step_idx = (step_idx + 1) % window;
    step_count +|= 1;
    last_step_us = step_us;
}

/// Frames per second over the window, rounded; 0 until a delta is known.
pub fn fps() u32 {
    const n = @min(frame_count, window);
    if (n == 0) return 0;
    var sum: u64 = 0;
    for (frame_deltas[0..n]) |d| sum += d;
    if (sum == 0) return 0;
    return @intCast((@as(u64, n) * 1_000_000 + sum / 2) / sum);
}

pub fn draw() void {
    if (!enabled and !alarm) return;
    const n = @min(step_count, window);
    if (n == 0) return;
    var max: u32 = 0;
    var sum: u64 = 0;
    for (step_samples[0..n]) |s| {
        max = @max(max, s);
        sum += s;
    }
    const avg: u32 = @intCast(sum / n);

    // "avg NNNN max NNNNus": the font is 8 px wide, so 20 characters fill
    // the 160 px screen; the unit is written once to keep 4-digit values
    // on screen.
    var buf: [48]u8 = undefined;
    var i: usize = 0;
    i += put(buf[i..], "avg ");
    i += put_num(buf[i..], avg);
    i += put(buf[i..], " max ");
    i += put_num(buf[i..], max);
    i += put(buf[i..], "us\nfps ");
    i += put_num(buf[i..], fps());
    i += put(buf[i..], " kf ");
    i += put_num(buf[i..], keyframes);
    i += put(buf[i..], " ");
    i += put_num(buf[i..], pool_kb);
    i += put(buf[i..], "K");
    draw_text(buf[0..i], white, if (alarm) red else black);
}

const white: cart.Pixel = .from_color(.rgb(0xFFFFFF));
const black: cart.Pixel = .from_color(.rgb(0x000000));
const red: cart.Pixel = .from_color(.rgb(0xFF0000));
/// The OS 8x8 font (`sycl-badge/src/font.zig`): `[char - ' '][row]`, bit
/// 7 - column, 0 = foreground. The same glyphs `cart.text` draws.
/// Byte-identical to the table `cart.text` uses, so the linker keeps one copy.
const font = @import("font").font;

/// `cart.text` at (0, 0), scale 1, opaque background, without its generic
/// per-pixel clipping and scaling: the overlay is drawn every frame, and
/// `cart.text` cost about 0.65 ms of it (badge-bench). The framebuffer is
/// column-major, so each glyph column is 8 consecutive halfword stores.
fn draw_text(str: []const u8, fg: cart.Pixel, bg: cart.Pixel) void {
    var cx: usize = 0;
    var cy: usize = 0;
    for (str) |ch| {
        if (ch == '\n') {
            cx = 0;
            cy += 8;
            continue;
        }
        if (cx + 8 > cart.screen_width or cy + 8 > cart.screen_height) {
            cx += 8;
            continue;
        }
        const glyph = &font[if (ch >= ' ') ch - ' ' else 0];
        for (0..8) |col| {
            const column = cart.framebuffer[cx + col][cy..][0..8];
            const bit: u3 = @intCast(7 - col);
            for (column, glyph) |*px, bits| {
                px.* = if ((bits >> bit) & 1 == 0) fg else bg;
            }
        }
        cx += 8;
    }
}

fn put(dst: []u8, s: []const u8) usize {
    @memcpy(dst[0..s.len], s);
    return s.len;
}

fn put_num(dst: []u8, v: u32) usize {
    var tmp: [10]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) {
        tmp[0] = '0';
        n = 1;
    }
    while (x > 0) : (x /= 10) {
        tmp[n] = @intCast('0' + x % 10);
        n += 1;
    }
    for (0..n) |k| dst[k] = tmp[n - 1 - k];
    return n;
}

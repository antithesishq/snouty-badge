//! step_frame timing and FPS (SPEC.md section 14), trimmed from Snouty
//! Gear's overlay (carts/snouty-gear/cart/src/frontend/debug.zig): the
//! numbers are kept every frame; `line` formats them for the status strip
//! when `enabled`. Allocation-free and std.fmt-free. In wasm
//! `micros_since_boot` adds 1000 per call, so only hardware numbers mean
//! anything.
pub var enabled: bool = false;

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

/// "fps NN max NNNNus" (20 columns at most) into `buf`.
pub fn line(buf: *[32]u8) []const u8 {
    var max: u32 = 0;
    for (step_samples[0..@min(step_count, window)]) |s| max = @max(max, s);
    var i: usize = 0;
    i += put(buf[i..], "fps ");
    i += put_num(buf[i..], fps());
    i += put(buf[i..], " max ");
    i += put_num(buf[i..], max);
    i += put(buf[i..], "us");
    return buf[0..i];
}

pub fn put(dst: []u8, s: []const u8) usize {
    const k = @min(s.len, dst.len);
    @memcpy(dst[0..k], s[0..k]);
    return k;
}

pub fn put_num(dst: []u8, v: u32) usize {
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
    const k = @min(n, dst.len);
    for (0..k) |j| dst[j] = tmp[n - 1 - j];
    return k;
}

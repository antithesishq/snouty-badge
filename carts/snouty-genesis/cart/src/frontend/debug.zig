//! Update-time and FPS overlay (SPEC.md section 14), copied from Snouty
//! Gear (itself from Snouty Boy). Changes: the sample is a whole
//! `update()`'s emulation (both Genesis frames of the 60/30 pair, SPEC.md
//! section 8), the window is 30 updates (one second at 30 Hz), and line 2
//! adds the emulated frame rate (`frames_per_update` x presents).
//! Allocation-free and std.fmt-free. Line 1: average and maximum update
//! time over the window; line 2: presents per second from
//! `micros_since_boot` deltas between `update()` calls, and emulated
//! frames per second; line 3: the Z80 (on, off, req = held by BUSREQ,
//! rst = in reset) and the `tunables` in force (render_every, z80_scale and
//! cpu_scale in percent).
//! In wasm builds `micros_since_boot` is an upstream stub that adds 1000 per
//! call (so the overlay shows 1000us and 500 fps in the simulator and in
//! preview.mjs); only hardware numbers mean anything.
const cart = @import("cart-api");
const core = @import("core");
const text = @import("text.zig");
const audio = @import("audio.zig");
const tunables = core.tunables;

pub var enabled: bool = true;

/// Set by the rewind self-check (M3) when a replayed keyframe differs from
/// the recorded one. The overlay is then drawn on red, even when disabled
/// in the menu.
pub var alarm: bool = false;

const window = 30;

/// Genesis frames emulated per update (tunables.render_every), for line 2.
pub var frames_per_update: u32 = 2;

var step_samples: [window]u32 = @splat(0);
var step_idx: usize = 0;
var step_count: u32 = 0;
/// Last update's emulation time in microseconds.
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

/// Record one update's emulation time.
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

/// The Z80's state for line 3, set by app.zig before `draw`: "on",
/// "req" (the 68000 holds its bus), "rst" (held in reset) or "off"
/// (`tunables.z80_enabled` false).
pub var z80_state: []const u8 = "on";

pub fn z80_label(md: *const core.Md) []const u8 {
    if (!tunables.z80_enabled) return "off";
    if (md.arbiter.z80_reset) return "rst";
    if (md.arbiter.busreq) return "req";
    return "on";
}

fn percent(scale: u16) u32 {
    return (@as(u32, scale) * 100 + tunables.scale_one / 2) / tunables.scale_one;
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
    var buf: [if (audio.streamed) 100 else 80]u8 = undefined;
    var i: usize = 0;
    i += put(buf[i..], "avg ");
    i += put_num(buf[i..], avg);
    i += put(buf[i..], " max ");
    i += put_num(buf[i..], max);
    const f = fps();
    i += put(buf[i..], "us\nfps ");
    i += put_num(buf[i..], f);
    i += put(buf[i..], " emu ");
    i += put_num(buf[i..], f * frames_per_update);
    // "z80:req r2 z100 c100" (20 columns): the Z80 and the tunables
    // (SPEC.md section 8).
    i += put(buf[i..], "\nz80:");
    i += put(buf[i..], z80_state);
    i += put(buf[i..], " r");
    i += put_num(buf[i..], tunables.render_every);
    i += put(buf[i..], " z");
    i += put_num(buf[i..], percent(tunables.z80_scale));
    i += put(buf[i..], " c");
    i += put_num(buf[i..], percent(tunables.cpu_scale));
    if (audio.streamed and audio.enabled) {
        // "snd q1472 u0": the stream's queue (samples) and underruns.
        i += put(buf[i..], "\nsnd q");
        i += put_num(buf[i..], audio.queued());
        i += put(buf[i..], " u");
        i += put_num(buf[i..], audio.underruns());
    }
    text.draw(buf[0..i], 0, 0, .rgb(0xFFFFFF), .rgb(if (alarm) 0xFF0000 else 0x000000));
}

pub fn put(dst: []u8, s: []const u8) usize {
    @memcpy(dst[0..s.len], s);
    return s.len;
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
    for (0..n) |k| dst[k] = tmp[n - 1 - k];
    return n;
}

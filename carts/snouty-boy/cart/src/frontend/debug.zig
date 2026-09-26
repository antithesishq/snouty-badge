//! FPS and step_frame microseconds overlay (SPEC.md section 14). Owner: track C.
const cart = @import("cart-api");

pub var enabled: bool = true;

var samples: [60]u32 = @splat(0);
var idx: usize = 0;
var count: u32 = 0;
var last_us: u32 = 0;

pub fn record(step_us: u32) void {
    samples[idx] = step_us;
    idx = (idx + 1) % samples.len;
    count +|= 1;
    last_us = step_us;
}

pub fn draw() void {
    if (!enabled) return;
    var min: u32 = 0xFFFF_FFFF;
    var max: u32 = 0;
    var sum: u64 = 0;
    const n = @min(count, samples.len);
    if (n == 0) return;
    for (samples[0..n]) |s| {
        min = @min(min, s);
        max = @max(max, s);
        sum += s;
    }
    var buf: [32]u8 = undefined;
    const text = fmt_line(&buf, @intCast(sum / n), max);
    cart.text(.{ .str = text, .x = 1, .y = 1, .text_color = .rgb(0xFFFFFF), .background_color = .rgb(0x000000) });
}

/// "avg 1234us max 5678us" without std.fmt (keeps the cart small).
fn fmt_line(buf: *[32]u8, avg: u32, max: u32) []const u8 {
    var i: usize = 0;
    i += put(buf[i..], "avg ");
    i += put_num(buf[i..], avg);
    i += put(buf[i..], " max ");
    i += put_num(buf[i..], max);
    return buf[0..i];
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

//! HUD (SPEC 6.4): lap, race clock, speed, the bars and the message bar.
//! Draw only; reads `world.w`.
const cart = @import("cart-api");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const sim = @import("sim.zig");
const track = @import("track.zig");
const sprites = @import("sprites.zig");
const font = @import("font.zig");

pub const white = cart.DisplayColor.rgb(0xFCFBF9);
pub const coral = cart.DisplayColor.rgb(0xF18271);
pub const anti_black = cart.DisplayColor.rgb(0x16031B);
pub const orange = cart.DisplayColor.rgb(0xF59A3C);
pub const cyan = cart.DisplayColor.rgb(0x4FD8F0);
pub const dim = cart.DisplayColor.rgb(0x3A3340);

/// Distance of the HUD from the screen edges: the outermost pixels sit
/// under the badge's bezel (the HUD used 1-2 px before).
const margin: i32 = 4;

/// Message bar rows (SPEC 6.4: a centred bar at y 56).
const bar_y: i32 = 56;
const bar_h: u32 = 16;

/// Text with a one-pixel Anti-Black drop shadow so it reads over the floor
/// (font.zig, the M4 fast path).
pub fn text(str: []const u8, x: i32, y: i32, color: cart.DisplayColor) void {
    font.draw(str, x, y, .from_color(color), .from_color(anti_black));
}

pub fn centered(str: []const u8, y: i32, color: cart.DisplayColor) void {
    text(str, 80 - @as(i32, @intCast(str.len * 4)), y, color);
}

fn put_uint(out: []u8, v: u32, pad: u8) void {
    var n = v;
    var i = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = @intCast('0' + n % 10);
        n /= 10;
        if (n == 0) break;
    }
    while (i > 0) {
        i -= 1;
        out[i] = pad;
    }
}

/// Race clock as M'SS"CC from ticks (60 per second).
pub fn format_clock(out: *[7]u8, ticks: u32) void {
    const cs = ticks * 100 / 60;
    put_uint(out[0..1], (cs / 6000) % 10, '0');
    out[1] = '\'';
    put_uint(out[2..4], (cs / 100) % 60, '0');
    out[4] = '"';
    put_uint(out[5..7], cs % 100, '0');
}

/// Minimap (SPEC 6.4): the track outline drawn once per race from the
/// centerline into 1-bit buffers at 32 and 48 px (Select toggles), the
/// machines as 2x2 dots (traffic 1x1), bottom-right.
const minimap_sizes = [2]u8{ 32, 48 };
var minimap_buf: [2][48 * 48]u8 = undefined;
pub var minimap_large: bool = false;

pub fn init_minimap(t: *const track.Track) void {
    for (minimap_sizes, 0..) |size, k| {
        const buf = &minimap_buf[k];
        @memset(buf, 0);
        // Half-width stroke: plot each sample and the point one step toward the next.
        for (0..256) |i| {
            const a = t.sample(i);
            const b = t.sample((i + 1) & 255);
            var step: u32 = 0;
            while (step < 4) : (step += 1) {
                const x = (@as(i32, a.x) * (4 - @as(i32, @intCast(step))) + @as(i32, b.x) * @as(i32, @intCast(step))) >> 2;
                const y = (@as(i32, a.y) * (4 - @as(i32, @intCast(step))) + @as(i32, b.y) * @as(i32, @intCast(step))) >> 2;
                const mx: usize = @intCast(@divTrunc(x * size, 1024));
                const my: usize = @intCast(@divTrunc(y * size, 1024));
                buf[my * 48 + mx] = 1;
            }
        }
    }
}

fn draw_minimap() void {
    const k: usize = if (minimap_large) 1 else 0;
    const size: i32 = minimap_sizes[k];
    const x0: i32 = 160 - size - margin;
    const y0: i32 = 128 - size - margin;
    const buf = &minimap_buf[k];
    const line: cart.Pixel = .from_color(white);
    const bg: cart.Pixel = .from_color(anti_black);
    for (0..@intCast(size)) |x| {
        const col = &cart.framebuffer[@intCast(x0 + @as(i32, @intCast(x)))];
        for (0..@intCast(size)) |y| {
            const on = buf[y * 48 + x] != 0;
            // Dim checkerboard background so the floor shows through.
            if (on) {
                col[@intCast(y0 + @as(i32, @intCast(y)))] = line;
            } else if (((x + y) & 1) == 0) {
                col[@intCast(y0 + @as(i32, @intCast(y)))] = bg;
            }
        }
    }
    // Machines: traffic first (grey 1x1), rivals (2x2 livery), player (2x2 white) on top.
    const w = &world.w;
    var i: usize = w.active_count;
    while (i > 0) {
        i -= 1;
        const m = &w.machines[i];
        if (!m.active) continue;
        const mx = x0 + @divTrunc((m.x >> fixed.Q) * size, 1024);
        const my = y0 + @divTrunc((m.y >> fixed.Q) * size, 1024);
        const color: cart.DisplayColor = if (i == world.player) white else .rgb(sprites.livery_rgb[sprites.livery_of(i)]);
        const d: u32 = if (i >= 5) 1 else 2;
        cart.rect(.{ .x = mx, .y = my, .width = d, .height = d, .fill_color = color });
    }
}

fn rank_text(rank: u8) []const u8 {
    return switch (rank) {
        1 => "1ST",
        2 => "2ND",
        3 => "3RD",
        4 => "4TH",
        5 => "5TH",
        else => "---",
    };
}

/// Snapshot bar state for the HUD (set by main.zig each frame).
pub var snapshot_ticks: u32 = 0;
pub var snapshot_max: u32 = 180;
pub var rewinding: bool = false;

/// Every other scanline black over the whole frame (the rewind dim).
pub fn dim_scanlines() void {
    const black: cart.Pixel = .from_color(.{ .r = 0, .g = 0, .b = 0 });
    for (cart.framebuffer) |*col| {
        var y: usize = 1;
        while (y < 128) : (y += 2) col[y] = black;
    }
}

pub fn draw() void {
    const w = &world.w;
    const m = &w.machines[world.player];
    // Top-right: rank (only with rivals in the race), its shadow inside the margin.
    if (w.active_count > 1) text(rank_text(m.rank), 160 - margin - 25, margin, if (m.rank == 1) cyan else white);
    // Top-left: LAP n/3.
    var lap_buf: [7]u8 = "LAP 1/3".*;
    lap_buf[4] = '1' + @as(u8, @min(m.lap, tuning.laps - 1));
    lap_buf[6] = '0' + @as(u8, tuning.laps);
    text(&lap_buf, margin, margin, white);
    // Top-centre (x 66..122; the lap text ends at 60, the rank starts at 131): the race clock.
    var clock: [7]u8 = undefined;
    format_clock(&clock, if (m.finished) m.finish_tick else w.tick);
    text(&clock, 66, margin, white);
    // Bottom-left: speed in Tb/s, then the thermal bar.
    var spd_buf: [8]u8 = "   0Tb/s".*;
    const tbs: u32 = @intCast(@max(0, (sim.speed(m) * 80) >> fixed.Q));
    put_uint(spd_buf[0..4], @min(tbs, 9999), ' ');
    text(&spd_buf, margin, 102, white);
    draw_bar(margin, 112, @intCast(@max(0, m.thermal)), tuning.thermal_max, if (m.boost > 0) white else orange);
    // Overclock ready mark beside the bar when the bar can pay for one.
    if (m.thermal >= tuning.thermal_overclock_min and m.boost == 0) text("OC", margin + 42, 110, cyan);
    // The snapshot bar (cyan) under the thermal bar; `<<` blinks while rewinding.
    draw_bar(margin, 118, @intCast(snapshot_ticks), @intCast(snapshot_max), cyan);
    if (rewinding and (w.tick / 4) % 2 == 0) text("<<", margin + 42, 116, cyan);
    draw_minimap();
    draw_message();
}

/// A 40x4 bar: dark background, `value`/`max` of it in `color`.
pub fn draw_bar(x: i32, y: i32, value: i32, max: i32, color: cart.DisplayColor) void {
    cart.rect(.{ .x = x, .y = y, .width = 40, .height = 4, .fill_color = anti_black });
    const wdt: u32 = @intCast(@max(0, @min(40, @divTrunc(value * 40, max))));
    if (wdt > 0) cart.rect(.{ .x = x, .y = y, .width = wdt, .height = 4, .fill_color = color });
}

fn message_text(msg: world.Message) []const u8 {
    return switch (msg) {
        .none => "",
        .provisioning => "PROVISIONING",
        .three => "3",
        .two => "2",
        .one => "1",
        .deploy => "DEPLOY",
        .final_lap => "FINAL LAP",
        .committed => "COMMITTED",
        .fall => "SEGMENT FAULT",
        .meltdown => "THERMAL SHUTDOWN",
        .collision => "COLLISION",
        .killed => "JOB KILLED",
    };
}

fn draw_message() void {
    const w = &world.w;
    if (w.msg == .none) return;
    const str = message_text(w.msg);
    const color = switch (w.msg) {
        .fall, .meltdown, .collision, .killed => coral,
        .deploy, .committed => cyan,
        else => white,
    };
    cart.rect(.{ .x = 0, .y = bar_y, .width = cart.screen_width, .height = bar_h, .fill_color = anti_black });
    centered(str, bar_y + 4, color);
}

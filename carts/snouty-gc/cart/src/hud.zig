//! Forked from snouty-zero/cart/src/hud.zig at f8f6962.
//! HUD (SPEC 10): lap, race clock, rank, speed, BURST pips, the minimap and
//! the message bar, for the car this badge follows. Draw only; reads the
//! World. Zero's thermal and snapshot bars are gone; M1 adds the armor bar,
//! ammo and the kill feed, M2 the pickup box.
const cart = @import("cart-api");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const sim = @import("sim.zig");
const track = @import("track.zig");
const racers = @import("racers.zig");
const font = @import("font.zig");

pub const white = cart.DisplayColor.rgb(0xFCFBF9);
pub const coral = cart.DisplayColor.rgb(0xF18271);
pub const anti_black = cart.DisplayColor.rgb(0x16031B);
pub const orange = cart.DisplayColor.rgb(0xF59A3C);
pub const cyan = cart.DisplayColor.rgb(0x4FD8F0);
pub const dim = cart.DisplayColor.rgb(0x3A3340);

/// Distance of the HUD from the screen edges: nothing closer than 4 px
/// (Zero M5.2: the outermost pixels sit under the badge's bezel).
pub const margin: i32 = 4;

/// Message bar rows (a centred bar at y 56).
const bar_y: i32 = 56;
const bar_h: u32 = 16;

/// Text with a one-pixel Anti-Black drop shadow so it reads over the floor.
pub fn text(str: []const u8, x: i32, y: i32, color: cart.DisplayColor) void {
    font.draw(str, x, y, .from_color(color), .from_color(anti_black));
}

pub fn centered(str: []const u8, y: i32, color: cart.DisplayColor) void {
    text(str, 80 - @as(i32, @intCast(str.len * 4)), y, color);
}

pub fn put_uint(out: []u8, v: u32, pad: u8) void {
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

/// Minimap (SPEC 10): the track outline drawn once per race from the
/// centerline into a 32x32 1-bit buffer, cars as 2x2 dots in livery
/// colours, the followed car white on top, bottom-right. (Zero's Select
/// toggle to 48 px is gone: Select is look back.)
const minimap_size: i32 = 32;
var minimap_buf: [32 * 32]u8 = undefined;

pub fn init_minimap(t: *const track.Track) void {
    const size = minimap_size;
    @memset(&minimap_buf, 0);
    for (0..256) |i| {
        const a = t.sample(i);
        const b = t.sample((i + 1) & 255);
        var step: i32 = 0;
        while (step < 4) : (step += 1) {
            const x = (@as(i32, a.x) * (4 - step) + @as(i32, b.x) * step) >> 2;
            const y = (@as(i32, a.y) * (4 - step) + @as(i32, b.y) * step) >> 2;
            const mx: usize = @intCast(@divTrunc(x * size, 1024));
            const my: usize = @intCast(@divTrunc(y * size, 1024));
            minimap_buf[my * 32 + mx] = 1;
        }
    }
}

fn draw_minimap(w: *const world.World, follow: u8) void {
    const size = minimap_size;
    const x0: i32 = 160 - size - margin;
    const y0: i32 = 128 - size - margin;
    const line: cart.Pixel = .from_color(white);
    const bg: cart.Pixel = .from_color(anti_black);
    for (0..@intCast(size)) |x| {
        const col = &cart.framebuffer[@intCast(x0 + @as(i32, @intCast(x)))];
        for (0..@intCast(size)) |y| {
            // Dim checkerboard background so the floor shows through.
            if (minimap_buf[y * 32 + x] != 0) {
                col[@intCast(y0 + @as(i32, @intCast(y)))] = line;
            } else if (((x + y) & 1) == 0) {
                col[@intCast(y0 + @as(i32, @intCast(y)))] = bg;
            }
        }
    }
    // Cars in livery colours, the followed car last (white, on top).
    var k: usize = 0;
    while (k <= world.car_count) : (k += 1) {
        const i: usize = if (k == world.car_count) follow else k;
        if (k < world.car_count and k == follow) continue;
        const c = &w.cars[i % world.car_count];
        if (!c.active) continue;
        const mx = x0 + @divTrunc((c.x >> fixed.Q) * size, 1024);
        const my = y0 + @divTrunc((c.y >> fixed.Q) * size, 1024);
        const color: cart.DisplayColor = if (i == follow) white else .rgb(racers.roster[c.racer % racers.count].livery);
        cart.rect(.{ .x = mx, .y = my, .width = 2, .height = 2, .fill_color = color });
    }
}

pub fn rank_text(rank: u8) []const u8 {
    return switch (rank) {
        1 => "1ST",
        2 => "2ND",
        3 => "3RD",
        4 => "4TH",
        5 => "5TH",
        6 => "6TH",
        else => "---",
    };
}

/// The race HUD for car `follow`.
pub fn draw(w: *const world.World, follow: u8) void {
    const c = &w.cars[follow % world.car_count];
    // Top-right: rank.
    text(rank_text(c.rank), 160 - margin - 25, margin, if (c.rank == 1) cyan else white);
    // Top-left: LAP n/3.
    var lap_buf: [7]u8 = "LAP 1/3".*;
    lap_buf[4] = '1' + @as(u8, @min(c.lap, tuning.laps - 1));
    lap_buf[6] = '0' + @as(u8, tuning.laps);
    text(&lap_buf, margin, margin, white);
    // Top-centre (x 66..122; the lap text ends at 60, the rank starts at 131): the race clock.
    var clock: [7]u8 = undefined;
    format_clock(&clock, if (c.finished) c.finish_tick else w.tick);
    text(&clock, 66, margin, white);
    // Bottom-left: speed, then the BURST pips (cyan while one burns).
    var spd_buf: [7]u8 = "  0 MPH".*;
    const mph: u32 = @intCast(@max(0, (sim.speed(c) * 80) >> fixed.Q));
    put_uint(spd_buf[0..3], @min(mph, 999), ' ');
    text(&spd_buf, margin, 108, white);
    text("BURST", margin, 118, if (c.burst > 0) cyan else dim);
    var k: u8 = 0;
    while (k < tuning.burst_per_lap) : (k += 1) {
        const lit = k < c.burst_charges;
        cart.rect(.{ .x = margin + 42 + @as(i32, k) * 6, .y = 119, .width = 4, .height = 6, .fill_color = if (lit) orange else dim });
    }
    draw_minimap(w, follow);
    draw_message(w, c);
}

fn message_text(msg: world.Message) []const u8 {
    return switch (msg) {
        .none => "",
        .ready => "SCAVENGERS READY",
        .three => "3",
        .two => "2",
        .one => "1",
        .go => "GO",
        .final_lap => "FINAL LAP",
        .finished => "FINISHED",
        .fall => "SEGMENT FAULT",
    };
}

/// The followed car's own message first, else the shared one (countdown).
fn draw_message(w: *const world.World, c: *const world.Car) void {
    const msg = if (c.msg != .none) c.msg else w.msg;
    if (msg == .none) return;
    const color = switch (msg) {
        .fall => coral,
        .go, .finished => cyan,
        else => white,
    };
    cart.rect(.{ .x = 0, .y = bar_y, .width = cart.screen_width, .height = bar_h, .fill_color = anti_black });
    centered(message_text(msg), bar_y + 4, color);
}

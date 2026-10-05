//! Forked from snouty-zero/cart/src/hud.zig at f8f6962.
//! HUD (SPEC 10), for the car this badge follows: lap, rank and the
//! pickup box along the top, the kill feed under them, the taunt pop-up
//! top left, the message bar, and bottom left the speed, BURST bolts,
//! front ammo count, rear ammo pips and the armor bar; the minimap bottom
//! right; `ACK` over cars the followed car hits, the SPEAR PHISH reticle
//! on its lock and `BEHIND` while looking back. Draw only: reads the World
//! and fx.zig's notices. Nothing is drawn closer than 4 px to an edge.
//!
//! M2 (pickups, SPEC 6.3): the pickup box shows the held pickup or the
//! roulette (`FETCHING...`, then the pickup's name), tags over cars
//! (KERNEL PANIC `:(`, CAPTCHA grid, SUDO `#`), the pickup feed lines, and
//! the gags on the followed car's badge: the KERNEL PANIC blue screen,
//! BIT FLIP (blinking mirrored, the floor's row jitter is render.zig's),
//! the CAPTCHA mini-game, DDOS's stuttering speed, the ZERO-DAY flash and
//! the RACE CONDITION glitch.
//!
//! M3: `LAP n/N` from `World.laps`; GARBAGE COLLECTION shows `SWEEP n`
//! with a bar filling as the leader nears the next sweep point, `MARKED`
//! over the marked car (blinking red on the minimap), the feed's MARKED,
//! TAGGED and `GC: freed` lines, the bar notes (MARKED, TAGGED, MARK
//! PASSED, COLLECTED); a badge watching another car (the attract demo, a
//! collected player) gets the watched racer's name instead of its own
//! speed, ammo and pickup caption, and the attract demo `PRESS START`.
const std = @import("std");
const cart = @import("cart-api");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const sim = @import("sim.zig");
const track = @import("track.zig");
const racers = @import("racers.zig");
const roster_text = @import("roster_text.zig");
const font = @import("font.zig");
const sprites = @import("sprites.zig");
const fx = @import("fx.zig");
const assets = @import("assets");
const gc_mode = @import("gc_mode.zig");

pub const white = cart.DisplayColor.rgb(0xFCFBF9);
pub const coral = cart.DisplayColor.rgb(0xF18271);
pub const anti_black = cart.DisplayColor.rgb(0x16031B);
pub const orange = cart.DisplayColor.rgb(0xF59A3C);
pub const cyan = cart.DisplayColor.rgb(0x4FD8F0);
pub const dim = cart.DisplayColor.rgb(0x3A3340);
pub const grey = cart.DisplayColor.rgb(0x9690A4);
pub const green = cart.DisplayColor.rgb(0x40D070);
pub const yellow = cart.DisplayColor.rgb(0xF0D040);
pub const red = cart.DisplayColor.rgb(0xE83838);

/// Distance of the HUD from the screen edges: nothing closer than 4 px
/// (Zero M5.2: the outermost pixels sit under the badge's bezel).
pub const margin: i32 = 4;

/// Rows (SPEC 10 layout, moved down where the 8x8 font needs it).
const top_y: i32 = margin;
const behind_y: i32 = 13;
const feed_y: i32 = 23;
const popup_y0: i32 = 33;
const bar_y: i32 = 62;
const bar_h: u32 = 16;
/// The bottom-left stack stays left of x 61: the followed car's sprite
/// spans x 64..96 above y 118.
const speed_y: i32 = 88;
const front_y: i32 = 98;
const rear_y: i32 = 108;
const armor_y: i32 = 117;
/// The pickup box (M2 fills it): 16x16 icon in a 1 px frame, top right.
const box_x: i32 = 160 - margin - 18;
/// The roulette's caption and the landed pickup's name: right-aligned
/// against the box, on the row under the rank (BEHIND's row).
const caption_y: i32 = 13;
const caption_right: i32 = box_x - 2;
/// The roulette's length (the sim's 45 ticks at a crate).
const roll_total: u32 = 45;

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

pub fn livery(racer: u8) cart.DisplayColor {
    return .rgb(roster_text.color[racer % roster_text.count]);
}

pub fn name_of(racer: u8) []const u8 {
    return racers.roster[racer % racers.count].name;
}

/// The down arrow of the `Down+A` glyph (the font has none): 5x6 at (x, y).
pub fn down_arrow(x: i32, y: i32, color: cart.DisplayColor) void {
    fill_rect(x + 2, y, 1, 4, color);
    fill_rect(x, y + 3, 5, 1, color);
    fill_rect(x + 1, y + 4, 3, 1, color);
    fill_rect(x + 2, y + 5, 1, 1, color);
}

/// Minimap (SPEC 10): the track outline drawn once per race from the
/// centerline into a 32x32 1-bit buffer, cars as 2x2 dots in livery
/// colours, the followed car white on top, bottom-right.
const minimap_size: i32 = 32;
var minimap_buf: [32 * 32]u8 = undefined;

/// The track outline of the last `init_minimap`, 32x32 at (x, y) (the
/// select's track row).
pub fn draw_outline(x0: i32, y0: i32, color: cart.DisplayColor) void {
    const px: cart.Pixel = .from_color(color);
    for (0..32) |x| {
        const col = &cart.framebuffer[@intCast(x0 + @as(i32, @intCast(x)))];
        for (0..32) |y| {
            if (minimap_buf[y * 32 + x] != 0) col[@intCast(y0 + @as(i32, @intCast(y)))] = px;
        }
    }
}

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

fn draw_minimap(w: *const world.World, follow: u8, frame: u32) void {
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
    // A Sweeper on its run, as a 2x2 orange block (M3).
    for (track.hazard_specs[0..track.hazard_n], 0..) |*h, k| {
        if (h.kind != .mover) continue;
        const hz = &w.hazards[k];
        if (hz.state == .idle and (frame / 16) % 2 == 1) continue;
        const mx = x0 + @divTrunc((hz.x >> fixed.Q) * size, 1024);
        const my = y0 + @divTrunc((hz.y >> fixed.Q) * size, 1024);
        cart.rect(.{ .x = @min(mx, x0 + size - 2), .y = @min(my, y0 + size - 2), .width = 2, .height = 2, .fill_color = orange });
    }
    // Cars in livery colours, the followed car last (white, on top); a
    // wrecked car blinks; the MARKED car blinks red (GARBAGE COLLECTION).
    var k: usize = 0;
    while (k <= world.car_count) : (k += 1) {
        const i: usize = if (k == world.car_count) follow else k;
        if (k < world.car_count and k == follow) continue;
        const c = &w.cars[i % world.car_count];
        if (!c.active) continue;
        if (c.wreck != .none and (frame / 8) % 2 == 1) continue;
        const mx = x0 + @divTrunc((c.x >> fixed.Q) * size, 1024);
        const my = y0 + @divTrunc((c.y >> fixed.Q) * size, 1024);
        var color: cart.DisplayColor = if (i == follow) white else livery(c.racer);
        if (i == w.gc.marked) {
            if ((frame / 6) % 2 == 1) continue;
            color = red;
        }
        cart.rect(.{ .x = @min(mx, x0 + size - 2), .y = @min(my, y0 + size - 2), .width = 2, .height = 2, .fill_color = color });
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

pub const Options = struct {
    frame: u32 = 0,
    /// Select held: `BEHIND` over the horizon.
    look_back: bool = false,
    /// This badge watches `follow` (the attract demo, a collected player):
    /// the racer's name instead of the speed, ammo and pickup caption.
    spectate: bool = false,
    /// GARBAGE COLLECTION collected this badge's player.
    collected: bool = false,
    /// The attract demo: `PRESS START` blinks.
    press_start: bool = false,
};

/// The race HUD for car `follow`. Call after the sprites (it reads where
/// they drew the cars).
pub fn draw(w: *const world.World, follow: u8, o: Options) void {
    const c = &w.cars[follow % world.car_count];
    draw_markers(w, c, follow, o.frame);
    // Top row: LAP n/N (GARBAGE COLLECTION: SWEEP n) left, the rank in the
    // middle, the pickup box right.
    if (w.mode == .gc) {
        draw_sweep(w);
    } else {
        const laps: u8 = @max(1, @min(9, w.laps));
        var lap_buf: [7]u8 = "LAP 1/3".*;
        lap_buf[4] = '1' + @as(u8, @min(c.lap, laps - 1));
        lap_buf[6] = '0' + laps;
        text(&lap_buf, margin, top_y, white);
    }
    if (c.active) text(rank_text(c.rank), 80 - 12, top_y, if (c.rank == 1) cyan else white);
    draw_pickup_box(c, follow, o.frame, o.look_back or o.spectate);
    if (o.look_back) centered("BEHIND", behind_y, coral);
    if (o.spectate and c.active) centered(name_of(c.racer), behind_y, livery(c.racer));
    const two_line = draw_feed();
    if (!o.spectate) draw_popup(if (two_line) 9 else 0);
    if (o.collected) {
        // Bottom left, where the badge's own armor bar was (the watched
        // car's MARKED tag sits higher).
        text("COLLECTED", margin, 116, coral);
    } else if (!o.spectate) {
        draw_bottom_left(w, c, follow, o.frame);
    }
    draw_minimap(w, follow, o.frame);
    if (!draw_message(w, c, o.spectate) and o.press_start and (o.frame / 30) % 2 == 0) centered("PRESS START", bar_y + 4, white);
    if (c.bit_flip > 0 and c.wreck == .none) draw_bit_flip(o.frame);
    if (captcha_up(c)) draw_captcha(c, o.frame);
}

// --- The pickup box (SPEC 6.3) ---------------------------------------------------

/// Top right: the held pickup, or the roulette while `roll_ticks > 0`
/// (cells flick by, slowing, and land on the hidden result at 0), blank
/// when empty. The caption beside it: `FETCHING...`, then the name.
fn draw_pickup_box(c: *const world.Car, follow: u8, frame: u32, look_back: bool) void {
    const rolling = c.roll_ticks > 0;
    const landing = fx.land_ticks > fx.land_show - 20 and c.pickup != .none;
    const stroke = if (rolling) cyan else if (landing and (frame / 3) % 2 == 0) white else if (c.pickup != .none) yellow else grey;
    cart.rect(.{ .x = box_x, .y = top_y, .width = 18, .height = 18, .stroke_color = stroke, .fill_color = anti_black });
    var cell: u32 = sprites.p_blank;
    if (rolling) {
        // Position along the reel, decelerating: t (100 - t) / 60 cells.
        const t: u32 = roll_total - @min(@as(u32, c.roll_ticks), roll_total);
        const pos = t * (100 - t) / 60;
        cell = (pos * 7 + @as(u32, follow) * 5) % 15;
    } else if (c.pickup != .none) {
        cell = @backingInt(c.pickup);
    }
    sprites.blit_at(&sprites.pickups, cell, box_x + 1, top_y + 1, .{});
    if (look_back) return;
    if (rolling) {
        var buf: [11]u8 = "FETCHING   ".*;
        const dots: usize = (frame / 6) % 4;
        for (0..dots) |k| buf[8 + k] = '.';
        text(&buf, caption_right - 88, caption_y, cyan);
    } else if (fx.land_ticks > 0 and c.pickup != .none) {
        const name = roster_text.pickup_name(c.pickup);
        text(name, caption_right - @as(i32, @intCast(name.len * 8)), caption_y, yellow);
    }
}

/// `ACK` over cars the followed car hit, and the SPEAR PHISH reticle on its lock.
fn draw_markers(w: *const world.World, c: *const world.Car, follow_index: usize, frame: u32) void {
    // GARBAGE COLLECTION: `MARKED` over the marked car, red and white.
    var tag_up: i32 = 0;
    if (w.gc.marked < world.car_count) {
        const s = sprites.car_screen[w.gc.marked];
        if (s.visible) {
            const y = s.top - 11;
            // Over the badge's own car, clear of the speed reading.
            const x = if (w.gc.marked == follow_index) @max(62, s.sx - 24) else s.sx - 24;
            text("MARKED", x, y, if ((frame / 8) % 2 == 0) red else white);
        }
    }
    for (&fx.acks) |*a| {
        if (a.ticks == 0) continue;
        const s = sprites.car_screen[a.car % world.car_count];
        if (!s.visible) continue;
        const rise: i32 = @divTrunc(@as(i32, fx.ack_ticks - a.ticks), 3);
        sprites.blit_at(&sprites.icons, sprites.i_ack, s.sx - 6, s.top - 13 - rise, .{});
    }
    // Pickup tags over the cars: KERNEL PANIC `:(`, the CAPTCHA grid (not
    // over a followed human, who plays it), SUDO's `#`.
    for (&w.cars, 0..) |*o, i| {
        if (o.wreck != .none or !o.active) continue;
        const s = sprites.car_screen[i];
        if (!s.visible) continue;
        const own_game = i == follow_index and o.human != world.no_human;
        const tag: u32 = if (o.frozen > 0 and o.frozen_by == .panic) sprites.i_panic else if (o.captcha > 0 and !own_game) sprites.i_captcha else if (o.sudo > 0) sprites.i_sudo else continue;
        // Over the MARKED tag when there is one.
        tag_up = if (i == w.gc.marked) 10 else 0;
        sprites.blit_at(&sprites.icons, tag, s.sx - 6, s.top - 13 - tag_up, .{});
    }
    if (c.lock < world.car_count and c.wreck == .none) {
        const s = sprites.car_screen[c.lock];
        if (s.visible) {
            const cell: u32 = sprites.i_lock + @as(u32, @intFromBool((frame / 6) % 2 == 1));
            sprites.blit_at(&sprites.icons, cell, s.sx - 6, @divTrunc(s.top + s.sy, 2) - 6, .{});
        }
    }
}

/// Kill feed (SPEC 5.3): `KILLER > VICTIM` in their livery colours, or
/// the victim and the cause for an uncredited wreck. M2: pickup lines
/// (`KERNEL PANIC > KIDDIE`) and RACE CONDITION swaps (`SNOUTY <> KIDDIE`).
/// M3: `KIDDIE MARKED`, `LEGACY TAGGED KIDDIE`, `GC: freed KIDDIE` and
/// hazard hits (`VENT > KIDDIE`). A line wider than the screen breaks
/// after the middle word into two rows. Returns whether it took two rows
/// (the pop-up moves down).
fn draw_feed() bool {
    const f = &fx.feed;
    if (f.ticks == 0) return false;
    const victim = name_of(f.victim);
    var left: []const u8 = "";
    var left_color = white;
    var right: []const u8 = victim;
    var right_color = livery(f.victim);
    var mid: []const u8 = " > ";
    switch (f.kind) {
        .swap => {
            left = if (f.killer < world.car_count) name_of(f.killer) else "";
            left_color = livery(f.killer);
            mid = " <> ";
        },
        .pickup => {
            left = roster_text.pickup_name(f.pickup);
            left_color = coral;
        },
        .hazard => {
            left = if (f.hazard == .mover) "SWEEPER" else "VENT";
            left_color = orange;
        },
        .marked => {
            left = victim;
            left_color = livery(f.victim);
            mid = " ";
            right = "MARKED";
            right_color = red;
        },
        .tagged => {
            left = if (f.killer < world.car_count) name_of(f.killer) else "";
            left_color = livery(f.killer);
            mid = " TAGGED ";
        },
        .freed => {
            left = "GC:";
            left_color = cyan;
            mid = " freed ";
        },
        .wreck => if (f.cause == .zero_day) {
            left = "ZERO-DAY";
            left_color = coral;
        } else if (f.killer < world.car_count) {
            left = name_of(f.killer);
            left_color = livery(f.killer);
        } else {
            left = victim;
            left_color = livery(f.victim);
            mid = " ";
            right = if (f.cause == .fall) "SEGFAULT" else "WRECKED";
            right_color = coral;
        },
    }
    const len: i32 = @intCast(left.len + mid.len + right.len);
    if (len * 8 > 160 - 2 * margin) {
        // Two rows: `KERNEL PANIC >` and the victim under it.
        const m = mid[0 .. mid.len - 1];
        const l1: i32 = @intCast(left.len + m.len);
        var x: i32 = 80 - l1 * 4;
        text(left, x, feed_y, left_color);
        x += @as(i32, @intCast(left.len)) * 8;
        text(m, x, feed_y, white);
        text(right, 80 - @as(i32, @intCast(right.len * 4)), feed_y + 9, right_color);
        return true;
    }
    var x: i32 = 80 - len * 4;
    text(left, x, feed_y, left_color);
    x += @as(i32, @intCast(left.len)) * 8;
    text(mid, x, feed_y, white);
    x += @as(i32, @intCast(mid.len)) * 8;
    text(right, x, feed_y, right_color);
    return false;
}

/// GARBAGE COLLECTION's top left: `SWEEP n` (the next sweep point, from
/// 1) and under it a 40 px bar filling as the race leader nears it.
fn draw_sweep(w: *const world.World) void {
    var buf: [8]u8 = "SWEEP 1 ".*;
    // The next sweep point; once a survivor is left, the last one.
    const next: u32 = if (w.gc.survivor != world.no_car) w.gc.sweeps else @as(u32, w.gc.sweeps) + 1;
    const n: u8 = @intCast(@max(1, @min(next, 99)));
    var len: usize = 7;
    if (n >= 10) {
        buf[6] = '0' + n / 10;
        buf[7] = '0' + n % 10;
        len = 8;
    } else buf[6] = '0' + n;
    text(buf[0..len], margin, top_y, if (w.gc.survivor != world.no_car) grey else white);
    if (w.gc.survivor != world.no_car) return;
    var lead: i32 = std.math.minInt(i32);
    for (&w.cars) |*o| {
        if (o.active) lead = @max(lead, sim.fine_progress(w, o));
    }
    const to = gc_mode.sweep_at(w.gc.sweeps);
    const from = if (w.gc.sweeps == 0) 0 else gc_mode.sweep_at(w.gc.sweeps - 1);
    const span = @max(1, to - from);
    const fill: i32 = @max(0, @min(40, @divTrunc((lead - from) * 40, span)));
    fill_rect(margin, top_y + 9, 40, 2, dim);
    if (fill > 0) fill_rect(margin, top_y + 9, fill, 2, if (fill > 32) red else coral);
}

/// Taunt pop-up (SPEC 5.3, 10): the racer's half-scale portrait in a
/// livery frame, their name and the line wrapped in two.
fn draw_popup(down: i32) void {
    const popup_y = popup_y0 + down;
    const p = &fx.popup;
    if (p.ticks == 0) return;
    const r = p.racer % roster_text.count;
    const line = if (p.wrecked) roster_text.roster[r].wrecked else roster_text.roster[r].taunt;
    const k = roster_text.wrap(line, 15);
    const l1 = line[0..k];
    const l2 = if (k < line.len) line[k + 1 ..] else "";
    const name = name_of(r);
    const chars: i32 = @intCast(@max(name.len, @max(l1.len, l2.len)));
    const x0: i32 = margin;
    const w: u32 = @intCast(26 + 4 + chars * 8 + 2);
    const dx: i32 = 0;
    cart.rect(.{ .x = x0 + dx, .y = popup_y, .width = w, .height = 27, .fill_color = anti_black, .stroke_color = livery(r) });
    sprites.blit_rect(&sprites.portraits[r], 0, 0, 48, 48, x0 + dx + 1, popup_y + 1, 24, 24, .{});
    const tx = x0 + dx + 30;
    text(name, tx, popup_y + 1, livery(r));
    text(l1, tx, popup_y + 10, white);
    text(l2, tx, popup_y + 18, white);
}

/// Bottom left: speed and BURST bolts; front ammo count and rear ammo
/// pips; the armor bar (green to red, flashes white when hit).
fn draw_bottom_left(w: *const world.World, c: *const world.Car, follow: u8, frame: u32) void {
    var spd_buf: [7]u8 = "  0 MPH".*;
    const mph: u32 = @intCast(@max(0, (sim.speed(c) * 80) >> fixed.Q));
    put_uint(spd_buf[0..3], @min(mph, 999), ' ');
    // DDOS: while drones orbit the car the reading stutters (and serves a 503).
    const ddos = ddos_on(w, follow);
    const phase = (frame / 5) % 4;
    if (ddos and phase == 2) put_uint(spd_buf[0..3], 503, ' ');
    if (!(ddos and phase == 3)) text(&spd_buf, margin, speed_y, if (ddos and phase == 2) coral else white);
    // Front: A and the count, then the BURST bolts (dim once spent,
    // flashing while one burns).
    const liv = livery(c.racer);
    text("A", margin, front_y, liv);
    var ammo_buf: [3]u8 = undefined;
    put_uint(&ammo_buf, @min(c.ammo_front, 999), ' ');
    const digits: []const u8 = if (c.ammo_front >= 100) ammo_buf[0..] else if (c.ammo_front >= 10) ammo_buf[1..] else ammo_buf[2..];
    text(digits, margin + 10, front_y, if (c.ammo_front == 0) coral else white);
    var k: u8 = 0;
    while (k < @max(tuning.burst_per_lap, c.burst_charges) and k < 2) : (k += 1) {
        const x = margin + 34 + @as(i32, k) * 11;
        const lit = k < c.burst_charges;
        const burning = c.burst > 0 and k == c.burst_charges and (frame / 3) % 2 == 0;
        sprites.blit_at(&sprites.icons, sprites.i_burst, x, front_y - 2, .{
            .flat = if (lit) null else if (burning) @as(?cart.Pixel, .from_color(white)) else .from_color(dim),
        });
    }
    // Rear: Down+A and a pip per drop left.
    down_arrow(margin, rear_y + 1, liv);
    text("A", margin + 6, rear_y, liv);
    var j: u8 = 0;
    while (j < c.ammo_rear and j < 6) : (j += 1) {
        cart.rect(.{ .x = margin + 17 + @as(i32, j) * 5, .y = rear_y + 1, .width = 3, .height = 6, .fill_color = orange });
    }
    if (c.ammo_rear == 0) text("-", margin + 16, rear_y, dim);
    // Armor: 40x4 in a 1 px frame.
    const max: u32 = @max(1, c.armor_max);
    const fill: u32 = @min(40, (@as(u32, c.armor) * 40 + max - 1) / max);
    const pct: u32 = @as(u32, c.armor) * 100 / max;
    const flash = fx.armor_flash > 0 and (fx.armor_flash / 2) % 2 == 0;
    const color = if (flash) white else if (pct > 60) green else if (pct > 30) yellow else red;
    cart.rect(.{ .x = margin, .y = armor_y, .width = 42, .height = 6, .stroke_color = grey, .fill_color = anti_black });
    if (fill > 0) fill_rect(margin + 1, armor_y + 1, fill, 4, color);
}

fn message_text(msg: world.Message) []const u8 {
    // An if-chain, so Track A's new messages draw nothing until named here.
    if (msg == .ready) return "SCAVENGERS READY";
    if (msg == .three) return "3";
    if (msg == .two) return "2";
    if (msg == .one) return "1";
    if (msg == .go) return "GO";
    if (msg == .final_lap) return "FINAL LAP";
    if (msg == .finished) return "FINISHED";
    if (msg == .fall) return "SEGMENT FAULT";
    return "";
}

/// The bar: the followed car's wreck note first, then a GARBAGE
/// COLLECTION note, then its own message, else the shared one
/// (countdown). Returns whether it drew. Spectating, only the shared one.
fn draw_message(w: *const world.World, c: *const world.Car, spectate: bool) bool {
    var buf: [20]u8 = undefined;
    var str: []const u8 = "";
    var color = white;
    const note = &fx.wreck_note;
    if (spectate) {
        if (w.msg == .none) return false;
        str = message_text(w.msg);
    } else if (fx.gc_note_ticks > 0 and fx.gc_note != .none and fx.gc_note != .collected) {
        str = switch (fx.gc_note) {
            .none => "",
            .marked => "MARKED! TAG SOMEONE",
            .tagged => "TAGGED! PASS IT ON",
            .passed => "MARK PASSED",
            // The claw is lifting the car out: the label says it, the bar
            // would hide the lift.
            .collected => "",
        };
        color = if (fx.gc_note == .passed) green else red;
    } else if (note.ticks > 0) {
        color = coral;
        if (note.cause == .zero_day) {
            str = "ZERO-DAY";
        } else if (note.killer < world.car_count) {
            const name = name_of(w.cars[note.killer].racer);
            const head = "WRECKED BY ";
            @memcpy(buf[0..head.len], head);
            @memcpy(buf[head.len..][0..name.len], name);
            str = buf[0 .. head.len + name.len];
        } else {
            str = "WRECKED";
        }
    } else if (fx.verified > 0 and c.msg == .none) {
        // A CAPTCHA solved before the wait ran out.
        str = "HUMAN VERIFIED";
        color = green;
    } else {
        const msg = if (c.msg != .none) c.msg else w.msg;
        if (msg == .none) return false;
        str = message_text(msg);
        color = if (msg == .fall) coral else if (msg == .go or msg == .finished) cyan else white;
    }
    if (str.len == 0) return false;
    fill_rect(0, bar_y, cart.screen_width, bar_h, anti_black);
    centered(str, bar_y + 4, color);
    return true;
}

// --- The gags on the followed car's badge (SPEC 6.3, 10) -----------------------------

/// A DDOS swarm orbits car `i`.
fn ddos_on(w: *const world.World, i: u8) bool {
    for (&w.drones) |*d| {
        if (d.state == .orbit and d.target == i) return true;
    }
    return false;
}

const glyphs: *const [96 * 8]u8 = assets.font[0 .. 96 * 8];

/// `str` in the 8x8 font, each glyph `scale` x `scale` px a pixel, or
/// mirrored left to right (`mirror`), no shadow.
pub fn glyph_text(str: []const u8, x: i32, y: i32, scale: i32, mirror: bool, color: cart.DisplayColor) void {
    var cx = x;
    for (0..str.len) |n| {
        // A mirror image reads right to left too.
        const ch = if (mirror) str[str.len - 1 - n] else str[n];
        defer cx += 8 * scale;
        const code: usize = if (ch < 32 or ch > 127) '?' - 32 else ch - 32;
        const g = glyphs[code * 8 ..][0..8];
        for (0..8) |row| {
            // The glyphs use columns 0..6; a mirror reads them 6..0.
            for (0..7) |col| {
                const bit: u3 = @intCast(if (mirror) 6 - col else col);
                if (g[row] & (@as(u8, 0x80) >> bit) == 0) continue;
                cart.rect(.{ .x = cx + @as(i32, @intCast(col)) * scale, .y = y + @as(i32, @intCast(row)) * scale, .width = @intCast(scale), .height = @intCast(scale), .fill_color = color });
            }
        }
    }
}

const flip_y: i32 = 78;
const purple = cart.DisplayColor.rgb(0xB070FF);

/// BIT FLIP: `BIT FLIP` blinking between itself and its mirror image,
/// between a left arrow marked R and a right arrow marked L: the stick's
/// sides are swapped. Under the message bar, over the car.
fn draw_bit_flip(frame: u32) void {
    const mirrored = (frame / 8) % 2 == 1;
    const x0: i32 = 80 - 4 * 14;
    fill_rect(x0 - 2, flip_y - 1, 14 * 8 + 3, 10, anti_black);
    text("<R", x0, flip_y, white);
    glyph_text("BIT FLIP", x0 + 24, flip_y, 1, mirrored, if (mirrored) purple else cyan);
    text("L>", x0 + 96, flip_y, white);
}

// The CAPTCHA mini-game: a reCAPTCHA card over the floor.
const cap_x: i32 = margin;
const cap_y: i32 = 25;
const cap_w: i32 = 160 - 2 * margin;
const cap_h: i32 = 99;
const cap_cell: i32 = 16;
/// The 3x3 grid (1 px gutters), centred on x 80.
const grid_x: i32 = 80 - 26;
const grid_y: i32 = cap_y + 34;
const cap_blue = cart.DisplayColor.rgb(0x4A90E2);
const cap_card = cart.DisplayColor.rgb(0xF9F9F9);
const cap_edge = cart.DisplayColor.rgb(0xC8C8C8);
const sky = cart.DisplayColor.rgb(0x9CC8E8);
const road = cart.DisplayColor.rgb(0x707070);
const road_line = cart.DisplayColor.rgb(0xE0E0E0);
const leaf = cart.DisplayColor.rgb(0x3C8C3C);
const brick = cart.DisplayColor.rgb(0xA05A3C);
const window_px = cart.DisplayColor.rgb(0xF0E090);
const lamp_dark = cart.DisplayColor.rgb(0x202020);
const lamp_red = cart.DisplayColor.rgb(0xFF3030);
const lamp_amber = cart.DisplayColor.rgb(0xF0A020);
const lamp_green = cart.DisplayColor.rgb(0x30E060);
const tick_blue = cart.DisplayColor.rgb(0x1A73E8);
/// Seconds of the human's longest wait (the sim frees the car at 120).
const captcha_wait: u32 = 120;

/// A filled rectangle written straight into the framebuffer, clipped
/// (M3: the API's `rect` was 9% of a stress frame under ReleaseSmall).
pub fn fill_rect(x: i32, y: i32, w: anytype, h: anytype, color: cart.DisplayColor) void {
    const px: cart.Pixel = .from_color(color);
    const xa: i32 = @max(0, x);
    const xb: i32 = @min(160, x + @as(i32, @intCast(w)));
    const ya: usize = @intCast(@max(0, y));
    const yb: i32 = @min(128, y + @as(i32, @intCast(h)));
    if (xa >= xb or @as(i32, @intCast(ya)) >= yb) return;
    const n: usize = @intCast(yb - @as(i32, @intCast(ya)));
    var cx = xa;
    while (cx < xb) : (cx += 1) @memset(cart.framebuffer[@intCast(cx)][ya..][0..n], px);
}

/// SPEC 6.3: "you play it". The sim runs the game from this badge's
/// buttons (A on a lit cell clears it, on an unlit one clears the board);
/// this draws `captcha_lit` as traffic lights, `captcha_done` as ticked
/// cells and the cursor on `captcha_cursor`, with the wait bar and
/// `PRESS A` (`TRY AGAIN` after a miss).
fn draw_captcha(c: *const world.Car, frame: u32) void {
    fill_rect(cap_x, cap_y, cap_w, cap_h, cap_edge);
    fill_rect(cap_x + 1, cap_y + 1, cap_w - 2, cap_h - 2, cap_card);
    // The header: SELECT ALL / SQUARES WITH / TRAFFIC LIGHTS.
    fill_rect(cap_x + 3, cap_y + 3, cap_w - 6, 28, cap_blue);
    font.draw("SELECT ALL", 80 - 40, cap_y + 5, .from_color(white), null);
    font.draw("SQUARES WITH", 80 - 48, cap_y + 13, .from_color(white), null);
    font.draw("TRAFFIC LIGHTS", 80 - 56, cap_y + 21, .from_color(white), .from_color(anti_black));
    // The grid on a dark gutter.
    fill_rect(grid_x, grid_y, 3 * cap_cell + 4, 3 * cap_cell + 4, white);
    var k: u32 = 0;
    while (k < 9) : (k += 1) {
        const cx = grid_x + 1 + @as(i32, @intCast(k % 3)) * (cap_cell + 1);
        const cy = grid_y + 1 + @as(i32, @intCast(k / 3)) * (cap_cell + 1);
        const bit = @as(u16, 1) << @intCast(k);
        const lit = c.captcha_lit & bit != 0;
        const done = c.captcha_done & bit != 0;
        if (done) {
            // Ticked: the picture shrinks inside a white rim, a blue tick on it.
            draw_scene(k, lit, cx + 2, cy + 2, cap_cell - 4);
            fill_rect(cx, cy, 7, 7, tick_blue);
            fill_rect(cx + 1, cy + 3, 1, 2, white);
            fill_rect(cx + 2, cy + 4, 1, 1, white);
            fill_rect(cx + 3, cy + 3, 1, 1, white);
            fill_rect(cx + 4, cy + 2, 1, 1, white);
            fill_rect(cx + 5, cy + 1, 1, 1, white);
        } else {
            draw_scene(k, lit, cx, cy, cap_cell);
        }
    }
    // The cursor: a yellow frame sweeping the cells.
    const cur: u32 = c.captcha_cursor % 9;
    const ux = grid_x + @as(i32, @intCast(cur % 3)) * (cap_cell + 1);
    const uy = grid_y + @as(i32, @intCast(cur / 3)) * (cap_cell + 1);
    cart.rect(.{ .x = ux - 1, .y = uy - 1, .width = cap_cell + 4, .height = cap_cell + 4, .stroke_color = yellow });
    cart.rect(.{ .x = ux, .y = uy, .width = cap_cell + 2, .height = cap_cell + 2, .stroke_color = yellow });
    // The wait bar under the header: the sim lets go after `captcha_wait`.
    const left: u32 = @min(@as(u32, c.captcha), captcha_wait);
    fill_rect(cap_x + 3, cap_y + 32, left * @as(u32, cap_w - 6) / captcha_wait, 1, cap_blue);
    // The footer: PRESS A (blinking), or TRY AGAIN after a miss.
    const fy = grid_y + 3 * cap_cell + 4 + 3;
    if (fx.captcha_fail > 0) {
        font.draw("TRY AGAIN", 80 - 36, fy, .from_color(red), null);
    } else if ((frame / 10) % 3 != 2) {
        fill_rect(80 - 32, fy - 1, 64, 10, cap_blue);
        font.draw("PRESS A", 80 - 28, fy, .from_color(white), null);
    }
}

/// One "photo" of the grid: sky over a road, and in each cell one of a
/// crossing, a tree or a building; lit cells hold a traffic light.
fn draw_scene(k: u32, lit: bool, x: i32, y: i32, size: i32) void {
    const horizon = y + @divTrunc(size * 7, 16);
    fill_rect(x, y, size, horizon - y, sky);
    fill_rect(x, horizon, size, y + size - horizon, road);
    switch ((k * 5 + 1) % 3) {
        0 => {
            // A zebra crossing.
            var sx: i32 = x + 1;
            while (sx < x + size - 1) : (sx += 3) fill_rect(sx, y + size - 4, 2, 3, road_line);
        },
        1 => {
            // A tree.
            fill_rect(x + size - 5, horizon - 2, 1, 4, brick);
            fill_rect(x + size - 7, horizon - 7, 5, 5, leaf);
        },
        else => {
            // A building with lit windows.
            fill_rect(x + 1, y + 2, 6, horizon - y - 2, brick);
            fill_rect(x + 2, y + 4, 1, 1, window_px);
            fill_rect(x + 5, y + 4, 1, 1, window_px);
            fill_rect(x + 2, y + 6, 1, 1, window_px);
        },
    }
    if (!lit or size < 12) {
        if (lit) {
            fill_rect(x + size - 6, y + 2, 3, 7, lamp_dark);
            fill_rect(x + size - 5, y + 3, 1, 1, lamp_red);
        }
        return;
    }
    // The traffic light: a pole and a housing with red, amber and green.
    const lx = x + @divTrunc(size, 2) - 2;
    fill_rect(lx + 2, y + 12, 1, size - 12, lamp_dark);
    fill_rect(lx, y + 1, 5, 11, lamp_dark);
    fill_rect(lx + 1, y + 2, 3, 3, lamp_red);
    fill_rect(lx + 1, y + 5, 3, 3, lamp_amber);
    fill_rect(lx + 1, y + 8, 3, 3, lamp_green);
}

// The KERNEL PANIC blue screen.
const bsod_blue = cart.DisplayColor.rgb(0x0A64C8);
/// The blue screen is the first 30 of the 90 frozen ticks (`frozen > 60`).
const panic_blue_from: u8 = 60;

/// The followed car's CAPTCHA card is up (a human plays it).
pub fn captcha_up(c: *const world.Car) bool {
    return c.captcha > 0 and c.human != world.no_human and c.wreck == .none;
}

/// The followed car is showing the KERNEL PANIC blue screen.
pub fn bluescreen_on(c: *const world.Car) bool {
    return c.frozen > panic_blue_from and c.frozen_by == .panic and c.wreck == .none;
}

/// SPEC 6.3: the screen goes blue, `:(` and `YOUR RIG RAN INTO A
/// PROBLEM`, a percentage counting up, the QR code and the stop code
/// naming who sent it. Full screen, instead of the race view.
pub fn draw_bluescreen(w: *const world.World, follow: u8) void {
    const c = &w.cars[follow % world.car_count];
    fill_rect(0, 0, 160, 128, bsod_blue);
    glyph_text(":(", 4, 6, 3, false, white);
    const lines = [_][]const u8{ "YOUR RIG RAN INTO", "A PROBLEM AND", "NEEDS TO RESTART." };
    for (lines, 0..) |l, i| font.draw(l, 6, 36 + @as(i32, @intCast(i)) * 9, .from_color(white), null);
    // 0% to 100% over the 30 blue ticks.
    const gone: u32 = 90 - @as(u32, @min(c.frozen, 90));
    var pct_buf: [13]u8 = "  0% COMPLETE".*;
    put_uint(pct_buf[0..3], @min(100, gone * 100 / 30), ' ');
    const digits: usize = if (gone * 100 / 30 >= 100) 0 else if (gone * 100 / 30 >= 10) 1 else 2;
    font.draw(pct_buf[digits..], 6, 68, .from_color(white), null);
    draw_qr(6, 84);
    font.draw("STOP CODE:", 36, 86, .from_color(white), null);
    font.draw("KERNEL_PANIC", 36, 96, .from_color(white), null);
    // Who sent it, as a driver file.
    const src = fx.panic_source;
    if (src < world.car_count) {
        const name = name_of(w.cars[src].racer);
        var buf: [12]u8 = undefined;
        @memcpy(buf[0..name.len], name);
        @memcpy(buf[name.len..][0..4], ".SYS");
        font.draw(buf[0 .. name.len + 4], 36, 106, .from_color(white), null);
    }
}

/// A 21x21 fake QR code (three finder squares and hashed modules) in a
/// white quiet zone, at (x, y).
fn draw_qr(x: i32, y: i32) void {
    fill_rect(x, y, 25, 25, white);
    const dark: cart.Pixel = .from_color(bsod_blue);
    var r: u32 = 0;
    while (r < 21) : (r += 1) {
        var q: u32 = 0;
        while (q < 21) : (q += 1) {
            const on = qr_module(q, r);
            if (on) cart.framebuffer[@intCast(x + 2 + @as(i32, @intCast(q)))][@intCast(y + 2 + @as(i32, @intCast(r)))] = dark;
        }
    }
}

fn qr_module(q: u32, r: u32) bool {
    // Finder squares at three corners: a 7x7 ring with a 3x3 core.
    const fq: ?u32 = if (q < 7) q else if (q >= 14) q - 14 else null;
    const fr: ?u32 = if (r < 7) r else if (r >= 14) r - 14 else null;
    if (fq != null and fr != null and !(q >= 14 and r >= 14)) {
        const a = fq.?;
        const b = fr.?;
        return a == 0 or a == 6 or b == 0 or b == 6 or (a >= 2 and a <= 4 and b >= 2 and b <= 4);
    }
    if ((q < 8 and r < 8) or (q >= 13 and r < 8) or (q < 8 and r >= 13)) return false;
    const h = (q *% 0x9E37 +% r *% 0x7F4A +% q *% r *% 0x3B) >> 3;
    return h % 7 < 3;
}

// --- After the HUD: the ZERO-DAY flash and the RACE CONDITION glitch -------------

const glitch_bands = 4;

pub fn draw_after(frame: u32) void {
    if (fx.zero_flash > 0) {
        if (fx.zero_flash > fx.zero_flash_ticks - 2) {
            fill_rect(0, 0, 160, 128, white);
        } else {
            // A red frame round the screen while the flash fades.
            fill_rect(0, 0, 160, 3, red);
            fill_rect(0, 125, 160, 3, red);
            fill_rect(0, 0, 3, 128, red);
            fill_rect(157, 0, 3, 128, red);
        }
    }
    if (fx.glitch > 0) {
        // Row bands torn sideways, a different set every frame.
        var row: [160]cart.Pixel = undefined;
        var k: u32 = 0;
        while (k < glitch_bands) : (k += 1) {
            const y0: u32 = (frame *% 37 +% k * 53) % 118;
            const h: u32 = 3 + (frame +% k) % 6;
            const shift: u32 = 6 + ((frame *% 13 +% k * 29) % 40);
            var y = y0;
            while (y < y0 + h and y < 128) : (y += 1) {
                for (0..160) |x| row[x] = cart.framebuffer[x][y];
                for (0..160) |x| cart.framebuffer[x][y] = row[(x + shift) % 160];
            }
        }
    }
}

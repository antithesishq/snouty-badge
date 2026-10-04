//! Forked from snouty-zero/cart/src/hud.zig at f8f6962.
//! HUD (SPEC 10), for the car this badge follows: lap, rank and the
//! pickup box along the top, the kill feed under them, the taunt pop-up
//! top left, the message bar, and bottom left the speed, BURST bolts,
//! front ammo count, rear ammo pips and the armor bar; the minimap bottom
//! right; `ACK` over cars the followed car hits, the SPEAR PHISH reticle
//! on its lock and `BEHIND` while looking back. Draw only: reads the World
//! and fx.zig's notices. Nothing is drawn closer than 4 px to an edge.
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
const popup_y: i32 = 33;
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
    cart.rect(.{ .x = x + 2, .y = y, .width = 1, .height = 4, .fill_color = color });
    cart.rect(.{ .x = x, .y = y + 3, .width = 5, .height = 1, .fill_color = color });
    cart.rect(.{ .x = x + 1, .y = y + 4, .width = 3, .height = 1, .fill_color = color });
    cart.rect(.{ .x = x + 2, .y = y + 5, .width = 1, .height = 1, .fill_color = color });
}

/// Minimap (SPEC 10): the track outline drawn once per race from the
/// centerline into a 32x32 1-bit buffer, cars as 2x2 dots in livery
/// colours, the followed car white on top, bottom-right.
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
    // Cars in livery colours, the followed car last (white, on top); a
    // wrecked car blinks.
    var k: usize = 0;
    while (k <= world.car_count) : (k += 1) {
        const i: usize = if (k == world.car_count) follow else k;
        if (k < world.car_count and k == follow) continue;
        const c = &w.cars[i % world.car_count];
        if (!c.active) continue;
        if (c.wreck != .none and (frame / 8) % 2 == 1) continue;
        const mx = x0 + @divTrunc((c.x >> fixed.Q) * size, 1024);
        const my = y0 + @divTrunc((c.y >> fixed.Q) * size, 1024);
        const color: cart.DisplayColor = if (i == follow) white else livery(c.racer);
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
};

/// The race HUD for car `follow`. Call after the sprites (it reads where
/// they drew the cars).
pub fn draw(w: *const world.World, follow: u8, o: Options) void {
    const c = &w.cars[follow % world.car_count];
    draw_markers(w, c, o.frame);
    // Top row: LAP n/3 left, the rank in the middle, the pickup box right.
    var lap_buf: [7]u8 = "LAP 1/3".*;
    lap_buf[4] = '1' + @as(u8, @min(c.lap, tuning.laps - 1));
    lap_buf[6] = '0' + @as(u8, tuning.laps);
    text(&lap_buf, margin, top_y, white);
    text(rank_text(c.rank), 80 - 12, top_y, if (c.rank == 1) cyan else white);
    cart.rect(.{ .x = box_x, .y = top_y, .width = 18, .height = 18, .stroke_color = grey, .fill_color = anti_black });
    sprites.blit_at(&sprites.pickups, sprites.p_blank, box_x + 1, top_y + 1, .{});
    if (o.look_back) centered("BEHIND", behind_y, coral);
    draw_feed();
    draw_popup();
    draw_bottom_left(c, o.frame);
    draw_minimap(w, follow, o.frame);
    draw_message(w, c);
}

/// `ACK` over cars the followed car hit, and the SPEAR PHISH reticle on its lock.
fn draw_markers(w: *const world.World, c: *const world.Car, frame: u32) void {
    for (&fx.acks) |*a| {
        if (a.ticks == 0) continue;
        const s = sprites.car_screen[a.car % world.car_count];
        if (!s.visible) continue;
        const rise: i32 = @divTrunc(@as(i32, fx.ack_ticks - a.ticks), 3);
        sprites.blit_at(&sprites.icons, sprites.i_ack, s.sx - 6, s.top - 13 - rise, .{});
    }
    if (c.lock < world.car_count and c.wreck == .none) {
        const s = sprites.car_screen[c.lock];
        if (s.visible) {
            const cell: u32 = sprites.i_lock + @as(u32, @intFromBool((frame / 6) % 2 == 1));
            sprites.blit_at(&sprites.icons, cell, s.sx - 6, @divTrunc(s.top + s.sy, 2) - 6, .{});
        }
    }
    _ = w;
}

/// Kill feed (SPEC 5.3): `KILLER > VICTIM` in their livery colours, or
/// the victim and the cause for an uncredited wreck.
fn draw_feed() void {
    const f = &fx.feed;
    if (f.ticks == 0) return;
    const victim = name_of(f.victim);
    var left: []const u8 = "";
    var left_color = white;
    var right: []const u8 = victim;
    var right_color = livery(f.victim);
    var mid: []const u8 = " > ";
    if (f.cause == .zero_day) {
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
    }
    const len: i32 = @intCast(left.len + mid.len + right.len);
    var x: i32 = 80 - len * 4;
    text(left, x, feed_y, left_color);
    x += @as(i32, @intCast(left.len)) * 8;
    text(mid, x, feed_y, white);
    x += @as(i32, @intCast(mid.len)) * 8;
    text(right, x, feed_y, right_color);
}

/// Taunt pop-up (SPEC 5.3, 10): the racer's half-scale portrait in a
/// livery frame, their name and the line wrapped in two.
fn draw_popup() void {
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
fn draw_bottom_left(c: *const world.Car, frame: u32) void {
    var spd_buf: [7]u8 = "  0 MPH".*;
    const mph: u32 = @intCast(@max(0, (sim.speed(c) * 80) >> fixed.Q));
    put_uint(spd_buf[0..3], @min(mph, 999), ' ');
    text(&spd_buf, margin, speed_y, white);
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
    if (fill > 0) cart.rect(.{ .x = margin + 1, .y = armor_y + 1, .width = fill, .height = 4, .fill_color = color });
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

/// The bar: the followed car's wreck note first, then its own message,
/// else the shared one (countdown).
fn draw_message(w: *const world.World, c: *const world.Car) void {
    var buf: [20]u8 = undefined;
    var str: []const u8 = "";
    var color = white;
    const note = &fx.wreck_note;
    if (note.ticks > 0) {
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
    } else {
        const msg = if (c.msg != .none) c.msg else w.msg;
        if (msg == .none) return;
        str = message_text(msg);
        color = if (msg == .fall) coral else if (msg == .go or msg == .finished) cyan else white;
    }
    if (str.len == 0) return;
    cart.rect(.{ .x = 0, .y = bar_y, .width = cart.screen_width, .height = bar_h, .fill_color = anti_black });
    centered(str, bar_y + 4, color);
}

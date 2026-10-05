//! Track B: 2D overlays on top of the pipes (SPEC.md sections 5, 6): the
//! bottom strip (the title "SNOUTY PIPES" over "SELECT: STEER", or B's
//! nametag), each with the Iris mark flipping like a coin now and then,
//! steer mode's HUD, banner, head marker, floor spot and game-over card
//! (M3), and, in `-Ddebug_overlay` builds, a timing readout.
//!
//! The framebuffer is persistent (.copy_forward) and the pipes are drawn
//! once, so an overlay must not leave marks: `draw` saves the pixels under
//! each overlay before drawing it and `restore` puts them back first thing
//! next frame (main.zig: restore -> director commands -> draw). Pipes drawn
//! under an overlay land in the restored picture and are saved again.
//! Overlays may overlap (the marker can pass under the HUD), so `restore`
//! runs in the reverse order of `draw`.
const std = @import("std");
const cart = @import("cart-api");
const iris = @import("iris");
const director = @import("../director.zig");
const zbuf = @import("zbuf.zig");
const math = @import("../math.zig");

/// A screen rectangle with room for the pixels under it.
fn Region(comptime x0: u8, comptime y0: u8, comptime w: u8, comptime h: u8) type {
    std.debug.assert(@as(u32, x0) + w <= cart.screen_width);
    std.debug.assert(@as(u32, y0) + h <= cart.screen_height);
    return struct {
        var saved: [w][h]cart.Pixel = undefined;
        var held: bool = false;

        fn save() void {
            for (0..w) |i| @memcpy(&saved[i], cart.framebuffer[x0 + i][y0..][0..h]);
            held = true;
        }

        fn restore() void {
            if (!held) return;
            for (0..w) |i| @memcpy(cart.framebuffer[x0 + i][y0..][0..h], &saved[i]);
            cart.mark_dirty_rect(x0, y0, w, h);
            held = false;
        }
    };
}

/// A square of side `n` that moves (the head marker), clipped to the screen.
fn Movable(comptime n: u8) type {
    return struct {
        var saved: [n][n]cart.Pixel = undefined;
        var x0: u32 = 0;
        var y0: u32 = 0;
        var w: u32 = 0;
        var h: u32 = 0;

        /// Saves the square with top left (x, y); false if it is off screen.
        fn save(x: i32, y: i32) bool {
            const xa = std.math.clamp(x, 0, cart.screen_width);
            const ya = std.math.clamp(y, 0, cart.screen_height);
            const xb = std.math.clamp(x + n, 0, cart.screen_width);
            const yb = std.math.clamp(y + n, 0, cart.screen_height);
            if (xb <= xa or yb <= ya) return false;
            x0 = @intCast(xa);
            y0 = @intCast(ya);
            w = @intCast(xb - xa);
            h = @intCast(yb - ya);
            for (0..w) |i| @memcpy(saved[i][0..h], cart.framebuffer[x0 + i][y0..][0..h]);
            return true;
        }

        fn restore() void {
            if (w == 0) return;
            for (0..w) |i| @memcpy(cart.framebuffer[x0 + i][y0..][0..h], saved[i][0..h]);
            cart.mark_dirty_rect(@intCast(x0), @intCast(y0), @intCast(w), @intCast(h));
            w = 0;
        }
    };
}

const black: cart.DisplayColor = .rgb(0x000000);
const white: cart.DisplayColor = .rgb(0xffffff);
const yellow: cart.DisplayColor = .rgb(0xffe020);
const red: cart.DisplayColor = .rgb(0xff3020);
const cyan: cart.DisplayColor = .rgb(0x30e0ff);
const grey: cart.DisplayColor = .rgb(0x606870);
const silver: cart.DisplayColor = .rgb(0xc8d0dc);

// The bottom strip, in one style for both kinds (the maze cart's nametag):
// the 24 px Iris mark left of two lines centred in a text block, over a
// 1 px black drop shadow, the group centred at the bottom of the screen.
// The title strip is "SNOUTY PIPES" in white over the steer hint in yellow;
// the nametag (B in the screensaver) two white lines.
pub const StripKind = enum { none, title, nametag };
const title = "SNOUTY PIPES";
const hint = "SELECT: STEER";
const name_line1 = "ADRIAN HATCH";
const name_line2 = "ANTITHESIS";
const icon_gap = 4;
const text_w: u32 = 8 * @as(u32, @max(@max(title.len, hint.len), @max(name_line1.len, name_line2.len)));
const group_w = iris.size + icon_gap + text_w;
const strip_x: u8 = (cart.screen_width - group_w - 1) / 2;
const strip_y: u8 = cart.screen_height - iris.size - 2;
const Strip = Region(strip_x, strip_y, group_w + 1, iris.size + 1);

/// The Iris mark flips like a coin about its vertical axis (as on the maze
/// cart's nametag): `flip_first` ticks after a strip appears, then every
/// `flip_period` ticks while it stays, one full turn in `flip_ticks`. Past
/// 90 degrees it shows the mirrored back face at 70% brightness.
pub const flip_first: u32 = 45;
pub const flip_ticks: u32 = 30;
pub const flip_period: u32 = 300;
/// Ticks the current strip has been on screen (0 on the tick it appears).
var strip_tick: u32 = 0;
var strip_shown: StripKind = .none;
/// Width the mark was last drawn at, `iris.size` at rest (debug_iris_width).
pub var iris_width: u32 = iris.size;
const iris_back: cart.DisplayColor = .rgb(0xb3b3b3);

// Steer HUD, top left: the score, then the rewind token ("<<", cyan while
// the run still has its rewind, grey once spent).
const hud_chars = 10;
const Hud = Region(0, 0, hud_chars * 8 + 2, 10);

// Steer banner (READY / CRASH! / << REWIND), centred near the bottom where
// the play box leaves room.
const banner_chars = 9;
const banner_w = banner_chars * 8 + 2;
const banner_y = cart.screen_height - 11;
const Banner = Region((cart.screen_width - banner_w) / 2, banner_y, banner_w, 9);

// The head marker: four corner brackets around the tip of the player's
// pipe, with a black shadow.
const marker_r = 6;
const Marker = Movable(2 * marker_r + 2);

// The floor spot under the head: a small ellipse on empty pixels only (the
// floor is behind every pipe, so pipes in front of it keep hiding it).
const shadow_w = 7;
const shadow_h = 3;
const Shadow = Movable(shadow_w);
const shadow_color: cart.DisplayColor = .rgb(0x66748c);

// The game-over card.
const card_w = 108;
const card_h = 62;
const card_x = (cart.screen_width - card_w) / 2;
const card_y = (cart.screen_height - card_h) / 2;
const Card = Region(card_x, card_y, card_w, card_h);

// The debug readout: two lines of the 8x8 font on a black box, top left.
const debug_chars = 16;
const debug_w = debug_chars * 8 + 2;
const Debug = Region(0, 0, debug_w, 19);

/// Puts back the pixels under last frame's overlays (marks them dirty), in
/// the reverse order of `draw`.
pub fn restore() void {
    Debug.restore();
    Card.restore();
    Marker.restore();
    Shadow.restore();
    Banner.restore();
    Hud.restore();
    Strip.restore();
}

/// What the debug readout shows.
pub const Stats = struct {
    render_us: u32,
    fps_x10: u32,
    filled: u32,
    alive: u32,
    scene: u32,
    speed: u32,
};

/// Saves what is under each overlay shown this frame, then draws it.
pub fn draw(strip: StripKind, steer: ?director.SteerOverlay, debug: ?Stats) void {
    if (strip != strip_shown) {
        // A new strip (or none): the flip timer restarts.
        strip_tick = 0;
        strip_shown = strip;
        iris_width = iris.size;
    }
    if (strip != .none) {
        Strip.save();
        draw_strip(strip);
        strip_tick +%= 1;
    }
    if (steer) |o| {
        if (!o.card) {
            Hud.save();
            draw_hud(o);
        }
        if (o.banner != .none) {
            Banner.save();
            draw_banner(o.banner);
        }
        if (o.shadow) |sp| {
            if (Shadow.save(sp[0] - shadow_w / 2, sp[1] - shadow_h / 2)) draw_shadow(sp[0] - shadow_w / 2, sp[1] - shadow_h / 2);
        }
        if (o.marker) |m| {
            if (Marker.save(m[0] - marker_r, m[1] - marker_r)) draw_marker(m[0], m[1], if (o.crash) red else yellow);
        }
        if (o.card) {
            Card.save();
            draw_card(o);
        }
    }
    if (debug) |s| {
        Debug.save();
        draw_debug(s);
    }
}

/// Text with a 1 px black drop shadow.
fn shadow_text(str: []const u8, x: i32, y: i32, c: cart.DisplayColor) void {
    cart.text(.{ .str = str, .x = x + 1, .y = y + 1, .text_color = black });
    cart.text(.{ .str = str, .x = x, .y = y, .text_color = c });
}

fn draw_strip(kind: StripKind) void {
    const t = strip_tick;
    var angle: f32 = 0;
    if (t >= flip_first) {
        const since = (t - flip_first) % flip_period;
        if (since < flip_ticks) angle = @as(f32, @floatFromInt(since)) / @as(f32, flip_ticks);
    }
    draw_iris(strip_x, strip_y, angle);
    const tx = strip_x + iris.size + icon_gap;
    switch (kind) {
        .title => {
            shadow_text_centred(title, tx, strip_y + 2, white);
            shadow_text_centred(hint, tx, strip_y + 14, yellow);
        },
        .nametag => {
            shadow_text_centred(name_line1, tx, strip_y + 2, white);
            shadow_text_centred(name_line2, tx, strip_y + 14, white);
        },
        .none => {},
    }
}

fn shadow_text_centred(comptime str: []const u8, x_left: i32, y: i32, c: cart.DisplayColor) void {
    shadow_text(str, x_left + @divTrunc(@as(i32, text_w) - 8 * @as(i32, str.len), 2), y, c);
}

/// The Iris mark at (x0, y0) turned `turns` of a full turn about its
/// vertical axis: columns squeezed to 24 |cos| px about the icon's centre
/// (nearest source column; 1:1 at rest, the same pixels as
/// `iris_mark.draw`), and past a quarter turn the mirrored back face in
/// grey. 1 px black drop shadow; nothing at zero width. Every pixel lies in
/// the strip's saved region, which is restored whole each frame, so the
/// narrow frames leave nothing behind.
fn draw_iris(x0: u32, y0: u32, turns: f32) void {
    const c = math.cos_turns(turns);
    const front = c >= 0;
    const w: u32 = @intFromFloat(@round(@abs(c) * @as(f32, iris.size)));
    iris_width = w;
    if (w == 0) return;
    const x_left = x0 + (iris.size - w) / 2;
    const fg: cart.Pixel = .from_color(if (front) white else iris_back);
    const shadow: cart.Pixel = .from_color(black);
    inline for (.{ 1, 0 }) |off| {
        for (0..w) |i| {
            const x = x_left + i + off;
            const src = ((2 * i + 1) * iris.size) / (2 * w);
            const u = if (front) src else iris.size - 1 - src;
            const col = &cart.framebuffer[x];
            for (0..iris.size) |j| {
                if (!iris.pixel(u, j)) continue;
                col[y0 + j + off] = if (off == 1) shadow else fg;
            }
        }
    }
    cart.mark_dirty_rect(@intCast(x_left), @intCast(y0), @intCast(w + 1), iris.size + 1);
}

var hud_buf: [hud_chars]u8 = undefined;

fn draw_hud(o: director.SteerOverlay) void {
    const s = std.fmt.bufPrint(&hud_buf, "{d}", .{@min(o.score, 99999)}) catch return;
    shadow_text(s, 1, 1, white);
    shadow_text("<<", 1 + @as(i32, @intCast(s.len + 1)) * 8, 1, if (o.rewind_token) cyan else grey);
}

fn draw_banner(b: director.Banner) void {
    const str, const c = switch (b) {
        .ready => .{ "READY", yellow },
        .crash => .{ "CRASH!", red },
        .rewind => .{ "<< REWIND", cyan },
        .none => return,
    };
    const x: i32 = @divTrunc(@as(i32, cart.screen_width) - @as(i32, @intCast(str.len)) * 8, 2);
    shadow_text(str, x, banner_y, c);
}

/// The ellipse with top left (x, y), rows 5, 7, 5 px wide.
fn draw_shadow(x: i32, y: i32) void {
    const px: cart.Pixel = .from_color(shadow_color);
    for (0..shadow_h) |ju| {
        const j: i32 = @intCast(ju);
        const inset: i32 = if (j == 1) 0 else 1;
        var i: i32 = inset;
        while (i < shadow_w - inset) : (i += 1) {
            const sx = x + i;
            const sy = y + j;
            if (sx < Shadow.x0 or sy < Shadow.y0 or sx >= Shadow.x0 + Shadow.w or sy >= Shadow.y0 + Shadow.h) continue;
            const ux: u32 = @intCast(sx);
            const uy: u32 = @intCast(sy);
            if (zbuf.buf[ux][uy] != zbuf.far) continue;
            cart.framebuffer[ux][uy] = px;
        }
    }
    cart.mark_dirty_rect(@intCast(Shadow.x0), @intCast(Shadow.y0), @intCast(Shadow.w), @intCast(Shadow.h));
}

/// Corner brackets of a (2 marker_r + 1) square centred on (cx, cy), arms
/// 3 px, shadow 1 px down-right. Only pixels on screen (the Movable region
/// covers exactly the square plus its shadow).
fn draw_marker(cx: i32, cy: i32, c: cart.DisplayColor) void {
    marker_pass(cx + 1, cy + 1, .from_color(black));
    marker_pass(cx, cy, .from_color(c));
    cart.mark_dirty_rect(@intCast(Marker.x0), @intCast(Marker.y0), @intCast(Marker.w), @intCast(Marker.h));
}

fn marker_pass(cx: i32, cy: i32, px: cart.Pixel) void {
    const r = marker_r;
    const arm = 3;
    for ([2]i32{ -1, 1 }) |sx| {
        for ([2]i32{ -1, 1 }) |sy| {
            const kx = cx + sx * r;
            const ky = cy + sy * r;
            for (0..arm) |iu| {
                const i: i32 = @intCast(iu);
                put_marker(kx - sx * i, ky, px);
                put_marker(kx, ky - sy * i, px);
            }
        }
    }
}

fn put_marker(x: i32, y: i32, px: cart.Pixel) void {
    if (x < Marker.x0 or y < Marker.y0 or x >= Marker.x0 + Marker.w or y >= Marker.y0 + Marker.h) return;
    cart.framebuffer[@intCast(x)][@intCast(y)] = px;
}

var card_buf: [2][16]u8 = undefined;

fn draw_card(o: director.SteerOverlay) void {
    cart.rect(.{ .x = card_x, .y = card_y, .width = card_w, .height = card_h, .stroke_color = silver, .fill_color = black });
    const lx = card_x + 6;
    var y: i32 = card_y + 5;
    cart.text(.{ .str = "GAME OVER", .x = (cart.screen_width - 9 * 8) / 2, .y = y, .text_color = red });
    y += 12;
    const s1 = std.fmt.bufPrint(&card_buf[0], "SCORE {d: >5}", .{@min(o.score, 99999)}) catch return;
    cart.text(.{ .str = s1, .x = lx, .y = y, .text_color = white });
    y += 10;
    const s2 = std.fmt.bufPrint(&card_buf[1], "BEST  {d: >5}", .{@min(o.best, 99999)}) catch return;
    cart.text(.{ .str = s2, .x = lx, .y = y, .text_color = if (o.score >= o.best and o.score > 0) yellow else white });
    y += 13;
    cart.text(.{ .str = "A: AGAIN", .x = lx, .y = y, .text_color = cyan });
    y += 10;
    cart.text(.{ .str = "SELECT: EXIT", .x = lx, .y = y, .text_color = cyan });
}

var buf: [2 * debug_chars]u8 = undefined;

fn draw_debug(s: Stats) void {
    const line1 = std.fmt.bufPrint(buf[0..debug_chars], "{d}us {d}.{d}", .{ @min(s.render_us, 999999), s.fps_x10 / 10, s.fps_x10 % 10 }) catch return;
    const line2 = std.fmt.bufPrint(buf[debug_chars..], "c{d} p{d} s{d} {d}x", .{ s.filled, s.alive, s.scene % 100, s.speed }) catch return;
    cart.rect(.{ .x = 0, .y = 0, .width = debug_w, .height = 19, .fill_color = .rgb(0x000000) });
    cart.text(.{ .str = line1, .x = 1, .y = 1, .text_color = .rgb(0xffffff) });
    cart.text(.{ .str = line2, .x = 1, .y = 10, .text_color = .rgb(0xffffff) });
}

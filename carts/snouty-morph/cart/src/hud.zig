//! On-screen extras (SPEC.md section 3): the active source top-left, the
//! zone map top-right (3x3 or 8 stripes, docs/TOF.md M5: coverage of the
//! hand per zone, dim grey for zones that only see the background), the
//! mesh name, sound and ZONES toasts,
//! and, while no hand is in view, a greetings scroller along the bottom.
const std = @import("std");
const cart = @import("cart-api");
const tof_pose = @import("tof").pose;
const hand = @import("hand.zig");
const math = @import("math.zig");
const text = @import("text.zig");

const toast_frames = 90;
var mesh_toast: u32 = 0;
var mesh_name: []const u8 = "";
var sound_toast: u32 = 0;
var sound_on = false;
var scroll: u32 = 0;

pub fn show_mesh(name: []const u8) void {
    mesh_name = name;
    mesh_toast = toast_frames;
}

pub fn show_sound(on: bool) void {
    sound_on = on;
    sound_toast = toast_frames;
}

var zones_toast: u32 = 0;
var zones_label: []const u8 = "";

/// ZONES changed (hold Select): "ZONES GRID" / "ZONES STRIPES".
pub fn show_zones(l: tof_pose.types.Layout) void {
    zones_label = if (l == .stripes) "ZONES STRIPES" else "ZONES GRID";
    zones_toast = toast_frames;
    // The sound toggle of the press was undone: no SOUND toast.
    sound_toast = 0;
}

const source_name = [_][]const u8{ "NO SENSOR", "STICK", "SENSOR" };
const source_rgb = [_]u32{ 0x9090a8, 0xffd850, 0x60ff90 };

const greetings = "SNOUTY MORPH  *  WAVE A HAND OVER THE SENSOR  *  STICK MOVES IT, B+STICK PUSHES AND TURNS, A PUNCHES  *  START: NEXT MESH  SELECT: SOUND  HOLD SELECT: ZONES  *  A 3X3 TIME-OF-FLIGHT SENSOR IS NINE PIXELS: THE REST IS MATHS  *  GREETINGS TO EVERY SYCL BADGE HACKER  *  ";

pub fn draw(t: u32) void {
    const src = @backingInt(hand.source);
    text.shadowed(source_name[src], 3, 3, .rgb(source_rgb[src]), 1);
    if (hand.source == .sensor) mini_map(hand.pose, &hand.frame, source_rgb[src]);

    if (mesh_toast > 0) {
        mesh_toast -= 1;
        text.shadowed(mesh_name, text.centre_x(mesh_name, 1), 3, .rgb(0xffffff), 1);
    }
    if (sound_toast > 0) {
        sound_toast -= 1;
        const s: []const u8 = if (sound_on) "SOUND ON" else "SOUND OFF";
        text.shadowed(s, text.centre_x(s, 1), 14, .rgb(0xffd850), 1);
    }
    if (zones_toast > 0) {
        zones_toast -= 1;
        text.shadowed(zones_label, text.centre_x(zones_label, 1), 14, .rgb(0x60ff90), 1);
    }
    if (hand.source != .stick and !hand.pose.present) scroller(t) else scroll = 0;
}

/// Size (pixels) of one cell of the zone map along an axis with `n` cells:
/// a 3x3 grid of 5 px cells, 8 stripes of 2 px across and 17 px along.
pub fn map_cell(n: u8, other: u8) i32 {
    if (n > 3) return 2;
    if (n == 1 and other > 3) return 17;
    return 5;
}

/// The zone map: `hand.geom`'s cells (3x3, or 8 stripes) in screen order;
/// a hand cell by its coverage, the others by the background's nearness.
fn mini_map(p: tof_pose.Pose, f: *const tof_pose.types.Frame, rgb: u32) void {
    const g = &hand.geom;
    if (g.n == 0) return;
    const cw = map_cell(g.cols, g.rows);
    const ch = map_cell(g.rows, g.cols);
    const w: i32 = @as(i32, g.cols) * (cw + 1);
    const h: i32 = @as(i32, g.rows) * (ch + 1);
    const x0: i32 = 160 - 3 - w;
    const y0: i32 = 3;
    cart.rect(.{ .x = x0 - 1, .y = y0 - 1, .width = @intCast(w + 1), .height = @intCast(h + 1), .fill_color = .rgb(0x000000) });
    const pose_ok = p.layout == g.layout;
    const frame_ok = f.layout == g.layout;
    for (0..g.n) |ci| {
        const c = if (pose_ok) p.coverage[ci] else 0;
        var colour: u32 = 0x181420;
        if (p.present and c > 0) {
            colour = mix(0x302848, rgb, @intFromFloat(@min(1.0, c) * 256.0));
        } else if (frame_ok) {
            // Background only: brighter when nearer.
            const z = f.zones[g.zones[ci].dev];
            if (z.near.valid()) {
                const near: u32 = @min(255, 255 * 300 / @max(@as(u32, z.near.mm), 300));
                colour = mix(0x181420, 0x5a5468, near);
            }
        }
        cart.rect(.{
            .x = x0 + @as(i32, g.col(ci)) * (cw + 1),
            .y = y0 + @as(i32, g.row(ci)) * (ch + 1),
            .width = @intCast(cw),
            .height = @intCast(ch),
            .fill_color = .rgb(colour),
        });
    }
}

fn mix(a: u32, b: u32, f: u32) u32 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const ca = (a >> shift) & 0xff;
        const cb = (b >> shift) & 0xff;
        out |= ((ca * (256 - f) + cb * f) >> 8) << shift;
    }
    return out;
}

/// The greetings, one pixel per frame, each letter bobbing on a sine.
fn scroller(t: u32) void {
    scroll +%= 1;
    const pitch = 8;
    const total: u32 = greetings.len * pitch;
    const offset = scroll % total;
    const first = offset / pitch;
    const sub: i32 = @intCast(offset % pitch);
    var i: u32 = 0;
    while (i < 22) : (i += 1) {
        const ch = greetings[(first + i) % greetings.len];
        if (ch == ' ') continue;
        const x = @as(i32, @intCast(i * pitch)) - sub;
        const wob = math.sin_turns(@as(f32, @floatFromInt(t)) / 90.0 + @as(f32, @floatFromInt(first + i)) * 0.07);
        const y: i32 = 128 - 13 + @as(i32, @intFromFloat(wob * 2.5));
        cart.text(.{ .str = &.{ch}, .x = x + 1, .y = y + 1, .text_color = .rgb(0x000000) });
        cart.text(.{ .str = &.{ch}, .x = x, .y = y, .text_color = .rgb(0xe8e0ff) });
    }
}

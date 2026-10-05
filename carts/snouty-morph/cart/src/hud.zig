//! On-screen extras (SPEC.md section 3): the active source top-left, the
//! 3x3 zone map top-right (coverage of the hand per zone, dim grey for
//! zones that only see the background), the mesh name and sound toasts,
//! and in GHOST a greetings scroller along the bottom.
const std = @import("std");
const cart = @import("cart-api");
const tof_pose = @import("tof_pose");
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

const source_name = [_][]const u8{ "GHOST", "STICK", "HAND" };
const source_rgb = [_]u32{ 0xa890ff, 0xffd850, 0x60ff90 };

const greetings = "SNOUTY MORPH  *  WAVE A HAND OVER THE SENSOR  *  STICK MOVES IT, B+STICK PUSHES AND TURNS, A PUNCHES  *  START: NEXT MESH  SELECT: SOUND  *  A 3X3 TIME-OF-FLIGHT SENSOR IS NINE PIXELS: THE REST IS MATHS  *  GREETINGS TO EVERY SYCL BADGE HACKER  *  ";

pub fn draw(t: u32) void {
    const src = @backingInt(hand.source);
    text.shadowed(source_name[src], 3, 3, .rgb(source_rgb[src]), 1);
    if (hand.source != .stick) mini_map(hand.pose, &hand.frame, source_rgb[src]);

    if (mesh_toast > 0) {
        mesh_toast -= 1;
        text.shadowed(mesh_name, text.centre_x(mesh_name, 1), 3, .rgb(0xffffff), 1);
    }
    if (sound_toast > 0) {
        sound_toast -= 1;
        const s: []const u8 = if (sound_on) "SOUND ON" else "SOUND OFF";
        text.shadowed(s, text.centre_x(s, 1), 14, .rgb(0xffd850), 1);
    }
    if (hand.source == .ghost) scroller(t) else scroll = 0;
}

fn mini_map(p: tof_pose.Pose, f: *const tof_pose.types.Frame, rgb: u32) void {
    const cell = 5;
    const x0: i32 = 160 - 3 - 3 * (cell + 1);
    const y0: i32 = 3;
    cart.rect(.{ .x = x0 - 1, .y = y0 - 1, .width = 3 * (cell + 1) + 1, .height = 3 * (cell + 1) + 1, .fill_color = .rgb(0x000000) });
    for (0..9) |ci| {
        const c = p.coverage[ci];
        var colour: u32 = 0x181420;
        if (p.present and c > 0) {
            colour = mix(0x302848, rgb, @intFromFloat(@min(1.0, c) * 256.0));
        } else {
            // Background only: brighter when nearer (device order: identity
            // orientation for the ghost; close enough for a glance).
            const z = f.zones[ci];
            if (z.near.valid()) {
                const near: u32 = @min(255, 255 * 300 / @max(@as(u32, z.near.mm), 300));
                colour = mix(0x181420, 0x5a5468, near);
            }
        }
        cart.rect(.{
            .x = x0 + @as(i32, @intCast(ci % 3)) * (cell + 1),
            .y = y0 + @as(i32, @intCast(ci / 3)) * (cell + 1),
            .width = cell,
            .height = cell,
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

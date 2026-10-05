//! What sits on top of the shader (SPEC.md section 3): toasts (program
//! name, palette, parameter, sound) and, while B is held, the inputs panel
//! in the manner of Shadertoy's: program and palette, the source, the 3x3
//! field as a grid (presence as brightness, nearness as warmth) and the
//! pose numbers, over a darkened strip of the image.
const std = @import("std");
const cart = @import("cart-api");
const app = @import("app.zig");
const hand = @import("hand.zig");
const palette = @import("palette.zig");
const programs = @import("programs.zig");
const surface = @import("surface.zig");
const text = @import("text.zig");
const U = @import("uniforms.zig").U;

const source_name = [_][]const u8{ "GHOST", "STICK", "HAND" };
const source_rgb = [_]u32{ 0xa890ff, 0xffd850, 0x60ff90 };

pub fn draw(u: *const U) void {
    if (app.hud) {
        panel(u);
        return;
    }
    if (app.toast == .none) return;
    const pr = &programs.list[app.program];
    var buf: [24]u8 = undefined;
    switch (app.toast) {
        .none => {},
        .program => {
            text.shadowed(pr.name, text.centre_x(pr.name, 2), 50, .rgb(0xffffff), 2);
            const hint = "HOLD B: INPUTS";
            text.shadowed(hint, text.centre_x(hint, 1), 70, .rgb(0xc0c0d0), 1);
        },
        .palette => {
            const name = palette.all[app.palette_index()].name;
            text.shadowed(name, text.centre_x(name, 1), 116, .rgb(0xffffff), 1);
        },
        .param => {
            const s = param_line(&buf, pr.param_name, app.param());
            text.shadowed(s, text.centre_x(s, 1), 116, .rgb(0xffffff), 1);
        },
        .mirror => {
            const s: []const u8 = if (app.mirror) "MIRROR ON" else "MIRROR OFF";
            text.shadowed(s, text.centre_x(s, 1), 116, .rgb(0x60ff90), 1);
        },
        .sound => {
            const s: []const u8 = if (app.sound) "SOUND ON" else "SOUND OFF";
            text.shadowed(s, text.centre_x(s, 1), 116, .rgb(0xffd850), 1);
        },
    }
}

fn param_line(buf: []u8, name: []const u8, v: u8) []const u8 {
    @memcpy(buf[0..name.len], name);
    buf[name.len] = ' ';
    buf[name.len + 1] = '0' + v;
    return buf[0 .. name.len + 2];
}

/// Quarter the brightness of framebuffer rows y0..y1 (a translucent strip).
fn darken(y0: usize, y1: usize) void {
    for (cart.framebuffer) |*col| {
        for (col[y0..y1]) |*px| {
            const c = surface.pixel_bits(px.bits); // swap back on wasm
            const d = surface.unspread((surface.spread(c) >> 2) & surface.mask);
            px.bits = surface.pixel_bits(d);
        }
    }
}

fn panel(u: *const U) void {
    const pr = &programs.list[app.program];
    darken(0, 11);
    darken(84, 128);
    // Top: program, palette, source.
    text.condensed(pr.name, 2, 2, .rgb(0xffffff));
    const pname = palette.all[app.palette_index()].name;
    text.condensed(pname, 2 + @as(i32, @intCast(pr.name.len + 1)) * 7, 2, .rgb(0x9090a8));
    const src = @backingInt(hand.source);
    const sname = source_name[src];
    text.condensed(sname, 160 - 2 - @as(i32, @intCast(sname.len)) * 7, 2, .rgb(source_rgb[src]));

    // The field grid, bottom-left: 3x3 cells of 11 px.
    const cell = 11;
    const gx: i32 = 3;
    const gy: i32 = 88;
    for (0..9) |ci| {
        const pres = u.presence[ci];
        const near = u.near[ci];
        const cold: palette.Rgb = .{ 0.2, 0.4, 1.0 };
        const hot: palette.Rgb = .{ 1.0, 0.45, 0.1 };
        var c: palette.Rgb = undefined;
        for (0..3) |k| c[k] = (cold[k] + (hot[k] - cold[k]) * near) * (0.12 + 0.88 * pres);
        const bits = surface.unspread(palette.pack(c, 1, 0));
        cart.rect(.{
            .x = gx + @as(i32, @intCast(ci % 3)) * (cell + 1),
            .y = gy + @as(i32, @intCast(ci / 3)) * (cell + 1),
            .width = cell,
            .height = cell,
            .fill_color = @bitCast(bits),
        });
    }
    // The hand's spot on the grid.
    const hd = u.hand;
    if (hd.present) {
        const px = gx + @as(i32, @intFromFloat(std.math.clamp((hd.x + 1.5) / 3.0, 0, 1) * (3 * (cell + 1) - 1)));
        const py = gy + @as(i32, @intFromFloat(std.math.clamp((1.5 - hd.y) / 3.0, 0, 1) * (3 * (cell + 1) - 1)));
        cart.rect(.{ .x = px - 1, .y = py - 1, .width = 3, .height = 3, .fill_color = .rgb(0xffffff) });
    }

    // Numbers, right of the grid: 16 condensed characters from x = 42.
    const tx: i32 = 42;
    var line: [16]u8 = undefined;
    fill(&line, "X", hd.x, 2, "Y", hd.y, 2);
    text.condensed(&line, tx, 87, .rgb(0xe0e0f0));
    fill(&line, "Z", hd.z, 2, "E", u.energy, 1);
    text.condensed(&line, tx, 97, .rgb(0xe0e0f0));
    angles(&line, hd.pitch, hd.roll, hd.yaw);
    text.condensed(&line, tx, 107, .rgb(0xb0d0ff));
    var buf: [24]u8 = undefined;
    const pl = param_line(&buf, pr.param_name, app.param());
    text.condensed(pl, tx, 117, .rgb(0xffd850));
    if (u.punch_age < 40) text.condensed("PUNCH", 160 - 2 - 5 * 7, 117, .rgb(0xff6060)) else if (app.mirror) text.condensed("MIRR", 160 - 2 - 4 * 7, 117, .rgb(0x60ff90));
}

/// "Xs0.00 Ys0.00" style: two labelled signed values, space-padded.
fn fill(out: *[16]u8, la: []const u8, a: f32, da: u32, lb: []const u8, b: f32, db: u32) void {
    @memset(out, ' ');
    var i: usize = 0;
    i = put_label(out, i, la);
    i = put_fixed(out, i, a, da);
    i += 1;
    i = put_label(out, i, lb);
    _ = put_fixed(out, i, b, db);
}

/// "P+12 R-05 W+30": pitch, roll, yaw in degrees.
fn angles(out: *[16]u8, pitch: f32, roll: f32, yaw: f32) void {
    @memset(out, ' ');
    const vals = [3]f32{ pitch, roll, yaw };
    const labels = "PRW";
    var i: usize = 0;
    for (vals, 0..) |v, k| {
        out[i] = labels[k];
        i += 1;
        const deg: i32 = @intFromFloat(std.math.clamp(v * (180.0 / std.math.pi), -99, 99));
        out[i] = if (deg < 0) '-' else '+';
        const m: u32 = @abs(deg);
        out[i + 1] = '0' + @as(u8, @intCast(m / 10));
        out[i + 2] = '0' + @as(u8, @intCast(m % 10));
        i += 4;
    }
}

fn put_label(out: []u8, i: usize, l: []const u8) usize {
    @memcpy(out[i .. i + l.len], l);
    return i + l.len;
}

/// Signed fixed-point with `d` decimals (|v| < 10).
fn put_fixed(out: []u8, first: usize, v: f32, d: u32) usize {
    var i = first;
    out[i] = if (v < 0) '-' else '+';
    i += 1;
    const scale: f32 = if (d == 2) 100 else 10;
    const n: u32 = @intFromFloat(@min(@abs(v), 9.99) * scale + 0.5);
    const whole = n / @as(u32, @intFromFloat(scale));
    out[i] = '0' + @as(u8, @intCast(@min(whole, 9)));
    out[i + 1] = '.';
    i += 2;
    if (d == 2) {
        out[i] = '0' + @as(u8, @intCast((n / 10) % 10));
        out[i + 1] = '0' + @as(u8, @intCast(n % 10));
        i += 2;
    } else {
        out[i] = '0' + @as(u8, @intCast(n % 10));
        i += 1;
    }
    return i;
}

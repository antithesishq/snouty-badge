//! Part 9, Fire (4 bars, 8 s): the classic cooling-map fire at half
//! resolution with the Iris mark floating in it.
//!
//! An 80x64 heat buffer (`fx.Indices`, column-major) is the whole state.
//! Each frame the bottom row is re-seeded from a xorshift stream (clumps
//! of 216..255 with random cold gaps; on every beat, 30 frames, it burns
//! at full heat without gaps for 3 frames), then every other row, top
//! down so it only reads last frame's rows below it, becomes the average
//! of the three cells under it and the one two rows under it, minus a
//! cooling value from a smoothed-noise cooling map that scrolls up with
//! the heat (so dark gaps travel with the flames and carve tongues), plus
//! extra cooling near the top so the upper third stays dark. The flames
//! reach about half to two thirds of the way up. A slow sine leans them:
//! per row, with a probability that follows the sine, the three cells
//! read are shifted one column left or right. The mark's 24x24 silhouette
//! (drawn at 2x, so one mark pixel is exactly one heat cell) is written
//! hot into the buffer every frame, so flames pour off its top.
//!
//! The buffer goes through a black / deep red / red / orange / yellow /
//! white palette with `fx.upscale2x` (writes every pixel), then the mark
//! is drawn over it in near-white shaded warm towards the bottom, with a
//! 1 px dark outline so it reads over the white-hot core, bobbing slowly.
//! All integer maths; the only state is the heat buffer and the rng,
//! both reset in enter(), so the fire ignites from black on every entry.
const std = @import("std");
const cart = @import("cart-api");
const math = @import("../math.zig");
const palette = @import("../palette.zig");
const fx = @import("../fx.zig");
const rng = @import("../rng.zig");
const iris = @import("iris_mark");

pub const name: []const u8 = "Fire";

const w = 80;
const h = 64;

var heat: fx.Indices = undefined;
var pal: palette.Palette = undefined;
var gen: rng.Xorshift = .init(1);

/// The mark at 2x plus a 1 px border: `mark_size` columns of row bits
/// (bit r = row r), fill and outline.
const mark_size = iris.size * 2 + 2;
var mark_fill: [mark_size]u64 = undefined;
var mark_line: [mark_size]u64 = undefined;
/// Mark colour per row of the 2x mark (near-white, warmer at the bottom).
var mark_rows: [mark_size]cart.Pixel = undefined;
var mark_outline: cart.Pixel = undefined;

/// Mark's top left in full-res pixels (x even so it sits on heat cells).
const mark_x = 80 - iris.size;
const mark_y_base = 26;
const mark_bob = 5;

/// The cooling map: a 64x64 tile of smoothed noise, 0..`cool_max`,
/// squared so most of it cools gently and a few blobs cool hard. It
/// scrolls up one row per frame, as fast as the heat rises, so a blob of
/// strong cooling travels with the same flame and carves a gap between
/// tongues (the Hugo Elias cooling-map fire).
const cmap_n = 64;
var cmap: [cmap_n][cmap_n]u8 = undefined;
const cool_max = 20;
/// Extra cooling per row near the top (rows above `top_rows` get up to
/// `top_extra` more), so the upper third stays dark.
const top_rows = 36;
const top_extra = 7;

pub fn init() void {
    pal = palette.gradient(&.{
        .{ .pos = 0, .rgb = 0x000000 },
        .{ .pos = 20, .rgb = 0x060000 },
        .{ .pos = 52, .rgb = 0x500404 },
        .{ .pos = 84, .rgb = 0xa81000 },
        .{ .pos = 116, .rgb = 0xf04800 },
        .{ .pos = 150, .rgb = 0xff9a10 },
        .{ .pos = 184, .rgb = 0xffe040 },
        .{ .pos = 212, .rgb = 0xfff8b0 },
        .{ .pos = 230, .rgb = 0xffffff },
        .{ .pos = 255, .rgb = 0xffffff },
    });
    build_cmap(&cmap, 0xf17e);
    build_mark(&mark_fill, &mark_line);
    for (&mark_rows, 0..) |*p, y| {
        const f: u32 = @intCast((y * 256) / (mark_size - 1));
        p.* = palette.pixel(palette.mix_rgb(0xfffcf4, 0xffd8a8, f));
    }
    mark_outline = palette.pixel(0x180400);
}

pub fn enter() void {
    for (&heat) |*col| @memset(col, 0);
    gen = .init(0x5eed_f12e);
}

/// Fills `m` with wrapped, box-blurred noise, stretched to 0..1 and
/// squared, scaled to 0..`cool_max`. Integer maths only.
pub fn build_cmap(m: *[cmap_n][cmap_n]u8, seed: u32) void {
    var r = rng.Xorshift.init(seed);
    for (m) |*col| for (col) |*v| {
        v.* = @truncate(r.next() >> 24);
    };
    // Wrapped 3-tap box blurs, three passes down the columns and two
    // across, so the blobs (and the tongues between them) stand tall.
    var tmp: [cmap_n]u8 = undefined;
    for (0..3) |pass| {
        for (m) |*col| {
            for (&tmp, 0..) |*o, y| {
                const s = @as(u32, col[(y + cmap_n - 1) % cmap_n]) + col[y] + col[(y + 1) % cmap_n];
                o.* = @intCast(s / 3);
            }
            col.* = tmp;
        }
        if (pass == 2) break;
        for (0..cmap_n) |y| {
            for (&tmp, 0..) |*o, x| {
                const s = @as(u32, m[(x + cmap_n - 1) % cmap_n][y]) + m[x][y] + m[(x + 1) % cmap_n][y];
                o.* = @intCast(s / 3);
            }
            for (tmp, 0..) |v, x| m[x][y] = v;
        }
    }
    var lo: u32 = 255;
    var hi: u32 = 0;
    for (m) |col| for (col) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
    };
    const span = @max(hi - lo, 1);
    for (m) |*col| for (col) |*v| {
        const n = ((@as(u32, v.*) - lo) * 256) / span; // 0..256
        v.* = @intCast((n * n * cool_max) >> 16);
    };
}

/// One fire cell from its three neighbours below (b0 b1 b2), the cell two
/// rows below (d) and the cooling value, clamped at 0.
pub inline fn spread(b0: u8, b1: u8, b2: u8, d: u8, cool: u8) u8 {
    const sum: u32 = @as(u32, b0) + b1 + b2 + d;
    const avg = sum >> 2;
    return if (avg > cool) @intCast(avg - cool) else 0;
}

/// The mark at 2x with a 1 px border as column bitmasks: `fill` has the
/// mark's pixels, `line` the 8-neighbour ring just outside them.
pub fn build_mark(fill: *[mark_size]u64, line: *[mark_size]u64) void {
    for (fill, 0..) |*m, c| {
        m.* = 0;
        if (c == 0 or c == mark_size - 1) continue;
        const mx = (c - 1) / 2;
        for (1..mark_size - 1) |r| {
            if (iris.pixel(mx, (r - 1) / 2)) m.* |= @as(u64, 1) << @intCast(r);
        }
    }
    for (line, 0..) |*l, c| {
        var d: u64 = 0;
        const lo = if (c == 0) 0 else c - 1;
        const hi = @min(c + 1, mark_size - 1);
        for (lo..hi + 1) |k| d |= fill[k] | (fill[k] << 1) | (fill[k] >> 1);
        l.* = d & ~fill[c];
    }
}

inline fn clampx(x: i32) usize {
    return @intCast(std.math.clamp(x, 0, w - 1));
}

pub fn render(t: u32, fb: cart.FramebufferPtr) void {
    // Seed the bottom row: clumps of 1..4 cells, hot or (1 in 8) cold.
    const beat = t % 30 < 3;
    var x: usize = 0;
    while (x < w) {
        const r = gen.next();
        const run: usize = 1 + (r & 3);
        const v: u8 = if (beat) 255 else if ((r >> 2) & 7 == 0) 0 else @intCast(216 + ((r >> 8) % 40));
        var k: usize = 0;
        while (k < run and x < w) : (k += 1) {
            heat[x][h - 1] = v;
            x += 1;
        }
    }

    // Wind: a slow sine; per row, shift the read columns by its sign with
    // a probability of half its magnitude.
    const lean = math.isin(t *% 3 +% 200);
    const mag: u32 = @intCast(@abs(lean) >> 1);
    const dir: i32 = if (lean < 0) -1 else 1;

    for (0..h - 1) |y| {
        const y1 = y + 1;
        const y2 = @min(y + 2, h - 1);
        const r = gen.next();
        const sh: i32 = if ((r & 0x7fff) < mag) dir else 0;
        const crow = (y +% t) & (cmap_n - 1);
        const extra: u8 = if (y < top_rows) @intCast(((top_rows - y) * top_extra) / top_rows) else 0;
        const cx0: usize = (r >> 16) & 1;
        for (0..w) |cx| {
            const xi: i32 = @as(i32, @intCast(cx)) + sh;
            const xc = clampx(xi);
            const cool = cmap[(cx + cx0) & (cmap_n - 1)][crow] + extra;
            heat[cx][y] = spread(heat[clampx(xi - 1)][y1], heat[xc][y1], heat[clampx(xi + 1)][y1], heat[xc][y2], cool);
        }
    }

    // The mark, bobbing: inject its silhouette hot into the heat buffer.
    const my: i32 = mark_y_base + ((math.isin(t *% 4) * mark_bob) >> 15);
    const hy0: usize = @intCast(@divFloor(my, 2));
    const hx0: usize = mark_x / 2;
    for (0..iris.size) |mx| {
        const col = &heat[hx0 + mx];
        for (0..iris.size) |mr| {
            if (iris.pixel(mx, mr)) col[hy0 + mr] = @intCast(160 + (gen.next() >> 26));
        }
    }

    fx.upscale2x(&heat, &pal, fb);

    // Draw the mark over the fire (border included: top left one px up-left).
    const ox: usize = mark_x - 1;
    const oy: usize = @intCast(my - 1);
    for (0..mark_size) |c| {
        const f = mark_fill[c];
        const l = mark_line[c];
        if (f | l == 0) continue;
        const col = &fb[ox + c];
        for (0..mark_size) |r| {
            const bit = @as(u64, 1) << @intCast(r);
            if (f & bit != 0) {
                col[oy + r] = mark_rows[r];
            } else if (l & bit != 0) {
                col[oy + r] = mark_outline;
            }
        }
    }
}

test "fire: spread averages and cools, clamped at zero" {
    try std.testing.expectEqual(@as(u8, 100), spread(100, 100, 100, 100, 0));
    try std.testing.expectEqual(@as(u8, 253), spread(255, 255, 255, 255, 2));
    try std.testing.expectEqual(@as(u8, 0), spread(1, 2, 0, 0, 3));
    try std.testing.expectEqual(@as(u8, 60), spread(0, 120, 120, 3, 0));
}

test "fire: cooling map spans 0..cool_max and is mostly gentle" {
    var m: [cmap_n][cmap_n]u8 = undefined;
    build_cmap(&m, 0xf17e);
    var lo: u8 = 255;
    var hi: u8 = 0;
    var sum: u32 = 0;
    for (m) |col| for (col) |v| {
        lo = @min(lo, v);
        hi = @max(hi, v);
        sum += v;
    };
    try std.testing.expectEqual(@as(u8, 0), lo);
    try std.testing.expectEqual(@as(u8, cool_max), hi);
    try std.testing.expect(sum / (cmap_n * cmap_n) < cool_max / 2);
}

test "fire: mark masks are the 2x mark with a disjoint ring" {
    var fill: [mark_size]u64 = undefined;
    var line: [mark_size]u64 = undefined;
    build_mark(&fill, &line);
    var n: u32 = 0;
    for (fill, line) |f, l| {
        try std.testing.expectEqual(@as(u64, 0), f & l);
        n += @popCount(f);
    }
    var set: u32 = 0;
    for (iris.rows) |row| set += @popCount(row);
    try std.testing.expectEqual(set * 4, n);
    // Nothing on the border columns except the ring.
    try std.testing.expectEqual(@as(u64, 0), fill[0] | fill[mark_size - 1]);
    try std.testing.expect(line[0] != 0 or line[1] != 0);
}

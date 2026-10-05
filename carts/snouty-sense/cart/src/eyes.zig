//! EYES (SPEC section 2): all nine zone histograms as a waterfall. Each
//! zone is a tile laid out like LIVE's grid (same orientation); in a tile
//! distance runs left to right (a bin a column, bins 9..59: about -0.35 m
//! to 2.5 m, the reach of a hand and a room's near walls; HIST shows all
//! 128) and time runs down (the newest histogram set on top, one row
//! per set). Intensity is false colour on a log scale, normalised per set
//! across the zones; the crosstalk bins (around bin 15) are drawn in grey,
//! and the reference channel is a grey strip under the tiles. The frame's
//! first (white) and second (yellow) objects are traced over the rows.
const std = @import("std");
const cart = @import("cart-api");
const tof = @import("tof");
const ui = @import("ui.zig");

const types = tof.types;

pub const cols = 51;
pub const rows = 32;
pub const first_bin = 9;
/// Columns up to here are crosstalk (bins 9..19).
pub const xt_cols = 11;
pub const tile_x0 = 2;
pub const tile_y0 = 9;
pub const tile_dx = 53;
pub const tile_dy = 33;
pub const ref_y = 109;
pub const none: u8 = 0xFF;

pub const Eyes = struct {
    hist: [types.zones][rows][cols]u8 = @splat(@splat(@splat(0))),
    near: [types.zones][rows]u8 = @splat(@splat(none)),
    far: [types.zones][rows]u8 = @splat(@splat(none)),
    ref: [types.hist_bins]u8 = @splat(0),
    /// Row of the newest set.
    head: u8 = 0,
    sets: u32 = 0,
    last_seq: ?u32 = null,
    hold: bool = false,

    pub fn reset(e: *Eyes) void {
        e.* = .{ .hold = e.hold };
    }

    /// A histogram set (with its frame, if the driver has one): a new row
    /// unless it was seen already or the waterfall is held. True if new.
    pub fn take(e: *Eyes, h: *const types.Histograms, f: ?*const types.Frame) bool {
        if (e.last_seq) |s| if (s == h.seq) return false;
        e.last_seq = h.seq;
        if (e.hold) return true;
        e.sets += 1;
        e.head = (e.head + rows - 1) % rows;
        var floor: [types.zones]u32 = undefined;
        var lmax: u32 = 1;
        var floor_min: u32 = std.math.maxInt(u32);
        for (0..types.zones) |z| {
            const bins = &h.bins[z + 1];
            var lo: u32 = std.math.maxInt(u32);
            for (bins[40..]) |v| lo = @min(lo, ui.log2_fix(v));
            // An octave under the quietest bin: the noise floor shows dimly.
            floor[z] = lo -| 16;
            floor_min = @min(floor_min, lo);
            for (bins[first_bin + xt_cols ..]) |v| lmax = @max(lmax, ui.log2_fix(v));
        }
        const range: u32 = @max(16, lmax -| floor_min);
        for (0..types.zones) |z| {
            const bins = &h.bins[z + 1];
            const row = &e.hist[z][e.head];
            for (row, 0..) |*px, c| {
                const v = bins[first_bin + c];
                px.* = @intCast(@min(255, (ui.log2_fix(v) -| floor[z]) * 255 / range));
            }
            e.near[z][e.head] = none;
            e.far[z][e.head] = none;
            if (f) |fr| {
                e.near[z][e.head] = col_of(fr.zones[z].near);
                e.far[z][e.head] = col_of(fr.zones[z].far);
            }
        }
        var rmax: u32 = 1;
        for (h.bins[0]) |v| rmax = @max(rmax, ui.log2_fix(v));
        for (&e.ref, h.bins[0]) |*o, v| o.* = @intCast(ui.log2_fix(v) * 255 / rmax);
        return true;
    }

    pub fn draw(e: *const Eyes, orient: types.Orientation, pal: *const Palettes, sound_zone: ?u4) void {
        for (0..3) |r| for (0..3) |c| {
            const z = orient.index(@intCast(c), @intCast(r));
            const x0: usize = tile_x0 + c * tile_dx;
            const y0: usize = tile_y0 + r * tile_dy;
            e.draw_tile(z, x0, y0, pal);
            if (sound_zone) |sz| if (sz == z) {
                cart.rect(.{ .x = @intCast(x0 - 1), .y = @intCast(y0 - 1), .width = cols + 2, .height = rows + 2, .stroke_color = ui.accent });
            };
        };
        // The reference channel: a grey strip, one pixel per bin.
        for (e.ref, 0..) |v, b| {
            const col = &cart.framebuffer[16 + b];
            for (0..5) |y| col[ref_y + y] = pal.dim[v];
        }
    }

    fn draw_tile(e: *const Eyes, z: usize, x0: usize, y0: usize, pal: *const Palettes) void {
        const tile = &e.hist[z];
        for (0..cols) |c| {
            const p = if (c < xt_cols) &pal.dim else &pal.hot;
            const col = &cart.framebuffer[x0 + c];
            var hr: usize = e.head;
            for (0..rows) |y| {
                col[y0 + y] = p[tile[hr][c]];
                hr = if (hr + 1 == rows) 0 else hr + 1;
            }
        }
        // Metre ticks above the tile.
        var m: u32 = 1;
        while (m <= 5) : (m += 1) {
            const b = tof.bin_of_mm(m * 1000);
            const c = b - first_bin;
            if (c < cols) cart.framebuffer[x0 + c][y0 - 1] = pal.tick;
        }
        // Object traces.
        var hr: usize = e.head;
        for (0..rows) |y| {
            const f = e.far[z][hr];
            if (f != none) cart.framebuffer[x0 + f][y0 + y] = pal.far;
            const n = e.near[z][hr];
            if (n != none) cart.framebuffer[x0 + n][y0 + y] = pal.near;
            hr = if (hr + 1 == rows) 0 else hr + 1;
        }
    }
};

fn col_of(t: types.Target) u8 {
    if (!t.valid()) return none;
    const b = tof.bin_of_mm(t.mm);
    if (b < first_bin) return none;
    const c = b - first_bin;
    return if (c < cols) @intCast(c) else none;
}

/// Precomputed pixels (start()): the false-colour ramp, the grey ramp for
/// crosstalk and the reference, and the trace colours.
pub const Palettes = struct {
    hot: [256]cart.Pixel = undefined,
    dim: [256]cart.Pixel = undefined,
    near: cart.Pixel = undefined,
    far: cart.Pixel = undefined,
    tick: cart.Pixel = undefined,

    pub fn init(p: *Palettes) void {
        const stops = [_]u24{ 0x000000, 0x10104A, 0x5A1A8C, 0xC8285A, 0xFF8C1E, 0xFFE650, 0xFFFFFF };
        for (0..256) |i| {
            const pos: u32 = @as(u32, @intCast(i)) * (stops.len - 1);
            const k = pos / 255;
            const t = (pos % 255) * 256 / 255;
            const rgb = if (k + 1 < stops.len) ui.lerp_rgb(stops[k], stops[k + 1], t) else stops[stops.len - 1];
            p.hot[i] = cart.Pixel.from_color(cart.DisplayColor.rgb(rgb));
            const g: u24 = @intCast(i * 110 / 255 + 12);
            p.dim[i] = cart.Pixel.from_color(cart.DisplayColor.rgb(g << 16 | g << 8 | g));
        }
        p.near = cart.Pixel.from_color(ui.white);
        p.far = cart.Pixel.from_color(ui.warn);
        p.tick = cart.Pixel.from_color(ui.dim);
    }
};

//! Drawing (SPEC.md sections 3 and 8). The picture is a function of the
//! grid: `paint_cell` draws one 2x2 cell from its value, its neighbours
//! (the floor glows next to a wall) and the trail age, over the floor's
//! grid lines. Transient things (cycle heads, banners) are erased by
//! repainting the cells they covered; nothing saves pixels.
//!
//! The cart runs `.copy_forward`: the OS keeps the last frame and sends
//! only the marked dirty rect to the LCD, so every put is covered by a
//! `S.mark_dirty` (host tests check it pixel by pixel; `tools/check.sh
//! lcd` checks the badge-bench LCD model).
//!
//! Generic over a sink `S`:
//!   pub fn put(x: u32, y: u32, c: u16) void   // c = DisplayColor bits
//!   pub fn mark_dirty(r: Rect) void
//! main.zig's `Screen` writes the framebuffer; the tests use arrays.
const std = @import("std");
const sim = @import("sim.zig");
const rng = @import("rng.zig");
const font = @import("font8.zig");
const iris = @import("iris");

pub const screen_w = 160;
pub const screen_h = 128;
/// The arena's top pixel row; above it is the HUD strip.
pub const arena_y = 8;
pub const hud_h = arena_y;
/// Every text and HUD element keeps this far from the screen edges
/// (Adrian rejected edge-touching UI on another cart).
pub const margin = 2;

/// Pixel rectangle, x0/y0 inclusive, x1/y1 exclusive, inside the screen.
pub const Rect = struct {
    x0: u8 = 0,
    y0: u8 = 0,
    x1: u8 = 0,
    y1: u8 = 0,

    pub const empty: Rect = .{};
    pub const full: Rect = .{ .x1 = screen_w, .y1 = screen_h };

    pub fn is_empty(r: Rect) bool {
        return r.x1 <= r.x0 or r.y1 <= r.y0;
    }
    pub fn intersects(a: Rect, b: Rect) bool {
        return !a.is_empty() and !b.is_empty() and a.x0 < b.x1 and b.x0 < a.x1 and a.y0 < b.y1 and b.y0 < a.y1;
    }
    /// The rect (x, y, w, h) clipped to the screen (and to y >= y_min).
    pub fn clip(x: i32, y: i32, w: i32, h: i32, y_min: i32) Rect {
        const xa = std.math.clamp(x, 0, screen_w);
        const ya = std.math.clamp(y, y_min, screen_h);
        const xb = std.math.clamp(x + w, 0, screen_w);
        const yb = std.math.clamp(y + h, y_min, screen_h);
        if (xb <= xa or yb <= ya) return .empty;
        return .{ .x0 = @intCast(xa), .y0 = @intCast(ya), .x1 = @intCast(xb), .y1 = @intCast(yb) };
    }
};

// ---------------------------------------------------------------- colour

/// 0xRRGGBB to DisplayColor bits (packed r:u5 g:u6 b:u5, r in the low bits).
pub fn rgb(c: u24) u16 {
    const r: u16 = @intCast((c >> 19) & 31);
    const g: u16 = @intCast((c >> 10) & 63);
    const b: u16 = @intCast((c >> 3) & 31);
    return r | (g << 5) | (b << 11);
}

/// Each channel of 0xRRGGBB times num/256.
fn scale24(c: u24, num: u32) u24 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const ch = ((@as(u32, c) >> sh) & 0xFF) * num / 256;
        out |= @as(u32, @min(ch, 255)) << sh;
    }
    return @intCast(out);
}

/// a + (b - a) * t/256, per channel.
fn mix24(a: u24, b: u24, t: u32) u24 {
    var out: u32 = 0;
    inline for (.{ 16, 8, 0 }) |sh| {
        const ca: u32 = (@as(u32, a) >> sh) & 0xFF;
        const cb: u32 = (@as(u32, b) >> sh) & 0xFF;
        const ch = (ca * (256 - t) + cb * t) / 256;
        out |= ch << sh;
    }
    return @intCast(out);
}

/// A 565 colour at about 30%: the banner's dimmed arena.
pub fn dim565(c: u16) u16 {
    const r = (c & 31) * 5 / 16;
    const g = ((c >> 5) & 63) * 5 / 16;
    const b = (c >> 11) * 5 / 16;
    return r | (g << 5) | (b << 11);
}

/// Tron Legacy-ish (SPEC 8): player cyan; programs orange, magenta,
/// yellow-green; a bright blue rim; dim blue blocks; a near-black floor
/// with dark blue lines every 8 px.
pub const colors = struct {
    pub const trail_rgb = [sim.max_cycles]u24{ 0x18E0FF, 0xFF7A10, 0xFF2AC8, 0xA8FF20 };
    pub const floor_rgb: u24 = 0x03050A;
    pub const line_rgb: u24 = 0x0A1A38;
    pub const cross_rgb: u24 = 0x143066;
    pub const rim_rgb: u24 = 0x3070FF;
    pub const block_rgb: u24 = 0x1A2E78;

    pub const floor = rgb(floor_rgb);
    pub const line = rgb(line_rgb);
    pub const cross = rgb(cross_rgb);
    pub const rim = rgb(rim_rgb);
    pub const rim_inner = rgb(0x1840B0);
    pub const block = rgb(block_rgb);
    pub const block_hi = rgb(0x2C48A8);
    pub const white = rgb(0xFFFFFF);
    pub const black = rgb(0x000000);
    pub const hud_bg = rgb(0x000000);
    pub const hud_text = rgb(0xC8D8F0);
    pub const hud_dim = rgb(0x5A6E90);

    /// Per cycle: the trail, the three newest cells (hottest first), the
    /// dead trail (a derezzed wall, before it fades), the floor glow.
    pub const trail = blk: {
        var t: [sim.max_cycles]u16 = undefined;
        for (&t, trail_rgb) |*d, c| d.* = rgb(c);
        break :blk t;
    };
    pub const hot = blk: {
        var t: [sim.max_cycles][3]u16 = undefined;
        for (&t, trail_rgb) |*d, c| d.* = .{ rgb(mix24(c, 0xFFFFFF, 200)), rgb(mix24(c, 0xFFFFFF, 130)), rgb(mix24(c, 0xFFFFFF, 64)) };
        break :blk t;
    };
    pub const dead = blk: {
        var t: [sim.max_cycles]u16 = undefined;
        for (&t, trail_rgb) |*d, c| d.* = rgb(scale24(c, 100));
        break :blk t;
    };
    pub const glow = blk: {
        var t: [sim.max_cycles]u16 = undefined;
        for (&t, trail_rgb) |*d, c| d.* = rgb(mix24(floor_rgb, c, 88));
        break :blk t;
    };
    pub const rim_glow = rgb(mix24(floor_rgb, rim_rgb, 48));
    pub const block_glow = rgb(mix24(floor_rgb, block_rgb, 64));

    /// Sudden death's closing ring (SPEC 8: red).
    pub const death_rgb: u24 = 0xC81820;
    pub const death = rgb(death_rgb);
    pub const death_dark = rgb(0x8C1018);
    pub const death_glow = rgb(mix24(floor_rgb, death_rgb, 72));

    /// Grind and stall sparks, hottest first.
    pub const spark = [3]u16{ rgb(0xFFFFFF), rgb(0xFFE870), rgb(0xFF8A20) };
    /// Derez burst per cycle: white-hot, hot, the trail colour, dim.
    pub const burst = blk: {
        var t: [sim.max_cycles][4]u16 = undefined;
        for (&t, trail_rgb) |*d, c| d.* = .{ rgb(0xFFFFFF), rgb(mix24(c, 0xFFFFFF, 140)), rgb(c), rgb(scale24(c, 110)) };
        break :blk t;
    };
    /// A stalled head flickers to this (rubber).
    pub const stall = rgb(0xFF3030);

    /// The HUD's energy bar: frame, empty, full by mode, low.
    pub const bar_frame = rgb(0x34486C);
    pub const bar_empty = rgb(0x0C1424);
    pub const bar_fill = [3]u16{ rgb(0x18E0FF), rgb(0xD0FFFF), rgb(0xFF9A30) };
    pub const bar_low = rgb(0xFF3838);
    pub const pip_on = rgb(0x18E0FF);
    pub const pip_off = rgb(0x24344C);
};

// ---------------------------------------------------------------- view

/// One banner line: text (up to 20 characters), scale and colour.
pub const Line = struct {
    text: [20]u8 = @splat(' '),
    len: u8 = 0,
    scale: u8 = 1,
    color: u16 = colors.white,

    pub fn of(s: []const u8, scale: u8, color: u16) Line {
        var l: Line = .{ .scale = scale, .color = color };
        const n = @min(s.len, l.text.len);
        @memcpy(l.text[0..n], s[0..n]);
        l.len = @intCast(n);
        return l;
    }
    pub fn str(l: *const Line) []const u8 {
        return l.text[0..l.len];
    }
    fn width(l: Line) u32 {
        return @as(u32, l.len) * 8 * l.scale;
    }
};

/// Text over the arena on a dimmed box: up to 8 lines, optionally under the
/// Iris mark, centred on (80, cy). Erased by repainting the cells. Lines
/// of up to 18 characters at scale 1 (9 at scale 2) fit inside the 2 px
/// screen margin.
pub const Banner = struct {
    lines: [max_lines]Line = @splat(.{}),
    n: u8 = 0,
    iris: bool = false,
    /// Vertical centre in screen pixels.
    cy: u8 = 68,

    pub fn add(b: *Banner, s: []const u8, scale: u8, color: u16) void {
        if (b.n == b.lines.len) return;
        b.lines[b.n] = .of(s, scale, color);
        b.n += 1;
    }

    pub const max_lines = 8;
    const pad = 4;
    const line_gap = 3;
    const iris_gap = 4;
    /// The box's widest and tallest, inside the screen margin.
    const max_w = screen_w - 2 * margin;
    const max_h = screen_h - margin - arena_y;

    /// The box, aligned to whole cells, inside the arena and the margin.
    pub fn rect(b: *const Banner) Rect {
        var w: u32 = if (b.iris) iris.size else 0;
        var h: u32 = if (b.iris) iris.size + iris_gap else 0;
        for (b.lines[0..b.n], 0..) |l, i| {
            w = @max(w, l.width());
            h += 8 * @as(u32, l.scale) + if (i + 1 < b.n) @as(u32, line_gap) else 0;
        }
        w += 2 * pad;
        h += 2 * pad;
        w = (w + 1) & ~@as(u32, 1);
        h = (h + 1) & ~@as(u32, 1);
        w = @min(w, max_w);
        h = @min(h, max_h);
        var x0: i32 = @divTrunc(@as(i32, screen_w) - @as(i32, @intCast(w)), 2) & ~@as(i32, 1);
        var y0: i32 = (@as(i32, b.cy) - @as(i32, @intCast(h / 2))) & ~@as(i32, 1);
        x0 = std.math.clamp(x0, margin, @as(i32, screen_w - margin) - @as(i32, @intCast(w)));
        y0 = std.math.clamp(y0, arena_y, @as(i32, screen_h - margin) - @as(i32, @intCast(h)));
        return Rect.clip(x0, y0, @intCast(w), @intCast(h), arena_y);
    }

    /// True if every line's ink fits inside the box (no clipped text).
    pub fn fits(b: *const Banner) bool {
        for (b.lines[0..b.n]) |l| {
            if (l.width() + 2 * pad > max_w) return false;
        }
        return true;
    }
};

/// The HUD strip (y 0..7) in the 4x5 font, 2 px from the screen edges:
/// text left and right, life pips and the energy bar between them.
pub const Hud = struct {
    left: Line = .{},
    right: Line = .{},
    /// The player's energy, 0..`sim.tuning.energy_max`; null hides the bar.
    energy: ?u16 = null,
    /// 0 riding, 1 boosting (A), 2 braking (B): the bar's colour.
    bar_mode: u8 = 0,
    /// `lives` lit pips of `max_lives`; 0 hides them.
    lives: u8 = 0,
    max_lives: u8 = 0,

    pub const bar_x = 82;
    pub const bar_w = 38;
    pub const pips_x = 58;
    pub const pip_w = 5;
    pub const pip_gap = 2;
};

/// What the game wants on screen this frame, besides the World.
pub const View = struct {
    banner: ?Banner = null,
    hud: Hud = .{},
    /// Draw the cycle heads.
    heads: bool = true,
    /// Bit i: a crash of cycle i gets a small name tag beside it for
    /// `fx.tag_ticks` (the programs; the player's crash is a big banner).
    tags: u8 = 0,
};

/// Effect tuning (SPEC 8, PLAN M1 Track P item 4). Lives are World ticks:
/// effects freeze with the World (pause).
pub const fx = struct {
    pub const max_dots = 96;
    pub const burst_dots = 16;
    pub const burst_life = 40;
    /// Sparks per grind event: 1..3, life 4..8 ticks.
    pub const spark_min = 1;
    pub const spark_max = 3;
    pub const spark_life_min = 4;
    pub const spark_life_max = 8;
    pub const tag_ticks = 30;
};

// ---------------------------------------------------------------- renderer

/// Arena height in pixels (the banner overlay's rows).
const arena_h = screen_h - arena_y;

pub fn Renderer(comptime S: type) type {
    return struct {
        const Self = @This();

        /// Head sprite rects drawn last frame, per cycle.
        heads: [sim.max_cycles]Rect = @splat(.empty),
        /// The banner on screen, if `banner_on`, and its cell-aligned box.
        banner: Banner = .{},
        banner_rect: Rect = .empty,
        banner_on: bool = false,
        /// The banner as an overlay over the arena, valid inside
        /// `banner_rect`: per pixel 0 = the dimmed arena shows through,
        /// else an index into `ov_colors` (shadow, Iris, one per line).
        /// Anything painted inside the box goes through it, so the box
        /// never needs redrawing when trails or heads pass under it.
        ov: [screen_w][arena_h]u8 = undefined,
        ov_colors: [ov_line0 + Banner.max_lines]u16 = @splat(0),
        /// Each banner line's ink box (for a colour-only change).
        line_rects: [Banner.max_lines]Rect = @splat(.empty),
        hud: HudKey = .{},
        /// The World tick whose events were applied.
        last_tick: u32 = 0xFFFF_FFFF,
        need_full: bool = true,
        /// Sudden-death rings drawn red so far.
        sd_drawn: u32 = 0,
        /// Transient effects: sparks and derez particles, crash tags.
        /// Redrawn every frame and erased by repainting their cells.
        dots: [fx.max_dots]Dot = @splat(.{}),
        tags: [sim.max_cycles]Tag = @splat(.{}),

        const ov_shadow = 1;
        const ov_iris = 2;
        const ov_line0 = 3;

        /// A spark or derez particle: position and velocity in 1/16 px.
        pub const Dot = struct {
            x: i16 = 0,
            y: i16 = 0,
            vx: i16 = 0,
            vy: i16 = 0,
            /// Ticks left (0 = free slot) of `max`.
            life: u8 = 0,
            max: u8 = 0,
            /// `spark`, or a derez burst of cycle `kind - 1`.
            kind: u8 = 0,
            /// Where it was drawn last frame (erase), if `drawn`, and its
            /// size (bursts start 2x2).
            drawn: bool = false,
            px: u8 = 0,
            py: u8 = 0,
            size: u8 = 1,

            pub const spark = 0;
        };

        /// A program's crash name, small, beside where it crashed.
        pub const Tag = struct {
            crash: sim.Crash = .none,
            cycle: u8 = 0,
            /// Top-left pixel of the tag box.
            x: u8 = 0,
            y: u8 = 0,
            life: u8 = 0,
            /// Drawn last frame (erase).
            drawn: Rect = .empty,
        };

        /// What the HUD shows, reduced to what changes its pixels.
        const HudKey = struct {
            left: Line = .{},
            right: Line = .{},
            bar: ?u8 = null,
            bar_color: u16 = 0,
            lives: u8 = 0,
            max_lives: u8 = 0,
        };

        /// Sets every field but the overlay to its default, in place: a
        /// `.{}` literal would put the 19 KB overlay in .data (the cart
        /// keeps its renderer `undefined` in .bss and calls this).
        pub fn reset(self: *Self) void {
            self.heads = @splat(.empty);
            self.banner = .{};
            self.banner_rect = .empty;
            self.banner_on = false;
            self.ov_colors = @splat(0);
            self.line_rects = @splat(.empty);
            self.hud = .{};
            self.last_tick = 0xFFFF_FFFF;
            self.need_full = true;
            self.sd_drawn = 0;
            self.clear_fx();
        }

        /// Next frame repaints everything (a new round, a mode change);
        /// the effects of the old scene go.
        pub fn invalidate(self: *Self) void {
            self.need_full = true;
            self.clear_fx();
        }

        fn clear_fx(self: *Self) void {
            self.dots = @splat(.{});
            self.tags = @splat(.{});
        }

        /// Brings the screen up to date with `w` and `view`.
        pub fn frame(self: *Self, w: *const sim.World, view: View) void {
            const new_tick = w.tick != self.last_tick;
            if (self.need_full or (new_tick and w.events_lost)) {
                if (new_tick and !self.need_full) self.fx_tick(w, view);
                self.full_repaint(w, view);
                return;
            }
            // Erase last frame's heads and effects by repainting their cells.
            for (&self.heads) |*r| {
                if (!r.is_empty()) self.repaint_rect(w, r.*);
                r.* = .empty;
            }
            self.erase_fx(w);
            self.set_banner(w, view.banner);
            if (new_tick) {
                self.apply_events(w);
                self.fx_tick(w, view);
            }
            self.last_tick = w.tick;
            self.update_rings(w);
            if (view.heads) self.draw_heads(w);
            self.draw_fx(w);
            self.maybe_draw_hud(w, view.hud);
        }

        /// Floor, every cell, the HUD, heads, effects and banner.
        pub fn full_repaint(self: *Self, w: *const sim.World, view: View) void {
            self.banner_on = false;
            if (view.banner) |b| self.load_banner(b);
            // The bare floor first, a column at a time, then only the cells
            // that differ from it: walls, glowing floor, the banner box.
            for (0..screen_w) |x| {
                const col = if (x & 7 == 0) &floor_line_column else &floor_column;
                for (col, arena_y..) |c, y| S.put(@intCast(x), @intCast(y), c);
            }
            for (0..sim.grid_w) |xi| {
                const x: u8 = @intCast(xi);
                for (0..sim.grid_h) |yi| {
                    const y: u8 = @intCast(yi);
                    if (bare_floor(w, x, y) and !self.in_banner(2 * @as(u32, x), arena_y + 2 * @as(u32, y))) continue;
                    self.put_cell(w, x, y);
                }
            }
            S.mark_dirty(.{ .x0 = 0, .y0 = arena_y, .x1 = screen_w, .y1 = screen_h });
            self.need_full = false;
            self.last_tick = w.tick;
            self.sd_drawn = @as(u32, w.sudden_death_ring);
            self.heads = @splat(.empty);
            self.draw_hud(w, view.hud);
            if (view.heads) self.draw_heads(w);
            for (&self.dots) |*d| d.drawn = false;
            for (&self.tags) |*t| t.drawn = .empty;
            self.draw_fx(w);
        }

        /// Repaints one cell from the grid and marks it.
        pub fn paint_cell(self: *Self, w: *const sim.World, x: u8, y: u8) void {
            self.put_cell(w, x, y);
            S.mark_dirty(.{ .x0 = 2 * x, .y0 = arena_y + 2 * y, .x1 = 2 * x + 2, .y1 = arena_y + 2 * y + 2 });
        }

        /// Repaints the empty neighbours of (x, y) (their glow follows it).
        fn paint_glow(self: *Self, w: *const sim.World, x: u8, y: u8) void {
            if (y > 0 and !sim.is_wall(w.at(x, y - 1))) self.paint_cell(w, x, y - 1);
            if (y + 1 < sim.grid_h and !sim.is_wall(w.at(x, y + 1))) self.paint_cell(w, x, y + 1);
            if (x > 0 and !sim.is_wall(w.at(x - 1, y))) self.paint_cell(w, x - 1, y);
            if (x + 1 < sim.grid_w and !sim.is_wall(w.at(x + 1, y))) self.paint_cell(w, x + 1, y);
        }

        /// Repaints every cell under pixel rect r (arena part only), one mark.
        fn repaint_rect(self: *Self, w: *const sim.World, r: Rect) void {
            if (r.y1 <= arena_y or r.is_empty()) return;
            const y0 = @max(r.y0, arena_y);
            self.repaint_cells(w, r.x0 / 2, (y0 - arena_y) / 2, (r.x1 + 1) / 2, (r.y1 - arena_y + 1) / 2);
        }

        /// Repaints cells [cx0, cx1) x [cy0, cy1) (clipped to the grid), one mark.
        fn repaint_cells(self: *Self, w: *const sim.World, cx0: u8, cy0: u8, cx1_in: u8, cy1_in: u8) void {
            const cx1: u8 = @min(cx1_in, sim.grid_w);
            const cy1: u8 = @min(cy1_in, sim.grid_h);
            if (cx1 <= cx0 or cy1 <= cy0) return;
            var cx = cx0;
            while (cx < cx1) : (cx += 1) {
                var cy = cy0;
                while (cy < cy1) : (cy += 1) self.put_cell(w, cx, cy);
            }
            S.mark_dirty(.{ .x0 = 2 * cx0, .y0 = arena_y + 2 * cy0, .x1 = 2 * cx1, .y1 = arena_y + 2 * cy1 });
        }

        fn apply_events(self: *Self, w: *const sim.World) void {
            for (w.events[0..w.n_events]) |e| switch (e.kind) {
                .painted => {
                    self.paint_cell(w, e.x, e.y);
                    self.paint_glow(w, e.x, e.y);
                    // The newest cells cool down a step.
                    var k: u32 = 1;
                    while (k <= 3) : (k += 1) {
                        const idx = w.log_at(e.cycle, k) orelse break;
                        self.paint_cell(w, @intCast(idx % sim.grid_w), @intCast(idx / sim.grid_w));
                    }
                },
                // A faded cell; a cell became a block (sudden death: a = its
                // ring, red by `in_death_ring`; update_rings recolours the
                // layout blocks already on a ring as it starts).
                .cleared, .block => {
                    self.paint_cell(w, e.x, e.y);
                    self.paint_glow(w, e.x, e.y);
                },
                .crash => self.repaint_trail(w, e.cycle),
                // Effects only (fx_tick).
                .turn, .grind, .stall => {},
            };
        }

        /// The whole live trail of cycle i (it changed colour: derezzed).
        fn repaint_trail(self: *Self, w: *const sim.World, i: u8) void {
            const c = &w.cycles[i];
            const n = c.trail_len();
            if (n == 0) return;
            var r: Rect = .{ .x0 = 255, .y0 = 255 };
            var k: u32 = 0;
            while (k < n) : (k += 1) {
                const idx = w.log_from_tail(i, k);
                const x: u8 = @intCast(idx % sim.grid_w);
                const y: u8 = @intCast(idx / sim.grid_w);
                self.put_cell(w, x, y);
                r.x0 = @min(r.x0, 2 * x);
                r.y0 = @min(r.y0, arena_y + 2 * y);
                r.x1 = @max(r.x1, 2 * x + 2);
                r.y1 = @max(r.y1, arena_y + 2 * y + 2);
            }
            S.mark_dirty(r);
        }

        /// Sudden death: rings drawn red as they close in, whatever events
        /// the rules sent (a block already on the ring turns red too).
        fn update_rings(self: *Self, w: *const sim.World) void {
            const now = @as(u32, w.sudden_death_ring);
            if (now < self.sd_drawn) {
                // A new World: everything was repainted already.
                self.sd_drawn = now;
                return;
            }
            while (self.sd_drawn < now) {
                self.sd_drawn += 1;
                self.repaint_ring(w, self.sd_drawn);
            }
        }

        /// Ring r (cells at distance r from the screen edge) and the rings
        /// beside it, whose floor glow follows it.
        fn repaint_ring(self: *Self, w: *const sim.World, r: u32) void {
            if (r == 0 or r >= sim.grid_h / 2) return;
            // Cells x in [a, xe), y in [a, ye): the ring and one cell to each side.
            const a: u8 = @intCast(r - 1);
            const xe: u8 = @intCast(sim.grid_w + 1 - r);
            const ye: u8 = @intCast(sim.grid_h + 1 - r);
            self.repaint_cells(w, a, a, xe, a + 3);
            self.repaint_cells(w, a, ye - 3, xe, ye);
            self.repaint_cells(w, a, a, a + 3, ye);
            self.repaint_cells(w, xe - 3, a, xe, ye);
        }

        // ------------------------------------------------ heads

        /// Head sprite, facing +f (forward) with lateral l, both -1..2
        /// around the 2x2 core at 0..1: 0 none, 1 cycle colour, 2 hot,
        /// 3 white: a white-hot core and nose with hot wings, the tail
        /// pixel in the trail colour. Rows are l = -1..2, columns f = -1..2.
        const sprite = [4][4]u2{
            .{ 0, 2, 2, 0 },
            .{ 1, 3, 3, 3 },
            .{ 1, 3, 3, 3 },
            .{ 0, 2, 2, 0 },
        };

        /// Top-left pixel of cycle c's head core: it glides one pixel into
        /// the next cell over the second half of the cell's progress.
        fn head_px(c: *const sim.Cycle) [2]i32 {
            const off: i32 = @intCast((c.p * 2) >> 16);
            return .{ 2 * @as(i32, c.x) + off * c.dir.dx(), arena_y + 2 * @as(i32, c.y) + off * c.dir.dy() };
        }

        fn draw_heads(self: *Self, w: *const sim.World) void {
            for (&w.cycles, 0..) |*c, i| {
                if (c.state != .alive) continue;
                const b = head_px(c);
                const bx = b[0];
                const by = b[1];
                var cols = [4]u16{ 0, colors.trail[i], colors.hot[i][0], colors.white };
                // Rubber: a stalled head flickers red against its wall.
                if (c.stalled and (w.tick >> 1) & 1 != 0) cols = .{ 0, colors.stall, colors.stall, colors.spark[1] };
                for (0..4) |li| {
                    for (0..4) |fi| {
                        const v = sprite[li][fi];
                        if (v == 0) continue;
                        const f: i32 = @as(i32, @intCast(fi)) - 1;
                        const l: i32 = @as(i32, @intCast(li)) - 1;
                        const p = local_to_screen(c.dir, f, l);
                        self.put_px(bx + p[0], by + p[1], cols[v]);
                    }
                }
                const r = Rect.clip(bx - 1, by - 1, 4, 4, arena_y);
                if (r.is_empty()) continue;
                S.mark_dirty(r);
                self.heads[i] = r;
            }
        }

        /// One arena pixel, through the banner, clipped. No mark.
        inline fn put_px(self: *const Self, px: i32, py: i32, c: u16) void {
            if (px < 0 or px >= screen_w or py < arena_y or py >= screen_h) return;
            const ux: u32 = @intCast(px);
            const uy: u32 = @intCast(py);
            S.put(ux, uy, if (self.in_banner(ux, uy)) self.through_banner(ux, uy, c) else c);
        }

        // ------------------------------------------------ effects

        /// Once per World tick: age the effects, then spawn from the
        /// World's events (crashes, grinding, stalls).
        fn fx_tick(self: *Self, w: *const sim.World, view: View) void {
            for (&self.dots) |*d| {
                if (d.life == 0) continue;
                d.life -= 1;
                d.x +%= d.vx;
                d.y +%= d.vy;
                // Drag: bursts slow down, sparks barely.
                if (d.kind != Dot.spark) {
                    d.vx -= @divTrunc(d.vx, 10);
                    d.vy -= @divTrunc(d.vy, 10);
                }
            }
            for (&self.tags) |*t| {
                if (t.life > 0) t.life -= 1;
            }
            for (w.events[0..w.n_events]) |e| {
                if (e.kind == .crash) {
                    self.spawn_burst(w, e.cycle, e.x, e.y);
                    if (view.tags & (@as(u8, 1) << @intCast(e.cycle & 3)) != 0) self.spawn_tag(e.cycle, @fromBackingInt(e.a), e.x, e.y);
                } else if (e.kind == .grind) {
                    self.spawn_grind(w, e.cycle, e.x, e.y, @fromBackingInt(@as(u2, @truncate(e.a))));
                } else if (e.kind == .stall) {
                    self.spawn_stall(w, e.cycle);
                }
            }
        }

        /// A stream for effect randomness: from the World, so the same
        /// round draws the same sparks (rewind replays, the cycle check).
        fn fx_rng(w: *const sim.World, cycle: u8, salt: u32) rng.Xorshift {
            return .init(rng.mix(w.seed ^ w.tick *% 0x9E3779B1, @as(u32, cycle) * 7 + salt));
        }

        fn add_dot(self: *Self, d: Dot) void {
            for (&self.dots) |*slot| {
                if (slot.life != 0 or slot.drawn) continue;
                slot.* = d;
                return;
            }
        }

        /// Unit-ish directions (x16) for burst particles.
        const dirs16 = [16][2]i8{
            .{ 16, 0 },  .{ 15, 6 },   .{ 11, 11 },   .{ 6, 15 },
            .{ 0, 16 },  .{ -6, 15 },  .{ -11, 11 },  .{ -15, 6 },
            .{ -16, 0 }, .{ -15, -6 }, .{ -11, -11 }, .{ -6, -15 },
            .{ 0, -16 }, .{ 6, -15 },  .{ 11, -11 },  .{ 15, -6 },
        };

        /// The derez burst: `fx.burst_dots` particles from the crash cell.
        pub fn spawn_burst(self: *Self, w: *const sim.World, cycle: u8, x: u8, y: u8) void {
            var r = fx_rng(w, cycle, 1);
            const cx: i16 = (2 * @as(i16, x) + 1) * 16;
            const cy: i16 = (arena_y + 2 * @as(i16, y) + 1) * 16;
            for (0..fx.burst_dots) |k| {
                const dir = dirs16[(k + r.below(2)) % 16];
                const speed: i16 = @intCast(10 + r.below(22));
                const life: u8 = @intCast(fx.burst_life - r.below(14));
                self.add_dot(.{
                    .x = cx,
                    .y = cy,
                    .vx = @divTrunc(@as(i16, dir[0]) * speed, 16),
                    .vy = @divTrunc(@as(i16, dir[1]) * speed, 16),
                    .life = life,
                    .max = life,
                    .kind = 1 + (cycle & 3),
                });
            }
        }

        /// Grind sparks: 1..3 from where cycle i's head meets the wall cell
        /// (wx, wy) on side `side`, flying back along the wall.
        pub fn spawn_grind(self: *Self, w: *const sim.World, cycle: u8, wx: u8, wy: u8, side: sim.Dir) void {
            _ = wx;
            _ = wy;
            const c = &w.cycles[cycle & 3];
            if (c.state != .alive) return;
            var r = fx_rng(w, cycle, 2);
            const b = head_px(c);
            // The contact edge: the head core's pixel next to the wall side.
            const ex: i32 = b[0] + switch (side) {
                .right => 2,
                .left => -1,
                else => @as(i32, @intCast(r.below(2))),
            };
            const ey: i32 = b[1] + switch (side) {
                .down => 2,
                .up => -1,
                else => @as(i32, @intCast(r.below(2))),
            };
            self.spawn_sparks(&r, ex, ey, c.dir.opposite(), side, fx.spark_min + r.below(fx.spark_max - fx.spark_min + 1));
        }

        /// Rubber: sparks off the nose of a stalled cycle i.
        pub fn spawn_stall(self: *Self, w: *const sim.World, cycle: u8) void {
            const c = &w.cycles[cycle & 3];
            if (c.state != .alive) return;
            var r = fx_rng(w, cycle, 3);
            const b = head_px(c);
            const nose = local_to_screen(c.dir, 2, @intCast(r.below(2)));
            const side = if (r.below(2) == 0) c.dir.cw() else c.dir.ccw();
            self.spawn_sparks(&r, b[0] + nose[0], b[1] + nose[1], c.dir.opposite(), side, 1 + r.below(2));
        }

        fn spawn_sparks(self: *Self, r: *rng.Xorshift, px: i32, py: i32, back: sim.Dir, side: sim.Dir, n: u32) void {
            for (0..n) |_| {
                const along: i16 = @intCast(14 + r.below(18));
                const out: i16 = @as(i16, @intCast(r.below(12))) - 3;
                const life: u8 = @intCast(fx.spark_life_min + r.below(fx.spark_life_max - fx.spark_life_min + 1));
                self.add_dot(.{
                    .x = @intCast(px * 16 + 8),
                    .y = @intCast(py * 16 + 8),
                    .vx = along * back.dx() - out * side.dx(),
                    .vy = along * back.dy() - out * side.dy(),
                    .life = life,
                    .max = life,
                    .kind = Dot.spark,
                });
            }
        }

        /// A crash name tag for cycle i at cell (x, y): above it, or below
        /// near the top, inside the screen margin.
        pub fn spawn_tag(self: *Self, cycle: u8, crash: sim.Crash, x: u8, y: u8) void {
            const name = crash.name();
            if (name.len == 0) return;
            const tw: i32 = tag_w(name);
            var tx: i32 = 2 * @as(i32, x) + 1 - @divTrunc(tw, 2);
            var ty: i32 = arena_y + 2 * @as(i32, y) - tag_h - 3;
            if (ty < arena_y + margin) ty = arena_y + 2 * @as(i32, y) + 5;
            tx = std.math.clamp(tx, margin, screen_w - margin - tw);
            ty = std.math.clamp(ty, arena_y, screen_h - margin - tag_h);
            const t = &self.tags[cycle & 3];
            t.crash = crash;
            t.cycle = cycle & 3;
            t.x = @intCast(tx);
            t.y = @intCast(ty);
            t.life = fx.tag_ticks;
        }

        const tag_h = 9;
        fn tag_w(name: []const u8) i32 {
            return @as(i32, @intCast(name.len)) * font5.advance - 1 + 4;
        }

        fn erase_fx(self: *Self, w: *const sim.World) void {
            for (&self.dots) |*d| {
                if (!d.drawn) continue;
                d.drawn = false;
                self.repaint_rect(w, .{ .x0 = d.px, .y0 = d.py, .x1 = d.px + d.size, .y1 = d.py + d.size });
            }
            for (&self.tags) |*t| {
                if (t.drawn.is_empty()) continue;
                self.repaint_rect(w, t.drawn);
                t.drawn = .empty;
            }
        }

        fn draw_fx(self: *Self, w: *const sim.World) void {
            for (&self.dots) |*d| {
                if (d.life == 0) continue;
                const px: i32 = d.x >> 4;
                const py: i32 = d.y >> 4;
                if (px < 0 or px >= screen_w or py < arena_y or py >= screen_h) continue;
                // Age 0..3 of the colour ramp; bursts flicker at the end.
                const age: u32 = 3 - @min(3, @as(u32, d.life) * 4 / (@as(u32, d.max) + 1));
                var c: u16 = undefined;
                var size: u8 = 1;
                if (d.kind == Dot.spark) {
                    c = colors.spark[@min(age, 2)];
                } else {
                    if (d.life < 8 and (d.life + w.tick) & 1 != 0) continue;
                    c = colors.burst[(d.kind - 1) & 3][age];
                    // Big and hot first, then embers.
                    if (age < 2 and px + 1 < screen_w and py + 1 < screen_h) size = 2;
                }
                var k: u8 = 0;
                while (k < size * size) : (k += 1) self.put_px(px + (k & 1), py + (k >> 1), c);
                d.drawn = true;
                d.px = @intCast(px);
                d.py = @intCast(py);
                d.size = size;
                S.mark_dirty(.{ .x0 = d.px, .y0 = d.py, .x1 = d.px + size, .y1 = d.py + size });
            }
            for (&self.tags) |*t| {
                if (t.life == 0) continue;
                // Never over a banner's text (LEVEL CLEAR right after the
                // last program's crash).
                if (self.banner_on and Rect.intersects(self.banner_rect, Rect.clip(t.x, t.y, tag_w(t.crash.name()), tag_h, arena_y))) continue;
                self.draw_tag(w, t);
            }
        }

        /// The tag box: the arena under it dimmed, the name in the 4x5
        /// font in the cycle's colour.
        fn draw_tag(self: *Self, w: *const sim.World, t: *Tag) void {
            const name = t.crash.name();
            const r = Rect.clip(t.x, t.y, tag_w(name), tag_h, arena_y);
            if (r.is_empty()) return;
            var py: u32 = r.y0;
            while (py < r.y1) : (py += 1) {
                var px: u32 = r.x0;
                while (px < r.x1) : (px += 1) {
                    const cc = cell_colors(w, @intCast(px / 2), @intCast((py - arena_y) / 2));
                    const k = (px & 1) + 2 * ((py - arena_y) & 1);
                    var c = cc[k];
                    if (self.in_banner(px, py)) c = self.through_banner(px, py, c);
                    S.put(px, py, dim565(dim565(c)));
                }
            }
            const target: ScreenTarget = .{ .clip = r };
            raster5(name, @as(i32, t.x) + 2, @as(i32, t.y) + 2, target, colors.hot[t.cycle][1]);
            S.mark_dirty(r);
            t.drawn = r;
        }

        // ------------------------------------------------ banner and HUD

        inline fn in_banner(self: *const Self, px: u32, py: u32) bool {
            const r = self.banner_rect;
            return self.banner_on and px >= r.x0 and px < r.x1 and py >= r.y0 and py < r.y1;
        }

        /// The colour of pixel (px, py) inside the banner box over arena colour c.
        inline fn through_banner(self: *const Self, px: u32, py: u32, c: u16) u16 {
            const o = self.ov[px][py - arena_y];
            return if (o != 0) self.ov_colors[o] else dim565(c);
        }

        /// Puts up, changes or takes down the banner, repainting the cells
        /// of the old and the new box.
        fn set_banner(self: *Self, w: *const sim.World, want: ?Banner) void {
            if (want) |b| {
                if (self.banner_on and std.meta.eql(b, self.banner)) return;
                if (self.banner_on and same_but_colors(b, self.banner)) {
                    // A blink: recolour the lines that changed, nothing else.
                    for (b.lines[0..b.n], self.banner.lines[0..b.n], 0..) |l, old, i| {
                        if (l.color == old.color) continue;
                        self.ov_colors[ov_line0 + i] = l.color;
                        self.repaint_rect(w, self.line_rects[i]);
                    }
                    self.banner = b;
                    return;
                }
            } else if (!self.banner_on) return;
            var r = if (self.banner_on) self.banner_rect else Rect.empty;
            self.banner_on = false;
            if (want) |b| {
                self.load_banner(b);
                const n = self.banner_rect;
                if (r.is_empty()) {
                    r = n;
                } else {
                    r = .{ .x0 = @min(r.x0, n.x0), .y0 = @min(r.y0, n.y0), .x1 = @max(r.x1, n.x1), .y1 = @max(r.y1, n.y1) };
                }
            }
            self.repaint_rect(w, r);
        }

        /// Makes `b` the banner: its box and its overlay. Draws nothing.
        fn load_banner(self: *Self, b: Banner) void {
            const r = b.rect();
            self.banner = b;
            self.banner_rect = r;
            self.banner_on = true;
            var x: u32 = r.x0;
            while (x < r.x1) : (x += 1) @memset(self.ov[x][r.y0 - arena_y .. r.y1 - arena_y], 0);
            self.ov_colors[ov_shadow] = colors.black;
            self.ov_colors[ov_iris] = colors.white;
            const target: OverlayTarget = .{ .self = self, .clip = r };
            var y: i32 = @as(i32, r.y0) + Banner.pad;
            if (b.iris) {
                const ix: i32 = (screen_w - iris.size) / 2;
                for (0..iris.size) |iy| {
                    for (0..iris.size) |ixx| {
                        if (iris.pixel(ixx, iy)) target.set(ix + @as(i32, @intCast(ixx)), y + @as(i32, @intCast(iy)), ov_iris);
                    }
                }
                y += iris.size + Banner.iris_gap;
            }
            for (b.lines[0..b.n], 0..) |l, i| {
                const lw: i32 = @intCast(l.width());
                const x0: i32 = @divTrunc(@as(i32, screen_w) - lw, 2);
                const idx: u8 = @intCast(ov_line0 + i);
                self.ov_colors[idx] = l.color;
                // The shadow one pixel down-right, then the ink over it.
                raster(l.str(), x0 + 1, y + 1, l.scale, target, ov_shadow);
                raster(l.str(), x0, y, l.scale, target, idx);
                self.line_rects[i] = Rect.clip(x0, y, lw, 8 * @as(i32, l.scale), arena_y);
                y += 8 * @as(i32, l.scale) + Banner.line_gap;
            }
        }

        /// Same text, scales and layout; only line colours may differ.
        fn same_but_colors(a: Banner, b: Banner) bool {
            if (a.n != b.n or a.iris != b.iris or a.cy != b.cy) return false;
            for (a.lines[0..a.n], b.lines[0..b.n]) |la, lb| {
                if (la.len != lb.len or la.scale != lb.scale or !std.mem.eql(u8, la.str(), lb.str())) return false;
            }
            return true;
        }

        const OverlayTarget = struct {
            self: *Self,
            clip: Rect,
            fn set(t: OverlayTarget, x: i32, y: i32, v: u8) void {
                if (x < t.clip.x0 or x >= t.clip.x1 or y < t.clip.y0 or y >= t.clip.y1) return;
                t.self.ov[@intCast(x)][@intCast(y - arena_y)] = v;
            }
        };

        const ScreenTarget = struct {
            clip: Rect,
            fn set(t: ScreenTarget, x: i32, y: i32, c: u16) void {
                if (x < t.clip.x0 or x >= t.clip.x1 or y < t.clip.y0 or y >= t.clip.y1) return;
                S.put(@intCast(x), @intCast(y), c);
            }
        };

        fn hud_key(w: *const sim.World, h: Hud) HudKey {
            var k: HudKey = .{ .left = h.left, .right = h.right, .lives = h.lives, .max_lives = h.max_lives };
            if (h.energy) |e| {
                const full: u32 = Hud.bar_w - 2;
                const px: u32 = @min(full, @as(u32, e) * full / sim.tuning.energy_max);
                k.bar = @intCast(px);
                k.bar_color = if (@as(u32, e) * 5 < sim.tuning.energy_max and (w.tick >> 3) & 1 != 0)
                    colors.bar_low
                else
                    colors.bar_fill[@min(h.bar_mode, 2)];
            }
            return k;
        }

        fn maybe_draw_hud(self: *Self, w: *const sim.World, h: Hud) void {
            if (!std.meta.eql(hud_key(w, h), self.hud)) self.draw_hud(w, h);
        }

        /// The HUD strip: black, the 4x5 font at y 2..6, 2 px from the
        /// edges; life pips and the energy bar between the texts.
        fn draw_hud(self: *Self, w: *const sim.World, h: Hud) void {
            const k = hud_key(w, h);
            for (0..screen_w) |x| {
                for (0..hud_h) |y| S.put(@intCast(x), @intCast(y), colors.hud_bg);
            }
            const target: ScreenTarget = .{ .clip = .{ .x1 = screen_w, .y1 = hud_h } };
            raster5(h.left.str(), margin, margin, target, h.left.color);
            raster5(h.right.str(), screen_w - margin - font5.width(h.right.str()), margin, target, h.right.color);
            // Life pips: small rounded squares.
            var i: u8 = 0;
            while (i < k.max_lives) : (i += 1) {
                const x0: u32 = Hud.pips_x + @as(u32, i) * (Hud.pip_w + Hud.pip_gap);
                const c = if (i < k.lives) colors.pip_on else colors.pip_off;
                for (0..Hud.pip_w) |dx| {
                    for (0..5) |dy| {
                        const corner = (dx == 0 or dx == Hud.pip_w - 1) and (dy == 0 or dy == 4);
                        if (!corner) S.put(@intCast(x0 + dx), @intCast(margin + dy), c);
                    }
                }
            }
            // The energy bar: a frame, empty inside, filled from the left.
            if (k.bar) |fill| {
                for (0..Hud.bar_w) |dx| {
                    for (0..5) |dy| {
                        const edge = dx == 0 or dx == Hud.bar_w - 1 or dy == 0 or dy == 4;
                        const c = if (edge) colors.bar_frame else if (dx - 1 < fill) k.bar_color else colors.bar_empty;
                        S.put(@intCast(Hud.bar_x + dx), @intCast(margin + dy), c);
                    }
                }
            }
            S.mark_dirty(target.clip);
            self.hud = k;
        }

        // ------------------------------------------------ pixels

        /// Writes the four pixels of cell (x, y), through the banner if the
        /// cell is in its box. No mark.
        fn put_cell(self: *const Self, w: *const sim.World, x: u8, y: u8) void {
            const px: u32 = 2 * @as(u32, x);
            const py: u32 = arena_y + 2 * @as(u32, y);
            var c = cell_colors(w, x, y);
            // Boxes are cell-aligned: a cell is wholly in or out.
            if (self.in_banner(px, py)) {
                c[0] = self.through_banner(px, py, c[0]);
                c[1] = self.through_banner(px + 1, py, c[1]);
                c[2] = self.through_banner(px, py + 1, c[2]);
                c[3] = self.through_banner(px + 1, py + 1, c[3]);
            }
            S.put(px, py, c[0]);
            S.put(px + 1, py, c[1]);
            S.put(px, py + 1, c[2]);
            S.put(px + 1, py + 1, c[3]);
        }

        /// Text in the 8x8 font at `scale`: target.set(x, y, v) per ink pixel.
        fn raster(s: []const u8, x: i32, y: i32, scale: u8, target: anytype, v: anytype) void {
            var gx = x;
            for (s) |ch| {
                const g = if (ch >= font.first and ch <= font.last) font.glyphs[ch - font.first] else font.glyphs[0];
                for (g, 0..) |row, ry| {
                    if (row == 0) continue;
                    for (0..8) |rx| {
                        if (row & (@as(u8, 0x80) >> @intCast(rx)) == 0) continue;
                        for (0..scale) |sy| {
                            for (0..scale) |sx| {
                                target.set(gx + @as(i32, @intCast(rx * scale + sx)), y + @as(i32, @intCast(ry * scale + sy)), v);
                            }
                        }
                    }
                }
                gx += 8 * @as(i32, scale);
            }
        }

        /// Text in the 4x5 font: target.set(x, y, v) per ink pixel.
        fn raster5(s: []const u8, x: i32, y: i32, target: anytype, v: anytype) void {
            var gx = x;
            for (s) |ch| {
                const g = font5.glyph(ch);
                for (g, 0..) |row, ry| {
                    for (0..4) |rx| {
                        if (row & (@as(u4, 8) >> @intCast(rx)) == 0) continue;
                        target.set(gx + @as(i32, @intCast(rx)), y + @as(i32, @intCast(ry)), v);
                    }
                }
                gx += font5.advance;
            }
        }
    };
}

/// Sprite-local (forward f, lateral l) to a screen offset from the head
/// cell's top-left pixel, for heading d (the 2x2 core maps to itself).
fn local_to_screen(d: sim.Dir, f: i32, l: i32) [2]i32 {
    return switch (d) {
        .right => .{ f, l },
        .left => .{ 1 - f, 1 - l },
        .down => .{ 1 - l, f },
        .up => .{ l, 1 - f },
    };
}

/// The floor of an empty cell: lines every 8 px (4 cells) through the
/// cell's left column and top row, brighter crossings. Indexed by
/// (x % 4 == 0) * 2 + (y % 4 == 0).
const floor_cells = [4][4]u16{
    .{ colors.floor, colors.floor, colors.floor, colors.floor },
    .{ colors.line, colors.line, colors.floor, colors.floor },
    .{ colors.line, colors.floor, colors.line, colors.floor },
    .{ colors.cross, colors.line, colors.line, colors.floor },
};

/// The floor's pixel columns: a column on a grid line (x % 8 == 0) and
/// any other, top to bottom over the arena.
const floor_line_column = blk: {
    var c: [arena_h]u16 = undefined;
    for (&c, 0..) |*p, y| p.* = if (y & 7 == 0) colors.cross else colors.line;
    break :blk c;
};
const floor_column = blk: {
    var c: [arena_h]u16 = undefined;
    for (&c, 0..) |*p, y| p.* = if (y & 7 == 0) colors.line else colors.floor;
    break :blk c;
};

/// True if cell (x, y) draws as the bare floor: empty, no wall beside it.
fn bare_floor(w: *const sim.World, x: u8, y: u8) bool {
    const i = sim.index(x, y);
    if (w.grid[i] != sim.empty) return false;
    return w.grid[i - sim.grid_w] | w.grid[i + sim.grid_w] | w.grid[i - 1] | w.grid[i + 1] == 0;
}

/// The glow a wall value casts on the floor next to it, or null. `sd`
/// is the sudden-death ring count; (x, y) is the wall's cell.
inline fn glow_of(v: u8, sd: u32, x: u32, y: u32) ?u16 {
    const t = v & ~sim.fx_bit;
    if (t == sim.empty) return null;
    if (sim.trail_owner(t)) |o| return colors.glow[o];
    if (t == sim.rim) return colors.rim_glow;
    return if (in_death_ring(sd, x, y)) colors.death_glow else colors.block_glow;
}

/// True if a block at (x, y) belongs to sudden death's closing rings
/// (rings 1..sd): drawn red, not layout blue.
inline fn in_death_ring(sd: u32, x: u32, y: u32) bool {
    if (sd == 0) return false;
    const r = sim.ring_of(x, y);
    return r >= 1 and r <= sd;
}

/// The 4x5 HUD and tag font: rows top to bottom, bit 3 the left column.
/// Digits, capitals and a few signs; anything else draws blank.
pub const font5 = struct {
    pub const advance = 5;
    const digits = [10][5]u4{
        .{ 0b0110, 0b1001, 0b1001, 0b1001, 0b0110 },
        .{ 0b0010, 0b0110, 0b0010, 0b0010, 0b0111 },
        .{ 0b1110, 0b0001, 0b0110, 0b1000, 0b1111 },
        .{ 0b1110, 0b0001, 0b0110, 0b0001, 0b1110 },
        .{ 0b1001, 0b1001, 0b1111, 0b0001, 0b0001 },
        .{ 0b1111, 0b1000, 0b1110, 0b0001, 0b1110 },
        .{ 0b0110, 0b1000, 0b1110, 0b1001, 0b0110 },
        .{ 0b1111, 0b0001, 0b0010, 0b0100, 0b0100 },
        .{ 0b0110, 0b1001, 0b0110, 0b1001, 0b0110 },
        .{ 0b0110, 0b1001, 0b0111, 0b0001, 0b0110 },
    };
    const letters = [26][5]u4{
        .{ 0b0110, 0b1001, 0b1111, 0b1001, 0b1001 }, // A
        .{ 0b1110, 0b1001, 0b1110, 0b1001, 0b1110 }, // B
        .{ 0b0111, 0b1000, 0b1000, 0b1000, 0b0111 }, // C
        .{ 0b1110, 0b1001, 0b1001, 0b1001, 0b1110 }, // D
        .{ 0b1111, 0b1000, 0b1110, 0b1000, 0b1111 }, // E
        .{ 0b1111, 0b1000, 0b1110, 0b1000, 0b1000 }, // F
        .{ 0b0111, 0b1000, 0b1011, 0b1001, 0b0111 }, // G
        .{ 0b1001, 0b1001, 0b1111, 0b1001, 0b1001 }, // H
        .{ 0b1110, 0b0100, 0b0100, 0b0100, 0b1110 }, // I
        .{ 0b0001, 0b0001, 0b0001, 0b1001, 0b0110 }, // J
        .{ 0b1001, 0b1010, 0b1100, 0b1010, 0b1001 }, // K
        .{ 0b1000, 0b1000, 0b1000, 0b1000, 0b1111 }, // L
        .{ 0b1001, 0b1111, 0b1111, 0b1001, 0b1001 }, // M
        .{ 0b1001, 0b1101, 0b1011, 0b1001, 0b1001 }, // N
        .{ 0b0110, 0b1001, 0b1001, 0b1001, 0b0110 }, // O
        .{ 0b1110, 0b1001, 0b1110, 0b1000, 0b1000 }, // P
        .{ 0b0110, 0b1001, 0b1001, 0b1010, 0b0101 }, // Q
        .{ 0b1110, 0b1001, 0b1110, 0b1010, 0b1001 }, // R
        .{ 0b0111, 0b1000, 0b0110, 0b0001, 0b1110 }, // S
        .{ 0b1110, 0b0100, 0b0100, 0b0100, 0b0100 }, // T
        .{ 0b1001, 0b1001, 0b1001, 0b1001, 0b0110 }, // U
        .{ 0b1010, 0b1010, 0b1010, 0b1010, 0b0100 }, // V
        .{ 0b1001, 0b1001, 0b1111, 0b1111, 0b1001 }, // W
        .{ 0b1001, 0b1001, 0b0110, 0b1001, 0b1001 }, // X
        .{ 0b1010, 0b1010, 0b0100, 0b0100, 0b0100 }, // Y
        .{ 0b1111, 0b0001, 0b0110, 0b1000, 0b1111 }, // Z
    };
    const blank = [5]u4{ 0, 0, 0, 0, 0 };

    pub fn glyph(ch: u8) [5]u4 {
        return switch (ch) {
            '0'...'9' => digits[ch - '0'],
            'A'...'Z' => letters[ch - 'A'],
            'a'...'z' => letters[ch - 'a'],
            '+' => .{ 0b0000, 0b0100, 0b1110, 0b0100, 0b0000 },
            '-' => .{ 0b0000, 0b0000, 0b1110, 0b0000, 0b0000 },
            ':' => .{ 0b0000, 0b0100, 0b0000, 0b0100, 0b0000 },
            '.' => .{ 0b0000, 0b0000, 0b0000, 0b0000, 0b0100 },
            '/' => .{ 0b0001, 0b0010, 0b0010, 0b0100, 0b1000 },
            '!' => .{ 0b0100, 0b0100, 0b0100, 0b0000, 0b0100 },
            '*' => .{ 0b0000, 0b1010, 0b0100, 0b1010, 0b0000 },
            else => blank,
        };
    }

    /// Ink width of s in pixels (no trailing gap).
    pub fn width(s: []const u8) i32 {
        if (s.len == 0) return 0;
        return @as(i32, @intCast(s.len)) * advance - 1;
    }
};

/// The four pixels of cell (x, y): top-left, top-right, bottom-left,
/// bottom-right.
pub fn cell_colors(w: *const sim.World, x: u8, y: u8) [4]u16 {
    const i = sim.index(x, y);
    const v = w.grid[i] & ~sim.fx_bit;
    if (v == sim.empty) {
        var c = floor_cells[@as(u32, @intFromBool(x & 3 == 0)) * 2 + @intFromBool(y & 3 == 0)];
        // Glow on the pixels that face a wall (interior cells only have
        // in-grid neighbours; the rim is never empty).
        const nu = w.grid[i - sim.grid_w];
        const nd = w.grid[i + sim.grid_w];
        const nl = w.grid[i - 1];
        const nr = w.grid[i + 1];
        if (nu | nd | nl | nr == 0) return c;
        const sd = @as(u32, w.sudden_death_ring);
        const up = glow_of(nu, sd, x, y - 1);
        const down = glow_of(nd, sd, x, y + 1);
        const left = glow_of(nl, sd, x - 1, y);
        const right = glow_of(nr, sd, x + 1, y);
        if (left orelse up) |g| c[0] = g;
        if (right orelse up) |g| c[1] = g;
        if (left orelse down) |g| c[2] = g;
        if (right orelse down) |g| c[3] = g;
        return c;
    }
    if (sim.trail_owner(v)) |o| {
        const cy = &w.cycles[o];
        if (cy.state != .alive) return @splat(colors.dead[o]);
        // The three newest cells glow hotter.
        var k: u32 = 0;
        while (k < 3) : (k += 1) {
            const at = w.log_at(o, k) orelse break;
            if (at == i) return @splat(colors.hot[o][k]);
        }
        return @splat(colors.trail[o]);
    }
    if (v == sim.rim) {
        // A bright outer edge with a darker inner line.
        var c: [4]u16 = @splat(colors.rim);
        if (x == 0) {
            c[1] = colors.rim_inner;
            c[3] = colors.rim_inner;
        } else if (x == sim.grid_w - 1) {
            c[0] = colors.rim_inner;
            c[2] = colors.rim_inner;
        }
        if (y == 0) {
            if (x != 0 and x != sim.grid_w - 1) {
                c[2] = colors.rim_inner;
                c[3] = colors.rim_inner;
            }
        } else if (y == sim.grid_h - 1) {
            if (x != 0 and x != sim.grid_w - 1) {
                c[0] = colors.rim_inner;
                c[1] = colors.rim_inner;
            }
        }
        return c;
    }
    // Sudden death: solid red, alternate rings a shade darker, so the
    // closing rings read as stripes.
    if (in_death_ring(@as(u32, w.sudden_death_ring), x, y)) return @splat(if (sim.ring_of(x, y) & 1 != 0) colors.death else colors.death_dark);
    return .{ colors.block_hi, colors.block, colors.block, colors.block };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

/// A screen in memory that records, per pixel, whether it was put and
/// whether a mark covered it, to check every put is marked.
const TestScreen = struct {
    var px: [screen_w][screen_h]u16 = undefined;
    var put_mask: [screen_w][screen_h]bool = undefined;
    var mark_mask: [screen_w][screen_h]bool = undefined;
    var puts: u32 = 0;

    fn reset() void {
        for (&px) |*c| @memset(c, 0);
        new_frame();
    }
    fn new_frame() void {
        for (&put_mask) |*c| @memset(c, false);
        for (&mark_mask) |*c| @memset(c, false);
        puts = 0;
    }
    pub fn put(x: u32, y: u32, c: u16) void {
        px[x][y] = c;
        put_mask[x][y] = true;
        puts += 1;
    }
    pub fn mark_dirty(r: Rect) void {
        var x: u32 = r.x0;
        while (x < r.x1) : (x += 1) {
            var y: u32 = r.y0;
            while (y < r.y1) : (y += 1) mark_mask[x][y] = true;
        }
    }
    /// Puts this frame that no mark covers.
    fn unmarked() u32 {
        var n: u32 = 0;
        for (0..screen_w) |x| {
            for (0..screen_h) |y| {
                if (put_mask[x][y] and !mark_mask[x][y]) n += 1;
            }
        }
        return n;
    }
};

var tworld: sim.World = undefined;
var test_r: Renderer(TestScreen) = .{};
var test_fresh: Renderer(TestScreen) = .{};
var tref: sim.World = undefined;

test "every put is inside a marked rect, and incremental frames match a full repaint" {
    const ai = @import("ai.zig");
    const w = &tworld;
    w.init(.{ .n_cycles = 4 }, 11);
    var brains: [4]ai.Brain = undefined;
    for (&brains, 0..) |*b, i| b.* = .init(.avoid, @intCast(i + 1));
    const r = &test_r;
    r.* = .{};
    TestScreen.reset();
    var view: View = .{};
    view.hud.left = .of("PASCAL", 1, colors.hud_text);
    r.frame(w, view);
    try testing.expectEqual(@as(u32, 0), TestScreen.unmarked());
    var t: u32 = 0;
    var compared: u32 = 0;
    while (t < 2400) : (t += 1) {
        var in: [sim.max_cycles]sim.Input = @splat(.idle);
        // Cycle 0 drives badly now and then, so crashes and fades happen.
        for (0..4) |i| in[i] = ai.decide(&brains[i], w, i);
        if (t % 97 == 0) in[0] = .{ .press = sim.Press.of(@fromBackingInt(@intCast(t % 4))) };
        w.step(in);
        // A banner comes and goes, the HUD changes.
        view.banner = null;
        if ((t / 40) % 3 == 0) {
            var b: Banner = .{};
            b.add("RUN", 2, colors.white);
            b.add(if (t % 80 < 40) "LEVEL 3" else "PASCAL", 1, colors.hud_text);
            // A blinking line: a colour-only change.
            b.add("PRESS A", 1, if (t % 14 < 7) colors.white else colors.hud_dim);
            view.banner = b;
        }
        view.hud.right = .of(if (t % 300 < 150) "0500" else "1000", 1, colors.hud_text);
        view.hud.energy = @intCast((t * 7) % 1001);
        view.hud.bar_mode = @intCast((t / 50) % 3);
        view.hud.lives = @intCast(1 + (t / 200) % 3);
        view.hud.max_lives = 3;
        view.tags = 0b1110;
        // Synthetic grind and stall sparks (Track S's events), beside the
        // derez bursts and crash tags the real crash events make.
        if (t % 3 == 0) {
            for (0..4) |i| r.spawn_grind(w, @intCast(i), 0, 0, w.cycles[i].dir.cw());
        }
        if (t % 7 == 0) r.spawn_stall(w, @intCast(t / 7 % 4));
        TestScreen.new_frame();
        r.frame(w, view);
        try testing.expectEqual(@as(u32, 0), TestScreen.unmarked());
        if (w.result != .running and w.alive_count() == 0) break;
        // Every 25 ticks: the incremental screen equals a fresh repaint.
        if (t % 25 == 12) {
            const saved = TestScreen.px;
            test_fresh = .{};
            test_fresh.dots = r.dots;
            test_fresh.tags = r.tags;
            test_fresh.full_repaint(w, view);
            for (0..screen_w) |x| {
                for (0..screen_h) |y| {
                    if (saved[x][y] != TestScreen.px[x][y]) {
                        std.debug.print("pixel ({d},{d}) differs at tick {d}: {x} vs {x}\n", .{ x, y, w.tick, saved[x][y], TestScreen.px[x][y] });
                        return error.TestExpectedEqual;
                    }
                }
            }
            compared += 1;
        }
    }
    try testing.expect(compared > 6);
}

test "block events repaint their cells, marked, equal to a full repaint" {
    const w = &tworld;
    w.init(.{ .n_cycles = 2 }, 5);
    const r = &test_r;
    r.* = .{};
    TestScreen.reset();
    r.frame(w, .{});
    // What Track S's sudden death does: up to 6 ring-1 cells a tick become
    // block, each with an event naming the ring.
    w.tick += 1;
    w.n_events = 0;
    for (0..6) |k| {
        const x: u8 = @intCast(1 + 3 * k);
        w.grid[sim.index(x, 1)] = sim.block;
        w.events[w.n_events] = .{ .kind = .block, .x = x, .y = 1, .a = 1 };
        w.n_events += 1;
    }
    TestScreen.new_frame();
    r.frame(w, .{});
    try testing.expectEqual(@as(u32, 0), TestScreen.unmarked());
    const saved = TestScreen.px;
    test_fresh = .{};
    test_fresh.full_repaint(w, .{});
    for (0..screen_w) |x| {
        for (0..screen_h) |y| try testing.expectEqual(saved[x][y], TestScreen.px[x][y]);
    }
}

test "HUD text and pips keep 2 px from the screen edges" {
    const r = &test_r;
    const w = &tworld;
    w.init(.{ .n_cycles = 2 }, 5);
    r.* = .{};
    TestScreen.reset();
    var view: View = .{};
    view.hud = .{ .left = .of("12 FORTRAN", 1, colors.hud_text), .right = .of("999999", 1, colors.hud_text), .energy = 1000, .lives = 3, .max_lives = 3 };
    r.frame(w, view);
    // Ink only in x 2..157, y 2..6 of the HUD strip.
    for (0..screen_w) |x| {
        for (0..hud_h) |y| {
            if (TestScreen.px[x][y] == colors.hud_bg) continue;
            try testing.expect(x >= margin and x < screen_w - margin and y >= margin and y < hud_h - 1);
        }
    }
}

test "cell colours: floor lines, glow beside a trail, hot newest cells" {
    const w = &tworld;
    w.init(.{ .n_cycles = 1 }, 1);
    // Cell (4, 4): pixel (8, 16), on both grid lines.
    try testing.expectEqual(colors.cross, cell_colors(w, 4, 4)[0]);
    try testing.expectEqual(colors.floor, cell_colors(w, 5, 5)[3]);
    const c = w.cycles[0];
    try testing.expectEqual(colors.hot[0][0], cell_colors(w, c.x, c.y)[0]);
    // The cell below the head glows on its top row.
    const below = cell_colors(w, c.x, c.y + 1);
    try testing.expectEqual(colors.glow[0], below[0]);
    try testing.expectEqual(colors.glow[0], below[1]);
    try testing.expect(below[2] != colors.glow[0]);
    _ = &tref;
}

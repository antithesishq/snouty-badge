//! Scaled sprites (SPEC 6.3): nearest-neighbour blit of 4-bit sheets from
//! the `gfx` module at a 1/256 scale, and the machines drawn back to front
//! from the world. Draw only; reads `world.w` and the camera.
const cart = @import("cart-api");
const gfx = @import("gfx");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const camera = @import("camera.zig");
const render = @import("render.zig");

pub const Palette = [16]cart.Pixel;

/// Palette of `sheet` converted to framebuffer pixels at comptime (<= 16 colours).
pub fn sheet_palette(comptime sheet: type) Palette {
    var out: Palette = undefined;
    for (&out) |*p| p.* = .from_color(.{ .r = 0, .g = 0, .b = 0 });
    for (sheet.colors, 0..) |c, i| out[i] = .from_color(c);
    return out;
}

pub const BlitOpts = struct {
    /// Skip pixels where screen (x + y) is odd (shadow translucency).
    skip_odd: bool = false,
    /// Draw every opaque pixel in this colour (hit flash).
    flat: ?cart.Pixel = null,
    /// Mirror horizontally.
    flip: bool = false,
};

/// Draws cell `cell` of a horizontal strip (`cell_w` x `cell_h` cells)
/// scaled by `scale`/256, centred on `cx` with its bottom row on `bottom_y`.
/// Index 0 is transparent. Clipped to the screen.
pub fn blit_scaled(
    comptime sheet: type,
    comptime cell_w: u32,
    comptime cell_h: u32,
    cell: u32,
    cx: i32,
    bottom_y: i32,
    scale: u32,
    pal: *const Palette,
    opts: BlitOpts,
) void {
    const dw: i32 = @intCast((cell_w * scale) >> 8);
    const dh: i32 = @intCast((cell_h * scale) >> 8);
    if (dw <= 0 or dh <= 0) return;
    const x0 = cx - @divTrunc(dw, 2);
    const y0 = bottom_y - dh;
    // Source step per destination pixel, 16.16.
    const step: u32 = (cell_w << 16) / @as(u32, @intCast(dw));
    const step_y: u32 = (cell_h << 16) / @as(u32, @intCast(dh));
    const col_begin: i32 = @max(0, -x0);
    const col_end: i32 = @min(dw, render.screen_w - x0);
    const row_begin: i32 = @max(0, -y0);
    const row_end: i32 = @min(dh, render.screen_h - y0);
    if (col_begin >= col_end or row_begin >= row_end) return;
    const src_x0: usize = cell * cell_w;
    var dx = col_begin;
    while (dx < col_end) : (dx += 1) {
        const sxx: u32 = (@as(u32, @intCast(if (opts.flip) dw - 1 - dx else dx)) * step) >> 16;
        const sx: usize = src_x0 + @min(sxx, cell_w - 1);
        const screen_x = x0 + dx;
        const column = &cart.framebuffer[@intCast(screen_x)];
        var dy = row_begin;
        while (dy < row_end) : (dy += 1) {
            const screen_y = y0 + dy;
            if (opts.skip_odd and ((screen_x + screen_y) & 1) == 1) continue;
            const sy: usize = @min((@as(u32, @intCast(dy)) * step_y) >> 16, cell_h - 1);
            const idx = sheet.indices.get(sy * sheet.width + sx);
            if (idx == 0) continue;
            column[@intCast(screen_y)] = if (opts.flat) |f| f else pal[idx];
        }
    }
}

const anteater_pal = sheet_palette(gfx.anteater);
const shadow_pal = sheet_palette(gfx.shadow);
const machine_pal = sheet_palette(gfx.machine);
const fx_pal = sheet_palette(gfx.fx);

/// Hop arc height in world px at the top.
const hop_height: i32 = 20;

const Entry = struct { index: u8, p: camera.Projected };

/// Every active machine, back to front. The player's lean frame follows
/// its steering; hopping machines rise on a sine arc over their shadow.
pub fn draw_machines() void {
    var list: [world.machine_count]Entry = undefined;
    var n: usize = 0;
    for (world.w.machines[0..world.w.active_count], 0..) |*m, i| {
        if (!m.active) continue;
        const p = camera.project(m.x, m.y) orelse continue;
        if (p.sy < tuning.horizon_y + 2) continue;
        list[n] = .{ .index = @intCast(i), .p = p };
        n += 1;
    }
    // Insertion sort by distance, far first.
    var i: usize = 1;
    while (i < n) : (i += 1) {
        const e = list[i];
        var j = i;
        while (j > 0 and list[j - 1].p.zf < e.p.zf) : (j -= 1) list[j] = list[j - 1];
        list[j] = e;
    }
    for (list[0..n]) |e| draw_machine(&world.w.machines[e.index], e.index, e.p);
}

fn draw_machine(m: *const world.Machine, index: u8, p: camera.Projected) void {
    // Shadow on the floor row.
    blit_scaled(gfx.shadow, 32, 6, 0, p.sx, p.sy, p.scale, &shadow_pal, .{ .skip_odd = true });
    // Body: hover height plus the hop arc, in screen px at this scale.
    var lift: i32 = tuning.hover_height;
    if (m.hop > 0) {
        const elapsed: i32 = @as(i32, tuning.hop_ticks) - @as(i32, m.hop);
        const a: fixed.Turn = @intCast(@divTrunc(elapsed * 32768, tuning.hop_ticks));
        lift += (fixed.sin(a) * hop_height) >> fixed.Q;
    }
    const lift_px: i32 = @intCast((@as(u32, @intCast(lift)) * p.scale) >> 8);
    const flash = m.immune > 0 and (m.immune / 2) % 2 == 0 and m.crash == .none;
    const opts = BlitOpts{ .flat = if (flash) @as(?cart.Pixel, .from_color(.rgb(0xFCFBF9))) else null };
    if (index == world.player) {
        const frame: u32 = if (m.hop > 0) 3 else if (m.steer < 0) 1 else if (m.steer > 0) 2 else 0;
        blit_scaled(gfx.anteater, 40, 24, frame, p.sx, p.sy - lift_px, p.scale, &anteater_pal, opts);
    } else {
        // Yaw view from the heading relative to the camera.
        const d = fixed.turn_diff(camera.cam.yaw, m.heading);
        const ad = @abs(d);
        const frame: u32 = if (ad < 5000) 0 else if (ad < 20000) (if (d < 0) 1 else 2) else (if (d < 0) 3 else 4);
        blit_scaled(gfx.machine, 32, 16, frame, p.sx, p.sy - lift_px, p.scale, &machine_pal, opts);
    }
}

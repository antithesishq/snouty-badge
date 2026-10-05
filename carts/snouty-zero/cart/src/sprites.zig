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
pub const fx_pal = sheet_palette(gfx.fx);

/// The machine sheet's four body shades (ASSETS.md), dark to light, as
/// convert_gfx quantises them (floor(31 * v / 255), not DisplayColor.rgb).
const body_rgb = [4]u32{ 0x3C3C50, 0x6A6A8C, 0x9A9AC0, 0xD0D0F0 };

fn quantise(rgb: u32) cart.DisplayColor {
    const r = (rgb >> 16) & 255;
    const g = (rgb >> 8) & 255;
    const b = rgb & 255;
    return .{ .r = @intCast(r * 31 / 255), .g = @intCast(g * 63 / 255), .b = @intCast(b * 31 / 255) };
}

/// Rival and traffic liveries (SPEC 3): ARGMAX, DROPOUT, BACKPROP, OVERFIT,
/// batch traffic. Each is a base colour; the four shades are 35%, 60%,
/// 85% and 100% of it. Also the minimap dot colours.
pub const livery_rgb = [5]u32{ 0xE8483C, 0xF0C030, 0x40D070, 0xD050E0, 0x8C8C94 };

fn shade(rgb: u32, pct: u32) cart.DisplayColor {
    const r = ((rgb >> 16) & 255) * pct / 100;
    const g = ((rgb >> 8) & 255) * pct / 100;
    const b = (rgb & 255) * pct / 100;
    return .rgb((r << 16) | (g << 8) | b);
}

/// Machine palettes per livery, built by `init` (the sheet's index order
/// is whatever convert_gfx saw first, so match by colour value).
var livery_pals: [5]Palette = undefined;

pub fn init() void {
    const shades = [4]u32{ 35, 60, 85, 100 };
    for (&livery_pals, livery_rgb) |*pal, base| {
        pal.* = machine_pal;
        for (gfx.machine.colors, 0..) |c, i| {
            for (body_rgb, 0..) |body, k| {
                const q = quantise(body);
                if (c.r == q.r and c.g == q.g and c.b == q.b) pal[i] = .from_color(shade(base, shades[k]));
            }
        }
    }
}

/// Livery of machine `index`: rivals 1..4 -> 0..3, traffic -> 4.
pub fn livery_of(index: usize) usize {
    return if (index >= 1 and index <= 4) index - 1 else 4;
}

/// Hop arc height in world px at the top.
const hop_height: i32 = 20;

const Entry = struct { index: u8, p: camera.Projected };

/// Effects (SPEC 6.3): spark bursts where a machine hit a rail or another
/// machine, exhaust flames behind boosting machines. Draw-only meta-state:
/// sparks live in screen-independent world coordinates for 16 ticks.
const Spark = struct { x: i32 = 0, y: i32 = 0, age: u8 = 255 };
var sparks: [8]Spark = undefined;
var next_spark: usize = 0;
var prev_shake: [world.machine_count]u8 = @splat(0);

/// Once per live frame: spawn sparks for machines whose shake just started.
pub fn tick_effects() void {
    for (world.w.machines[0..world.w.active_count], 0..) |*m, i| {
        if (m.shake > 0 and prev_shake[i] == 0) spawn_spark(m.x, m.y);
        prev_shake[i] = m.shake;
        // A wreck (SPEC 5.5) throws a spark every 2 ticks, scattered by the countdown.
        if (m.f.active and m.f.ko and m.hitstop % 2 == 0) {
            const k: i32 = m.hitstop;
            spawn_spark(m.x + (((k * 5) & 15) - 8) * fixed.one, m.y + (((k * 3) & 15) - 8) * fixed.one);
        }
    }
    for (&sparks) |*sp| {
        if (sp.age < 16) sp.age += 1;
    }
}

fn spawn_spark(x: i32, y: i32) void {
    sparks[next_spark] = .{ .x = x, .y = y, .age = 0 };
    next_spark = (next_spark + 1) % sparks.len;
}

pub fn reset_effects() void {
    sparks = @splat(.{});
    prev_shake = @splat(0);
}

fn draw_sparks() void {
    for (sparks) |sp| {
        if (sp.age >= 16) continue;
        const p = camera.project(sp.x, sp.y) orelse continue;
        if (p.sy < tuning.horizon_y + 2) continue;
        const lift_px: i32 = @intCast((@as(u32, 6) * p.scale) >> 8);
        blit_scaled(gfx.fx, 16, 16, sp.age / 4, p.sx, p.sy - lift_px + 8, p.scale, &fx_pal, .{});
    }
}

/// Every active machine, back to front. The player's lean frame follows
/// its steering; hopping machines rise on a sine arc over their shadow.
pub fn draw_machines() void {
    var list: [world.machine_count]Entry = undefined;
    var n: usize = 0;
    for (world.w.machines[0..world.w.active_count], 0..) |*m, i| {
        if (!m.f.active) continue;
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
    draw_sparks();
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
    // Exhaust flame behind a boosting machine, under the body.
    if (m.boost > 0) {
        const fl: u32 = if ((m.boost / 3) % 2 == 0) 4 else 5;
        blit_scaled(gfx.fx, 16, 16, fl, p.sx, p.sy - lift_px + 6, p.scale, &fx_pal, .{});
    }
    // A wreck flickers: hidden every other 2 ticks, white the rest.
    if (m.f.ko and (m.hitstop / 2) % 2 == 0) return;
    const flash = (m.immune > 0 and (m.immune / 2) % 2 == 0 and m.crash == .none) or m.f.ko;
    const opts = BlitOpts{ .flat = if (flash) @as(?cart.Pixel, .from_color(.rgb(0xFCFBF9))) else null };
    // A human's machine is its machine select pick (M5; two in a link race).
    const slot = world.w.slot_of(index);
    const pick: usize = if (slot) |s| world.w.picks[s] else 0;
    if (slot != null and pick == 0) {
        // The Anteater has only the rear views (lean and hop).
        const frame: u32 = if (m.hop > 0) 3 else if (m.steer < 0) 1 else if (m.steer > 0) 2 else 0;
        blit_scaled(gfx.anteater, 40, 24, frame, p.sx, p.sy - lift_px, p.scale, &anteater_pal, opts);
    } else {
        var frame: u32 = undefined;
        if (index == world.view) {
            // A rival's machine from the machine select: its livery,
            // leaning into the steer with the rear-quarter views.
            frame = if (m.steer < 0) 1 else if (m.steer > 0) 2 else 0;
        } else {
            // Yaw view from the heading relative to the camera.
            const d = fixed.turn_diff(camera.cam.yaw, m.heading);
            const ad = @abs(d);
            frame = if (ad < 5000) 0 else if (ad < 20000) (if (d < 0) 1 else 2) else (if (d < 0) 3 else 4);
        }
        // A human's pick in its livery (the other human's too).
        const livery = if (slot != null) livery_of(pick) else livery_of(index);
        blit_scaled(gfx.machine, 32, 16, frame, p.sx, p.sy - lift_px, p.scale, &livery_pals[livery], opts);
    }
}

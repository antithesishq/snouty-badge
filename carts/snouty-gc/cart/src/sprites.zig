//! Forked from snouty-zero/cart/src/sprites.zig at f8f6962.
//! Sprites (SPEC 10): the 4-bit sheets of the `gfx` module behind one
//! runtime `Sheet` descriptor, a nearest-neighbour blit with separate
//! width and height (so flat decals lie on the floor: height x squash),
//! and the race's one depth list of up to `draw_cap` objects: the six
//! cars, the projectiles, the drops (FIREWALL as a row of flaming
//! segments) and the effect particles of fx.zig, far first, the farthest
//! culled when there are more. Draw only: reads the World, the camera and
//! fx's render-side state, never writes the World.
const cart = @import("cart-api");
const gfx = @import("gfx");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const camera = @import("camera.zig");
const render = @import("render.zig");
const fx = @import("fx.zig");
const sim = @import("sim.zig");

pub const Palette = [16]cart.Pixel;

/// Palette of `sheet` converted to framebuffer pixels at comptime (<= 16 colours).
pub fn sheet_palette(comptime s: type) Palette {
    var out: Palette = undefined;
    for (&out) |*p| p.* = .from_color(.{ .r = 0, .g = 0, .b = 0 });
    for (s.colors, 0..) |c, i| out[i] = .from_color(c);
    return out;
}

fn PaletteOf(comptime s: type) type {
    return struct {
        const pal: Palette = sheet_palette(s);
    };
}

/// A horizontal strip of equal cells at 4 bits per pixel (convert_gfx packs
/// pixel 2k in the low nibble of byte k), so one blit serves every sheet
/// and a racer's sheets can be picked at run time.
pub const Sheet = struct {
    bytes: [*]const u8,
    /// Width of the whole strip, px.
    width: u32,
    cell_w: u16,
    cell_h: u16,
    pal: *const Palette,
    /// Index 0 is a colour, not the key (the opaque portraits).
    solid: bool = false,
};

fn sheet(comptime s: type, comptime cell_w: u16, comptime cell_h: u16) Sheet {
    return .{ .bytes = s.indices.bytes.ptr, .width = s.width, .cell_w = cell_w, .cell_h = cell_h, .pal = &PaletteOf(s).pal };
}

fn portrait_sheet(comptime s: type) Sheet {
    var out = sheet(s, 48, 48);
    out.solid = true;
    return out;
}

/// The art track's sheets (ASSETS.md), per racer in SPEC 4.1 order.
pub const portraits = [6]Sheet{
    portrait_sheet(gfx.portrait_snouty),   portrait_sheet(gfx.portrait_legacy),
    portrait_sheet(gfx.portrait_kiddie),   portrait_sheet(gfx.portrait_sysadmin),
    portrait_sheet(gfx.portrait_rootkit),  portrait_sheet(gfx.portrait_botnet),
};
pub const cars = [6]Sheet{
    sheet(gfx.car_snouty, 32, 16),  sheet(gfx.car_legacy, 32, 16),  sheet(gfx.car_kiddie, 32, 16),
    sheet(gfx.car_sysadmin, 32, 16), sheet(gfx.car_rootkit, 32, 16), sheet(gfx.car_botnet, 32, 16),
};
pub const weapons = sheet(gfx.weapons, 8, 8);
pub const decals = sheet(gfx.decals, 16, 8);
pub const pickups = sheet(gfx.pickups, 16, 16);
pub const effects = sheet(gfx.fx, 24, 24);
pub const icons = sheet(gfx.hud, 12, 12);
/// Zero's engine sheets: the car shadow and the BURST flame (ASSETS_ENGINE.md).
pub const shadow = sheet(gfx.shadow, 32, 6);
pub const exhaust = sheet(gfx.exhaust, 16, 16);

/// Car sheet cells (ASSETS.md).
pub const car_rear = 0;
pub const car_quarter = 1;
pub const car_side = 2;
pub const car_wreck = 3;
pub const car_air = 4;
/// weapons.png cells.
pub const w_ping = 0;
pub const w_broadcast = 1;
pub const w_phish_rear = 2;
pub const w_phish_side = 3;
pub const w_phish_quarter = 4;
pub const w_bomb = 5;
pub const w_bomb_off = 6;
/// decals.png cells.
pub const d_leak = 0;
pub const d_leak_b = 1;
pub const d_rot = 2;
pub const d_firewall = 4;
/// fx.png cells.
pub const f_explosion = 0;
pub const f_smoke = 4;
pub const f_spark = 6;
pub const f_muzzle = 8;
pub const f_flame = 9;
/// hud.png cells.
pub const i_reticle = 0;
pub const i_lock = 1;
pub const i_burst = 3;
pub const i_ammo = 4;
pub const i_ack = 5;
/// pickups.png cells.
pub const p_blank = 16;

pub const Blit = struct {
    /// Skip pixels where screen (x + y) is odd (shadow translucency).
    skip_odd: bool = false,
    /// Draw every opaque pixel in this colour (hit flash, glow, black smoke).
    flat: ?cart.Pixel = null,
    /// Mirror horizontally.
    flip: bool = false,
    /// Rows above this are not drawn.
    clip_top: i32 = 0,
};

/// Source rectangle (sx0, sy0, sw, sh) of `s` scaled into the screen
/// rectangle (x0, y0, dw, dh), nearest neighbour. Clipped to the screen.
pub fn blit_rect(s: *const Sheet, sx0: u32, sy0: u32, sw: u32, sh: u32, x0: i32, y0: i32, dw: i32, dh: i32, o: Blit) void {
    if (dw <= 0 or dh <= 0 or dw > 1024 or dh > 1024) return;
    const col_begin: i32 = @max(0, -x0);
    const col_end: i32 = @min(dw, render.screen_w - x0);
    const row_begin: i32 = @max(0, @max(o.clip_top, 0) - y0);
    const row_end: i32 = @min(dh, render.screen_h - y0);
    if (col_begin >= col_end or row_begin >= row_end) return;
    // Source step per destination pixel, 16.16.
    const step_x: u32 = (sw << 16) / @as(u32, @intCast(dw));
    const step_y: u32 = (sh << 16) / @as(u32, @intCast(dh));
    const bytes = s.bytes;
    const width = s.width;
    const pal = s.pal;
    const keyed = !s.solid;
    var dx = col_begin;
    while (dx < col_end) : (dx += 1) {
        const ux: u32 = @intCast(if (o.flip) dw - 1 - dx else dx);
        const sx: u32 = sx0 + @min((ux * step_x) >> 16, sw - 1);
        const screen_x = x0 + dx;
        const column = &cart.framebuffer[@intCast(screen_x)];
        var acc: u32 = @as(u32, @intCast(row_begin)) * step_y;
        var dy = row_begin;
        while (dy < row_end) : (dy += 1) {
            const sy: u32 = sy0 + @min(acc >> 16, sh - 1);
            acc += step_y;
            const i = sy * width + sx;
            const idx: usize = (bytes[i >> 1] >> @intCast((i & 1) << 2)) & 15;
            if (keyed and idx == 0) continue;
            const screen_y = y0 + dy;
            if (o.skip_odd and ((screen_x + screen_y) & 1) == 1) continue;
            column[@intCast(screen_y)] = if (o.flat) |f| f else pal[idx];
        }
    }
}

/// Cell `cell` at `dw` x `dh` screen px with its top-left at (x, y).
pub fn blit_cell(s: *const Sheet, cell: u32, x: i32, y: i32, dw: i32, dh: i32, o: Blit) void {
    blit_rect(s, cell * s.cell_w, 0, s.cell_w, s.cell_h, x, y, dw, dh, o);
}

/// Cell `cell` 1:1 with its top-left at (x, y).
pub fn blit_at(s: *const Sheet, cell: u32, x: i32, y: i32, o: Blit) void {
    blit_cell(s, cell, x, y, s.cell_w, s.cell_h, o);
}

/// Cell `cell` scaled by `scale`/256, centred on `cx` with its bottom row on `bottom_y`.
pub fn blit(s: *const Sheet, cell: u32, cx: i32, bottom_y: i32, scale: u32, o: Blit) void {
    const dw: i32 = @intCast((@as(u32, s.cell_w) * scale) >> 8);
    const dh: i32 = @intCast((@as(u32, s.cell_h) * scale) >> 8);
    blit_cell(s, cell, cx - @divTrunc(dw, 2), bottom_y - dh, dw, dh, o);
}

/// Cell `cell` scaled to `dw` x `dh`, centred on `cx`, bottom row on `bottom_y`.
pub fn blit_sized(s: *const Sheet, cell: u32, cx: i32, bottom_y: i32, dw: i32, dh: i32, o: Blit) void {
    blit_cell(s, cell, cx - @divTrunc(dw, 2), bottom_y - dh, dw, dh, o);
}

/// A flat decal lying on the floor (SPEC 10): `world_w` world px wide at
/// the projected point, its height the cell's aspect times the squash of
/// the floor at that distance (a floor patch seen from cam_height px up is
/// cam_height / z as tall as it is wide; the top-down cells are drawn 2:1
/// already, so the squash is 2 * cam_height / z, at most 1). Centred on the point.
pub fn blit_decal(s: *const Sheet, cell: u32, p: camera.Projected, world_w: i32, o: Blit) void {
    const dw: i32 = @divTrunc(world_w * tuning.focal, @max(p.zf, 1));
    const squash_q8: i32 = @min(256, @divTrunc(2 * tuning.cam_height * 256, @max(p.zf, 1)));
    const dh: i32 = @max(1, (@divTrunc(dw * @as(i32, s.cell_h), @as(i32, s.cell_w)) * squash_q8) >> 8);
    blit_cell(s, cell, p.sx - @divTrunc(dw, 2), p.sy - @divTrunc(dh, 2), dw, dh, o);
}

/// Screen px of `world_px` world px of height at a projected point.
pub fn lift_px(world_px: i32, p: camera.Projected) i32 {
    return @divTrunc(world_px * tuning.focal, @max(p.zf, 1));
}

/// Screen px of `px` sprite px at a scale (sprite px at the car distance).
pub fn scaled(px: i32, scale: u32) i32 {
    return @intCast((@as(i64, px) * scale) >> 8);
}

// --- The race's depth list --------------------------------------------------------

/// SPEC 10: at most this many objects are drawn per frame, the farthest
/// culled first (cars are never culled).
pub const draw_cap = 64;
/// Candidates gathered before the cull (cars, every projectile, drops with
/// FIREWALL segments, particles).
const gather_cap = 192;

const Kind = enum(u8) { car, proj, drop, wall, particle };
const Entry = struct {
    z: i32,
    p: camera.Projected,
    kind: Kind,
    index: u8,
    sub: u8,
};
var list: [gather_cap]Entry = undefined;
/// Sort keys: distance << 8 | list index (distance is under max_sprite_z,
/// so it fits), sorted instead of the entries themselves.
var keys: [gather_cap]u32 = undefined;
var count: usize = 0;
/// Objects gathered and drawn on the last frame (the stress bench reads them).
pub var last_gathered: u32 = 0;
pub var last_drawn: u32 = 0;

/// Where each car was drawn this frame, for the HUD's reticle and ACK.
pub const CarScreen = struct { visible: bool = false, sx: i32 = 0, top: i32 = 0, sy: i32 = 0 };
pub var car_screen: [world.car_count]CarScreen = @splat(.{});

/// FIREWALL: segments every `wall_step` world px along its width.
const wall_step: i32 = 16;
/// Ramp arc height in world px at the top.
const hop_height: i32 = 20;
pub const View = struct {
    follow: u8,
    /// Look back (Select held): the followed car is not drawn.
    look_back: bool = false,
    frame: u32 = 0,
};

fn push(kind: Kind, index: usize, sub: usize, p: camera.Projected) void {
    if (count >= gather_cap) return;
    list[count] = .{ .z = p.zf, .p = p, .kind = kind, .index = @intCast(index), .sub = @intCast(sub) };
    keys[count] = (@as(u32, @intCast(@max(p.zf, 0))) << 8) | @as(u32, @intCast(count));
    count += 1;
}

/// A world point in px (Q16 in, wrapping) on the floor in front of the camera.
fn visible(x: i32, y: i32) ?camera.Projected {
    const p = camera.project_cull(x, y) orelse return null;
    if (p.sy < tuning.horizon_y + 2) return null;
    return p;
}

/// Every world object of the race, back to front.
pub fn draw_world(w: *const world.World, v: View) void {
    count = 0;
    car_screen = @splat(.{});
    for (&w.cars, 0..) |*c, i| {
        if (!c.active) continue;
        if (v.look_back and i == v.follow) continue;
        if (c.wreck != .none and !sim.is_hulk(c)) continue;
        const p = visible(c.x, c.y) orelse continue;
        push(.car, i, 0, p);
    }
    for (&w.projs, 0..) |*pr, i| {
        if (pr.kind == .none) continue;
        const p = visible(pr.x, pr.y) orelse continue;
        push(.proj, i, 0, p);
    }
    for (&w.drops, 0..) |*d, i| {
        switch (d.kind) {
            .none => {},
            .firewall => {
                // Across the track: perpendicular to the heading it was laid at.
                const across: fixed.Turn = (@as(fixed.Turn, d.dir) << 8) +% 16384;
                const half: i32 = if (d.size == 0) 32 else d.size;
                const n: i32 = @divTrunc(half, wall_step);
                var k: i32 = -n;
                while (k <= n) : (k += 1) {
                    const off = k * wall_step;
                    const p = visible(d.x +% fixed.cos(across) * off, d.y +% fixed.sin(across) * off) orelse continue;
                    push(.wall, i, @intCast(k + n), p);
                }
            },
            else => {
                const p = visible(d.x, d.y) orelse continue;
                push(.drop, i, 0, p);
            },
        }
    }
    for (&fx.particles, 0..) |*pt, i| {
        if (pt.kind == .none) continue;
        const p = visible(pt.x, pt.y) orelse continue;
        push(.particle, i, 0, p);
    }
    last_gathered = @intCast(count);
    // Insertion sort, far first (the list is mostly in pool order, so small).
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const key = keys[i];
        var j = i;
        while (j > 0 and keys[j - 1] < key) : (j -= 1) keys[j] = keys[j - 1];
        keys[j] = key;
    }
    // The nearest `draw_cap`: the farthest are culled first, but never a
    // car (six at most), so the race itself always shows.
    var cull: usize = if (count > draw_cap) count - draw_cap else 0;
    last_drawn = @intCast(count - cull);
    for (keys[0..count]) |key| {
        const e = &list[key & 0xFF];
        if (cull > 0 and e.kind != .car) {
            cull -= 1;
            continue;
        }
        switch (e.kind) {
            .car => draw_car(&w.cars[e.index], e.index, e.index == v.follow, e.p, v.frame),
            .proj => draw_proj(&w.projs[e.index], e.p),
            .drop => draw_drop(&w.drops[e.index], e.p, v.frame),
            .wall => draw_wall(e.p, e.sub, v.frame),
            .particle => fx.draw_particle(e.index, e.p),
        }
    }
}

/// Car body lift over its shadow, world px: ride height plus the ramp arc.
fn car_lift(c: *const world.Car) i32 {
    var lift: i32 = tuning.ride_height;
    if (c.hop > 0) {
        const elapsed: i32 = @as(i32, tuning.ramp_ticks) - @as(i32, c.hop);
        const a: fixed.Turn = @intCast(@divTrunc(elapsed * 32768, tuning.ramp_ticks));
        lift += (fixed.sin(a) * hop_height) >> fixed.Q;
    }
    return lift;
}

/// The view of a thing heading `heading` seen from the camera: rear,
/// quarter or side, mirrored when the nose points to screen left. Positive
/// turn_diff(cam yaw, heading) is a nose to screen right (right = yaw + 90).
const ViewCell = struct { cell: u8, flip: bool };
fn view_of(heading: fixed.Turn, rear: u8, quarter: u8, side: u8) ViewCell {
    const d = fixed.turn_diff(camera.cam.yaw, heading);
    const ad = @abs(d);
    // 22.5 and 67.5 degrees. There is no front view: past 67.5 the side.
    const cell = if (ad < 4096) rear else if (ad < 12288) quarter else side;
    return .{ .cell = cell, .flip = d < 0 };
}

const white_px: cart.Pixel = .from_color(.rgb(0xFCFBF9));
const glow_px: cart.Pixel = .from_color(.rgb(0x8EF0FF));
const lance_full_px: cart.Pixel = .from_color(.rgb(0xFFFFFF));

fn draw_car(c: *const world.Car, index: usize, followed: bool, p: camera.Projected, frame: u32) void {
    const sheet_ = &cars[c.racer % cars.len];
    const lift_px_: i32 = scaled(car_lift(c), p.scale);
    const body_bottom = p.sy - lift_px_;
    const body_h = scaled(16, p.scale);
    car_screen[index] = .{ .visible = true, .sx = p.sx, .top = body_bottom - body_h, .sy = p.sy };
    // Shadow on the floor row.
    blit(&shadow, 0, p.sx, p.sy, p.scale, .{ .skip_odd = true });
    if (c.wreck != .none) {
        // The burning hulk: the wreck frame, flames over it (fx.zig adds smoke).
        blit(sheet_, car_wreck, p.sx, p.sy, p.scale, .{});
        const flame: u32 = f_flame + @as(u32, @intFromBool((frame / 6) % 2 == 1));
        blit(&effects, flame, p.sx, p.sy - scaled(2, p.scale), p.scale * 3 / 4, .{});
        return;
    }
    // Respawn immunity: blink (two frames on, two off).
    if (c.immune > 0 and (c.immune / 2) % 2 == 1) return;
    // Exhaust flame behind a BURST, under the body (Zero's cyan flame).
    if (c.burst > 0) {
        const fl: u32 = if ((c.burst / 3) % 2 == 0) 4 else 5;
        blit(&exhaust, fl, p.sx, body_bottom + scaled(6, p.scale), p.scale, .{});
    }
    var vc: ViewCell = undefined;
    if (c.hop > 0) {
        vc = .{ .cell = car_air, .flip = false };
    } else {
        vc = view_of(c.heading, car_rear, car_quarter, car_side);
        // The followed car is seen from behind: lean into the steer with the
        // rear-quarter view (Zero's lean frames).
        if (followed and vc.cell == car_rear and c.steer != 0) vc = .{ .cell = car_quarter, .flip = c.steer < 0 };
    }
    var o = Blit{ .flip = vc.flip };
    if (c.hit_flash > 0 and (c.hit_flash / 2) % 2 == 0) {
        o.flat = white_px;
    } else if (c.charge > 0) {
        // FIBER LANCE charging: the car glows, faster as it fills, steady white when full.
        const period: u32 = if (c.charge >= 30) 2 else if (c.charge >= 15) 4 else 8;
        if ((frame / period) % 2 == 0) o.flat = if (c.charge >= 30) lance_full_px else glow_px;
    }
    blit(sheet_, vc.cell, p.sx, body_bottom, p.scale, o);
}

/// Projectiles fly at muzzle height.
const shot_lift: i32 = 5;

fn draw_proj(pr: *const world.Projectile, p: camera.Projected) void {
    const bottom = p.sy - lift_px(shot_lift, p);
    switch (pr.kind) {
        .none => {},
        .ping => blit(&weapons, w_ping, p.sx, bottom, p.scale, .{}),
        .broadcast => blit(&weapons, w_broadcast, p.sx, bottom, p.scale, .{}),
        .phish => {
            // Heading from the velocity; the art faces right, rear, up-right.
            const h = fixed.atan2(pr.vy, pr.vx);
            const vc = view_of(h, w_phish_rear, w_phish_quarter, w_phish_side);
            blit(&weapons, vc.cell, p.sx, bottom, p.scale * 3 / 2, .{ .flip = vc.flip });
        },
    }
}

/// LOGIC BOMB arming (SPEC 6.2): dark until armed, then it blinks.
const bomb_arm_ticks: u16 = 30;

fn draw_drop(d: *const world.Drop, p: camera.Projected, frame: u32) void {
    switch (d.kind) {
        .none, .firewall => {},
        .leak => {
            const r: i32 = if (d.size == 0) 6 else d.size;
            const cell: u32 = if ((frame / 12) % 2 == 0) d_leak else d_leak_b;
            blit_decal(&decals, cell, p, 2 * r + 4, .{ .clip_top = tuning.horizon_y + 1 });
        },
        .caltrop => blit_decal(&decals, d_rot, p, 10, .{ .clip_top = tuning.horizon_y + 1 }),
        .bomb => {
            const lit = d.age >= bomb_arm_ticks and (frame / 8) % 2 == 0;
            blit(&weapons, if (lit) w_bomb else w_bomb_off, p.sx, p.sy + 1, p.scale, .{});
        },
    }
}

/// One FIREWALL segment: bricks on the floor, a flame tongue standing on them.
fn draw_wall(p: camera.Projected, sub: u8, frame: u32) void {
    blit_decal(&decals, d_firewall, p, wall_step + 2, .{ .clip_top = tuning.horizon_y + 1 });
    const flame: u32 = f_flame + ((frame / 5 + sub) % 2);
    // The flame's foot is on row 22 of its 24-row cell.
    blit(&effects, flame, p.sx, p.sy + scaled(2, p.scale), p.scale, .{});
}

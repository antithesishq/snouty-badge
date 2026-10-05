//! Forked from snouty-zero/cart/src/sprites.zig at f8f6962.
//! Sprites (SPEC 10): the 4-bit sheets of the `gfx` module behind one
//! runtime `Sheet` descriptor, a nearest-neighbour blit with separate
//! width and height (so flat decals lie on the floor: height x squash),
//! and the race's one depth list of up to `draw_cap` objects: the six
//! cars, the projectiles, the drops (FIREWALL as a row of flaming
//! segments), the M2 pickup objects (RMA crates, DDOS drones, RUBBER
//! DUCKs) and the effect particles of fx.zig, far first, the farthest
//! culled when there are more; before it, the floor lines (DEADLOCK
//! chains, duck tethers, SPAGHETTI strands). Car states (M2): HEISENBUG
//! flicker, SUDO's gold flash, the KERNEL PANIC blue, RACE CONDITION
//! tearing, the PREFETCH flame, the HONEYPOT spin. Draw only: reads the
//! World, the camera and fx's render-side state, never writes the World.
const cart = @import("cart-api");
const gfx = @import("gfx");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const world = @import("world.zig");
const camera = @import("camera.zig");
const render = @import("render.zig");
const fx = @import("fx.zig");
const sim = @import("sim.zig");
const track = @import("track.zig");
const pickup_sim = @import("pickups.zig");

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
        const blue: Palette = tinted(s, .blue);
        const gold: Palette = tinted(s, .gold);
    };
}

/// Recoloured car palettes (M2): KERNEL PANIC's blue, SUDO's gold.
pub const Tint = enum { blue, gold };

/// `s`'s palette mapped through its luma onto a ramp (16 entries, comptime).
fn tinted(comptime s: type, comptime t: Tint) Palette {
    var out: Palette = undefined;
    for (&out) |*p| p.* = .from_color(.{ .r = 0, .g = 0, .b = 0 });
    for (s.colors, 0..) |c, i| {
        const r: u32 = @as(u32, c.r) << 3;
        const g: u32 = @as(u32, c.g) << 2;
        const b: u32 = @as(u32, c.b) << 3;
        const l: u32 = (r * 77 + g * 150 + b * 29) >> 8;
        const rgb: u32 = switch (t) {
            .blue => ((l / 5) << 16) | ((40 + l * 2 / 5) << 8) | @as(u32, @min(255, 110 + l * 3 / 5)),
            .gold => (@as(u32, @min(255, 110 + l)) << 16) | (@as(u32, @min(255, 70 + l * 3 / 4)) << 8) | (l / 5),
        };
        out[i] = .from_color(.rgb(rgb));
    }
    return out;
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
    /// The KERNEL PANIC and SUDO recolours of `pal`.
    blue: *const Palette,
    gold: *const Palette,
};

fn sheet(comptime s: type, comptime cell_w: u16, comptime cell_h: u16) Sheet {
    const P = PaletteOf(s);
    return .{ .bytes = s.indices.bytes.ptr, .width = s.width, .cell_w = cell_w, .cell_h = cell_h, .pal = &P.pal, .blue = &P.blue, .gold = &P.gold };
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
pub const w_fork = 7;
pub const w_panic = 8;
pub const w_drone = 9;
pub const w_duck = 10;
/// decals.png cells.
pub const d_leak = 0;
pub const d_leak_b = 1;
pub const d_rot = 2;
pub const d_spaghetti = 3;
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
pub const i_panic = 6;
pub const i_sudo = 7;
pub const i_captcha = 8;
pub const i_honey = 9;
/// pickups.png cells: 0..15 the pickups in `world.Pickup` order, then these.
pub const p_blank = 16;
pub const p_crate = 17;
pub const p_honeypot = 18;
pub const p_honeypot_q = 19;

pub const Blit = struct {
    /// Skip pixels where screen (x + y) is odd (shadow translucency).
    skip_odd: bool = false,
    /// Draw every opaque pixel in this colour (hit flash, glow, black smoke).
    flat: ?cart.Pixel = null,
    /// Mirror horizontally.
    flip: bool = false,
    /// Rows above this are not drawn.
    clip_top: i32 = 0,
    /// Draw with this palette instead of the sheet's (the car tints).
    pal: ?*const Palette = null,
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
    const pal = o.pal orelse s.pal;
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
/// FIREWALL segments, crates, drones, ducks, particles). At most 256: the
/// sort key keeps the list index in 8 bits.
const gather_cap = 224;

const Kind = enum(u8) { car, proj, drop, wall, particle, crate, drone, duck };
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
    // M2: the RMA crates that are there, DDOS drones, RUBBER DUCKs.
    for (0..@min(track.crate_n, world.crate_max)) |k| {
        if (w.crates[k] != 0) continue;
        const spot = track.crate_spots[k];
        const p = visible(@as(i32, spot.x) << fixed.Q, @as(i32, spot.y) << fixed.Q) orelse continue;
        push(.crate, k, 0, p);
    }
    for (&w.drones, 0..) |*d, i| {
        if (d.state == .none) continue;
        const p = visible(d.x, d.y) orelse continue;
        push(.drone, i, 0, p);
    }
    for (&w.cars, 0..) |*c, i| {
        if (c.duck == 0 or !c.active or c.wreck != .none) continue;
        const dp = pickup_sim.duck_pos(c);
        const p = visible(dp.x, dp.y) orelse continue;
        push(.duck, i, 0, p);
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
            .proj => draw_proj(&w.projs[e.index], e.p, v.frame),
            .drop => draw_drop(&w.drops[e.index], e.p, v.frame),
            .wall => draw_wall(e.p, e.sub, v.frame),
            .particle => fx.draw_particle(e.index, e.p),
            .crate => draw_crate(e.index, e.p, v.frame),
            .drone => draw_drone(e.index, e.p, v.frame),
            .duck => draw_duck(&w.cars[e.index], e.p, v.frame),
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
const fork_flash_px: cart.Pixel = .from_color(.rgb(0xFF6A3C));
const glow_px: cart.Pixel = .from_color(.rgb(0x8EF0FF));
const lance_full_px: cart.Pixel = .from_color(.rgb(0xFFFFFF));

/// HONEYPOT spin: the view steps round the car every `spin_step` frames
/// (rear, quarter, side, the other side, its quarter; there is no front).
const spin_step: u32 = 3;
const spin_views = [6]ViewCell{
    .{ .cell = car_rear, .flip = false },   .{ .cell = car_quarter, .flip = false },
    .{ .cell = car_side, .flip = false },   .{ .cell = car_side, .flip = true },
    .{ .cell = car_quarter, .flip = true }, .{ .cell = car_rear, .flip = true },
};
/// RACE CONDITION tearing: the sprite in `tear_slices` bands, each shifted
/// by one of these screen px (scaled), the pattern stepping every 2 frames.
const tear_slices = 4;
const tear_shift = [8]i32{ 3, -2, 0, -4, 2, 4, -3, 1 };
const tear_px: cart.Pixel = .from_color(.rgb(0xFF40C0));

fn draw_car(c: *const world.Car, index: usize, followed: bool, p: camera.Projected, frame: u32) void {
    // HEISENBUG (SPEC 6.3): unobservable, drawn on odd frames only.
    if (c.heisen > 0 and c.wreck == .none and frame & 1 == 0) return;
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
    // Exhaust flame behind a BURST, under the body (Zero's cyan flame);
    // PREFETCH burns twin flames, bigger.
    if (c.prefetch > 0) {
        const fl: u32 = if ((frame / 2) % 2 == 0) 4 else 5;
        const off = scaled(7, p.scale);
        blit(&exhaust, fl, p.sx - off, body_bottom + scaled(8, p.scale), p.scale * 5 / 4, .{});
        blit(&exhaust, 9 - fl, p.sx + off, body_bottom + scaled(8, p.scale), p.scale * 5 / 4, .{});
    } else if (c.burst > 0) {
        const fl: u32 = if ((c.burst / 3) % 2 == 0) 4 else 5;
        blit(&exhaust, fl, p.sx, body_bottom + scaled(6, p.scale), p.scale, .{});
    }
    var vc: ViewCell = undefined;
    if (c.hop > 0) {
        vc = .{ .cell = car_air, .flip = false };
    } else if (c.spin > 0) {
        vc = spin_views[(frame / spin_step + index) % spin_views.len];
    } else {
        vc = view_of(c.heading, car_rear, car_quarter, car_side);
        // The followed car is seen from behind: lean into the steer with the
        // rear-quarter view (Zero's lean frames).
        if (followed and vc.cell == car_rear and c.steer != 0) vc = .{ .cell = car_quarter, .flip = c.steer < 0 };
    }
    var o = Blit{ .flip = vc.flip };
    if (c.hit_flash > 0 and (c.hit_flash / 2) % 2 == 0) {
        o.flat = white_px;
    } else if (c.frozen > 0 and c.frozen_by == .panic) {
        // KERNEL PANIC: frozen blue (the `:(` tag is the HUD's).
        o.pal = sheet_.blue;
    } else if (c.sudo > 0) {
        // SUDO: root flashes gold (the `#` tag is the HUD's).
        if ((frame / 4) % 2 == 0) o.pal = sheet_.gold;
    } else if (c.charge > 0) {
        // FIBER LANCE charging: the car glows, faster as it fills, steady white when full.
        const period: u32 = if (c.charge >= 30) 2 else if (c.charge >= 15) 4 else 8;
        if ((frame / period) % 2 == 0) o.flat = if (c.charge >= 30) lance_full_px else glow_px;
    }
    if (c.swap_ticks > 0) return draw_torn(sheet_, vc.cell, p.sx, body_bottom, p.scale, o, frame +% @as(u32, @intCast(index)) * 3);
    blit(sheet_, vc.cell, p.sx, body_bottom, p.scale, o);
}

/// RACE CONDITION (SPEC 6.3): the sprite torn into shifted bands, one band
/// flat magenta on alternate frames.
fn draw_torn(s: *const Sheet, cell: u32, cx: i32, bottom_y: i32, scale: u32, o: Blit, frame: u32) void {
    const dw: i32 = @intCast((@as(u32, s.cell_w) * scale) >> 8);
    const dh: i32 = @intCast((@as(u32, s.cell_h) * scale) >> 8);
    const x0 = cx - @divTrunc(dw, 2);
    const y0 = bottom_y - dh;
    const band_h: u32 = s.cell_h / tear_slices;
    var k: u32 = 0;
    while (k < tear_slices) : (k += 1) {
        const ya = y0 + @divTrunc(dh * @as(i32, @intCast(k)), tear_slices);
        const yb = y0 + @divTrunc(dh * @as(i32, @intCast(k + 1)), tear_slices);
        const shift = scaled(tear_shift[(frame / 2 + k * 3) % tear_shift.len], scale);
        var ob = o;
        if ((frame / 2 + k) % 4 == 0) ob.flat = tear_px;
        blit_rect(s, cell * s.cell_w, k * band_h, s.cell_w, band_h, x0 + shift, ya, dw, yb - ya, ob);
    }
}

/// Projectiles fly at muzzle height.
const shot_lift: i32 = 5;

fn draw_proj(pr: *const world.Projectile, p: camera.Projected, frame: u32) void {
    const bottom = p.sy - lift_px(shot_lift, p);
    switch (pr.kind) {
        // The KERNEL PANIC packet: a blue `:(` packet at twice a shot's size,
        // bobbing (fx.zig trails ghosts behind it).
        .panic => blit(&weapons, w_panic, p.sx, bottom - @as(i32, @intCast((frame / 4) % 2)), p.scale * 2, .{}),
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
        .fork => {
            // One `&`; it swells and flashes in the last 12 ticks before it
            // forks (every 60, SPEC 6.3), so the split reads.
            const phase = d.age % fork_every;
            const swell = phase >= fork_every - 12;
            const sc: u32 = if (swell) p.scale * 2 + p.scale * (phase - (fork_every - 12)) / 16 else p.scale * 2;
            const flash = swell and (frame / 2) % 2 == 0;
            blit(&weapons, w_fork, p.sx, p.sy + 1, sc, .{ .flat = if (flash) fork_flash_px else null });
        },
        // The fake RMA crate: the `?` frame on odd frames (ASSETS.md 18/19).
        .honeypot => blit(&pickups, if (frame & 1 == 1) p_honeypot_q else p_honeypot, p.sx, p.sy + 1, p.scale, .{}),
        .spaghetti => blit_decal(&decals, d_spaghetti, p, 26, .{ .clip_top = tuning.horizon_y + 1 }),
    }
}

/// FORK BOMB fork period, ticks (the sim's tuning.fork_every).
const fork_every: u16 = 60;

/// An RMA crate (SPEC 6.3): standing on the floor, bobbing a pixel.
fn draw_crate(k: usize, p: camera.Projected, frame: u32) void {
    const bob: i32 = @intFromBool((frame / 16 + k) % 2 == 0);
    blit(&pickups, p_crate, p.sx, p.sy + 1 - bob, p.scale, .{});
}

/// A DDOS drone: the 4x4 red quad at 2x, hovering and buzzing.
fn draw_drone(i: usize, p: camera.Projected, frame: u32) void {
    const buzz: i32 = @intCast((frame + i * 3) % 3);
    blit(&weapons, w_drone, p.sx + buzz - 1, p.sy - lift_px(9, p) + @as(i32, @intFromBool(buzz == 1)), p.scale * 2, .{});
}

/// A RUBBER DUCK on its tether behind its car: the side view, facing the
/// way the car drives, bobbing.
fn draw_duck(c: *const world.Car, p: camera.Projected, frame: u32) void {
    const d = fixed.turn_diff(camera.cam.yaw, c.heading);
    const bob: i32 = @intFromBool((frame / 10) % 2 == 0);
    blit(&weapons, w_duck, p.sx, p.sy + 1 - bob, p.scale * 3 / 2, .{ .flip = d < 0 });
}

// --- Floor lines (drawn after the floor, before the depth list) ------------------

const chain_light: cart.Pixel = .from_color(.rgb(0xC8C8D0));
const chain_dark: cart.Pixel = .from_color(.rgb(0x505060));
const tether_px: cart.Pixel = .from_color(.rgb(0xE8E0C0));
const strand_a: cart.Pixel = .from_color(.rgb(0xF0D040));
const strand_b: cart.Pixel = .from_color(.rgb(0x9A7A20));

/// Chains, tethers and strands lie under the cars: the depth list draws
/// the cars over their ends. Lifted `lift` world px, through `steps`
/// projected points; `wave` sways the line sideways (a strand), `links`
/// alternates two colours every few px (a chain).
const LineStyle = struct { a: cart.Pixel, b: cart.Pixel, lift: i32, steps: i32, wave: i32 = 0, links: bool = false, thick: bool = false };

pub fn draw_floor_lines(w: *const world.World, frame: u32) void {
    for (&w.cars, 0..) |*c, i| {
        if (!c.active or c.wreck != .none) continue;
        // DEADLOCK: one chain per pair (the lower index draws it), or to the wall.
        if (c.chain_ticks > 0 and (c.chain == world.no_car or c.chain > i)) {
            const a = pickup_sim.chain_anchor(w, i);
            world_line(c.x, c.y, a.x, a.y, .{ .a = chain_light, .b = chain_dark, .lift = 4, .steps = 8, .links = true, .thick = true }, frame);
        }
        // RUBBER DUCK: its tether from the tail.
        if (c.duck > 0) {
            const dp = pickup_sim.duck_pos(c);
            world_line(c.x, c.y, dp.x, dp.y, .{ .a = tether_px, .b = tether_px, .lift = 3, .steps = 3 }, frame);
        }
        // SPAGHETTI: a cable strand trailing 40 px behind, swaying.
        if (c.strand > 0 or c.tangle > 0) {
            const bx = c.x -% fixed.cos(c.heading) * 40;
            const by = c.y -% fixed.sin(c.heading) * 40;
            world_line(c.x, c.y, bx, by, .{ .a = strand_a, .b = strand_b, .lift = 1, .steps = 6, .wave = 5, .thick = true }, frame +% @as(u32, @intCast(i)) * 7);
        }
    }
}

/// A line between two world points (Q16) through projected points.
fn world_line(x0: i32, y0: i32, x1: i32, y1: i32, st: LineStyle, frame: u32) void {
    var dx = (x1 -% x0) & ((1024 << fixed.Q) - 1);
    var dy = (y1 -% y0) & ((1024 << fixed.Q) - 1);
    if (dx >= 512 << fixed.Q) dx -= 1024 << fixed.Q;
    if (dy >= 512 << fixed.Q) dy -= 1024 << fixed.Q;
    // The unit normal for the sway, roughly: (-dy, dx) / length.
    const len: i32 = @max(1, (@as(i32, @intCast(@abs(dx))) + @as(i32, @intCast(@abs(dy)))) >> fixed.Q);
    var have_prev = false;
    var px0: i32 = 0;
    var py0: i32 = 0;
    var k: i32 = 0;
    while (k <= st.steps) : (k += 1) {
        var x = x0 +% @divTrunc(dx, st.steps) * k;
        var y = y0 +% @divTrunc(dy, st.steps) * k;
        if (st.wave != 0 and k > 0) {
            const a: fixed.Turn = @truncate(@as(u32, @intCast(k)) *% 21000 +% frame *% 1500);
            const sway = (fixed.sin(a) * st.wave) >> fixed.Q;
            x +%= @divTrunc(-dy, len) * sway;
            y +%= @divTrunc(dx, len) * sway;
        }
        const p = camera.project(x, y) orelse {
            have_prev = false;
            continue;
        };
        if (p.sy <= tuning.horizon_y) {
            have_prev = false;
            continue;
        }
        const sy = p.sy - lift_px(st.lift, p);
        if (have_prev) {
            if (st.thick) fx.line(px0, py0 + 1, p.sx, sy + 1, st.b, false);
            fx.line(px0, py0, p.sx, sy, st.a, st.links);
        }
        px0 = p.sx;
        py0 = sy;
        have_prev = true;
    }
}

/// One FIREWALL segment: bricks on the floor, a flame tongue standing on them.
fn draw_wall(p: camera.Projected, sub: u8, frame: u32) void {
    blit_decal(&decals, d_firewall, p, wall_step + 2, .{ .clip_top = tuning.horizon_y + 1 });
    const flame: u32 = f_flame + ((frame / 5 + sub) % 2);
    // The flame's foot is on row 22 of its 24-row cell.
    blit(&effects, flame, p.sx, p.sy + scaled(2, p.scale), p.scale, .{});
}

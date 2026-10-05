//! Billboard sprites: enemies, pickups, projectiles (SPEC.md section 5,
//! PLAN.md M2 "Contract: sprites (track A)"). Drawn after the wall pass,
//! back to front, clipped per column against `view.depth`.
//!
//! Anchors (screen y, z = perpendicular distance, horizon at 52):
//! enemies size 1.0 bottom on the floor line 52 + 52/z (floor to ceiling,
//! like a wall); spider size 1.0 top on the ceiling line 52 - 52/z (same
//! span as the others at size 1.0, but it stays anchored to the ceiling if
//! its size ever changes); boss 1.5 bottom-anchored (the top clips above
//! the ceiling line); pickups 0.5 bottom-anchored; projectiles 0.25
//! centred on the horizon (the Debugger burst 0.6 -> 1.0, also centred). Screen height and width are both 104 * size / z,
//! so the art keeps its square texels.
//!
//! Deathmatch (M9): weapon pads, fork bombs, rockets and explosions from
//! `dm` (fx.zig rect art and discs), and the rivals' blue cyber warp-out /
//! warp-in (`warp_of`, `blit_warp`) instead of the fallen cell 4.
const std = @import("std");
const cart = @import("cart-api");
const gfx = @import("gfx");
const state = @import("../state.zig");
const levels = @import("../levels.zig");
const fixed = @import("../fixed.zig");
const view = @import("view.zig");
const raycast = @import("raycast.zig");
const textures = @import("textures.zig");
const slots = @import("slots.zig");
const match = @import("../match.zig");
const sim = @import("../sim.zig");
const arsenal = @import("../arsenal.zig");
const fx = @import("fx.zig");

/// Sprites that drew at least one column last frame (for `debug_sprites`).
pub var drawn: u32 = 0;

const max_visible = 64;
const view_h: i32 = @intCast(view.view_h);
const view_w: i32 = @intCast(view.view_w);
const horizon: f32 = @as(f32, @floatFromInt(view.view_h)) * 0.5;
const tan_half_fov: f32 = @tan(66.0 * 0.5 * std.math.pi / 180.0);
const near_z: f32 = 0.2;

const white: cart.Pixel = .from_color(.rgb(0xFCFBF9)); // Anti-White

const Anchor = enum(u8) { bottom, top, centre };
/// How an entry draws: a sheet cell, M9 rect art (`fx.Art` in `cell`), an
/// explosion (`cell` = 1 for a rocket's), or a warping rival (phase `t`).
const Kind = enum(u8) { sheet, rects, blast, warp };

const Entry = struct {
    z: f32,
    /// Screen x of the sprite centre (continuous; pixel x covers [x, x+1)).
    sx: f32,
    size: f32,
    sheet: textures.SpriteSheet,
    cell: u8,
    anchor: Anchor,
    white: bool,
    /// Rivals only: `slots.shirts` index (the shirt remap) and the slot
    /// number over the head (1..16, 0 = none).
    shirt: u8 = 0,
    label: u8 = 0,
    kind: Kind = .sheet,
    /// Warp: the phase (`warp_of`); blast: its age in ticks.
    t: f32 = 0,
};

/// Visible sprites this frame, `scratch[0..count]`. Render-only .bss.
var scratch: [max_visible]Entry = undefined;
var count: usize = 0;

// The texel reads below assume PackedIntSlice(u4) little-endian layout:
// element i lives in bytes[i >> 1], low nibble for even i. Verified at run
// time by `blit.nibble_order_ok` (a comptime check here made the compiler
// fail with OutOfMemory on macOS).

inline fn nibble(bytes: []const u8, i: usize) u4 {
    return @truncate(bytes[i >> 1] >> @intCast((i & 1) << 2));
}

/// Screen size of a Debugger burst (`ttl` counts 6 -> 1): 0.6 at 6,
/// 0.73 at 5, 0.87 at 4, 1.0 from 3 down.
fn burst_size(ttl: u8) f32 {
    const grow: f32 = @floatFromInt(@min(@max(ttl, 3), 6) - 3); // 3..0
    return 1.0 - grow * (0.4 / 3.0);
}

/// Spiders (ceiling turrets) are drawn only within this perpendicular distance.
pub const spider_range: f32 = 6.0;

/// Deathmatch (M7): the other player's billboard (`rival.png` cell 0-4,
/// all white for the hit flash), null in the campaign; and whether the
/// bugs are drawn at all (BUGS OFF leaves their slots empty).
/// M8: `shirt` tints it (`slots.shirts`, 0 = the M7 Coral) and `label`
/// floats that number (the slot + 1; 0 = none) over the head when nearer
/// than `label_range`.
/// M9: `warp` = the blue cyber warp phase (`warp_of`), null = standing.
pub const Rival = struct { x: f32, y: f32, cell: u8, white: bool, shirt: u8 = 0, label: u8 = 0, warp: ?f32 = null };
pub var rival: ?Rival = null;
/// Deathmatch (M9): the match whose weapon pads and arsenal shots
/// (`dm_shots`) are drawn; null in the campaign. Set around `view.draw`.
pub var dm: ?*const state.Match = null;

/// The warp-out runs `warp_out_ticks` from the death (phase 0 -> 1: tint,
/// scanline shear and upward stretch, squeeze to a beam by 0.6, the beam
/// rises away by 0.85, rising pixels until `warp_end`, then nothing). The
/// warp-in plays phase 0.7 -> 0 over the first `warp_in_ticks` of the
/// spawn grace (the beam coming down and opening into the player).
pub const warp_out_ticks: f32 = 36;
pub const warp_in_ticks: u8 = 20;
pub const warp_end: f32 = 1.2;

/// Slot `o`'s warp phase from the match countdowns, null when it stands.
pub fn warp_of(m: *const state.Match, o: usize) ?f32 {
    if (m.dead[o] > 0) return @as(f32, @floatFromInt(match.death_ticks -| m.dead[o])) / warp_out_ticks;
    const g = m.players[o].grace;
    if (g + warp_in_ticks > match.spawn_grace) return 0.7 * @as(f32, @floatFromInt(g + warp_in_ticks - match.spawn_grace)) / @as(f32, @floatFromInt(warp_in_ticks));
    return null;
}
pub var show_enemies: bool = true;
/// Party deathmatch (M8): every other player, `rivals[0..rival_count]`
/// (`set_rivals` fills it; `clear_rivals` after the frame, so the
/// campaign never draws one).
pub var rivals: [state.max_players - 1]Rival = undefined;
pub var rival_count: usize = 0;
/// Slot numbers float over heads nearer than this (cells).
pub const label_range: f32 = 6.0;

/// The rivals as `viewer` (slot `me`) sees them: every other present
/// slot, alive or warping (M9, no number then), tinted by `slots.shirt_of`
/// and flashing white for two ticks after a hit, as M7's rival.
pub fn set_rivals(m: *const state.Match, me: usize, viewer: *const state.Player) void {
    rival_count = 0;
    for (0..state.max_players) |o| {
        if (o == me or !m.is_present(o)) continue;
        const r = &m.players[o];
        const warp = warp_of(m, o);
        rivals[rival_count] = .{
            .x = fixed.to_f32(r.x),
            .y = fixed.to_f32(r.y),
            .cell = match.rival_cell(viewer, r, false),
            .white = m.hurt[o] + 2 > sim.hurt_ticks,
            .shirt = slots.shirt_of(m, o),
            .label = if (warp != null) 0 else @intCast(o + 1),
            .warp = warp,
        };
        rival_count += 1;
    }
}

pub fn clear_rivals() void {
    rival_count = 0;
}

pub fn draw(s: *const state.GameState, level: *const levels.Level, px: f32, py: f32, dx: f32, dy: f32) void {
    count = 0;
    drawn = 0;
    const cam: Cam = .{ .px = px, .py = py, .dx = dx, .dy = dy };

    const n_enemies = if (show_enemies) @min(level.enemies.len, state.max_enemies) else 0;
    for (s.enemies[0..n_enemies]) |e| {
        const kind = e.kind;
        if (kind == .spider) {
            // Deadlock is only visible from within 6 cells (SPEC.md section 8).
            const ex = fixed.to_f32(e.x) - px;
            const ey = fixed.to_f32(e.y) - py;
            if (ex * dx + ey * dy > spider_range) continue;
        }
        const sheet: textures.SpriteSheet = @fromBackingInt(@intCast(@backingInt(kind)));
        const size: f32 = if (kind == .boss) 1.5 else 1.0;
        const anchor: Anchor = if (kind == .spider) .top else .bottom;
        cam.add(fixed.to_f32(e.x), fixed.to_f32(e.y), size, sheet, e.frame, anchor, e.flash > 0);
    }

    const n_pickups = @min(level.pickups.len, state.max_pickups);
    for (level.pickups[0..n_pickups], 0..) |p, i| {
        const present = state.pickup_present(s, i);
        const wx = @as(f32, @floatFromInt(p.x)) + 0.5;
        const wy = @as(f32, @floatFromInt(p.y)) + 0.5;
        if (p.kind == .pad) {
            // M9 weapon pad: its base (dim while empty) and what it shows.
            const m = dm orelse continue;
            cam.add_art(wx, wy, 0.5, if (present) .pad_on else .pad_off, .bottom, false);
            if (!present or i >= state.max_match_pickups) continue;
            const item = m.pad_item[i];
            if (item == @backingInt(state.Weapon.spray)) {
                cam.add(wx, wy, 0.5, .pickups, @backingInt(levels.PickupKind.spray_can), .bottom, false);
            } else if (item >= 4) {
                cam.add_art(wx, wy, 0.5, fx.weapon_art(item, s.tick), .bottom, false);
            }
            continue;
        }
        if (!present) continue;
        cam.add(wx, wy, 0.5, .pickups, @backingInt(p.kind), .bottom, false);
    }
    if (dm) |m| add_shots(cam, m);

    const alt: u8 = @intCast((s.tick >> 2) & 1);
    for (s.projectiles) |p| {
        var size: f32 = 0.25;
        const cell: u8 = switch (p.kind) {
            1 => alt,
            2 => 2 + alt,
            3 => 4, // Debugger bolt
            4 => blk: {
                // Debugger burst: grows 0.6 -> 1.0 over its first three
                // ticks (ttl 6, 5, 4), then holds 1.0 until it expires.
                size = burst_size(p.ttl);
                break :blk 5;
            },
            else => continue,
        };
        cam.add(fixed.to_f32(p.x), fixed.to_f32(p.y), size, .projectiles, cell, .centre, false);
    }

    if (rival) |r| cam.add_rival(r);
    for (rivals[0..rival_count]) |r| cam.add_rival(r);

    // Back to front: insertion sort by z, farthest first.
    var i: usize = 1;
    while (i < count) : (i += 1) {
        const e = scratch[i];
        var j = i;
        while (j > 0 and scratch[j - 1].z < e.z) : (j -= 1) scratch[j] = scratch[j - 1];
        scratch[j] = e;
    }

    const pals = &textures.sprite_pal;
    const tint = @backingInt(textures.sprite_tint(view.shade_override));
    for (scratch[0..count]) |*e| {
        switch (e.kind) {
            .sheet => {},
            .rects => {
                const zh: f32 = @as(f32, @floatFromInt(view.view_h)) / e.z;
                const h = zh * e.size;
                const top = if (e.anchor == .bottom) horizon + zh * 0.5 - h else horizon - h * 0.5;
                fx.rects(fx.art(@fromBackingInt(@intCast(e.cell))), e.sx - h * 0.5, top, h / 16.0, e.z, view_h, &fx.pal[if (e.white) 2 else tint], null);
                drawn += 1;
                continue;
            },
            .blast => {
                const rad = @as(f32, @floatFromInt(view.view_h)) * e.size * 0.5 / e.z;
                fx.blast(e.sx, horizon, rad, e.z, @intFromFloat(e.t), arsenal.blast_ticks, e.cell == 1);
                drawn += 1;
                continue;
            },
            .warp => {
                blit_warp(e, &textures.rival_pal[e.shirt][if (e.t < 0.12) tint else 3]);
                drawn += 1;
                continue;
            },
        }
        const pal = if (e.sheet == .rival) &textures.rival_pal[e.shirt][tint] else &pals[@backingInt(e.sheet)][tint];
        const any = switch (e.sheet) {
            .gnat => blit(gfx.bug_gnat, 32, e, pal),
            .wasp => blit(gfx.bug_wasp, 32, e, pal),
            .beetle => blit(gfx.bug_beetle, 32, e, pal),
            .spider => blit(gfx.bug_spider, 32, e, pal),
            .boss => blit(gfx.bug_boss, 32, e, pal),
            .pickups => blit(gfx.pickups, 16, e, pal),
            .projectiles => blit(gfx.projectiles, 8, e, pal),
            .rival => blit(gfx.rival, 32, e, pal),
        };
        if (any) drawn += 1;
        if (any and e.label != 0 and e.z < label_range) draw_label(e, tint);
    }
}

/// The slot number over a rival's head: 3x5 digits in its shirt colour
/// on an Anti-black tag, its bottom 2 px above the head (row 2 of the
/// 32-texel cell), clipped by the same per-column depth test.
fn draw_label(e: *const Entry, tint: u8) void {
    const zh: f32 = @as(f32, @floatFromInt(view.view_h)) / e.z;
    const head = horizon + zh * 0.5 - zh * e.size + zh * e.size * (2.0 / 32.0);
    const w = slots.small_width(e.label) + 2;
    const x = pix_start(e.sx) - @divTrunc(w, 2);
    const y = @max(0, pix_start(head) - 9);
    const fg = textures.rival_pal[e.shirt][tint][textures.rival_shirt_index];
    slots.small_number(e.label, x, y, fg, label_bg, e.z, in_front);
}

const label_bg: cart.Pixel = .from_color(.rgb(0x16031B)); // Anti-black

fn in_front(z: f32, x: usize) bool {
    return x < view.view_w and z < view.depth[x];
}

const Cam = struct {
    px: f32,
    py: f32,
    dx: f32,
    dy: f32,

    /// Camera transform and culling; appends to `scratch`, replacing the
    /// farthest entry when full (and dropping the new one if it is farther).
    fn add(c: Cam, wx: f32, wy: f32, size: f32, sheet: textures.SpriteSheet, cell: u8, anchor: Anchor, is_white: bool) void {
        c.add_entry(wx, wy, .{ .z = 0, .sx = 0, .size = size, .sheet = sheet, .cell = cell, .anchor = anchor, .white = is_white });
    }

    fn add_rival(c: Cam, r: Rival) void {
        var e: Entry = .{ .z = 0, .sx = 0, .size = 1.0, .sheet = .rival, .cell = r.cell, .anchor = .bottom, .white = r.white, .shirt = @min(r.shirt, slots.shirts.len - 1), .label = r.label };
        if (r.warp) |p| {
            if (p >= warp_end) return;
            e.kind = .warp;
            e.t = p;
            e.white = false;
            e.size = 1.7; // culling width; the stretched beam is that tall
        }
        c.add_entry(r.x, r.y, e);
    }

    /// M9 rect art (`fx.Art`); `flash` draws it in the hurt tint.
    fn add_art(c: Cam, wx: f32, wy: f32, size: f32, a: fx.Art, anchor: Anchor, flash: bool) void {
        c.add_entry(wx, wy, .{ .z = 0, .sx = 0, .size = size, .sheet = .pickups, .cell = @backingInt(a), .anchor = anchor, .white = flash, .kind = .rects });
    }

    /// `proto` with its z and sx filled in from the world position.
    fn add_entry(c: Cam, wx: f32, wy: f32, proto: Entry) void {
        const size = proto.size;
        const rx = wx - c.px;
        const ry = wy - c.py;
        const z = rx * c.dx + ry * c.dy;
        if (z < near_z or z > raycast.range) return;
        // M9 rockets and their puffs at point-blank (just fired) would fill
        // the view with a few big squares.
        if (proto.kind == .rects and proto.anchor == .centre and z < 0.7) return;
        // plane = (-dy, dx) * tan(fov/2); screen x = 80 (1 + tx / z)
        const lateral = ry * c.dx - rx * c.dy;
        const half_w: f32 = @as(f32, @floatFromInt(view.view_w)) * 0.5;
        const inv_z = 1.0 / z;
        const sx = half_w * (1.0 + lateral * inv_z * (1.0 / tan_half_fov));
        const w = @as(f32, @floatFromInt(view.view_h)) * size * inv_z;
        if (sx + w * 0.5 <= 0 or sx - w * 0.5 >= half_w * 2) return;
        var e = proto;
        e.z = z;
        e.sx = sx;
        if (count < max_visible) {
            scratch[count] = e;
            count += 1;
            return;
        }
        var far: usize = 0;
        for (scratch[1..], 1..) |f, k| {
            if (f.z > scratch[far].z) far = k;
        }
        if (z < scratch[far].z) scratch[far] = e;
    }
};

/// Scales cell `e.cell` (cw x cw texels) of `sheet` onto the view.
/// Returns whether any column survived the depth test.
fn blit(comptime sheet: type, comptime cw: u32, e: *const Entry, pal: *const [16]cart.Pixel) bool {
    comptime {
        if (sheet.height != cw or sheet.width % cw != 0) @compileError("sprite sheet cell size mismatch");
    }
    const cells: u32 = sheet.width / cw;
    const bytes = sheet.indices.bytes;

    const zh: f32 = @as(f32, @floatFromInt(view.view_h)) / e.z;
    const h = zh * e.size;
    const top: f32 = switch (e.anchor) {
        .bottom => horizon + zh * 0.5 - h,
        .top => horizon - zh * 0.5,
        .centre => horizon - h * 0.5,
    };
    const left = e.sx - h * 0.5;

    // A pixel is covered when its centre is inside, as for wall slices.
    const x0: i32 = @max(0, pix_start(left));
    const x1: i32 = @min(view_w, pix_start(left + h));
    const y0: i32 = @max(0, pix_start(top));
    const y1: i32 = @min(view_h, pix_start(top + h));
    if (x0 >= x1 or y0 >= y1) return false;

    const texels_per_px: f32 = @as(f32, @floatFromInt(cw)) / h;
    const step: u32 = @intFromFloat(texels_per_px * 65536.0);
    const v0f = (@as(f32, @floatFromInt(y0)) + 0.5 - top) * texels_per_px;
    const v0: u32 = @intFromFloat(@max(v0f, 0) * 65536.0);
    const cell_x: u32 = @min(e.cell, cells - 1) * cw;
    const n: usize = @intCast(y1 - y0);
    const ys: usize = @intCast(y0);

    var any = false;
    var x = x0;
    while (x < x1) : (x += 1) {
        const xi: usize = @intCast(x);
        if (e.z >= view.depth[xi]) continue;
        const uf = (@as(f32, @floatFromInt(x)) + 0.5 - left) * texels_per_px;
        const u: u32 = @min(@as(u32, @intFromFloat(@max(uf, 0))), cw - 1);
        any = true;
        const base = cell_x + u;
        const col = cart.framebuffer[xi][ys..][0..n];
        var v = v0;
        if (e.white) {
            for (col) |*p| {
                const row: u32 = @min(v >> 16, cw - 1);
                if (nibble(bytes, row * sheet.width + base) != 0) p.* = white;
                v +%= step;
            }
        } else {
            for (col) |*p| {
                const row: u32 = @min(v >> 16, cw - 1);
                const idx = nibble(bytes, row * sheet.width + base);
                if (idx != 0) p.* = pal[idx];
                v +%= step;
            }
        }
    }
    return any;
}

/// First pixel whose centre is at or after `f`: ceil(f - 0.5), for any sign.
inline fn pix_start(f: f32) i32 {
    const c = @ceil(f - 0.5);
    return @intFromFloat(std.math.clamp(c, -1024.0, 1024.0));
}

/// M9: the match's fork bombs (on the floor, blinking faster as the fuse
/// runs out), rockets (with two exhaust puffs behind them) and explosions.
fn add_shots(cam: Cam, m: *const state.Match) void {
    for (m.dm_shots) |d| {
        const x = fixed.to_f32(d.x);
        const y = fixed.to_f32(d.y);
        switch (d.kind) {
            arsenal.kind_bomb => {
                const per: u8 = if (d.ttl > 60) 16 else if (d.ttl > 30) 8 else if (d.ttl > 12) 4 else 2;
                cam.add_art(x, y, 0.35, .fork_bomb, .bottom, d.ttl % per < per / 2);
            },
            arsenal.kind_rocket => {
                const vx = fixed.to_f32(d.vx);
                const vy = fixed.to_f32(d.vy);
                cam.add_art(x - vx * 4, y - vy * 4, 0.16, .puff_cold, .centre, false);
                cam.add_art(x - vx * 2, y - vy * 2, 0.22, .puff_hot, .centre, false);
                cam.add_art(x, y, 0.3, .rocket, .centre, false);
            },
            arsenal.kind_blast => {
                const rocket = d.aux == 1;
                cam.add_entry(x, y, .{
                    .z = 0,
                    .sx = 0,
                    .size = if (rocket) 1.5 else 1.8,
                    .sheet = .projectiles,
                    .cell = @intFromBool(rocket),
                    .anchor = .centre,
                    .white = false,
                    .kind = .blast,
                    .t = @floatFromInt(arsenal.blast_ticks -| d.ttl),
                });
            },
            else => {},
        }
    }
}

/// A warping rival (M9, `warp_of`): before phase 0.6 its standing cell
/// stretched upward, sliced into scanlines (odd rows dropped) whose
/// two-texel bands shear sideways in turn, squeezed toward a beam from
/// 0.3 and flat cyan from 0.35; then a beam whose foot rises, then a few
/// rising blue pixels.
fn blit_warp(e: *const Entry, pal: *const [16]cart.Pixel) void {
    const p = e.t;
    const z = e.z;
    const zh: f32 = @as(f32, @floatFromInt(view.view_h)) / z;
    const bottom = horizon + zh * 0.5;
    const cyan = fx.px(fx.c_cyan);
    const hi = fx.px(fx.c_white);
    if (p < 0.6) {
        const k = @min(p * 2.0, 1.0);
        const h = zh * (1.0 + 0.7 * k * k);
        const top = bottom - h;
        const squeeze: f32 = if (p < 0.3) 1.0 else @max(1.0 - (p - 0.3) * (1.0 / 0.3), 0.06);
        const w = zh * squeeze;
        const shear = zh * 0.12 * @min(p * (1.0 / 0.3), 1.0) * squeeze;
        const flat = p >= 0.35;
        const sliced = p >= 0.1;
        const y0: usize = @intCast(@max(pix_start(top), 0));
        const y1: usize = @intCast(@max(@min(pix_start(bottom), view_h), 0));
        const vstep = 32.0 / h;
        const ustep = 32.0 / w;
        const sheet = gfx.rival;
        const bytes = sheet.indices.bytes;
        const cell_x: u32 = @as(u32, @min(e.cell, 4)) * 32;
        var y = y0;
        while (y < y1) : (y += 1) {
            if (sliced and y & 1 == 1) continue;
            const vf = (@as(f32, @floatFromInt(y)) + 0.5 - top) * vstep;
            const v: u32 = @min(@as(u32, @intFromFloat(@max(vf, 0))), 31);
            const dir: f32 = if ((v >> 1) & 1 == 1) 1 else -1;
            const left = e.sx - w * 0.5 + dir * shear;
            const x0 = @max(pix_start(left), 0);
            const x1 = @min(pix_start(left + w), view_w);
            var uf = (@as(f32, @floatFromInt(x0)) + 0.5 - left) * ustep;
            const row = v * sheet.width + cell_x;
            const ink = if (v & 2 == 0) cyan else hi;
            var x = x0;
            while (x < x1) : (x += 1) {
                const xi: usize = @intCast(x);
                if (z < view.depth[xi]) {
                    const idx = nibble(bytes, row + @min(@as(u32, @intFromFloat(@max(uf, 0))), 31));
                    if (idx != 0) cart.framebuffer[xi][y] = if (flat) ink else pal[idx];
                }
                uf += ustep;
            }
        }
    }
    const xc = pix_start(e.sx);
    if (p >= 0.5 and p < 0.85) {
        const k = (p - 0.5) * (1.0 / 0.35);
        const top = pix_start(bottom - zh * 1.7);
        const foot = pix_start(bottom - zh * 1.7 * k);
        const half: i32 = @intFromFloat(zh * 0.04 * (1.0 - k));
        fx.fill(xc - half - 1, xc + half + 2, top, foot, view_h, z, cyan);
        fx.fill(xc, xc + 1, top, foot, view_h, z, hi);
    }
    if (p >= 0.7) {
        const k = p - 0.7;
        const sz: i32 = @max(@as(i32, @intFromFloat(zh * (1.0 / 24.0))), 1);
        const blue = fx.px(fx.c_blue);
        for (sparks, 0..) |ox, i| {
            const fi: f32 = @floatFromInt(i);
            const sy = pix_start(bottom - zh * (0.8 + 0.12 * fi) - k * zh * (2.0 + fi * 0.4));
            const sx = pix_start(e.sx + ox * zh);
            fx.fill(sx, sx + sz, sy, sy + sz, view_h, z, if (i & 1 == 0) cyan else blue);
        }
    }
}

/// Lateral offsets (sprite heights) of the rising warp pixels.
const sparks = [6]f32{ -0.2, 0.15, -0.05, 0.22, -0.15, 0.06 };

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
pub const Rival = struct { x: f32, y: f32, cell: u8, white: bool, shirt: u8 = 0, label: u8 = 0 };
pub var rival: ?Rival = null;
pub var show_enemies: bool = true;
/// Party deathmatch (M8): every other player, `rivals[0..rival_count]`
/// (`set_rivals` fills it; `clear_rivals` after the frame, so the
/// campaign never draws one).
pub var rivals: [state.max_players - 1]Rival = undefined;
pub var rival_count: usize = 0;
/// Slot numbers float over heads nearer than this (cells).
pub const label_range: f32 = 6.0;

/// The rivals as `viewer` (slot `me`) sees them: every other present
/// slot, alive or lying dead (no number then), tinted by `slots.shirt_of`
/// and flashing white for two ticks after a hit, as M7's rival.
pub fn set_rivals(m: *const state.Match, me: usize, viewer: *const state.Player) void {
    rival_count = 0;
    for (0..state.max_players) |o| {
        if (o == me or !m.is_present(o)) continue;
        const r = &m.players[o];
        const dead = m.dead[o] > 0;
        rivals[rival_count] = .{
            .x = fixed.to_f32(r.x),
            .y = fixed.to_f32(r.y),
            .cell = match.rival_cell(viewer, r, dead),
            .white = m.hurt[o] + 2 > sim.hurt_ticks,
            .shirt = slots.shirt_of(m, o),
            .label = if (dead) 0 else @intCast(o + 1),
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
        if (!state.pickup_present(s, i)) continue;
        const wx = @as(f32, @floatFromInt(p.x)) + 0.5;
        const wy = @as(f32, @floatFromInt(p.y)) + 0.5;
        cam.add(wx, wy, 0.5, .pickups, @backingInt(p.kind), .bottom, false);
    }

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
        c.add_entry(r.x, r.y, .{ .z = 0, .sx = 0, .size = 1.0, .sheet = .rival, .cell = r.cell, .anchor = .bottom, .white = r.white, .shirt = @min(r.shirt, slots.shirts.len - 1), .label = r.label });
    }

    /// `proto` with its z and sx filled in from the world position.
    fn add_entry(c: Cam, wx: f32, wy: f32, proto: Entry) void {
        const size = proto.size;
        const rx = wx - c.px;
        const ry = wy - c.py;
        const z = rx * c.dx + ry * c.dy;
        if (z < near_z or z > raycast.range) return;
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

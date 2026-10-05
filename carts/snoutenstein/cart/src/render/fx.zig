//! Deathmatch arsenal look (M9, PLAN.md "M9 Deathmatch arsenal"):
//! code-drawn art for the four arsenal weapons (pads, flying fork bombs,
//! rockets, explosions, HUD icons; the view models are in weapon.zig) and
//! the blue cyber death view. Code size is the budget, so the art is
//! lists of flat rectangles (`Rect`, 4 bytes each) in a small cell space,
//! drawn at any scale with a 1-texel Anti-black outline around their
//! union (all outlines first, then the fills), clipped per column against
//! `view.depth` like the sheet sprites. Explosions are concentric discs
//! computed per column. Render-only; the campaign never draws any of it.
const cart = @import("cart-api");
const view = @import("view.zig");
const textures = @import("textures.zig");

// ---------------------------------------------------------------- palette

/// Palette indices of the rect art (Antithesis colours plus the arsenal's).
pub const c_dsteel = 0;
pub const c_black = 1; // Anti-black, the outline
pub const c_steel = 2;
pub const c_grey = 3;
pub const c_white = 4; // Anti-White
pub const c_coral = 5;
pub const c_iris = 6;
pub const c_gold = 7;
pub const c_green = 8;
pub const c_red = 9;
pub const c_cyan = 10;
pub const c_blue = 11;
pub const c_diris = 12;
pub const c_brown = 13;
pub const c_dbrown = 14;
pub const c_orange = 15;

const rgb = [16]u24{
    0x3A3548, 0x16031B, 0x6D6A86, 0x958D9D, 0xFCFBF9, 0xF18271, 0x8E42DE, 0xE6C229,
    0x8FD14F, 0xEE453C, 0x6FE8FF, 0x3D6BFF, 0x4B1F7A, 0xB07438, 0x60391F, 0xFF8C1A,
};

/// `pal[tint][index]` in the sprite tints (`textures.SpriteTint`).
pub var pal: [textures.sprite_tint_count][16]cart.Pixel = undefined;

pub fn init() void {
    for (rgb, 0..) |c, i| {
        const cr: u32 = c >> 16;
        const cg: u32 = (c >> 8) & 0xFF;
        const cb: u32 = c & 0xFF;
        const lum = (cr * 77 + cg * 150 + cb * 29) >> 8;
        pal[0][i] = textures.rgb_pixel(cr, cg, cb);
        for (textures.tints, 1..) |t, k| pal[k][i] = textures.tint(cr, cg, cb, lum, t);
    }
}

pub fn px(c: u4) cart.Pixel {
    return pal[0][c];
}

// ---------------------------------------------------------------- rects

/// A filled rectangle of art: cell coordinates, size, palette index;
/// `bare` = no outline (sparks, glyphs, highlights).
pub const Rect = packed struct(u32) { x: u6, y: u6, w: u6, h: u6, c: u4, bare: bool = false, _: u3 = 0 };

pub fn ro(x: u6, y: u6, w: u6, h: u6, c: u4) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h, .c = c };
}
/// Without the outline.
pub fn rb(x: u6, y: u6, w: u6, h: u6, c: u4) Rect {
    return .{ .x = x, .y = y, .w = w, .h = h, .c = c, .bare = true };
}

/// First pixel whose centre is at or after `f`: ceil(f - 0.5).
pub inline fn pix(f: f32) i32 {
    const c = @ceil(@min(@max(f, -1024.0), 1024.0) - 0.5);
    return @intFromFloat(c);
}

/// Fills screen pixels [x0, x1) x [y0, y1) (clipped to the screen and
/// `ymax`) in the columns where `z` is nearer than the wall.
pub fn fill(x0: i32, x1: i32, y0: i32, y1: i32, ymax: i32, z: f32, p: cart.Pixel) void {
    const xa: usize = @intCast(@max(x0, 0));
    const xb: usize = @intCast(@max(@min(x1, @as(i32, cart.screen_width)), 0));
    const ya: usize = @intCast(@max(y0, 0));
    const yb: usize = @intCast(@max(@min(y1, ymax), 0));
    if (xa >= xb or ya >= yb) return;
    for (xa..xb) |x| {
        if (z >= view.depth[x]) continue;
        @memset(cart.framebuffer[x][ya..yb], p);
    }
}

/// Draws `list` with its cell origin at (left, top), `s` screen pixels per
/// cell unit, depth `z` (0 = in front of everything: HUD, view models),
/// clipped at row `ymax`. `flat` paints every pixel one colour (a flash).
pub fn rects(list: []const Rect, left: f32, top: f32, s: f32, z: f32, ymax: i32, p: *const [16]cart.Pixel, flat: ?cart.Pixel) void {
    inline for (.{ true, false }) |outline| {
        for (list) |q| {
            if (outline and q.bare) continue;
            const o: f32 = if (outline) 1 else 0;
            const x: f32 = @floatFromInt(q.x);
            const y: f32 = @floatFromInt(q.y);
            const w: f32 = @floatFromInt(q.w);
            const h: f32 = @floatFromInt(q.h);
            const colour = flat orelse p[if (outline) c_black else q.c];
            fill(pix(left + (x - o) * s), pix(left + (x + w + o) * s), pix(top + (y - o) * s), pix(top + (y + h + o) * s), ymax, z, colour);
        }
    }
}

/// `list` at 1:1 on the screen, top-left at (x, y).
pub fn screen(list: []const Rect, x: i32, y: i32) void {
    rects(list, @floatFromInt(x), @floatFromInt(y), 1, 0, cart.screen_height, &pal[0], null);
}

// ---------------------------------------------------------------- world art

/// World art in a 16 x 16 cell (a 0.5-cell pickup, bottom on the floor).
pub const Art = enum(u8) { fuzzer = 0, fork_bomb, ship_it, gc, gc_b, pad_on, pad_off, rocket, puff_hot, puff_cold };

pub fn art(a: Art) []const Rect {
    return switch (a) {
        .fuzzer => &fuzzer_art,
        .fork_bomb => &bomb_art,
        .ship_it => &ship_art,
        .gc => &gc_art,
        .gc_b => &gc_art_b,
        .pad_on => &pad_on_art,
        .pad_off => &pad_off_art,
        .rocket => &rocket_art,
        .puff_hot => &puff_hot_art,
        .puff_cold => &puff_cold_art,
    };
}

/// A chunky coral blaster with a glyph window of random bits.
const fuzzer_art = [_]Rect{
    ro(3, 5, 8, 4, c_coral), ro(4, 4, 6, 1, c_iris),   ro(11, 6, 4, 2, c_steel),
    ro(4, 9, 2, 3, c_diris), ro(8, 9, 2, 2, c_dsteel), rb(5, 6, 4, 2, c_black),
    rb(5, 6, 1, 1, c_green), rb(7, 7, 1, 1, c_green),  rb(8, 6, 1, 1, c_green),
};
/// A round bomb with a ":(" face and a lit fuse.
const bomb_art = [_]Rect{
    ro(5, 5, 6, 8, c_diris),  ro(4, 6, 8, 6, c_diris),  ro(7, 3, 2, 2, c_steel),  ro(8, 1, 1, 2, c_gold),
    rb(6, 6, 2, 1, c_iris),   rb(5, 7, 1, 2, c_iris),   rb(6, 8, 1, 1, c_coral),  rb(9, 8, 1, 1, c_coral),
    rb(7, 10, 2, 1, c_coral), rb(6, 11, 1, 1, c_coral), rb(9, 11, 1, 1, c_coral), rb(9, 0, 1, 1, c_orange),
};
/// A shipping crate with a rocket nose poking out.
const ship_art = [_]Rect{
    ro(1, 5, 13, 6, c_brown),  ro(0, 4, 2, 8, c_steel), ro(13, 4, 2, 8, c_steel), ro(15, 6, 1, 4, c_red),
    rb(2, 7, 11, 1, c_dbrown), rb(5, 8, 4, 2, c_coral), rb(6, 8, 2, 1, c_white),
};
/// A shredder head; `gc_b` is the blades a quarter turn on.
const gc_body = [_]Rect{ ro(4, 2, 8, 9, c_iris), ro(3, 3, 10, 7, c_iris), ro(7, 11, 2, 3, c_steel), rb(5, 4, 6, 5, c_black) };
const gc_art = gc_body ++ [_]Rect{ rb(5, 6, 6, 1, c_grey), rb(7, 4, 2, 5, c_grey), rb(7, 6, 2, 1, c_gold) };
const gc_art_b = gc_body ++ [_]Rect{ rb(5, 4, 2, 1, c_grey), rb(9, 8, 2, 1, c_grey), rb(9, 4, 2, 1, c_grey), rb(5, 8, 2, 1, c_grey), rb(6, 5, 4, 3, c_grey), rb(7, 6, 2, 1, c_gold) };
/// The pad under a weapon, lit while it holds one.
const pad_on_art = [_]Rect{ ro(3, 14, 10, 2, c_iris), rb(5, 14, 6, 1, c_cyan) };
const pad_off_art = [_]Rect{rb(4, 15, 8, 1, c_diris)};
/// A rocket seen nose on, and its exhaust puffs.
const rocket_art = [_]Rect{
    ro(5, 5, 6, 6, c_brown),  ro(3, 7, 2, 2, c_steel), ro(11, 7, 2, 2, c_steel), ro(7, 3, 2, 2, c_steel),
    ro(7, 11, 2, 2, c_steel), rb(6, 6, 4, 4, c_red),   rb(7, 7, 2, 2, c_white),
};
const puff_hot_art = [_]Rect{ rb(5, 5, 6, 6, c_orange), rb(6, 6, 4, 4, c_gold) };
const puff_cold_art = [_]Rect{ rb(5, 5, 6, 6, c_grey), rb(6, 4, 3, 3, c_steel) };

/// The arsenal weapon a pad shows (4..7), as world art (`tick` spins the GC).
pub fn weapon_art(w: u8, tick: u32) Art {
    return switch (w) {
        4 => .fuzzer,
        5 => .fork_bomb,
        6 => .ship_it,
        else => if ((tick >> 3) & 1 == 0) .gc else .gc_b,
    };
}

// ---------------------------------------------------------------- HUD icons

/// 8 x 8 ammo icons for the status bar: FUZZER, FORK BOMB, SHIP IT.
pub const icons = [3][]const Rect{ &icon_fuzzer, &icon_bomb, &icon_rocket };
const icon_fuzzer = [_]Rect{ ro(1, 2, 5, 3, c_coral), ro(6, 3, 2, 1, c_steel), ro(2, 5, 1, 2, c_diris), rb(2, 3, 1, 1, c_green), rb(4, 3, 1, 1, c_green) };
const icon_bomb = [_]Rect{ ro(2, 3, 4, 5, c_iris), ro(1, 4, 6, 3, c_iris), ro(4, 1, 1, 2, c_gold), rb(5, 0, 1, 1, c_orange) };
const icon_rocket = [_]Rect{ ro(1, 3, 5, 3, c_brown), ro(6, 3, 2, 3, c_red), ro(0, 2, 1, 5, c_steel), rb(2, 4, 3, 1, c_dbrown) };

// ---------------------------------------------------------------- explosions

/// An explosion centred at screen (sx, cy), radius `rad` px at its full
/// size, depth `z`, `age` ticks old of `life`; `rocket` = fire colours
/// (else the fork bomb's iris/cyan cyber blast). Three discs, grows over
/// four ticks, the core burns out, the last third dithers away.
pub fn blast(sx: f32, cy: f32, rad: f32, z: f32, age: u32, life: u32, rocket: bool) void {
    const a: f32 = @floatFromInt(age);
    const grow = @min(a, 4.0) * 0.15 + 0.4;
    const fade = age * 3 >= life * 2;
    const rings = [3]f32{ rad * grow, rad * grow * 0.75, rad * grow * @max(0.55 - a * 0.05, 0) };
    const cols: [3]u4 = if (rocket) .{ c_orange, c_gold, c_white } else .{ c_iris, c_cyan, c_white };
    const x0 = pix(sx - rings[0]);
    const x1 = pix(sx + rings[0]);
    var x = @max(x0, 0);
    while (x < @min(x1, @as(i32, cart.screen_width))) : (x += 1) {
        const xi: usize = @intCast(x);
        if (z >= view.depth[xi]) continue;
        const dx = @as(f32, @floatFromInt(x)) + 0.5 - sx;
        const col = &cart.framebuffer[xi];
        for (rings, cols) |rr, c| {
            const d2 = rr * rr - dx * dx;
            if (d2 <= 0) continue;
            const hh = @sqrt(d2);
            const ya: usize = @intCast(@max(pix(cy - hh), 0));
            const yb: usize = @intCast(@max(@min(pix(cy + hh), @as(i32, view.view_h)), 0));
            if (ya >= yb) continue;
            const p = pal[0][c];
            if (fade) {
                var y = ya + ((xi ^ ya ^ age) & 1);
                while (y < yb) : (y += 2) col[y] = p;
            } else {
                @memset(col[ya..yb], p);
            }
        }
    }
}

// ---------------------------------------------------------------- death view

/// Render-only noise (shear offsets, muzzle bits, sparks).
var seed: u32 = 0x9E3779B9;
pub fn noise() u32 {
    seed ^= seed << 13;
    seed ^= seed >> 17;
    seed ^= seed << 5;
    return seed;
}

/// Ticks the dissolve takes to sweep the view.
pub const sweep_ticks: u32 = 30;
const view_h: usize = view.view_h;
const view_w: usize = view.view_w;

/// Your own death view (`t` ticks since you died, the view already drawn
/// in the warp tint): a cyan scan line sweeps down; above it the rows
/// split into scanlines (odd rows halved) and the even rows near the
/// front shear sideways, settling as the front moves on.
pub fn death_view(t: u32) void {
    const front: usize = @min(t * view_h / sweep_ticks, view_h);
    var y: usize = 0;
    while (y < front) : (y += 1) {
        if (y & 1 == 1) {
            for (0..view_w) |x| halve(&cart.framebuffer[x][y]);
            continue;
        }
        const d = front - y;
        if (d >= 24) continue;
        const amp: u32 = @intCast(24 - d);
        const sh: i32 = @as(i32, @intCast(noise() % (amp / 3 + 1))) - @as(i32, @intCast(amp / 6));
        shift_row(y, sh);
    }
    if (front < view_h) {
        const p = pal[0][c_cyan];
        const w = pal[0][c_white];
        for (0..view_w) |x| {
            cart.framebuffer[x][front] = w;
            if (front + 1 < view_h) cart.framebuffer[x][front + 1] = p;
        }
    }
}

fn halve(p: *cart.Pixel) void {
    if (cart.is_wasm) {
        p.bits = @byteSwap((@byteSwap(p.bits) >> 1) & 0x7BEF);
    } else {
        p.bits = (p.bits >> 1) & 0x7BEF;
    }
}

/// Moves row `y` of the view `sh` pixels sideways (the edge pixel repeats).
fn shift_row(y: usize, sh: i32) void {
    if (sh == 0) return;
    var row: [view_w]cart.Pixel = undefined;
    for (0..view_w) |x| row[x] = cart.framebuffer[x][y];
    for (0..view_w) |x| {
        const src = @min(@max(@as(i32, @intCast(x)) - sh, 0), @as(i32, view_w - 1));
        cart.framebuffer[x][y] = row[@intCast(src)];
    }
}

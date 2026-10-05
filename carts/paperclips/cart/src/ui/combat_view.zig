//! The COMBAT page's battle field, drawn from the game's ships (combat.js
//! draws them on a 310 x 150 canvas): a grey field, the probes white, the
//! drifters black, dead ships as the original's little white explosions,
//! all scaled into the box the page gives it.
const G = @import("game");
const d = @import("draw.zig");

const field_w: f64 = G.combat.width;
const field_h: f64 = G.combat.height;

pub fn draw(g: *const G.Game, x0: i32, y0: i32, w: i32, h: i32) void {
    d.fill_rect_px(x0, y0, w, h, d.pixel_of(0x808080));
    const sx = @as(f64, @floatFromInt(w)) / field_w;
    const sy = @as(f64, @floatFromInt(h)) / field_h;
    const white = d.px(.white);
    const black = d.px(.black);
    for (g.ships[0..g.num_ships]) |s| {
        const x = x0 + to_i(s.x * sx);
        const y = y0 + to_i(s.y * sy);
        if (s.alive) {
            // A 2x2 ship at full size reads as one or two pixels here.
            const p = if (s.team == 0) white else black;
            put(x, y, p, x0, y0, w, h);
            put(x + 1, y, p, x0, y0, w, h);
        } else if (s.frames_dead < 10) {
            const f: i32 = @intCast(s.frames_dead / 2);
            if (s.frames_dead < 2) {
                var dy: i32 = -1;
                while (dy <= 1) : (dy += 1) {
                    var dx: i32 = -1;
                    while (dx <= 1) : (dx += 1) put(x + dx, y + dy, white, x0, y0, w, h);
                }
            } else {
                put(x + f, y + f, white, x0, y0, w, h);
                put(x - f, y + f, white, x0, y0, w, h);
                put(x + f, y - f, white, x0, y0, w, h);
                put(x - f, y - f, white, x0, y0, w, h);
            }
        }
    }
}

fn to_i(v: f64) i32 {
    if (!(v > -1000 and v < 1000)) return -1000;
    return @intFromFloat(@floor(v));
}

inline fn put(x: i32, y: i32, p: anytype, x0: i32, y0: i32, w: i32, h: i32) void {
    if (x < x0 or y < y0 or x >= x0 + w or y >= y0 + h) return;
    d.plot(x, y, p);
}

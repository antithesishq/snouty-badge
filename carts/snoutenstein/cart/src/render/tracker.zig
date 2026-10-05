//! The deathmatch motion tracker (M9.3, PLAN.md): a 23 px disc in the
//! view's bottom-left corner with the blips `radar.zig` keeps. Up is the
//! way the viewer faces, 1 px a cell. Render-only.
const cart = @import("cart-api");
const state = @import("../state.zig");
const radar = @import("../radar.zig");
const fx = @import("fx.zig");
const hud = @import("hud.zig");
const slots = @import("slots.zig");

/// The match's RADAR rule; the lobbies set it at match start.
pub var on: bool = true;
/// Undefined until `reset` (every match start), so it sits in .bss.
var memory: radar.Memory = undefined;

const r: i32 = radar.range;
const cx: i32 = 2 + r;
const cy: i32 = 103 - 1 - r;
/// A blip is 2x2 for the first half second after the pulse found it,
/// then one pixel, then gone.
const big_ticks: u32 = 30;
const small_ticks: u32 = 50;

/// At match start (and whenever the viewed slot changes).
pub fn reset() void {
    memory.reset();
}

/// Once per stepped tick.
pub fn tick(m: *const state.Match, me: usize, now: u32) void {
    if (on) memory.tick(m, me, now);
}

pub fn draw(m: *const state.Match, me: usize, now: u32) void {
    if (!on or m.dead[me] > 0) return;
    const rim: cart.Pixel = .from_color(hud.steel);
    const wave: cart.Pixel = .from_color(.rgb(0x2E6B3A));
    const you: cart.Pixel = .from_color(hud.anti_white);
    // Pulse radius in px, growing over the period.
    const pr: i32 = @intCast((now % radar.period) * @as(u32, @intCast(r)) / radar.period);
    // Squared radii bands: |d - k| < 0.5 <=> (2k-1)^2 <= 4 d^2 < (2k+1)^2.
    const rim_lo = (2 * r - 1) * (2 * r - 1);
    const rim_hi = (2 * r + 1) * (2 * r + 1);
    const wave_lo = (2 * pr - 1) * (2 * pr - 1);
    const wave_hi = (2 * pr + 1) * (2 * pr + 1);
    var dy: i32 = -r;
    while (dy <= r) : (dy += 1) {
        var dx: i32 = -r;
        while (dx <= r) : (dx += 1) {
            const d4 = 4 * (dx * dx + dy * dy);
            if (d4 >= rim_hi) continue;
            const p = &cart.framebuffer[@intCast(cx + dx)][@intCast(cy + dy)];
            if (d4 >= rim_lo) {
                p.* = rim;
            } else if (pr > 0 and d4 >= wave_lo and d4 < wave_hi) {
                p.* = wave;
            } else {
                fx.halve(p);
                fx.halve(p);
            }
        }
    }
    // You: a dot with a forward tick.
    cart.framebuffer[@intCast(cx)][@intCast(cy)] = you;
    cart.framebuffer[@intCast(cx)][@intCast(cy - 2)] = you;
    const p = &m.players[me];
    for (memory.blips, 0..) |b_opt, i| {
        const b = b_opt orelse continue;
        if (i == me) continue;
        const age = now -% b.tick;
        if (age >= small_ticks) continue;
        const s = radar.to_screen(b.x, b.y, p.x, p.y, p.angle);
        const x = cx + s[0];
        const y = cy - s[1];
        if ((x - cx) * (x - cx) + (y - cy) * (y - cy) >= (r - 1) * (r - 1)) continue;
        const c: cart.Pixel = .from_color(slots.slot_color(m, i));
        cart.framebuffer[@intCast(x)][@intCast(y)] = c;
        if (age < big_ticks) {
            cart.framebuffer[@intCast(x + 1)][@intCast(y)] = c;
            cart.framebuffer[@intCast(x)][@intCast(y + 1)] = c;
            cart.framebuffer[@intCast(x + 1)][@intCast(y + 1)] = c;
        }
    }
}

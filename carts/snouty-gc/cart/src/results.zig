//! Forked from snouty-zero/cart/src/results.zig at f8f6962.
//! The results screen (SPEC 8.2), M0 placeholder: the followed car's rank,
//! time and best lap, then the six racers in finishing order with their
//! times. M3 adds the portraits, kills, wrecks and CYCLES. Draw only.
const cart = @import("cart-api");
const world = @import("world.zig");
const racers = @import("racers.zig");
const hud = @import("hud.zig");

pub fn draw(w: *const world.World, follow: u8, frame: u32) void {
    const me = &w.cars[follow % world.car_count];
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = hud.anti_black });
    hud.centered("RESULTS", 6, hud.cyan);
    var clock: [7]u8 = undefined;
    hud.text("BEST", 20, 18, hud.white);
    hud.format_clock(&clock, me.best_lap);
    hud.text(&clock, 76, 18, hud.white);
    // The field by rank: position, racer, finish time (or the lap reached).
    var r: u8 = 1;
    while (r <= world.car_count) : (r += 1) {
        for (&w.cars, 0..) |*c, i| {
            if (c.rank != r) continue;
            const y = 32 + @as(i32, r - 1) * 12;
            const color = if (i == follow) hud.cyan else hud.white;
            var pos: [2]u8 = "1.".*;
            pos[0] = '0' + r;
            hud.text(&pos, 5, y, color);
            hud.text(racers.roster[c.racer % racers.count].name, 22, y, color);
            if (c.finished) {
                hud.format_clock(&clock, c.finish_tick);
                hud.text(&clock, 90, y, color);
            } else {
                var lap: [5]u8 = "LAP 1".*;
                lap[4] = @as(u8, '1') + @min(c.lap, 2);
                hud.text(&lap, 90, y, hud.dim);
            }
            cart.rect(.{ .x = 150, .y = y + 1, .width = 4, .height = 6, .fill_color = .rgb(racers.roster[c.racer % racers.count].livery) });
        }
    }
    if ((frame / 30) % 2 == 0) hud.centered("PRESS START", 110, hud.coral);
}

//! First-person weapon overlay: `weapons.png` 48x32, cell `weapon * 3 +
//! frame`, at x 56 with its bottom at y 104 plus the walk bob. Drawn
//! before the status bar, which covers the rows that sink below 104
//! (ASSETS.md section 10: the sleeve never lifts off the bottom edge).
const gfx = @import("gfx");
const state = @import("../state.zig");
const sim = @import("../sim.zig");
const blit = @import("blit.zig");

pub const x: i32 = 56;
pub const w: u32 = 48;
pub const h: u32 = 32;
/// Resting top: bottom row exactly on y 103.
pub const rest_y: i32 = 104 - @as(i32, h);
pub const bob_period: u32 = 32;
/// Peak-to-peak bob is 4 px (SPEC.md 4, +-2 around rest_y + 2), and only
/// downward from rest_y, so no gap opens under the sleeve.
pub const bob_depth: i32 = 4;

/// Render-only bob phase, 0..bob_period-1. Advances while moving; when
/// the player stops it runs on to the nearest rest point (phase 0).
var phase: u32 = 0;

/// 0 idle, 1 first fire/swing frame, 2 second.
pub fn frame_for(wp: state.Weapon, cooldown: u8) u32 {
    const r: u32 = sim.fire_rate(wp);
    const c: u32 = cooldown;
    if (c > r * 2 / 3) return 1;
    if (c > r / 3) return 2;
    return 0;
}

/// Triangle wave 0..bob_depth..0 over bob_period ticks.
fn bob_offset(p: u32) i32 {
    const half = bob_period / 2;
    const d: u32 = if (p < half) p else bob_period - p; // 0..half
    return @intCast(d * @as(u32, bob_depth) / half);
}

/// Call once per displayed tick. `moving` = the player walked this tick.
pub fn draw(s: *const state.GameState, moving: bool) void {
    if (moving) {
        phase = (phase + 1) % bob_period;
    } else if (phase != 0) {
        // Settle to rest by the shorter way round.
        phase = if (phase < bob_period / 2) phase - 1 else (phase + 1) % bob_period;
    }
    const wp = s.player.weapon;
    const cell_index: u32 = @as(u32, @backingInt(wp)) * 3 + frame_for(wp, s.player.fire_cooldown);
    blit.cell(gfx.weapons, w, h, cell_index, x, rest_y + bob_offset(phase), .{});
}

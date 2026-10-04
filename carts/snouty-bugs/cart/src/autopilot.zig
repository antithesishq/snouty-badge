//! Difficulty-probe bots (PLAN.md M7 "Probe", track D): turret (1), sweep
//! (2), dodger (3). While `main`'s bot is non-zero, `main.update` takes its
//! controls from here instead of the hardware or the input script, through
//! the normal input path, so history logs them and rewinds and the
//! identity check work. This is track A's stub: no buttons; track D
//! implements the bots. A bot may read `world.w` but never draws from the
//! world rng.
const cart = @import("cart-api");

/// Controls for `bot` (1..3) on the frame about to simulate `tick`
/// (`world.w.game_tick`).
pub fn controls(bot: u8, tick: u32) cart.Controls {
    _ = bot;
    _ = tick;
    return @bitCast(@as(u16, 0));
}

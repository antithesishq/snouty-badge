//! Enemy behaviour (SPEC.md section 8), called once per tick from
//! `sim.step` after doors and pickups and before the player's weapon.
//! Owns every field of `state.Enemy` (including `frame`) once the level
//! starts; `sim.damage_enemy` is the only outside writer. Fixed point
//! only, `sim.next_rand` for randomness, no cart-api.
//! M3 track A replaces this stub, which only keeps the M2 hit reactions.
const std = @import("std");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");

const GameState = state.GameState;
const Level = levels.Level;

pub fn update(s: *GameState, level: *const Level) void {
    _ = level;
    for (&s.enemies) |*e| {
        if (e.flash > 0) e.flash -= 1;
        switch (e.state) {
            .dead => {},
            .dying => {
                if (e.timer > 0) e.timer -= 1;
                if (e.timer == 0) {
                    e.state = .dead;
                    e.frame = sim.frame_dead;
                } else {
                    e.frame = sim.frame_dying + (sim.dying_ticks - e.timer) / sim.dying_frame_ticks;
                }
            },
            .pain => {
                if (e.timer > 0) e.timer -= 1;
                if (e.timer == 0) {
                    e.state = .idle;
                    e.frame = sim.frame_idle;
                } else e.frame = sim.frame_pain;
            },
            .attack => e.frame = sim.frame_attack,
            .dormant, .idle, .alert, .chase => e.frame = sim.frame_idle,
        }
    }
}

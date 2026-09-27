//! Snouty portrait (SPEC.md section 10): picks one of the nine `face.png`
//! frames from render-only state advanced once per displayed tick. None
//! of this lives in GameState, so rewind and replay never see it.
const state = @import("../state.zig");

pub const Frame = enum(u8) {
    healthy = 0,
    hurt = 1,
    critical = 2,
    ouch = 3,
    grin = 4,
    glance_left = 5,
    glance_right = 6,
    rewind = 7,
    dead = 8,
};

pub const ouch_ticks: u16 = 30;
pub const grin_ticks: u16 = 45;
pub const glance_ticks: u16 = 40;
pub const glance_min: u16 = 180;
pub const glance_span: u16 = 121; // next glance in 180..300 ticks

/// Set by main.zig while the player holds rewind (M4); shows the rewind
/// face and suppresses event triggers (the state runs backwards).
pub var rewinding: bool = false;

var primed: bool = false;
var last_tick: u32 = 0;
var last_level: u8 = 0;
var last_hp: i16 = 0;
var last_keys: u8 = 0;
var last_spray: bool = false;

var ouch: u16 = 0;
var grin: u16 = 0;
var glance: u16 = 0;
var glance_wait: u16 = glance_min;
var glance_right: bool = false;
/// Own LCG (not s.rng: that would make the face part of the replay).
var lcg: u32 = 0x1234_5678;

fn next_wait() u16 {
    lcg = lcg *% 1664525 +% 1013904223;
    return glance_min + @as(u16, @intCast((lcg >> 16) % glance_span));
}

/// Forget events; the next `tick` re-reads the baseline without firing.
pub fn reset() void {
    primed = false;
    ouch = 0;
    grin = 0;
    glance = 0;
    glance_wait = glance_min;
}

pub fn tick(s: *const state.GameState) void {
    const p = &s.player;
    if (ouch > 0) ouch -= 1;
    if (grin > 0) grin -= 1;
    // A new level, a restart or a rewind (tick went backwards): take a
    // fresh baseline instead of reading the jump as damage or a pickup.
    const jumped = !primed or s.tick < last_tick or s.level != last_level;
    if (jumped) {
        ouch = 0;
        grin = 0;
    } else if (!rewinding) {
        if (p.hp < last_hp) ouch = ouch_ticks;
        const new_keys = p.keys & ~last_keys;
        if (new_keys != 0 or (p.has_spray and !last_spray)) grin = grin_ticks;
    }
    primed = true;
    last_tick = s.tick;
    last_level = s.level;
    last_hp = p.hp;
    last_keys = p.keys;
    last_spray = p.has_spray;

    if (glance > 0) {
        glance -= 1;
    } else if (ouch == 0 and grin == 0) {
        if (glance_wait > 0) glance_wait -= 1;
        if (glance_wait == 0) {
            glance = glance_ticks;
            glance_right = !glance_right;
            glance_wait = next_wait();
        }
    }
}

pub fn frame(s: *const state.GameState) Frame {
    const hp = s.player.hp;
    if (hp <= 0) return .dead;
    if (rewinding) return .rewind;
    if (ouch > 0) return .ouch;
    if (grin > 0) return .grin;
    if (glance > 0) return if (glance_right) .glance_right else .glance_left;
    if (hp < 25) return .critical;
    if (hp < 60) return .hurt;
    return .healthy;
}

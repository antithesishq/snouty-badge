//! Sound effects and neopixels (SPEC.md section 12). Render-side only: it
//! reads GameState once per displayed tick, diffs it against the previous
//! one to find events (like render/portrait.zig), and never writes to the
//! simulation. One voice through `cart.tone2`: a tick plays only its
//! highest-priority event, and a sound still playing is only cut by an
//! event of higher priority (or a different event of equal priority).
//!
//! Tone2 has square, triangle, sawtooth, sine, major and minor shapes, no
//! noise and no sweep: "noise" rows play as low sawtooth; the two sweeps
//! (door, rewind) retrigger the tone every `sweep_step` ticks at the
//! interpolated frequency from `tick`. The wasm simulator ignores the shape.
//!
//! Neopixels are off (docs/NEOPIXELS.md at the repository root, approved
//! 2026-09-29: carts never write a non-zero neopixel value; a coworker's
//! badge shows the LEDs are unusably bright even at 1%). The HP bar, key
//! flash and rewind pulse below are kept but compiled out unless the cart
//! is built with `-Dneopixels=true`: `write_pixels` is the only writer of
//! `cart.neopixels` and returns at once otherwise. The OS zeroes the strip
//! at cart start.
const cart = @import("cart-api");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");
const build_options = @import("build_options");

/// Sound (and the dormant LED effects), off by default; Select on the
/// title toggles it.
pub var enabled: bool = false;

pub const Event = enum { swatter, zapper, spray, enemy_hit, enemy_death, player_hurt, door, locked_door, pickup, rewind, death_freeze };

const Shape = cart.Tone2Options.Shape;

const Sound = struct {
    shape: Shape,
    from: u16, // Hz
    to: u16, // Hz, == from unless it sweeps
    ticks: u8, // duration, 1/60 s
    prio: u8, // higher wins
};

/// Indexed by `@intFromEnum(Event)`. Priority: death > rewind > player
/// hurt > pickup > enemy death > door > enemy hit > locked door > weapon.
const sounds = [_]Sound{
    .{ .shape = .sawtooth, .from = 200, .to = 200, .ticks = 3, .prio = 1 }, // swatter (noise)
    .{ .shape = .square, .from = 1200, .to = 1200, .ticks = 3, .prio = 1 }, // zapper
    .{ .shape = .sawtooth, .from = 120, .to = 120, .ticks = 9, .prio = 1 }, // spray (noise)
    .{ .shape = .triangle, .from = 900, .to = 900, .ticks = 2, .prio = 3 }, // enemy hit
    .{ .shape = .square, .from = 180, .to = 180, .ticks = 7, .prio = 5 }, // enemy death
    .{ .shape = .sawtooth, .from = 140, .to = 140, .ticks = 12, .prio = 7 }, // player hurt
    .{ .shape = .triangle, .from = 300, .to = 500, .ticks = 15, .prio = 4 }, // door
    .{ .shape = .square, .from = 90, .to = 90, .ticks = 12, .prio = 2 }, // locked door
    .{ .shape = .major, .from = 660, .to = 660, .ticks = 12, .prio = 6 }, // pickup
    .{ .shape = .square, .from = 800, .to = 200, .ticks = 10, .prio = 8 }, // rewind
    .{ .shape = .minor, .from = 55, .to = 55, .ticks = 48, .prio = 9 }, // death freeze
};

const volume: f32 = 0.6;
const sweep_step: u8 = 3;
const led_max: u8 = 10; // cap for the dormant effects; compiled out unless -Dneopixels=true
const key_flash_ticks: u8 = 6;

// Playing sound.
var cur: Event = .swatter;
var left: u8 = 0; // ticks of `cur` still sounding, 0 = silent
var sounding: bool = false; // a tone was started and not yet stopped

// Baseline (the previous displayed state).
var primed: bool = false;
var last_tick: u32 = 0;
var last_level: u8 = 0;
var last_hp: i16 = 0;
var last_kills: u16 = 0;
var last_keys: u8 = 0;
var last_ammo_zapper: u8 = 0;
var last_ammo_spray: u8 = 0;
var last_cooldown: u8 = 0;
var last_doors_closed: u64 = 0; // bit i: door i phase == closed
var last_flash2: u64 = 0; // bit i: enemy i flash == flash_ticks

var key_flash: u8 = 0;

// Rewind: ticks since this rewind began (sound retrigger and LED pulse).
var rewind_n: u32 = 0;
const rewind_retrigger: u32 = 10;
const rewind_pulse: u32 = 30; // LED triangle period, ticks
const rewind_led_lo: u32 = 3;
const rewind_led_hi: u32 = 8;

fn start_tone(freq: u16, ticks: u8, shape: Shape) void {
    cart.tone2(.{
        .frequency = @floatFromInt(freq),
        .duration = @as(f32, @floatFromInt(ticks)) * (1.0 / 60.0),
        .volume = volume,
        .flags = .{ .shape = shape },
    });
    sounding = true;
}

fn silence() void {
    if (sounding) cart.tone2(cart.Tone2Options.stop);
    sounding = false;
    left = 0;
}

/// Start `ev` now unless a more important sound is still playing.
pub fn play(ev: Event) void {
    if (!enabled) return;
    const snd = sounds[@backingInt(ev)];
    if (left > 0) {
        const p = sounds[@backingInt(cur)].prio;
        if (snd.prio < p or (snd.prio == p and ev == cur)) return;
    }
    cur = ev;
    left = snd.ticks;
    start_tone(snd.from, snd.ticks, snd.shape);
}

/// Advance the playing sound one tick; retrigger sweeps.
fn advance() void {
    if (left == 0) return;
    left -= 1;
    if (left == 0) {
        sounding = false; // the tone's own duration ended it
        return;
    }
    const snd = sounds[@backingInt(cur)];
    const done = snd.ticks - left;
    if (snd.from == snd.to or done % sweep_step != 0) return;
    const f0: i32 = snd.from;
    const f1: i32 = snd.to;
    // Reach `to` on the last retrigger.
    const span: i32 = snd.ticks - sweep_step;
    const f = f0 + @divTrunc((f1 - f0) * @min(@as(i32, done), span), span);
    start_tone(@intCast(f), left, snd.shape);
}

fn doors_closed(s: *const state.GameState, level: *const levels.Level) u64 {
    var m: u64 = 0;
    const n = @min(level.doors.len, state.max_doors);
    for (s.doors[0..n], 0..) |d, i| {
        if (d.phase == sim.door_closed) m |= @as(u64, 1) << @intCast(i);
    }
    return m;
}

fn flash2(s: *const state.GameState, level: *const levels.Level) u64 {
    var m: u64 = 0;
    const n = @min(level.enemies.len, state.max_enemies);
    for (s.enemies[0..n], 0..) |e, i| {
        if (e.flash == sim.flash_ticks) m |= @as(u64, 1) << @intCast(i);
    }
    return m;
}

fn baseline(s: *const state.GameState, level: *const levels.Level) void {
    const p = &s.player;
    primed = true;
    last_tick = s.tick;
    last_level = s.level;
    last_hp = p.hp;
    last_kills = s.kills;
    last_keys = p.keys;
    last_ammo_zapper = p.ammo_zapper;
    last_ammo_spray = p.ammo_spray;
    last_cooldown = p.fire_cooldown;
    last_doors_closed = doors_closed(s, level);
    last_flash2 = flash2(s, level);
}

/// Forget the baseline (the next `tick` takes a fresh one and plays
/// nothing), stop any sound and show the HP bar for `s`.
pub fn reset(s: *const state.GameState) void {
    primed = false;
    key_flash = 0;
    rewind_n = 0;
    silence();
    write_leds(s.player.hp);
}

/// Once per displayed tick while playing.
/// After a rewind the next call sees `s.tick < last_tick` and takes a
/// fresh baseline without playing anything (the `jumped` branch).
pub fn tick(s: *const state.GameState, level: *const levels.Level) void {
    if (!enabled) silence() else advance();
    rewind_n = 0; // the next rewind starts its sweep and pulse afresh

    const jumped = !primed or s.tick < last_tick or s.level != last_level;
    if (jumped) {
        key_flash = 0;
        baseline(s, level);
    } else {
        const p = &s.player;
        const closed = doors_closed(s, level);
        const f2 = flash2(s, level);
        const new_keys = p.keys & ~last_keys;
        if (new_keys != 0) key_flash = key_flash_ticks;

        const rate = sim.fire_rate(p.weapon);
        const fired = p.fire_cooldown == rate and last_cooldown < rate;
        // Door i was closed last tick and is opening now.
        var opened: u64 = 0;
        const nd = @min(level.doors.len, state.max_doors);
        for (s.doors[0..nd], 0..) |d, i| {
            if (d.phase == sim.door_opening) opened |= @as(u64, 1) << @intCast(i);
        }
        opened &= last_doors_closed;

        // Highest priority first; play only one.
        const ev: ?Event = if (p.hp < last_hp)
            .player_hurt
        else if (new_keys != 0 or p.ammo_zapper > last_ammo_zapper or
            p.ammo_spray > last_ammo_spray or p.hp > last_hp)
            .pickup
        else if (s.kills > last_kills)
            .enemy_death
        else if (opened != 0)
            .door
        else if (f2 & ~last_flash2 != 0)
            .enemy_hit
        else if (s.last_locked != 0)
            .locked_door
        else if (fired) switch (p.weapon) {
            .swatter => .swatter,
            .zapper => .zapper,
            .spray => .spray,
        } else null;
        if (ev) |e| play(e);

        baseline(s, level);
        last_doors_closed = closed;
        last_flash2 = f2;
    }

    if (key_flash > 0) key_flash -= 1;
    write_leds(s.player.hp);
}

/// Once per displayed tick while rewinding, instead of `tick`: no event
/// detection; the descending rewind sweep retriggers every 10 ticks (it
/// cuts whatever is playing, including the death freeze) and all five
/// neopixels would pulse Iris purple, 3/255 to 8/255 on the blue channel
/// over a 30-tick triangle (compiled out unless -Dneopixels=true). Silent when
/// disabled. `s` is the shown
/// state; unused for now (the display is state-independent).
pub fn rewind_tick(s: *const state.GameState) void {
    _ = s;
    var c: [5]cart.NeopixelColor = @splat(.{ .g = 0, .r = 0, .b = 0 });
    if (!enabled) {
        silence();
    } else {
        advance();
        if (rewind_n % rewind_retrigger == 0) {
            left = 0;
            play(.rewind);
        }
        // Triangle 0..15..0 over 30 ticks -> level 3..8.
        const ph = rewind_n % rewind_pulse;
        const tri = if (ph < rewind_pulse / 2) ph else rewind_pulse - ph;
        const lvl: u32 = rewind_led_lo + tri * (rewind_led_hi - rewind_led_lo) / (rewind_pulse / 2);
        // Iris 0x8E42DE scaled so blue = lvl (r = 0.64 lvl, g = 0.30 lvl).
        const on: cart.NeopixelColor = .{
            .g = @intCast(@min(lvl * 0x42 / 0xDE, led_max)),
            .r = @intCast(@min(lvl * 0x8E / 0xDE, led_max)),
            .b = @intCast(@min(lvl, led_max)),
        };
        c = @splat(on);
    }
    rewind_n +%= 1;
    write_pixels(c);
}

/// HP bar: one LED per started 20 HP; green from 60, amber from 25, red
/// below. Dead: LED 0 dim red. Key pickup: all white for 6 ticks. Off
/// when disabled. Compiled out unless -Dneopixels=true.
fn write_leds(hp: i16) void {
    const off: cart.NeopixelColor = .{ .g = 0, .r = 0, .b = 0 };
    var c: [5]cart.NeopixelColor = @splat(off);
    if (enabled) {
        if (key_flash > 0) {
            c = @splat(.{ .g = led_max, .r = led_max, .b = led_max });
        } else if (hp <= 0) {
            c[0] = .{ .g = 0, .r = 4, .b = 0 };
        } else {
            const on: cart.NeopixelColor = if (hp >= 60)
                .{ .g = led_max, .r = 0, .b = 0 }
            else if (hp >= 25)
                .{ .g = 5, .r = led_max, .b = 0 }
            else
                .{ .g = 0, .r = led_max, .b = 0 };
            const n: usize = @intCast(@min(@divTrunc(@as(i32, hp) + 19, 20), 5));
            for (c[0..n]) |*l| l.* = on;
        }
    }
    write_pixels(c);
}

/// The only place in the cart that writes cart.neopixels (docs/NEOPIXELS.md).
fn write_pixels(c: [5]cart.NeopixelColor) void {
    if (!build_options.neopixels) return; // the OS zeroes the strip at cart start
    for (c, 0..) |p, i| cart.neopixels[i] = p;
}

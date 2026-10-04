//! Sound effects (SPEC.md section 11). Render-side only: `frame` reads the
//! World once per displayed frame, diffs it against the previous one to
//! find events, and never writes to the simulation, so replay, rewind and
//! the identity checks see the same World with sound on or off. One
//! voice: a frame plays only its highest-priority event, and a sound still
//! playing is only cut by an event of higher priority (or a different
//! event of equal priority).
//!
//! The badge build renders the voice itself into the newer firmware's
//! streaming ring (lib/tone_stream.zig): that OS ignores `tone2` and the
//! old tone words are now the ring's, so only wasm calls `cart.tone2`
//! (finite tones, for the simulator); `update` once per cart update keeps
//! the ring fed.
const cart = @import("cart-api");
const build_options = @import("build_options");
const tone_stream = @import("tone_stream");
const world = @import("world.zig");
const player = @import("player.zig");

/// Starts as `-Dsound` says (off by default, docs/SOUND.md); Select
/// toggles it.
pub var enabled: bool = build_options.sound;

pub const Event = enum { zapper, enemy_hit, enemy_death, pickup, boss, extra_life, retry, bug_report, rewind, death };

const Shape = cart.Tone2Options.Shape;

const Sound = struct {
    shape: Shape,
    hz: u16,
    ms: u16,
    prio: u8, // higher wins
};

/// Indexed by `@intFromEnum(Event)`. Priority (SPEC.md 11): death >
/// rewind (bug report and sweep) > retry shield pop > extra life > boss
/// enters > crate > enemy death > enemy hit > zapper.
const sounds = [_]Sound{
    .{ .shape = .square, .hz = 880, .ms = 40, .prio = 1 }, // zapper
    .{ .shape = .triangle, .hz = 1200, .ms = 30, .prio = 2 }, // enemy hit (the spark)
    .{ .shape = .square, .hz = 220, .ms = 100, .prio = 3 }, // enemy death
    .{ .shape = .major, .hz = 880, .ms = 120, .prio = 4 }, // crate collected
    .{ .shape = .minor, .hz = 82, .ms = 800, .prio = 5 }, // boss enters
    .{ .shape = .major, .hz = 660, .ms = 300, .prio = 6 }, // extra life
    .{ .shape = .sawtooth, .hz = 330, .ms = 150, .prio = 7 }, // retry shield takes a hit
    .{ .shape = .sawtooth, .hz = 220, .ms = 300, .prio = 8 }, // bug report
    .{ .shape = .triangle, .hz = 110, .ms = 70, .prio = 8 }, // rewind step (hz from `rewind_hz`)
    .{ .shape = .sawtooth, .hz = 110, .ms = 500, .prio = 9 }, // player death
};

comptime {
    if (sounds.len != @as(usize, @backingInt(Event.death)) + 1) @compileError("one sounds row per Event (death is the last)");
}

/// Linear peak levels (the old `tone2` volumes 0.6, and 0.3 for the zapper).
const level: u8 = tone_stream.level_from_volume(60);
const zapper_level: u8 = tone_stream.level_from_volume(30);
/// The zapper sounds on every `zapper_every`-th volley.
const zapper_every: u32 = 3;
/// Rewind sweep: 110 to 880 Hz in `sweep_steps` steps, one per `sweep_step` frames.
const sweep_lo: u32 = 110;
const sweep_hi: u32 = 880;
const sweep_steps: u32 = 15;
const sweep_step: u32 = 4;

/// What the frame shows (main.zig's state machine).
pub const Mode = enum { quiet, play, dying, rewind, manual };

pub const Frame = struct {
    mode: Mode,
    /// Rewind stock (meta, main.zig).
    rewinds: u32,
    /// Frames into the REWIND sequence (0 on the hit frame).
    rewind_age: u32 = 0,
    /// Frames before the reverse playback starts (the bug report).
    report_ticks: u32 = 0,
    /// Frames into the hold-B rewind (1 on the press frame).
    manual_frame: u32 = 0,
};

// Playing sound.
var cur: Event = .zapper;
var left: u32 = 0; // frames of `cur` still sounding, 0 = silent

// Baseline (the previous displayed frame).
var last_mode: Mode = .quiet;
var primed: bool = false;
var last_tick: u32 = 0;
var last_rewinds: u32 = 0;
var last_boss: bool = false;
var last_weapon: player.Weapon = .fuzzer;
var last_level: u8 = 0;
var last_forks: u8 = 0;
var last_shield: u8 = 0;
var last_cores: u32 = 0;
/// Volleys fired since boot (the zapper's every-third count).
var volleys: u32 = 0;

fn frames_of(ms: u32) u32 {
    return (ms * 60 + 999) / 1000;
}

fn start_tone(hz: u32, ms: u32, shape: Shape, peak: u8) void {
    if (cart.is_wasm) {
        cart.tone2(.{
            .frequency = @floatFromInt(hz),
            .duration = @as(f32, @floatFromInt(ms)) * (1.0 / 1000.0),
            .volume = @as(f32, @floatFromInt(peak)) * (1.0 / 127.0),
            .flags = .{ .shape = shape },
        });
    } else {
        tone_stream.play(hz, tone_stream.ms(ms), peak, @fromBackingInt(@intCast(@backingInt(shape))));
    }
}

/// Once per cart update (renders the sounding tone into the ring).
pub fn update() void {
    tone_stream.update();
}

/// Select: flip the flag; off stops the tone at once.
pub fn toggle() void {
    enabled = !enabled;
    if (!enabled) silence();
}

fn silence() void {
    if (left > 0) {
        if (cart.is_wasm) cart.tone2(cart.Tone2Options.stop) else tone_stream.stop();
    }
    left = 0;
}

/// Start `ev` (at `hz`) unless a more important sound is still playing;
/// `force` restarts it even over itself (the rewind sweep's steps).
fn play_at(ev: Event, hz: u32, force: bool) void {
    const snd = sounds[@backingInt(ev)];
    if (left > 0 and !force) {
        const p = sounds[@backingInt(cur)].prio;
        if (snd.prio < p or (snd.prio == p and ev == cur)) return;
    }
    cur = ev;
    left = frames_of(snd.ms);
    start_tone(hz, snd.ms, snd.shape, if (ev == .zapper) zapper_level else level);
}

fn play(ev: Event) void {
    play_at(ev, sounds[@backingInt(ev)].hz, false);
}

/// Sweep step `k` (0..sweep_steps-1).
fn rewind_hz(k: u32) u32 {
    return sweep_lo + (sweep_hi - sweep_lo) * k / (sweep_steps - 1);
}

/// One rewind step every `sweep_step` frames, `n` frames in (from 0).
fn sweep(n: u32) void {
    if (n % sweep_step != 0) return;
    play_at(.rewind, rewind_hz((n / sweep_step) % sweep_steps), true);
}

fn baseline(rewinds: u32) void {
    const w = &world.w;
    const p = &w.player;
    primed = true;
    last_tick = w.game_tick;
    last_rewinds = rewinds;
    last_boss = w.waves.phase == .boss;
    last_weapon = p.weapon;
    last_level = p.level;
    last_forks = p.forks;
    last_shield = p.shield;
    last_cores = p.cores;
}

/// A spark (`spark`) or an explosion appeared this tick: `fx.update` ages
/// a new effect to 1 on the tick it was spawned.
fn new_fx(spark: bool) bool {
    for (world.w.fx) |f| {
        if (f.active and f.age == 1 and (f.kind == .spark) == spark) return true;
    }
    return false;
}

/// The highest-priority event of one live tick (the World advanced by
/// exactly one tick since the baseline), or null.
fn detect(rewinds: u32) ?Event {
    const w = &world.w;
    const p = &w.player;
    // `player.update` set the cooldown this tick: a volley left the ship.
    const fired = p.fire_cooldown == player.fire_interval;
    if (fired) volleys +%= 1;
    if (p.shield < last_shield) return .retry;
    if (rewinds > last_rewinds) return .extra_life;
    if (w.waves.phase == .boss and !last_boss) return .boss;
    if (p.weapon != last_weapon or p.level > last_level or p.forks > last_forks or
        p.shield > last_shield or p.cores > last_cores) return .pickup;
    if (new_fx(false)) return .enemy_death;
    if (new_fx(true)) return .enemy_hit;
    if (fired and volleys % zapper_every == 0) return .zapper;
    return null;
}

/// Once per displayed frame, after the state machine.
pub fn frame(f: Frame) void {
    defer last_mode = f.mode;
    if (left > 0) left -= 1;
    if (!enabled) {
        primed = false;
        return;
    }
    switch (f.mode) {
        .quiet => primed = false,
        .play => {
            const w = &world.w;
            if (primed and w.game_tick == last_tick +% 1) {
                if (detect(f.rewinds)) |ev| play(ev);
            }
            baseline(f.rewinds);
        },
        .dying => {
            primed = false;
            if (last_mode != .dying) play(.death);
        },
        .rewind => {
            primed = false;
            if (f.rewind_age == 0) {
                play(.bug_report);
            } else if (f.rewind_age >= f.report_ticks) {
                sweep(f.rewind_age - f.report_ticks);
            }
        },
        .manual => {
            primed = false;
            sweep(f.manual_frame -| 1);
        },
    }
}

//! Snouty vs. the Bugs: M5 "Rewind bar". Title card, then stages against
//! five enemy kinds and the Heisenbug, with graze, death, and the rewind:
//! a hit with a rewind in stock shows the bug report, plays the last 120
//! ticks backward from `history.zig` and resumes 120 ticks before the hit;
//! B held in play rewinds the world live, 2 ticks per frame, paid from a
//! fuel bar. See SPEC.md for the game, PLAN.md for the contracts and
//! CLAUDE.md for the toolchain.
const cart = @import("cart-api");
const draw = @import("draw.zig");
const input = @import("input.zig");
const rng = @import("rng.zig");
const player = @import("player.zig");
const bullets = @import("bullets.zig");
const enemies = @import("enemies.zig");
const waves = @import("waves.zig");
const collide = @import("collide.zig");
const fx = @import("fx.zig");
const pickups = @import("pickups.zig");
const patterns = @import("patterns.zig");
const hud = @import("hud.zig");
const world = @import("world.zig");
const history = @import("history.zig");
const rewind = @import("rewind.zig");
const rank = @import("rank.zig");
const autopilot = @import("autopilot.zig");

comptime {
    cart.export_start_code();
}

pub const State = enum(u32) { title = 0, playing = 1, paused = 2, dying = 3, rewind = 4, manual = 5 };

// Meta-state, outside the World (never rewound). Play state is `world.w`.
var state: State = .title;
/// Ticks since boot (drives title blink).
var tick_total: u32 = 0;
/// Rewind stock (replaces lives; SPEC.md 5.1).
var rewinds: u32 = start_rewinds;
/// Highest rewind-score threshold already paid out this game. The
/// threshold itself (`w.player.next_rewind_score`) is rewound; this is
/// not, so crossing the same threshold again after a rewind grants nothing.
var rewind_award_high_water: u32 = 0;
/// Ticks left in DYING before the title.
var dying_ticks: u32 = 0;
/// The bug that ended the game (DYING's message bar).
var fatal_kind: enemies.Kind = .gnat;
/// Test hook (wasm `debug_god`): hits are ignored.
var god: bool = false;
/// Endless probe mode (wasm `debug_probe`, PLAN.md M7): a hit removes the
/// offender, charges `player.on_rewound_hit` in the World at once, grants
/// `probe_invuln` ticks and counts in `w.player.probe_hits`; no rewind
/// runs. Constant through a probe run (like `god`), so applying it in both
/// simulate modes keeps the identity check exact.
var probe: bool = false;
/// Difficulty-probe bot (wasm `debug_bot`, 0 = off): while non-zero,
/// `update` reads its controls from `autopilot.controls`.
var bot: u8 = 0;
/// The REWIND sequence: the hit, `w.game_tick` right after it, the tick
/// play resumes from, and frames spent in REWIND (0 on the hit frame).
var rewind_hit: collide.Hit = .{};
var rewind_hit_tick: u32 = 0;
var rewind_target: u32 = 0;
var rewind_age: u32 = 0;
/// Rewind fuel in game ticks (SPEC.md 5.2). Meta, never in the World: a
/// rewind moves the World's clock, so fuel kept inside it would be
/// restored along with everything else and every rewind would be free.
var fuel: u32 = fuel_max;
/// Live ticks toward the next +1 refill.
var fuel_acc: u32 = 0;
/// Highest `w.player.grazes` / `w.waves.stage_clears` already paid out as
/// fuel this game: a graze or clear rewound away and made again pays
/// nothing (the `rewind_award_high_water` pattern).
var graze_high_water: u32 = 0;
var clear_high_water: u32 = 0;
/// Highest `w.player.cores` already paid out as fuel (CORE HOURS crates).
var cores_high_water: u32 = 0;
/// Frames spent in the current hold-B rewind (1 on the press frame).
var manual_frame: u32 = 0;
/// Hardcore game (SPEC.md 5.3, chosen with B on the title): no rewind
/// stock; a hit rewinds as far as the fuel allows, or is fatal under
/// `fatal_floor`.
var hardcore: bool = false;
/// Playback frames of the auto rewind in progress: half its depth,
/// rounded up (60 for a full 120-tick rewind).
var rewind_frames: u32 = rewind.playback_frames;

const start_rewinds: u32 = 3;
const max_rewinds: u32 = 5;
const rewind_score_step: u32 = 20_000;
const dying_len: u32 = 60;
/// Game ticks an auto rewind goes back at most (SPEC.md 5.1).
const rewind_depth: u32 = rewind.playback_frames * rewind.ticks_per_frame;
/// Fuel numbers (PLAN.md M5 "Numbers"): 3 s of rewind, full at the start;
/// +1 per 10 live ticks (empty to full in 30 s), +2 per graze.
const fuel_max: u32 = 180;
const fuel_refill_every: u32 = 10;
const graze_fuel: u32 = 2;
/// Fuel per CORE HOURS crate (PLAN.md M6): a third of the bar.
const cores_fuel: u32 = 60;
/// Hardcore: a hit met with less fuel than this is death (SPEC.md 5.3).
const fatal_floor: u32 = 45;
/// Probe mode: invulnerability after a counted hit (the resume grant).
const probe_invuln: u32 = rewind.resume_invuln;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    history.reset();
}

pub fn update() void {
    // A bot drives the same input path (meta and World detectors, the
    // history log) as the buttons would.
    const c = if (bot != 0) autopilot.controls(bot, world.w.game_tick) else read_controls();
    input.update_meta(c);

    switch (state) {
        .title => {
            if (input.meta_pressed(.a) or input.meta_pressed(.start)) {
                new_game(false);
            } else if (input.meta_pressed(.b)) {
                new_game(true);
            } else {
                draw.tick_bg();
            }
        },
        .playing => {
            if (input.meta_pressed(.start)) {
                state = .paused;
            } else if (input.meta_pressed(.b) and can_step()) {
                // The press frame rewinds instead of simulating, so a tap
                // is exactly one step.
                state = .manual;
                manual_frame = 0;
                manual_step();
            } else {
                input.update(c);
                simulate(.live);
            }
        },
        // The hold continues while B is down and fuel and history last;
        // then play resumes (with B possibly still down: only a fresh
        // press rewinds again). Joystick, A and Start are ignored.
        .manual => {
            if (input.meta.current.b and can_step()) manual_step() else manual_resume();
        },
        .paused => {
            if (input.meta_pressed(.start)) state = .playing;
        },
        .dying => {
            simulate_dying();
            dying_ticks -|= 1;
            if (dying_ticks == 0) state = .title;
        },
        // Inputs are ignored (Start cannot pause a rewind).
        .rewind => step_rewind(),
    }

    switch (state) {
        .title => {
            draw.draw_bg();
            hud.draw_title(tick_total);
        },
        .playing => {
            draw_scene();
            if (world.w.player.go_pop > 0) rewind.draw_go(world.w.player.go_pop);
            if (world.w.player.retry_pop > 0) rewind.draw_retry(world.w.player.retry_pop);
        },
        .dying => {
            draw_scene();
            if (hardcore) {
                rewind.draw_fatal_bar(fatal_kind, dying_len - dying_ticks);
            } else {
                rewind.draw_bar(fatal_kind);
            }
        },
        .paused => {
            draw_scene();
            hud.draw_pause();
        },
        .manual => {
            draw_scene();
            rewind.draw_manual(manual_frame);
        },
        .rewind => {
            draw_scene();
            if (rewind_age < rewind.report_ticks) {
                rewind.draw_report(rewind_hit, rewind_age);
            } else {
                rewind.draw_playback(rewind_hit, rewind_age - rewind.report_ticks + 1);
            }
        },
    }

    tick_total +%= 1;
    if (cart.is_wasm) present_wasm();
}

/// A fresh World, except that the background and the input edge detector
/// carry over so the sky scrolls on from the title and the button that
/// started the game is not seen as a new press. Meta-state is reset for
/// a normal or a hardcore game (no rewind stock), fuel full.
fn new_game(hard: bool) void {
    const w = &world.w;
    const bg = w.bg;
    w.* = .{};
    w.bg = bg;
    w.input = input.meta;
    const t: u32 = @truncate(cart.micros_since_boot());
    rng.seed(if (t == 0) 0x5EED else t);
    hardcore = hard;
    rewinds = if (hard) 0 else start_rewinds;
    rewind_award_high_water = 0;
    fuel = fuel_max;
    fuel_acc = 0;
    graze_high_water = 0;
    clear_high_water = 0;
    cores_high_water = 0;
    manual_frame = 0;
    if (bugs_bench_stage > 0) {
        probe = true;
        for (1..bugs_bench_stage) |_| waves.next_stage();
        waves.warp_to_warning();
    }
    history.reset();
    state = .playing;
}

/// badge-bench hook (`--poke bugs_bench_stage=N`, PLAN.md M7 "Deviations
/// (B2)"): N > 0 starts every game in probe mode, N - 1 stages on, at the
/// boss warning, so a bench reaches a boss in 7 s instead of 72.
export var bugs_bench_stage: u8 = 0;

/// One tick of play, in the PLAN.md update order; the caller has already
/// run `input.update` for it. `.live` ticks are logged (and keyframed) by
/// `history.record` and may change meta-state (the rewind stock, the fuel,
/// the state machine). `.silent` ticks are `history.restore`'s catch-up replay: the
/// same world-side simulation with no history, meta-state, audio or light.
pub fn simulate(mode: world.Mode) void {
    if (mode == .live) history.record();
    rank.update();
    waves.update();
    player.update();
    enemies.update();
    bullets.update();
    bullets.update_enemy_bullets();
    pickups.update();
    var hit = collide.run();
    // Probe mode (PLAN.md M7) counts the hit and charges the power loss in
    // the World at once, in both modes; the retry shield still goes first.
    if (hit.by != .none and probe and world.w.player.shield == 0) {
        collide.remove_offender(hit);
        player.on_rewound_hit();
        const p = &world.w.player;
        p.invuln = probe_invuln;
        p.probe_hits += 1;
        hit = .{};
    }
    // The retry shield takes the hit inside the World, in both modes: the
    // offender goes as in god mode, 60 ticks of invulnerability and the
    // `FLAKY, RETRYING` pop, and no meta logic ever sees the hit.
    if (hit.by != .none and !god and world.w.player.shield > 0) {
        collide.remove_offender(hit);
        const p = &world.w.player;
        p.shield = 0;
        p.invuln = player.retry_ticks;
        p.retry_pop = player.retry_ticks;
        hit = .{};
    }
    // A live hit that will be rewound leaves the world as it is (the
    // restore replaces it); any other hit (god mode, death, or one met
    // while replaying history, which can only be a god-mode hit) removes
    // the offender now, exactly where M3 did. Decided here, with the fuel
    // the hit meets (before this tick's refill).
    const rewinding = hit.by != .none and mode == .live and !god and can_auto_rewind();
    if (hit.by != .none and !rewinding) collide.remove_offender(hit);
    // audio effects check `mode` here (M6)
    fx.update();
    draw.tick_bg();
    world.w.game_tick +%= 1;
    award_rewinds(mode);
    if (mode == .live) award_fuel();
    if (mode == .live and hit.by != .none) on_hit(hit, rewinding);
}

/// A hit now would rewind rather than kill: a rewind in stock, or in
/// hardcore fuel at or above the fatal floor.
fn can_auto_rewind() bool {
    return if (hardcore) fuel >= fatal_floor else rewinds > 0;
}

/// The ship was touched (live only). `rewinding` was decided in
/// `simulate` (`can_auto_rewind`, not god mode). Normal mode spends a
/// rewind and goes back up to 120 ticks, fuel untouched; hardcore goes
/// back as far as the fuel allows (at most 120) and spends that much.
fn on_hit(hit: collide.Hit, rewinding: bool) void {
    if (god) return;
    if (rewinding) {
        rewind_hit = hit;
        rewind_hit_tick = world.w.game_tick;
        const reach = rewind_hit_tick - history.earliest_tick();
        if (hardcore) {
            const depth = @min(rewind_depth, fuel, reach);
            fuel -= depth;
            rewind_target = rewind_hit_tick - depth;
        } else {
            rewinds -= 1;
            rewind_target = rewind_hit_tick - @min(rewind_depth, reach);
        }
        const tpf = rewind.ticks_per_frame;
        rewind_frames = (rewind_hit_tick - rewind_target + tpf - 1) / tpf;
        rewind_age = 0;
        state = .rewind;
    } else {
        state = .dying;
        dying_ticks = dying_len;
        fatal_kind = hit.kind;
        const c = player.hitbox_center();
        fx.spawn(.big_explosion, c[0], c[1]);
    }
}

/// Extra rewind at 10,000 points and every 20,000 after (max 5; never in
/// hardcore, which has no stock). The
/// threshold walks in the World in both modes; the stock is granted only
/// live and only for a threshold above the high water, so a threshold
/// crossed again after a rewind pays nothing.
fn award_rewinds(mode: world.Mode) void {
    const p = &world.w.player;
    while (p.score >= p.next_rewind_score) {
        if (mode == .live and !hardcore and p.next_rewind_score > rewind_award_high_water) {
            rewinds = @min(rewinds + 1, max_rewinds);
            rewind_award_high_water = p.next_rewind_score;
        }
        p.next_rewind_score += rewind_score_step;
    }
}

/// Fuel grants, live ticks only (so never in pause, freeze, playback, a
/// hold or DYING): +1 per `fuel_refill_every` ticks, `graze_fuel` per
/// graze above the high water, and a full bar for a stage clear above it.
fn award_fuel() void {
    fuel_acc += 1;
    if (fuel_acc >= fuel_refill_every) {
        fuel_acc = 0;
        fuel = @min(fuel + 1, fuel_max);
    }
    const grazes = world.w.player.grazes;
    if (grazes > graze_high_water) {
        fuel = @min(fuel + graze_fuel * (grazes - graze_high_water), fuel_max);
        graze_high_water = grazes;
    }
    const cores = world.w.player.cores;
    if (cores > cores_high_water) {
        fuel = @min(fuel + cores_fuel * (cores - cores_high_water), fuel_max);
        cores_high_water = cores;
    }
    const clears = world.w.waves.stage_clears;
    if (clears > clear_high_water) {
        fuel = fuel_max;
        clear_high_water = clears;
    }
}

/// A hold-B step is possible: fuel for a whole step (an odd 1 stays and
/// refills) and history that reaches that far back.
fn can_step() bool {
    return fuel >= rewind.ticks_per_frame and
        world.w.game_tick >= history.earliest_tick() + rewind.ticks_per_frame;
}

/// One hold-B frame: the world as it was `ticks_per_frame` ticks ago, paid
/// for tick by tick.
fn manual_step() void {
    if (!history.restore(world.w.game_tick - rewind.ticks_per_frame)) {
        manual_resume();
        return;
    }
    fuel -= rewind.ticks_per_frame;
    manual_frame += 1;
}

/// B released (or fuel or history ran out): the rewound-away future is
/// dropped and play goes on from here with live input on the next frame.
/// No invulnerability and no `GO!`: the player chose the moment. The
/// checkpoint keeps later restores from replaying across the resume.
fn manual_resume() void {
    history.invalidate_after(world.w.game_tick);
    history.checkpoint();
    state = .playing;
}

/// One REWIND frame (PLAN.md M4 state machine, M5 playback length).
/// Age 1..19: frozen bug report. 20 .. 19 + rewind_frames: reverse
/// playback frame k = age - 19, showing the world at hit_tick - 2k (never
/// past the target). 20 + rewind_frames (80 for a full rewind): resume at
/// the target with the invulnerability and the GO! pop, and a checkpoint
/// so later restores see that grant.
fn step_rewind() void {
    rewind_age += 1;
    const playback_end = rewind.report_ticks + rewind_frames;
    if (rewind_age < rewind.report_ticks) return;
    if (rewind_age < playback_end) {
        const k = rewind_age - rewind.report_ticks + 1;
        _ = history.restore(@max(rewind_hit_tick -| rewind.ticks_per_frame * k, rewind_target));
        return;
    }
    _ = history.restore(rewind_target);
    history.invalidate_after(rewind_target);
    // Raiden's power loss (PLAN.md M7), charged on the restored World so
    // the checkpoint below records it: one level, one fork, +80 mercy.
    player.on_rewound_hit();
    world.w.player.invuln = rewind.resume_invuln;
    world.w.player.go_pop = rewind.go_ticks;
    history.checkpoint();
    state = .playing;
}

/// A DYING tick: enemies, enemy bullets and the spawner are frozen (so
/// nothing fires); bolts, fx and the background keep running.
fn simulate_dying() void {
    bullets.update();
    fx.update();
    draw.tick_bg();
    world.w.game_tick +%= 1;
}

/// Draw order: bg, enemies, crates, ghosts, ship, bolts, enemy bullets,
/// fx, HUD, stage text. The ship and its ghosts are hidden while DYING.
fn draw_scene() void {
    draw.draw_bg();
    enemies.draw_enemies();
    pickups.draw_pickups();
    if (state != .dying) {
        player.draw_ghosts();
        player.draw_ship(world.w.game_tick);
    }
    bullets.draw_bolts(world.w.game_tick);
    bullets.draw_enemy_bullets();
    fx.draw_fx();
    hud.draw_hud(rewinds, fuel, fuel_max, fatal_floor, hardcore);
    hud.draw_stage_text();
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_state, .{ .name = "debug_state" });
        @export(&debug_score, .{ .name = "debug_score" });
        @export(&debug_lives, .{ .name = "debug_lives" });
        @export(&debug_enemies, .{ .name = "debug_enemies" });
        @export(&debug_bolts, .{ .name = "debug_bolts" });
        @export(&debug_world_size, .{ .name = "debug_world_size" });
        @export(&debug_rewinds, .{ .name = "debug_rewinds" });
        @export(&debug_bullets, .{ .name = "debug_bullets" });
        @export(&debug_grazes, .{ .name = "debug_grazes" });
        @export(&debug_stage, .{ .name = "debug_stage" });
        @export(&debug_boss_hp, .{ .name = "debug_boss_hp" });
        @export(&debug_stage_clears, .{ .name = "debug_stage_clears" });
        @export(&debug_phase, .{ .name = "debug_phase" });
        @export(&debug_god, .{ .name = "debug_god" });
        @export(&debug_warp, .{ .name = "debug_warp" });
        @export(&debug_history_check, .{ .name = "debug_history_check" });
        @export(&debug_game_tick, .{ .name = "debug_game_tick" });
        @export(&debug_rewind_target, .{ .name = "debug_rewind_target" });
        @export(&debug_earliest_tick, .{ .name = "debug_earliest_tick" });
        @export(&debug_fuel, .{ .name = "debug_fuel" });
        @export(&debug_manual_frame, .{ .name = "debug_manual_frame" });
        @export(&debug_hardcore, .{ .name = "debug_hardcore" });
        @export(&debug_weapon, .{ .name = "debug_weapon" });
        @export(&debug_forks, .{ .name = "debug_forks" });
        @export(&debug_shield, .{ .name = "debug_shield" });
        @export(&debug_pickups, .{ .name = "debug_pickups" });
        @export(&debug_cores, .{ .name = "debug_cores" });
        @export(&debug_drops, .{ .name = "debug_drops" });
        @export(&debug_probe, .{ .name = "debug_probe" });
        @export(&debug_hits, .{ .name = "debug_hits" });
        @export(&debug_rank, .{ .name = "debug_rank" });
        @export(&debug_mercy, .{ .name = "debug_mercy" });
        @export(&debug_stage_index, .{ .name = "debug_stage_index" });
        @export(&debug_next_stage, .{ .name = "debug_next_stage" });
        @export(&debug_bot, .{ .name = "debug_bot" });
        @export(&debug_spray, .{ .name = "debug_spray" });
    }
}

fn debug_state() callconv(.c) u32 {
    return @backingInt(state);
}
fn debug_score() callconv(.c) u32 {
    return world.w.player.score;
}
/// Kept from M1; the lives are the rewind stock now.
fn debug_lives() callconv(.c) u32 {
    return rewinds;
}
fn debug_enemies() callconv(.c) u32 {
    return enemies.live_count();
}
fn debug_bolts() callconv(.c) u32 {
    return bullets.live_bolts();
}
fn debug_world_size() callconv(.c) u32 {
    return @sizeOf(world.World);
}
fn debug_rewinds() callconv(.c) u32 {
    return rewinds;
}
fn debug_bullets() callconv(.c) u32 {
    return bullets.live_enemy_bullets();
}
fn debug_grazes() callconv(.c) u32 {
    return world.w.player.grazes;
}
/// Completed stages (`waves.State.loop`).
fn debug_stage() callconv(.c) u32 {
    return world.w.waves.loop;
}
fn debug_boss_hp() callconv(.c) u32 {
    const b = enemies.boss() orelse return 0;
    return b.hp;
}
fn debug_stage_clears() callconv(.c) u32 {
    return world.w.waves.stage_clears;
}
fn debug_phase() callconv(.c) u32 {
    return @backingInt(world.w.waves.phase);
}
/// Test hook: toggles god mode (hits ignored). Returns the new flag.
fn debug_god() callconv(.c) u32 {
    god = !god;
    return @intFromBool(god);
}
/// Test hook: jumps the stage clock to the 66 s warning. Returns the new t.
/// An edit from outside `simulate`, so it checkpoints the history.
fn debug_warp() callconv(.c) u32 {
    waves.warp_to_warning();
    if (state == .playing) history.checkpoint();
    return world.w.waves.t;
}
/// The identity test (SPEC.md 14): rebuilds the current tick from history
/// and compares. 0 identical, 1 differs, 2 refused: the restore was
/// impossible, or the world is not one the history describes (TITLE;
/// DYING, whose ticks are not recorded; the frozen bug report, whose world
/// is the aftermath of a hit that is being rewound away). The world is
/// left as restored.
fn debug_history_check() callconv(.c) u32 {
    switch (state) {
        .title, .dying => return 2,
        .rewind => if (rewind_age < rewind.report_ticks) return 2,
        // A hold-B frame shows a restored history state: 0 expected.
        .playing, .paused, .manual => {},
    }
    history_aside = world.w;
    if (!history.restore(world.w.game_tick)) return 2;
    return if (history.worlds_equal(&history_aside, &world.w)) 0 else 1;
}
/// Module-level (6 KB) rather than on the stack.
var history_aside: world.World = undefined;
fn debug_game_tick() callconv(.c) u32 {
    return world.w.game_tick;
}
fn debug_rewind_target() callconv(.c) u32 {
    return rewind_target;
}
fn debug_earliest_tick() callconv(.c) u32 {
    return history.earliest_tick();
}
fn debug_fuel() callconv(.c) u32 {
    return fuel;
}
fn debug_manual_frame() callconv(.c) u32 {
    return manual_frame;
}
fn debug_hardcore() callconv(.c) u32 {
    return @intFromBool(hardcore);
}
/// kind * 10 + level, kind 0 fuzzer, 1 assert, 2 bisect.
fn debug_weapon() callconv(.c) u32 {
    const p = &world.w.player;
    return @as(u32, @backingInt(p.weapon)) * 10 + p.level;
}
fn debug_forks() callconv(.c) u32 {
    return world.w.player.forks;
}
fn debug_shield() callconv(.c) u32 {
    return world.w.player.shield;
}
/// Live crates.
fn debug_pickups() callconv(.c) u32 {
    return pickups.live_count();
}
fn debug_cores() callconv(.c) u32 {
    return world.w.player.cores;
}
/// Crates spawned this game (World counter).
fn debug_drops() callconv(.c) u32 {
    return world.w.drops.count;
}

/// Test hook: toggles the endless probe mode (PLAN.md M7). Returns the
/// new flag.
fn debug_probe() callconv(.c) u32 {
    probe = !probe;
    return @intFromBool(probe);
}
/// Hits counted by the probe mode this game (World counter).
fn debug_hits() callconv(.c) u32 {
    return world.w.player.probe_hits;
}
/// Rank 0..1000 (PLAN.md M7).
fn debug_rank() callconv(.c) u32 {
    return rank.value();
}
fn debug_mercy() callconv(.c) u32 {
    return world.w.mercy;
}
/// stage + 4 x loop.
fn debug_stage_index() callconv(.c) u32 {
    return waves.stage_index();
}
/// Test hook: jumps to the start of the next stage (`waves.next_stage`:
/// enemies, enemy bullets and crates cleared). An edit from outside
/// `simulate`, so it checkpoints the history while playing or paused.
/// Returns the new stage index.
fn debug_next_stage() callconv(.c) u32 {
    waves.next_stage();
    if (state == .playing or state == .paused) history.checkpoint();
    return waves.stage_index();
}
/// Test hook: selects the difficulty-probe bot (0 = off, buttons again).
/// Returns the bot now driving.
fn debug_bot(n: u32) callconv(.c) u32 {
    bot = @intCast(@min(n, 255));
    return bot;
}
/// Test hook for the pattern engine's identity checks: from (140, 64), a
/// ring of 8 turning round bullets, two orbs that split into 6 pellets
/// (whose children split again into 3), three stop-and-go pellets (drag,
/// then an aimed fan of 3 at age 50) and an accelerating needle with a
/// speed cap. Spawned outside `simulate`, so it checkpoints the history
/// while playing. Returns the live enemy bullets.
fn debug_spray() callconv(.c) u32 {
    const x: f32 = 140;
    const y: f32 = 64;
    patterns.ring(x, y, 8, 0, .{ .speed = 0.8, .source = .moth, .turn = 2, .turn_left = 60 });
    patterns.ring(x, y, 2, 96, .{ .speed = 0.6, .shape = .orb, .source = .boss, .event = .split, .event_at = 40, .ev_n = 6, .ev_speed = 14, .gen = 1 });
    patterns.fan(x, y, 3, 20, .{ .speed = 1.5, .shape = .pellet, .source = .spider, .drag = 0.94, .event = .aim, .event_at = 50, .ev_n = 3, .ev_speed = 20 });
    patterns.at_angle(x, y, 128, .{ .speed = 0.2, .shape = .needle, .source = .wasp, .accel = 0.05, .vmax = 2.0 });
    if (state == .playing) history.checkpoint();
    return bullets.live_enemy_bullets();
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls.
pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim, copied from snouty-badge (see its CLAUDE.md for the full
/// story): upstream's wasm platform never presents, and the web simulator
/// reads a legacy framebuffer at 0x20 with red and blue swapped relative to
/// DisplayColor. Hardware builds compile none of this.
const sim_swap_rb = true;

fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    if (sim_swap_rb) {
        for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
            for (src_column, dst_column) |src, *dst| {
                const c = src.to_color();
                dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
            }
        }
    } else {
        sim_framebuffer.* = cart.framebuffer.*;
    }
}

//! Snouty vs. the Bugs: M4 "Rewind". Title card, then stages against five
//! enemy kinds and the Heisenbug, with graze, death, and the
//! rewind: a hit with a rewind in stock shows the bug report, plays the
//! last 120 ticks backward from `history.zig` and resumes 120 ticks before
//! the hit. See SPEC.md for the game, PLAN.md for the contracts and
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
const hud = @import("hud.zig");
const world = @import("world.zig");
const history = @import("history.zig");
const rewind = @import("rewind.zig");

comptime {
    cart.export_start_code();
}

pub const State = enum(u32) { title = 0, playing = 1, paused = 2, dying = 3, rewind = 4 };

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
/// The REWIND sequence: the hit, `w.game_tick` right after it, the tick
/// play resumes from, and frames spent in REWIND (0 on the hit frame).
var rewind_hit: collide.Hit = .{};
var rewind_hit_tick: u32 = 0;
var rewind_target: u32 = 0;
var rewind_age: u32 = 0;

const start_rewinds: u32 = 3;
const max_rewinds: u32 = 5;
const rewind_score_step: u32 = 20_000;
const dying_len: u32 = 60;
/// Game ticks a rewind goes back (SPEC.md 5.1).
const rewind_depth: u32 = rewind.playback_frames * rewind.ticks_per_frame;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    history.reset();
}

pub fn update() void {
    const c = read_controls();
    input.update_meta(c);

    switch (state) {
        .title => {
            if (input.meta_pressed(.a) or input.meta_pressed(.b) or input.meta_pressed(.start)) {
                new_game();
            } else {
                draw.tick_bg();
            }
        },
        .playing => {
            if (input.meta_pressed(.start)) {
                state = .paused;
            } else {
                input.update(c);
                simulate(.live);
            }
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
        },
        .dying => {
            draw_scene();
            rewind.draw_bar(fatal_kind);
        },
        .paused => {
            draw_scene();
            hud.draw_pause();
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
/// started the game is not seen as a new press.
fn new_game() void {
    const w = &world.w;
    const bg = w.bg;
    w.* = .{};
    w.bg = bg;
    w.input = input.meta;
    const t: u32 = @truncate(cart.micros_since_boot());
    rng.seed(if (t == 0) 0x5EED else t);
    rewinds = start_rewinds;
    rewind_award_high_water = 0;
    history.reset();
    state = .playing;
}

/// One tick of play, in the PLAN.md update order; the caller has already
/// run `input.update` for it. `.live` ticks are logged (and keyframed) by
/// `history.record` and may change meta-state (the rewind stock, the state
/// machine). `.silent` ticks are `history.restore`'s catch-up replay: the
/// same world-side simulation with no history, meta-state, audio or light.
pub fn simulate(mode: world.Mode) void {
    if (mode == .live) history.record();
    waves.update();
    player.update();
    enemies.update();
    bullets.update();
    bullets.update_enemy_bullets();
    const hit = collide.run();
    // A live hit with a rewind in stock leaves the world as it is (the
    // restore replaces it); any other hit (god mode, death, or one met
    // while replaying history, which can only be a god-mode hit) removes
    // the offender now, exactly where M3 did.
    const rewinding = hit.by != .none and mode == .live and !god and rewinds > 0;
    if (hit.by != .none and !rewinding) collide.remove_offender(hit);
    // audio/neopixel effects check `mode` here (M6)
    fx.update();
    draw.tick_bg();
    world.w.game_tick +%= 1;
    award_rewinds(mode);
    if (mode == .live and hit.by != .none) on_hit(hit, rewinding);
}

/// The ship was touched (live only). `rewinding` was decided in
/// `simulate`: rewind stock, not god mode.
fn on_hit(hit: collide.Hit, rewinding: bool) void {
    if (god) return;
    if (rewinding) {
        rewinds -= 1;
        rewind_hit = hit;
        rewind_hit_tick = world.w.game_tick;
        rewind_target = @max(rewind_hit_tick -| rewind_depth, history.earliest_tick());
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

/// Extra rewind at 10,000 points and every 20,000 after (max 5). The
/// threshold walks in the World in both modes; the stock is granted only
/// live and only for a threshold above the high water, so a threshold
/// crossed again after a rewind pays nothing.
fn award_rewinds(mode: world.Mode) void {
    const p = &world.w.player;
    while (p.score >= p.next_rewind_score) {
        if (mode == .live and p.next_rewind_score > rewind_award_high_water) {
            rewinds = @min(rewinds + 1, max_rewinds);
            rewind_award_high_water = p.next_rewind_score;
        }
        p.next_rewind_score += rewind_score_step;
    }
}

/// One REWIND frame (PLAN.md M4 state machine). Age 1..19: frozen bug
/// report. 20..79: reverse playback frame k = age - 19, showing the world
/// at hit_tick - 2k. 80: resume at the target with the invulnerability
/// and the GO! pop, and a checkpoint so later restores see that grant.
fn step_rewind() void {
    rewind_age += 1;
    const playback_end = rewind.report_ticks + rewind.playback_frames;
    if (rewind_age < rewind.report_ticks) return;
    if (rewind_age < playback_end) {
        const k = rewind_age - rewind.report_ticks + 1;
        _ = history.restore(@max(rewind_hit_tick -| rewind.ticks_per_frame * k, rewind_target));
        return;
    }
    _ = history.restore(rewind_target);
    history.invalidate_after(rewind_target);
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

/// Draw order: bg, enemies, ship, bolts, enemy bullets, fx, HUD, stage
/// text. The ship is hidden while DYING.
fn draw_scene() void {
    draw.draw_bg();
    enemies.draw_enemies();
    if (state != .dying) player.draw_ship(world.w.game_tick);
    bullets.draw_bolts(world.w.game_tick);
    bullets.draw_enemy_bullets();
    fx.draw_fx();
    hud.draw_hud(rewinds, 0, 1, 0, false);
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
        .playing, .paused => {},
    }
    history_aside = world.w;
    if (!history.restore(world.w.game_tick)) return 2;
    return if (history.worlds_equal(&history_aside, &world.w)) 0 else 1;
}
/// Module-level (4 KB) rather than on the stack.
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

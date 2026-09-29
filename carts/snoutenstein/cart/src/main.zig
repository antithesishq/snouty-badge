//! Snoutenstein 3D: entry point, top-level state machine, wasm shims.
//! SPEC.md is the design, PLAN.md the current milestone, CLAUDE.md the
//! toolchain. Modes: title -> playing <-> rewinding (hold B) / dead (time
//! frozen, B rewinds) / paused; playing -> intermission -> next level ->
//! victory; the title idles into the recorded demo (attract mode, PLAN.md
//! M5) which any pad press takes over. Rewind semantics: PLAN.md M4; the
//! core is rewind.zig.
const std = @import("std");
const builtin = @import("builtin");
const cart = @import("cart-api");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");
const view = @import("render/view.zig");
const sprites = @import("render/sprites.zig");
const weapon = @import("render/weapon.zig");
const hud = @import("render/hud.zig");
const blit = @import("render/blit.zig");
const audio = @import("audio.zig");
const rewind = @import("rewind.zig");
const demo = @import("demo.zig");

comptime {
    cart.export_start_code();
}

pub const Mode = enum(u32) { title = 0, playing = 1, paused = 2, intermission = 3, victory = 4, dead = 5, rewinding = 6 };

// Level indices come from levels.zig once the campaign levels land (M3
// track C); until then everything maps onto the levels that exist.
const campaign_len: u8 = if (@hasDecl(levels, "campaign_len")) levels.campaign_len else 1;
const test_index: u8 = if (@hasDecl(levels, "test_index")) levels.test_index else 0;
const e1m1_index: u8 = if (@hasDecl(levels, "e1m1_index")) levels.e1m1_index else 1;
/// Death freeze safety net: with no history to rewind into (only possible
/// at the very first tick), holding B this long restarts the level. The
/// real exit from death is the rewind (SPEC.md 9.1, PLAN.md M4).
const dead_hold: u32 = 60;
/// Emergency reserve granted when rewinding out of death: 3 s.
const death_reserve: u16 = 180;
/// SPEC.md 9.3: re-simulate every keyframe span and compare, on builds
/// where the extra 30 `sim.step`s per half second do not matter.
const self_check = cart.is_wasm or builtin.mode == .debug;

/// Intermission card: skippable with A after `card_min`, auto-advances at `card_max`.
const card_min: u32 = 60;
const card_max: u32 = 300;
const victory_max: u32 = 600;
/// M1 gate readout stays on screen until Adrian has photographed it.
const show_render_us = true;

/// Attract mode (SPEC.md 11, PLAN.md M5): the title idles this long before
/// the recorded demo starts; the demo gives up after `demo_max` ticks, or
/// after sitting dead for `demo_dead_max` ticks without rewinding.
const attract_after: u32 = 600;
const demo_max: u32 = 3 * 3600;
const demo_dead_max: u32 = 120;

var mode: Mode = .title;
var tick_total: u32 = 0;
var card_ticks: u32 = 0;
var game: state.GameState = undefined;
var level: *const levels.Level = &levels.all[0];
var level_index: u8 = 0;
/// The input applied last tick (pad or demo log): edge detection for the
/// mode machine. `prev_pad` is the pad alone, for the takeover edge.
var prev_in: state.Buttons = .{};
var prev_pad: state.Buttons = .{};
var render_us: u32 = 0;
var held_b: u32 = 0;
/// Rewind bookkeeping (PLAN.md M4): ticks available when the rewind began
/// (the meter, topped up to the reserve when entered from death), ticks
/// spent so far, and whether death is where B was pressed.
var budget: u16 = 0;
var drained: u16 = 0;
var from_dead: bool = false;
/// Attract mode: the demo log drives the game while `demo_active`.
var demo_active: bool = false;
var title_ticks: u32 = 0;
var demo_ticks: u32 = 0;
var demo_dead: u32 = 0;
var demo_result: hud.DemoResult = .none;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    view.init();
}

pub fn update() void {
    const pad: state.Buttons = @bitCast(@as(u16, @bitCast(read_controls())));
    defer prev_pad = pad;
    tick_total += 1;

    // Which input drives this tick: the pad, or the demo log. A takeover
    // edge on the pad ends the demo without stepping; the pad is live from
    // the next tick on (SPEC.md 11).
    var in: state.Buttons = pad;
    if (demo_active) {
        demo_ticks += 1;
        if (takeover_edge(pad)) {
            take_over();
        } else if (demo_ticks >= demo_max) {
            end_demo(false);
        } else if (demo.next()) |db| {
            in = db;
            run_mode(in);
            demo_exit_checks();
        } else {
            end_demo(true);
        }
    } else {
        run_mode(in);
    }
    prev_in = in;

    switch (mode) {
        .title => hud.draw_title(tick_total, audio.enabled, demo_result),
        .playing, .paused, .dead, .rewinding => {
            const rw = mode == .rewinding;
            const shown: *const state.GameState = if (rw) rewind.current() else &game;
            const moving = mode == .playing and (in.up or in.down);
            const t0 = cart.micros_since_boot();
            view.shade_override = if (rw) 4 else if (mode == .dead or shown.hurt > 0) 5 else null;
            hud.meter_override = if (rw) budget - drained else null;
            view.draw(shown, level);
            if (rw) view.scanlines();
            weapon.draw(shown, moving);
            hud.draw_bar(shown);
            render_us = @intCast(cart.micros_since_boot() - t0);
            if (rw) hud.draw_rewind_marker();
            if (demo_active) hud.draw_demo_marker(tick_total);
            if (show_render_us) hud.draw_render_us(render_us);
            if (mode == .paused) hud.draw_pause();
            if (mode == .dead) hud.draw_dead(@max(game.player.rewind_meter, death_reserve));
        },
        .intermission => hud.draw_intermission(&game, level.name, @intCast(level.enemies.len), card_ticks),
        .victory => hud.draw_victory(&game, card_ticks),
    }

    if (cart.is_wasm) present_wasm();
}

/// The mode machine, one tick, driven by `b` (pad or demo log).
fn run_mode(b: state.Buttons) void {
    switch (mode) {
        .title => {
            // A: campaign. B: the imported E1M1. Start: the test level (the
            // scripted runs use it). Select: sound (SPEC.md section 3).
            // Nothing for `attract_after` ticks: the recorded demo.
            title_ticks += 1;
            if (pressed(b, .a)) {
                new_game(0);
            } else if (pressed(b, .b)) {
                new_game(e1m1_index);
            } else if (pressed(b, .start)) {
                new_game(test_index);
            } else if (pressed(b, .select)) {
                audio.enabled = !audio.enabled;
                audio.reset(&game); // LEDs off at once when disabled
                title_ticks = 0;
            } else if (title_ticks >= attract_after) {
                start_demo();
            }
        },
        .playing => {
            if (pressed(b, .start)) {
                mode = .paused;
            } else if (pressed(b, .b) and game.player.rewind_meter > 0) {
                begin_rewind(game.player.rewind_meter, false);
            } else {
                rewind.log_input(game.tick, b);
                sim.step(&game, level, b);
                rewind.after_step(&game);
                if (self_check and game.tick % rewind.keyframe_every == 0) _ = rewind.check(&game, level);
                hud.tick(&game);
                audio.tick(&game, level);
                if (game.player.hp <= 0) {
                    mode = .dead;
                    held_b = 0;
                    audio.play(.death_freeze);
                } else if (game.finished) {
                    mode = .intermission;
                    card_ticks = 0;
                }
            }
        },
        .dead => {
            // Time is frozen; only B does anything. A press starts the
            // rewind with at least the reserve; the hold counter is the
            // no-history safety net (see `dead_hold`).
            if (pressed(b, .b)) {
                begin_rewind(@max(game.player.rewind_meter, death_reserve), true);
            } else {
                held_b = if (b.b) held_b + 1 else 0;
                if (held_b >= dead_hold) new_game(level_index);
            }
        },
        .rewinding => {
            if (!b.b or drained >= budget) {
                end_rewind();
            } else if (rewind.back(level)) |_| {
                drained += 1;
                held_b = 0;
            } else if (from_dead and drained == 0) {
                // Dead at the very first tick with nothing to rewind into.
                held_b += 1;
                if (held_b >= dead_hold) new_game(level_index);
            }
            if (mode == .rewinding) audio.rewind_tick(rewind.current());
        },
        .paused => {
            if (pressed(b, .start)) mode = .playing;
        },
        .intermission => {
            card_ticks += 1;
            if (card_ticks >= card_max or (card_ticks >= card_min and (pressed(b, .a) or pressed(b, .start)))) {
                if (next_level(level_index)) |next| {
                    new_game(next);
                } else {
                    mode = .victory;
                    card_ticks = 0;
                }
            }
        },
        .victory => {
            card_ticks += 1;
            if (card_ticks >= victory_max or (card_ticks >= card_min and (pressed(b, .a) or pressed(b, .start)))) to_title();
        },
    }
}

/// The level after `i`: through the campaign, then victory; the test level
/// hands over to E1M1 so the scripted exit run exercises the transition.
fn next_level(i: u8) ?u8 {
    if (i + 1 < campaign_len) return i + 1;
    if (i == test_index and e1m1_index != test_index) return e1m1_index;
    return null;
}

fn new_game(index: u8) void {
    new_game_seeded(index, @truncate(cart.micros_since_boot()));
}

fn new_game_seeded(index: u8, seed: u32) void {
    level_index = index;
    level = &levels.all[level_index];
    sim.init(&game, level, level_index, seed);
    rewind.reset(&game);
    hud.set_rewinding(false);
    hud.meter_override = null;
    hud.tick(&game);
    audio.reset(&game);
    mode = .playing;
}

fn to_title() void {
    mode = .title;
    title_ticks = 0;
}

// ---------------------------------------------------------------- attract mode

/// The title idled: play the recorded demo (Build Farm, fixed seed).
fn start_demo() void {
    new_game_seeded(demo.level_index, demo.seed);
    demo.reset();
    demo_active = true;
    demo_ticks = 0;
    demo_dead = 0;
}

/// A, B, Start or the joystick pressed on the pad while the demo runs.
fn takeover_edge(pad: state.Buttons) bool {
    const now: u16 = @bitCast(pad);
    const before: u16 = @bitCast(prev_pad);
    const mask: u16 = @bitCast(state.Buttons{ .a = true, .b = true, .start = true, .up = true, .down = true, .left = true, .right = true });
    return (now & ~before & mask) != 0;
}

/// SPEC.md 11: the world stays as it is, the meter is refilled and the pad
/// is live from the next tick. The refill is recorded as a rewind patch so
/// replays and the keyframe self-check reproduce it.
fn take_over() void {
    if (mode == .rewinding) end_rewind();
    if (mode == .playing or mode == .dead or mode == .paused) rewind.set_meter(&game, sim.max_rewind);
    demo_active = false;
    hud.meter_override = null;
}

/// The demo ends on its own when the log runs out (`log_done`: compare the
/// gameplay hash with the recorded one; that is the hardware determinism
/// test), on the 3 min cap, after sitting dead, or once a level ends.
fn end_demo(log_done: bool) void {
    if (log_done and mode == .playing and demo.final_hash != 0) {
        demo_result = if (sim.hash_gameplay(&game) == demo.final_hash) .ok else .desync;
    }
    if (mode == .rewinding) end_rewind();
    demo_active = false;
    hud.set_rewinding(false);
    hud.meter_override = null;
    audio.reset(&game);
    to_title();
}

fn demo_exit_checks() void {
    if (mode == .dead) {
        demo_dead += 1;
        if (demo_dead >= demo_dead_max) end_demo(false);
    } else {
        demo_dead = 0;
    }
    if ((mode == .intermission or mode == .victory) and card_ticks >= card_min) end_demo(false);
}

/// Enter rewind with `ticks` of budget (PLAN.md M4 "Rewind semantics").
/// The death reserve is never written into `game`: the live state must
/// keep agreeing with its replay, so `end_rewind` writes the result.
fn begin_rewind(ticks: u16, dead: bool) void {
    budget = ticks;
    drained = 0;
    from_dead = dead;
    held_b = 0;
    rewind.begin(&game, level);
    // The press itself steps back once, so a tap out of death lands on
    // the last living tick and N held frames rewind N ticks.
    if (rewind.back(level)) |_| drained += 1;
    hud.set_rewinding(true);
    mode = .rewinding;
}

/// B released or budget spent. The shown state becomes live unless it is
/// still the death tick (B tapped without stepping back): then back to dead.
fn end_rewind() void {
    hud.set_rewinding(false);
    hud.meter_override = null;
    rewind.commit(&game, budget - drained, drained > 0);
    if (game.player.hp <= 0) {
        mode = .dead;
        held_b = 0;
        return;
    }
    mode = .playing;
}

const Button = enum { start, select, a, b, up, down, left, right };
fn pressed(b: state.Buttons, comptime btn: Button) bool {
    return @field(b, @tagName(btn)) and !@field(prev_in, @tagName(btn));
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_mode, .{ .name = "debug_mode" });
        @export(&debug_tick, .{ .name = "debug_tick" });
        @export(&debug_px, .{ .name = "debug_px" });
        @export(&debug_py, .{ .name = "debug_py" });
        @export(&debug_angle, .{ .name = "debug_angle" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_state_size, .{ .name = "debug_state_size" });
        @export(&debug_hp, .{ .name = "debug_hp" });
        @export(&debug_kills, .{ .name = "debug_kills" });
        @export(&debug_weapon, .{ .name = "debug_weapon" });
        @export(&debug_ammo, .{ .name = "debug_ammo" });
        @export(&debug_level, .{ .name = "debug_level" });
        @export(&debug_sprites, .{ .name = "debug_sprites" });
        @export(&debug_state_hash, .{ .name = "debug_state_hash" });
        @export(&debug_nibble_ok, .{ .name = "debug_nibble_ok" });
        @export(&debug_frozen, .{ .name = "debug_frozen" });
        @export(&debug_projectiles, .{ .name = "debug_projectiles" });
        @export(&debug_rewinds, .{ .name = "debug_rewinds" });
        @export(&debug_meter, .{ .name = "debug_meter" });
        @export(&debug_desync, .{ .name = "debug_desync" });
        @export(&debug_gameplay_hash, .{ .name = "debug_gameplay_hash" });
        @export(&debug_demo, .{ .name = "debug_demo" });
        @export(&debug_demo_result, .{ .name = "debug_demo_result" });
        @export(&debug_title_ticks, .{ .name = "debug_title_ticks" });
        @export(&debug_start_demo, .{ .name = "debug_start_demo" });
        @export(&debug_new_game_seeded, .{ .name = "debug_new_game_seeded" });
    }
}
fn debug_mode() callconv(.c) u32 {
    return @backingInt(mode);
}
/// Tick of the shown state (the rewound one while rewinding).
fn debug_tick() callconv(.c) u32 {
    return if (mode == .rewinding) rewind.current().tick else game.tick;
}
/// Player x in 16.16 fixed point (cells).
fn debug_px() callconv(.c) u32 {
    return @bitCast(game.player.x);
}
fn debug_py() callconv(.c) u32 {
    return @bitCast(game.player.y);
}
fn debug_angle() callconv(.c) u32 {
    return game.player.angle;
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}
fn debug_state_size() callconv(.c) u32 {
    return @sizeOf(state.GameState);
}
fn debug_hp() callconv(.c) u32 {
    return @bitCast(@as(i32, game.player.hp));
}
fn debug_kills() callconv(.c) u32 {
    return game.kills;
}
fn debug_weapon() callconv(.c) u32 {
    return @backingInt(game.player.weapon);
}
/// Ammo of the current weapon (swatter: 0).
fn debug_ammo() callconv(.c) u32 {
    return switch (game.player.weapon) {
        .swatter => 0,
        .zapper => game.player.ammo_zapper,
        .spray => game.player.ammo_spray,
    };
}
fn debug_level() callconv(.c) u32 {
    return level_index;
}
fn debug_sprites() callconv(.c) u32 {
    return sprites.drawn;
}
fn debug_state_hash() callconv(.c) u32 {
    return sim.hash(&game);
}
fn debug_frozen() callconv(.c) u32 {
    return game.player.frozen;
}
/// Live projectiles.
fn debug_projectiles() callconv(.c) u32 {
    var n: u32 = 0;
    for (game.projectiles) |pr| n += @intFromBool(pr.kind != 0);
    return n;
}
fn debug_rewinds() callconv(.c) u32 {
    return game.rewinds;
}
/// The displayed rewind meter in ticks (budget left while rewinding).
fn debug_meter() callconv(.c) u32 {
    return if (mode == .rewinding) budget - drained else game.player.rewind_meter;
}
/// Keyframe self-check mismatches (SPEC.md 9.3); the harness wants 0.
fn debug_desync() callconv(.c) u32 {
    return rewind.desyncs;
}
/// `sim.hash_gameplay` of the live state (the shown one while rewinding).
fn debug_gameplay_hash() callconv(.c) u32 {
    return sim.hash_gameplay(if (mode == .rewinding) rewind.current() else &game);
}
/// 1 while the demo log drives the game.
fn debug_demo() callconv(.c) u32 {
    return @intFromBool(demo_active);
}
/// 0 none, 1 ok, 2 desync: the last finished demo's hash check.
fn debug_demo_result() callconv(.c) u32 {
    return @backingInt(demo_result);
}
fn debug_title_ticks() callconv(.c) u32 {
    return title_ticks;
}
/// Setup call (`preview.mjs --call debug_start_demo`): the demo starts at
/// update 0 instead of after 10 s on the title.
fn debug_start_demo() callconv(.c) void {
    start_demo();
}
/// Setup call: Build Farm with the demo seed in normal play, so a demo
/// script can be authored and its hash recorded without a rebuild.
fn debug_new_game_seeded() callconv(.c) void {
    new_game_seeded(demo.level_index, demo.seed);
}
/// 1 when the sprite/blit nibble reads agree with PackedIntSlice.get.
fn debug_nibble_ok() callconv(.c) u32 {
    return @intFromBool(blit.nibble_order_ok());
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls.
pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim (see snouty-badge/CLAUDE.md): upstream's wasm platform
/// never presents, and the web simulator reads a legacy framebuffer at
/// 0x20 with red and blue swapped relative to DisplayColor.
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

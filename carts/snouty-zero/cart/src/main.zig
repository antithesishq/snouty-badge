//! Snouty Zero: an F-Zero style Mode 7 hover racer on a planet-sized AI
//! datacenter. SPEC.md is the design, PLAN.md the milestone contract.
//! M3: splash, title, attract, menus, Quick Race and Grand Prix, the hold-B
//! rewind and the crash auto-rewind on the snapshot bar, pause, sound.
const cart = @import("cart-api");
const build_options = @import("build_options");
const input = @import("input.zig");
const fixed = @import("fixed.zig");
const tuning = @import("tuning.zig");
const camera = @import("camera.zig");
const render = @import("render.zig");
const track = @import("track.zig");
const world = @import("world.zig");
const sim = @import("sim.zig");
const sprites = @import("sprites.zig");
const hud = @import("hud.zig");
const ai = @import("ai.zig");
const results = @import("results.zig");
const history = @import("history.zig");
const menu = @import("menu.zig");
const sound = @import("sound.zig");
const hills = @import("hills.zig");

comptime {
    cart.export_start_code();
}

/// Screens (SPEC 8).
pub const Screen = enum(u8) { splash, title, main_menu, league_pick, track_pick, race, pause, results, standings };
var screen: Screen = .splash;
/// Why the race runs: a Quick Race, a Grand Prix round, or the attract demo.
const Mode = enum { quick, gp, attract };
var mode: Mode = .quick;

/// Frames since start(); one frame is one update() at 60 Hz.
var frame: u32 = 0;
/// Frames on the current screen.
var screen_frames: u32 = 0;
/// Microseconds spent in the last frame (hardware timer; 0 on wasm).
var render_us: u32 = 0;
/// The autopilot drives the player (attract mode, `debug_set_autopilot`).
pub var autopilot: bool = false;
/// The M0 free camera (debug_set_freecam).
var free_cam: bool = false;

// Menus.
var main_list = menu.List{ .count = 4 };
var league_list = menu.List{ .count = track.leagues.len };
var track_list = menu.List{ .count = 3 };
var pause_list = menu.List{ .count = 4 };
var picked_league: u8 = 0;
var picked_track: u8 = 0;
/// Grand Prix progress.
var gp = menu.Standings{};
var gp_round: u8 = 0;
var gp_final: bool = false;
/// Attract: which track the next demo uses.
var attract_next: u8 = 0;
/// Title idle frames before the attract demo starts (10 s).
const attract_after: u32 = 600;

// Race meta-state (outside the World, never rewound).
/// Snapshot bar in ticks of rewind (SPEC 5.4).
var snapshot: u32 = tuning.snapshot_max;
var snapshot_refill: u32 = 0;
var rewinding: bool = false;
/// Hit-stop frames left after a crash, auto-rewind ticks left, JOB KILLED frames left.
var hitstop_left: u32 = 0;
var auto_left: u32 = 0;
var killed_left: u32 = 0;
/// Frames since the player finished (results follow).
var finished_ticks: u32 = 0;
const results_after: u32 = 150;
/// Crash starts since boot (debug_crashes); last message seen (sound cues).
var crashes: u32 = 0;
var last_msg: world.Message = .none;
var last_lap: u8 = 0;
var finish_note: u32 = 0;
/// Attract demo: frames left of its scripted B hold.
var attract_b: u32 = 0;

pub const race_machines: u8 = 11;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    sprites.init();
    sprites.reset_effects();
    render.set_track(&track.cold_aisle);
    camera.init(512 << fixed.Q, 512 << fixed.Q, 0);
    camera.cam.height = 96;
    go(.splash);
}

fn go(s: Screen) void {
    screen = s;
    screen_frames = 0;
}

fn current_track() *const track.Track {
    return track.leagues[picked_league].tracks[picked_track];
}

fn new_race(t: *const track.Track) void {
    render.set_track(t);
    hud.init_minimap(t);
    hills.init(t);
    render.hills_on = true;
    sim.reset(t, race_machines);
    history.reset();
    sprites.reset_effects();
    const p = &world.w.machines[world.player];
    camera.follow(p.x, p.y, p.heading, true);
    snapshot = tuning.snapshot_max;
    snapshot_refill = 0;
    rewinding = false;
    hitstop_left = 0;
    auto_left = 0;
    killed_left = 0;
    finished_ticks = 0;
    results.rewinds = 0;
    last_msg = .none;
    last_lap = 0;
    finish_note = 0;
    attract_b = 0;
    go(.race);
}

/// Most replay simulate calls in one frame since boot (debug_replay_max).
var replay_max: u32 = 0;

pub fn update() void {
    input.update(read_controls());
    history.replay_calls = 0;
    const t0 = cart.micros_since_boot();
    switch (screen) {
        .splash => splash_frame(),
        .title => title_frame(),
        .main_menu, .league_pick, .track_pick => menu_frame(),
        .race => race_frame(),
        .pause => pause_frame(),
        .results => results_frame(),
        .standings => standings_frame(),
    }
    render_us = @truncate(cart.micros_since_boot() - t0);
    replay_max = @max(replay_max, history.replay_calls);
    if (build_options.debug_overlay) draw_overlay();
    frame +%= 1;
    screen_frames +%= 1;
    if (cart.is_wasm) present_wasm();
}

fn any_pressed() bool {
    return input.pressed(.start) or input.pressed(.a) or input.pressed(.b) or input.pressed(.select) or
        input.pressed(.up) or input.pressed(.down) or input.pressed(.left) or input.pressed(.right);
}

// --- Splash and title -----------------------------------------------------------

fn splash_frame() void {
    menu.draw_splash(screen_frames);
    if (screen_frames >= 120 or input.pressed(.start)) go(.title);
}

/// Title over a slowly turning view of Cold Aisle; 10 s idle starts the attract demo.
fn title_frame() void {
    autopilot = false;
    render.hills_on = false;
    render.frame = frame;
    camera.cam.yaw +%= 24;
    render.draw();
    menu.draw_title(screen_frames);
    if (input.pressed(.start)) {
        sound.menu_confirm();
        go(.main_menu);
    } else if (any_pressed()) {
        screen_frames = 0;
    } else if (screen_frames >= attract_after) start_attract();
}

fn start_attract() void {
    mode = .attract;
    autopilot = true;
    const t = track.tracks[attract_next % track.tracks.len];
    attract_next +%= 1;
    new_race(t);
}

// --- Menus -----------------------------------------------------------------------

fn menu_nav(list: *menu.List) void {
    if (input.pressed(.up)) {
        list.up();
        sound.menu_move();
    }
    if (input.pressed(.down)) {
        list.down();
        sound.menu_move();
    }
}

fn menu_frame() void {
    render.hills_on = false;
    render.frame = frame;
    camera.cam.yaw +%= 8;
    render.draw();
    cart.rect(.{ .x = 0, .y = 28, .width = 160, .height = 72, .fill_color = hud.anti_black });
    switch (screen) {
        .main_menu => {
            menu_nav(&main_list);
            const sound_item: []const u8 = if (sound.enabled) "SOUND: ON" else "SOUND: OFF";
            const machine_item = menu.machine_items[sim.player_character];
            menu.draw_list("SNOUTY ZERO", &.{ "QUICK RACE", "GRAND PRIX", machine_item, sound_item }, &main_list, 36);
            // The machine row cycles with Left/Right too.
            if (main_list.cursor == 2 and (input.pressed(.right) or input.pressed(.left))) {
                sim.player_character = @intCast((sim.player_character + (if (input.pressed(.right)) @as(u8, 1) else 4)) % 5);
                sound.menu_move();
            }
            if (input.pressed(.a) or input.pressed(.start)) {
                sound.menu_confirm();
                switch (main_list.cursor) {
                    0 => {
                        mode = .quick;
                        go(.league_pick);
                    },
                    1 => {
                        mode = .gp;
                        go(.league_pick);
                    },
                    2 => sim.player_character = (sim.player_character + 1) % 5,
                    else => {
                        sound.enabled = !sound.enabled;
                        if (!sound.enabled) sound.stop();
                    },
                }
            }
            if (input.pressed(.b)) go(.title);
        },
        .league_pick => {
            menu_nav(&league_list);
            const names = menu.league_names();
            menu.draw_list(if (mode == .gp) "GRAND PRIX: LEAGUE" else "QUICK RACE: LEAGUE", &names, &league_list, 36);
            if (input.pressed(.a) or input.pressed(.start)) {
                sound.menu_confirm();
                picked_league = league_list.cursor;
                if (mode == .gp) {
                    gp = .{};
                    gp_round = 0;
                    gp_final = false;
                    picked_track = 0;
                    new_race(current_track());
                } else {
                    track_list = .{ .count = @intCast(track.leagues[picked_league].tracks.len) };
                    go(.track_pick);
                }
            }
            if (input.pressed(.b)) go(.main_menu);
        },
        .track_pick => {
            menu_nav(&track_list);
            const l = track.leagues[picked_league];
            var names: [3][]const u8 = undefined;
            for (l.tracks, 0..) |t, i| names[i] = t.name;
            menu.draw_list(l.name, names[0..l.tracks.len], &track_list, 36);
            if (input.pressed(.a) or input.pressed(.start)) {
                sound.menu_confirm();
                picked_track = track_list.cursor;
                new_race(current_track());
            }
            if (input.pressed(.b)) go(.league_pick);
        },
        else => {},
    }
}

// --- Race ------------------------------------------------------------------------

/// Draw the race scene from the current world: floor, machines, then
/// (during a rewind) the scanline dim, then the HUD on top so it stays legible.
fn draw_race() void {
    const p = &world.w.machines[world.player];
    if (free_cam) camera.free_fly() else camera.follow(p.x, p.y, p.heading, false);
    render.shake = p.shake;
    render.frame = frame;
    hud.snapshot_ticks = snapshot;
    hud.rewinding = rewinding or auto_left > 0;
    render.draw();
    sprites.draw_machines();
    if (hud.rewinding) hud.dim_scanlines();
    hud.draw();
}

/// Rewind `ticks` game ticks (bounded by the history); false if nothing to rewind.
fn rewind_by(ticks: u32) bool {
    const w = &world.w;
    const earliest = history.earliest_tick();
    if (w.tick <= earliest) return false;
    const target = if (w.tick - earliest < ticks) earliest else w.tick - ticks;
    return history.restore(target);
}

/// Back to live play after a rewind: collision immunity, and a keyframe so
/// a later restore never replays across this edit.
fn resume_live() void {
    rewinding = false;
    const p = &world.w.machines[world.player];
    p.immune = tuning.immune_ticks;
    p.crash = .none;
    p.hitstop = 0;
    world.w.msg = .none;
    world.w.msg_ticks = 0;
    history.checkpoint();
}

fn race_frame() void {
    const w = &world.w;
    const p = &w.machines[world.player];

    if (mode == .attract) {
        if (any_pressed()) {
            autopilot = false;
            go(.title);
            return;
        }
    } else if (input.pressed(.start) and p.active and w.phase != .finished and hitstop_left == 0 and auto_left == 0) {
        pause_list = .{ .count = 4 };
        go(.pause);
        draw_race();
        return;
    }

    // Crash hit-stop: the world freezes with the cause named (SPEC 5.4).
    if (hitstop_left > 0) {
        hitstop_left -= 1;
        draw_race();
        if (hitstop_left == 0) {
            if (snapshot >= tuning.auto_rewind_cost and rewind_possible()) {
                snapshot -= tuning.auto_rewind_cost;
                auto_left = tuning.auto_rewind_ticks;
                results.rewinds += 1;
            } else {
                p.active = false;
                w.msg = .killed;
                w.msg_ticks = 255;
                killed_left = 60;
            }
        }
        return;
    }
    // Automatic rewind playback: 4 ticks a frame, dimmed.
    if (auto_left > 0) {
        const k = @min(auto_left, tuning.auto_rewind_per_frame);
        if (!rewind_by(k)) auto_left = 0 else auto_left -= k;
        history.prefill(tuning.prefill_per_frame);
        if (auto_left == 0) resume_live();
        draw_race();
        return;
    }
    // JOB KILLED: the message holds, then the results.
    if (killed_left > 0) {
        killed_left -= 1;
        draw_race();
        if (killed_left == 0) go(.results);
        return;
    }

    // Hold-B rewind (SPEC 5.4), 2 ticks a frame while the bar lasts.
    const want_b = if (mode == .attract) attract_b > 0 else input.held(.b);
    if (want_b and w.phase == .racing and snapshot >= tuning.rewind_per_frame and rewind_possible()) {
        if (!rewinding) {
            rewinding = true;
            results.rewinds += 1;
        }
        if (rewind_by(tuning.rewind_per_frame)) snapshot -= tuning.rewind_per_frame;
        history.prefill(tuning.prefill_per_frame);
        if (attract_b > 0) attract_b -= 1;
        draw_race();
        return;
    }
    if (rewinding) resume_live();
    if (attract_b > 0) attract_b -= 1;

    // A live tick.
    var buttons: world.Buttons = @bitCast(@as(u16, @bitCast(input.current)));
    if (autopilot) {
        buttons = ai.drive(p, 0);
        // The demo shows the mechanic: a 40-tick rewind every 9 s once racing.
        if (mode == .attract and w.phase == .racing and w.tick > 300 and w.tick % 540 == 0 and snapshot >= 80) attract_b = 20;
    }
    if (free_cam) buttons = .{};
    if (w.phase == .racing) history.record(buttons);
    sim.simulate(buttons);
    sprites.tick_effects();

    // Crash start: freeze for the hit-stop (the sim's own reset path is for rivals).
    if (p.crash != .none and p.active) {
        crashes += 1;
        hitstop_left = tuning.hitstop_ticks;
    }
    // Snapshot bar refill: 1 tick per 10 game ticks, full at the start line.
    if (w.phase == .racing and snapshot < tuning.snapshot_max) {
        snapshot_refill += 1;
        if (snapshot_refill >= tuning.snapshot_refill_every) {
            snapshot_refill = 0;
            snapshot += 1;
        }
    }
    if (p.lap != last_lap) {
        if (p.lap > last_lap) snapshot = tuning.snapshot_max;
        last_lap = p.lap;
    }
    sound_cues();
    if (w.phase == .finished) {
        finished_ticks += 1;
        if (finished_ticks >= results_after or input.pressed(.start)) {
            if (mode == .attract) {
                autopilot = false;
                go(.title);
                return;
            }
            go(.results);
        }
    }
    draw_race();
}

fn rewind_possible() bool {
    return world.w.tick > history.earliest_tick();
}

/// Tones on message changes and rail hits (SPEC 9).
fn sound_cues() void {
    const w = &world.w;
    const p = &w.machines[world.player];
    if (w.msg != last_msg) {
        switch (w.msg) {
            .three, .two, .one => sound.countdown_beep(),
            .deploy => sound.deploy(),
            .committed => {
                sound.finish(0);
                finish_note = 8;
            },
            else => {},
        }
        last_msg = w.msg;
    }
    if (finish_note > 0) {
        finish_note -= 1;
        if (finish_note == 1) sound.finish(1);
    }
    if (p.shake == 4 and p.crash == .none) sound.rail_click();
}

// --- Pause -----------------------------------------------------------------------

fn pause_frame() void {
    draw_race();
    cart.rect(.{ .x = 24, .y = 30, .width = 112, .height = 70, .fill_color = hud.anti_black });
    menu_nav(&pause_list);
    const sound_item: []const u8 = if (sound.enabled) "SOUND: ON" else "SOUND: OFF";
    menu.draw_list("PAUSED", &.{ "RESUME", "RESTART", "QUIT", sound_item }, &pause_list, 34);
    if (input.pressed(.b)) {
        go(.race);
        return;
    }
    if (input.pressed(.a) or input.pressed(.start)) {
        sound.menu_confirm();
        switch (pause_list.cursor) {
            0 => go(.race),
            1 => new_race(sim.current),
            2 => {
                autopilot = false;
                go(.main_menu);
            },
            else => {
                sound.enabled = !sound.enabled;
                if (!sound.enabled) sound.stop();
            },
        }
    }
}

// --- Results and Grand Prix -------------------------------------------------------

fn results_frame() void {
    results.draw(screen_frames);
    if (input.pressed(.start) or input.pressed(.a)) {
        sound.menu_confirm();
        if (mode == .gp) {
            award_points();
            gp_final = gp_round + 1 >= track.leagues[picked_league].tracks.len;
            go(.standings);
        } else {
            go(.main_menu);
        }
    }
}

/// Points 9/6/4/3/2 by rank for SNOUTY and the four rivals (SPEC 8).
fn award_points() void {
    const w = &world.w;
    for (0..5) |i| {
        const m = &w.machines[i];
        const r: usize = if (i == 0 and !m.active) 0 else m.rank;
        gp.points[i] += menu.points_for_rank[@min(r, 5)];
    }
}

fn standings_frame() void {
    menu.draw_standings(&gp, track.leagues[picked_league].name, gp_final, screen_frames);
    if (input.pressed(.start) or input.pressed(.a)) {
        sound.menu_confirm();
        if (gp_final) {
            go(.main_menu);
        } else {
            gp_round += 1;
            picked_track = gp_round;
            new_race(current_track());
        }
    }
}

// --- Overlay and debug --------------------------------------------------------------

/// -Ddebug_overlay=true: "uuuuuus" top-right under the rank.
fn draw_overlay() void {
    var buf: [8]u8 = "      us".*;
    put_uint(buf[0..6], @min(render_us, 999_999));
    cart.text(.{
        .str = &buf,
        .x = 160 - 8 * @as(i32, buf.len),
        .y = 13,
        .text_color = .{ .r = 31, .g = 63, .b = 31 },
        .background_color = .{ .r = 0, .g = 0, .b = 0 },
    });
}

/// Right-aligned decimal into `out`, space-padded. `v` must fit.
fn put_uint(out: []u8, v: u32) void {
    var n = v;
    var i = out.len;
    while (i > 0) {
        i -= 1;
        out[i] = @intCast('0' + n % 10);
        n /= 10;
        if (n == 0) break;
    }
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        @export(&debug_frame, .{ .name = "debug_frame" });
        @export(&debug_render_us, .{ .name = "debug_render_us" });
        @export(&debug_pixel_checksum, .{ .name = "debug_pixel_checksum" });
        @export(&debug_cam_x, .{ .name = "debug_cam_x" });
        @export(&debug_cam_y, .{ .name = "debug_cam_y" });
        @export(&debug_cam_yaw, .{ .name = "debug_cam_yaw" });
        @export(&debug_cam_height, .{ .name = "debug_cam_height" });
        @export(&debug_tile_under, .{ .name = "debug_tile_under" });
        @export(&debug_px, .{ .name = "debug_px" });
        @export(&debug_py, .{ .name = "debug_py" });
        @export(&debug_heading, .{ .name = "debug_heading" });
        @export(&debug_speed, .{ .name = "debug_speed" });
        @export(&debug_lap, .{ .name = "debug_lap" });
        @export(&debug_progress, .{ .name = "debug_progress" });
        @export(&debug_phase, .{ .name = "debug_phase" });
        @export(&debug_tick, .{ .name = "debug_tick" });
        @export(&debug_thermal, .{ .name = "debug_thermal" });
        @export(&debug_crashes, .{ .name = "debug_crashes" });
        @export(&debug_best_lap, .{ .name = "debug_best_lap" });
        @export(&debug_set_autopilot, .{ .name = "debug_set_autopilot" });
        @export(&debug_set_freecam, .{ .name = "debug_set_freecam" });
        @export(&debug_rank, .{ .name = "debug_rank" });
        @export(&debug_screen, .{ .name = "debug_screen" });
        @export(&debug_machine_px, .{ .name = "debug_machine_px" });
        @export(&debug_machine_py, .{ .name = "debug_machine_py" });
        @export(&debug_machine_lap, .{ .name = "debug_machine_lap" });
        @export(&debug_snapshot, .{ .name = "debug_snapshot" });
        @export(&debug_rewinds, .{ .name = "debug_rewinds" });
        @export(&debug_rewinding, .{ .name = "debug_rewinding" });
        @export(&debug_active, .{ .name = "debug_active" });
        @export(&debug_sound, .{ .name = "debug_sound" });
        @export(&debug_mode, .{ .name = "debug_mode" });
        @export(&debug_track, .{ .name = "debug_track" });
        @export(&debug_gp_points, .{ .name = "debug_gp_points" });
        @export(&debug_start_race, .{ .name = "debug_start_race" });
        @export(&debug_force_crash, .{ .name = "debug_force_crash" });
        @export(&debug_rebuilds, .{ .name = "debug_rebuilds" });
        @export(&debug_replay_calls, .{ .name = "debug_replay_calls" });
        @export(&debug_replay_max, .{ .name = "debug_replay_max" });
        @export(&debug_set_machine, .{ .name = "debug_set_machine" });
        @export(&debug_machine, .{ .name = "debug_machine" });
    }
}

fn debug_frame() callconv(.c) u32 {
    return frame;
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}
fn debug_cam_x() callconv(.c) u32 {
    return @bitCast(camera.cam.x >> fixed.Q);
}
fn debug_cam_y() callconv(.c) u32 {
    return @bitCast(camera.cam.y >> fixed.Q);
}
fn debug_cam_yaw() callconv(.c) u32 {
    return camera.cam.yaw;
}
fn debug_cam_height() callconv(.c) u32 {
    return @bitCast(camera.cam.height);
}
/// Attribute of the tile under the player.
fn debug_tile_under() callconv(.c) u32 {
    const p = &world.w.machines[world.player];
    return @backingInt(sim.current.attr_at(p.x >> fixed.Q, p.y >> fixed.Q));
}
fn debug_px() callconv(.c) u32 {
    return @bitCast(world.w.machines[world.player].x >> fixed.Q);
}
fn debug_py() callconv(.c) u32 {
    return @bitCast(world.w.machines[world.player].y >> fixed.Q);
}
fn debug_heading() callconv(.c) u32 {
    return world.w.machines[world.player].heading;
}
/// Player speed in 1/100 px per tick.
fn debug_speed() callconv(.c) u32 {
    return @bitCast((sim.speed(&world.w.machines[world.player]) * 100) >> fixed.Q);
}
fn debug_lap() callconv(.c) u32 {
    return world.w.machines[world.player].lap;
}
fn debug_progress() callconv(.c) u32 {
    return world.w.machines[world.player].progress;
}
/// 0 countdown, 1 racing, 2 finished.
fn debug_phase() callconv(.c) u32 {
    return @backingInt(world.w.phase);
}
fn debug_tick() callconv(.c) u32 {
    return world.w.tick;
}
fn debug_thermal() callconv(.c) u32 {
    return @bitCast(@as(i32, world.w.machines[world.player].thermal));
}
fn debug_crashes() callconv(.c) u32 {
    return crashes;
}
/// --call debug_set_autopilot:1 hands the player to the centerline autopilot.
fn debug_set_autopilot(v: u32) callconv(.c) void {
    autopilot = v != 0;
}
/// --call debug_set_freecam:1 switches to the M0 free camera (Left/Right
/// yaw, A forward, B back, Up/Down height); the race keeps running unsteered.
fn debug_set_freecam(v: u32) callconv(.c) void {
    free_cam = v != 0;
}
/// --call debug_start_race:N skips the splash and menus straight into a
/// Quick Race on track N (0..5 in `track.tracks` order).
fn debug_start_race(n: u32) callconv(.c) void {
    mode = .quick;
    var k: usize = 0;
    for (track.leagues, 0..) |l, li| {
        for (l.tracks, 0..) |_, ti| {
            if (k == n % track.tracks.len) {
                picked_league = @intCast(li);
                picked_track = @intCast(ti);
            }
            k += 1;
        }
    }
    new_race(current_track());
}
/// --call-at T debug_force_crash: the player falls off the track (SEGMENT
/// FAULT) on the next frame, for scripting the crash auto-rewind.
fn debug_force_crash() callconv(.c) u32 {
    const p = &world.w.machines[world.player];
    if (p.active and p.crash == .none and screen == .race) sim.crash(p, .fall);
    return world.w.tick;
}
/// --call debug_set_machine:N picks the player's physics character (0 SNOUTY, 1..4 the rivals').
fn debug_set_machine(n: u32) callconv(.c) void {
    sim.player_character = @intCast(n % 5);
}
fn debug_machine() callconv(.c) u32 {
    return sim.player_character;
}
/// Keyframe rebuilds (the slow restore path) since the race started.
fn debug_rebuilds() callconv(.c) u32 {
    return history.rebuilds;
}
/// Simulate calls made by restores and prefills in the last frame; the most since boot.
fn debug_replay_calls() callconv(.c) u32 {
    return history.replay_calls;
}
fn debug_replay_max() callconv(.c) u32 {
    return replay_max;
}
/// Player rank 1..5 (0 before the first tick or when retired).
fn debug_rank() callconv(.c) u32 {
    return world.w.machines[world.player].rank;
}
/// Screen: 0 splash, 1 title, 2 main menu, 3 league pick, 4 track pick, 5 race, 6 pause, 7 results, 8 standings.
fn debug_screen() callconv(.c) u32 {
    return @backingInt(screen);
}
fn debug_machine_px(i: u32) callconv(.c) u32 {
    return @bitCast(world.w.machines[i % world.machine_count].x >> fixed.Q);
}
fn debug_machine_py(i: u32) callconv(.c) u32 {
    return @bitCast(world.w.machines[i % world.machine_count].y >> fixed.Q);
}
fn debug_machine_lap(i: u32) callconv(.c) u32 {
    return world.w.machines[i % world.machine_count].lap;
}
fn debug_best_lap() callconv(.c) u32 {
    return world.w.machines[world.player].best_lap;
}
/// Snapshot bar in ticks (0..180).
fn debug_snapshot() callconv(.c) u32 {
    return snapshot;
}
/// Rewinds (hold-B holds and auto rewinds) this race.
fn debug_rewinds() callconv(.c) u32 {
    return results.rewinds;
}
/// 1 during a hold-B rewind, 2 during an auto-rewind playback, 3 in the crash hit-stop, 4 JOB KILLED.
fn debug_rewinding() callconv(.c) u32 {
    if (hitstop_left > 0) return 3;
    if (auto_left > 0) return 2;
    if (killed_left > 0) return 4;
    return @intFromBool(rewinding);
}
fn debug_active() callconv(.c) u32 {
    return @intFromBool(world.w.machines[world.player].active);
}
fn debug_sound() callconv(.c) u32 {
    return @intFromBool(sound.enabled);
}
/// 0 quick, 1 gp, 2 attract.
fn debug_mode() callconv(.c) u32 {
    return @backingInt(mode);
}
/// Index of the current track in `track.tracks`.
fn debug_track() callconv(.c) u32 {
    for (track.tracks, 0..) |t, i| {
        if (t == sim.current) return @intCast(i);
    }
    return 0xFFFF;
}
/// SNOUTY's Grand Prix points.
fn debug_gp_points() callconv(.c) u32 {
    return gp.points[0];
}
/// Sum of all framebuffer words, for render regression tests.
fn debug_pixel_checksum() callconv(.c) u32 {
    var sum: u32 = 0;
    for (cart.framebuffer) |*column| {
        for (column) |px| sum +%= @as(u16, @bitCast(px));
    }
    return sum;
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls.
pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim (see snouty-bugs CLAUDE.md): upstream's wasm platform never
/// presents, and the web simulator reads a legacy framebuffer at 0x20 with
/// red and blue swapped relative to DisplayColor. Hardware compiles none of this.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const c = src.to_color();
            dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
        }
    }
}

//! Snouty Zero: an F-Zero style Mode 7 hover racer on a planet-sized AI
//! datacenter. SPEC.md is the design, PLAN.md the milestone contract.
//! M3: splash, title, attract, menus, Quick Race and Grand Prix, the hold-B
//! rewind and the crash auto-rewind on the snapshot bar, pause, sound.
//! M6: LINK RACE, two badges in lockstep over the link cable (the lobby,
//! the link race loop, its pause and results; `link_race.zig`).
const std = @import("std");
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
const link = @import("link");
const lockstep = @import("lockstep");
const link_race = @import("link_race.zig");
const link_ui = @import("link_ui.zig");

comptime {
    cart.export_start_code();
}

/// Screens (SPEC 8).
pub const Screen = enum(u8) { splash, title, main_menu, league_pick, track_pick, race, pause, results, standings, lobby };
var screen: Screen = .splash;
/// Why the race runs: a Quick Race, a Grand Prix round, the attract demo,
/// or a link race (M6).
const Mode = enum { quick, gp, attract, link };
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
var main_list = menu.List{ .count = 5 };
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
var ko_note: u32 = 0;
/// Attract demo: frames left of its scripted B hold.
var attract_b: u32 = 0;

pub const race_machines: u8 = 11;

// Link race (M6, link_race.zig). The link starts when LINK RACE opens and
// is pumped only on its screens and through a link race: solo play never
// touches it.
const Net = lockstep.Lockstep(link.Badge, link_race.G);
var lnk: Net = undefined;
var lnk_started: bool = false;
/// A link race runs (from the GO to leaving the results); `fake_link`: a
/// made-up one in the simulator (`debug_link_race`), no lockstep behind it.
var linked: bool = false;
var fake_link: bool = false;
/// The lobby: the host's row and track, this badge's machine and mark.
var lobby_cursor: u8 = 0;
var lobby_track: u8 = 0;
var link_pick: u8 = 0;
var link_ready: bool = false;
/// The race ended on a desync; the PEER LEFT notice's frames left (shown once).
var desynced: bool = false;
var left_note: u32 = 0;
var left_shown: bool = false;
/// Pause RESUME: send a Start edge (a frame without Start first if needed).
var resume_pending: bool = false;
var last_byte: u8 = 0;
/// Frames of the link race without a lockstep tick (debug_link_waits).
var link_waits: u32 = 0;
/// The time at the top of this update (the pump loop runs to 14 ms past it).
var frame_t0: u64 = 0;
/// Debug (wasm, where the link is offline): a made-up lobby
/// (`debug_link_view`) and race notice (`debug_link_notice`).
var fake_view: u32 = 0;
var fake_notice: u32 = 0;
/// The main menu's note under LINK RACE in the simulator (frames left).
var link_note: u32 = 0;

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

/// The track's floor, minimap and hills for a race on it.
fn prepare_race(t: *const track.Track) void {
    render.set_track(t);
    hud.init_minimap(t);
    hills.init(t);
    render.hills_on = true;
}

fn new_race(t: *const track.Track) void {
    prepare_race(t);
    sim.reset(t, race_machines);
    world.view = world.player;
    begin_race();
}

/// The race meta-state for a World just reset (solo or link).
fn begin_race() void {
    hud.show_snapshot = !linked;
    history.reset();
    sprites.reset_effects();
    const p = &world.w.machines[world.view];
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
    ko_note = 0;
    attract_b = 0;
    go(.race);
}

/// Most replay simulate calls in one frame since boot (debug_replay_max).
var replay_max: u32 = 0;

pub fn update() void {
    defer sound.update();
    input.update(read_controls());
    history.replay_calls = 0;
    const t0 = cart.micros_since_boot();
    frame_t0 = t0;
    switch (screen) {
        .splash => splash_frame(),
        .title => title_frame(),
        .main_menu, .league_pick, .track_pick => menu_frame(),
        .race => race_frame(),
        .pause => pause_frame(),
        .results => results_frame(),
        .standings => standings_frame(),
        .lobby => lobby_frame(),
    }
    engine_cue();
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
    // The main menu's box runs one line longer for the machine's handling blurb.
    cart.rect(.{ .x = 0, .y = 28, .width = 160, .height = if (screen == .main_menu) 96 else 72, .fill_color = hud.anti_black });
    switch (screen) {
        .main_menu => {
            menu_nav(&main_list);
            const sound_item: []const u8 = if (sound.enabled) "SOUND: ON" else "SOUND: OFF";
            const machine_item = menu.machine_items[sim.player_character];
            // LINK RACE is greyed where there is no link (the simulator).
            const no_link = !link_possible();
            menu.draw_list_dim("SNOUTY ZERO", &.{ "QUICK RACE", "GRAND PRIX", "LINK RACE", machine_item, sound_item }, &main_list, 36, if (no_link) @as(?usize, 2) else null);
            link_note -|= 1;
            if (main_list.cursor == 2) {
                if (no_link) {
                    hud.centered("NO LINK IN SIMULATOR", 112, if (link_note > 0) hud.coral else hud.dim);
                } else hud.centered("TWO BADGES, ONE CABLE", 112, hud.orange);
            } else hud.centered(menu.machine_blurbs[sim.player_character], 112, hud.orange);
            // The machine row cycles with Left/Right too.
            if (main_list.cursor == 3 and (input.pressed(.right) or input.pressed(.left))) {
                sim.player_character = @intCast((sim.player_character + (if (input.pressed(.right)) @as(u8, 1) else 4)) % 5);
                sound.menu_move();
            }
            if (input.pressed(.a) or input.pressed(.start)) {
                if (main_list.cursor != 2 or !no_link) sound.menu_confirm();
                switch (main_list.cursor) {
                    0 => {
                        mode = .quick;
                        go(.league_pick);
                    },
                    1 => {
                        mode = .gp;
                        go(.league_pick);
                    },
                    2 => if (no_link) {
                        link_note = 60;
                    } else open_lobby(),
                    3 => sim.player_character = (sim.player_character + 1) % 5,
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
    const p = &world.w.machines[world.view];
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
    const p = &world.w.machines[world.view];
    p.immune = tuning.immune_ticks;
    p.crash = .none;
    p.hitstop = 0;
    world.w.msg[0] = .none;
    world.w.msg_ticks[0] = 0;
    history.checkpoint();
}

fn race_frame() void {
    if (linked) return link_race_frame();
    const w = &world.w;
    const p = &w.machines[world.view];

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
                w.msg[0] = .killed;
                w.msg_ticks[0] = 255;
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
    const p = &w.machines[world.view];
    const msg = w.msg[w.slot_of(world.view) orelse 0];
    if (msg != last_msg) {
        switch (msg) {
            .three, .two, .one => sound.countdown_beep(),
            .deploy => sound.deploy(),
            .committed => {
                sound.finish(0);
                finish_note = 8;
            },
            .ko => {
                sound.ko(0);
                ko_note = 6;
            },
            else => {},
        }
        last_msg = msg;
    }
    if (finish_note > 0) {
        finish_note -= 1;
        if (finish_note == 1) sound.finish(1);
    }
    if (ko_note > 0) {
        ko_note -= 1;
        if (ko_note == 1) sound.ko(1);
    }
    if (p.shake == 4 and p.crash == .none) sound.rail_click();
}

/// The engine drone (SPEC 9): the player's machine while racing, silent
/// everywhere else, in the crash hit-stop, after JOB KILLED and in the
/// attract demo.
fn engine_cue() void {
    const w = &world.w;
    const p = &w.machines[world.view];
    if (screen != .race or mode == .attract or hitstop_left > 0 or killed_left > 0 or !p.active) return sound.engine_off();
    sound.engine(.{
        .speed = sim.speed(p),
        .throttle = (input.held(.a) or autopilot) and !p.finished,
        .boost = p.boost > 0,
        .air = p.hop > 0,
        .rough = p.on_throttled,
        .grid = w.phase == .countdown,
        .rewind = rewinding or auto_left > 0,
        .frame = frame,
    });
}

// --- Pause -----------------------------------------------------------------------

fn pause_frame() void {
    if (linked) return link_pause_frame();
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
    if (linked) return link_results_frame();
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

// --- Link race (M6: link_race.zig, PLAN "M6 Link race") ------------------------------

/// LINK RACE can run: a badge (the simulator has no link).
fn link_possible() bool {
    return !cart.is_wasm;
}

/// LINK RACE from the main menu: the link starts on its first opening
/// (solo play never touches it), then the lobby.
fn open_lobby() void {
    if (!lnk_started) {
        lnk = Net.init(link.Badge.init(.{}, link_race.app_id, cart.rand()));
        lnk_started = true;
    }
    link_pick = sim.player_character;
    link_ready = false;
    go(.lobby);
}

/// The top of a link frame: run the link.
fn pump_top() void {
    if (lnk_started and !fake_link) lnk.pump(cart.micros_since_boot());
}

/// After drawing, while a race runs: keep pumping until
/// `tuning.link_pump_until_us` into the frame (the vsync wait is the one
/// stretch where nothing reads the receive FIFO), retrying a stalled step
/// (`ticked`; null when there is nothing to retry).
fn pump_loop(ticked: ?*bool) void {
    if (cart.is_wasm or fake_link or !lnk_started) return;
    while (lnk.busy() and cart.micros_since_boot() -% frame_t0 < tuning.link_pump_until_us) {
        lnk.pump(cart.micros_since_boot());
        const t = ticked orelse continue;
        if (!t.* and world.w.phase != .finished) {
            t.* = lnk.step(&world.w);
            if (t.* and !lnk.paused and screen != .results) after_tick();
        }
    }
}

/// What the lobby shows: the link's, or the made-up one of `debug_link_view`.
fn lobby_view() link_ui.View {
    if (fake_view != 0) return fake_lobby();
    const host = lnk.role == .host;
    const r = lnk.rules();
    return .{
        .state = lnk.state(),
        .role = lnk.role,
        .cable = @backingInt(lnk.link.cable()),
        .partner_app = lnk.link.partner_app,
        .track = if (host) lobby_track else if (r) |x| x[0] else null,
        .pick = link_pick,
        .ready = link_ready,
        .peer_pick = lnk.peer_pick(),
        .peer_ready = lnk.peer_ready(),
        .can_go = lnk.can_go(),
    };
}

/// The LINK RACE lobby (SPEC 8.1): the cable state until a partner
/// running Snouty Zero answers, then the host's TRACK row (Up/Down a row,
/// Left/Right its value; the guest sees it live), the MACHINE row, A
/// ready, B takes the mark back or leaves for the main menu (the link
/// stops being pumped; the partner sees it gone 2 s later), the host's
/// Start goes once both are ready.
fn lobby_frame() void {
    pump_top();
    if (lnk.take_started()) return start_link_race();
    render.hills_on = false;
    render.frame = frame;
    camera.cam.yaw +%= 8;
    render.draw();
    var v = lobby_view();
    if (input.pressed(.b)) {
        if (link_ready) {
            link_ready = false;
        } else {
            lnk.set_pick(link_pick, false);
            fake_view = 0;
            go(.main_menu);
            return;
        }
    }
    if (v.state == .lobby) {
        const host = v.role == .host;
        if (host and (input.pressed(.up) or input.pressed(.down))) {
            lobby_cursor = (lobby_cursor + 1) % link_ui.row_count;
            sound.menu_move();
        }
        const on_track = host and lobby_cursor == @backingInt(link_ui.Row.track);
        const step: i32 = @as(i32, @intFromBool(input.pressed(.right))) - @as(i32, @intFromBool(input.pressed(.left)));
        if (step != 0) {
            if (on_track) {
                const n: i32 = @intCast(track.tracks.len);
                lobby_track = @intCast(@mod(@as(i32, lobby_track) + step, n));
                sound.menu_move();
            } else if (!link_ready) {
                link_pick = @intCast(@mod(@as(i32, link_pick) + step, link_race.pick_count));
                sound.menu_move();
            }
        }
        if (input.pressed(.a) and !link_ready) {
            link_ready = true;
            sound.menu_confirm();
        }
        if (host) lnk.set_rules(.{lobby_track});
        lnk.set_pick(link_pick, link_ready);
        if (host and input.pressed(.start) and !input.held(.select) and lnk.can_go()) {
            sound.menu_confirm();
            _ = lnk.go(cart.micros_since_boot());
        }
        v = lobby_view();
    }
    link_ui.draw_lobby(&v, lobby_cursor, frame);
    if (lnk.take_started()) return start_link_race();
}

/// Both badges, once per race (`take_started`): the World from the agreed
/// track, picks and seed, this badge's machine followed.
fn start_link_race() void {
    const rules = lnk.rules() orelse [1]u8{lobby_track};
    prepare_race(link_race.track_of(rules));
    link_race.reset(&world.w, rules, lnk.picks(), lnk.seed());
    world.view = link_race.machine_of(lnk.local_slot());
    fake_link = false;
    begin_link_race();
}

fn begin_link_race() void {
    mode = .link;
    linked = true;
    link_ready = false;
    desynced = false;
    left_note = 0;
    left_shown = false;
    resume_pending = false;
    last_byte = 0;
    link_waits = 0;
    begin_race();
}

/// This badge's input byte: the buttons (the autopilot's in previews);
/// nothing once its machine has finished (no Start reaches the race then,
/// so a finished badge never pauses its partner).
fn link_byte() u8 {
    const m = &world.w.machines[world.view];
    if (m.finished) return 0;
    if (autopilot) return link_race.byte_of(ai.drive_human(m, world.view));
    return link_race.byte_of(@bitCast(@as(u16, @bitCast(input.current))));
}

/// What a tick that ran the World brings on the badge (as a solo frame
/// after `simulate`): effects and the sound cues.
fn after_tick() void {
    sprites.tick_effects();
    sound_cues();
}

/// `debug_link_race`: both humans' bytes without a lockstep. With the
/// autopilot on, slot 0 drives plainly and slot 1 with taps whichever
/// machine is viewed, so the two views show the same race.
fn fake_tick() void {
    const w = &world.w;
    const me: u1 = if (world.view == world.guest) 1 else 0;
    var in: [2]world.Buttons = undefined;
    for (0..2) |k| {
        const s: u1 = @intCast(k);
        const h = w.humans[s];
        var b = ai.drive_human(&w.machines[h], h);
        if (s == 1) {
            var r = w.tick *% 2_654_435_761 +% 77;
            r ^= r >> 15;
            if (r % 53 == 0) b.left = !b.left;
            if (r % 89 == 0) b.right = !b.right;
        }
        if (s == me and !autopilot) b = link_race.buttons_of(link_byte());
        in[s] = b;
    }
    sim.simulate_humans(in);
}

/// A link race frame (docs/LOCKSTEP.md): pump, submit this frame's byte,
/// step one tick if both bytes are here, draw, then pump and retry until
/// 14 ms into the frame. Once the World is finished no input reaches it
/// (finished humans drive on their AI), so each badge runs it on alone.
fn link_race_frame() void {
    const w = &world.w;
    pump_top();
    if (!fake_link and lnk.state() == .desync) return end_desync();
    if (fake_link and fake_notice == 3) return end_desync();
    const me = &w.machines[world.view];
    if (!fake_link and lnk.paused and !me.finished) {
        pause_list = .{ .count = 3 };
        go(.pause);
        return link_pause_frame();
    }
    var ticked = false;
    if (w.phase == .finished) {
        sim.simulate_humans(.{ .{}, .{} });
        ticked = true;
        after_tick();
    } else if (fake_link) {
        fake_tick();
        ticked = true;
        after_tick();
    } else {
        const byte = link_byte();
        lnk.submit(cart.micros_since_boot(), byte);
        last_byte = byte;
        ticked = lnk.step(w);
        if (ticked and !lnk.paused) after_tick();
    }
    // This badge's human home: its results follow (the race may go on
    // for the partner; the results keep the lockstep running).
    if (me.finished) {
        finished_ticks += 1;
        if (finished_ticks >= results_after or input.pressed(.start)) go(.results);
    }
    draw_race();
    link_notices();
    pump_loop(&ticked);
    if (!ticked) link_waits += 1;
}

/// WAITING FOR PEER while the partner's bytes are late; PEER LEFT, AI
/// DRIVING for a while once it has gone (not if its machine had finished).
fn link_notices() void {
    if (fake_link) return link_ui.draw_notice(switch (fake_notice) {
        1 => .waiting,
        2 => .peer_left,
        else => .none,
    }, .unplugged, frame);
    const st = lnk.state();
    if (st == .peer_left and !left_shown) {
        left_shown = true;
        const peer = world.w.humans[lnk.local_slot() ^ 1];
        if (peer != world.no_human and !world.w.machines[peer].finished) left_note = tuning.link_left_note;
    }
    const k: link_ui.Notice = if (st == .waiting) .waiting else if (left_note > 0) .peer_left else .none;
    left_note -|= 1;
    link_ui.draw_notice(k, lnk.left, frame);
    if (lnk.paused and screen == .race) hud.centered("PEER PAUSED", 20, hud.white);
}

/// The shared pause: either badge's Start paused both on one tick. Only
/// Start reaches the race while paused (it resumes both); RESUME or B
/// sends a Start edge; QUIT leaves (the partner's AI takes this machine).
/// The lockstep's ticks run on, without the World.
fn link_pause_frame() void {
    pump_top();
    if (lnk.state() == .desync) return end_desync();
    var byte = link_byte() & link_race.bit_start;
    if (resume_pending) {
        if (last_byte & link_race.bit_start != 0) {
            byte = 0;
        } else {
            byte = link_race.bit_start;
            resume_pending = false;
        }
    }
    lnk.submit(cart.micros_since_boot(), byte);
    last_byte = byte;
    var ticked = lnk.step(&world.w);
    if (ticked and !lnk.paused) after_tick();
    draw_race();
    cart.rect(.{ .x = 24, .y = 30, .width = 112, .height = 58, .fill_color = hud.anti_black });
    menu_nav(&pause_list);
    const sound_item: []const u8 = if (sound.enabled) "SOUND: ON" else "SOUND: OFF";
    menu.draw_list("PAUSED", &.{ "RESUME", "QUIT", sound_item }, &pause_list, 34);
    if (input.pressed(.b)) resume_pending = true;
    if (input.pressed(.a)) {
        sound.menu_confirm();
        switch (pause_list.cursor) {
            0 => resume_pending = true,
            1 => return leave_link(),
            else => {
                sound.enabled = !sound.enabled;
                if (!sound.enabled) sound.stop();
            },
        }
    }
    if (!lnk.paused) go(.race);
    link_notices();
    pump_loop(&ticked);
}

/// The link results: both humans. The lockstep keeps running underneath
/// while the partner still races (its row updates); A goes back to the
/// lobby on this badge (the partner, if still racing, sees PEER LEFT with
/// this badge's machine already home).
fn link_results_frame() void {
    const w = &world.w;
    pump_top();
    var ticked = true;
    if (w.phase != .finished and !desynced) {
        if (fake_link) {
            fake_tick();
        } else if (lnk.state() == .desync) {
            desynced = true;
        } else {
            lnk.submit(cart.micros_since_boot(), 0);
            ticked = lnk.step(w);
        }
    }
    results.draw_link(screen_frames, if (world.view == world.guest) 1 else 0, desynced);
    if (input.pressed(.a) or (input.pressed(.start) and !input.held(.select))) {
        sound.menu_confirm();
        return leave_link();
    }
    pump_loop(&ticked);
}

/// A desync (the Worlds' hashes differ; `step` has stopped): the results
/// with DESYNC over them, then the lobby.
fn end_desync() void {
    desynced = true;
    go(.results);
    results.draw_link(screen_frames, if (world.view == world.guest) 1 else 0, true);
}

/// Leave the link race (QUIT, the results, after a desync): the partner
/// hears it (its AI takes this machine if it still races), back to the
/// lobby.
fn leave_link() void {
    if (!fake_link) lnk.leave(cart.micros_since_boot());
    linked = false;
    fake_link = false;
    fake_notice = 0;
    desynced = false;
    link_ready = false;
    world.view = world.player;
    hud.show_snapshot = true;
    go(.lobby);
}

/// `debug_link_view` k: 1 searching, 2 the host's lobby, 3 the guest's,
/// 4 another cart, 5 the host with both ready (START: GO), 6 the guest
/// ready, 7 no link (the simulator's own state).
fn fake_lobby() link_ui.View {
    const host = fake_view != 3 and fake_view != 6;
    return switch (fake_view) {
        1 => .{ .state = .searching },
        4 => .{ .state = .wrong_cart, .partner_app = 'G' },
        7 => .{ .state = .offline },
        else => .{
            .state = .lobby,
            .role = if (host) .host else .guest,
            .cable = if (host) 1 else 2,
            .track = lobby_track,
            .pick = link_pick,
            .ready = link_ready or fake_view >= 5,
            .peer_pick = if (host) 3 else 0,
            .peer_ready = fake_view >= 5,
            .can_go = host and fake_view >= 5,
        },
    };
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
        @export(&debug_force_ko, .{ .name = "debug_force_ko" });
        @export(&debug_kos, .{ .name = "debug_kos" });
        @export(&debug_rebuilds, .{ .name = "debug_rebuilds" });
        @export(&debug_replay_calls, .{ .name = "debug_replay_calls" });
        @export(&debug_replay_max, .{ .name = "debug_replay_max" });
        @export(&debug_set_machine, .{ .name = "debug_set_machine" });
        @export(&debug_machine, .{ .name = "debug_machine" });
        @export(&debug_link_view, .{ .name = "debug_link_view" });
        @export(&debug_link_race, .{ .name = "debug_link_race" });
        @export(&debug_link_notice, .{ .name = "debug_link_notice" });
        @export(&debug_link_state, .{ .name = "debug_link_state" });
        @export(&debug_linked, .{ .name = "debug_linked" });
        @export(&debug_view, .{ .name = "debug_view" });
        @export(&debug_link_waits, .{ .name = "debug_link_waits" });
        @export(&debug_human_lap, .{ .name = "debug_human_lap" });
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
    const p = &world.w.machines[world.view];
    return @backingInt(sim.current.attr_at(p.x >> fixed.Q, p.y >> fixed.Q));
}
fn debug_px() callconv(.c) u32 {
    return @bitCast(world.w.machines[world.view].x >> fixed.Q);
}
fn debug_py() callconv(.c) u32 {
    return @bitCast(world.w.machines[world.view].y >> fixed.Q);
}
fn debug_heading() callconv(.c) u32 {
    return world.w.machines[world.view].heading;
}
/// Player speed in 1/100 px per tick.
fn debug_speed() callconv(.c) u32 {
    return @bitCast((sim.speed(&world.w.machines[world.view]) * 100) >> fixed.Q);
}
fn debug_lap() callconv(.c) u32 {
    return world.w.machines[world.view].lap;
}
fn debug_progress() callconv(.c) u32 {
    return world.w.machines[world.view].progress;
}
/// 0 countdown, 1 racing, 2 finished.
fn debug_phase() callconv(.c) u32 {
    return @backingInt(world.w.phase);
}
fn debug_tick() callconv(.c) u32 {
    return world.w.tick;
}
fn debug_thermal() callconv(.c) u32 {
    return @bitCast(@as(i32, world.w.machines[world.view].thermal));
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
    const p = &world.w.machines[world.view];
    if (p.active and p.crash == .none and screen == .race) sim.crash(p, .fall);
    return world.w.tick;
}
/// --call-at T debug_force_ko: the live rival or batch job nearest the
/// player, credited to the player, melts down on the spot: a knockout
/// (SPEC 5.5) for scripting the wreck. Returns its index, 0 if none.
fn debug_force_ko() callconv(.c) u32 {
    const w = &world.w;
    const p = &w.machines[world.view];
    if (screen != .race) return 0;
    var best: u32 = 0;
    var best_d: i64 = std.math.maxInt(i64);
    for (w.machines[1..w.active_count], 1..) |*m, i| {
        if (!m.active or m.crash != .none or m.finished) continue;
        const dx: i64 = ((((m.x -% p.x) >> fixed.Q) + 512) & 1023) - 512;
        const dy: i64 = ((((m.y -% p.y) >> fixed.Q) + 512) & 1023) - 512;
        if (dx * dx + dy * dy < best_d) {
            best_d = dx * dx + dy * dy;
            best = @intCast(i);
        }
    }
    if (best == 0) return 0;
    const m = &w.machines[best];
    m.hit_by_player = tuning.ko_credit_ticks;
    m.thermal = 0;
    sim.crash(m, .meltdown);
    return best;
}
/// Machines the player knocked out this race (SPEC 5.5).
fn debug_kos() callconv(.c) u32 {
    return world.w.kos[0];
}
/// --call debug_set_machine:N picks the player's physics character (0 SNOUTY, 1..4 the rivals').
fn debug_set_machine(n: u32) callconv(.c) void {
    sim.player_character = @intCast(n % 5);
    world.w.picks[0] = sim.player_character;
}
fn debug_machine() callconv(.c) u32 {
    return sim.player_character;
}
/// --call debug_link_view:K shows a made-up LINK RACE lobby (the
/// simulator's link is offline): 1 searching, 2 the host's lobby, 3 the
/// guest's, 4 another cart, 5 the host with both ready, 6 the guest
/// ready, 7 no link. The lobby's controls work on it (the host's track
/// and machine rows, A ready); 0 back to the real one.
fn debug_link_view(k: u32) callconv(.c) u32 {
    fake_view = k;
    if (screen != .lobby) open_lobby();
    return k;
}
/// --call debug_link_race:K starts a made-up two-human link race in the
/// simulator (no lockstep: both humans' bytes are made here), K bit 0 =
/// the view (0 the host's machine 0, 1 the guest's machine 1), K >> 1 =
/// the track (`track.tracks` order). The host drives the Anteater, the
/// guest BACKPROP. With `debug_set_autopilot:1` both views show the same
/// race. Its results show both humans, A to the (made-up) lobby.
fn debug_link_race(k: u32) callconv(.c) u32 {
    if (!lnk_started) {
        lnk = Net.init(link.Badge.init(.{}, link_race.app_id, cart.rand()));
        lnk_started = true;
    }
    if (fake_view == 0) fake_view = 2;
    lobby_track = @intCast((k >> 1) % track.tracks.len);
    const rules = [1]u8{lobby_track};
    prepare_race(link_race.track_of(rules));
    link_race.reset(&world.w, rules, .{ sim.player_character, 3 }, 0x5EED_0001);
    world.view = link_race.machine_of(@intCast(k & 1));
    fake_link = true;
    begin_link_race();
    return world.view;
}
/// --call-at T debug_link_notice:K over a made-up link race: 1 WAITING
/// FOR PEER, 2 PEER LEFT, AI DRIVING, 3 a desync (the results with the
/// DESYNC band), 0 none.
fn debug_link_notice(k: u32) callconv(.c) u32 {
    fake_notice = k;
    return k;
}
/// lockstep.State: 0 offline (the simulator), 1 searching, 2 wrong cart,
/// 3 lobby, 4 racing, 5 waiting, 6 peer left, 7 desync; 0xFF before
/// LINK RACE first opened.
fn debug_link_state() callconv(.c) u32 {
    return if (lnk_started) @backingInt(lnk.state()) else 0xFF;
}
fn debug_linked() callconv(.c) u32 {
    return @as(u32, @intFromBool(linked)) | (@as(u32, @intFromBool(fake_link)) << 1);
}
/// The machine the camera and HUD follow (0 solo and the host, 1 the guest).
fn debug_view() callconv(.c) u32 {
    return world.view;
}
fn debug_link_waits() callconv(.c) u32 {
    return link_waits;
}
/// Laps of human slot s's machine (0xFF without one).
fn debug_human_lap(s: u32) callconv(.c) u32 {
    const h = world.w.humans[s & 1];
    return if (h == world.no_human) 0xFF else world.w.machines[h].lap;
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
    return world.w.machines[world.view].rank;
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
    return world.w.machines[world.view].best_lap;
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
    return @intFromBool(world.w.machines[world.view].active);
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

//! Forked from snouty-zero/cart/src/main.zig at f8f6962.
//! Snouty GC: a Mode 7 combat racer on the Snouty Zero engine. SPEC.md is
//! the design, PLAN.md the milestone contract.
//!
//! M1: splash (Snouty's eyepatched portrait), title, the racer select
//! (select.zig), a 6-car combat race with the picked racer against the
//! other five, pause, results (winner card, then the field), the attract
//! demo, and the render stress scene (stress.zig). M3: the main menu
//! (QUICK RACE, GARBAGE COLLECTION, LINK greyed, SOUND), the track row over
//! every track, GARBAGE COLLECTION (a collected player watches the leader),
//! and the attract demo's camera cuts on a rotating track. The World lives here; `sim.simulate(&w, inputs)`
//! advances it and everything else only reads it. `follow` (which car this
//! badge draws and hears), the camera, the effects and the HUD notices
//! (fx.zig, from the World's event ring) are render-side state, never in
//! the World.
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
const racers = @import("racers.zig");
const results = @import("results.zig");
const menu = @import("menu.zig");
const sound = @import("sound.zig");
const hills = @import("hills.zig");
const fx = @import("fx.zig");
const select = @import("select.zig");
const stress = @import("stress.zig");

comptime {
    cart.export_start_code();
}

/// Screens (SPEC 8.1; the numbers are debug_screen's, `menu` came in M3).
pub const Screen = enum(u8) { splash, title, select, race, pause, results, menu };
var screen: Screen = .splash;
/// Why the race runs: a Quick Race, the attract demo, the render stress
/// scene, or GARBAGE COLLECTION (M3; the numbers are debug_mode's).
const Mode = enum(u8) { quick, attract, stress, gc };
var mode: Mode = .quick;
/// The mode the main menu picked (quick or gc): the select races it.
var race_mode: Mode = .quick;

/// The race. Only `sim` writes it.
var w: world.World = .{};
/// The car this badge draws, follows with the camera and hears (render-side).
/// The player's own car, except in the attract demo (the camera cuts) and
/// once GARBAGE COLLECTION has collected the player (the leader's camera).
var follow: u8 = racers.snouty;
/// The player's car (car i is racer i, so the picked racer's index).
var me: u8 = racers.snouty;
/// The racer the player drives (the racer select sets it).
var player_racer: u8 = racers.snouty;
/// The track the select's track row shows.
var player_track: u8 = 0;
/// Results: 0 the winner's card, 1 the field.
var results_card: u8 = 0;
/// The render stress scene (stress.zig): badge-bench `--poke gc_stress=1`
/// starts it at boot; the wasm `debug_stress` export too.
export var gc_stress: u8 = 0;
/// Race seed: a new one per race from the frame counter (any value works;
/// the link race of M4 shares one between the badges).
var seed: u32 = 0x5EED_6C00;

/// Frames since start(); one frame is one update() at 60 Hz.
var frame: u32 = 0;
/// Frames on the current screen.
var screen_frames: u32 = 0;
/// Microseconds spent in the last frame (hardware timer; 0 on wasm).
var render_us: u32 = 0;
/// The autopilot drives the player (`debug_set_autopilot`).
pub var autopilot: bool = false;
/// `debug_set_autopilot:2`: the pad's A and B join the autopilot's byte,
/// and the pad alone plays a CAPTCHA board (preview scripts use pickups).
var autopilot_mix: bool = false;

var pause_list = menu.List{ .count = 4 };
var main_list = menu.List{ .count = menu.item_count };
/// Frames NO LINK YET flashes after A on LINK.
var link_note: u32 = 0;
/// The attract demo's track, the next one each time (SPEC 8.2).
var attract_track: u8 = 0;
/// Attract: frames on the current car, and the car the camera holds on
/// while a scripted KERNEL PANIC flies at it and blue-screens it.
var cut_frames: u32 = 0;
const cut_every: u32 = 300;
var hold_frames: u32 = 0;
const panic_hold: u32 = 150;
/// A collected player watches the leader: frames on the current leader
/// (the camera changes car at most this often).
const watch_min: u32 = 120;
/// Title idle frames before the attract demo starts (10 s).
const attract_after: u32 = 600;
/// Frames since the race finished (results follow).
var finished_frames: u32 = 0;
const results_after: u32 = 150;
var last_msg: world.Message = .none;
/// The input byte slot 0 got on the last race tick (debug_input).
var last_input: u8 = 0;
var finish_note: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    backdrop();
    go(.splash);
    if (gc_stress != 0) start_stress();
}

fn start_stress() void {
    new_race(.quick, 0);
    mode = .stress;
    stress.fill(&w, follow);
    fx.begin(&w);
}

fn go(s: Screen) void {
    screen = s;
    screen_frames = 0;
}

/// The title and menu backdrop: Landfill Loop's floor under the Dumps
/// horizon, the camera high over the middle of the map, turning.
fn backdrop() void {
    const t = track.tracks[0];
    track.select(t);
    render.set_track(t);
    camera.init(512 << fixed.Q, 512 << fixed.Q, camera.cam.yaw);
    camera.cam.height = 96;
    render.hills_on = false;
}

fn to_title() void {
    backdrop();
    go(.title);
}

fn to_menu() void {
    if (screen != .title) backdrop();
    link_note = 0;
    go(.menu);
}

fn new_race(m: Mode, t: u8) void {
    mode = m;
    seed = seed *% 1103515245 +% 12345 +% frame;
    var setup = world.Setup{ .track = t, .seed = seed, .mode = switch (m) {
        .gc => .gc,
        .attract => .attract,
        .quick, .stress => .race,
    } };
    if (m == .quick or m == .gc) setup.humans[0] = player_racer;
    sim.reset(&w, setup);
    const tr = sim.track_of(&w);
    render.set_track(tr);
    hud.init_minimap(tr);
    hills.init(tr, w.lap_px);
    render.hills_on = true;
    me = player_racer;
    follow = me;
    cut_frames = 0;
    hold_frames = 0;
    fx.begin(&w);
    const c = &w.cars[follow];
    camera.follow(c.x, c.y, c.heading, true);
    finished_frames = 0;
    last_msg = .none;
    finish_note = 0;
    go(.race);
}

pub fn update() void {
    defer sound.update();
    input.update(read_controls());
    const t0 = cart.micros_since_boot();
    switch (screen) {
        .splash => splash_frame(),
        .title => title_frame(),
        .select => select_frame(),
        .race => race_frame(),
        .pause => pause_frame(),
        .results => results_frame(),
        .menu => menu_frame(),
    }
    engine_cue();
    render_us = @truncate(cart.micros_since_boot() - t0);
    if (build_options.debug_overlay) draw_overlay();
    frame +%= 1;
    screen_frames +%= 1;
    if (cart.is_wasm) present_wasm();
}

fn any_pressed() bool {
    return input.pressed(.start) or input.pressed(.a) or input.pressed(.b) or input.pressed(.select) or
        input.pressed(.up) or input.pressed(.down) or input.pressed(.left) or input.pressed(.right);
}

// --- Splash, title, menu ------------------------------------------------------

fn splash_frame() void {
    menu.draw_splash(screen_frames);
    if (screen_frames >= 120 or input.pressed(.start)) go(.title);
}

/// Title over a slowly turning view of the Dumps; 10 s idle starts the attract demo.
fn title_frame() void {
    draw_backdrop();
    menu.draw_title(screen_frames);
    if (input.pressed(.start)) {
        sound.menu_confirm();
        to_menu();
    } else if (any_pressed()) {
        screen_frames = 0;
    } else if (screen_frames >= attract_after) {
        const t = attract_track;
        attract_track = @intCast((attract_track + 1) % track.tracks.len);
        new_race(.attract, t);
    }
}

fn draw_backdrop() void {
    render.hills_on = false;
    render.frame = frame;
    camera.cam.yaw +%= 24;
    render.draw();
}

/// The main menu (SPEC 8.1): Up/Down, A or Start picks, B back to the title.
fn menu_frame() void {
    link_note -|= 1;
    draw_backdrop();
    menu_nav(&main_list);
    if (input.pressed(.b)) {
        to_title();
        draw_backdrop();
        menu.draw_title(screen_frames);
        return;
    }
    if (input.pressed(.a) or input.pressed(.start)) {
        switch (@as(menu.Item, @enumFromInt(main_list.cursor))) {
            .quick, .gc => |it| {
                sound.menu_confirm();
                race_mode = if (it == .gc) .gc else .quick;
                to_select();
                select.draw(frame);
                return;
            },
            // M4: the link cable. Until then the row only says so.
            .link => link_note = 48,
            .sound => {
                toggle_sound();
                sound.menu_confirm();
            },
        }
    }
    menu.draw_main(&main_list, sound.enabled, link_note, frame);
}

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

fn toggle_sound() void {
    sound.enabled = !sound.enabled;
    if (!sound.enabled) sound.stop();
}

fn to_select() void {
    select.enter(player_racer, player_track, race_mode == .gc);
    go(.select);
}

/// The racer select (select.zig): A picks and starts a Quick Race.
fn select_frame() void {
    switch (select.update()) {
        .pick => {
            player_racer = select.racer;
            player_track = select.track_index;
            new_race(race_mode, player_track);
            // The track's art and map were just unpacked (a few ms):
            // this frame shows the select once more, the race starts next.
            select.draw(frame);
            return;
        },
        .back => {
            to_menu();
            draw_backdrop();
            menu.draw_main(&main_list, sound.enabled, link_note, frame);
            return;
        },
        .none => {},
    }
    select.draw(frame);
}

// --- Race ------------------------------------------------------------------------

/// Draw the race from the followed car: floor, the depth list, beams,
/// HUD. `look` (Select held): the camera turns round for this frame only
/// (SPEC 5.1, 10), so the follow camera keeps easing underneath.
fn draw_race(look: bool) void {
    const c = &w.cars[follow];
    camera.follow(c.x, c.y, c.heading, snap_camera);
    snap_camera = false;
    hills.base_progress = c.progress;
    const watching = spectating();
    render.shake = if (watching) c.shake else @max(c.shake, fx.shake);
    render.frame = frame;
    // KERNEL PANIC on this badge's car: the blue screen instead of the race.
    if (hud.bluescreen_on(c)) return hud.draw_bluescreen(&w, follow);
    const saved = camera.cam;
    if (look) {
        camera.look_back(c.x, c.y);
        hills.backward = true;
    }
    render.row_jitter = c.bit_flip > 0 and c.wreck == .none;
    render.draw();
    // This badge's CAPTCHA card covers the floor (x 4..156, y 25..124):
    // nothing under it is drawn (M3: the card frames were the stress
    // scene's worst).
    if (!watching and hud.captcha_up(c)) {
        sprites.car_screen = @splat(.{});
    } else {
        sprites.draw_floor_lines(&w, frame);
        sprites.draw_world(&w, .{ .follow = follow, .look_back = look, .frame = frame });
        fx.draw_beams(&w);
    }
    hud.draw(&w, follow, .{
        .frame = frame,
        .look_back = look,
        .spectate = watching,
        .collected = mode == .gc and !w.cars[me].active,
        .press_start = mode == .attract,
    });
    hud.draw_after(frame);
    camera.cam = saved;
    hills.backward = false;
}

/// Look back: Select held in a race this badge drives (the input mask
/// already hides Select while Start is held too).
fn looking_back() bool {
    return !spectating() and input.held(.select);
}

fn race_frame() void {
    if (mode == .attract) {
        if (any_pressed()) {
            to_title();
            draw_backdrop();
            menu.draw_title(screen_frames);
            return;
        }
    } else if (mode == .stress) {
        stress.step(&w, follow, screen_frames);
        fx.tick(&w, follow, frame);
        draw_race(looking_back());
        return;
    } else if (input.pressed(.start) and w.phase != .finished) {
        pause_list = .{ .count = 4 };
        go(.pause);
        draw_race(false);
        return;
    }

    // One tick. The human slot 0 is this badge's buttons (or the autopilot).
    var inputs = [2]u8{ 0, 0 };
    if (mode == .quick or mode == .gc) {
        inputs[0] = if (autopilot) ai.drive(&w, me).byte() else input.race_byte();
        if (autopilot and autopilot_mix) {
            const pad = world.Input.of(input.race_byte());
            var in = world.Input.of(inputs[0]);
            if (w.cars[me].captcha > 0) in.a = false;
            in.a = in.a or pad.a;
            in.b = in.b or pad.b;
            in.select = in.select or pad.select;
            inputs[0] = in.byte();
        }
    }
    last_input = inputs[0];
    sim.simulate(&w, inputs);
    // The notices are the player's own (a collected player sees none of
    // the leader's); the attract demo's follow its camera.
    fx.tick(&w, if (mode == .attract) follow else me, frame);
    switch (mode) {
        .attract => attract_camera(),
        .gc => watch_leader(),
        else => {},
    }
    sound_cues();
    if (w.phase == .finished) {
        finished_frames += 1;
        if (finished_frames >= results_after or (mode != .attract and input.pressed(.start))) {
            if (mode == .attract) {
                to_title();
                draw_backdrop();
                menu.draw_title(screen_frames);
                return;
            }
            results_card = 0;
            go(.results);
        }
    }
    draw_race(looking_back());
}

/// The camera jumps to car `i` on the next drawn frame.
var snap_camera: bool = false;

fn cut_to(i: u8) void {
    if (i == follow) return;
    follow = i;
    snap_camera = true;
}

/// Attract (SPEC 8.2): the camera cuts to the next car still running every
/// `cut_every` frames, and to a car a KERNEL PANIC strikes (the scripted
/// one in lap 2, or any other), holding on it while the blue screen and
/// the freeze run.
fn attract_camera() void {
    if (fx.panic_target < world.car_count and w.cars[fx.panic_target].frozen_by == .panic) {
        // The panic was handled by fx.tick this frame (it set the panic
        // source for this car's blue screen only if it was followed).
        fx.panic_source = fx.panic_from;
        cut_to(fx.panic_target);
        fx.panic_target = world.no_car;
        hold_frames = panic_hold;
        cut_frames = 0;
    }
    fx.panic_target = world.no_car;
    if (hold_frames > 0) {
        hold_frames -= 1;
        return;
    }
    cut_frames += 1;
    if (cut_frames < cut_every) return;
    cut_frames = 0;
    var k: u8 = 1;
    while (k < world.car_count) : (k += 1) {
        const i: u8 = (follow + k) % world.car_count;
        const c = &w.cars[i];
        if (c.active and c.wreck == .none) return cut_to(i);
    }
}

/// GARBAGE COLLECTION: once the claw has lifted the player's car out, the
/// camera rides with the leader (SPEC 8.2), changing car at most every
/// `watch_min` frames.
fn watch_leader() void {
    if (w.cars[me].active or fx.claw_on(me)) {
        follow = me;
        cut_frames = watch_min;
        return;
    }
    cut_frames +|= 1;
    var lead: u8 = world.no_car;
    for (&w.cars, 0..) |*c, i| {
        if (c.active and (lead == world.no_car or c.rank < w.cars[lead].rank)) lead = @intCast(i);
    }
    if (lead == world.no_car or lead == follow) return;
    if (follow == me or !w.cars[follow].active or cut_frames >= watch_min) {
        cut_to(lead);
        cut_frames = 0;
    }
}

/// This badge is watching another car: the attract demo, or a collected player.
fn spectating() bool {
    return mode == .attract or follow != me;
}

/// Tones on message changes and wall hits (Zero SPEC 9), for the followed car.
fn sound_cues() void {
    const c = &w.cars[follow];
    const msg = if (c.msg != .none) c.msg else w.msg;
    if (msg != last_msg) {
        switch (msg) {
            .three, .two, .one => sound.countdown_beep(),
            .go => sound.go(),
            .finished => {
                sound.finish(0);
                finish_note = 8;
            },
            else => {},
        }
        last_msg = msg;
    }
    if (finish_note > 0) {
        finish_note -= 1;
        if (finish_note == 1) sound.finish(1);
    }
    if (c.shake == 4 and c.wreck == .none) sound.wall_click();
}

/// The engine drone: the followed car while racing, silent everywhere
/// else, while wrecked and in the attract demo.
fn engine_cue() void {
    const c = &w.cars[follow];
    if (screen != .race or spectating() or c.wreck != .none) return sound.engine_off();
    sound.engine(.{
        .speed = sim.speed(c),
        .throttle = !input.held(.down) and !c.finished,
        .boost = c.burst > 0,
        .air = c.hop > 0,
        .rough = c.on_coolant,
        .grid = w.phase == .countdown,
        .frame = frame,
    });
}

// --- Pause and results -------------------------------------------------------------

fn pause_frame() void {
    draw_race(false);
    hud.fill_rect(24, 30, 112, 70, hud.anti_black);
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
            1 => new_race(mode, w.track),
            2 => {
                autopilot = false;
                to_select();
            },
            else => toggle_sound(),
        }
    }
}

/// Results: the winner's card, then the field; then the racer select
/// for the next race.
fn results_frame() void {
    if (results_card == 0) results.draw_winner(&w, me, screen_frames) else results.draw_table(&w, me, screen_frames);
    if (input.pressed(.start) or input.pressed(.a)) {
        sound.menu_confirm();
        if (results_card == 0) {
            results_card = 1;
        } else {
            to_select();
        }
    }
}

// --- Overlay and debug --------------------------------------------------------------

/// -Ddebug_overlay=true: "uuuuuus" top-right under the rank.
fn draw_overlay() void {
    var buf: [8]u8 = "      us".*;
    hud.put_uint(buf[0..6], @min(render_us, 999_999), ' ');
    hud.text(&buf, 160 - 8 * @as(i32, buf.len) - 4, 14, hud.white);
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        for (.{
            "debug_frame",      "debug_render_us",  "debug_pixel_checksum", "debug_px",
            "debug_py",         "debug_heading",    "debug_speed",          "debug_lap",
            "debug_progress",   "debug_phase",      "debug_tick",           "debug_rank",
            "debug_screen",     "debug_mode",       "debug_follow",         "debug_best_lap",
            "debug_wrecks",     "debug_burst",      "debug_sound",          "debug_world_size",
            "debug_world_sum",  "debug_car_px",     "debug_car_py",         "debug_car_lap",
            "debug_car_rank",   "debug_car_racer",  "debug_car_human",      "debug_set_autopilot",
            "debug_start_race", "debug_tile_under", "debug_input",
            "debug_stress",     "debug_drawn",      "debug_gathered",       "debug_select_racer",
            "debug_event_seq",  "debug_car_armor",  "debug_results_card",   "debug_give_pickup",
            "debug_roll_pickup", "debug_effect",    "debug_pickup",         "debug_frozen",
            "debug_captcha",    "debug_captcha_cursor", "debug_captcha_lit", "debug_forks",
            "debug_give_ahead", "debug_start_gc",   "debug_start_attract", "debug_gc_marked",
            "debug_gc_sweeps",  "debug_gc_collected", "debug_gc_survivor", "debug_alive",
            "debug_hazard_state", "debug_me",
        }) |name| @export(&@field(@This(), name), .{ .name = name });
    }
}

fn debug_frame() callconv(.c) u32 {
    return frame;
}
fn debug_render_us() callconv(.c) u32 {
    return render_us;
}
/// Sum of all framebuffer words, for render regression tests.
fn debug_pixel_checksum() callconv(.c) u32 {
    var sum: u32 = 0;
    for (cart.framebuffer) |*column| {
        for (column) |px| sum +%= @as(u16, @bitCast(px));
    }
    return sum;
}
fn debug_px() callconv(.c) u32 {
    return @bitCast(w.cars[follow].x >> fixed.Q);
}
fn debug_py() callconv(.c) u32 {
    return @bitCast(w.cars[follow].y >> fixed.Q);
}
fn debug_heading() callconv(.c) u32 {
    return w.cars[follow].heading;
}
/// Followed car's speed in 1/100 px per tick (300 = a WORKSTATION's top speed).
fn debug_speed() callconv(.c) u32 {
    return @bitCast((sim.speed(&w.cars[follow]) * 100) >> fixed.Q);
}
fn debug_lap() callconv(.c) u32 {
    return w.cars[follow].lap;
}
fn debug_progress() callconv(.c) u32 {
    return w.cars[follow].progress;
}
/// 0 countdown, 1 racing, 2 finished.
fn debug_phase() callconv(.c) u32 {
    return @backingInt(w.phase);
}
fn debug_tick() callconv(.c) u32 {
    return w.tick;
}
/// Followed car's rank 1..6.
fn debug_rank() callconv(.c) u32 {
    return w.cars[follow].rank;
}
/// 0 splash, 1 title, 2 racer select, 3 race, 4 pause, 5 results.
fn debug_screen() callconv(.c) u32 {
    return @backingInt(screen);
}
/// 0 quick race, 1 attract, 2 the render stress scene.
fn debug_mode() callconv(.c) u32 {
    return @backingInt(mode);
}
fn debug_follow() callconv(.c) u32 {
    return follow;
}
fn debug_best_lap() callconv(.c) u32 {
    return w.cars[follow].best_lap;
}
/// Wrecks in progress across the field (cars waiting for the WATCHDOG).
fn debug_wrecks() callconv(.c) u32 {
    var n: u32 = 0;
    for (&w.cars) |*c| n += @intFromBool(c.wreck != .none);
    return n;
}
/// Followed car: BURST ticks left * 256 + charges.
fn debug_burst() callconv(.c) u32 {
    const c = &w.cars[follow];
    return @as(u32, c.burst) * 256 + c.burst_charges;
}
fn debug_sound() callconv(.c) u32 {
    return @intFromBool(sound.enabled);
}
fn debug_world_size() callconv(.c) u32 {
    return @sizeOf(world.World);
}
/// A sum over the world's car positions and clock (a cheap fingerprint
/// for scripted runs; the M4 CRC is the real one).
fn debug_world_sum() callconv(.c) u32 {
    var s: u32 = w.tick ^ w.rng;
    for (&w.cars) |*c| s = s *% 31 +% @as(u32, @bitCast(c.x)) +% @as(u32, @bitCast(c.y)) *% 7 +% c.heading;
    return s;
}
fn debug_car_px(i: u32) callconv(.c) u32 {
    return @bitCast(w.cars[i % world.car_count].x >> fixed.Q);
}
fn debug_car_py(i: u32) callconv(.c) u32 {
    return @bitCast(w.cars[i % world.car_count].y >> fixed.Q);
}
fn debug_car_lap(i: u32) callconv(.c) u32 {
    return w.cars[i % world.car_count].lap;
}
fn debug_car_rank(i: u32) callconv(.c) u32 {
    return w.cars[i % world.car_count].rank;
}
fn debug_car_racer(i: u32) callconv(.c) u32 {
    return w.cars[i % world.car_count].racer;
}
fn debug_car_human(i: u32) callconv(.c) u32 {
    return w.cars[i % world.car_count].human;
}
/// --call debug_set_autopilot:1 hands the player's car to the autopilot;
/// 2 also lets the pad's A, B and Select through (and the pad alone plays
/// a CAPTCHA board).
fn debug_set_autopilot(v: u32) callconv(.c) void {
    autopilot = v != 0;
    autopilot_mix = v == 2;
}
/// --call debug_start_race:N skips the splash and menus into a Quick Race on track N.
fn debug_start_race(n: u32) callconv(.c) void {
    new_race(.quick, @intCast(n % track.tracks.len));
}
/// --call debug_start_gc:N: a GARBAGE COLLECTION race on track N.
fn debug_start_gc(n: u32) callconv(.c) void {
    race_mode = .gc;
    new_race(.gc, @intCast(n % track.tracks.len));
}
/// --call debug_start_attract:N: the attract demo on track N.
fn debug_start_attract(n: u32) callconv(.c) void {
    new_race(.attract, @intCast(n % track.tracks.len));
}
/// GARBAGE COLLECTION: the marked car (255 none), sweeps, collected bits,
/// the survivor (255 none), the cars still running.
fn debug_gc_marked() callconv(.c) u32 {
    return w.gc.marked;
}
fn debug_gc_sweeps() callconv(.c) u32 {
    return w.gc.sweeps;
}
fn debug_gc_collected() callconv(.c) u32 {
    return w.gc.collected;
}
fn debug_gc_survivor() callconv(.c) u32 {
    return w.gc.survivor;
}
fn debug_alive() callconv(.c) u32 {
    var n: u32 = 0;
    for (&w.cars) |*c| n += @intFromBool(c.active);
    return n;
}
/// The hazards' states, a hex digit per slot (slot 0 lowest): state (0
/// idle, 1 warn, 2 active) + 4 * kind (1 blast, 2 mover).
fn debug_hazard_state() callconv(.c) u32 {
    var v: u32 = 0;
    for (w.hazards, 0..) |hz, k| v |= (@as(u32, @intFromEnum(hz.state)) + 4 * @as(u32, @intFromEnum(hz.kind))) << @intCast(4 * k);
    return v;
}
/// The player's car.
fn debug_me() callconv(.c) u32 {
    return me;
}
/// --call debug_stress:1 starts the render stress scene (stress.zig).
fn debug_stress(v: u32) callconv(.c) void {
    gc_stress = @intCast(v & 0xFF);
    if (gc_stress != 0) start_stress();
}
/// Objects the depth list drew / gathered on the last frame (cap 64).
fn debug_drawn() callconv(.c) u32 {
    return sprites.last_drawn;
}
fn debug_gathered() callconv(.c) u32 {
    return sprites.last_gathered;
}
/// The racer the select shows.
fn debug_select_racer() callconv(.c) u32 {
    return select.racer;
}
/// The World's next event seq (events written so far, mod 65536).
fn debug_event_seq() callconv(.c) u32 {
    return w.event_seq;
}
fn debug_car_armor(i: u32) callconv(.c) u32 {
    return w.cars[i % world.car_count].armor;
}
/// Results: 0 the winner's card, 1 the field.
fn debug_results_card() callconv(.c) u32 {
    return results_card;
}
/// M2 preview hooks (debug paths like `debug_stress`: they write the
/// World so a script can show a gag on a chosen frame; the sim runs on).
/// --call-at "T debug_give_pickup:P" puts pickup P (world.Pickup, SPEC 6.3
/// order) in the followed car's slot.
fn debug_give_pickup(p: u32) callconv(.c) u32 {
    const c = &w.cars[follow];
    c.pickup = if (p <= @intFromEnum(world.Pickup.prompt_injection)) @enumFromInt(p) else .none;
    c.roll_ticks = 0;
    return @intFromEnum(c.pickup);
}
/// The same with the 45-tick roulette in front of it.
fn debug_roll_pickup(p: u32) callconv(.c) u32 {
    const r = debug_give_pickup(p);
    w.cars[follow].roll_ticks = 45;
    return r;
}
/// stress.Effect `k & 0xFF` on car `(k >> 8) - 1`, or the followed car when
/// `k >> 8` is 0 (1 KERNEL PANIC, 2 BIT FLIP, 3 CAPTCHA, 4 DDOS, 5 DEADLOCK,
/// 6 HEISENBUG, 7 SUDO, 8 RACE CONDITION, 9 SPAGHETTI, 10 RUBBER DUCK,
/// 11 PREFETCH, 12 HONEYPOT spin, 13 ZERO-DAY, 14 duck pop, 15 HOT PATCH,
/// 16 a crate pop, 17 a rival's FORK BOMB 8 samples ahead).
fn debug_effect(k: u32) callconv(.c) u32 {
    const e = k & 0xFF;
    if (e > @intFromEnum(stress.Effect.fork_ahead)) return 0;
    const car: usize = if (k >> 8 == 0) follow else ((k >> 8) - 1) % world.car_count;
    stress.force_effect(&w, car, @enumFromInt(e));
    return e;
}
/// Pickup P to the nearest car ahead of the followed one (its AI uses it
/// by its policy); returns that car + 1, or 0 for none within 300 px.
fn debug_give_ahead(p: u32) callconv(.c) u32 {
    const j = stress.car_ahead(&w, follow, 300) orelse return 0;
    const c = &w.cars[j];
    c.pickup = if (p <= @intFromEnum(world.Pickup.prompt_injection)) @enumFromInt(p) else .none;
    c.roll_ticks = 0;
    return @as(u32, @intCast(j)) + 1;
}
/// Followed car: the held pickup (16 = none).
fn debug_pickup() callconv(.c) u32 {
    return @intFromEnum(w.cars[follow].pickup);
}
fn debug_frozen() callconv(.c) u32 {
    return w.cars[follow].frozen;
}
/// Followed car's CAPTCHA: ticks left, the cursor cell, the lit cells.
fn debug_captcha() callconv(.c) u32 {
    return w.cars[follow].captcha;
}
fn debug_captcha_cursor() callconv(.c) u32 {
    return w.cars[follow].captcha_cursor;
}
fn debug_captcha_lit() callconv(.c) u32 {
    return w.cars[follow].captcha_lit;
}
/// Live FORK BOMB `&`s.
fn debug_forks() callconv(.c) u32 {
    var n: u32 = 0;
    for (&w.drops) |*d| n += @intFromBool(d.kind == .fork);
    return n;
}
/// The race byte of human slot 0 on the last tick (records the autopilot's
/// drive into an input script: tools/record_script.py).
fn debug_input() callconv(.c) u32 {
    return last_input;
}
/// Attribute of the tile under the followed car.
fn debug_tile_under() callconv(.c) u32 {
    const c = &w.cars[follow];
    return @backingInt(sim.track_of(&w).attr_at(c.x >> fixed.Q, c.y >> fixed.Q));
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

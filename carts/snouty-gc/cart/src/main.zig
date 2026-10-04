//! Forked from snouty-zero/cart/src/main.zig at f8f6962.
//! Snouty GC: a Mode 7 combat racer on the Snouty Zero engine. SPEC.md is
//! the design, PLAN.md the milestone contract.
//!
//! M1: splash (Snouty's eyepatched portrait), title, the racer select
//! (select.zig: Start, A is a Quick Race), a 6-car combat race on Landfill
//! Loop with the picked racer against the other five, pause, results
//! (winner card, then the field), the attract demo, and the render stress
//! scene (stress.zig). The World lives here; `sim.simulate(&w, inputs)`
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

/// Screens (SPEC 8.1, M1 subset; the numbers are debug_screen's).
pub const Screen = enum(u8) { splash, title, select, race, pause, results };
var screen: Screen = .splash;
/// Why the race runs: a Quick Race, the attract demo, or the render stress scene.
const Mode = enum(u8) { quick, attract, stress };
var mode: Mode = .quick;

/// The race. Only `sim` writes it.
var w: world.World = .{};
/// The car this badge draws, follows with the camera and hears (render-side).
var follow: u8 = racers.snouty;
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

var pause_list = menu.List{ .count = 4 };
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
    track.select(track.tracks[0]);
    render.set_track(track.tracks[0]);
    camera.init(512 << fixed.Q, 512 << fixed.Q, 0);
    camera.cam.height = 96;
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

fn new_race(m: Mode, t: u8) void {
    mode = m;
    seed = seed *% 1103515245 +% 12345 +% frame;
    var setup = world.Setup{ .track = t, .seed = seed };
    if (m == .quick) setup.humans[0] = player_racer;
    sim.reset(&w, setup);
    const tr = sim.track_of(&w);
    render.set_track(tr);
    hud.init_minimap(tr);
    hills.init(tr, w.lap_px);
    render.hills_on = true;
    follow = player_racer;
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
    render.hills_on = false;
    render.frame = frame;
    camera.cam.yaw +%= 24;
    render.draw();
    menu.draw_title(screen_frames);
    if (input.pressed(.start)) {
        sound.menu_confirm();
        to_select();
    } else if (any_pressed()) {
        screen_frames = 0;
    } else if (screen_frames >= attract_after) new_race(.attract, 0);
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
    select.enter(player_racer, player_track);
    go(.select);
}

/// The racer select (select.zig): A picks and starts a Quick Race.
fn select_frame() void {
    switch (select.update()) {
        .pick => {
            player_racer = select.racer;
            player_track = select.track_index;
            new_race(.quick, player_track);
            draw_race(false);
            return;
        },
        .back => {
            go(.title);
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
    camera.follow(c.x, c.y, c.heading, false);
    hills.base_progress = c.progress;
    render.shake = @max(c.shake, fx.shake);
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
    sprites.draw_floor_lines(&w, frame);
    sprites.draw_world(&w, .{ .follow = follow, .look_back = look, .frame = frame });
    fx.draw_beams(&w);
    hud.draw(&w, follow, .{ .frame = frame, .look_back = look });
    hud.draw_after(frame);
    camera.cam = saved;
    hills.backward = false;
}

/// Look back: Select held in a race this badge drives (the input mask
/// already hides Select while Start is held too).
fn looking_back() bool {
    return mode != .attract and input.held(.select);
}

fn race_frame() void {
    if (mode == .attract) {
        if (any_pressed()) {
            go(.title);
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
    if (mode == .quick) {
        inputs[0] = if (autopilot) ai.drive(&w, follow).byte() else input.race_byte();
    }
    last_input = inputs[0];
    sim.simulate(&w, inputs);
    fx.tick(&w, follow, frame);
    sound_cues();
    if (w.phase == .finished) {
        finished_frames += 1;
        if (finished_frames >= results_after or (mode == .quick and input.pressed(.start))) {
            if (mode == .attract) {
                go(.title);
                return;
            }
            results_card = 0;
            go(.results);
        }
    }
    draw_race(looking_back());
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
    if (screen != .race or mode == .attract or c.wreck != .none) return sound.engine_off();
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
    if (results_card == 0) results.draw_winner(&w, follow, screen_frames) else results.draw_table(&w, follow, screen_frames);
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
            "debug_event_seq",  "debug_car_armor",  "debug_results_card",
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
/// --call debug_set_autopilot:1 hands the player's car to the autopilot.
fn debug_set_autopilot(v: u32) callconv(.c) void {
    autopilot = v != 0;
}
/// --call debug_start_race:N skips the splash and menus into a Quick Race on track N.
fn debug_start_race(n: u32) callconv(.c) void {
    new_race(.quick, @intCast(n % track.tracks.len));
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

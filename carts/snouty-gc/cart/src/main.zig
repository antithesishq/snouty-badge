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
//! and the attract demo's camera cuts on a rotating track. M4: LINK (the
//! lobby, the shared racer select, LINK RACE and LINK GC over `net.zig`'s
//! lockstep, docs/NET.md section 3). M5: the CIRCUIT (the SNOUTY GCP:
//! `prix`, career.zig; the garage, standings and cards), A on the title
//! for a Quick Race. The World lives here; `sim.simulate(&w, inputs)`
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
const link = @import("link");
const net = @import("net.zig");
const link_ui = @import("link_ui.zig");
const career = @import("career.zig");
const csave = @import("career_save.zig");
const save_ui = @import("save_ui.zig");
const garage = @import("garage.zig");
const standings = @import("standings.zig");
const pickup_page = @import("pickup_page.zig");

comptime {
    cart.export_start_code();
}

/// Screens (SPEC 8.1; the numbers are debug_screen's, `menu` came in M3,
/// `lobby` (the LINK screen) in M4; the link race's racer select is
/// `select` with `select.link` set; M5 the CIRCUIT's `garage`,
/// `standings` and `card` (the league, unlock and end cards); `pickups`
/// (the menu's PICKUPS page) came with gc/menu-fix after them).
pub const Screen = enum(u8) { splash, title, select, race, pause, results, menu, lobby, garage, standings, card, pickups };
var screen: Screen = .splash;
/// Why the race runs: a Quick Race, the attract demo, the render stress
/// scene, GARBAGE COLLECTION (M3), a CIRCUIT race (M5; race rules, the
/// garage's loadouts, chips on), BATTLE (M6, `KILL -9` on an arena). The
/// numbers are debug_mode's.
const Mode = enum(u8) { quick, attract, stress, gc, circuit, battle };
var mode: Mode = .quick;
/// The mode the main menu picked (quick, gc or circuit): the select races it.
var race_mode: Mode = .quick;

/// M5: the CIRCUIT (the SNOUTY GCP), kept in RAM for the session (no
/// saves, SPEC 17.6): CIRCUIT in the main menu resumes it at the garage
/// until its end card.
var prix: career.Career = career.Career.init(racers.snouty);
var prix_on: bool = false;
/// Which card the `card` screen shows.
const Card = enum(u8) { league, unlock, end };
var card: Card = .league;

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
/// M5: badge-bench `--poke gc_cards=1` (tools/scripts/m5_cards.json): a
/// SNOUTY GCP with 5,000 CYCLES in the garage at boot, where Start books a
/// made-up 1st place instead of racing, so a script walks the garage, the
/// standings and every card.
export var gc_cards: u8 = 0;
/// M6: badge-bench `--poke gc_battle=1`: a BATTLE round on The Sandbox at
/// boot with SNOUTY on the autopilot (3 lives, 3 min); `gc_battle=2`: the
/// render stress scene (stress.zig) placed in the arena.
export var gc_battle: u8 = 0;
/// M6: the next BATTLE round's options (Track B's setup screen sets them;
/// the wasm `debug_start_battle` / `debug_battle_minutes` /
/// `debug_battle_crews` too): lives (0 INF), TIME minutes (0 NONE), AI cars.
var battle_lives: u8 = 3;
var battle_minutes: u8 = 3;
var battle_crews: u8 = world.car_count;
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

// --- Link (M4, docs/NET.md) ------------------------------------------------------

const Net = net.Net(link.Badge);
/// The race byte's Start bit (world.Input bit 6).
const start_bit: u8 = 0x40;
/// The link and its lockstep. Pumped on the LINK screens and through a
/// link race only: single player never touches it.
var lnk: Net = undefined;
/// This race runs over the link (LINK RACE / LINK GC): from the GO to
/// `leave` (QUIT, the results, a desync).
var linked: bool = false;
/// The lobby: the host's row and the rules it offers (kept between races).
var lobby_cursor: u8 = 0;
var lobby_rules: net.Rules = .{};
/// The link select: this badge is ready on its racer.
var link_ready: bool = false;
/// Pause: RESUME (or B) holds Start in the race byte until `paused` turns
/// off (net.Resume: a byte `submit` drops while `step` stalls must not
/// lose the edge). It sees every byte submitted in a link race.
var resume_hold: net.Resume = .{};
/// Frames `PEER LEFT, AI DRIVING` stays up; set once per race.
var left_note: u32 = 0;
var left_shown: bool = false;
/// The race ended in a desync (the results say so).
var desynced: bool = false;
/// The top of this update (us): the pump loop runs until
/// `tuning.link_pump_until_us` after it.
var frame_t0: u64 = 0;
/// Pump instrumentation: the last pump of this frame, the worst gap
/// between two pumps inside a race frame (top of update to the last pump
/// after the HUD), and the race's frames without a tick. badge-bench
/// `--poke gc_pump_probe=1` runs the pump points in a single-player race
/// too (no partner) and traces the worst gap as it grows (PLAN M4 status).
export var gc_pump_probe: u8 = 0;
var last_pump: u64 = 0;
var pump_gap_worst: u32 = 0;
var race_waits: u32 = 0;
/// The probe's sink for the per-tick lockstep work it runs (world_hash,
/// encode_input), so the optimizer keeps it.
export var gc_probe_sink: u32 = 0;
/// Debug (wasm, where the link is offline): a made-up lobby or select
/// (`debug_link_view`) and race notice (`debug_link_notice`).
var fake_view: u8 = 0;
var fake_notice: u8 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    lnk = Net.init(link.Badge.init(.{}, net.app_id, cart.rand()));
    backdrop();
    go(.splash);
    if (gc_stress != 0) start_stress();
    if (gc_battle == 1) {
        autopilot = true;
        new_race(.battle, 0);
    } else if (gc_battle == 2) {
        new_race(.battle, 0);
        mode = .stress;
        stress.fill(&w, follow);
        fx.begin(&w);
    }
    if (gc_cards != 0) {
        debug_start_circuit(racers.snouty);
        prix.cycles = 5000;
    }
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
    if (screen != .title and screen != .lobby) backdrop();
    link_note = 0;
    go(.menu);
}

fn new_race(m: Mode, t: u8) void {
    linked = false;
    seed = seed *% 1103515245 +% 12345 +% frame;
    var setup = world.Setup{ .track = t, .seed = seed, .mode = switch (m) {
        .gc => .gc,
        .attract => .attract,
        .battle => .battle,
        .quick, .stress, .circuit => .race,
    } };
    if (m == .quick or m == .gc or m == .battle) setup.humans[0] = player_racer;
    if (m == .battle) {
        setup.lives = battle_lives;
        setup.minutes = battle_minutes;
        setup.crews = battle_crews;
    }
    // The CIRCUIT: the league's track, every car's loadout, chips on.
    if (m == .circuit) setup = prix.setup(seed);
    begin_race(m, setup, player_racer);
}

/// Reset the World from `setup` and start drawing the race from car `car`.
fn begin_race(m: Mode, setup: world.Setup, car: u8) void {
    mode = m;
    sim.reset(&w, setup);
    const tr = sim.track_of(&w);
    render.set_track(tr);
    hud.init_minimap(tr);
    hills.init(tr, w.lap_px);
    render.hills_on = true;
    me = car;
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
    save_hook_top();
    const t0 = cart.micros_since_boot();
    frame_t0 = t0;
    // The floor bands pump the link in a link race (and in the probe).
    render.band_hook = if (linked or (gc_pump_probe != 0 and screen == .race)) &pump else null;
    switch (screen) {
        .lobby => lobby_frame(),
        .splash => splash_frame(),
        .title => title_frame(),
        .select => select_frame(),
        .race => race_frame(),
        .pause => pause_frame(),
        .results => results_frame(),
        .menu => menu_frame(),
        .garage => garage_frame(),
        .standings => standings_frame(),
        .card => card_frame(),
        .pickups => pickups_frame(),
    }
    engine_cue();
    save_ui.draw(screen != .race and screen != .pause);
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
    } else if (input.pressed(.a)) {
        // M5: A goes straight to the Quick Race select (SPEC 8.1: two
        // presses from the title to a race); Start opens the menu.
        sound.menu_confirm();
        race_mode = .quick;
        to_select();
        select.draw(frame);
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
    if (save_ui.chooser.open) return chooser_frame();
    menu_nav(&main_list);
    if (input.pressed(.b)) {
        to_title();
        draw_backdrop();
        menu.draw_title(screen_frames);
        return;
    }
    if (input.pressed(.a) or input.pressed(.start)) {
        switch (@as(menu.Item, @fromBackingInt(@intCast(main_list.cursor)))) {
            .quick, .gc => |it| {
                sound.menu_confirm();
                race_mode = if (it == .gc) .gc else .quick;
                to_select();
                select.draw(frame);
                return;
            },
            // M5: the SNOUTY GCP: a Prix under way resumes in the garage,
            // else the racer select starts one.
            .circuit => {
                sound.menu_confirm();
                if (save_ui.saver.offers(prix_on and !prix.done)) return open_chooser();
                if (prix_on and !prix.done) return to_garage();
                race_mode = .circuit;
                to_select();
                select.draw(frame);
                return;
            },
            // The PICKUPS reference page (pickup_page.zig).
            .pickups => {
                sound.menu_confirm();
                go(.pickups);
                pickup_page.draw(frame);
                return;
            },
            // M4: the link cable (greyed in the simulator: it only says so).
            .link => if (link_ok()) {
                sound.menu_confirm();
                to_lobby();
                draw_backdrop();
                link_ui.draw_lobby(&lobby_view(), lobby_cursor, frame);
                return;
            } else {
                link_note = 48;
            },
            .sound => {
                toggle_sound();
                sound.menu_confirm();
            },
        }
    }
    menu.draw_main(&main_list, sound.enabled, link_ok(), link_note, frame);
}

/// The menu's PICKUPS page (pickup_page.zig): the arrows browse, B goes
/// back to the menu on its PICKUPS row.
fn pickups_frame() void {
    if (pickup_page.update() == .back) {
        to_menu();
        draw_backdrop();
        menu.draw_main(&main_list, sound.enabled, link_ok(), link_note, frame);
        return;
    }
    pickup_page.draw(frame);
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
    select.link = null;
    select.circuit = race_mode == .circuit;
    select.enter(player_racer, player_track, race_mode == .gc);
    go(.select);
}

/// The racer select (select.zig): A picks and starts a Quick Race.
fn select_frame() void {
    if (select.link != null) return link_select_frame();
    switch (select.update()) {
        .pick => {
            player_racer = select.racer;
            if (race_mode == .circuit) {
                // A new SNOUTY GCP with the racer picked.
                prix = career.Career.init(player_racer);
                prix_on = true;
                return to_garage();
            }
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
            menu.draw_main(&main_list, sound.enabled, link_ok(), link_note, frame);
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
        pump_point(.lines);
        sprites.draw_world(&w, .{ .follow = follow, .look_back = look, .frame = frame });
        fx.draw_beams(&w);
    }
    pump_point(.sprites);
    hud.draw(&w, follow, .{
        .frame = frame,
        .look_back = look,
        .spectate = watching,
        .collected = (mode == .gc or mode == .battle) and !w.cars[me].active,
        .press_start = mode == .attract,
    });
    hud.draw_after(frame);
    pump_point(.after);
    camera.cam = saved;
    hills.backward = false;
}

/// Look back: Select held in a race this badge drives (the input mask
/// already hides Select while Start is held too).
fn looking_back() bool {
    return !spectating() and input.held(.select);
}

fn race_frame() void {
    if (linked) return link_race_frame();
    if (gc_pump_probe != 0) pump_top();
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
        pump_point(.sim);
        draw_race(looking_back());
        return probe_end();
    } else if (input.pressed(.start) and w.phase != .finished) {
        pause_list = .{ .count = 4 };
        go(.pause);
        draw_race(false);
        return;
    }

    // One tick. The human slot 0 is this badge's buttons (or the autopilot).
    var inputs = [2]u8{ 0, 0 };
    if (mode == .quick or mode == .gc or mode == .circuit or mode == .battle) {
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
        .gc, .battle => watch_leader(),
        else => {},
    }
    sound_cues();
    pump_point(.sim);
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
    if (cart.is_wasm and fake_notice != 0) link_ui.draw_notice(@fromBackingInt(@intCast(fake_notice % 3)), .unplugged, frame);
    probe_end();
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
    // BATTLE: an out player watches the kill leader (SPEC 8.3).
    if (mode == .battle and w.battle.leader != world.no_car and w.cars[w.battle.leader].active) lead = w.battle.leader;
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
    if (linked) return link_pause_frame();
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
                // A CIRCUIT race quit is not booked: back to the garage.
                if (mode == .circuit) return to_garage();
                to_select();
            },
            else => toggle_sound(),
        }
    }
}

/// Results: the winner's card, then the field; then the racer select
/// for the next race.
fn results_frame() void {
    // A link race keeps pumping: the partner may still need a late tick
    // of ours (the link resends it).
    if (linked) pump_top();
    if (results_card == 0) results.draw_winner(&w, me, screen_frames) else results.draw_table(&w, me, screen_frames);
    if (desynced) link_ui.draw_desync(frame);
    if (input.pressed(.start) or input.pressed(.a)) {
        sound.menu_confirm();
        if (results_card == 0) {
            results_card = 1;
        } else if (linked) {
            // Both badges go back to the lobby; a rematch starts there.
            return leave_link();
        } else if (mode == .circuit) {
            // M5: the race is booked (CYCLES, points), then the standings.
            _ = prix.finish_race(&w);
            save_ui.saver.request(&prix, .race);
            go(.standings);
            return standings.draw_standings(&prix, screen_frames);
        } else {
            to_select();
        }
    }
    if (linked) pump_loop(null);
}

// --- The CIRCUIT (M5: SPEC 8.2, 9) ---------------------------------------------------

fn to_garage() void {
    garage.enter(&prix);
    go(.garage);
    garage.draw(&prix, frame);
}

/// The garage (garage.zig): purchases, then Start / A on RACE: the AIs
/// shop on their plans and the league's next race starts.
fn garage_frame() void {
    switch (garage.update(&prix)) {
        .race => {
            if (gc_cards != 0) {
                _ = debug_prix_skip(1);
                return standings.draw_standings(&prix, screen_frames);
            }
            prix.ai_shop();
            new_race(.circuit, prix.track_index());
            // The track was just unpacked: the garage shows once more.
            garage.draw(&prix, frame);
            return;
        },
        .back => {
            save_ui.saver.request(&prix, .menu);
            to_menu();
            draw_backdrop();
            menu.draw_main(&main_list, sound.enabled, link_ok(), link_note, frame);
            return;
        },
        .none => {},
    }
    garage.draw(&prix, frame);
}

/// The standings after a CIRCUIT race; A: the garage, or after a league's
/// third race the league card.
fn standings_frame() void {
    standings.draw_standings(&prix, screen_frames);
    if (!(input.pressed(.a) or input.pressed(.start))) return;
    sound.menu_confirm();
    if (prix.league_over()) {
        _ = prix.close_league();
        card = .league;
        go(.card);
        return standings.draw_league(&prix, screen_frames);
    }
    to_garage();
}

/// The league card, then the unlock card over the new league's floor (or
/// the end card after the last), then the garage; a failed league goes
/// back to the garage to try it again.
fn card_frame() void {
    switch (card) {
        .league => standings.draw_league(&prix, screen_frames),
        .unlock => {
            draw_backdrop();
            standings.draw_unlock(&prix, screen_frames);
        },
        .end => standings.draw_end(&prix, screen_frames),
    }
    if (!(input.pressed(.a) or input.pressed(.start)) or screen_frames < 20) return;
    sound.menu_confirm();
    switch (card) {
        .league => if (prix.unlocked) {
            card = .unlock;
            show_league(prix.league);
            go(.card);
        } else if (prix.done) {
            card = .end;
            go(.card);
        } else to_garage(),
        .unlock => to_garage(),
        .end => {
            prix_on = false;
            save_ui.saver.request(&prix, .finished);
            backdrop();
            to_menu();
        },
    }
}

/// The backdrop over league `l`'s first track (the unlock card).
fn show_league(l: u8) void {
    const t = track.tracks[(l * track.tracks_per_league) % track.tracks.len];
    track.select(t);
    render.set_track(t);
    camera.init(512 << fixed.Q, 512 << fixed.Q, camera.cam.yaw);
    camera.cam.height = 96;
    render.hills_on = false;
}

// --- Cart saves (saves/gcp: career_save.zig, save_ui.zig; docs/RUNNING.md "Saves") ---

/// A link session (the LINK lobby, the link select, a link race with its
/// pause and results): no save may park the cart then.
fn link_session() bool {
    return linked or screen == .lobby or select.link != null;
}

/// The top of update(): the probe (once, on the splash or title), the
/// OS's exit request, a save whose SAVING mark the last frame showed.
fn save_hook_top() void {
    save_ui.saver.boot(frame, screen == .splash or screen == .title);
    save_ui.saver.frame_start(.{ .career = &prix, .on = prix_on, .link = link_session() });
}

/// CIRCUIT in the main menu with saves: CONTINUE CAREER / NEW CAREER.
fn open_chooser() void {
    save_ui.chooser.enter();
    chooser_frame();
}

/// The chooser (career_save.Chooser) over the menu's floor: CONTINUE picks
/// the career up where it was saved, NEW CAREER (confirmed when there is
/// one to lose) opens the racer select, B goes back to the menu.
fn chooser_frame() void {
    const session = prix_on and !prix.done;
    const can = save_ui.saver.can_continue(session);
    const k = csave.Keys{
        .up = input.pressed(.up),
        .down = input.pressed(.down),
        .a = input.pressed(.a) or input.pressed(.start),
        .b = input.pressed(.b),
    };
    if (k.up or k.down) sound.menu_move();
    if (k.a) sound.menu_confirm();
    switch (save_ui.chooser.update(can, k)) {
        .none => {},
        .back => return menu.draw_main(&main_list, sound.enabled, link_ok(), link_note, frame),
        .resume_career => {
            if (!session) prix = save_ui.saver.take_staged();
            prix_on = true;
            player_racer = prix.racer;
            race_mode = .circuit;
            return resume_career();
        },
        .new_career => {
            race_mode = .circuit;
            to_select();
            return select.draw(frame);
        },
    }
    save_ui.draw_chooser(can, if (session) &prix else &save_ui.saver.staged);
}

/// A continued career: the garage, or the standings of a league whose
/// third race was saved before it closed, or the end card.
fn resume_career() void {
    switch (csave.resume_at(&prix)) {
        .garage => to_garage(),
        .standings => {
            go(.standings);
            standings.draw_standings(&prix, screen_frames);
        },
        .end => {
            card = .end;
            go(.card);
            standings.draw_end(&prix, screen_frames);
        },
    }
}

// --- Link (M4: SPEC 7, docs/NET.md section 3) ---------------------------------------

/// LINK can run: a badge (the simulator's link is `.unavailable`).
fn link_ok() bool {
    return lnk.state() != .offline;
}

/// The top of a link frame: pump, and start timing the gaps between pumps.
fn pump_top() void {
    const now = cart.micros_since_boot();
    last_pump = now;
    render.site = .top;
    lnk.pump(now);
}

/// A pump point inside the frame (the floor bands call it through
/// `render.band_hook`): run the link, record the gap since the last one.
fn pump() void {
    const now = cart.micros_since_boot();
    const gap: u32 = @truncate(now -% last_pump);
    if (gap > pump_gap_worst) pump_gap_worst = gap;
    if (gc_pump_probe != 0) {
        const k = @backingInt(render.site);
        probe_gaps[k] = @max(probe_gaps[k], gap);
    }
    last_pump = now;
    lnk.pump(now);
}

/// The pump points between the race's sprite and HUD passes.
fn pump_point(at: render.Site) void {
    render.pump_at(at);
}

/// The probe's worst gap ending at each kind of pump point
/// (`render.Site`: the top of update, after the tick (the World's step
/// and the effects), the horizon's columns, the floor's
/// rows, the floor lines, the sprites, the HUD's passes, after the HUD).
var probe_gaps: [8]u32 = @splat(0);

/// Every 120 frames from frame 10 (the first frames unpack the track):
/// the worst gap at each pump point so far, then start again.
fn trace_gaps() void {
    if (frame < 10) {
        probe_gaps = @splat(0);
        return;
    }
    if ((frame - 10) % 120 != 119) return;
    // The OS trace buffer holds 128 bytes.
    var buf: [8 + 6 * probe_gaps.len]u8 = undefined;
    @memcpy(buf[0..8], "gc gaps:");
    for (probe_gaps, 0..) |g, k| hud.put_uint(buf[8 + 6 * k ..][0..6], @min(g, 99_999), ' ');
    cart.trace(&buf);
    probe_gaps = @splat(0);
}

/// The probe (badge-bench `--poke gc_pump_probe=1`, single player): the
/// per-frame lockstep work that needs no partner, so the bench counts its
/// cost: an input packet's encoding every frame, the World hash every
/// 32nd tick.
fn probe_end() void {
    if (gc_pump_probe == 0) return;
    trace_gaps();
    const p = net.encode_input(w.tick, .{ last_input, 0, 0 }, @truncate(w.tick));
    gc_probe_sink +%= p[0];
    if (w.tick % net.check_every == 0) gc_probe_sink +%= net.world_hash(&w);
}

/// After drawing, while a race runs or the link handshakes
/// (`lnk.wants_pump()`; the lobby and the link select call it too, as a
/// HELLO overflows the receive FIFO): keep pumping until
/// `tuning.link_pump_until_us` into the frame (the vsync wait is the one
/// stretch where nothing reads the receive FIFO), retrying a stalled step
/// (`ticked`, null: no race). Searching and a settled lobby pump once a
/// frame at the top only.
fn pump_loop(ticked: ?*bool) void {
    if (cart.is_wasm) return;
    while (lnk.wants_pump() and cart.micros_since_boot() -% frame_t0 < tuning.link_pump_until_us) {
        lnk.pump(cart.micros_since_boot());
        const t = ticked orelse continue;
        if (!t.* and w.phase != .finished) {
            t.* = lnk.step(&w);
            if (t.* and !lnk.ls.paused) after_tick();
        }
    }
}

/// What the lobby shows: the link's, or the made-up one of `debug_link_view`.
fn lobby_view() link_ui.View {
    if (cart.is_wasm and fake_view != 0) return fake_lobby();
    return .{
        .state = lnk.state(),
        .role = lnk.ls.role,
        .cable = @backingInt(lnk.ls.link.cable()),
        .rules = lnk.rules(),
        .peer = lnk.peer_pick(),
    };
}

fn to_lobby() void {
    if (screen != .menu and screen != .title) backdrop();
    select.link = null;
    link_ready = false;
    go(.lobby);
}

/// The LINK screen (SPEC 7.3): the cable state until a partner running
/// Snouty GC answers, then the host's rules (Up/Down a row, Left/Right
/// its value; the guest sees them), A to the racer select, B back to the
/// main menu (the link stops being pumped; the partner sees it gone 2 s
/// later).
fn lobby_frame() void {
    pump_top();
    if (lnk.take_started()) return start_link_race();
    draw_backdrop();
    const v = lobby_view();
    if (input.pressed(.b)) {
        lnk.set_pick(player_racer, false);
        to_menu();
        menu.draw_main(&main_list, sound.enabled, link_ok(), link_note, frame);
        return;
    }
    if (v.state == .lobby) {
        if (v.role == .host) {
            if (input.pressed(.up)) {
                lobby_cursor = if (lobby_cursor == 0) link_ui.row_count - 1 else lobby_cursor - 1;
                sound.menu_move();
            }
            if (input.pressed(.down)) {
                lobby_cursor = (lobby_cursor + 1) % link_ui.row_count;
                sound.menu_move();
            }
            const step: i32 = @as(i32, @intFromBool(input.pressed(.right))) - @as(i32, @intFromBool(input.pressed(.left)));
            if (step != 0 and lobby_cursor != @backingInt(link_ui.Row.racer)) {
                sound.menu_move();
                change_rule(step);
            }
            lnk.set_rules(lobby_rules);
        }
        lnk.set_pick(player_racer, false);
        if (input.pressed(.a) or input.pressed(.start)) {
            sound.menu_confirm();
            to_link_select();
            select.draw(frame);
            return pump_loop(null);
        }
    }
    link_ui.draw_lobby(&v, lobby_cursor, frame);
    pump_loop(null);
}

/// Host: Left/Right on a rules row.
fn change_rule(step: i32) void {
    switch (@as(link_ui.Row, @fromBackingInt(@intCast(lobby_cursor)))) {
        .mode => lobby_rules.mode = if (lobby_rules.mode == .gc) .race else .gc,
        .track => {
            const nt: i32 = @intCast(track.tracks.len);
            lobby_rules.track = @intCast(@mod(@as(i32, lobby_rules.track) + step, nt));
        },
        .crews => {
            var k: usize = 0;
            for (link_ui.crew_steps, 0..) |c, i| {
                if (c == lobby_rules.crews) k = i;
            }
            const len: i32 = link_ui.crew_steps.len;
            lobby_rules.crews = link_ui.crew_steps[@intCast(@mod(@as(i32, @intCast(k)) + step, len))];
        },
        .racer => {},
    }
}

fn link_info() select.Link {
    if (cart.is_wasm and fake_view != 0) return fake_select();
    return .{
        .host = lnk.ls.role == .host,
        .ready = link_ready,
        .peer = lnk.peer_pick(),
        .can_go = lnk.can_go(),
        .rules = lnk.rules(),
    };
}

fn to_link_select() void {
    select.enter(player_racer, player_track, false);
    link_ready = false;
    select.link = link_info();
    go(.select);
}

/// The shared racer select (SPEC 7.3): Left/Right a racer, A ready on one
/// the partner has not taken (greyed `TAKEN`), B takes the mark back (or
/// goes back to the lobby). The host's A with both ready starts the race
/// on both badges; on a clash the guest's mark goes (the host's pick wins).
fn link_select_frame() void {
    pump_top();
    const fake = cart.is_wasm and fake_view != 0;
    if (lnk.take_started()) {
        select.draw(frame);
        return start_link_race();
    }
    if (!fake and lnk.state() != .lobby) {
        // The cable went or the partner left the lobby: the LINK screen
        // shows why.
        link_ready = false;
        to_lobby();
        draw_backdrop();
        return link_ui.draw_lobby(&lobby_view(), lobby_cursor, frame);
    }
    select.link = link_info();
    if (link_ready and !select.link.?.host and select.taken(select.racer)) link_ready = false;
    select.link.?.ready = link_ready;
    switch (select.update()) {
        .pick => {
            if (!link_ready) {
                if (!select.taken(select.racer)) link_ready = true;
            } else if (lnk.ls.role == .host and lnk.can_go()) {
                player_racer = select.racer;
                _ = lnk.go(cart.micros_since_boot());
            }
        },
        .back => if (link_ready) {
            link_ready = false;
        } else {
            lnk.set_pick(select.racer, false);
            to_lobby();
            draw_backdrop();
            return link_ui.draw_lobby(&lobby_view(), lobby_cursor, frame);
        },
        .none => {},
    }
    lnk.set_pick(select.racer, link_ready);
    select.link = link_info();
    select.draw(frame);
    if (lnk.take_started()) return start_link_race();
    pump_loop(null);
}

/// Both badges, once per race (`take_started`): the World from the agreed
/// setup, this badge's car followed. The track was just unpacked, so the
/// race draws from the next frame (as a Quick Race's pick frame).
fn start_link_race() void {
    const s = lnk.world_setup();
    select.link = null;
    linked = true;
    link_ready = false;
    desynced = false;
    left_note = 0;
    left_shown = false;
    resume_hold = .{};
    race_waits = 0;
    pump_gap_worst = 0;
    autopilot = false;
    player_racer = lnk.local_car();
    player_track = s.track;
    race_mode = if (s.mode == .gc) .gc else .quick;
    begin_race(race_mode, s, lnk.local_car());
}

/// The byte this badge drives its car with (the autopilot's in tests).
fn link_byte() u8 {
    return if (autopilot) ai.drive(&w, me).byte() else input.race_byte();
}

/// What a tick that ran the World brings on the badge (as a Quick Race's
/// frame after `simulate`): effects, the GC camera, the sound cues.
fn after_tick() void {
    fx.tick(&w, me, frame);
    if (mode == .gc) watch_leader();
    sound_cues();
}

/// A link race frame (docs/NET.md section 3): pump, submit this frame's
/// buttons, step one tick if both bytes are here, draw (the floor bands
/// pump), then pump and retry until 14 ms into the frame. Once the World
/// is finished no input reaches it (finished humans drive on their AI), so
/// each badge runs it on alone until its results.
fn link_race_frame() void {
    pump_top();
    resume_hold.settle(lnk.ls.paused);
    if (lnk.state() == .desync) return end_desync();
    if (lnk.ls.paused and w.phase != .finished) {
        pause_list = .{ .count = 3 };
        go(.pause);
        return link_pause_frame();
    }
    var ticked = false;
    if (w.phase == .finished) {
        sim.simulate(&w, .{ 0, 0 });
        ticked = true;
        after_tick();
    } else {
        const byte = link_byte();
        last_input = byte;
        resume_hold.took(byte, lnk.submit(cart.micros_since_boot(), byte));
        ticked = lnk.step(&w);
        if (ticked and !lnk.ls.paused) after_tick();
    }
    pump_point(.sim);
    if (w.phase == .finished) {
        finished_frames += 1;
        if (finished_frames >= results_after or input.pressed(.start)) {
            results_card = 0;
            go(.results);
        }
    }
    draw_race(looking_back());
    link_notices();
    pump_loop(&ticked);
    if (!ticked) race_waits += 1;
}

/// WAITING FOR PEER while the partner's bytes are late; PEER LEFT, AI
/// DRIVING for a while once it has gone (not after the finish).
fn link_notices() void {
    const st = lnk.state();
    if (st == .peer_left and !left_shown) {
        left_shown = true;
        if (w.phase != .finished) left_note = tuning.link_left_note;
    }
    const k: link_ui.Notice = if (st == .waiting) .waiting else if (left_note > 0) .peer_left else .none;
    left_note -|= 1;
    link_ui.draw_notice(k, lnk.ls.left, frame);
}

/// The shared pause (L6): either badge's Start paused both on one tick.
/// Only Start reaches the race while paused (it resumes both); RESUME or
/// B holds Start until `paused` turns off (net.Resume: one edge, never
/// lost to a dropped byte); QUIT leaves (the partner's AI takes this car).
/// The lockstep ticks run on, without the World.
fn link_pause_frame() void {
    pump_top();
    resume_hold.settle(lnk.ls.paused);
    if (lnk.state() == .desync) return end_desync();
    const byte = resume_hold.byte(input.race_byte() & start_bit);
    resume_hold.took(byte, lnk.submit(cart.micros_since_boot(), byte));
    var ticked = lnk.step(&w);
    if (ticked and !lnk.ls.paused) after_tick();
    draw_race(false);
    hud.fill_rect(24, 30, 112, 70, hud.anti_black);
    menu_nav(&pause_list);
    const sound_item: []const u8 = if (sound.enabled) "SOUND: ON" else "SOUND: OFF";
    menu.draw_list("PAUSED", &.{ "RESUME", "QUIT", sound_item }, &pause_list, 34);
    if (input.pressed(.b)) resume_hold.request();
    if (input.pressed(.a)) {
        sound.menu_confirm();
        switch (pause_list.cursor) {
            0 => resume_hold.request(),
            1 => return leave_link(),
            else => toggle_sound(),
        }
    }
    if (!lnk.ls.paused) go(.race);
    link_notices();
    pump_loop(&ticked);
}

/// A desync (the Worlds' hashes differ; `step` has stopped): the results
/// with `DESYNC` over them, then the lobby.
fn end_desync() void {
    desynced = true;
    results_card = 0;
    go(.results);
    results.draw_winner(&w, me, screen_frames);
    link_ui.draw_desync(frame);
}

/// Leave the link race (QUIT, the results, after a desync): the partner
/// hears it (its AI takes this car if it still races), back to the lobby.
fn leave_link() void {
    lnk.leave(cart.micros_since_boot());
    linked = false;
    desynced = false;
    render.band_hook = null;
    to_lobby();
    draw_backdrop();
    link_ui.draw_lobby(&lobby_view(), lobby_cursor, frame);
}

/// `debug_link_view` k: 1 searching, 2 the host's lobby, 3 the guest's,
/// 4 another cart, 5 the host's select with both ready (A START), 6 the
/// guest's select on the host's racer (TAKEN), 7 another GC version.
fn fake_lobby() link_ui.View {
    return switch (fake_view) {
        1 => .{ .state = .searching },
        4 => .{ .state = .wrong_cart },
        7 => .{ .state = .wrong_version },
        else => .{
            .state = .lobby,
            .role = if (fake_view == 3 or fake_view == 6) .guest else .host,
            .cable = if (fake_view == 3) 2 else 1,
            .rules = lobby_rules,
            .peer = .{ .racer = racers.kiddie, .ready = fake_view >= 5 },
        },
    };
}

fn fake_select() select.Link {
    const host = fake_view != 6;
    return .{
        .host = host,
        .ready = link_ready,
        .peer = .{ .racer = if (host) racers.kiddie else racers.snouty, .ready = true },
        .can_go = host and link_ready and select.racer != racers.kiddie,
        .rules = lobby_rules,
    };
}

// --- Overlay and debug --------------------------------------------------------------

/// -Ddebug_overlay=true: "uuuuuus" top-right under the rank.
fn draw_overlay() void {
    var buf: [8]u8 = "      us".*;
    hud.put_uint(buf[0..6], @min(render_us, 999_999), ' ');
    hud.text(&buf, 160 - 8 * @as(i32, buf.len) - 4, 14, hud.white);
    if (!linked) return;
    // Link race: frames without a tick, link CRC drops, the worst gap
    // between two pumps (us) this race.
    var l: [19]u8 = "W     C     G      ".*;
    hud.put_uint(l[1..5], @min(race_waits, 9999), ' ');
    hud.put_uint(l[7..11], @min(lnk.ls.link.stats.crc_errors, 9999), ' ');
    hud.put_uint(l[13..19], @min(pump_gap_worst, 999_999), ' ');
    hud.text(&l, 4, 24, hud.white);
}

// Debug exports for the headless harness (wasm only).
comptime {
    if (cart.is_wasm) {
        for (.{
            "debug_frame",          "debug_render_us",     "debug_pixel_checksum", "debug_px",
            "debug_py",             "debug_heading",       "debug_speed",          "debug_lap",
            "debug_progress",       "debug_phase",         "debug_tick",           "debug_rank",
            "debug_screen",         "debug_mode",          "debug_follow",         "debug_best_lap",
            "debug_wrecks",         "debug_burst",         "debug_sound",          "debug_world_size",
            "debug_world_sum",      "debug_car_px",        "debug_car_py",         "debug_car_lap",
            "debug_car_rank",       "debug_car_racer",     "debug_car_human",      "debug_set_autopilot",
            "debug_start_race",     "debug_tile_under",    "debug_input",          "debug_stress",
            "debug_drawn",          "debug_gathered",      "debug_select_racer",   "debug_event_seq",
            "debug_car_armor",      "debug_results_card",  "debug_give_pickup",    "debug_roll_pickup",
            "debug_effect",         "debug_pickup",        "debug_frozen",         "debug_captcha",
            "debug_captcha_cursor", "debug_captcha_lit",   "debug_forks",          "debug_give_ahead",
            "debug_start_gc",       "debug_start_attract", "debug_gc_marked",      "debug_gc_sweeps",
            "debug_gc_collected",   "debug_gc_survivor",   "debug_alive",          "debug_hazard_state",
            "debug_me",             "debug_link_view",     "debug_link_notice",    "debug_link_state",
            "debug_linked",         "debug_start_circuit", "debug_prix_skip",      "debug_prix_cycles",
            "debug_prix_give",      "debug_prix_league",   "debug_prix_race",      "debug_prix_done",
            "debug_card",           "debug_garage_row",    "debug_pickup_cursor",  "debug_menu_battle",
            "debug_menu_row",       "debug_start_battle",  "debug_battle_minutes", "debug_battle_crews",
            "debug_battle_lives",   "debug_battle_elims",  "debug_battle_safe",    "debug_battle_left",
            "debug_battle_refill",  "debug_battle_out",    "debug_battle_leader",  "debug_battle_end",
            "debug_battle_set_lives", "debug_battle_kill", "debug_battle_clock",
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
/// 0 splash, 1 title, 2 racer select, 3 race, 4 pause, 5 results, 6 the
/// main menu, 7 the LINK lobby; M5: 8 the garage, 9 the standings, 10 a
/// CIRCUIT card (`debug_card`); 11 the PICKUPS page.
fn debug_screen() callconv(.c) u32 {
    return @backingInt(screen);
}
/// 0 quick race, 1 attract, 2 the render stress scene, 3 GARBAGE
/// COLLECTION, 4 a CIRCUIT race.
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
    for (w.hazards, 0..) |hz, k| v |= (@as(u32, @backingInt(hz.state)) + 4 * @as(u32, @backingInt(hz.kind))) << @intCast(4 * k);
    return v;
}
/// The player's car.
fn debug_me() callconv(.c) u32 {
    return me;
}
/// --call debug_link_view:K shows a made-up LINK screen (the simulator's
/// link is offline): 1 searching, 2 the host's lobby, 3 the guest's, 4
/// another cart, 5 the host's racer select with both ready, 6 the guest's
/// select on the host's racer, 7 another Snouty GCP version (WRONG
/// VERSION); 0 back to the real one.
fn debug_link_view(k: u32) callconv(.c) u32 {
    fake_view = @intCast(k % 8);
    if (fake_view == 0) return 0;
    if (fake_view == 5 or fake_view == 6) {
        to_link_select();
        if (fake_view == 6) select.racer = racers.snouty;
    } else to_lobby();
    return fake_view;
}
/// --call debug_link_notice:K draws a link race notice over a single-player
/// race: 1 WAITING FOR PEER, 2 PEER LEFT, AI DRIVING (cable out); 0 off.
fn debug_link_notice(k: u32) callconv(.c) u32 {
    fake_notice = @intCast(k % 3);
    return fake_notice;
}
/// net.State: 0 offline (the simulator), 1 searching, ... (net.zig).
fn debug_link_state() callconv(.c) u32 {
    return @backingInt(lnk.state());
}
fn debug_linked() callconv(.c) u32 {
    return @intFromBool(linked);
}
/// M5: --call debug_start_circuit:R skips the menus into a new SNOUTY GCP
/// with racer R, in the garage.
fn debug_start_circuit(r: u32) callconv(.c) void {
    player_racer = @intCast(r % racers.count);
    race_mode = .circuit;
    prix = career.Career.init(player_racer);
    prix_on = true;
    to_garage();
}
/// Books the next CIRCUIT race as if the player finished `place` (1..6;
/// the others in racer order, no kills or chips) and shows the standings
/// (preview hook: the league and end cards without driving six races).
fn debug_prix_skip(place: u32) callconv(.c) u32 {
    if (!prix_on) return 0;
    var fw: world.World = .{};
    const p: u8 = @intCast(@max(1, @min(place, racers.count)));
    var next: u8 = 1;
    for (&fw.cars, 0..) |*c, i| {
        c.racer = @intCast(i);
        if (i == prix.racer) {
            c.rank = p;
            continue;
        }
        if (next == p) next += 1;
        c.rank = next;
        next += 1;
    }
    _ = prix.finish_race(&fw);
    go(.standings);
    return prix.race;
}
/// The CIRCUIT: the wallet, give it CYCLES (preview hook), the league and
/// race, the end reached; the card shown (0 league, 1 unlock, 2 end);
/// the garage's row.
fn debug_prix_cycles() callconv(.c) u32 {
    return prix.cycles;
}
fn debug_prix_give(v: u32) callconv(.c) u32 {
    prix.cycles += v;
    return prix.cycles;
}
fn debug_prix_league() callconv(.c) u32 {
    return prix.league;
}
fn debug_prix_race() callconv(.c) u32 {
    return prix.race;
}
fn debug_prix_done() callconv(.c) u32 {
    return @intFromBool(prix.done);
}
fn debug_card() callconv(.c) u32 {
    return @backingInt(card);
}
fn debug_garage_row() callconv(.c) u32 {
    return garage.cursor;
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
/// --call debug_menu_battle:1 draws the main menu with a made-up BATTLE
/// row (the 7-row layout M6 needs; menu.preview_battle), 0 without.
fn debug_menu_battle(v: u32) callconv(.c) void {
    menu.preview_battle = v != 0;
}
/// The main menu's cursor (a menu.Item value).
// --- M6 BATTLE (wasm debug: the simulator's fakes for Track B) ---------------------

/// --call debug_start_battle:N: a BATTLE round on The Sandbox with the
/// select's racer, N lives (0 INF), the TIME and CREWS set below (default
/// 3 min, every AI car).
fn debug_start_battle(n: u32) callconv(.c) void {
    battle_lives = @intCast(n & 0xFF);
    race_mode = .battle;
    new_race(.battle, 0);
}
/// The next round's TIME in minutes (0 NONE) and AI cars (CREWS).
fn debug_battle_minutes(m: u32) callconv(.c) void {
    battle_minutes = @intCast(m & 0xFF);
}
fn debug_battle_crews(k: u32) callconv(.c) void {
    battle_crews = @intCast(k & 0xFF);
}
/// Car i's lives, eliminations and SAFE MODE ticks.
fn debug_battle_lives(i: u32) callconv(.c) u32 {
    return w.cars[i % world.car_count].lives;
}
fn debug_battle_elims(i: u32) callconv(.c) u32 {
    return w.cars[i % world.car_count].kills;
}
fn debug_battle_safe(i: u32) callconv(.c) u32 {
    return w.cars[i % world.car_count].safe;
}
/// Ticks left on the round's clock (0xFFFFFFFF: TIME NONE).
fn debug_battle_left() callconv(.c) u32 {
    if (w.battle.limit == 0) return 0xFFFF_FFFF;
    return w.battle.limit -| w.tick;
}
fn debug_battle_refill() callconv(.c) u32 {
    return w.battle.refill;
}
/// Cars out of lives (bits), the kill leader (255 none), why the round
/// ended (0 running, 1 lives, 2 time).
fn debug_battle_out() callconv(.c) u32 {
    return w.battle.out;
}
fn debug_battle_leader() callconv(.c) u32 {
    return w.battle.leader;
}
fn debug_battle_end() callconv(.c) u32 {
    return @backingInt(w.battle.end);
}
/// Fakes (debug writes outside `simulate`, like `debug_effect`):
/// `car | lives << 8` sets a car's lives; `victim | killer << 8` wrecks
/// the victim with the killer's hit credited (killer 255: no hit, nobody
/// scores); T sets the clock to T ticks left.
fn debug_battle_set_lives(v: u32) callconv(.c) void {
    w.cars[(v & 0xFF) % world.car_count].lives = @intCast((v >> 8) & 0xFF);
}
fn debug_battle_kill(v: u32) callconv(.c) void {
    const victim = (v & 0xFF) % world.car_count;
    const killer: u8 = @intCast((v >> 8) & 0xFF);
    const c = &w.cars[victim];
    if (!c.active or c.wreck != .none) return;
    c.last_hit_by = if (killer < world.car_count and killer != victim) killer else world.no_car;
    c.last_hit_ticks = 0;
    c.armor = 0;
    sim.wreck(&w, victim, .armor);
}
fn debug_battle_clock(t: u32) callconv(.c) void {
    if (w.battle.limit == 0) return;
    w.tick = w.battle.limit -| @as(u16, @intCast(@min(t, w.battle.limit)));
}

fn debug_menu_row() callconv(.c) u32 {
    return main_list.cursor;
}
/// The PICKUPS page's cursor (a world.Pickup value).
fn debug_pickup_cursor() callconv(.c) u32 {
    return pickup_page.cursor;
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
    c.pickup = if (p <= @backingInt(world.Pickup.prompt_injection)) @fromBackingInt(@intCast(p)) else .none;
    c.roll_ticks = 0;
    return @backingInt(c.pickup);
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
    if (e > @backingInt(stress.Effect.fork_ahead)) return 0;
    const car: usize = if (k >> 8 == 0) follow else ((k >> 8) - 1) % world.car_count;
    stress.force_effect(&w, car, @fromBackingInt(@intCast(e)));
    return e;
}
/// Pickup P to the nearest car ahead of the followed one (its AI uses it
/// by its policy); returns that car + 1, or 0 for none within 300 px.
fn debug_give_ahead(p: u32) callconv(.c) u32 {
    const j = stress.car_ahead(&w, follow, 300) orelse return 0;
    const c = &w.cars[j];
    c.pickup = if (p <= @backingInt(world.Pickup.prompt_injection)) @fromBackingInt(@intCast(p)) else .none;
    c.roll_ticks = 0;
    return @as(u32, @intCast(j)) + 1;
}
/// Followed car: the held pickup (16 = none).
fn debug_pickup() callconv(.c) u32 {
    return @backingInt(w.cars[follow].pickup);
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

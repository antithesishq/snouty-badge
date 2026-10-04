//! The frontend's state machine and its update (PLAN.md M2 "Frontend
//! states"), moved out of main.zig in M5 so it can be a module of its own:
//! the RAM cart builds this module (and every frontend file it imports)
//! ReleaseSmall, while the core and `video` (the per-row line sink) stay
//! ReleaseFast (PLAN.md M5 cut 4). main.zig keeps the cart exports, the
//! simulator shims and the `debug_*` exports, and calls `start`/`update`
//! here; both are `noinline` so the cold code is not inlined back into the
//! fast root module. See main.zig for the overview.
const cart = @import("cart-api");
const core = @import("core");
const video = @import("video");
pub const input = @import("input.zig");
pub const audio = @import("audio.zig");
pub const debug = @import("debug.zig");
pub const romsrc = @import("romsrc.zig");
const text = @import("text.zig");
const menu = @import("menu.zig");
const splash = @import("splash.zig");
const picker = @import("picker.zig");
const help = @import("help.zig");
pub const rewind = @import("rewind.zig");
const hint = @import("hint");

/// The console (~137 KB), a static initialised in place: never build it on
/// the stack (32 KB on the badge, 14.7 KB in wasm).
pub var md: core.Md = undefined;

/// Genesis frames per update; only the last is rendered.
const frames_per_update = core.tunables.render_every;

/// 0 splash, 1 running, 2 menu, 3 pick (drive picker), 4 help (no ROM on
/// the drive: frontend/help.zig, never left). `pick` and `help` only happen
/// in drive builds.
pub const State = enum(u32) { splash = 0, running = 1, menu = 2, pick = 3, help = 4 };
pub var state: State = .splash;
/// Where the splash leads: `running` (the ROM was chosen in `start`),
/// `pick` or `help`.
var after_splash: State = .running;
/// `md` has been initialised by `begin`; nothing reads it before.
pub var have_md = false;
var controls_state: input.State = .{};

/// Menu opens since boot.
pub var menu_opens: u32 = 0;
/// "Hold Select: menu" over the first seconds of play (lib/hint.zig).
var play_hint: hint.Overlay = .{};
/// `hint.play_seconds` in updates (30 a second by default).
const play_hint_updates = hint.play_seconds * 60 / frames_per_update;

pub noinline fn start() void {
    // Presents at 60 / render_every Hz (30 by default).
    cart.set_vsync_enabled(1000.0 * @as(f32, frames_per_update) / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    text.init();
    video.init();
    debug.frames_per_update = frames_per_update;
    audio.init();
    // False when the arena has no room: the game runs untracked and the
    // menu reads "Scrub: no memory".
    _ = rewind.init();
    romsrc.scan();
    choose_rom();
}

/// The ROM decision of PLAN.md "Frontend states": the embedded ROM when the
/// drive is not used (wasm, embed builds), the one playable drive file, the
/// picker for several, the no-ROM screen for none (no volume included): a
/// drive build has no embedded ROM to fall back on.
fn choose_rom() void {
    if (!romsrc.use_drive) return begin(romsrc.embedded());
    const s = &romsrc.scan_result;
    if (s.playable_count == 1) {
        if (romsrc.select(s.first_playable().?)) |src| return begin(src);
        after_splash = .help;
    } else if (s.playable_count > 1) {
        picker.reset();
        after_splash = .pick;
    } else {
        after_splash = .help;
    }
}

/// Create the console for `src`. Called once the ROM is known: in `start`,
/// or when the picker or the help screen is left.
fn begin(src: core.RomSource) void {
    md.init_in_place(src);
    audio.attach(&md);
    md.line_sink = video.sink();
    video.apply(&md);
    have_md = true;
    rewind.reset(&md);
}

pub noinline fn update() void {
    controls_state.poll(read_controls());
    const t0 = cart.micros_since_boot();
    debug.frame_tick(t0);
    switch (state) {
        .splash => splash_update(t0),
        .running => run_update(t0),
        .menu => menu_update(),
        // Only a drive build gets here; the check keeps the picker and the
        // help screen out of the wasm and embed builds.
        .pick => if (romsrc.use_drive) pick_update(t0),
        .help => if (romsrc.use_drive) help.draw(),
    }
}

/// One splash update (frontend/splash.zig); any button skips it. When it
/// ends, `after_splash` starts in the same update.
fn splash_update(t0: u64) void {
    if (splash.update(controls_state.edge.any_pressed())) leave_splash(t0);
}

/// Enter `after_splash` and run its first update now, with the buttons that
/// skipped the splash ignored until released.
fn leave_splash(t0: u64) void {
    controls_state.suppress_held();
    state = after_splash;
    switch (state) {
        .running => {
            play_hint.start(play_hint_updates);
            run_update(t0);
        },
        .pick => if (romsrc.use_drive) pick_update(t0),
        .help => if (romsrc.use_drive) help.draw(),
        else => {},
    }
}

/// The edge with suppressed (held-over) buttons masked out, so a button
/// that left the previous state does not act in the next.
fn live_edge() input.Edge {
    const e = controls_state.edge;
    return .{ .prev = e.prev, .cur = e.cur & ~controls_state.suppress };
}

/// One picker update (drive builds). On a choice start that ROM and run
/// its first frames in the same update; if it no longer maps, the no-ROM
/// screen instead.
fn pick_update(t0: u64) void {
    const i = picker.update(live_edge()) orelse return;
    const src = romsrc.select(i) orelse {
        state = .help;
        return help.draw();
    };
    begin(src);
    start_running(t0);
}

fn start_running(t0: u64) void {
    controls_state.suppress_held();
    state = .running;
    play_hint.start(play_hint_updates);
    run_update(t0);
}

fn run_update(t1: u64) void {
    const in = controls_state.game_frame();
    if (in.open_menu) {
        play_hint.stop();
        menu_opens += 1;
        state = .menu;
        audio.silence();
        // A Left/Right held over from the game must not scrub.
        controls_state.suppress_held();
        menu.open();
        _ = menu.update(&md, live_edge());
        return;
    }

    // After a scrub the console is parked on a record boundary: playing on
    // drops the records ahead.
    rewind.resume_if_parked(&md);
    var sound_buf: audio.UpdateBuf = undefined;
    audio.before_frames(&md, &sound_buf);
    var f: u8 = 1;
    while (f <= frames_per_update) : (f += 1) {
        md.step_frame(in.pad, f == frames_per_update);
        rewind.record_frame(&md);
    }
    // The drive ROM's CRC32, 8 KB per update (a no-op once known).
    romsrc.crc_tick();
    const t2 = cart.micros_since_boot();

    audio.update(&md);
    video.finish_frame();
    debug.record(@truncate(t2 -% t1));
    if (debug.enabled) romsrc.draw_report();
    debug.z80_state = debug.z80_label(&md);
    debug.draw();
    // A press held over from the splash, picker or help is suppressed, not fresh.
    play_hint.update_and_draw(cart, text.draw, live_edge().any_pressed(), cart.screen_height - hint.strip_h, menu.title_color, menu.band_color);
}

/// One menu update over the frozen frame; the core is not stepped.
fn menu_update() void {
    audio.silence();
    switch (menu.update(&md, live_edge())) {
        .stay => {},
        .resume_game => {
            menu.close();
            controls_state.suppress_held();
            video.apply(&md); // a Scale change, Reset's squeeze, a scrub
            state = .running;
            run_update(cart.micros_since_boot());
        },
        .pick_rom => {
            menu.close();
            controls_state.suppress_held();
            audio.silence();
            picker.reset();
            state = .pick;
        },
    }
}

pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

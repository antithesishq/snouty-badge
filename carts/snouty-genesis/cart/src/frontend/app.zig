//! The frontend's state machine and its update (PLAN.md M2 "Frontend
//! states"), moved out of main.zig in M5 so it can be a module of its own:
//! the RAM cart builds this module (and every frontend file it imports)
//! ReleaseSmall, while the core and `video` (the per-row line sink) stay
//! ReleaseFast (PLAN.md M5 cut 4). main.zig keeps the cart exports, the
//! simulator shims and the `debug_*` exports, and calls `start`/`update`
//! here; both are `noinline` so the cold code is not inlined back into the
//! fast root module. See main.zig for the overview.
//!
//! Multiplayer, chosen at comptime by `build_options.party`: the party
//! cart (`snouty-genesis-party`) has the USB party (frontend/lobby.zig,
//! `players.Session`, docs/MULTIPLAYER.md) and no link cable; every other
//! build (the RAM cart, the XIP cart, the simulator) has the two-player
//! link cable (frontend/link_lobby.zig, `linkplay.Session`,
//! docs/LINK_PLAY.md) and no party. The other side's code sits behind
//! comptime-known branches, so it is never analysed or linked in.
const std = @import("std");
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
const tuning = @import("tuning.zig");
const hint = @import("hint");
const link = @import("link");
pub const linkplay = @import("linkplay");
const link_lobby = @import("link_lobby.zig");
pub const players = @import("players");
const lobby = @import("lobby.zig");

/// The party lobby and lockstep exist in this build (`build_options.party`:
/// the party cart); the link cable exists in every other build.
const party_on = @import("build_options").party;

// ---- Link cable play (docs/LINK_PLAY.md; every build but the party cart) ----

/// The two-player session over the link cable: lib/lockstep.zig with the
/// console as its World (frontend/linkplay.zig). A static, started in
/// `start` (the link idles in its search until a cable and a partner
/// appear; `.unavailable` in the simulator).
pub const Net = linkplay.Session(link.Badge);
pub var net: Net = undefined;
/// A link race drives the console.
pub inline fn linked() bool {
    if (party_on) return false;
    return net.racing;
}
/// "PARTNER LEFT" band (updates to go).
var left_notice: u32 = 0;
/// Microseconds the last link tick (its two Genesis frames) took: how long
/// an update may wait for the partner's pad before giving up the tick.
var last_tick_us: u64 = 25_000;

/// `Md.setup.poll_hook`: pump the link inside a long frame (the receive
/// FIFO holds one input packet; a frame is 10-15 ms).
fn poll_net(_: *anyopaque) void {
    net.pump(cart.micros_since_boot());
}
var poll_ctx: u8 = 0;

// ---- Party (docs/MULTIPLAYER.md; party builds only) ----

const party_lib = @import("party_lib");
/// The fork firmware's cart serial port: static rings, 2 KiB in (about 13
/// frames of a 4-badge race's traffic, drained five times a Genesis frame)
/// and 512 B out (a whole lobby frame).
const PartyPort = party_lib.cart_serial.Badge(.{ .rx_size = 2048, .tx_size = 512 });
pub const PartyNet = players.Session(PartyPort);
/// The session, a static (it holds LockstepN's input rings); created the
/// first time the lobby opens.
pub var party_net: PartyNet = undefined;
pub var party_net_on = false;
/// The party race drives the console.
inline fn networked() bool {
    if (!party_on) return false;
    return party_net_on and party_net.racing;
}
/// "P3 LEFT" after a player left (updates to go) and which slot.
var party_left_notice: u32 = 0;
var left_slot: u4 = 0;
var prev_gone: u16 = 0;

/// `Md.setup.poll_hook`: drain the receive ring inside a long frame.
fn party_poll(_: *anyopaque) void {
    if (party_on and party_net_on) party_net.pump(cart.micros_since_boot());
}

/// The console (~137 KB), a static initialised in place: never build it on
/// the stack (32 KB on the badge, 14.7 KB in wasm).
pub var md: core.Md = undefined;

/// Genesis frames per update; only the last is rendered.
const frames_per_update = core.tunables.render_every;

/// 0 splash, 1 running, 2 menu, 3 pick (drive picker), 4 help (no ROM on
/// the drive: frontend/help.zig, never left), 5 party (the party lobby,
/// party builds), 6 link (the link screen, every other build). `pick` and
/// `help` only happen in drive builds.
pub const State = enum(u32) { splash = 0, running = 1, menu = 2, pick = 3, help = 4, party = 5, link = 6 };
pub var state: State = .splash;
/// Where the splash leads: `running` (the ROM was chosen in `start`),
/// `pick` or `help`.
var after_splash: State = .running;
/// `md` has been initialised by `begin`; nothing reads it before.
pub var have_md = false;
var controls_state: input.State = .{};

/// Menu opens since boot.
pub var menu_opens: u32 = 0;
/// "Hold Select: menu", then `menu.fast_hint`, over the first seconds of
/// play (lib/hint.zig): `hint.play_seconds` each.
var play_hint: hint.Overlay = .{};
/// `hint.play_seconds` in updates (30 a second by default).
const play_hint_updates = hint.play_seconds * 60 / frames_per_update;

/// Genesis frames the last running update stepped: `frames_per_update` at
/// 1x, up to `tuning.ff_max_frames` while fast forwarding (the `>>4x`
/// indicator and the `debug_ff_frames` export).
pub var frames_stepped: u32 = 0;
/// Microseconds the last rendered Genesis frame took (step, record and the
/// CRC tick) and the last unrendered one (step and record): fast forward's
/// estimates of what the update's remaining frames will cost.
var last_frame_us: u64 = 0;
var last_skip_us: u64 = 0;

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
    if (!party_on) net.init(link.Badge.init(.{}, linkplay.app_id, cart.rand()), &md);
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
    // What a link race with this ROM plugs in: a second pad, or the
    // game's own multitap. The pump inside frames keeps the link answered.
    if (!party_on) {
        net.kind = linkplay.race_kind(md.setup.cfg.kind);
        md.setup.poll_hook = .{ .ctx = &poll_ctx, .func = &poll_net };
    }
}

pub noinline fn update() void {
    controls_state.poll(read_controls());
    const t0 = cart.micros_since_boot();
    if (party_on) {
        // Drain the party port every update (the relay removes a badge that
        // stops reading); the console's poll hook does it inside frames.
        if (party_net_on) party_net.pump(t0);
    } else {
        // The link every update (lobby messages, keepalives); a race GO
        // sent or heard resets the console and runs it as the race.
        net.pump(t0);
        if (have_md and net.take_start()) start_race();
    }
    debug.frame_tick(t0);
    switch (state) {
        .splash => splash_update(t0),
        .running => run_update(t0),
        .menu => menu_update(),
        // Only a drive build gets here; the check keeps the picker and the
        // help screen out of the wasm and embed builds.
        .pick => if (romsrc.use_drive) pick_update(t0),
        .help => if (romsrc.use_drive) help.draw(),
        .party => if (party_on) party_update(t0),
        .link => if (!party_on) link_update(t0),
    }
    // The vsync wait is the one stretch nobody reads the receive FIFO:
    // pump to near the end of the 33 ms update while a race runs or the
    // link handshakes (root docs/LOCKSTEP.md section 3.1).
    if (!party_on) while (net.ls.wants_pump()) {
        const now = cart.micros_since_boot();
        if (now -% t0 >= tuning.link_pump_until_us or cart.is_wasm) break;
        net.pump(now);
    };
}

/// One link screen update (frontend/link_lobby.zig); B goes back to the
/// game.
fn link_update(t0: u64) void {
    // The game waits under the screen: no frames, no sound.
    audio.silence();
    romsrc.crc_tick();
    switch (link_lobby.update(&net, live_edge(), t0)) {
        .stay => {},
        .back => {
            controls_state.suppress_held();
            state = .running;
        },
    }
}

/// A race started (the console was reset for it): play it.
fn start_race() void {
    video.apply(&md);
    // No history while linked (the scrubber is off; `end_race` starts it
    // again): the console's undo hooks stay idle.
    if (rewind.available) core.undo.disable();
    menu.link_racing = true;
    left_notice = 0;
    link_lobby.last_end = .none;
    if (state == .menu) menu.close();
    controls_state.suppress_held();
    state = .running;
}

/// The race is over on this badge (a desync, the partner left, or Leave):
/// the console plays on locally with pad 2 released; a desync shows the
/// link screen.
fn end_race(why: link_lobby.End) void {
    net.leave(cart.micros_since_boot());
    menu.link_racing = false;
    // A history that mixes linked and local play cannot replay.
    rewind.reset(&md);
    link_lobby.last_end = why;
    if (why == .partner_left) left_notice = 60;
    if (why == .desync) {
        if (state == .menu) menu.close();
        controls_state.suppress_held();
        net.want = true;
        state = .link;
    }
}

/// A link update's tick: submit this badge's pad and step the tick (its
/// two Genesis frames, the second rendered when `render`), waiting for the
/// partner's pad while the tick still fits the update; a rendered tick
/// that did not come shows the last frame again. True when it ran.
fn link_tick(pad: u16, t1: u64, render: bool) bool {
    net.submit(t1, pad);
    var t = cart.micros_since_boot();
    var ok = net.step(render);
    const wait_us = tuning.link_pump_until_us -| @min(last_tick_us, tuning.link_pump_until_us);
    while (!ok) {
        if (t -% t1 >= wait_us or cart.is_wasm) break;
        net.pump(t);
        t = cart.micros_since_boot();
        ok = net.step(render);
    }
    if (ok) last_tick_us = cart.micros_since_boot() -% t;
    if (render and !ok) video.keep_last_frame();
    return ok;
}

/// After a race update: its end, the waiting band.
fn link_after() void {
    switch (net.ls.state()) {
        .desync => end_race(.desync),
        .peer_left => end_race(.partner_left),
        .waiting => draw_band("WAITING FOR PARTNER"),
        else => {},
    }
}

/// One lobby update (frontend/lobby.zig); B goes back to the game, GO
/// starts the race on the console.
fn party_update(t0: u64) void {
    if (!party_on) return;
    romsrc.crc_tick();
    switch (lobby.update(&party_net, &md, live_edge(), t0)) {
        .stay => {},
        .back => resume_local(),
        .started => {
            // Game.start reset the console with the race's peripheral.
            md.setup.poll_hook = .{ .ctx = &poll_ctx, .func = &party_poll };
            video.apply(&md);
            rewind.reset(&md);
            menu.party_racing = true;
            prev_gone = 0;
            lobby.last_end = .none;
            controls_state.suppress_held();
            state = .running;
        },
    }
}

/// Back to the local game (from the lobby, or after a race ended).
fn resume_local() void {
    controls_state.suppress_held();
    state = .running;
}

/// The party race is over on this badge (a desync, a drop, or Leave): the
/// console plays on locally; show the lobby when it ended badly.
fn party_end_race(why: lobby.End) void {
    if (!party_on) return;
    party_net.leave(cart.micros_since_boot());
    md.setup.poll_hook = null;
    menu.party_racing = false;
    lobby.last_end = why;
    if (why == .desync or why == .dropped) {
        controls_state.suppress_held();
        state = .party;
    }
}

/// A party update's ticks: submit this badge's byte for two ticks and step
/// both (pumping up to 14 ms into the update while a peer's byte is
/// missing), the second rendered; a missing rendered tick redraws the
/// last frame again. Returns the ticks stepped.
fn net_ticks(byte: u8, t1: u64, render: bool) u32 {
    party_net.submit(t1, byte);
    party_net.submit(t1, byte);
    var done: u32 = 0;
    while (done < frames_per_update) {
        if (party_net.step(render and done == frames_per_update - 1)) {
            done += 1;
            continue;
        }
        const now = cart.micros_since_boot();
        if (now -% t1 > 14_000 or cart.is_wasm) break;
        party_net.pump(now);
    }
    // The rendered tick did not come: show the last frame again (a copy,
    // not `render_still`, whose second call site would un-inline the
    // renderer from the frame loop: 4 KB the party cart lacks).
    if (render and done < frames_per_update) video.keep_last_frame();
    return done;
}

/// After the party race's ticks: its end, a leaver's notice, WAITING FOR
/// PLAYERS.
fn net_after() void {
    switch (party_net.ls.state()) {
        .desync => return party_end_race(.desync),
        .dropped => return party_end_race(.dropped),
        .waiting => draw_band("WAITING FOR PLAYERS"),
        else => {},
    }
    const gone = party_net.world.gone;
    if (gone & ~prev_gone != 0) {
        left_slot = @intCast(@ctz(gone & ~prev_gone));
        party_left_notice = 60;
    }
    prev_gone = gone;
    if (party_left_notice > 0) {
        party_left_notice -= 1;
        var b: [12]u8 = undefined;
        const msg = std.fmt.bufPrint(&b, "P{d} LEFT", .{@as(u32, left_slot) + 1}) catch "LEFT";
        draw_band(msg);
    }
}

/// A one-line band across the middle of the screen (Snoutenstein's; both
/// races' notices).
fn draw_band(msg: []const u8) void {
    cart.rect(.{ .x = 0, .y = 58, .width = cart.screen_width, .height = 11, .fill_color = menu.band_color });
    const n: i32 = @intCast(@min(msg.len, 20));
    text.draw(msg[0..@intCast(n)], @divTrunc(@as(i32, cart.screen_width) - 8 * n, 2), 60, menu.title_color, menu.band_color);
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
            play_hint.start(2 * play_hint_updates);
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
    play_hint.start(2 * play_hint_updates);
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
        menu.open(&md);
        _ = menu.update(&md, live_edge());
        return;
    }

    // A link or party race: fast forward, the chorded rewind and the
    // scrubber are off (they would step or rewind this badge alone).
    const link_on = linked();
    const race = link_on or networked();
    const fast = in.fast and !race;

    // Chorded rewind (Left during fast forward): the game stays frozen
    // under the menu's scrub bar and Left/Right step time as in the menu;
    // letting go of Select resumes as the menu does (input.zig suppressed
    // the held buttons) and steps this update.
    switch (if (race) .off else in.rewind) {
        .enter, .on => {
            if (in.rewind == .enter) {
                play_hint.stop();
                menu.freeze_frame();
            }
            rewinding = true;
            frames_stepped = 0;
            audio.silence();
            if (in.scrub != 0) _ = rewind.step(&md, in.scrub);
            menu.draw_scrub_bar(true);
            return;
        },
        .exit => {
            rewinding = false;
            menu.close();
            video.apply(&md);
        },
        .off => {},
    }

    // After a scrub the console is parked on a record boundary: playing on
    // drops the records ahead.
    rewind.resume_if_parked(&md);
    var sound_buf: audio.UpdateBuf = undefined;
    audio.before_frames(&md, &sound_buf, fast);
    if (networked()) {
        const t_net = cart.micros_since_boot();
        frames_stepped = net_ticks(players.wire_byte(in.pad), t1, true);
        romsrc.crc_tick();
        const t_end = cart.micros_since_boot();
        last_frame_us = t_end -% t_net;
        audio.update(&md, false);
        video.finish_frame();
        debug.record(@truncate(t_end -% t1));
        if (debug.enabled) romsrc.draw_report();
        debug.draw();
        net_after();
        return;
    }
    var n: u32 = frames_per_update;
    if (link_on) {
        // One lockstep tick: both frames with the tick's two pads, or
        // none (the partner's pad is late: the last frame again).
        if (!link_tick(in.pad, t1, true)) n = 0;
    } else {
        n = local_frames(in.pad, fast, t1);
    }
    frames_stepped = n;
    debug.frames_per_update = n;
    const t2 = cart.micros_since_boot();

    audio.update(&md, fast or (!party_on and n == 0));
    video.finish_frame();
    debug.record(@truncate(t2 -% t1));
    if (debug.enabled) romsrc.draw_report();
    debug.z80_state = debug.z80_label(&md);
    debug.draw();
    // A press held over from the splash, picker or help is suppressed, not fresh.
    if (play_hint.tick(live_edge().any_pressed())) {
        const s = if (play_hint.left >= play_hint_updates) hint.hold_select else menu.fast_hint;
        hint.draw_strip(cart, text.draw, s, cart.screen_height - hint.strip_h, menu.title_color, menu.band_color);
    }
    if (fast) draw_fast(n);
    if (link_on) link_after();
    if (!party_on and left_notice > 0) {
        left_notice -= 1;
        draw_band("PARTNER LEFT");
    }
}

/// The update's frames played alone: the frames before the last run
/// without the line sink (Genesis frames render only on the last of an
/// update, at 1x too) and, while fast forwarding, without sound. Fast
/// forward steps them until `tuning.ff_max_frames`, or until the time so
/// far plus the dearest unrendered frame and the last rendered one would
/// pass `tuning.ff_budget_us`; never fewer than the 1x pair. Returns the
/// frames stepped. The party cart steps every pad through the input-source
/// seam (players.zig: the badge is player 1, the others released); the
/// other builds step pad 1 alone, as before the party.
fn local_frames(pad: u16, fast: bool, t1: u64) u32 {
    var pads: core.Pads = undefined;
    if (party_on) players.local_pads(pad, &pads);
    var n: u32 = 1;
    const max: u32 = if (fast) tuning.ff_max_frames else frames_per_update;
    var skip_us: u64 = last_skip_us;
    var t = t1;
    while (n < max) : (n += 1) {
        if (n >= frames_per_update and !cart.is_wasm and t -% t1 + skip_us + last_frame_us > tuning.ff_budget_us) break;
        if (party_on) md.step_frame_pads(&pads, false) else md.step_frame(pad, false);
        rewind.record_frame(&md);
        const now = cart.micros_since_boot();
        last_skip_us = now -% t;
        skip_us = @max(skip_us, last_skip_us);
        t = now;
    }
    const t_last = cart.micros_since_boot();
    if (party_on) md.step_frame_pads(&pads, true) else md.step_frame(pad, true);
    rewind.record_frame(&md);
    // The drive ROM's CRC32, 8 KB per update (a no-op once known; a link
    // race starts only once it is known).
    romsrc.crc_tick();
    last_frame_us = cart.micros_since_boot() -% t_last;
    return n;
}

/// The chorded rewind is showing (the `debug_chord_rewind` export).
pub var rewinding: bool = false;

/// `>>4x` (Genesis frames this update over the 1x pair; `>>1.5x` for an odd
/// count) in the bottom right corner, over the hint strip and the report
/// line, inside the menu's scrub bar rectangle: a chorded rewind freezes
/// the last fast-forward frame and its bar then covers the indicator. The
/// game redraws the whole screen every update (`.no_copy_full_frame`), so
/// it is gone the update fast forward stops.
fn draw_fast(n: u32) void {
    var buf: [6]u8 = undefined;
    var i = debug.put(&buf, ">>");
    i += debug.put_num(buf[i..], @min(n / frames_per_update, 9));
    if (n % frames_per_update != 0) i += debug.put(buf[i..], ".5");
    i += debug.put(buf[i..], "x");
    const x: i32 = @intCast(menu.bar_x + menu.bar_w - 1 - 8 * i);
    text.draw(buf[0..i], x, menu.bar_top + 1, menu.title_color, menu.band_color);
}

comptime {
    // The indicator (6 glyphs at most) lies inside the scrub bar's frame.
    if (menu.bar_height < 10 or menu.bar_top + 1 + 8 > cart.screen_height or menu.bar_w < 2 + 8 * 6) @compileError("indicator outside the scrub bar");
}

/// One menu update over the frozen frame; the core is not stepped.
fn menu_update() void {
    audio.silence();
    // A party race goes on under the menu (released pad, nothing drawn):
    // stopping would stall every other badge.
    if (networked()) {
        _ = net_ticks(0, cart.micros_since_boot(), false);
        if (party_net.ls.state() == .desync) party_end_race(.desync) else if (party_net.ls.state() == .dropped) party_end_race(.dropped);
        if (state != .menu) return menu.close();
    }
    // A link race goes on under the menu (a released pad, nothing drawn):
    // stopping would stall the partner.
    if (linked()) {
        var sound_buf: audio.UpdateBuf = undefined;
        audio.before_frames(&md, &sound_buf, true);
        _ = link_tick(0, cart.micros_since_boot(), false);
        audio.update(&md, true);
        link_after();
        if (state != .menu) return;
    }
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
        .party => if (party_on) {
            menu.close();
            controls_state.suppress_held();
            if (!party_net_on) {
                party_net.init(.{}, if (core.tunables.z80_enabled) players.game_full else players.game_ram, party_lib.lockstep_n.party.pad(12, "GENESIS"), &md, cart.rand());
                party_net_on = true;
            } else party_net.ls.enter();
            state = .party;
        },
        .leave_party => if (party_on) {
            party_end_race(.left);
            menu.close();
            controls_state.suppress_held();
            video.apply(&md);
            state = .running;
        },
        .link => if (!party_on) {
            menu.close();
            controls_state.suppress_held();
            link_lobby.last_end = .none;
            state = .link;
        },
        .leave_link => if (!party_on) {
            end_race(.left);
            menu.close();
            controls_state.suppress_held();
            video.apply(&md);
            state = .running;
        },
    }
}

pub fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

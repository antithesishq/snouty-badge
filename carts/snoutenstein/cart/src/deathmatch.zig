//! Deathmatch screens and the two-badge glue (M7, SPEC.md section 19,
//! PLAN.md M7): `G` for the shared lockstep, the lobby (the host sets the
//! rules, both ready up, the host's Start goes), the match frame (pump at
//! the top, then loop to 14 ms into the frame while the lockstep is busy,
//! as Snouty GC's link race), the HUD frags and kill banners, the results
//! (A back to the lobby). The rules are match.zig; the campaign never
//! reaches this file (main.zig's `.deathmatch` mode is the only way in).
//!
//! Without a cable (the simulator, badge-bench, the previews) a *local*
//! match runs instead: the pad drives `view_slot`, bot.zig the other
//! player (or both), stepping once a frame as if the inputs had arrived.
//! main.zig's debug exports and `stein_dm_bench` start one.
const std = @import("std");
const cart = @import("cart-api");
const link = @import("link");
const lockstep = @import("lockstep");
const fixed = @import("fixed.zig");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");
const match = @import("match.zig");
const bot = @import("bot.zig");
const view = @import("render/view.zig");
const sprites = @import("render/sprites.zig");
const weapon = @import("render/weapon.zig");
const hud = @import("render/hud.zig");
const audio = @import("audio.zig");

const Buttons = state.Buttons;
const centered = hud.centered;
const fmt = hud.fmt;

/// The HELLO app byte of Snoutenstein (the partner's `app_name`).
pub const app_id: u8 = lockstep.apps.snoutenstein;

pub const G = match.G;
pub const Net = lockstep.Lockstep(link.Badge, G);

/// Pump the link until this far into the frame while the lockstep is busy
/// (the vsync wait is the stretch where nothing reads the 8-byte FIFO).
pub const pump_until_us: u64 = 14_000;
/// Kill banners stay this long (ticks).
const banner_ticks: u32 = 120;
/// The results take A only after this many frames (a held fire button
/// does not skip them).
const results_min: u32 = 60;

pub const Screen = enum(u8) { lobby = 0, match = 1, results = 2 };

pub var screen: Screen = .lobby;
var net: Net = undefined;
var net_up = false;
pub var world: match.World = undefined;
/// The player this badge shows (and, in a local match, the pad drives).
pub var view_slot: u1 = 0;
/// Local match (no lockstep): which players bot.zig drives.
pub var local: ?[2]bool = null;
/// How the last match ended beyond the World: a desync stops it.
pub var desynced = false;
/// Lobby: the host's cursor row and rules, this badge's ready flag.
var cursor: u8 = 0;
var rules: match.Rules = .{};
var ready = false;
var prev: Buttons = .{};
var results_frames: u32 = 0;
/// The tick the HUD and audio last saw (once per stepped tick).
var seen_tick: u32 = 0xFFFF_FFFF;
/// Preview only (wasm debug export): a made-up lobby to draw instead of the
/// real one, which is always NO LINK in the simulator.
pub var fake_lobby: ?LobbyView = null;

/// What the lobby screen shows.
pub const LobbyView = struct {
    st: lockstep.State,
    role: lockstep.Role = .none,
    rules: ?match.Rules = null,
    ready: bool = false,
    peer_ready: bool = false,
    can_go: bool = false,
    partner: u8 = 0,
};

/// From the title's DEATHMATCH entry: the lobby. The link is started the
/// first time (never in the campaign).
pub fn enter() void {
    if (!net_up) {
        net = Net.init(link.Badge.init(.{}, app_id, cart.rand()));
        net_up = true;
    }
    screen = .lobby;
    local = null;
    ready = false;
    desynced = false;
    net.set_pick(0, false);
}

/// A local match on `r` (debug exports, the bench): `bots[i]` = bot.zig
/// drives player i, otherwise the pad does (`view_slot`).
pub fn start_local(r: match.Rules, bots: [2]bool, seed: u32) void {
    local = bots;
    match.init_rules(&world, r, seed);
    begin_match();
}

fn begin_match() void {
    screen = .match;
    desynced = false;
    results_frames = 0;
    seen_tick = 0xFFFF_FFFF;
    var shown = shown_state();
    hud.set_rewinding(false);
    hud.meter_override = null;
    hud.tick(&shown);
    audio.reset(&shown);
}

/// One frame (input, step, draw). `t0` is `micros_since_boot` at the top
/// of `update`. False: back to the title.
pub fn update(pad: Buttons, t0: u64) bool {
    defer prev = pad;
    return switch (screen) {
        .lobby => lobby_frame(pad, t0),
        .match => match_frame(pad, t0),
        .results => results_frame(pad, t0),
    };
}

fn pressed(pad: Buttons, comptime f: []const u8) bool {
    return @field(pad, f) and !@field(prev, f);
}

// ---------------------------------------------------------------- lobby

fn lobby_frame(pad: Buttons, t0: u64) bool {
    if (net_up) net.pump(t0);
    if (pressed(pad, "b")) {
        if (net_up) net.set_pick(0, false);
        fake_lobby = null;
        return false;
    }
    if (fake_lobby == null and net_up) {
        if (net.state() == .lobby) {
            if (net.role == .host) {
                if (pressed(pad, "up")) cursor = if (cursor == 0) 2 else cursor - 1;
                if (pressed(pad, "down")) cursor = (cursor + 1) % 3;
                if (pressed(pad, "left") or pressed(pad, "right")) change_rule(pressed(pad, "right"));
                net.set_rules(.{rules.encode()});
            }
            if (pressed(pad, "a")) {
                ready = !ready;
                net.set_pick(0, ready);
            }
            if (net.role == .host and pressed(pad, "start") and net.can_go()) _ = net.go(t0);
        } else {
            ready = false;
        }
        if (net.take_started()) {
            const r = if (net.rules()) |b| match.Rules.decode(b[0]) else rules;
            view_slot = net.local_slot();
            local = null;
            match.init_rules(&world, r, net.seed());
            begin_match();
        }
    }
    draw_lobby(fake_lobby orelse lobby_view());
    return true;
}

fn change_rule(up: bool) void {
    switch (cursor) {
        0 => rules.arena = @intCast((rules.arena + 1) % levels.arena_indices.len),
        1 => rules.frags = if (up) (rules.frags + 1) & 3 else (rules.frags + 3) & 3,
        else => rules.bugs = !rules.bugs,
    }
}

fn lobby_view() LobbyView {
    if (!net_up) return .{ .st = .offline };
    const st = net.state();
    return .{
        .st = st,
        .role = net.role,
        .rules = if (net.role == .host) rules else if (net.rules()) |b| match.Rules.decode(b[0]) else null,
        .ready = ready,
        .peer_ready = net.peer_ready(),
        .can_go = net.can_go(),
        .partner = net.link.partner_app,
    };
}

pub fn draw_lobby(v: LobbyView) void {
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = hud.anti_black });
    centered("DEATHMATCH", 6, hud.coral);
    switch (v.st) {
        .offline => centered("NO LINK IN SIMULATOR", 52, hud.grey),
        .searching => {
            centered("PLUG IN THE CABLE", 46, hud.anti_white);
            centered("UART HEADER TO UART", 60, hud.grey);
        },
        .wrong_cart => {
            centered("WRONG CART:", 46, hud.coral);
            centered(lockstep.app_name(v.partner), 58, hud.anti_white);
        },
        .wrong_version => {
            centered("WRONG VERSION:", 46, hud.coral);
            centered("UPDATE BOTH BADGES", 58, hud.anti_white);
        },
        .lobby => draw_rules(v),
        // A match ended (results left) but the lockstep is not back in
        // the lobby yet: the next frame is.
        else => {},
    }
    centered("B: BACK", 118, hud.grey);
}

fn draw_rules(v: LobbyView) void {
    const host = v.role == .host;
    centered(if (host) "YOU HOST: PICK RULES" else "GUEST: HOST PICKS", 20, hud.iris);
    const labels = [3][]const u8{ "ARENA", "FRAGS", "BUGS" };
    var buf: [16]u8 = undefined;
    for (labels, 0..) |label, i| {
        const y: i32 = 36 + 12 * @as(i32, @intCast(i));
        const on = host and cursor == i;
        if (on) cart.text(.{ .str = ">", .x = 2, .y = y, .text_color = hud.coral });
        cart.text(.{ .str = label, .x = 12, .y = y, .text_color = hud.grey });
        const value: []const u8 = if (v.rules) |r| switch (i) {
            0 => levels.arena_names[r.arena],
            1 => fmt(&buf, "{d}", .{r.frag_limit()}),
            else => if (r.bugs) "ON" else "OFF",
        } else "...";
        cart.text(.{ .str = value, .x = 64, .y = y, .text_color = if (on) hud.anti_white else hud.grey });
    }
    cart.text(.{ .str = "YOU", .x = 12, .y = 76, .text_color = hud.grey });
    cart.text(.{ .str = if (v.ready) "READY" else "NOT READY", .x = 64, .y = 76, .text_color = if (v.ready) hud.green else hud.steel });
    cart.text(.{ .str = "THEM", .x = 12, .y = 88, .text_color = hud.grey });
    cart.text(.{ .str = if (v.peer_ready) "READY" else "NOT READY", .x = 64, .y = 88, .text_color = if (v.peer_ready) hud.green else hud.steel });
    if (host and v.can_go) {
        centered("START: FIGHT", 104, hud.coral);
    } else if (host) {
        centered("A: READY", 104, hud.anti_white);
    } else {
        centered("A: READY  HOST GOES", 104, hud.anti_white);
    }
}

// ---------------------------------------------------------------- match

fn arena() *const levels.Level {
    return &levels.all[world.gs.level];
}

/// The World from this badge's player: the campaign renderer, HUD and
/// audio read `GameState.player`, so they get a copy with it filled in.
fn shown_state() state.GameState {
    var s = world.gs;
    s.player = world.m.players[view_slot];
    s.hurt = world.m.hurt[view_slot];
    return s;
}

fn local_step(pad: Buttons) void {
    const bots = local.?;
    var in: [2]Buttons = .{ .{}, .{} };
    for (0..2) |i| {
        const slot: u1 = @intCast(i);
        if (bots[i]) {
            in[i] = bot.think(&world, arena(), slot);
        } else if (slot == view_slot) {
            in[i] = pad;
            in[i].start = false;
            in[i].select = pad.select and !pad.start;
        }
    }
    match.step(&world, arena(), in);
}

fn match_frame(pad: Buttons, t0: u64) bool {
    var ticked = false;
    if (local != null) {
        local_step(pad);
        ticked = true;
    } else {
        net.pump(t0);
        var byte = match.byte_of(pad);
        // Paused: only Start reaches the lockstep (it resumes); B leaves.
        if (net.paused) {
            if (pressed(pad, "b")) return leave_match(t0);
            byte &= match.bit_start;
        }
        net.submit(t0, byte);
        ticked = net.step(&world);
    }
    if (ticked) on_tick();
    draw_match(pad);
    if (local == null) {
        while (net.busy()) {
            const now = cart.micros_since_boot();
            if (now -% t0 >= pump_until_us) break;
            net.pump(now);
            if (!ticked) {
                ticked = net.step(&world);
                if (ticked) on_tick();
            }
        }
        if (net.state() == .desync) desynced = true;
    }
    if (world.m.over or desynced) {
        screen = .results;
        results_frames = 0;
    }
    return true;
}

fn on_tick() void {
    if (world.gs.tick == seen_tick) return;
    seen_tick = world.gs.tick;
    var shown = shown_state();
    hud.tick(&shown);
    audio.tick(&shown, arena());
}

fn leave_match(t0: u64) bool {
    net.leave(t0);
    screen = .lobby;
    ready = false;
    return true;
}

pub fn draw_match(pad: Buttons) void {
    const m = &world.m;
    const me = view_slot;
    const other = me ^ 1;
    const shown = shown_state();
    const dead = m.dead[me] > 0;
    const o = &m.players[other];
    sprites.show_enemies = m.bugs;
    sprites.rival = .{
        .x = fixed.to_f32(o.x),
        .y = fixed.to_f32(o.y),
        .cell = match.rival_cell(&shown.player, o, m.dead[other] > 0),
        .white = m.hurt[other] + 2 > sim.hurt_ticks,
    };
    view.shade_override = if (dead or shown.hurt > 0) 5 else null;
    view.draw(&shown, arena());
    sprites.rival = null;
    sprites.show_enemies = true;
    if (!dead) weapon.draw(&shown, pad.up or pad.down or (pad.b and (pad.left or pad.right)));
    hud.draw_bar(&shown);
    hud.draw_frags(m.frags[me], m.frags[other]);
    draw_banner();
    if (dead) {
        var buf: [16]u8 = undefined;
        band(fmt(&buf, "RESPAWN IN {d}", .{(@as(u32, m.dead[me]) + 59) / 60}), 46, hud.anti_white);
    }
    if (local == null) {
        if (net.paused) draw_pause();
        switch (net.state()) {
            .waiting => band("WAITING FOR PEER", 60, hud.iris),
            .desync => band("DESYNC", 60, hud.coral),
            else => {},
        }
    }
}

/// The latest death, from this badge's side, for `banner_ticks`.
fn draw_banner() void {
    const m = &world.m;
    if (m.kill_tick == state.no_shot or world.gs.tick -% m.kill_tick > banner_ticks) return;
    const me: u8 = view_slot;
    const msg: []const u8 = if (m.victim == me)
        (if (m.killer == me) "SELF-FRAG -1" else if (m.killer == me ^ 1) "FRAGGED BY THEM" else "EATEN BY BUGS")
    else if (m.killer == me)
        "YOU FRAGGED THEM"
    else if (m.killer == m.victim)
        "THEY SELF-FRAGGED"
    else
        "BUGS GOT THEM";
    band(msg, 22, if (m.killer == me and m.victim != me) hud.green else hud.coral);
}

fn band(str: []const u8, y: i32, color: cart.DisplayColor) void {
    cart.rect(.{ .x = 0, .y = y - 2, .width = 160, .height = 12, .fill_color = hud.anti_black });
    centered(str, y, color);
}

fn draw_pause() void {
    cart.rect(.{ .x = 16, .y = 30, .width = 128, .height = 44, .fill_color = hud.anti_black, .stroke_color = hud.grey });
    centered("PAUSED", 36, hud.anti_white);
    centered("START: RESUME", 50, hud.grey);
    centered("B: LEAVE MATCH", 62, hud.grey);
}

// ---------------------------------------------------------------- results

fn results_frame(pad: Buttons, t0: u64) bool {
    results_frames += 1;
    if (local == null) {
        // Keep the partner fed until we leave (it may still need a late tick).
        net.pump(t0);
        net.submit(t0, 0);
        _ = net.step(&world);
    }
    draw_results();
    if (results_frames >= results_min and (pressed(pad, "a") or pressed(pad, "start"))) {
        if (local != null) {
            local = null;
            screen = .lobby;
            return true;
        }
        return leave_match(t0);
    }
    return true;
}

pub fn draw_results() void {
    const m = &world.m;
    const me: u8 = view_slot;
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = hud.anti_black });
    if (desynced) {
        centered("MATCH STOPPED", 10, hud.anti_white);
        band("DESYNC", 24, hud.coral);
    } else if (m.winner == me) {
        centered(if (m.forfeit) "YOU WIN: FORFEIT" else "YOU WIN", 10, hud.green);
    } else if (m.winner == state.no_one) {
        centered("DRAW", 10, hud.iris);
    } else {
        centered("YOU LOSE", 10, hud.coral);
    }
    if (m.forfeit) band("PEER LEFT", 24, hud.iris);
    hud.text_right("YOU", 103, 42, hud.green);
    hud.text_right("THEM", 151, 42, hud.coral);
    const o = me ^ 1;
    var buf: [8]u8 = undefined;
    const rows = [3][]const u8{ "FRAGS", "SHOTS", "ACC" };
    for (rows, 0..) |label, i| {
        const y: i32 = 56 + 12 * @as(i32, @intCast(i));
        cart.text(.{ .str = label, .x = 8, .y = y, .text_color = hud.grey });
        for ([2]u8{ me, o }, 0..) |slot, k| {
            const str: []const u8 = switch (i) {
                0 => hud.signed(&buf, m.frags[slot]),
                1 => fmt(&buf, "{d}", .{m.shots[slot]}),
                else => fmt(&buf, "{d}%", .{accuracy(m, slot)}),
            };
            hud.text_right(str, 103 + 48 * @as(i32, @intCast(k)), y, hud.anti_white);
        }
    }
    var lbuf: [24]u8 = undefined;
    centered(fmt(&lbuf, "{s}, TO {d}", .{ levels.arena_names[m.arena], m.frag_limit }), 96, hud.grey);
    if (results_frames >= results_min and (results_frames / 30) % 2 == 0) centered("PRESS A", 112, hud.anti_white);
}

fn accuracy(m: *const state.Match, slot: usize) u32 {
    if (m.shots[slot] == 0) return 0;
    return @as(u32, m.hits[slot]) * 100 / m.shots[slot];
}

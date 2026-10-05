//! Party deathmatch screens and glue (M8, up to 16 badges; SPEC.md section
//! 20, PLAN.md M8): `LockstepN` over the fork firmware's cart serial port
//! and the laptop's `badge lobby` relay (root docs/LOCKSTEP_N.md), with
//! `match.GN` as the game. The title's PARTY entry hands every frame here
//! until B backs out; the campaign and the M7 cable (deathmatch.zig) never
//! reach this file, and the port is opened only on the first entry.
//!
//! - Lobby: the roster (two columns of eight, slot colour, ready tick),
//!   the host's rules (arena preselected for the head count, frags, bugs,
//!   teams, input delay with the suggestion from everyone's round trips),
//!   each player's team (Left/Right before ready), A ready, the host's
//!   Start goes. A badge that joins during a match waits ("MATCH IN
//!   PROGRESS").
//! - Match: pump at the top of `update`, submit this frame's byte, step,
//!   draw from this badge's slot, then pump in a loop to 14 ms into the
//!   frame while the lockstep wants it: every frame drains the receive
//!   ring (the relay removes a badge that stops reading). Leavers become
//!   bots (`match.GN.hand_over`); DESYNC ends the match, DROPPED returns to
//!   the lobby; Start pauses everyone (the lockstep's pause bit).
//! - Results: the table; A leaves the race (back to the lobby).
//!
//! Without the firmware (the simulator, badge-bench) a *local* match runs
//! instead: bot.zig on every slot (or the pad on `view_slot`), one tick a
//! frame. main.zig's debug exports and `stein_party_bench` start one;
//! `fake` draws a made-up lobby for the previews.
const std = @import("std");
const cart = @import("cart-api");
const lockstep_n = @import("lockstep_n");
const cart_serial = @import("cart_serial");
const build_options = @import("build_options");
const state = @import("state.zig");
const levels = @import("levels.zig");
const sim = @import("sim.zig");
const match = @import("match.zig");
const deathmatch = @import("deathmatch.zig");
const sprites = @import("render/sprites.zig");
const hud = @import("render/hud.zig");
const scoreboard = @import("render/scoreboard.zig");
const slots = @import("render/slots.zig");
const tracker = @import("render/tracker.zig");
const audio = @import("audio.zig");

const Buttons = state.Buttons;
const centered = hud.centered;
const fmt = hud.fmt;
const band = deathmatch.band;
const max = state.max_players;
const name_len = lockstep_n.party.name_len;

pub const Port = cart_serial.Badge(.{});
pub const Party = lockstep_n.LockstepN(Port, match.GN);

/// The name this badge goes by in every roster (no text entry on the badge).
pub const player_name = "SNOUTY";
/// Pump until this far into the frame while the lockstep wants it.
pub const pump_until_us: u64 = 14_000;
const results_min: u32 = 60;
/// "P7 LEFT: BOT" stays this long (frames); "YOU WERE DROPPED" at most
/// this long before the lobby.
const notice_frames: u32 = 120;
const dropped_frames: u32 = 240;
/// The host's DELAY row: 0 = AUTO (`suggested_delay`), else ticks.
const delays = [_]u8{ 0, 2, 3, 4, 6, 8, 12 };

pub const Screen = enum(u8) { lobby = 0, match = 1, results = 2, dropped = 3 };

pub var screen: Screen = .lobby;
var pt: Party = undefined;
var pt_up = false;
/// The port is open. Never without -Dstein_party (main): there is no
/// PARTY row, so the lockstep and the cart serial port are compiled out
/// and only the local match (the bench, the previews) remains.
inline fn port_up() bool {
    return build_options.party and pt_up;
}
/// No lockstep under the match: bots and the pad only.
inline fn is_local() bool {
    return !build_options.party or local;
}
/// The match World is M7's (one mode runs at a time).
const world = &deathmatch.world;
/// The slot this badge shows (its lobby id; in a local match any slot).
pub var view_slot: u8 = 0;
/// Local match (no lockstep): bot.zig drives every slot but `view_slot`
/// when `local_pad`.
pub var local = false;
pub var local_pad = false;
pub var desynced = false;
var prev: Buttons = .{};
var results_frames: u32 = 0;
var seen_tick: u32 = 0xFFFF_FFFF;
/// Names by slot, copied from the roster when a race starts (a leaver
/// keeps its name); `names_n` = 0 means "P1".."P16".
var name_store: [max][name_len]u8 = undefined;
var names_buf: [max][]const u8 = undefined;
var names_n: usize = 0;
/// Lobby: the host's cursor and rules, this badge's team and ready flag.
var cursor: u8 = 0;
var rules: match.Rules = .{};
/// The arena follows the head count until the host picks one.
var arena_auto = true;
var delay_i: u8 = 0;
var team_choice: ?u8 = null;
var ready = false;
/// The leave notice: a slot handed to a bot, frames left.
var prev_bots: u16 = 0;
var notice_slot: u8 = 0;
var notice_left: u32 = 0;
/// Preview only (wasm debug export): a made-up lobby to draw instead of
/// the real one, which is always NEEDS PARTY FIRMWARE in the simulator.
pub var fake: ?LobbyView = null;

/// The firmware serves the cart serial port (`os_flags` bit 1). Never true
/// in the web simulator or badge-bench.
pub fn supported() bool {
    var p: Port = .{};
    return p.supported();
}

/// From the title's PARTY entry: the lobby. The port is opened (and the
/// room joined) the first time; later entries rejoin.
pub fn enter() void {
    if (!pt_up) {
        pt = Party.init(.{}, .{ .game = lockstep_n.games.snoutenstein, .name = lockstep_n.party.pad(name_len, player_name) }, cart.rand());
        pt_up = true;
    } else {
        pt.enter();
    }
    screen = .lobby;
    local = false;
    ready = false;
    desynced = false;
    cursor = 0;
    arena_auto = true;
}

/// A local match (debug exports, the bench): the slots in `present`, all
/// on bot.zig, or the pad on `view_slot` when `pad`.
pub fn start_local(r: match.Rules, present: u16, seed: u32, pad: bool) void {
    local = true;
    local_pad = pad;
    match.init_party(world, r, present, null, seed);
    tracker.on = r.radar;
    world.m.bots = present;
    if (pad) world.m.bots &= ~(@as(u16, 1) << @intCast(view_slot & 15));
    begin_match();
}

/// Names for a local match ("P1".. when empty).
pub fn set_local_names(list: []const []const u8) void {
    names_n = @min(list.len, max);
    for (list[0..names_n], 0..) |n, i| names_buf[i] = n;
}

fn names() []const []const u8 {
    return names_buf[0..names_n];
}

fn begin_match() void {
    screen = .match;
    desynced = false;
    results_frames = 0;
    seen_tick = 0xFFFF_FFFF;
    tracker.reset();
    prev_bots = world.m.bots;
    notice_left = 0;
    const shown = shown_state();
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
        .dropped => dropped_frame(pad, t0),
    };
}

fn pressed(pad: Buttons, comptime f: []const u8) bool {
    return @field(pad, f) and !@field(prev, f);
}

/// Pump until `pump_until_us` into the frame while the lockstep wants it.
fn pump_rest(t0: u64) void {
    while (pt.wants_pump()) {
        const now = cart.micros_since_boot();
        if (now -% t0 >= pump_until_us) break;
        pt.pump(now);
    }
}

// ---------------------------------------------------------------- lobby

fn lobby_frame(pad: Buttons, t0: u64) bool {
    const real = fake == null and port_up();
    if (real) pt.pump(t0);
    if (pressed(pad, "b")) {
        if (real) pt.exit(t0);
        fake = null;
        return false;
    }
    if (real) {
        const st = pt.state();
        if (st == .idle) pt.enter();
        if (st == .lobby) lobby_input(pad, t0) else ready = false;
        if (pt.take_started()) {
            // GO (this badge's or the host's): the match from this frame.
            start_race();
            draw_match(pad);
            pump_rest(t0);
            return true;
        }
    }
    draw_lobby(fake orelse lobby_view());
    if (real) pump_rest(t0);
    return true;
}

/// The team mode the lobby shows: the host's own, else the host's SETUP.
fn lobby_rules() ?match.Rules {
    if (pt.is_host()) return rules;
    if (pt.rules()) |b| return match.Rules.decode2(b);
    return null;
}

fn my_team(teams: u8, me: u8) u8 {
    return (team_choice orelse me) % teams;
}

/// Host rows: arena, frags, bugs, teams, your team (team modes), radar
/// (M9.3), delay.
const row_arena = 0;
const row_frags = 1;
const row_bugs = 2;
const row_teams = 3;
const row_team = 4;
const row_radar = 5;
const row_delay = 6;
const rows = 7;

fn lobby_input(pad: Buttons, t0: u64) void {
    const me = pt.local_slot();
    const host = pt.is_host();
    if (host) {
        const n: u8 = @popCount(pt.present());
        if (arena_auto) rules.arena = levels.suggest_arena(n);
        if (pressed(pad, "up") or pressed(pad, "down")) {
            const step: u8 = if (pressed(pad, "down")) 1 else rows - 1;
            cursor = (cursor + step) % rows;
            if (cursor == row_team and rules.teams == 0) cursor = (cursor + step) % rows;
        }
        if (pressed(pad, "left") or pressed(pad, "right")) change_rule(pressed(pad, "right"), me);
        pt.set_rules(rules.encode2());
        pt.set_delay(if (delays[delay_i] == 0) pt.suggested_delay() else delays[delay_i]);
    } else {
        cursor = row_team;
    }
    const lr = lobby_rules();
    const teams: u8 = if (lr) |r| r.teams else 0;
    if (!host and teams != 0 and !ready and (pressed(pad, "left") or pressed(pad, "right"))) change_team(pressed(pad, "right"), teams, me);
    if (pressed(pad, "a")) ready = !ready;
    pt.set_pick(if (teams != 0) my_team(teams, me) + 1 else 0, ready);
    if (host and pressed(pad, "start") and pt.can_go()) _ = pt.go(t0);
}

fn change_team(up: bool, teams: u8, me: u8) void {
    const t = my_team(teams, me);
    team_choice = if (up) (t + 1) % teams else (t + teams - 1) % teams;
}

fn change_rule(up: bool, me: u8) void {
    switch (cursor) {
        row_arena => {
            arena_auto = false;
            const n: u8 = levels.arena_indices.len;
            rules.arena = if (up) (rules.arena + 1) % n else (rules.arena + n - 1) % n;
        },
        row_frags => {
            const n: u8 = match.frag_limits.len;
            rules.frags = if (up) (rules.frags + 1) % n else (rules.frags + n - 1) % n;
        },
        row_bugs => rules.bugs = !rules.bugs,
        row_radar => rules.radar = !rules.radar,
        row_teams => rules.teams = switch (rules.teams) {
            0 => if (up) 2 else 4,
            2 => if (up) 4 else 0,
            else => if (up) 0 else 2,
        },
        row_team => if (rules.teams != 0 and !ready) change_team(up, rules.teams, me),
        else => {
            const n: u8 = delays.len;
            delay_i = if (up) (delay_i + 1) % n else (delay_i + n - 1) % n;
        },
    }
}

/// GO arrived (or this badge sent it): the World from the race's rules,
/// participants, picks (teams) and seed; names from the roster.
fn start_race() void {
    const r = pt.rules() orelse rules.encode2();
    const picks = pt.picks();
    const team = match.GN.team_of(&picks);
    const mask = pt.participants();
    match.GN.start(world, r, mask, &team, pt.seed());
    tracker.on = match.Rules.decode2(r).radar;
    for (0..max) |i| {
        const n = pt.name(@intCast(i));
        const k = @min(n.len, name_len);
        @memcpy(name_store[i][0..k], n[0..k]);
        names_buf[i] = name_store[i][0..k];
    }
    names_n = max;
    view_slot = pt.local_slot();
    local = false;
    ready = false;
    begin_match();
}

/// What the lobby screen shows (from the lockstep, or made up).
pub const LobbyView = struct {
    st: lockstep_n.State,
    me: u8 = 0,
    host: bool = false,
    present: u16 = 0,
    ready: u16 = 0,
    other_version: u16 = 0,
    /// Slots that pick a team (team modes): their team; else 0xFF.
    team: [max]u8 = @splat(0xFF),
    names: [max][]const u8 = @splat(""),
    rules: ?match.Rules = null,
    delay: u8 = match.GN.input_delay,
    delay_auto: bool = true,
    suggested: u8 = match.GN.input_delay,
    can_go: bool = false,
    running: bool = false,
};

fn lobby_view() LobbyView {
    if (!port_up()) return .{ .st = .unsupported };
    var v: LobbyView = .{ .st = pt.state() };
    if (v.st != .lobby) return v;
    v.me = pt.local_slot();
    v.host = pt.is_host();
    v.present = pt.present();
    v.ready = pt.ready_mask();
    v.other_version = pt.other_version_mask();
    v.rules = lobby_rules();
    v.delay = @intCast(pt.delay_offer());
    v.delay_auto = delays[delay_i] == 0;
    v.suggested = @intCast(pt.suggested_delay());
    v.can_go = pt.can_go();
    v.running = pt.match_running();
    const teams: u8 = if (v.rules) |r| r.teams else 0;
    for (0..max) |i| {
        const s: u4 = @intCast(i);
        v.names[i] = pt.name(s);
        if (teams == 0) continue;
        if (pt.peer_pick_of(s)) |p| v.team[i] = (if (p == 0 or p > 4) s else p - 1) % teams;
    }
    if (teams != 0) v.team[v.me] = my_team(teams, v.me);
    return v;
}

pub fn draw_lobby(v: LobbyView) void {
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = hud.anti_black });
    cart.text(.{ .str = "PARTY", .x = 2, .y = 0, .text_color = hud.coral });
    switch (v.st) {
        .unsupported => {
            centered("NEEDS PARTY FIRMWARE", 44, hud.anti_white);
            centered("FLASH THE FORK OS", 58, hud.grey);
            centered("(RUNNING.MD 8)", 70, hud.grey);
        },
        .disconnected => {
            centered("START BADGE LOBBY", 40, hud.anti_white);
            centered("ON THE LAPTOP", 52, hud.anti_white);
            centered("badge.py lobby", 68, hud.grey);
        },
        .lobby => draw_room(v),
        // joining, idle; or a race between GO and this frame's switch.
        else => centered("JOINING...", 52, hud.iris),
    }
    if (v.st != .lobby) centered("B: BACK", 118, hud.grey);
}

fn draw_room(v: LobbyView) void {
    var buf: [24]u8 = undefined;
    const n: u8 = @popCount(v.present);
    hud.text_right(fmt(&buf, "{d}/16", .{n}), 159, 0, hud.grey);
    if (v.host) centered("HOST", 0, hud.iris);
    const r = v.rules;
    const teams: u8 = if (r) |x| x.teams else 0;
    // Rules: three lines, two fields on the second and third.
    field(row_arena, 2, 9, "ARENA", if (r) |x| levels.arena_names[x.arena] else "...", v, if (r != null and n > levels.arena_max_players[r.?.arena]) hud.coral else null);
    field(row_frags, 2, 18, "FRAGS", if (r) |x| fmt(buf[0..4], "{d}", .{x.frag_limit()}) else "...", v, null);
    field(row_bugs, 80, 18, "BUGS", if (r) |x| (if (x.bugs) "ON" else "OFF") else "...", v, null);
    field(row_teams, 2, 27, "TEAMS", if (r) |x| (if (x.teams == 0) "FFA" else if (x.teams == 2) "2" else "4") else "...", v, null);
    if (teams != 0 and v.team[v.me] < 4) {
        const t = v.team[v.me];
        const on = cursor == row_team;
        if (on) cart.text(.{ .str = ">", .x = 80, .y = 27, .text_color = hud.coral });
        cart.rect(.{ .x = 90, .y = 28, .width = 6, .height = 6, .fill_color = slots.team_color(t) });
        cart.text(.{ .str = slots.team_names[t], .x = 99, .y = 27, .text_color = slots.team_color(t) });
    }
    field(row_radar, 2, 36, "RADAR", if (r) |x| (if (x.radar) "ON" else "OFF") else "...", v, null);
    // The host's DELAY (M9.3: right of RADAR): AUTO n, or DELAY n with
    // the suggestion on the hint line while the cursor is on it.
    if (v.host) {
        var dbuf: [4]u8 = undefined;
        field(row_delay, 80, 36, if (v.delay_auto) "AUTO" else "DELAY", fmt(&dbuf, "{d}", .{v.delay}), v, null);
    }
    cart.rect(.{ .x = 0, .y = 45, .width = 160, .height = 1, .fill_color = hud.trough });
    draw_roster(v, teams);
    // Status line and hint line.
    const ready_n: u8 = @popCount(v.ready & v.present);
    const me_ready = v.ready >> @intCast(v.me) & 1 == 1;
    if (v.running) {
        centered("MATCH IN PROGRESS", 112, hud.iris);
    } else if (v.host and v.can_go) {
        centered("START: GO!", 112, hud.coral);
    } else if (v.host and me_ready) {
        centered(if (ready_n >= 2 and teams != 0) "NEED 2 TEAMS" else fmt(&buf, "{d} READY, NEED 2", .{ready_n}), 112, hud.grey);
    } else if (me_ready) {
        centered("READY: HOST STARTS", 112, hud.green);
    } else if (r == null) {
        centered("WAITING FOR HOST", 112, hud.grey);
    } else {
        centered("A: READY", 112, hud.anti_white);
    }
    if (v.host and cursor == row_delay and !v.delay_auto) {
        centered(fmt(&buf, "AUTO: {d}  B: BACK", .{v.suggested}), 120, hud.grey);
    } else {
        centered(if (teams != 0 and !me_ready) "<>: TEAM  B: BACK" else "B: BACK", 120, hud.grey);
    }
}

/// One rules field: the cursor (host), the label, the value.
fn field(row: u8, x: i32, y: i32, label: []const u8, value: []const u8, v: LobbyView, color: ?cart.DisplayColor) void {
    const on = v.host and cursor == row;
    if (on) cart.text(.{ .str = ">", .x = x, .y = y, .text_color = hud.coral });
    cart.text(.{ .str = label, .x = x + 8, .y = y, .text_color = hud.grey });
    const vx = x + 8 + 8 * @as(i32, @intCast(label.len + 1));
    cart.text(.{ .str = value, .x = vx, .y = y, .text_color = color orelse if (on) hud.anti_white else hud.grey });
}

/// The players in id order, two columns of eight: swatch (slot colour, or
/// the team's), name (yours highlighted, another version in Coral), a
/// green tick when ready.
fn draw_roster(v: LobbyView, teams: u8) void {
    var k: i32 = 0;
    for (0..max) |i| {
        if (v.present >> @intCast(i) & 1 == 0) continue;
        const x0: i32 = 80 * @divTrunc(k, 8);
        const y: i32 = 47 + 8 * @mod(k, 8);
        k += 1;
        const mine = i == v.me;
        if (mine) cart.rect(.{ .x = x0, .y = y, .width = 80, .height = 8, .fill_color = hud.steel });
        const c = if (teams != 0 and v.team[i] < 4) slots.team_color(v.team[i]) else slots.color(@intCast(i));
        cart.rect(.{ .x = x0 + 2, .y = y + 1, .width = 5, .height = 5, .fill_color = c });
        var nbuf: [4]u8 = undefined;
        const nm = if (v.names[i].len > 0) v.names[i] else slots.name(&.{}, i, &nbuf);
        const other = v.other_version >> @intCast(i) & 1 == 1;
        cart.text(.{ .str = nm[0..@min(nm.len, 7)], .x = x0 + 9, .y = y, .text_color = if (other) hud.coral else hud.anti_white });
        if (v.ready >> @intCast(i) & 1 == 1) {
            // A tick, 2 px thick: down-right then up-right (upstream's
            // `line` does not compile on this SDK pin).
            const px: cart.Pixel = .from_color(hud.green);
            const ys = [8]i32{ 3, 4, 5, 4, 3, 2, 1, 0 };
            for (ys, 0..) |dy, dx| {
                const xx: usize = @intCast(x0 + 69 + @as(i32, @intCast(dx)));
                const yy: usize = @intCast(y + dy);
                cart.framebuffer[xx][yy] = px;
                cart.framebuffer[xx][yy + 1] = px;
            }
        }
    }
}

// ---------------------------------------------------------------- match

fn arena() *const levels.Level {
    return &levels.all[world.gs.level];
}

/// The World from this badge's slot: the campaign renderer, HUD and audio
/// read `GameState.player`, so they get a copy with it filled in.
fn shown_state() state.GameState {
    var s = world.gs;
    s.player = world.m.players[view_slot];
    s.hurt = world.m.hurt[view_slot];
    return s;
}

fn local_step(pad: Buttons) void {
    var in: [max]Buttons = @splat(.{});
    if (local_pad) {
        in[view_slot] = pad;
        in[view_slot].start = false;
        in[view_slot].select = pad.select and !pad.start;
    }
    match.step_n(world, arena(), &in);
}

fn match_frame(pad: Buttons, t0: u64) bool {
    var ticked = false;
    if (is_local()) {
        local_step(pad);
        ticked = true;
    } else {
        pt.pump(t0);
        var byte = match.byte_of(pad);
        // Paused: only Start reaches the lockstep (it resumes); B leaves.
        if (pt.paused) {
            if (pressed(pad, "b")) return leave_race(t0);
            byte &= match.bit_start;
        }
        pt.submit(t0, byte);
        ticked = pt.step(world);
    }
    if (ticked) on_tick();
    draw_match(pad);
    if (!is_local()) {
        while (pt.wants_pump()) {
            const now = cart.micros_since_boot();
            if (now -% t0 >= pump_until_us) break;
            pt.pump(now);
            if (!ticked) {
                ticked = pt.step(world);
                if (ticked) on_tick();
            }
        }
        switch (pt.state()) {
            .desync => desynced = true,
            .dropped => {
                screen = .dropped;
                results_frames = 0;
                return true;
            },
            // The laptop's relay went away mid-match: back to the lobby
            // screen, which says what to do.
            .racing, .waiting => {},
            else => {
                screen = .lobby;
                return true;
            },
        }
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
    const shown = shown_state();
    hud.tick(&shown);
    audio.tick(&shown, arena());
    tracker.tick(&world.m, view_slot, world.gs.tick);
    // A human left (or was dropped): the notice names the slot.
    const gone = world.m.bots & ~prev_bots;
    prev_bots = world.m.bots;
    if (gone != 0 and !is_local()) {
        notice_slot = @ctz(gone);
        notice_left = notice_frames;
    }
}

fn leave_race(t0: u64) bool {
    pt.leave(t0);
    screen = .lobby;
    ready = false;
    return true;
}

pub fn draw_match(pad: Buttons) void {
    const m = &world.m;
    const me = view_slot;
    const shown = shown_state();
    const dead = m.dead[me] > 0;
    sprites.show_enemies = m.bugs;
    sprites.set_rivals(m, me, &shown.player);
    deathmatch.draw_view(m, me, &shown, pad);
    sprites.clear_rivals();
    scoreboard.draw_rank(m, me);
    scoreboard.draw_kill_feed(m, me, names(), world.gs.tick);
    var buf: [24]u8 = undefined;
    if (dead) deathmatch.draw_dead(m, me);
    if (notice_left > 0) {
        notice_left -= 1;
        var nbuf: [4]u8 = undefined;
        band(fmt(&buf, "{s} LEFT: BOT", .{slots.name(names(), notice_slot, &nbuf)}), 14, hud.iris);
    }
    if (pad.select) scoreboard.draw_scoreboard(m, me, names());
    if (!is_local()) {
        if (pt.paused) deathmatch.draw_pause();
        switch (pt.state()) {
            .waiting => band("WAITING FOR PLAYERS", 60, hud.iris),
            .desync => band("DESYNC", 60, hud.coral),
            else => {},
        }
    }
}

// ---------------------------------------------------------------- dropped

fn dropped_frame(pad: Buttons, t0: u64) bool {
    results_frames += 1;
    if (!is_local()) pt.pump(t0);
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = hud.anti_black });
    band("YOU WERE DROPPED", 46, hud.coral);
    centered("TOO LONG SILENT", 62, hud.grey);
    centered("A: BACK TO LOBBY", 110, hud.anti_white);
    if (results_frames >= dropped_frames or (results_frames >= results_min and pressed(pad, "a"))) {
        if (!is_local()) return leave_race(t0);
        screen = .lobby;
    }
    if (!is_local()) pump_rest(t0);
    return true;
}

// ---------------------------------------------------------------- results

fn results_frame(pad: Buttons, t0: u64) bool {
    results_frames += 1;
    if (!is_local()) {
        // Keep feeding the others until we leave (they may need a late tick).
        pt.pump(t0);
        pt.submit(t0, 0);
        _ = pt.step(world);
    }
    draw_results();
    if (!is_local()) pump_rest(t0);
    if (results_frames >= results_min and (pressed(pad, "a") or pressed(pad, "start"))) {
        if (!is_local()) return leave_race(t0);
        local = false;
        screen = .lobby;
    }
    return true;
}

pub fn draw_results() void {
    const m = &world.m;
    const me = view_slot;
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = hud.anti_black });
    var buf: [24]u8 = undefined;
    var nbuf: [4]u8 = undefined;
    if (desynced) {
        centered("DESYNC: STOPPED", 0, hud.coral);
    } else if (m.winner == me) {
        centered(if (m.forfeit) "YOU WIN: FORFEIT" else "YOU WIN", 0, hud.green);
    } else if (m.winner == state.no_one) {
        centered("DRAW", 0, hud.iris);
    } else if (m.winner & state.team_win != 0) {
        const t = m.winner & 3;
        centered(fmt(&buf, "{s} TEAM WINS", .{slots.team_names[t]}), 0, if (t == m.team[me]) hud.green else slots.team_color(t));
    } else {
        centered(fmt(&buf, "{s} WINS", .{slots.name(names(), m.winner, &nbuf)}), 0, slots.slot_color(m, m.winner));
    }
    const y = scoreboard.draw_results_table(m, me, names(), 10);
    if (y <= 120 and results_frames >= results_min and (results_frames / 30) % 2 == 0) centered("PRESS A", 120, hud.anti_white);
}

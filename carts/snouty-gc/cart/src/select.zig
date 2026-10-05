//! New for Snouty GC (M1 Track B): the racer select (SPEC 8.1), the first
//! screen of every mode, laid out as docs/art_select_mock.png: the 48x48
//! portrait in a livery frame top left, the name and car to its right, the
//! car turning on its yaw cells over a plinth, the SPD/ARM/DMG bars, the
//! front weapon (A) and the rear weapon (Down+A), the 4-line bio, and the
//! cycling row along the bottom. Left/Right cycle the six racers; Down
//! moves to the track row (M3: Left/Right cycle every track in
//! `track.tracks`, and the bio's place shows the track: name, league, the
//! mode's rule, its hazards and its outline), Up back; A (or Start) on
//! either row starts the race with the racer shown; B goes back to the
//! menu. Everything is drawn 4 px clear of the edges.
const cart = @import("cart-api");
const world = @import("world.zig");
const racers = @import("racers.zig");
const track = @import("track.zig");
const roster_text = @import("roster_text.zig");
const sprites = @import("sprites.zig");
const hud = @import("hud.zig");
const input = @import("input.zig");
const sound = @import("sound.zig");
const net = @import("net.zig");
const link_ui = @import("link_ui.zig");

/// The racer and track shown (main.zig reads them on a pick).
pub var racer: u8 = racers.snouty;
pub var track_index: u8 = 0;
/// 0 the racer row, 1 the track row.
var row: u8 = 0;
/// The mode the race will be (the track panel names its rule).
var gc_mode: bool = false;
/// Frames since the racer last changed (the turntable).
var frames: u32 = 0;

pub const Action = enum { none, pick, back };

/// M4: the link race's select (SPEC 7.3), set by main.zig every frame
/// (null: single player). No track row (the host's lobby picks it); A
/// marks this badge ready on a racer the partner has not taken, and the
/// panel under the stats shows the rules, the partner's pick and both
/// ready marks.
pub const Link = struct {
    host: bool = false,
    ready: bool = false,
    /// The partner's pick (null: not heard since the lobby began).
    peer: ?net.Pick = null,
    /// Host: both are ready on different racers (A starts the race).
    can_go: bool = false,
    rules: ?net.Rules = null,
};
pub var link: ?Link = null;

/// The racer `r` is the partner's, ready: not for this badge.
pub fn taken(r: u8) bool {
    const l = link orelse return false;
    const p = l.peer orelse return false;
    return p.ready and p.racer == r;
}

pub fn enter(r: u8, t: u8, gc: bool) void {
    racer = r % racers.count;
    track_index = t % @as(u8, @intCast(track.tracks.len));
    row = 0;
    frames = 0;
    gc_mode = gc;
    hud.init_minimap(track.tracks[track_index]);
}

/// One frame of input.
pub fn update() Action {
    frames +%= 1;
    if (input.pressed(.a) or input.pressed(.start)) {
        sound.menu_confirm();
        return .pick;
    }
    if (input.pressed(.b)) return .back;
    if (link) |l| {
        // A ready badge keeps its racer; B takes the mark back.
        if (l.ready) return .none;
    } else if (input.pressed(.down) and row == 0) {
        row = 1;
        sound.menu_move();
    }
    if (input.pressed(.up) and row == 1) {
        row = 0;
        sound.menu_move();
    }
    const step: i32 = @as(i32, @intFromBool(input.pressed(.right))) - @as(i32, @intFromBool(input.pressed(.left)));
    if (step != 0) {
        sound.menu_move();
        if (row == 0) {
            racer = @intCast(@mod(@as(i32, racer) + step, racers.count));
            frames = 0;
        } else {
            const n: i32 = @intCast(track.tracks.len);
            track_index = @intCast(@mod(@as(i32, track_index) + step, n));
            hud.init_minimap(track.tracks[track_index]);
        }
    }
    return .none;
}

const bg = cart.DisplayColor.rgb(0x100E16);
const panel = cart.DisplayColor.rgb(0x221E2C);
const ink = cart.DisplayColor.rgb(0xECE8F0);
const dim = cart.DisplayColor.rgb(0x9692A4);
const rule = cart.DisplayColor.rgb(0x464056);

fn plain(str: []const u8, x: i32, y: i32, color: cart.DisplayColor) void {
    @import("font.zig").draw(str, x, y, .from_color(color), null);
}

/// Turntable (SPEC 8.1, 5 yaws): rear, quarter right, side right and back,
/// then the mirrored side, 20 frames a view, starting on the quarter view.
const turntable = [8]struct { cell: u8, flip: bool }{
    .{ .cell = sprites.car_quarter, .flip = false }, .{ .cell = sprites.car_side, .flip = false },
    .{ .cell = sprites.car_quarter, .flip = false }, .{ .cell = sprites.car_rear, .flip = false },
    .{ .cell = sprites.car_quarter, .flip = true },  .{ .cell = sprites.car_side, .flip = true },
    .{ .cell = sprites.car_quarter, .flip = true },  .{ .cell = sprites.car_rear, .flip = false },
};
const view_frames: u32 = 20;

/// The plinth under the turntable: an ellipse of radii (rx, ry) by spans.
fn plinth(cx: i32, cy: i32, rx: i32, ry: i32, color: cart.DisplayColor) void {
    var dy: i32 = -ry;
    while (dy <= ry) : (dy += 1) {
        // Half width at this row: rx * sqrt(1 - (dy/ry)^2), integer.
        const t = ry * ry - dy * dy;
        var hw: i32 = 0;
        while ((hw + 1) * (hw + 1) * ry * ry <= t * rx * rx) hw += 1;
        hud.fill_rect(cx - hw, cy + dy, 2 * hw + 1, 1, color);
    }
}

pub fn draw(frame: u32) void {
    const r = racer;
    const ro = racers.roster[r];
    const txt = roster_text.roster[r];
    const st = roster_text.stats[r];
    const liv = hud.livery(r);
    hud.fill_rect(0, 0, 160, 128, bg);
    // Portrait in a livery frame.
    hud.fill_rect(4, 4, 50, 50, liv);
    sprites.blit_at(&sprites.portraits[r], 0, 5, 5, .{});
    if (taken(r)) {
        hud.fill_rect(5, 24, 48, 11, hud.anti_black);
        plain("TAKEN", 9, 26, hud.coral);
    }
    // Name and car.
    plain(ro.name, 58, 5, liv);
    plain(ro.car, 58, 15, ink);
    // The car on its turntable.
    plinth(74, 44, 17, 4, panel);
    const v = turntable[(frames / view_frames) % turntable.len];
    sprites.blit_cell(&sprites.cars[r], v.cell, 58, 30, 32, 16, .{ .flip = v.flip });
    // Stat bars.
    const vals = [3]u8{ st.spd, st.arm, st.dmg };
    const labels = [3][]const u8{ "SPD", "ARM", "DMG" };
    for (vals, labels, 0..) |val, lab, k| {
        const y: i32 = 26 + @as(i32, @intCast(k)) * 9;
        plain(lab, 96, y, dim);
        var j: i32 = 0;
        while (j < 8) : (j += 1) {
            hud.fill_rect(121 + j * 4, y + 1, 3, 6, if (j < val) liv else rule);
        }
    }
    // Weapons: A fires the front gun, Down+A drops the rear one.
    plain("A", 4, 57, liv);
    plain(roster_text.front_name(ro.front), 24, 57, ink);
    hud.down_arrow(4, 67, liv);
    plain("A", 11, 66, liv);
    plain(roster_text.rear_name(ro.rear), 24, 66, ink);
    hud.fill_rect(4, 76, 152, 1, rule);
    if (link) |*l| return draw_link_panel(l, frame);
    if (row == 1) {
        draw_track_panel();
    } else {
        for (txt.bio, 0..) |line, k| plain(line, 4, 79 + @as(i32, @intCast(k)) * 9, ink);
    }
    // The cycling row: racers (A PICK, Down for the track) or the track.
    const blink = (frame / 20) % 2 == 0;
    const arrow = if (row == 0) (if (blink) ink else dim) else (if (blink) hud.cyan else dim);
    plain("<", 4, 116, arrow);
    plain(">", 148, 116, arrow);
    if (row == 0) {
        // "A PICK  vTRACK" centred: 14 cells, the arrow drawn in cell 8.
        plain("A PICK", 24, 116, dim);
        hud.down_arrow(90, 117, dim);
        plain("TRACK", 96, 116, dim);
    } else {
        // "TRACK n/N", centred.
        var buf: [9]u8 = "TRACK 1/1".*;
        buf[6] = '1' + track_index;
        buf[8] = '0' + @as(u8, @intCast(track.tracks.len));
        plain(&buf, 80 - 36, 116, hud.cyan);
    }
}

/// The track row's panel in the bio's place: the track's name, league,
/// the mode's rule and the hazards on it, its outline on the right.
fn draw_track_panel() void {
    const t = track.tracks[track_index];
    plain(t.name, 4, 79, hud.cyan);
    plain(t.league.name, 4, 88, dim);
    if (gc_mode) {
        plain("MARK AND SWEEP", 4, 97, ink);
    } else {
        var laps: [6]u8 = "3 LAPS".*;
        laps[0] = '0' + @as(u8, @min(9, t.laps));
        plain(&laps, 4, 97, ink);
    }
    // The hazards from its feature records (SPEC 3.3, 19.4).
    var specs: [world.hazard_max]track.HazardSpec = undefined;
    const n = track.parse_hazards(t, &specs);
    var vents = false;
    var movers = false;
    for (specs[0..n]) |*h| {
        vents = vents or h.kind == .blast;
        movers = movers or h.kind == .mover;
    }
    const hz: []const u8 = if (vents and movers) "VENTS, SWEEPER" else if (vents) "EXHAUST VENTS" else if (movers) "THE SWEEPER" else "";
    plain(hz, 4, 106, hud.coral);
    hud.draw_outline(122, 79, ink);
}

/// Link select (M4): the bio's place shows the host's rules, the
/// partner's pick and this badge's mark; the bottom row the next press.
fn draw_link_panel(l: *const Link, frame: u32) void {
    if (l.rules) |ru| {
        plain(track.tracks[ru.track % track.tracks.len].name, 4, 79, hud.cyan);
        var buf: [18]u8 = undefined;
        const mode = link_ui.mode_name(ru.mode);
        @memcpy(buf[0..mode.len], mode);
        @memcpy(buf[mode.len..][0..9], ", CREWS 4");
        buf[mode.len + 8] = '0' + @as(u8, @min(ru.crews, 9));
        plain(buf[0 .. mode.len + 9], 4, 88, dim);
    } else plain("WAITING FOR HOST", 4, 79, dim);
    if (l.peer) |p| link_ui.peer_line(p, 97) else plain("PEER: PICKING", 4, 97, dim);
    plain("YOU", 4, 106, dim);
    plain(racers.roster[racer].name, 44, 106, hud.livery(racer));
    if (l.ready) plain("READY", 156 - 40, 106, hud.green);
    const blink = (frame / 20) % 2 == 0;
    const arrow = if (l.ready) rule else if (blink) ink else dim;
    plain("<", 4, 116, arrow);
    plain(">", 148, 116, arrow);
    const prompt: []const u8, const color = if (!l.ready)
        (if (taken(racer)) .{ "TAKEN", hud.coral } else .{ "A READY", ink })
    else if (l.can_go)
        .{ "A START", if (blink) hud.cyan else ink }
    else if (l.host)
        .{ "WAITING", dim }
    else
        .{ "HOST STARTS", dim };
    plain(prompt, 80 - @as(i32, @intCast(prompt.len * 4)), 116, color);
}

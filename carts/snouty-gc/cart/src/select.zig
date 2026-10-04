//! New for Snouty GC (M1 Track B): the racer select (SPEC 8.1), the first
//! screen of every mode, laid out as docs/art_select_mock.png: the 48x48
//! portrait in a livery frame top left, the name and car to its right, the
//! car turning on its yaw cells over a plinth, the SPD/ARM/DMG bars, the
//! front weapon (A) and the rear weapon (Down+A), the 4-line bio, and the
//! cycling row along the bottom. Left/Right cycle the six racers; Down
//! moves to the track row (Left/Right change the track: one for now), Up
//! back; A (or Start) on either row starts the race with the racer shown,
//! so a Quick Race is Start, A from the title (SPEC 8.1); B goes back.
//! Everything is drawn 4 px clear of the edges.
const cart = @import("cart-api");
const world = @import("world.zig");
const racers = @import("racers.zig");
const track = @import("track.zig");
const roster_text = @import("roster_text.zig");
const sprites = @import("sprites.zig");
const hud = @import("hud.zig");
const input = @import("input.zig");
const sound = @import("sound.zig");

/// The racer and track shown (main.zig reads them on a pick).
pub var racer: u8 = racers.snouty;
pub var track_index: u8 = 0;
/// 0 the racer row, 1 the track row.
var row: u8 = 0;
/// Frames since the racer last changed (the turntable).
var frames: u32 = 0;

pub const Action = enum { none, pick, back };

pub fn enter(r: u8, t: u8) void {
    racer = r % racers.count;
    track_index = t % @as(u8, @intCast(track.tracks.len));
    row = 0;
    frames = 0;
}

/// One frame of input.
pub fn update() Action {
    frames +%= 1;
    if (input.pressed(.a) or input.pressed(.start)) {
        sound.menu_confirm();
        return .pick;
    }
    if (input.pressed(.b)) return .back;
    if (input.pressed(.down) and row == 0) {
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
        cart.rect(.{ .x = cx - hw, .y = cy + dy, .width = @intCast(2 * hw + 1), .height = 1, .fill_color = color });
    }
}

pub fn draw(frame: u32) void {
    const r = racer;
    const ro = racers.roster[r];
    const txt = roster_text.roster[r];
    const st = roster_text.stats[r];
    const liv = hud.livery(r);
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = bg });
    // Portrait in a livery frame.
    cart.rect(.{ .x = 4, .y = 4, .width = 50, .height = 50, .fill_color = liv });
    sprites.blit_at(&sprites.portraits[r], 0, 5, 5, .{});
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
            cart.rect(.{ .x = 121 + j * 4, .y = y + 1, .width = 3, .height = 6, .fill_color = if (j < val) liv else rule });
        }
    }
    // Weapons: A fires the front gun, Down+A drops the rear one.
    plain("A", 4, 57, liv);
    plain(roster_text.front_name(ro.front), 24, 57, ink);
    hud.down_arrow(4, 67, liv);
    plain("A", 11, 66, liv);
    plain(roster_text.rear_name(ro.rear), 24, 66, ink);
    cart.rect(.{ .x = 4, .y = 76, .width = 152, .height = 1, .fill_color = rule });
    for (txt.bio, 0..) |line, k| plain(line, 4, 79 + @as(i32, @intCast(k)) * 9, ink);
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
        const name = track.tracks[track_index].name;
        plain(name, 80 - @as(i32, @intCast(name.len * 4)), 116, hud.cyan);
    }
}

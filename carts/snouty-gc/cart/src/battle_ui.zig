//! New for Snouty GC (M6 Track B): BATTLE's own screens (SPEC 8.3). The
//! setup screen after the racer select (the arena, LIVES, TIME, CREWS and
//! FIGHT!, over the live floor of the arena, laid out as the main menu)
//! and the `KILL -9` title card over the countdown's first two steps.
//! The words and option rows are battle_text.zig's; main.zig owns the
//! state machine and draws the floor behind the setup.
const cart = @import("cart-api");
const tuning = @import("tuning.zig");
const track = @import("track.zig");
const hud = @import("hud.zig");
const input = @import("input.zig");
const sound = @import("sound.zig");
const menu_text = @import("menu_text.zig");
const text = @import("battle_text.zig");

/// The options of the next round (kept between rounds).
pub var opts: text.Options = .{};
/// The row under the cursor (a `text.Row`).
pub var cursor: u8 = @backingInt(text.Row.fight);

pub const Action = enum { none, start, back };

/// Entering the setup: the cursor on FIGHT!, so A A from the select fights.
pub fn enter() void {
    cursor = @backingInt(text.Row.fight);
}

/// One frame of input: Up / Down a row, Left / Right its value, A or
/// Start fights, B goes back to the racer select.
pub fn update() Action {
    if (input.pressed(.a) or input.pressed(.start)) {
        sound.menu_confirm();
        return .start;
    }
    if (input.pressed(.b)) return .back;
    if (input.pressed(.up)) {
        cursor = if (cursor == 0) text.row_count - 1 else cursor - 1;
        sound.menu_move();
    }
    if (input.pressed(.down)) {
        cursor = (cursor + 1) % text.row_count;
        sound.menu_move();
    }
    const step: i32 = @as(i32, @intFromBool(input.pressed(.right))) - @as(i32, @intFromBool(input.pressed(.left)));
    if (step != 0 and cursor != @backingInt(text.Row.fight)) {
        sound.menu_move();
        text.change(&opts, @fromBackingInt(cursor), step, track.arenas.len);
    }
    return .none;
}

const panel = cart.DisplayColor.rgb(0x2A1E34);
const panel_hi = cart.DisplayColor.rgb(0x4A2440);
const lay = menu_text.layout;

/// The setup over the arena's floor (drawn by the caller): BATTLE at 2x
/// where the menu's lockup is, the rows in the menu's panel, the line
/// about the row and the footer in the bar along the bottom.
pub fn draw(frame: u32) void {
    title_2x(text.title, lay.title_y);
    const rows: i32 = text.row_count;
    const py = lay.panel_y(rows);
    cart.rect(.{ .x = 4, .y = py, .width = 152, .height = @intCast(lay.panel_h(rows)), .fill_color = panel, .stroke_color = hud.dim });
    var b: [5][16]u8 = undefined;
    const labels = [text.row_count][]const u8{
        track.arenas[opts.arena % track.arenas.len].name,
        text.lives_label(&b[1], opts.lives),
        text.time_label(&b[2], opts.minutes),
        text.crews_label(&b[3], opts.crews),
        "FIGHT!",
    };
    for (labels, 0..) |label, i| {
        const y = lay.row_y(rows, @intCast(i));
        const sel = i == cursor;
        if (sel) hud.fill_rect(6, y - lay.bar_above, 148, lay.highlight_h, panel_hi);
        const fight = i == @backingInt(text.Row.fight);
        const color = if (sel) hud.coral else if (fight) hud.red else hud.white;
        hud.centered(label, y, color);
        if (sel and !fight) {
            hud.text("<", 8, y, hud.coral);
            hud.text(">", 144, y, hud.coral);
        }
    }
    hud.fill_rect(4, lay.bar_y, 152, 128 - lay.bar_y, hud.anti_black);
    const r: text.Row = @fromBackingInt(cursor);
    // INF lives: say why TIME has no NONE.
    const about = if (r == .time and opts.lives == 0 and (frame / 45) % 2 == 1) text.time_inf_note else text.hint(r);
    hud.centered(about, lay.hint_y, hud.grey);
    hud.centered(text.footer, lay.footer_y, hud.dim);
}

/// `str` at 2x, white on a coral drop, centred, top row at `y`.
fn title_2x(str: []const u8, y: i32) void {
    const x: i32 = 80 - @as(i32, @intCast(str.len)) * 8;
    hud.fill_rect(x - 4, y - 2, @as(i32, @intCast(str.len)) * 16 + 8, 21, hud.anti_black);
    hud.glyph_text(str, x + 2, y + 2, 2, false, hud.coral);
    hud.glyph_text(str, x, y, 2, false, hud.white);
}

const card_red = cart.DisplayColor.rgb(0xE83838);
const card_dark = cart.DisplayColor.rgb(0x6A0E14);

/// The `KILL -9` card (SPEC 8.3: "no cleanup handler, no appeal") over the
/// arena while the countdown's first two steps run: a terminal prompt
/// typing itself, KILL -9 at 2x, the tagline, the arena and the rules,
/// and the countdown's own message under it (3 shows on its second step).
/// `cd` is World.countdown, `place` the arena's name.
pub fn draw_card(cd: u16, place: []const u8, lives: u8, minutes: u8, frame: u32) void {
    const x0: i32 = 4;
    const y0: i32 = 18;
    const w: i32 = 152;
    const h: i32 = 92;
    hud.fill_rect(x0, y0, w, h, hud.anti_black);
    hud.fill_rect(x0, y0, w, 1, card_red);
    hud.fill_rect(x0, y0 + h - 1, w, 1, card_red);
    hud.fill_rect(x0, y0, 1, h, card_red);
    hud.fill_rect(x0 + w - 1, y0, 1, h, card_red);
    // Ticks since the card came up (the countdown runs down from 4 steps).
    const age: u32 = 4 * @as(u32, tuning.countdown_step) - @min(cd, 4 * tuning.countdown_step);
    // The prompt types itself, a character every 2 ticks, then blinks.
    const typed: usize = @min(text.card_prompt.len, age / 2);
    hud.text(text.card_prompt[0..typed], x0 + 6, y0 + 5, hud.grey);
    if ((frame / 8) % 2 == 0 or typed < text.card_prompt.len) {
        hud.fill_rect(x0 + 6 + @as(i32, @intCast(typed)) * 8, y0 + 5, 6, 8, hud.grey);
    }
    // KILL -9 lands once the command is in, shaking for a few ticks.
    if (typed == text.card_prompt.len) {
        const since = age - 2 * text.card_prompt.len;
        const shake: i32 = if (since < 8) @as(i32, @intCast(since % 3)) - 1 else 0;
        const tx: i32 = 80 - @as(i32, text.card_title.len) * 8 + shake;
        hud.glyph_text(text.card_title, tx + 2, y0 + 19, 2, false, card_dark);
        hud.glyph_text(text.card_title, tx, y0 + 17, 2, false, card_red);
    }
    hud.centered(text.card_line1, y0 + 39, hud.white);
    hud.centered(text.card_line2, y0 + 48, hud.white);
    hud.fill_rect(x0 + 12, y0 + 60, w - 24, 1, hud.dim);
    hud.centered(place, y0 + 65, hud.cyan);
    var b: [24]u8 = undefined;
    hud.centered(text.rules_line(&b, lives, minutes), y0 + 75, hud.grey);
}

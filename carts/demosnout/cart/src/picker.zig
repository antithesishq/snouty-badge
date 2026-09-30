//! The part picker (SPEC.md section 6): Select opens a list of every part
//! over the demo, which keeps running underneath. The list is an opaque
//! dark panel with a 1 px frame (readable over any part): a title, one row
//! per part (index, name, length in seconds; the part now playing marked
//! with a gold arrow, the highlighted row on a blue bar) and a hint line.
//! Up/Down move the highlight (wrapping), A jumps to that part (frame 0,
//! enter() called) and closes, Select or B closes.
//!
//! The picker never binds the stick click (input.zig has no such button),
//! and main.zig ignores every button while Start and Select are held
//! together, which is the OS's exit chord.
const cart = @import("cart-api");
const input = @import("input.zig");
const timeline = @import("timeline.zig");
const text = @import("text.zig");

pub var open: bool = false;
var cursor: u8 = 0;

const title = "DEMOSNOUT  -  PARTS";
const hint = "A JUMP  B/SELECT CLOSE";

const row_h: i32 = 9;
const panel_x: i32 = 0;
const panel_w: u32 = 160;
/// Title band, then the rows, then the hint band.
const head_h: i32 = 13;
const foot_h: i32 = 13;
const panel_h: i32 = head_h + @as(i32, timeline.count) * row_h + foot_h;
const panel_y: i32 = @divTrunc(128 - panel_h, 2);

const bg: cart.DisplayColor = .rgb(0x080a18);
const frame: cart.DisplayColor = .rgb(0x5060a0);
const rule: cart.DisplayColor = .rgb(0x283058);
const gold: cart.DisplayColor = .rgb(0xffd850);
const dim: cart.DisplayColor = .rgb(0x9098b8);
const salmon: cart.DisplayColor = .rgb(0xff9f91);

/// Opens with the highlight on the part now playing.
pub fn show() void {
    open = true;
    cursor = timeline.current();
}

/// Input while open; call instead of the running-state bindings.
pub fn handle() void {
    if (input.pressed(.select) or input.pressed(.b)) {
        open = false;
    } else if (input.pressed(.a)) {
        timeline.goto(cursor);
        open = false;
    } else if (input.pressed(.up)) {
        cursor = if (cursor == 0) timeline.count - 1 else cursor - 1;
    } else if (input.pressed(.down)) {
        cursor = timeline.next_index(cursor);
    }
}

/// Draws the panel over the frame.
pub fn draw() void {
    cart.rect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = @intCast(panel_h), .fill_color = bg, .stroke_color = frame });
    text.condensed(title, 3, panel_y + 3, gold);
    const rows_y = panel_y + head_h;
    cart.hline(.{ .x = panel_x + 2, .y = rows_y - 2, .len = panel_w - 4, .color = rule });
    for (0..timeline.count) |i| {
        const y: i32 = rows_y + @as(i32, @intCast(i)) * row_h;
        const selected = i == cursor;
        const playing = i == timeline.current();
        if (selected) cart.rect(.{ .x = panel_x + 2, .y = y - 1, .width = panel_w - 4, .height = @intCast(row_h), .fill_color = .rgb(0x3048b0) });
        const fg: cart.DisplayColor = if (selected) .rgb(0xffffff) else if (playing) gold else dim;
        if (playing) text.draw(">", panel_x + 4, y, gold, null);
        var num: [2]u8 = undefined;
        text.put_uint(&num, @intCast(i));
        text.draw(&num, panel_x + 13, y, fg, null);
        text.draw(timeline.name(i), panel_x + 13 + 3 * 8, y, fg, null);
        var secs: [3]u8 = .{ ' ', ' ', 's' };
        text.put_uint(secs[0..2], timeline.frames_of(i) / 60);
        text.draw(&secs, panel_x + @as(i32, panel_w) - 4 - 3 * 8, y, if (selected) .rgb(0xffffff) else salmon, null);
    }
    const foot_y = rows_y + @as(i32, timeline.count) * row_h;
    cart.hline(.{ .x = panel_x + 2, .y = foot_y, .len = panel_w - 4, .color = rule });
    text.condensed(hint, 3, foot_y + 3, dim);
}

pub fn highlighted() u8 {
    return cursor;
}

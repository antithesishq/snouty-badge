//! The part picker (SPEC.md section 6): Select opens a list of every part
//! over the demo, which keeps running underneath dimmed by fx.fade(8).
//! Up/Down move the highlight (wrapping), A jumps to that part (frame 0,
//! enter() called) and closes, Select or B closes.
const cart = @import("cart-api");
const input = @import("input.zig");
const timeline = @import("timeline.zig");
const text = @import("text.zig");

pub var open: bool = false;
var cursor: u8 = 0;

const row_h: i32 = 9;
const panel_x: i32 = 12;
const panel_w: u32 = 136;
const title_h: i32 = 12;
const panel_h: i32 = title_h + @as(i32, timeline.count) * row_h + 3;
const panel_y: i32 = @divTrunc(128 - panel_h, 2);

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

/// Draws the list over the (already dimmed) frame.
pub fn draw() void {
    cart.rect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = @intCast(panel_h), .fill_color = .rgb(0x0a0a1c), .stroke_color = .rgb(0x5060a0) });
    const title = "PARTS";
    text.draw(title, text.centre_x(title, 1), panel_y + 3, .rgb(0xffd850), null);
    for (0..timeline.count) |i| {
        const y: i32 = panel_y + title_h + @as(i32, @intCast(i)) * row_h;
        const selected = i == cursor;
        if (selected) cart.rect(.{ .x = panel_x + 2, .y = y - 1, .width = panel_w - 4, .height = @intCast(row_h), .fill_color = .rgb(0x3048b0) });
        var num: [2]u8 = undefined;
        text.put_uint(&num, @intCast(i));
        const fg: cart.DisplayColor = if (selected) .rgb(0xffffff) else if (i == timeline.current()) .rgb(0xffd850) else .rgb(0x9098b8);
        text.draw(&num, panel_x + 4, y, fg, null);
        text.draw(timeline.name(i), panel_x + 4 + 3 * 8, y, fg, null);
    }
}

pub fn highlighted() u8 {
    return cursor;
}

//! ROM picker (PLAN.md M5, SPEC.md 11.1): shown after the splash when the
//! badge drive holds more than one playable `.gb`/`.gbc` file. One row per
//! file found (frontend/romsrc.zig, at most 8): name and size; unplayable
//! files are listed dimmed so the user sees why a copied file is missing.
//! Below the list, the selected file's note (why it cannot be played, or
//! hints such as "Color" or "no RTC"). Up/Down move, A plays the selected file, B
//! runs the embedded ROM instead (`flow.Picker`, host-tested). Full redraw
//! every frame, like the game. main.zig passes the live edge
//! (frontend/flow.zig), so the button that skipped the splash does not act
//! here.
const cart = @import("cart-api");
const video = @import("video.zig");
const input = @import("input.zig");
const flow = @import("flow.zig");
const romsrc = @import("romsrc.zig");

var picker: flow.Picker = .{};

/// One picker frame. Returns null to stay, or the choice: a candidate index,
/// or null inside for the embedded ROM.
pub fn update(e: input.Edge) ??usize {
    const n = romsrc.candidate_count;
    var playable: [romsrc.max_candidates]bool = undefined;
    for (romsrc.candidates[0..n], playable[0..n]) |c, *p| p.* = c.playable;
    if (picker.update(e, playable[0..n])) |choice| return choice;
    draw();
    return null;
}

const row_h = 10;
const first_row_y = 13;
/// Characters of the name that fit left of the size column.
const name_cols = 14;

fn draw() void {
    const bg = video.shade_color(0);
    const fg = video.shade_color(3);
    const dim = video.shade_color(2);
    video.blank(0);
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = 10, .fill_color = fg });
    cart.text(.{ .str = "Pick a ROM", .x = 40, .y = 1, .text_color = bg });

    var buf: [8]u8 = undefined;
    for (romsrc.candidates[0..romsrc.candidate_count], 0..) |*c, i| {
        const y: i32 = first_row_y + @as(i32, @intCast(i)) * row_h;
        var color = if (c.playable) fg else dim;
        if (i == picker.cursor) {
            cart.rect(.{ .x = 0, .y = y - 1, .width = cart.screen_width, .height = row_h, .fill_color = fg });
            color = bg;
        }
        const name = c.entry.slice();
        cart.text(.{ .str = name[0..@min(name.len, name_cols)], .x = 2, .y = y, .text_color = color });
        const kb = kb_label(&buf, c.entry.size);
        cart.text(.{ .str = kb, .x = @as(i32, cart.screen_width) - 2 - @as(i32, @intCast(kb.len * 8)), .y = y, .text_color = color });
    }
    const sel = &romsrc.candidates[picker.cursor];
    cart.text(.{ .str = sel.note(), .x = 2, .y = 98, .text_color = if (sel.playable) fg else dim });
    cart.text(.{ .str = "A: play", .x = 2, .y = 110, .text_color = if (sel.playable) fg else dim });
    cart.text(.{ .str = "B: embedded ROM", .x = 2, .y = 119, .text_color = fg });
}

/// "64K": the size rounded up to whole KB, at most 5 characters (1 MB is
/// the largest playable file; bigger ones show 9999K).
fn kb_label(buf: *[8]u8, bytes: u32) []const u8 {
    var v: u32 = @min((bytes + 1023) / 1024, 9999);
    var tmp: [4]u8 = undefined;
    var n: usize = 0;
    while (true) {
        tmp[n] = '0' + @as(u8, @intCast(v % 10));
        n += 1;
        v /= 10;
        if (v == 0) break;
    }
    for (0..n) |k| buf[k] = tmp[n - 1 - k];
    buf[n] = 'K';
    return buf[0 .. n + 1];
}

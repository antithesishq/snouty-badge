//! The title screen: the original's paperclip box (gen/title.*, written by
//! tools/gen_title.py), the credit, "Press A", and after a prestige the
//! universe / sim level line. The code Up Up Down Down Left Right Left
//! Right B A (app.zig) unlocks the CHEATS page.
const cart = @import("cart-api");
const app_mod = @import("app.zig");
const draw = @import("draw.zig");
const gen = @import("gen/title.zig");
const numfmt = @import("numfmt.zig");

var palette: [16]cart.Pixel = undefined;
var ready = false;

fn init() void {
    for (gen.palette, 0..) |c, i| palette[i] = draw.pixel_of(c);
    ready = true;
}

/// Where the picture sits: full width, one pixel down.
const pic_y: i32 = 1;

pub fn draw_picture() void {
    if (!ready) init();
    draw.clear(.white);
    const w = gen.width;
    var y: u32 = 0;
    while (y < gen.height) : (y += 1) {
        const sy: i32 = pic_y + @as(i32, @intCast(y));
        if (sy >= draw.height) break;
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const i = y * w + x;
            const byte = gen.pixels[i / 2];
            const idx = if (i & 1 == 0) byte & 0x0F else byte >> 4;
            if (idx == 0) continue; // white, already cleared
            cart.framebuffer[x][@intCast(sy)] = palette[idx];
        }
    }
}

pub fn screen(app: *app_mod.App) void {
    draw_picture();
    // The credit, in the white space above the box's top edge.
    _ = draw.text("by Frank Lantz", 2, 2, .black);
    _ = draw.text("& Bennett Foddy", 2, 11, .black);
    const blink = (app.frame / 30) % 2 == 0;
    if (app.cheats and app.cheat_flash < 120) {
        _ = draw.text("CHEATS", 118, 100, .black);
        _ = draw.text("ON", 130, 109, .black);
    } else if (blink) {
        _ = draw.text(if (app.playing) "A: back" else "Press A", 112, 104, .black);
    }
    if (app.playing and (app.game.prestige_u > 0 or app.game.prestige_s > 0)) {
        var bu: [24]u8 = undefined;
        var bs: [24]u8 = undefined;
        const u = numfmt.int(&bu, app.game.prestige_u);
        const s = numfmt.int(&bs, app.game.prestige_s);
        var x = draw.text("Universe: ", 1, 119, .black);
        x = draw.text(u, x, 119, .black);
        x = draw.text(" / Sim Level: ", x, 119, .black);
        _ = draw.text(s, x, 119, .black);
    }
}

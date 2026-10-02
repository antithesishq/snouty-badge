//! Boot splash (SPEC.md section 12): for `frames` frames (1.2 s) the Iris
//! mark and "SNOUTY BOY" scroll down from above the screen to the centre,
//! like the DMG boot logo, on shade 0 of the current palette. In CGB mode
//! (SPEC.md 19) the title is "SNOUTY BOY COLOR" on white, "COLOR" in five
//! colours like the GBC boot logo. Any button
//! press skips it. The bottom line says how to open the emulator menu
//! (`hint.hold_select`, lib/hint.zig). The two-note chime belongs to frontend/audio.zig: this
//! module only raises `request_chime` once, the frame the logo lands.
const cart = @import("cart-api");
const video = @import("video.zig");
const iris = @import("iris");
const hint = @import("hint");

/// Splash length in frames (1.2 s at 60 Hz).
pub const frames = 72;
/// Frame on which the logo reaches its resting place.
pub const land_frame = 48;

/// Set to true once when the logo lands. The audio module (wired by the
/// integrator) plays the chime and clears it.
pub var request_chime: bool = false;

/// The Antithesis Iris mark (lib/iris_mark.zig, 24x24) at 2x: 48 px.
const mark_scale = 2;
const mark_px: i32 = iris.size * mark_scale;
const title = "SNOUTY BOY";
const title_cgb = "SNOUTY BOY COLOR";
/// One colour per letter of "COLOR".
const color_letters = [5]u32{ 0xE02020, 0xF08000, 0x20A020, 0x2060E0, 0xA020C0 };
const title_scale = 1;
const gap = 6;
const block_h: i32 = mark_px + gap + 8 * title_scale;
const rest_y: i32 = @divTrunc(@as(i32, cart.screen_height) - block_h, 2);
const start_y: i32 = -block_h;

comptime {
    if (rest_y + block_h > hint.splash_y) @compileError("the menu hint overlaps the title");
}

var frame: u32 = 0;

/// One splash frame. Returns true when the splash is over (finished or
/// skipped); the caller then starts the game in the same frame, so nothing
/// is drawn in that case.
pub fn update(skip: bool) bool {
    if (skip or frame >= frames) return true;
    if (frame == land_frame) request_chime = true;
    draw(logo_y(frame));
    frame += 1;
    return false;
}

fn logo_y(f: u32) i32 {
    if (f >= land_frame) return rest_y;
    const dist = rest_y - start_y;
    return start_y + @divTrunc(dist * @as(i32, @intCast(f)), land_frame);
}

fn draw(y: i32) void {
    video.blank(0);
    const ink = video.shade_color(3);
    const x0: i32 = @divTrunc(@as(i32, cart.screen_width) - mark_px, 2);
    iris.draw(cart, x0, y, mark_scale, ink);
    const str = if (video.cgb) title_cgb else title;
    const tw: i32 = @intCast(str.len * 8 * title_scale);
    const tx = @divTrunc(@as(i32, cart.screen_width) - tw, 2);
    const ty = y + mark_px + gap;
    cart.text(.{ .str = title, .x = tx, .y = ty, .scale = title_scale, .text_color = ink });
    hint.draw_centred(cart, hint.hold_select, hint.splash_y, video.shade_color(2));
    if (video.cgb) {
        for (color_letters, 0..) |rgb, i| {
            const at = title.len + 1 + i;
            cart.text(.{
                .str = title_cgb[at..][0..1],
                .x = tx + @as(i32, @intCast(at * 8 * title_scale)),
                .y = ty,
                .scale = title_scale,
                .text_color = .rgb(rgb),
            });
        }
    }
}

//! __NAME__: a Snouty cart made on the fly by the badge-manager station.
//! Started from badge-manager/template-cart: a title, a square the d-pad
//! moves and A recolours. Everything the cart draws is redrawn every frame.
const cart = @import("cart-api");

comptime {
    cart.export_start_code();
}

// Colours from the Antithesis brand guide.
const anti_black = cart.DisplayColor.rgb(0x16031B);
const anti_white = cart.DisplayColor.rgb(0xFCFBF9);
const coral = cart.DisplayColor.rgb(0xF18271);
const floor_color = cart.DisplayColor.rgb(0x2A0E30);

/// The colours A cycles the square through.
const square_colors = [_]cart.DisplayColor{
    coral,
    cart.DisplayColor.rgb(0x7FD1AE), // mint
    cart.DisplayColor.rgb(0xF6D55C), // yellow
    cart.DisplayColor.rgb(0x6FA8DC), // blue
};

// Layout and motion knobs.
const title = "SNOUTY";
const title_scale = 2;
const title_y = 6;
const play_top = title_y + 8 * title_scale + 6; // first row the square may use
const square_size = 12;
const speed_px = 2; // per tick at 60 Hz

// State. Tick-based and deterministic: no allocation, no clock reads.
var square_x: i32 = (cart.screen_width - square_size) / 2;
var square_y: i32 = (play_top + cart.screen_height - square_size) / 2;
var color_index: usize = 0;
var prev_a: bool = false;
var tick: u32 = 0;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    // update() redraws every pixel, so neither a clear nor a copy-forward is needed.
    cart.set_double_buffer_mode(.no_copy_full_frame);
}

pub fn update() void {
    const c = read_controls();
    step(c);
    draw();
    tick +%= 1;
    if (cart.is_wasm) present_wasm();
}

/// Moves the square and handles A (on the press edge only).
fn step(c: cart.Controls) void {
    if (c.left) square_x -= speed_px;
    if (c.right) square_x += speed_px;
    if (c.up) square_y -= speed_px;
    if (c.down) square_y += speed_px;
    square_x = clamp(square_x, 0, cart.screen_width - square_size);
    square_y = clamp(square_y, play_top, cart.screen_height - square_size);

    if (c.a and !prev_a) color_index = (color_index + 1) % square_colors.len;
    prev_a = c.a;
}

fn draw() void {
    // Background: a dark band behind the title, a slightly lighter play area.
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = play_top, .fill_color = anti_black });
    cart.rect(.{ .x = 0, .y = play_top, .width = cart.screen_width, .height = cart.screen_height - play_top, .fill_color = floor_color });
    cart.hline(.{ .x = 0, .y = play_top - 1, .len = cart.screen_width, .color = coral });

    draw_centered_text(title, title_y, title_scale, anti_white);

    cart.rect(.{
        .x = square_x,
        .y = square_y,
        .width = square_size,
        .height = square_size,
        .stroke_color = anti_white,
        .fill_color = square_colors[color_index],
    });

    // A blinking hint at the bottom for the first few seconds.
    if (tick < 300 and (tick / 30) % 2 == 0) {
        draw_centered_text("D-PAD MOVE  A COLOUR", cart.screen_height - 10, 1, anti_white);
    }
}

fn draw_centered_text(str: []const u8, y: i32, scale: u32, color: cart.DisplayColor) void {
    const w: i32 = @intCast(str.len * cart.font_width * scale);
    const screen_w: i32 = cart.screen_width;
    cart.text(.{ .str = str, .x = @divTrunc(screen_w - w, 2), .y = y, .scale = scale, .text_color = color });
}

fn clamp(v: i32, lo: i32, hi: i32) i32 {
    return @max(lo, @min(hi, v));
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls.
fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim. Upstream's platform_wasm.zig never presents (its
/// present_and_acquire is a TODO and update() is exported without calling
/// present()), and the web simulator reads a legacy framebuffer at linear
/// address 0x20 (add_os_cart reserves it via global_base). Copy our frame
/// there, swapping red and blue: the simulator's compositor was written for
/// the legacy API that kept blue in the low bits, while DisplayColor keeps
/// red there. Hardware builds do not compile any of this.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const col = src.to_color();
            dst.* = .from_color(.{ .r = col.b, .g = col.g, .b = col.r });
        }
    }
    // No re-clear: like .no_copy_full_frame on hardware, the next update()
    // overwrites every pixel of cart.framebuffer before it is presented.
}

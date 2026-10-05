//! The Raspberry Trail for the SYCL badge: the cart shell.
//!
//! PLAN-COMMIT PLACEHOLDER: shows the engine's first lines so the build is
//! wired end to end. Track U replaces this with the real shell (SPEC 4).
const cart = @import("cart-api");
const G = @import("game");

comptime {
    cart.export_start_code();
}

var game: G.Game = .{};

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    G.init(&game, 1);
    G.start(&game);
}

pub fn update() void {
    _ = read_controls();
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = cart.screen_height, .fill_color = cart.DisplayColor.rgb(0x16031B) });
    cart.text(.{ .str = "RASPBERRY TRAIL", .x = 20, .y = 8, .text_color = cart.DisplayColor.rgb(0xE30B5C) });
    var y: i32 = 30;
    for (game.printed()) |l| {
        const n = @min(l.text.len, 20);
        cart.text(.{ .str = l.text[0..n], .x = 0, .y = y, .text_color = cart.DisplayColor.rgb(0xFCFBF9) });
        y += 10;
    }
    if (cart.is_wasm) present_wasm();
}

/// Button state. Upstream's platform_wasm.zig never fills `controls` from
/// the simulator, which writes its button word to linear address 0x04.
fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim: copy the frame to the legacy framebuffer at 0x20 with
/// red and blue swapped (see badge-manager/template-cart).
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const col = src.to_color();
            dst.* = .from_color(.{ .r = col.b, .g = col.g, .b = col.r });
        }
    }
}

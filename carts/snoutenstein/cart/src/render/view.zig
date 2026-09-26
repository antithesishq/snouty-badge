//! The 3D view (y 0..103). M0 stub: horizon split. M1 track A replaces
//! this with the raycaster (raycast.zig, floor.zig, textures.zig).
const cart = @import("cart-api");
const state = @import("../state.zig");
const levels = @import("../levels.zig");

pub const view_h: u32 = 104;
pub const view_w: u32 = cart.screen_width;

pub fn init() void {}

pub fn draw(s: *const state.GameState, level: *const levels.Level) void {
    _ = s;
    _ = level;
    const sky: cart.Pixel = .from_color(.rgb(0x182552));
    const ground: cart.Pixel = .from_color(.rgb(0x29232F));
    for (0..view_w) |x| {
        const col = &cart.framebuffer[x];
        for (0..view_h / 2) |y| col[y] = sky;
        for (view_h / 2..view_h) |y| col[y] = ground;
    }
}

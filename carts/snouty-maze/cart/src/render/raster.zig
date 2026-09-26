//! Column-major convex polygon rasterizer with a u16 z buffer. Track A
//! implements. `draw_polygon` is the whole interface scene.zig relies on.
const cart = @import("cart-api");
const math = @import("../math.zig");
const clip = @import("clip.zig");
const textures = @import("textures.zig");

pub const Vertex = clip.Vertex;

pub const Fill = union(enum) {
    textured: *const textures.Texture,
    flat: cart.Pixel,
    /// Textured, palette index 0 skipped, for billboards.
    sprite: *const textures.Texture,
};

/// Horizontal FOV 66 degrees: focal length in pixels.
pub const focal: f32 = 123.2;

/// 1/z scaled by this is stored in the z buffer; near = 0.05 gives 40,960.
pub const z_scale: f32 = 2048.0;

pub var zbuf: [cart.screen_width][cart.screen_height]u16 = undefined;

/// Clears the z buffer. Call once per frame before any draw_polygon.
pub fn begin_frame() void {
    @memset(@as(*[cart.screen_width * cart.screen_height]u16, @ptrCast(&zbuf)), 0);
}

/// Draws a convex polygon (3 or 4 view-space vertices, any winding) with
/// near clipping, perspective projection and z test.
/// STUB: fills the projected bounding box with the flat colour (or the
/// texture's palette[1]) so the scaffold shows something.
pub fn draw_polygon(verts: []const Vertex, fill: Fill) void {
    var clipped: [clip.max_out]Vertex = undefined;
    const n = clip.clip_near(verts, &clipped);
    if (n < 3) return;
    var x0: i32 = 1 << 20;
    var x1: i32 = -(1 << 20);
    var y0: i32 = 1 << 20;
    var y1: i32 = -(1 << 20);
    var inv_z_max: f32 = 0;
    for (clipped[0..n]) |v| {
        const inv_z = 1.0 / v.p[2];
        inv_z_max = @max(inv_z_max, inv_z);
        const sx: i32 = @intFromFloat(@min(4096.0, @max(-4096.0, 80.0 + focal * v.p[0] * inv_z)));
        const sy: i32 = @intFromFloat(@min(4096.0, @max(-4096.0, 64.0 - focal * v.p[1] * inv_z)));
        x0 = @min(x0, sx);
        x1 = @max(x1, sx);
        y0 = @min(y0, sy);
        y1 = @max(y1, sy);
    }
    const px: cart.Pixel = switch (fill) {
        .flat => |c| c,
        .textured, .sprite => |t| t.palette[1],
    };
    const q: u16 = @intFromFloat(@min(65535.0, inv_z_max * z_scale));
    const cx0: usize = @intCast(@max(0, x0));
    const cx1: usize = @intCast(@min(@as(i32, cart.screen_width), x1 + 1));
    const cy0: usize = @intCast(@max(0, y0));
    const cy1: usize = @intCast(@min(@as(i32, cart.screen_height), y1 + 1));
    var x = cx0;
    while (x < cx1) : (x += 1) {
        var y = cy0;
        while (y < cy1) : (y += 1) {
            if (q > zbuf[x][y]) {
                zbuf[x][y] = q;
                cart.framebuffer[x][y] = px;
            }
        }
    }
}

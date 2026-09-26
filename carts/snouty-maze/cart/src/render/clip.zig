//! Near-plane clipping of convex polygons in view space. Pure math, host
//! testable. Track A implements; the types here are the raster contract.
const std = @import("std");
const math = @import("../math.zig");

pub const near: f32 = 0.05;

/// A polygon vertex in view space with texture coordinates in texels/32
/// (u, v in cells; the rasterizer wraps with & 31 after scaling).
pub const Vertex = struct { p: math.Vec3, u: f32, v: f32 };

pub const max_in = 4;
pub const max_out = max_in + 1;

/// Sutherland-Hodgman against z = near. Returns the number of output
/// vertices (0 when fully behind). STUB: passes through when all in front.
pub fn clip_near(in: []const Vertex, out: *[max_out]Vertex) usize {
    var n: usize = 0;
    for (in) |v| {
        if (v.p[2] < near) return 0;
        out[n] = v;
        n += 1;
    }
    return n;
}

test "fully in front passes through" {
    const quad = [_]Vertex{
        .{ .p = math.vec3(-1, -1, 2), .u = 0, .v = 0 },
        .{ .p = math.vec3(1, -1, 2), .u = 1, .v = 0 },
        .{ .p = math.vec3(1, 1, 2), .u = 1, .v = 1 },
        .{ .p = math.vec3(-1, 1, 2), .u = 0, .v = 1 },
    };
    var out: [max_out]Vertex = undefined;
    try std.testing.expectEqual(@as(usize, 4), clip_near(&quad, &out));
}

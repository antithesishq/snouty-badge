//! Near-plane clipping of convex polygons in view space. Pure math, host
//! testable.
const std = @import("std");
const math = @import("../math.zig");

pub const near: f32 = 0.05;

/// A polygon vertex in view space with texture coordinates in cells (one
/// texture repeat per unit; the rasterizer scales by 32 and wraps with & 31).
pub const Vertex = struct { p: math.Vec3, u: f32, v: f32 };

pub const max_in = 4;
pub const max_out = max_in + 1;

/// Sutherland-Hodgman against z = near; `z >= near` is inside. Returns the
/// number of output vertices (0 when fully behind; fewer than 3 means
/// nothing to draw). Attributes are interpolated linearly in view space,
/// which is exact for u, v. A vertex exactly on the plane is kept once and
/// produces no extra intersection. The intersection is always computed from
/// the inside vertex towards the outside one, so an edge shared by two
/// polygons clips to bit-identical points whatever the winding.
pub fn clip_near(in: []const Vertex, out: *[max_out]Vertex) usize {
    std.debug.assert(in.len <= max_in);
    var n: usize = 0;
    var prev = in[in.len - 1];
    var prev_d = prev.p[2] - near;
    for (in) |cur| {
        const cur_d = cur.p[2] - near;
        if ((prev_d < 0 and cur_d > 0) or (prev_d > 0 and cur_d < 0)) {
            const a = if (prev_d > 0) prev else cur;
            const b = if (prev_d > 0) cur else prev;
            const t = (near - a.p[2]) / (b.p[2] - a.p[2]);
            var p = math.lerp(a.p, b.p, t);
            p[2] = near;
            out[n] = .{ .p = p, .u = a.u + (b.u - a.u) * t, .v = a.v + (b.v - a.v) * t };
            n += 1;
        }
        if (cur_d >= 0) {
            out[n] = cur;
            n += 1;
        }
        prev = cur;
        prev_d = cur_d;
    }
    return n;
}

fn vtx(x: f32, y: f32, z: f32, u: f32, v: f32) Vertex {
    return .{ .p = math.vec3(x, y, z), .u = u, .v = v };
}

fn expect_all_in_front(out: []const Vertex) !void {
    for (out) |o| try std.testing.expect(o.p[2] >= near - 1e-6);
}

test "fully in front passes through" {
    const quad = [_]Vertex{ vtx(-1, -1, 2, 0, 0), vtx(1, -1, 2, 1, 0), vtx(1, 1, 2, 1, 1), vtx(-1, 1, 2, 0, 1) };
    var out: [max_out]Vertex = undefined;
    const n = clip_near(&quad, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    for (quad, out[0..4]) |a, b| {
        try std.testing.expectEqual(a.p, b.p);
        try std.testing.expectEqual(a.u, b.u);
    }
}

test "fully behind gives nothing" {
    const quad = [_]Vertex{ vtx(-1, -1, -2, 0, 0), vtx(1, -1, -2, 1, 0), vtx(1, 1, 0.01, 1, 1), vtx(-1, 1, 0.0, 0, 1) };
    var out: [max_out]Vertex = undefined;
    try std.testing.expectEqual(@as(usize, 0), clip_near(&quad, &out));
}

test "one vertex behind gives five" {
    // Vertex 2 behind; z goes 1 -> -1 so the crossings are at the midpoints
    // (shifted by near).
    const quad = [_]Vertex{ vtx(0, 0, 1, 0, 0), vtx(1, 0, 1, 1, 0), vtx(1, 1, -1, 1, 1), vtx(0, 1, 1, 0, 1) };
    var out: [max_out]Vertex = undefined;
    const n = clip_near(&quad, &out);
    try std.testing.expectEqual(@as(usize, 5), n);
    try expect_all_in_front(out[0..n]);
    // Crossing on edge 1->2: t = (1 - near) / 2 from vertex 1.
    const t = (1.0 - near) / 2.0;
    var found = false;
    for (out[0..n]) |o| {
        if (@abs(o.p[0] - 1) < 1e-6 and @abs(o.p[1] - t) < 1e-5) {
            try std.testing.expectApproxEqAbs(@as(f32, near), o.p[2], 1e-6);
            try std.testing.expectApproxEqAbs(@as(f32, 1), o.u, 1e-6);
            try std.testing.expectApproxEqAbs(t, o.v, 1e-5);
            found = true;
        }
    }
    try std.testing.expect(found);
}

test "two vertices behind gives four" {
    const quad = [_]Vertex{ vtx(0, 0, 1, 0, 0), vtx(1, 0, 1, 1, 0), vtx(1, 1, -1, 1, 1), vtx(0, 1, -1, 0, 1) };
    var out: [max_out]Vertex = undefined;
    const n = clip_near(&quad, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try expect_all_in_front(out[0..n]);
    const t = (1.0 - near) / 2.0;
    for (out[0..n]) |o| {
        if (o.p[2] < 0.5) try std.testing.expectApproxEqAbs(t, o.p[1], 1e-5);
    }
}

test "vertex exactly on the plane is kept once" {
    // Triangle with one vertex on the plane, others in front: unchanged.
    const tri = [_]Vertex{ vtx(0, 0, near, 0, 0), vtx(1, 0, 2, 1, 0), vtx(0, 1, 2, 0, 1) };
    var out: [max_out]Vertex = undefined;
    try std.testing.expectEqual(@as(usize, 3), clip_near(&tri, &out));
    try std.testing.expectEqual(tri[0].p, out[0].p);
    // Quad with one vertex on the plane and one behind: the on-plane vertex
    // is not duplicated, one crossing is added on the other side.
    const quad = [_]Vertex{ vtx(0, 0, near, 0, 0), vtx(1, 0, -1, 1, 0), vtx(1, 1, 1, 1, 1), vtx(0, 1, 1, 0, 1) };
    const n = clip_near(&quad, &out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try expect_all_in_front(out[0..n]);
    for (out[0..n], 0..) |a, i| {
        for (out[i + 1 .. n]) |b| try std.testing.expect(@reduce(.Or, a.p != b.p));
    }
}

test "shared edge clips identically for both windings" {
    const a = vtx(0.3, 0.2, 1.7, 0.25, 0);
    const b = vtx(-0.9, 0.2, -0.6, 3.5, 0);
    var o1: [max_out]Vertex = undefined;
    var o2: [max_out]Vertex = undefined;
    const n1 = clip_near(&[_]Vertex{ a, b, vtx(0, -1, 1, 0, 1) }, &o1);
    const n2 = clip_near(&[_]Vertex{ b, a, vtx(0, 1, 1, 0, 1) }, &o2);
    var p1: ?Vertex = null;
    var p2: ?Vertex = null;
    for (o1[0..n1]) |o| if (o.p[1] == 0.2 and o.p[2] == near) {
        p1 = o;
    };
    for (o2[0..n2]) |o| if (o.p[1] == 0.2 and o.p[2] == near) {
        p2 = o;
    };
    try std.testing.expectEqual(p1.?.p, p2.?.p);
    try std.testing.expectEqual(p1.?.u, p2.?.u);
}

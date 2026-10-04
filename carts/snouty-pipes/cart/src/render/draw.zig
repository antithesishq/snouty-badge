//! Track A: draws grid cells into the persistent framebuffer (SPEC.md
//! section 4). Each primitive is ray cast per pixel inside its screen rect
//! (trace.zig), depth tested against zbuf.zig, Phong shaded and dithered
//! (shade.zig), and the rect it actually wrote is marked dirty so the OS
//! sends it to the LCD in .copy_forward mode. Generic over the pixel sink so
//! host tests can draw into an array.
//!
//! `S` must provide:
//!   pub fn put(x: u32, y: u32, c: u16) void       // c = cart DisplayColor bits (r low 5, g 6, b high 5)
//!   pub fn mark_dirty(r: camera.Rect) void
//!
//! Cell geometry (PLAN.md "Cell geometry"): the path runs from the entry
//! face `centre - din/2` to the exit face `centre + dout/2`, s in [0, 1] by
//! arc length. Every piece is a closed solid (capped cylinder, sphere, capped
//! torus slice), so drawing s in slices builds the same image as one call:
//! the growing end shows a flat cap that the next slice paints over.
const std = @import("std");
const math = @import("../math.zig");
const grid = @import("../grid.zig");
const camera = @import("../camera.zig");
const zbuf = @import("zbuf.zig");
const shade = @import("shade.zig");
const trace = @import("trace.zig");
const teapot = @import("teapot.zig");

const Vec3 = math.Vec3;
const Rect = camera.Rect;

/// Pipe radius, ball joint and cap radius, elbow (torus) major radius, all
/// in cells.
pub const r_pipe: f32 = 0.22;
pub const r_ball: f32 = 0.32;
pub const r_elbow: f32 = 0.5;
/// Teapot height in cells.
pub const teapot_size: f32 = 1.3;

/// Dissolve blocks: the screen as 4x4 pixel blocks, 40 x 32.
pub const block_count = (camera.screen_w / 4) * (camera.screen_h / 4);
const blocks_x = camera.screen_w / 4;
/// Step of the dissolve permutation: odd and not a multiple of 5, so
/// `i * block_step mod block_count` visits every block once.
const block_step = 797;

pub fn Renderer(comptime S: type) type {
    return struct {
        /// Draws the part of cell `p`'s path between fractions s0 and s1
        /// (0 = the entry face, or the centre for a pipe start; 1 = the exit
        /// face, or the centre for a pipe end). Calls with consecutive
        /// ranges must build the same image as one call with 0..1.
        pub fn draw_cell(cam: *const camera.Camera, p: grid.Prim, s0_in: f32, s1_in: f32) void {
            const s0 = math.clamp01(s0_in);
            const s1 = math.clamp01(s1_in);
            shade.set_view(cam);
            const c = p.center();
            const col = p.color;
            if (p.din == .none) {
                // Pipe start: ball at s = 0, then centre -> exit face.
                if (s0 <= 0) ball(cam, c, col);
                if (p.dout != .none) half(cam, c, p.dout, 0.5 * s0, 0.5 * s1, col);
                return;
            }
            if (p.dout == .none) {
                // Pipe end: entry face -> centre, then the ball at s = 1.
                half(cam, c, p.din.opposite(), 0.5 * (1.0 - s1), 0.5 * (1.0 - s0), col);
                if (s1 >= 1) ball(cam, c, col);
                return;
            }
            if (p.din == p.dout) {
                // Straight: one cylinder face to face, s = 0.5 at the centre.
                if (p.dout.sign() > 0) cylinder(cam, c, p.dout, s0 - 0.5, s1 - 0.5, col) else cylinder(cam, c, p.dout, 0.5 - s1, 0.5 - s0, col);
                return;
            }
            if (p.joint == .elbow) {
                elbow(cam, p, s0, s1);
                return;
            }
            // Ball or teapot turn: in-half on [0, 0.5], joint at 0.5,
            // out-half on [0.5, 1].
            if (s0 < 0.5) half(cam, c, p.din.opposite(), 0.5 - @min(s1, 0.5), 0.5 - s0, col);
            if (s0 <= 0.5 and s1 > 0.5) {
                if (p.joint == .teapot) {
                    const front = if (p.dout.axis() != 1) p.dout else p.din;
                    teapot.draw(S, cam, c, .py, front, col, teapot_size);
                } else ball(cam, c, col);
            }
            if (s1 > 0.5) half(cam, c, p.dout, @max(s0, 0.5) - 0.5, s1 - 0.5, col);
        }

        /// Background everywhere, z buffer to far, whole screen dirty.
        pub fn clear_all() void {
            zbuf.clear();
            S.mark_dirty(Rect.full);
        }

        /// Dissolve step: clears blocks [from, to) of a fixed pseudo-random
        /// permutation of the `block_count` 4x4 blocks (screen and z buffer).
        pub fn clear_blocks(from: u16, to: u16) void {
            var box: Box = .{};
            var i: u32 = from;
            const end: u32 = @min(to, block_count);
            while (i < end) : (i += 1) {
                const b = (i * block_step) % block_count;
                const x0: u32 = (b % blocks_x) * 4;
                const y0: u32 = (b / blocks_x) * 4;
                for (x0..x0 + 4) |x| {
                    for (y0..y0 + 4) |y| {
                        zbuf.buf[x][y] = zbuf.far;
                        S.put(@intCast(x), @intCast(y), 0);
                    }
                }
                box.add(x0, y0);
                box.add(x0 + 3, y0 + 3);
            }
            box.mark();
        }

        /// The half cylinder from the centre `c` along `dir`, covering
        /// distances [a0, a1] from the centre (0 <= a0, a1 <= 0.5).
        fn half(cam: *const camera.Camera, c: Vec3, dir: grid.Dir, a0: f32, a1: f32, col: u4) void {
            if (dir.sign() > 0) cylinder(cam, c, dir, a0, a1, col) else cylinder(cam, c, dir, -a1, -a0, col);
        }

        /// Capped cylinder of radius r_pipe on the line through the cell
        /// centre `c` along `dir`'s axis, axial coordinates [lo, hi]
        /// relative to the centre. Every piece of one cell traces from the
        /// same origin (eye - c), so slices agree to the last bit.
        fn cylinder(cam: *const camera.Camera, c: Vec3, dir: grid.Dir, lo: f32, hi: f32, col: u4) void {
            if (hi <= lo) return;
            switch (dir.axis()) {
                inline 0, 1, 2 => |a| {
                    var lo_w = c - math.splat(r_pipe);
                    var hi_w = c + math.splat(r_pipe);
                    lo_w[a] = c[a] + lo;
                    hi_w[a] = c[a] + hi;
                    const t: CylTracer(a) = .{ .o = cam.eye - c, .lo = lo, .hi = hi };
                    fill(cam, cam.screen_rect(lo_w, hi_w), col, &t);
                },
                else => unreachable,
            }
        }

        fn ball(cam: *const camera.Camera, c: Vec3, col: u4) void {
            const t: BallTracer = .{ .o = cam.eye - c };
            fill(cam, cam.screen_rect(c - math.splat(r_ball), c + math.splat(r_ball)), col, &t);
        }

        /// Quarter torus about the corner `centre - din/2 + dout/2`, from
        /// the entry face (u = -dout) to the exit face (v = din), slice
        /// [s0, s1] by angle.
        fn elbow(cam: *const camera.Camera, p: grid.Prim, s0: f32, s1: f32) void {
            if (s1 <= s0) return;
            const u = -p.dout.vec();
            const v = p.din.vec();
            const corner = p.center() - (u + v) * math.splat(0.5);
            const t = trace.Elbow.init(cam.eye, corner, u, v, r_elbow, r_pipe, s0, s1);
            // The arc is monotone along u and v over a quarter turn, so its
            // box is the box of its ends; the tube adds r_pipe all round.
            const e0 = corner + (u * math.splat(math.cos_turns(s0 * 0.25)) + v * math.splat(math.sin_turns(s0 * 0.25))) * math.splat(r_elbow);
            const e1 = corner + (u * math.splat(math.cos_turns(s1 * 0.25)) + v * math.splat(math.sin_turns(s1 * 0.25))) * math.splat(r_elbow);
            const lo_w = @min(e0, e1) - math.splat(r_pipe);
            const hi_w = @max(e0, e1) + math.splat(r_pipe);
            fill(cam, cam.screen_rect(lo_w, hi_w), p.color, &t);
        }

        /// The per-pixel loop shared by every primitive: ray, trace, z
        /// test, shade, put; then one dirty rect around what was written.
        inline fn fill(cam: *const camera.Camera, r: Rect, col: u4, tracer: anytype) void {
            var box: Box = .{};
            var x: u32 = r.x0;
            while (x < r.x1) : (x += 1) {
                const fx: f32 = @floatFromInt(x);
                const zcol = &zbuf.buf[x];
                var y: u32 = r.y0;
                var y_lo: u32 = 0xFF;
                var y_hi: u32 = 0;
                while (y < r.y1) : (y += 1) {
                    const d = cam.ray(fx, @floatFromInt(y));
                    const h = tracer.hit(d) orelse continue;
                    const z: u16 = @intFromFloat(@min(h.t * zbuf.scale, 65534.0));
                    if (z >= zcol[y]) continue;
                    zcol[y] = z;
                    S.put(x, y, shade.shade(col, h.n, d, x, y));
                    y_lo = @min(y_lo, y);
                    y_hi = y;
                }
                if (y_hi >= y_lo) {
                    box.add(x, y_lo);
                    box.add(x, y_hi);
                }
            }
            box.mark();
        }

        /// Running bounding box of written pixels, marked dirty at the end.
        const Box = struct {
            x0: u32 = 0xFF,
            y0: u32 = 0xFF,
            x1: u32 = 0,
            y1: u32 = 0,

            inline fn add(b: *Box, x: u32, y: u32) void {
                b.x0 = @min(b.x0, x);
                b.y0 = @min(b.y0, y);
                b.x1 = @max(b.x1, x + 1);
                b.y1 = @max(b.y1, y + 1);
            }
            fn mark(b: Box) void {
                if (b.x1 <= b.x0) return;
                S.mark_dirty(.{ .x0 = @intCast(b.x0), .y0 = @intCast(b.y0), .x1 = @intCast(b.x1), .y1 = @intCast(b.y1) });
            }
        };
    };
}

fn CylTracer(comptime axis: u2) type {
    return struct {
        o: Vec3,
        lo: f32,
        hi: f32,
        inline fn hit(t: *const @This(), d: Vec3) ?trace.Hit {
            return trace.cylinder(axis, t.o, d, r_pipe, t.lo, t.hi);
        }
    };
}

const BallTracer = struct {
    o: Vec3,
    inline fn hit(t: *const BallTracer, d: Vec3) ?trace.Hit {
        return trace.sphere(t.o, d, r_ball);
    }
};

// ---------------------------------------------------------------------------
// Host tests.

/// Array pixel sink. Records every put and checks it lies inside the next
/// marked rect (puts are only legal before the mark that covers them).
fn TestSurface(comptime tag: u8) type {
    return struct {
        const tag_value = tag;
        var px: [camera.screen_w][camera.screen_h]u16 = @splat(@splat(0));
        var pend_x0: u32 = 0xFF;
        var pend_y0: u32 = 0xFF;
        var pend_x1: u32 = 0;
        var pend_y1: u32 = 0;
        var outside: u32 = 0;
        var puts: u32 = 0;

        fn reset() void {
            px = @splat(@splat(0));
            pend_x0 = 0xFF;
            pend_y0 = 0xFF;
            pend_x1 = 0;
            pend_y1 = 0;
            outside = 0;
            puts = 0;
        }
        pub fn put(x: u32, y: u32, c: u16) void {
            px[x][y] = c;
            puts += 1;
            pend_x0 = @min(pend_x0, x);
            pend_y0 = @min(pend_y0, y);
            pend_x1 = @max(pend_x1, x + 1);
            pend_y1 = @max(pend_y1, y + 1);
        }
        pub fn mark_dirty(r: Rect) void {
            if (pend_x1 > pend_x0 and (pend_x0 < r.x0 or pend_y0 < r.y0 or pend_x1 > r.x1 or pend_y1 > r.y1)) outside += 1;
            pend_x0 = 0xFF;
            pend_y0 = 0xFF;
            pend_x1 = 0;
            pend_y1 = 0;
        }
        /// Puts not yet covered by a mark.
        fn unmarked() bool {
            return pend_x1 > pend_x0;
        }
    };
}

/// A small fixed scene: one pipe through a straight run, an elbow, a ball
/// turn, a teapot turn and both caps; a second pipe crossing behind it with
/// elbows on two other axes.
const test_scene = blk: {
    const P = struct {
        fn cell(x: u5, y: u5, z: u5, din: grid.Dir, dout: grid.Dir, color: u4, joint: grid.Joint) grid.Prim {
            return .{ .x = x, .y = y, .z = z, .din = din, .dout = dout, .color = color, .joint = joint };
        }
    };
    break :blk [_]grid.Prim{
        P.cell(2, 4, 6, .none, .px, 0, .ball),
        P.cell(3, 4, 6, .px, .px, 0, .ball),
        P.cell(4, 4, 6, .px, .px, 0, .ball),
        P.cell(5, 4, 6, .px, .py, 0, .elbow),
        P.cell(5, 5, 6, .py, .py, 0, .ball),
        P.cell(5, 6, 6, .py, .pz, 0, .ball),
        P.cell(5, 6, 7, .pz, .pz, 0, .ball),
        P.cell(5, 6, 8, .pz, .nx, 0, .teapot),
        P.cell(4, 6, 8, .nx, .nx, 0, .ball),
        P.cell(3, 6, 8, .nx, .none, 0, .ball),
        P.cell(8, 2, 9, .none, .nz, 7, .ball),
        P.cell(8, 2, 8, .nz, .nz, 7, .ball),
        P.cell(8, 2, 7, .nz, .py, 7, .elbow),
        P.cell(8, 3, 7, .py, .py, 7, .ball),
        P.cell(8, 4, 7, .py, .nx, 7, .elbow),
        P.cell(7, 4, 7, .nx, .nx, 7, .ball),
        P.cell(6, 4, 7, .nx, .nz, 7, .elbow),
        P.cell(6, 4, 6, .nz, .nz, 7, .ball),
        P.cell(6, 4, 5, .nz, .ny, 7, .ball),
        P.cell(6, 3, 5, .ny, .ny, 7, .ball),
        P.cell(6, 2, 5, .ny, .px, 7, .elbow),
        P.cell(7, 2, 5, .px, .none, 7, .ball),
        P.cell(1, 7, 3, .none, .pz, 2, .ball),
        P.cell(1, 7, 4, .pz, .px, 2, .elbow),
        P.cell(2, 7, 4, .px, .px, 2, .ball),
        P.cell(3, 7, 4, .px, .ny, 2, .elbow),
        P.cell(3, 6, 4, .ny, .none, 2, .ball),
    };
};

test "slices build the same image as whole cells, all puts inside marked rects" {
    const A = TestSurface('a');
    const B = TestSurface('b');
    const RA = Renderer(A);
    const RB = Renderer(B);
    for ([_]usize{ 3, 0, 4, 5 }) |vi| {
        const cam = camera.view(vi, 0);
        A.reset();
        B.reset();
        zbuf.clear();
        for (test_scene) |p| RA.draw_cell(&cam, p, 0, 1);
        zbuf.clear();
        for (test_scene) |p| {
            for (0..4) |q| {
                const qf: f32 = @floatFromInt(q);
                RB.draw_cell(&cam, p, qf * 0.25, (qf + 1) * 0.25);
            }
        }
        try std.testing.expect(A.puts > 250);
        try std.testing.expectEqual(@as(u32, 0), A.outside);
        try std.testing.expectEqual(@as(u32, 0), B.outside);
        try std.testing.expect(!A.unmarked());
        try std.testing.expect(!B.unmarked());
        var differ: u32 = 0;
        for (0..camera.screen_w) |x| {
            for (0..camera.screen_h) |y| {
                if (A.px[x][y] != B.px[x][y]) differ += 1;
            }
        }
        try std.testing.expect(differ <= 4);
    }
}

test "clear_blocks covers every block once and marks it" {
    const A = TestSurface('c');
    const R = Renderer(A);
    A.reset();
    for (&A.px) |*col| @memset(col, 0xFFFF);
    @memset(&zbuf.buf[0], 7);
    var i: u16 = 0;
    while (i < block_count) : (i += 64) R.clear_blocks(i, @min(i + 64, block_count));
    try std.testing.expectEqual(@as(u32, 0), A.outside);
    try std.testing.expectEqual(@as(u32, camera.screen_w * camera.screen_h), A.puts);
    for (A.px) |col| for (col) |c| try std.testing.expectEqual(@as(u16, 0), c);
    for (zbuf.buf[0]) |z| try std.testing.expectEqual(zbuf.far, z);
}

test "pipe start and end draw their cap balls once" {
    const A = TestSurface('d');
    const R = Renderer(A);
    const cam = camera.view(3, 0);
    A.reset();
    zbuf.clear();
    const start: grid.Prim = .{ .x = 6, .y = 5, .z = 6, .din = .none, .dout = .px, .color = 3 };
    R.draw_cell(&cam, start, 0, 0.25);
    const after_first = A.puts;
    try std.testing.expect(after_first > 0);
    // Later quarters add only the cylinder, never the ball again.
    R.draw_cell(&cam, start, 0.25, 0.5);
    const s = cam.project(start.center());
    const cx: u32 = @intFromFloat(s[0]);
    const cy: u32 = @intFromFloat(s[1]);
    try std.testing.expect(A.px[cx][cy] != 0);
}

// Renders the test scene from every view into one contact sheet when
// SNOUTY_PIPES_PPM names an output file (4 x 2 views, 2x scale).
test "debug contact sheet" {
    const path = std.testing.environ.getPosix("SNOUTY_PIPES_PPM") orelse return;
    const A = TestSurface('e');
    const R = Renderer(A);
    const sc = 2;
    const w = camera.screen_w * 4 * sc;
    const h = camera.screen_h * 2 * sc;
    const header = std.fmt.comptimePrint("P6\n{d} {d}\n255\n", .{ w, h });
    const img = try std.testing.allocator.alloc(u8, header.len + w * h * 3);
    defer std.testing.allocator.free(img);
    @memcpy(img[0..header.len], header);
    // Top row: four framed views. Bottom row: close-ups of the scene.
    const close = [4][3]f32{ .{ 1, 0.6, 1 }, .{ -1, 0.5, 1 }, .{ 0.3, 1, 0.4 }, .{ 1, -0.4, 0.7 } };
    for (0..8) |vi| {
        const target = grid.cell_center(5, 4, 7);
        const cd = close[vi % 4];
        const cam = if (vi < 4) camera.view(vi + 3, 0) else camera.Camera.look_at(
            target + math.normalize(math.vec3(cd[0], cd[1], cd[2])) * math.splat(6.5),
            target,
            math.vec3(0, 1, 0),
        );
        A.reset();
        zbuf.clear();
        for (test_scene) |p| R.draw_cell(&cam, p, 0, 1);
        const ox = (vi % 4) * camera.screen_w * sc;
        const oy = (vi / 4) * camera.screen_h * sc;
        for (0..camera.screen_h * sc) |yy| {
            for (0..camera.screen_w * sc) |xx| {
                const c = A.px[xx / sc][yy / sc];
                const o = header.len + ((oy + yy) * w + ox + xx) * 3;
                img[o + 0] = @intCast(((c & 31) * 255) / 31);
                img[o + 1] = @intCast((((c >> 5) & 63) * 255) / 63);
                img[o + 2] = @intCast(((c >> 11) * 255) / 31);
            }
        }
    }
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = img });
}

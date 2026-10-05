//! Host tests over the whole pipeline: hand -> uniforms -> each program ->
//! surface, the way main.zig runs it (no cart API).
const std = @import("std");
const field = @import("field.zig");
const hand = @import("hand.zig");
const math = @import("math.zig");
const noise = @import("noise.zig");
const palette = @import("palette.zig");
const programs = @import("programs.zig");
const surface = @import("surface.zig");
const uniforms = @import("uniforms.zig");

var surf: surface.Surface = undefined;

fn setup() void {
    math.init_tables();
    noise.init();
    field.init();
    programs.init_all();
    hand.reset();
    uniforms.reset();
}

fn checksum() u64 {
    var sum: u64 = 0;
    for (surf, 0..) |col, x| for (col, 0..) |p, y| {
        sum +%= @as(u64, surface.unspread(p)) *% (x * 131 + y * 7 + 1);
    };
    return sum;
}

fn distinct_colours() usize {
    var seen: [1024]bool = @splat(false);
    var n: usize = 0;
    for (surf) |col| for (col) |p| {
        const k = (surface.unspread(p) *% 40503) >> 6 & 1023;
        if (!seen[k]) {
            seen[k] = true;
            n += 1;
        }
    };
    return n;
}

/// Run `ticks` ticks of the ghost through program `p`.
fn run(p: usize, ticks: u32) void {
    const pr = &programs.list[p];
    for (0..ticks) |i| {
        hand.update(.{}, @as(u64, i) * 16_667);
        uniforms.update(4);
        pr.render(&uniforms.u, &palette.all[pr.default_palette], &surf);
    }
}

test "programs: every program fills the surface with a varied, moving image" {
    setup();
    for (0..programs.count) |p| {
        programs.list[p].enter();
        run(p, 120);
        const a = checksum();
        const n = distinct_colours();
        if (n <= 40) std.debug.print("{s}: {d} colours\n", .{ programs.list[p].name, n });
        try std.testing.expect(n > 40);
        run(p, 30);
        try std.testing.expect(checksum() != a);
    }
}

test "programs: the hand changes the image (field and pose reach every program)" {
    for (0..programs.count) |p| {
        // Same tick, with and without a hand in the uniforms.
        setup();
        programs.list[p].enter();
        for (0..90) |_| uniforms.update(4);
        const pr = &programs.list[p];
        pr.render(&uniforms.u, &palette.all[0], &surf);
        const empty = checksum();

        setup();
        programs.list[p].enter();
        hand.hand = .{ .present = true, .x = 0.3, .y = -0.2, .z = 0.8, .roll = 0.3, .yaw = 0.4, .vx = 0.5 };
        for (0..9) |i| {
            hand.cells.presence[i] = if (i == 4 or i == 5) 1 else 0;
            hand.cells.near[i] = 0.8;
        }
        for (0..90) |_| uniforms.update(4);
        pr.render(&uniforms.u, &palette.all[0], &surf);
        if (checksum() == empty) std.debug.print("{s}: no hand effect\n", .{pr.name});
        try std.testing.expect(checksum() != empty);
    }
}

test "programs: deterministic from a reset" {
    setup();
    programs.list[3].enter();
    run(3, 60);
    const a = checksum();
    setup();
    programs.list[3].enter();
    run(3, 60);
    try std.testing.expectEqual(a, checksum());
}

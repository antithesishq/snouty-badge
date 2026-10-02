//! Host unit tests (`zig build test`): the flight model and the map ring
//! without the renderer. They get the real cart API for its types; nothing
//! they run touches the platform or the framebuffer.
const std = @import("std");
const fixed = @import("fixed.zig");
const world = @import("world.zig");
const camera = @import("camera.zig");
const input = @import("input.zig");

/// One attract frame as main.zig's fly() runs it, minus the drawing.
fn fly(frame: u32) void {
    input.update(@bitCast(@as(u16, 0)));
    const stick = camera.pilot(frame);
    camera.update(stick, frame);
    const row = camera.cam_row();
    world.advance_to(row);
    world.tick(frame, row, stick.verb);
}

/// Every row of the window advance_to promises is in the ring.
fn window_ok(row: i32) bool {
    var y = row - world.keep_behind;
    while (y < row + world.gen_ahead) : (y += 1) {
        if (!world.generated_row(y)) return false;
    }
    return true;
}

// G2 (review 2026-10-01): an i32 Q16 camera y wrapped negative at row 32768
// while the ring's generation head stayed positive, so terrain stopped.
test "autopilot flies across row 32768 with the ring window intact" {
    world.advance_to(camera.cam_row());
    camera.init();
    // Land on the Bus that starts a pair below the old limit, the way a
    // Select skip does (main.zig start_skip), and refill the ring.
    const start: i32 = 32768 - world.pair_len;
    camera.jump_to(start);
    world.skip_reset(start);
    while (!world.advance_partial(camera.cam_row(), 96)) {}

    const goal: i32 = 32768 + world.pair_len;
    var prev = camera.cam_row();
    var frame: u32 = 0;
    while (camera.cam_row() < goal) : (frame += 1) {
        try std.testing.expect(frame < 2000); // cruise is 0.75 rows per frame
        fly(frame);
        const row = camera.cam_row();
        try std.testing.expect(row >= prev);
        prev = row;
        try std.testing.expect(window_ok(row));
        if (frame % 16 == 0) try std.testing.expectEqual(@as(u32, 0), world.check(row));
    }
    try std.testing.expectEqual(@as(u32, 0), world.check(camera.cam_row()));
    // Past the old limit the camera is on the pair after the crossing.
    try std.testing.expect(world.segment_at(camera.cam_row()).index >= 2 * (32768 / world.pair_len));
}

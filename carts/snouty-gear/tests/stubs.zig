//! M0: the subsystem stubs compile with their M1 public shapes (PLAN.md,
//! "Frozen for M1"). Zig only analyses what is referenced, so call each.
const std = @import("std");
const core = @import("core");

test "stubs: Z80 steps through the bus, VDP ticks a frame, PSG latches" {
    var data: [0x8000]u8 = @splat(0);
    data[0] = 0x00;
    var gg = core.Gg.init(core.Rom.from_slice(&data));
    var b = gg.bus_for();
    var t: u32 = 0;
    var done = false;
    while (!done) {
        const n = gg.cpu.step(&b);
        t += n;
        done = gg.vdp.tick(n, gg.line_sink);
    }
    try std.testing.expectEqual(core.frame_tstates, t);
    b.write(0xC123, 0x42);
    try std.testing.expectEqual(@as(u8, 0x42), b.read(0xE123));
    b.write(0xFFFF, 1);
    try std.testing.expectEqual(@as(u8, 1), gg.mapper.slot[2]);
    b.out(0x7F, 0x9F);
    try std.testing.expectEqual(@as(u8, 1), gg.psg.latch);
    try std.testing.expectEqual(@as(u8, 0xFF), b.in(0xDC));
    try std.testing.expect(!b.irq_line());
    var line: [core.screen_w]u5 = undefined;
    gg.vdp.render_line(0, &line);
    _ = gg.vdp.read_status();
    _ = gg.vdp.read_data();
    gg.vdp.write_data(0);
    gg.vdp.write_control(0);
    try std.testing.expectEqual(@as(u16, 0xDFF0), gg.cpu.sp);
}

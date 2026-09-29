//! M0: the test pattern reaches the line sink, 144 lines per frame, and
//! changes from frame to frame and with the pad.
const std = @import("std");
const core = @import("core");

const Hasher = struct {
    lines: u32 = 0,
    next_y: u32 = 0,
    in_order: bool = true,
    hash: u64 = 0,

    fn on_line(ctx: *anyopaque, y: u8, pixels: *const [core.screen_w]u5, cram: *const [32]u16) void {
        const h: *Hasher = @ptrCast(@alignCast(ctx));
        if (y != h.next_y) h.in_order = false;
        h.next_y = y + 1;
        h.lines += 1;
        var w = std.hash.Wyhash.init(h.hash);
        w.update(&.{y});
        for (pixels) |p| w.update(&.{@as(u8, p)});
        w.update(std.mem.sliceAsBytes(cram));
        h.hash = w.final();
    }

    fn sink(h: *Hasher) core.LineSink {
        return .{ .ctx = h, .func = &on_line };
    }

    fn start_frame(h: *Hasher) void {
        h.lines = 0;
        h.next_y = 0;
        h.hash = 0;
    }
};

const data: [0x10000]u8 = @splat(0xC9);

test "pattern: 144 lines per frame, hash changes every frame" {
    var gg = core.Gg.init(core.Rom.from_slice(&data));
    var h: Hasher = .{};
    gg.line_sink = h.sink();
    var prev: ?u64 = null;
    for (0..10) |_| {
        h.start_frame();
        gg.step_frame(0);
        try std.testing.expectEqual(@as(u32, 144), h.lines);
        try std.testing.expect(h.in_order);
        if (prev) |p| try std.testing.expect(p != h.hash);
        prev = h.hash;
    }
    try std.testing.expectEqual(@as(u32, 10), gg.frame_count);
}

test "pattern: deterministic, and the pad changes it" {
    var a = core.Gg.init(core.Rom.from_slice(&data));
    var b = core.Gg.init(core.Rom.from_slice(&data));
    var ha: Hasher = .{};
    var hb: Hasher = .{};
    a.line_sink = ha.sink();
    b.line_sink = hb.sink();
    for (0..5) |_| {
        ha.start_frame();
        hb.start_frame();
        a.step_frame(core.Pad.right);
        b.step_frame(core.Pad.right);
        try std.testing.expectEqual(ha.hash, hb.hash);
    }
    ha.start_frame();
    hb.start_frame();
    a.step_frame(core.Pad.b1);
    b.step_frame(0);
    try std.testing.expect(ha.hash != hb.hash);
}

test "pattern: snapshot, restore, replay gives the same frame" {
    var gg = core.Gg.init(core.Rom.from_slice(&data));
    var h: Hasher = .{};
    gg.line_sink = h.sink();
    for (0..7) |i| gg.step_frame(if (i % 2 == 0) core.Pad.down else core.Pad.right);
    const k = try std.testing.allocator.create(core.Gg.Keyframe);
    defer std.testing.allocator.destroy(k);
    gg.snapshot(k);
    h.start_frame();
    gg.step_frame(core.Pad.start);
    const want = h.hash;
    gg.restore(k);
    h.start_frame();
    gg.step_frame(core.Pad.start);
    try std.testing.expectEqual(want, h.hash);
}

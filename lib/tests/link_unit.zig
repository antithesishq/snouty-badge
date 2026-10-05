//! lib/link.zig over lib/link_virtual.zig: two badges on a simulated cable.
const std = @import("std");
const link = @import("../link.zig");
const virtual = @import("../link_virtual.zig");

const L = link.Link(virtual.Port);

const Pair = struct {
    cable: virtual.Cable,
    a: L,
    b: L,
    now: u64 = 1_000_000,

    fn init(pair: *Pair, kind: virtual.Kind, seed: u32) void {
        pair.* = .{ .cable = .{ .kind = kind }, .a = undefined, .b = undefined };
        pair.a = L.init(pair.cable.port(0), 0x4C, seed *% 2654435761 +% 1);
        pair.b = L.init(pair.cable.port(1), 0x4C, seed *% 40503 +% 7);
    }

    /// Advance `us` in steps of `step`, polling both ends each step (b a
    /// little later in the step, as two badges are never in phase).
    fn run(pair: *Pair, us: u64, step: u64) void {
        const end = pair.now + us;
        while (pair.now < end) {
            pair.now += step;
            pair.a.poll(pair.now);
            pair.b.poll(pair.now + step / 3);
        }
    }

    fn run_until_connected(pair: *Pair, limit: u64, step: u64) !u64 {
        const t0 = pair.now;
        while (pair.now - t0 < limit) {
            pair.run(step, step);
            if (pair.a.connected() and pair.b.connected()) return pair.now - t0;
        }
        return error.NeverConnected;
    }
};

test "both cable kinds connect, at 1 ms and at frame-rate polling, without fights" {
    for ([_]virtual.Kind{ .crossed, .straight }) |kind| {
        for ([_]u64{ 1_000, 16_667 }) |step| {
            var worst: u64 = 0;
            var seed: u32 = 1;
            while (seed <= 200) : (seed += 1) {
                var pair: Pair = undefined;
                pair.init(kind, seed);
                const took = try pair.run_until_connected(10_000_000, step);
                worst = @max(worst, took);
                try std.testing.expectEqual(@as(u32, 0), pair.cable.fights);
                const want: link.Cable = if (kind == .crossed) .crossed else .straight;
                try std.testing.expectEqual(want, pair.a.cable());
                try std.testing.expectEqual(want, pair.b.cable());
                try std.testing.expectEqual(@as(u8, 0x4C), pair.a.partner_app);
                try std.testing.expectEqual(link.protocol_version, pair.b.partner_version);
                // Stays connected (keepalives) and quiet.
                pair.run(5_000_000, step);
                try std.testing.expect(pair.a.connected() and pair.b.connected());
                try std.testing.expectEqual(@as(u32, 1), pair.a.session);
                try std.testing.expectEqual(@as(u32, 1), pair.b.session);
                try std.testing.expectEqual(@as(u32, 0), pair.cable.fights);
                try std.testing.expectEqual(@as(u32, 0), pair.a.stats.crc_errors + pair.b.stats.crc_errors);
            }
            // Generous bound: typically well under a second.
            try std.testing.expect(worst < 3_000_000);
        }
    }
}

test "data packets arrive intact and in order, SLIP bytes included" {
    var pair: Pair = undefined;
    pair.init(.straight, 42);
    _ = try pair.run_until_connected(10_000_000, 1_000);
    const msgs = [_][]const u8{
        &.{0x01},
        &.{ 0xC0, 0xDB, 0xDC, 0xDD },
        &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 0xC0 },
        &.{},
    };
    for (msgs) |m| try std.testing.expect(pair.a.send(pair.now, m));
    try std.testing.expect(pair.b.send(pair.now, "hi"));
    const too_long: [link.max_payload + 1]u8 = @splat(0);
    try std.testing.expect(!pair.a.send(pair.now, &too_long));
    pair.run(1_000, 1_000);
    for (msgs) |m| {
        const p = pair.b.recv() orelse return error.Missing;
        try std.testing.expectEqualSlices(u8, m, p.slice());
    }
    try std.testing.expect(pair.b.recv() == null);
    try std.testing.expectEqualSlices(u8, "hi", (pair.a.recv() orelse return error.Missing).slice());
}

test "a corrupted packet is dropped by the CRC, the next one gets through" {
    var pair: Pair = undefined;
    pair.init(.crossed, 3);
    _ = try pair.run_until_connected(10_000_000, 1_000);
    // Inject a frame with a bad CRC straight into b's receive buffer.
    const e = &pair.cable.ends[1];
    for ([_]u8{ 0xC0, 0x10, 0x55, 0x00, 0xC0 }) |byte| {
        e.rx[e.rx_head +% @as(u8, @truncate(e.rx_len))] = byte;
        e.rx_len += 1;
    }
    try std.testing.expect(pair.a.send(pair.now, &.{0x66}));
    pair.run(1_000, 1_000);
    try std.testing.expectEqual(@as(u32, 1), pair.b.stats.crc_errors);
    try std.testing.expectEqualSlices(u8, &.{0x66}, (pair.b.recv() orelse return error.Missing).slice());
    try std.testing.expect(pair.b.recv() == null);
}

test "unplug drops both ends to searching, replug reconnects with a new session" {
    var pair: Pair = undefined;
    pair.init(.straight, 9);
    _ = try pair.run_until_connected(10_000_000, 16_667);
    pair.cable.plugged = false;
    pair.run(200_000, 16_667);
    try std.testing.expect(!pair.a.connected() and !pair.b.connected());
    try std.testing.expect(!pair.a.send(pair.now, &.{1}));
    pair.cable.plugged = true;
    _ = try pair.run_until_connected(10_000_000, 16_667);
    try std.testing.expectEqual(@as(u32, 2), pair.a.session);
    try std.testing.expectEqual(@as(u32, 2), pair.b.session);
    try std.testing.expectEqual(@as(u32, 0), pair.cable.fights);
}

test "a partner that restarts its cart gives a new session" {
    for ([_]virtual.Kind{ .crossed, .straight }) |kind| {
        var pair: Pair = undefined;
        pair.init(kind, 11);
        _ = try pair.run_until_connected(10_000_000, 16_667);
        // b's cart exits and starts again: pins released, a fresh link.
        pair.cable.reset_end(1);
        pair.b = L.init(pair.cable.port(1), 0x42, 777);
        _ = try pair.run_until_connected(10_000_000, 16_667);
        try std.testing.expectEqual(@as(u32, 2), pair.a.session);
        try std.testing.expectEqual(@as(u32, 1), pair.b.session);
        try std.testing.expectEqual(@as(u8, 0x42), pair.a.partner_app);
        try std.testing.expectEqual(@as(u32, 0), pair.cable.fights);
    }
}

test "a partner that goes silent times out" {
    var pair: Pair = undefined;
    pair.init(.crossed, 5);
    _ = try pair.run_until_connected(10_000_000, 16_667);
    // b stops polling (its cart hung or exited with the UART still idle-high).
    const end = pair.now + link.timing.peer_timeout + 100_000;
    while (pair.now < end) {
        pair.now += 16_667;
        pair.a.poll(pair.now);
    }
    try std.testing.expect(!pair.a.connected());
}

test "ping measures the round trip" {
    var pair: Pair = undefined;
    pair.init(.crossed, 8);
    _ = try pair.run_until_connected(10_000_000, 1_000);
    pair.a.ping(pair.now);
    pair.run(3_000, 1_000);
    try std.testing.expect(pair.a.rtt_us > 0 and pair.a.rtt_us <= 3_000);
}

test "the null port never runs" {
    var l = link.Link(link.NullPort).init(.{}, 1, 1);
    l.poll(1000);
    try std.testing.expectEqual(link.State.unavailable, l.state);
    try std.testing.expect(!l.send(1000, &.{1}));
}

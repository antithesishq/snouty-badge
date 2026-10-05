//! Host tests: two badges on lib/link_virtual.zig's cable, each running
//! the same frame loop as main.zig, play Pong in lockstep.
//! `zig build test -Dcart=snouty-pong`.
const std = @import("std");
const lockstep = @import("lockstep");
const link_host = @import("link_host");
const pong = @import("pong.zig");

const Link = link_host.link.Link(link_host.virtual.Port);
const Lockstep = lockstep.Lockstep(Link, pong);

/// One badge: main.zig's frame loop without the screen. Its player is a
/// bot that chases the ball on every other frame, so it can miss.
const Badge = struct {
    ls: Lockstep,
    world: pong.World = undefined,
    playing: bool = false,
    frames: u32 = 0,

    fn init(port: link_host.virtual.Port, nonce: u32) Badge {
        return .{ .ls = .init(Link.init(port, lockstep.apps.pong, nonce)) };
    }

    fn frame(b: *Badge, now: u64) void {
        b.ls.pump(now);
        if (b.ls.take_started()) {
            b.world = .init(b.ls.seed(), b.ls.rules().?[0]);
            b.playing = true;
        }
        b.frames += 1;
        var ticked = false;
        if (b.playing) {
            const bot: pong.Input = if (b.frames % 2 == 0) pong.cpu_input(&b.world, b.ls.local_slot()) else .{};
            b.ls.submit(now, @bitCast(bot));
            ticked = b.ls.step(&b.world);
        } else if (b.ls.state() == .lobby) {
            if (b.ls.role == .host) b.ls.set_rules(.{3});
            b.ls.set_pick(0, true);
            if (b.ls.role == .host and b.ls.can_go()) _ = b.ls.go(now);
        }
        // The late pump loop, a few times through the frame.
        var t = now + 4_000;
        while (t < now + 14_000) : (t += 4_000) {
            b.ls.pump(t);
            if (b.playing and !ticked) ticked = b.ls.step(&b.world);
        }
    }
};

const Pair = struct {
    cable: link_host.virtual.Cable = .{ .kind = .crossed },
    a: Badge = undefined,
    b: Badge = undefined,
    now: u64 = 1_000_000,

    fn init(p: *Pair) void {
        p.a = .init(p.cable.port(0), 1234);
        p.b = .init(p.cable.port(1), 98765);
    }

    /// Frames of 16.667 ms on one badge and 16.690 on the other (their
    /// clocks drift), until both Worlds have a winner.
    fn run(p: *Pair, max_frames: u32) void {
        for (0..max_frames) |_| {
            p.a.frame(p.now);
            p.b.frame(p.now + 7_000);
            p.now += 16_680;
            if (p.a.playing and p.b.playing and p.a.world.winner() != null and p.b.world.winner() != null) return;
        }
    }
};

test "pong: two badges play a whole match in lockstep" {
    var p: Pair = .{};
    p.init();
    p.run(20_000);

    try std.testing.expect(p.a.playing and p.b.playing);
    try std.testing.expect(p.a.ls.local_slot() != p.b.ls.local_slot());
    try std.testing.expectEqual(@as(u8, 3), p.a.world.target);
    try std.testing.expect(p.a.world.winner() != null);
    try std.testing.expectEqual(p.a.world, p.b.world);
}

test "pong: unplugged mid-match, the CPU finishes it for the partner" {
    var p: Pair = .{};
    p.init();
    p.run(600);
    try std.testing.expect(p.a.playing and p.b.playing);
    p.cable.plugged = false;
    p.run(20_000);

    for ([_]*Badge{ &p.a, &p.b }) |b| {
        try std.testing.expectEqual(lockstep.State.peer_left, b.ls.state());
        try std.testing.expect(b.world.cpu[~b.ls.local_slot()]);
        try std.testing.expect(b.world.winner() != null);
    }
}

test "pong: the same seed and inputs give the same World" {
    var w1: pong.World = .init(42, 5);
    var w2: pong.World = .init(42, 5);
    w1.cpu = .{ true, true };
    w2.cpu = .{ true, true };
    for (0..100_000) |_| {
        pong.simulate(&w1, .{ 0, 0 });
        pong.simulate(&w2, .{ 0, 0 });
    }
    try std.testing.expect(w1.winner() != null);
    try std.testing.expectEqual(pong.hash(&w1), pong.hash(&w2));
}

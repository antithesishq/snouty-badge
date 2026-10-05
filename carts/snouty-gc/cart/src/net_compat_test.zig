//! Wire compatibility of net.zig (GC's names over lib/lockstep.zig) with
//! the M4 net.zig verified on two badges (net_m4.zig, from 90683be4, tag
//! snouty-gc/m4-hw):
//!
//! - the same scripted lobby, two races, pause, quit, a rematch and a
//!   desync, run once on two M4 stacks and once on two new ones over the
//!   virtual cable (same seeds, inputs, byte loss and FIFO model), puts the
//!   exact same bytes on the wire from each badge, and every message kind
//!   (SETUP, PICK, GO, QUIT, DESYNC, input) occurs in it;
//! - an M4 badge and a new one race in sync to the finish, either hosting;
//! - a version-1 GC (lockstep's `G.version`) sends an M4 badge nothing:
//!   the M4 badge waits in its lobby, the new one says wrong_version.
const std = @import("std");
const host = @import("link_host");
const link = host.link;
const virtual = host.virtual;
const lockstep = @import("lockstep");
const world = @import("world.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const net = @import("net.zig");
const net_m4 = @import("net_m4.zig");
const racers = @import("racers.zig");

const World = world.World;

const report = true;

// ---- the cable: loss, the 8-byte FIFO, and a recorder ---------------------------

const Wire = struct {
    loss_ppm: u32 = 0,
    fifo: bool = false,
    rng: u32 = 0x1234_5678,
    /// Every byte each side put on the wire (before loss), in order.
    tx: [2]std.ArrayList(u8) = .{ .empty, .empty },

    fn next(wi: *Wire) u32 {
        var x = wi.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        wi.rng = x;
        return x;
    }
};

const Port = struct {
    pub const available = true;
    inner: virtual.Port,
    wire: *Wire,

    pub fn search(p: *Port, drive: link.Pin) void {
        p.inner.search(drive);
    }
    pub fn read(p: *Port, pin: link.Pin) bool {
        return p.inner.read(pin);
    }
    pub fn probe(p: *Port, pin: link.Pin) bool {
        return p.inner.probe(pin);
    }
    pub fn uart_start(p: *Port, tx: link.Pin) void {
        p.inner.uart_start(tx);
    }
    pub fn uart_put(p: *Port, byte: u8) bool {
        const wi = p.wire;
        wi.tx[p.inner.side].append(std.testing.allocator, byte) catch @panic("oom");
        if (wi.loss_ppm > 0 and wi.next() % 1_000_000 < wi.loss_ppm) return true;
        const far = &p.inner.cable.ends[p.inner.side ^ 1];
        if (wi.fifo and far.rx_len >= 8) return true;
        return p.inner.uart_put(byte);
    }
    pub fn uart_get(p: *Port) ?u8 {
        return p.inner.uart_get();
    }
    pub fn take_framing_errors(p: *Port) u32 {
        return p.inner.take_framing_errors();
    }
};

const L = link.Link(Port);
const Old = net_m4.Net(L);
const New = net.Net(L);

/// The struct holding role / tick / paused: M4's Net itself, the lockstep
/// inside the new one.
fn core(n: anytype) switch (@TypeOf(n)) {
    *Old => *Old,
    *New => *New.Ls,
    else => unreachable,
} {
    return if (@TypeOf(n) == *Old) n else &n.ls;
}

// ---- two badges, either stack on either side ---------------------------------------

const draw_points = [_]u64{ 0, 500, 1000, 1500, 2000, 2500, 3000 };

fn Badge(comptime N: type) type {
    return struct {
        net: N,
        w: World = .{},
        side: u1,
        period: u64,
        frame_start: u64,
        point: u8 = 0,
        rng: u32,
        racing: bool = false,
        frames: u64 = 0,
        stepped: bool = true,
        press_at: u64 = 0,
        leave_at: u32 = 0,
        mutate_at: u32 = 0,

        fn rand(b: *@This()) u32 {
            var x = b.rng;
            x ^= x << 13;
            x ^= x >> 17;
            x ^= x << 5;
            b.rng = x;
            return x;
        }

        fn next_time(b: *const @This()) u64 {
            if (b.point < draw_points.len) return b.frame_start + draw_points[b.point];
            return b.frame_start + draw_points[draw_points.len - 1] + 1000 * @as(u64, b.point - draw_points.len + 1);
        }

        fn done(b: *const @This()) bool {
            return b.w.phase == .finished;
        }

        fn script_byte(b: *@This()) u8 {
            var in = ai.drive(&b.w, b.net.local_car());
            const r = b.rand();
            if (r % 61 == 0) in.b = true;
            if (r % 113 == 0) in.left = !in.left;
            if (b.press_at != 0 and b.frames >= b.press_at and b.frames < b.press_at + 3) in.start = true;
            return in.byte();
        }

        fn try_step(b: *@This()) void {
            if (!b.racing or b.done()) return;
            if (!b.net.step(&b.w)) return;
            b.stepped = true;
            const c = core(&b.net);
            if (b.mutate_at != 0 and c.tick == b.mutate_at) b.w.cars[3].x +%= 1 << 16;
        }

        /// The top of update().
        fn frame(b: *@This(), now: u64, rules: net.Rules, pick: u8) void {
            const n = &b.net;
            const c = core(n);
            n.pump(now);
            if (n.state() == .lobby) {
                n.set_rules(if (N == Old) net_m4.Rules.decode(rules.encode()) else rules);
                n.set_pick(pick, true);
                if (c.role == .host and n.can_go()) _ = n.go(now);
            }
            if (n.take_started()) {
                sim.reset(&b.w, n.world_setup());
                b.racing = true;
            }
            const st = n.state();
            if (b.racing and (st == .racing or st == .waiting or st == .peer_left)) {
                if (b.leave_at != 0 and c.tick >= b.leave_at) {
                    n.leave(now);
                    b.racing = false;
                    b.leave_at = 0;
                    n.pump(now);
                    return;
                }
                _ = n.submit(now, b.script_byte());
                b.stepped = false;
                b.try_step();
            } else b.stepped = true;
            if (st == .desync and b.leave_at != 0 and b.frames >= b.leave_at) {
                n.leave(now);
                b.racing = false;
                b.leave_at = 0;
            }
            n.pump(now);
        }
    };
}

fn Duo(comptime N0: type, comptime N1: type) type {
    return struct {
        const Self = @This();
        cable: virtual.Cable,
        wire: Wire,
        b0: Badge(N0),
        b1: Badge(N1),
        now: u64,
        rules: net.Rules = .{},
        picks: [2]u8 = .{ racers.snouty, racers.kiddie },

        fn init(d: *Self, seed: u32, kind: virtual.Kind, loss_ppm: u32) void {
            d.cable = .{ .kind = kind };
            d.wire = .{ .loss_ppm = loss_ppm, .rng = seed *% 2_654_435_761 | 1 };
            d.now = 1_000_000;
            d.rules = .{};
            d.picks = .{ racers.snouty, racers.kiddie };
            const s0 = seed *% 2_654_435_761 +% 1;
            const s1 = seed *% 40_503 +% 7;
            d.b0 = .{ .net = N0.init(L.init(.{ .inner = d.cable.port(0), .wire = &d.wire }, net.app_id, s0)), .side = 0, .period = 16_667, .frame_start = d.now, .rng = s0 | 1 };
            d.b1 = .{ .net = N1.init(L.init(.{ .inner = d.cable.port(1), .wire = &d.wire }, net.app_id, s1)), .side = 1, .period = 16_690, .frame_start = d.now + 7_000, .rng = s1 | 1 };
        }

        fn deinit(d: *Self) void {
            for (&d.wire.tx) |*t| t.deinit(std.testing.allocator);
        }

        fn step_badge(d: *Self, b: anytype) void {
            d.now = b.next_time();
            d.wire.fifo = d.b0.net.state() != .searching and d.b1.net.state() != .searching;
            if (b.point == 0) b.frame(d.now, d.rules, d.picks[b.side]) else {
                b.net.pump(d.now);
                if (!b.stepped) b.try_step();
            }
            b.point += 1;
            if (b.point >= draw_points.len + 11) {
                b.point = 0;
                var len = b.period;
                if (b.rand() % 150 == 0) len *= 2;
                b.frame_start += len;
                b.frames += 1;
            }
        }

        fn run(d: *Self, limit_us: u64, ctx: anytype, comptime done: fn (*Self, @TypeOf(ctx)) bool) !void {
            const end = d.now + limit_us;
            while (!done(d, ctx)) {
                if (d.now > end) return error.Timeout;
                if (d.b0.next_time() <= d.b1.next_time()) d.step_badge(&d.b0) else d.step_badge(&d.b1);
            }
        }

        fn run_for(d: *Self, us: u64) void {
            d.run(us + 1_000_000, d.now + us, struct {
                fn f(dd: *Self, e: u64) bool {
                    return dd.now >= e;
                }
            }.f) catch unreachable;
        }

        fn both_racing(d: *Self, _: void) bool {
            return d.b0.racing and d.b1.racing;
        }
        fn both_tick(d: *Self, t: u32) bool {
            return core(&d.b0.net).tick >= t and core(&d.b1.net).tick >= t;
        }
        fn both_finished(d: *Self, _: void) bool {
            return d.b0.done() and d.b1.done();
        }
        fn both_lobby(d: *Self, _: void) bool {
            return d.b0.net.state() == .lobby and d.b1.net.state() == .lobby;
        }
        fn both_desync(d: *Self, _: void) bool {
            return d.b0.net.state() == .desync and d.b1.net.state() == .desync;
        }
    };
}

/// The scripted session: lobby, race 1 with a pause (badge 1's Start) and
/// a resume (badge 0's), badge 1 quits, badge 0 finishes the race with the
/// AI and leaves, race 2 with new rules, a World changed on badge 0 (a
/// desync), both leave, the lobby again.
fn session(comptime N: type, seed: u32, kind: virtual.Kind, loss_ppm: u32, d: *Duo(N, N)) !void {
    d.init(seed, kind, loss_ppm);
    try d.run(20_000_000, {}, Duo(N, N).both_racing);
    try d.run(60_000_000, @as(u32, 300), Duo(N, N).both_tick);
    d.b1.press_at = d.b1.frames + 1;
    try d.run(60_000_000, @as(u32, 420), Duo(N, N).both_tick);
    d.b0.press_at = d.b0.frames + 1;
    d.b1.leave_at = 900;
    try d.run(60_000_000, {}, struct {
        fn f(dd: *Duo(N, N), _: void) bool {
            return dd.b0.net.state() == .peer_left and dd.b1.net.state() == .lobby;
        }
    }.f);
    d.b0.leave_at = core(&d.b0.net).tick + 200;
    d.rules = .{ .mode = .gc, .track = 2, .crews = 2 };
    d.picks = .{ racers.botnet, racers.legacy };
    try d.run(60_000_000, {}, Duo(N, N).both_racing);
    d.b0.mutate_at = 400;
    try d.run(60_000_000, {}, Duo(N, N).both_desync);
    d.b0.leave_at = @intCast(d.b0.frames + 20);
    d.b1.leave_at = @intCast(d.b1.frames + 35);
    d.run_for(1_500_000);
}

/// Decode a recorded byte stream into its DATA packets' first byte kinds.
const Kinds = struct {
    setup: u32 = 0,
    pick: u32 = 0,
    go: u32 = 0,
    quit: u32 = 0,
    desync: u32 = 0,
    input: u32 = 0,

    fn of(bytes: []const u8) Kinds {
        var k: Kinds = .{};
        var frame: [32]u8 = undefined;
        var len: usize = 0;
        var esc = false;
        for (bytes) |b| {
            if (b == 0xC0) {
                if (len >= 3 and frame[0] == @backingInt(link.Kind.data)) {
                    const payload = frame[1 .. len - 1];
                    if (payload.len == net.input_len) k.input += 1 else switch (payload[0]) {
                        0xA1 => k.setup += 1,
                        0xA2 => k.pick += 1,
                        0xA3 => k.go += 1,
                        0xA4 => k.quit += 1,
                        0xA5 => k.desync += 1,
                        else => {},
                    }
                }
                len = 0;
                esc = false;
                continue;
            }
            var v = b;
            if (esc) {
                v = if (b == 0xDC) 0xC0 else if (b == 0xDD) 0xDB else b;
                esc = false;
            } else if (b == 0xDB) {
                esc = true;
                continue;
            }
            if (len < frame.len) {
                frame[len] = v;
                len += 1;
            }
        }
        return k;
    }
};

test "net compat: M4 and the lockstep wrapper put the same bytes on the wire" {
    const cases = [_]struct { seed: u32, kind: virtual.Kind, loss: u32 }{
        .{ .seed = 3, .kind = .crossed, .loss = 0 },
        .{ .seed = 8, .kind = .straight, .loss = 0 },
        .{ .seed = 17, .kind = .crossed, .loss = 10_000 },
    };
    for (cases) |c| {
        var a: Duo(Old, Old) = undefined;
        try session(Old, c.seed, c.kind, c.loss, &a);
        defer a.deinit();
        var b: Duo(New, New) = undefined;
        try session(New, c.seed, c.kind, c.loss, &b);
        defer b.deinit();
        for (0..2) |s| {
            const x = a.wire.tx[s].items;
            const y = b.wire.tx[s].items;
            if (std.mem.indexOfDiff(u8, x, y)) |at| {
                const lo = at -| 24;
                std.debug.print("\nseed {d} side {d}: first difference at byte {d} of {d} / {d}\nM4:  {x}\nnew: {x}\n", .{ c.seed, s, at, x.len, y.len, x[lo..@min(x.len, at + 24)], y[lo..@min(y.len, at + 24)] });
                return error.WireDiffers;
            }
            const k = Kinds.of(b.wire.tx[s].items);
            if (report) std.debug.print("\ncompat seed {d} side {d}: {d} wire bytes identical; SETUP {d}, PICK {d}, GO {d}, QUIT {d}, DESYNC {d}, input {d}\n", .{ c.seed, s, b.wire.tx[s].items.len, k.setup, k.pick, k.go, k.quit, k.desync, k.input });
            try std.testing.expect(k.pick > 0 and k.quit > 0 and k.desync > 0 and k.input > 1000);
        }
        // SETUP and GO come from the host, whichever side it is.
        const k0 = Kinds.of(b.wire.tx[0].items);
        const k1 = Kinds.of(b.wire.tx[1].items);
        try std.testing.expect(k0.setup + k1.setup > 0 and k0.go + k1.go > 0);
        try std.testing.expectEqual(core(&a.b0.net).tick, core(&b.b0.net).tick);
    }
}

test "net compat: an M4 badge and a converted one race in sync, either hosting" {
    inline for (.{ .{ Old, New }, .{ New, Old } }) |pair| {
        var seed: u32 = 1;
        var hosts: [2]bool = .{ false, false };
        while (seed <= 6) : (seed += 1) {
            const D = Duo(pair[0], pair[1]);
            var d: D = undefined;
            d.init(seed, if (seed % 2 == 0) .straight else .crossed, if (seed % 3 == 0) 10_000 else 0);
            defer d.deinit();
            try d.run(20_000_000, {}, D.both_racing);
            hosts[if (core(&d.b0.net).role == .host) 0 else 1] = true;
            try d.run(400_000_000, {}, D.both_finished);
            try std.testing.expect(sim.worlds_equal(&d.b0.w, &d.b1.w));
            try std.testing.expectEqualStrings("racing", @tagName(d.b0.net.state()));
            try std.testing.expectEqualStrings("racing", @tagName(d.b1.net.state()));
        }
        try std.testing.expect(hosts[0] and hosts[1]);
    }
}

/// GC with `G.version = 1`: every other decl as net.Game.
const GameV1 = struct {
    pub const World = net.Game.World;
    pub const rules_len = net.Game.rules_len;
    pub const input_delay = net.Game.input_delay;
    pub const check_every = net.Game.check_every;
    pub const pause_bit = net.Game.pause_bit;
    pub const pick_bits = net.Game.pick_bits;
    pub const simulate = net.Game.simulate;
    pub const hash = net.Game.hash;
    pub const hand_over = net.Game.hand_over;
    pub const picks_ok = net.Game.picks_ok;
    pub const can_pause = net.Game.can_pause;
    pub const version: u4 = 1;
};

test "net compat: a version-1 GC and an M4 badge never race" {
    const V1 = lockstep.Lockstep(L, GameV1);
    for ([_]u32{ 1, 2, 3, 4 }) |seed| {
        var cable: virtual.Cable = .{ .kind = if (seed % 2 == 0) .straight else .crossed };
        var wire: Wire = .{};
        defer for (&wire.tx) |*t| t.deinit(std.testing.allocator);
        var old = Old.init(L.init(.{ .inner = cable.port(0), .wire = &wire }, net.app_id, seed *% 2_654_435_761 +% 1));
        var new = V1.init(L.init(.{ .inner = cable.port(1), .wire = &wire }, net.app_id, seed *% 40_503 +% 7));
        var now: u64 = 1_000_000;
        while (now < 6_000_000) : (now += 16_667) {
            old.pump(now);
            if (old.state() == .lobby) {
                old.set_pick(racers.snouty, true);
                if (old.role == .host and old.can_go()) _ = old.go(now);
            }
            _ = old.take_started();
            new.pump(now + 7_000);
            new.set_pick(racers.kiddie, true);
            _ = new.take_started();
        }
        try std.testing.expectEqual(net_m4.State.lobby, old.state());
        try std.testing.expect(old.peer_pick == null);
        try std.testing.expectEqual(lockstep.State.wrong_version, new.state());
        try std.testing.expectEqual(@as(u32, 0), new.stats.control_sent);
        try std.testing.expectEqual(@as(u8, 0x11), old.link.partner_version);
    }
}

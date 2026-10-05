//! Host tests for the link race (M6): two badges, each a lockstep
//! (`Lockstep(L, link_race.G)`) and a World, on a lib/link_virtual.zig
//! cable, run on a shared microsecond clock with their own 60 Hz frames
//! (one a little slower, an occasional missed vsync), polling the link
//! only at the frame's pump points, with the badge's 8-entry receive FIFO
//! and optional byte loss. Each badge's frame is main.zig's link race
//! frame: pump, submit the byte (0 once its own machine is home), step at
//! most once, pump through the draw, and with `loop_until` pump and retry
//! to 14 ms. The model follows Snouty GC's net_test.zig.
const std = @import("std");
const host = @import("link_host");
const link = host.link;
const virtual = host.virtual;
const lockstep = @import("lockstep");
const world = @import("world.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const link_race = @import("link_race.zig");

const World = world.World;
const G = link_race.G;

/// Print per-test summaries (loss, stalls, detection latency).
const report = true;

// ---- the cable with faults --------------------------------------------------

/// Faults on top of the virtual cable: random byte loss, and the badge's
/// 8-entry receive FIFO (a byte arriving while 8 are unread is lost). The
/// virtual cable delivers a packet instantly, so the FIFO model is
/// pessimistic. Off until both links are connected.
const Wire = struct {
    loss_ppm: u32 = 0,
    fifo: bool = false,
    rng: u32 = 0x1234_5678,
    lost: u32 = 0,
    overflow: u32 = 0,

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
        if (wi.loss_ppm > 0 and wi.next() % 1_000_000 < wi.loss_ppm) {
            wi.lost += 1;
            return true;
        }
        const far = &p.inner.cable.ends[p.inner.side ^ 1];
        if (wi.fifo and far.rx_len >= 8) {
            wi.overflow += 1;
            return true;
        }
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
const N = lockstep.Lockstep(L, G);

// ---- two badges ----------------------------------------------------------------

const max_steps = 16_000;
/// World hash after each successful step, per side (index = steps taken).
var logs: [2][max_steps + 1]u32 = undefined;

const Opts = struct {
    seed: u32 = 1,
    kind: virtual.Kind = .crossed,
    loss_ppm: u32 = 0,
    /// The host's track (`track.tracks` index).
    track: u8 = 0,
    /// The machine each side picks (side, not role: the nonces pick the host).
    picks: [2]u8 = .{ 0, 3 },
    /// The app byte of side 1's link (another cart: not link_race.app_id).
    app1: u8 = link_race.app_id,
    /// Pump in a loop until this far into the frame (us), as the cart does.
    loop_until: u64 = 14_000,
    /// Side 1's frame is this much longer (us) than side 0's 16 667.
    drift: u64 = 23,
    /// One frame in this many takes two vsyncs (0: never).
    slow_every: u32 = 150,
    auto_lobby: bool = true,
};

/// Pump points inside a frame (us from the frame's start): the top of
/// update, then a ~3 ms draw (Zero pumps only at the top and after it).
const draw_points = [_]u64{ 0, 3000 };

const Badge = struct {
    net: N,
    w: World = .{},
    side: u1,
    period: u64,
    frame_start: u64,
    point: u8 = 0,
    rng: u32,
    racing: bool = false,
    frames: u64 = 0,
    /// Successful steps this race (the lockstep tick, paused ones included).
    steps: u32 = 0,
    wait_run: u32 = 0,
    wait_max: u32 = 0,
    wait_frames: u32 = 0,
    /// Steps at which `paused` turned on / off.
    pause_on: ?u32 = null,
    pause_off: ?u32 = null,
    /// Hold Start on frames [press_start_at, +3) (0: never).
    press_start_at: u64 = 0,
    /// Mutate the World once `steps` reaches this (0: never).
    mutate_at: u32 = 0,
    stepped: bool = true,

    fn done(b: *const Badge) bool {
        return b.w.phase == .finished;
    }

    fn rand(b: *Badge) u32 {
        var x = b.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b.rng = x;
        return x;
    }

    fn next_time(b: *const Badge, points: u8) u64 {
        _ = points;
        if (b.point < draw_points.len) return b.frame_start + draw_points[b.point];
        return b.frame_start + draw_points[draw_points.len - 1] + 1000 * @as(u64, b.point - draw_points.len + 1);
    }

    fn me(b: *const Badge) u8 {
        return link_race.machine_of(b.net.local_slot());
    }

    /// This side's race byte (main.zig `link_byte`): the autopilot on its
    /// machine with a few random taps so the two humans differ; nothing
    /// once its machine has finished.
    fn script_byte(b: *Badge) u8 {
        const i = b.me();
        if (b.w.machines[i].f.finished) return 0;
        world.w = b.w;
        var in = ai.drive_human(&b.w.machines[i], i);
        const r = b.rand();
        if (r % 61 == 0) in.b = true;
        if (r % 113 == 0) in.left = !in.left;
        if (r % 151 == 0) in.up = true;
        if (b.press_start_at != 0 and b.frames >= b.press_start_at and b.frames < b.press_start_at + 3) in.start = true;
        return link_race.byte_of(in);
    }
};

const Duo = struct {
    cable: virtual.Cable,
    wire: Wire,
    b: [2]Badge,
    now: u64,
    opts: Opts,

    fn init(d: *Duo, opts: Opts) void {
        d.cable = .{ .kind = opts.kind };
        d.wire = .{ .loss_ppm = opts.loss_ppm, .rng = opts.seed *% 2_654_435_761 | 1 };
        d.opts = opts;
        d.now = 1_000_000;
        for (0..2) |i| {
            const side: u1 = @intCast(i);
            const app: u8 = if (side == 1) opts.app1 else link_race.app_id;
            const seed = if (side == 0) opts.seed *% 2_654_435_761 +% 1 else opts.seed *% 40_503 +% 7;
            const l = L.init(.{ .inner = d.cable.port(side), .wire = &d.wire }, app, seed);
            d.b[i] = .{
                .net = N.init(l),
                .side = side,
                .period = 16_667 + if (side == 1) opts.drift else 0,
                .frame_start = d.now + @as(u64, side) * 7_000,
                .rng = seed | 1,
            };
        }
    }

    fn pump_points(d: *const Duo) u8 {
        const last = draw_points[draw_points.len - 1];
        if (d.opts.loop_until <= last) return draw_points.len;
        return @intCast(draw_points.len + (d.opts.loop_until - last) / 1000);
    }

    /// Run events in time order until `done` or `limit_us` of virtual time.
    fn run(d: *Duo, limit_us: u64, ctx: anytype, comptime done: fn (*Duo, @TypeOf(ctx)) bool) !void {
        const end = d.now + limit_us;
        const points = d.pump_points();
        while (!done(d, ctx)) {
            if (d.now > end) {
                for (&d.b) |*b| std.debug.print("timeout: side {d} role {t} state {t} steps {d} w.phase {t} racing {}\n", .{ b.side, b.net.role, b.net.state(), b.steps, b.w.phase, b.racing });
                return error.Timeout;
            }
            const i: usize = if (d.b[0].next_time(points) <= d.b[1].next_time(points)) 0 else 1;
            const b = &d.b[i];
            d.now = b.next_time(points);
            d.wire.fifo = d.b[0].net.link.connected() and d.b[1].net.link.connected();
            if (b.point == 0) d.frame(b) else {
                b.net.pump(d.now);
                // main's pump loop: retry a stalled step while busy.
                if (!b.stepped and (b.point < draw_points.len or b.net.busy())) d.try_step(b);
            }
            b.point += 1;
            if (b.point >= points) {
                if (b.racing and !b.stepped and !b.done()) {
                    b.wait_frames += 1;
                    b.wait_run += 1;
                    b.wait_max = @max(b.wait_max, b.wait_run);
                } else b.wait_run = 0;
                b.point = 0;
                var len = b.period;
                if (d.opts.slow_every != 0 and b.rand() % d.opts.slow_every == 0) len *= 2;
                b.frame_start += len;
                b.frames += 1;
            }
        }
    }

    /// The top of one badge's update(): main.zig's lobby and race frames.
    fn frame(d: *Duo, b: *Badge) void {
        const n = &b.net;
        n.pump(d.now);
        if (d.opts.auto_lobby and n.state() == .lobby) {
            if (n.role == .host) n.set_rules(.{d.opts.track});
            n.set_pick(d.opts.picks[b.side], true);
            if (n.role == .host and n.can_go()) _ = n.go(d.now);
        }
        if (n.take_started()) {
            link_race.reset(&b.w, n.rules().?, n.picks(), n.seed());
            b.racing = true;
            b.steps = 0;
            logs[b.side][0] = G.hash(&b.w);
        }
        const st = n.state();
        if (b.racing and (st == .racing or st == .waiting or st == .peer_left)) {
            const byte = b.script_byte();
            n.submit(d.now, byte);
            b.stepped = false;
            d.try_step(b);
        } else b.stepped = true;
        n.pump(d.now);
    }

    /// One lockstep step at most per frame.
    fn try_step(_: *Duo, b: *Badge) void {
        const n = &b.net;
        if (!b.racing or b.done()) return;
        const was_paused = n.paused;
        if (!n.step(&b.w)) return;
        b.stepped = true;
        b.steps += 1;
        if (n.paused and !was_paused) b.pause_on = b.steps;
        if (!n.paused and was_paused) b.pause_off = b.steps;
        if (b.steps <= max_steps) logs[b.side][b.steps] = G.hash(&b.w);
        if (b.mutate_at != 0 and b.steps == b.mutate_at) b.w.machines[6].x +%= 1 << 16;
    }

    fn both(d: *Duo, s: lockstep.State) bool {
        return d.b[0].net.state() == s and d.b[1].net.state() == s;
    }
};

fn done_lobby(d: *Duo, _: void) bool {
    return d.both(.lobby);
}
fn done_started(d: *Duo, _: void) bool {
    return d.b[0].racing and d.b[1].racing;
}
fn done_finished(d: *Duo, _: void) bool {
    return d.b[0].done() and d.b[1].done();
}
fn done_steps(d: *Duo, t: u32) bool {
    return d.b[0].steps >= t and d.b[1].steps >= t;
}

/// Both badges logged the same World hash after every step both took.
fn expect_logs_equal(d: *const Duo) !u32 {
    const upto = @min(@min(d.b[0].steps, d.b[1].steps), max_steps);
    var t: u32 = 0;
    while (t <= upto) : (t += 1) {
        if (logs[0][t] != logs[1][t]) {
            std.debug.print("World hashes differ after step {d}\n", .{t});
            return error.Desync;
        }
    }
    return upto;
}

const Tally = struct {
    races: u32 = 0,
    ticks: u64 = 0,
    wait_max: u32 = 0,
    wait_frames: u64 = 0,
    frames: u64 = 0,
    lost: u64 = 0,
    overflow: u64 = 0,
    crc: u64 = 0,

    fn add(t: *Tally, d: *const Duo) void {
        t.races += 1;
        t.ticks += d.b[0].steps;
        for (&d.b) |*b| {
            t.wait_max = @max(t.wait_max, b.wait_max);
            t.wait_frames += b.wait_frames;
            t.frames += b.frames;
            t.crc += b.net.link.stats.crc_errors;
        }
        t.lost += d.wire.lost;
        t.overflow += d.wire.overflow;
    }

    fn print(t: *const Tally, name: []const u8) void {
        if (!report) return;
        std.debug.print("\n{s}: {d} races, {d} lockstep ticks; {d} injected byte losses, {d} FIFO overflow bytes, {d} CRC drops; frames without a tick {d} of {d}, longest run {d}\n", .{ name, t.races, t.ticks, t.lost, t.overflow, t.crc, t.wait_frames, t.frames, t.wait_max });
    }
};

/// One link race from cold (search, lobby, GO) to both badges finished;
/// checks the per-step World hashes and the final Worlds.
fn synced_race(opts: Opts, tally: *Tally) !void {
    var d: Duo = undefined;
    d.init(opts);
    try d.run(20_000_000, {}, done_started);
    try std.testing.expectEqual(d.b[0].net.seed(), d.b[1].net.seed());
    try std.testing.expectEqual(d.b[0].net.picks(), d.b[1].net.picks());
    try std.testing.expectEqual(d.b[0].net.rules().?, d.b[1].net.rules().?);
    try std.testing.expectEqual(opts.track, d.b[0].net.rules().?[0]);
    // The same World from the agreed setup (one badge may have stepped
    // the all-zero first ticks already).
    try std.testing.expectEqual(logs[0][0], logs[1][0]);
    try d.run(400_000_000, {}, done_finished);
    try std.testing.expectEqual(d.b[0].steps, d.b[1].steps);
    try std.testing.expect(sim.worlds_equal(&d.b[0].w, &d.b[1].w));
    _ = try expect_logs_equal(&d);
    for (&d.b) |*b| {
        // Each badge drove its own machine (no hand-over) and both humans
        // are home with their places.
        try std.testing.expect(!b.w.ai_drives[0] and !b.w.ai_drives[1]);
        for (b.w.humans) |h| {
            try std.testing.expect(b.w.machines[h].f.finished);
            try std.testing.expect(b.w.machines[h].rank >= 1 and b.w.machines[h].rank <= 5);
        }
        try std.testing.expect(b.net.state() == .racing or b.net.state() == .waiting);
    }
    tally.add(&d);
}

// ---- tests ---------------------------------------------------------------------

test "lobby: the higher nonce hosts; another cart is told apart; no link offline" {
    var seed: u32 = 1;
    while (seed <= 8) : (seed += 1) {
        var d: Duo = undefined;
        d.init(.{ .seed = seed, .kind = if (seed % 2 == 0) .straight else .crossed, .auto_lobby = false });
        try d.run(10_000_000, {}, done_lobby);
        const a = &d.b[0].net;
        const b = &d.b[1].net;
        try std.testing.expect(a.role != .none and b.role != .none and a.role != b.role);
        try std.testing.expect(a.local_slot() != b.local_slot());
    }
    var d: Duo = undefined;
    d.init(.{ .seed = 3, .app1 = 'G', .auto_lobby = false });
    const Wc = struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].net.state() == .wrong_cart;
        }
    };
    try d.run(10_000_000, {}, Wc.f);
    try std.testing.expectEqual(@as(u8, 'G'), d.b[0].net.link.partner_app);
    var o = lockstep.Lockstep(link.Link(link.NullPort), G).init(link.Link(link.NullPort).init(.{}, link_race.app_id, 1));
    o.pump(1000);
    try std.testing.expectEqual(lockstep.State.offline, o.state());
}

test "lobby: the host's track reaches the guest live, both may pick the same machine" {
    var d: Duo = undefined;
    d.init(.{ .seed = 77, .auto_lobby = false, .loss_ppm = 20_000 });
    try d.run(20_000_000, {}, done_lobby);
    const hs: usize = if (d.b[0].net.role == .host) 0 else 1;
    const h = &d.b[hs].net;
    const g = &d.b[hs ^ 1].net;
    h.set_rules(.{7});
    h.set_pick(2, true);
    g.set_pick(2, false);
    const Seen = struct {
        fn f(dd: *Duo, s: usize) bool {
            const gg = &dd.b[s ^ 1].net;
            return gg.rules() != null and gg.rules().?[0] == 7 and dd.b[s].net.peer_pick() != null;
        }
    };
    try d.run(5_000_000, hs, Seen.f);
    try std.testing.expect(!h.can_go());
    g.set_pick(2, true);
    const Can = struct {
        fn f(dd: *Duo, s: usize) bool {
            return dd.b[s].net.can_go();
        }
    };
    try d.run(5_000_000, hs, Can.f);
    try std.testing.expect(h.go(d.now));
    d.opts.auto_lobby = true;
    d.opts.track = 7;
    d.opts.picks = .{ 2, 2 };
    try d.run(20_000_000, {}, done_started);
    for (&d.b) |*b| {
        try std.testing.expectEqual([2]u8{ 2, 2 }, b.w.picks);
        try std.testing.expect(sim.current == link_race.track_of(.{7}));
    }
    try d.run(60_000_000, @as(u32, 600), done_steps);
    _ = try expect_logs_equal(&d);
}

test "a full link race to the finish stays in sync, clean and with 1% byte loss" {
    var clean: Tally = .{};
    try synced_race(.{ .seed = 1, .track = 0, .picks = .{ 0, 3 } }, &clean);
    try synced_race(.{ .seed = 2, .kind = .straight, .track = 4, .picks = .{ 1, 1 }, .loop_until = 0 }, &clean);
    clean.print("link race, clean cable");
    var lossy: Tally = .{};
    var seed: u32 = 101;
    while (seed <= 104) : (seed += 1) {
        try synced_race(.{
            .seed = seed,
            .kind = if (seed % 2 == 0) .straight else .crossed,
            .track = @intCast((seed * 2) % 9),
            .picks = .{ @intCast(seed % 5), @intCast((seed * 3) % 5) },
            .loss_ppm = 10_000,
        }, &lossy);
    }
    lossy.print("link race, 1% byte loss");
}

test "peer left mid-race: the AI drives that machine and both finish" {
    var d: Duo = undefined;
    d.init(.{ .seed = 31, .track = 1, .picks = .{ 4, 0 } });
    try d.run(20_000_000, {}, done_started);
    try d.run(60_000_000, @as(u32, 1500), done_steps);
    _ = try expect_logs_equal(&d);
    d.cable.plugged = false;
    const Left = struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.both(.peer_left);
        }
    };
    const t0 = d.now;
    try d.run(5_000_000, {}, Left.f);
    if (report) std.debug.print("\nunplug: both peer_left after {d} ms\n", .{(d.now - t0) / 1000});
    try d.run(400_000_000, {}, done_finished);
    for (&d.b) |*b| {
        try std.testing.expectEqual(lockstep.Left.unplugged, b.net.left);
        const mine = b.net.local_slot();
        // The partner's machine went to the AI, still the partner's.
        try std.testing.expect(b.w.ai_drives[mine ^ 1]);
        try std.testing.expect(!b.w.ai_drives[mine]);
        for (b.w.humans) |h| try std.testing.expect(b.w.machines[h].f.finished);
    }
}

test "a World changed on one badge is a desync on both within 64 ticks" {
    var worst: u32 = 0;
    for ([_]u32{ 600, 1001, 1231 }, 0..) |at, k| {
        var d: Duo = undefined;
        d.init(.{ .seed = 40 + @as(u32, @intCast(k)), .loss_ppm = if (k == 2) 10_000 else 0 });
        d.b[k % 2].mutate_at = at;
        try d.run(20_000_000, {}, done_started);
        try d.run(120_000_000, {}, struct {
            fn f(dd: *Duo, _: void) bool {
                return dd.both(.desync);
            }
        }.f);
        for (&d.b) |*b| {
            const late = b.steps - at;
            worst = @max(worst, late);
            try std.testing.expect(b.steps >= at and late <= 64);
            // step stops on desync.
            try std.testing.expect(!b.net.step(&b.w));
        }
    }
    if (report) std.debug.print("\ndesync: found on both badges at most {d} ticks after the change\n", .{worst});
}

test "Start pauses both badges on the same tick, the other's Start resumes" {
    var d: Duo = undefined;
    d.init(.{ .seed = 12, .track = 2 });
    try d.run(20_000_000, {}, done_started);
    try d.run(60_000_000, @as(u32, 400), done_steps);
    d.b[0].press_start_at = d.b[0].frames + 1;
    const On = struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].pause_on != null and dd.b[1].pause_on != null and dd.b[0].steps > dd.b[0].pause_on.? + 60 and dd.b[1].steps > dd.b[1].pause_on.? + 60;
        }
    };
    try d.run(10_000_000, {}, On.f);
    try std.testing.expectEqual(d.b[0].pause_on.?, d.b[1].pause_on.?);
    // Frozen: the race clock stands while the lockstep runs on.
    const wt = d.b[0].w.tick;
    const s0 = d.b[0].steps;
    try d.run(5_000_000, s0 + 60, done_steps);
    try std.testing.expectEqual(wt, d.b[0].w.tick);
    try std.testing.expect(d.b[0].net.paused and d.b[1].net.paused);
    d.b[1].press_start_at = d.b[1].frames + 1;
    const Off = struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].pause_off != null and dd.b[1].pause_off != null;
        }
    };
    try d.run(10_000_000, {}, Off.f);
    try std.testing.expectEqual(d.b[0].pause_off.?, d.b[1].pause_off.?);
    try d.run(400_000_000, {}, done_finished);
    try std.testing.expect(sim.worlds_equal(&d.b[0].w, &d.b[1].w));
    _ = try expect_logs_equal(&d);
}

test "the lockstep over the badge's link compiles" {
    std.testing.refAllDecls(lockstep.Lockstep(link.Badge, G));
}

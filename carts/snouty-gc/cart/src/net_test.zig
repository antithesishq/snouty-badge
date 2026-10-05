//! Host tests for net.zig (PLAN M4 Track A item 5): two badges, each a
//! `Net` and a `World`, on a lib/link_virtual.zig cable, run on a shared
//! microsecond clock with their own 60 Hz frames (one a little slower, an
//! occasional missed vsync), polling the link only at the frame's pump
//! points, with the badge's 8-entry receive FIFO and optional byte loss.
const std = @import("std");
const host = @import("link_host");
const link = host.link;
const virtual = host.virtual;
const world = @import("world.zig");
const sim = @import("sim.zig");
const ai = @import("ai.zig");
const net = @import("net.zig");
const racers = @import("racers.zig");
const gc_mode = @import("gc_mode.zig");
const tuning = @import("tuning.zig");

const World = world.World;

/// Print per-test summaries (loss, stalls, detection latency).
const report = true;

// ---- the cable with faults --------------------------------------------------

/// Faults on top of the virtual cable: random byte loss, and the badge's
/// 8-entry receive FIFO (a byte arriving while 8 are unread is lost). The
/// virtual cable delivers a packet instantly, so the FIFO model is
/// pessimistic: a packet that arrives while the receiver draws waits whole
/// in the FIFO and the next one is lost. Off until both links are
/// connected (a HELLO is 10 wire bytes; on the badge the handshake polls in
/// a loop).
const Wire = struct {
    loss_ppm: u32 = 0,
    fifo: bool = false,
    rng: u32 = 0x1234_5678,
    lost: u32 = 0,
    overflow: u32 = 0,
    gets: u64 = 0,
    puts: u64 = 0,

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
        wi.puts += 1;
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
        p.wire.gets += 1;
        return p.inner.uart_get();
    }
    pub fn take_framing_errors(p: *Port) u32 {
        return p.inner.take_framing_errors();
    }
};

const L = link.Link(Port);
const N = net.Net(L);

// ---- two badges ----------------------------------------------------------------

const max_ticks = 16_000;
/// World hash after each lockstep tick, per side (index = tick).
var logs: [2][max_ticks + 1]u32 = undefined;

const Opts = struct {
    seed: u32 = 1,
    kind: virtual.Kind = .crossed,
    loss_ppm: u32 = 0,
    rules: net.Rules = .{},
    /// The racer each side picks (side, not role: the nonces pick the host).
    picks: [2]u8 = .{ racers.snouty, racers.kiddie },
    /// The app byte of side 1's link (another cart: not net.app_id).
    app1: u8 = net.app_id,
    /// Pump in a loop until this far into the frame (us), as the cart may.
    loop_until: u64 = 0,
    /// Side 1's frame is this much longer (us) than side 0's 16 667.
    drift: u64 = 23,
    /// One frame in this many takes two vsyncs (0: never).
    slow_every: u32 = 150,
    /// Lobby on autopilot (rules, picks, ready, GO).
    auto_lobby: bool = true,
};

/// Pump points inside a frame (us from the frame's start): the top of
/// update, then the floor bands and sprite / HUD passes of a ~3 ms draw.
const draw_points = [_]u64{ 0, 500, 1000, 1500, 2000, 2500, 3000 };

const Badge = struct {
    net: N,
    w: World = .{},
    side: u1,
    period: u64,
    frame_start: u64,
    point: u8 = 0,
    rng: u32,
    /// The World was reset from the agreed setup.
    racing: bool = false,
    /// Stop stepping once the World's race is finished (so both badges end
    /// on the same tick).
    stop_at_finish: bool = true,
    frames: u64 = 0,
    /// Frames in a row where step ran nothing, and the longest such run.
    wait_run: u32 = 0,
    wait_max: u32 = 0,
    wait_frames: u32 = 0,
    /// Lockstep ticks at which `paused` turned on / off.
    pause_on: ?u32 = null,
    pause_off: ?u32 = null,
    /// Hold Start on frames [press_at, press_at + 3) (0: never).
    press_start_at: u64 = 0,
    /// Leave the race once the lockstep tick reaches this (0: never).
    leave_at: u32 = 0,
    /// Mutate the World once the lockstep tick reaches this (0: never).
    mutate_at: u32 = 0,

    /// This frame's tick has run (or there is nothing to run).
    stepped: bool = true,
    /// main.zig's pause (M4 Track B, net.Resume since the integration):
    /// while `paused` only the Start bit is submitted, and RESUME (picked
    /// on frame `resume_frame`, or with `resume_on_stall` on the first
    /// paused frame whose byte `submit` will drop) holds Start until
    /// `paused` turns off.
    main_pause: bool = false,
    resume_frame: u64 = 0,
    resume_on_stall: bool = false,
    hold: net.Resume = .{},
    /// RESUME requests made; how many of them had their first held Start
    /// byte dropped (M4's one-frame edge would have been lost: the race
    /// stays paused); held Start bytes dropped in all.
    resumes: u32 = 0,
    first_dropped: u32 = 0,
    held_dropped: u32 = 0,
    first_held: bool = false,
    /// `paused` turned on / off this many times.
    pause_ons: u32 = 0,
    pause_offs: u32 = 0,

    fn done(b: *const Badge) bool {
        return b.stop_at_finish and b.w.phase == .finished;
    }

    fn rand(b: *Badge) u32 {
        var x = b.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b.rng = x;
        return x;
    }

    fn next_time(b: *const Badge) u64 {
        if (b.point < draw_points.len) return b.frame_start + draw_points[b.point];
        return b.frame_start + draw_points[draw_points.len - 1] + 1000 * @as(u64, b.point - draw_points.len + 1);
    }

    /// This side's race byte: the autopilot on its car, plus a few random
    /// taps so the two humans do not drive like the AI.
    fn script_byte(b: *Badge) u8 {
        var in = ai.drive(&b.w, b.net.local_car());
        const r = b.rand();
        if (r % 61 == 0) in.b = true;
        if (r % 89 == 0) in.select = true;
        if (r % 113 == 0) in.left = !in.left;
        if (b.press_start_at != 0 and b.frames >= b.press_start_at and b.frames < b.press_start_at + 3) in.start = true;
        // Start with a random Select tap is the OS chord: `submit` clears
        // both, so a held Start would show two edges (pause, unpause).
        // A player pausing does not press Select with it (M6: the v1 seeds
        // hit this in the RESUME test).
        if (in.start) in.select = false;
        return in.byte();
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
            const app: u8 = if (side == 1) opts.app1 else net.app_id;
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
        if (d.opts.loop_until <= draw_points[draw_points.len - 1]) return draw_points.len;
        return @intCast(draw_points.len + (d.opts.loop_until - draw_points[draw_points.len - 1]) / 1000);
    }

    /// Run `us` of virtual time.
    fn run_for(d: *Duo, us: u64) void {
        const Until = struct {
            fn f(dd: *Duo, end: u64) bool {
                return dd.now >= end;
            }
        };
        d.run(us + 1_000_000, d.now + us, Until.f) catch unreachable;
    }

    /// Run events in time order until `done` or `limit_us` of virtual time.
    fn run(d: *Duo, limit_us: u64, ctx: anytype, comptime done: fn (*Duo, @TypeOf(ctx)) bool) !void {
        const end = d.now + limit_us;
        const points = d.pump_points();
        while (!done(d, ctx)) {
            if (d.now > end) {
                if (report) for (&d.b) |*b| std.debug.print("timeout: side {d} role {t} state {t} tick {d} local_hi {d} remote_hi {d} peer_need {d} peer_top {d} w.phase {t} racing {}\n", .{ b.side, b.net.ls.role, b.net.state(), b.net.ls.tick, b.net.ls.local_hi, b.net.ls.remote_hi, b.net.ls.peer_need, b.net.ls.peer_top, b.w.phase, b.racing });
                return error.Timeout;
            }
            const i: usize = if (d.b[0].next_time() <= d.b[1].next_time()) 0 else 1;
            const b = &d.b[i];
            d.now = b.next_time();
            d.wire.fifo = d.b[0].net.ls.link.connected() and d.b[1].net.ls.link.connected();
            if (b.point == 0) d.frame(b) else {
                b.net.pump(d.now);
                // main's waiting loop: retry a stalled step while pumping.
                if (!b.stepped) d.try_step(b);
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

    /// The top of one badge's update(): what main.zig will do.
    fn frame(d: *Duo, b: *Badge) void {
        const n = &b.net;
        n.pump(d.now);
        if (d.opts.auto_lobby and n.state() == .lobby) {
            n.set_rules(d.opts.rules);
            n.set_pick(d.opts.picks[b.side], true);
            if (n.ls.role == .host and n.can_go()) _ = n.go(d.now);
        }
        if (n.take_started()) {
            sim.reset(&b.w, n.world_setup());
            b.racing = true;
            logs[b.side][0] = net.world_hash(&b.w);
        }
        const st = n.state();
        if (b.racing and (st == .racing or st == .waiting or st == .peer_left)) {
            if (b.leave_at != 0 and n.ls.tick >= b.leave_at) {
                n.leave(d.now);
                b.racing = false;
                n.pump(d.now);
                return;
            }
            var byte = b.script_byte();
            var picked = false;
            if (b.main_pause) {
                // As main.zig: settle at the top of the frame, the paused
                // frame's byte from the hold, RESUME picked after it.
                b.hold.settle(n.ls.paused);
                if (n.ls.paused) {
                    byte = b.hold.byte(byte & 0x40);
                    const full = n.ls.local_hi >= n.ls.tick + net.input_delay + 1;
                    if (b.resume_frame != 0 and b.frames >= b.resume_frame) picked = true;
                    if (b.resume_on_stall and full and !b.hold.pending) picked = true;
                }
            }
            const kept = n.submit(d.now, byte);
            if (b.main_pause) {
                if (b.hold.pending and byte & 0x40 != 0) {
                    if (!kept) b.held_dropped += 1;
                    if (b.first_held and !kept) b.first_dropped += 1;
                    b.first_held = false;
                }
                b.hold.took(byte, kept);
            }
            if (picked) {
                // main.zig picks RESUME after the frame's submit, so its
                // first held byte goes out next frame (a stall often lasts
                // several frames: `resume_on_stall` picks inside one).
                b.hold.request();
                b.resume_frame = 0;
                b.resume_on_stall = false;
                b.resumes += 1;
                b.first_held = true;
            }
            b.stepped = false;
            d.try_step(b);
        } else b.stepped = true;
        n.pump(d.now);
    }

    /// One lockstep tick at most per frame.
    fn try_step(_: *Duo, b: *Badge) void {
        const n = &b.net;
        if (!b.racing or b.done()) return;
        const was_paused = n.ls.paused;
        if (!n.step(&b.w)) return;
        b.stepped = true;
        if (n.ls.paused and !was_paused) {
            b.pause_on = n.ls.tick - 1;
            b.pause_ons += 1;
        }
        if (!n.ls.paused and was_paused) {
            b.pause_off = n.ls.tick - 1;
            b.pause_offs += 1;
        }
        if (n.ls.tick <= max_ticks) logs[b.side][n.ls.tick] = net.world_hash(&b.w);
        if (b.mutate_at != 0 and n.ls.tick == b.mutate_at) {
            // Car 3 a pixel over, and the PRNG: a hulk's respawn puts the
            // car back on its pad, which can erase the pixel before the
            // next check (M6: a v1 seed did), the PRNG change stays.
            b.w.cars[3].x +%= 1 << 16;
            b.w.rng ^= 0x10;
            if (b.w.rng == 0) b.w.rng = 1;
        }
    }

    fn both(d: *Duo, s: net.State) bool {
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
    return d.b[0].w.phase == .finished and d.b[1].w.phase == .finished;
}
fn done_tick(d: *Duo, t: u32) bool {
    return d.b[0].net.ls.tick >= t and d.b[1].net.ls.tick >= t;
}

/// Both badges logged the same World hash at every tick both reached.
fn expect_logs_equal(d: *const Duo) !u32 {
    const upto = @min(@min(d.b[0].net.ls.tick, d.b[1].net.ls.tick), max_ticks);
    var t: u32 = 0;
    while (t <= upto) : (t += 1) {
        if (logs[0][t] != logs[1][t]) {
            std.debug.print("World hashes differ at tick {d}\n", .{t});
            return error.Desync;
        }
    }
    return upto;
}

const Tally = struct {
    races: u32 = 0,
    ticks: u64 = 0,
    sent: u64 = 0,
    recv: u64 = 0,
    stale: u64 = 0,
    old_windows: u64 = 0,
    overflow: u64 = 0,
    lost: u64 = 0,
    puts: u64 = 0,
    crc: u64 = 0,
    wait_max: u32 = 0,
    wait_frames: u64 = 0,
    checks: u64 = 0,
    frames: u64 = 0,

    fn add(t: *Tally, d: *const Duo) void {
        t.races += 1;
        t.ticks += d.b[0].net.ls.tick;
        for (&d.b) |*b| {
            t.sent += b.net.ls.stats.inputs_sent;
            t.recv += b.net.ls.stats.inputs_recv;
            t.stale += b.net.ls.stats.inputs_stale;
            t.old_windows += b.net.ls.stats.old_windows;
            t.wait_max = @max(t.wait_max, b.wait_max);
            t.wait_frames += b.wait_frames;
            t.checks += b.net.ls.stats.checks_ok;
            t.crc += b.net.ls.link.stats.crc_errors;
            t.frames += b.frames;
        }
        t.overflow += d.wire.overflow;
        t.lost += d.wire.lost;
        t.puts += d.wire.puts;
    }

    fn print(t: *const Tally, name: []const u8) void {
        if (!report) return;
        const lost_pkts = t.sent -| t.recv;
        std.debug.print(
            "\n{s}: {d} races, {d} ticks; input packets sent {d}, received {d} ({d}.{d:0>2}% lost: {d} FIFO overflow bytes, {d} injected byte losses of {d}, {d} CRC drops); {d} stale, {d} old windows; checks ok {d}; frames without a tick {d} of {d}, longest run {d}\n",
            .{ name, t.races, t.ticks, t.sent, t.recv, lost_pkts * 100 / @max(t.sent, 1), (lost_pkts * 10000 / @max(t.sent, 1)) % 100, t.overflow, t.lost, t.puts, t.crc, t.stale, t.old_windows, t.checks, t.wait_frames, t.frames, t.wait_max },
        );
    }
};

/// One link race from cold (search, lobby, GO) to both badges finished;
/// checks the per-tick World hashes and the final Worlds.
fn synced_race(opts: Opts, tally: *Tally) !void {
    var d: Duo = undefined;
    d.init(opts);
    try d.run(20_000_000, {}, done_started);
    try std.testing.expectEqual(d.b[0].net.race().seed, d.b[1].net.race().seed);
    try std.testing.expect(std.meta.eql(d.b[0].net.world_setup(), d.b[1].net.world_setup()));
    // CREWS: the two humans and that many AI cars on the grid (L3).
    for (&d.b) |*b| try std.testing.expectEqual(2 + @min(opts.rules.crews, world.car_count - 2), gc_mode.active_count(&b.w));
    try d.run(400_000_000, {}, done_finished);
    try std.testing.expectEqual(d.b[0].net.ls.tick, d.b[1].net.ls.tick);
    try std.testing.expect(sim.worlds_equal(&d.b[0].w, &d.b[1].w));
    _ = try expect_logs_equal(&d);
    try std.testing.expectEqual(net.State.racing, d.b[0].net.state());
    try std.testing.expectEqual(net.State.racing, d.b[1].net.state());
    // Both humans drove (their cars are human slots) and finished: a lap
    // race when both crossed the line; GARBAGE COLLECTION when one car is
    // left (the survivor finished; a collected human is out, L4).
    for (&d.b) |*b| {
        const c = &b.w.cars[b.net.local_car()];
        try std.testing.expectEqual(@as(u8, b.net.local_slot()), c.human);
        if (b.w.mode == .gc) {
            try std.testing.expect(b.w.gc.survivor < world.car_count);
            const out = b.w.gc.collected & (@as(u8, 1) << @intCast(b.net.local_car())) != 0;
            try std.testing.expect(c.finished != out);
        } else try std.testing.expect(c.finished);
    }
    tally.add(&d);
}

fn picks_for(seed: u32) [2]u8 {
    const a: u8 = @intCast(seed % world.car_count);
    const b: u8 = @intCast((a + 1 + seed % 5) % world.car_count);
    return .{ a, b };
}

// ---- tests ---------------------------------------------------------------------

test "input packets are always 8 wire bytes and decode back" {
    try std.testing.expectEqual(link.crc8("123456789"), net.crc8("123456789"));
    try std.testing.expectEqual(@backingInt(link.Kind.data), net.data_kind);
    var r: u32 = 0xACE1;
    var n: u32 = 0;
    while (n < 64) : (n += 1) {
        var c: u32 = 0;
        while (c < 128) : (c += 1) {
            for (0..6) |_| {
                var ins: [3]u8 = undefined;
                for (&ins) |*x| {
                    r ^= r << 13;
                    r ^= r >> 17;
                    r ^= r << 5;
                    x.* = net.sanitize(@truncate(r));
                }
                const p = net.encode_input(n + 64 * (r % 50), ins, @intCast(c));
                var buf: [1 + net.input_len]u8 = undefined;
                buf[0] = net.data_kind;
                @memcpy(buf[1..], &p);
                var wire_len: u32 = 2; // CRC and END
                for (buf) |byte| wire_len += if (byte == 0xC0 or byte == 0xDB) 2 else 1;
                const crc = link.crc8(&buf);
                if (crc == 0xC0 or crc == 0xDB) wire_len += 1;
                try std.testing.expectEqual(@as(u32, 8), wire_len);
                try std.testing.expectEqual(n, p[0] & 0x3F);
                try std.testing.expectEqualSlices(u8, &ins, p[1..4]);
                try std.testing.expectEqual(@as(u8, @intCast(c)), p[4]);
            }
        }
    }
    // The chord never reaches the wire.
    try std.testing.expectEqual(@as(u8, 0x3F), net.sanitize(0xFF));
    try std.testing.expectEqual(@as(u8, 0x41), net.sanitize(0x41));
}

test "wire formats: rules, picks" {
    const r = net.Rules{ .mode = .gc, .track = 5, .crews = 2 };
    try std.testing.expect(std.meta.eql(r, net.Rules.decode(r.encode())));
    const r0 = net.Rules{};
    try std.testing.expect(std.meta.eql(r0, net.Rules.decode(r0.encode())));
    // M6: LINK BATTLE's five bytes, every LIVES and TIME row.
    for (tuning.battle_lives_opts) |l| for (tuning.battle_minutes_opts) |m| {
        const rb = net.Rules{ .mode = .battle, .track = 0, .crews = 0, .lives = l, .minutes = m };
        try std.testing.expect(std.meta.eql(rb, net.Rules.decode(rb.encode())));
    };
    // Bytes off the rows decode to the defaults; an unknown mode is a race.
    const junk = net.Rules.decode(.{ 9, 1, 200, 4, 7 });
    try std.testing.expectEqual(world.Mode.race, junk.mode);
    try std.testing.expectEqual(@as(u8, 3), junk.lives);
    try std.testing.expectEqual(@as(u8, 3), junk.minutes);
    try std.testing.expectEqual(@as(u8, 7), junk.crews);
    // The M5.1 byte still round-trips race and GC rules.
    try std.testing.expect(std.meta.eql(r, net.Rules.decode_v0(r.encode_v0())));
    const p = net.Pick{ .racer = 4, .ready = true };
    try std.testing.expect(std.meta.eql(p, net.Pick.decode(p.encode())));
    try std.testing.expectEqual(net.no_racer, net.Pick.decode((net.Pick{}).encode()).racer);
}

test "the world hash sees every field and ignores nothing" {
    var w: World = undefined;
    sim.reset(&w, .{ .seed = 9, .humans = .{ racers.snouty, racers.kiddie } });
    const h = net.world_hash(&w);
    var v = w;
    try std.testing.expectEqual(h, net.world_hash(&v));
    v.cars[5].captcha_done ^= 1;
    try std.testing.expect(net.world_hash(&v) != h);
    v = w;
    v.hazards[3].leg = 1;
    try std.testing.expect(net.world_hash(&v) != h);
    v = w;
    v.gc.survivor = 2;
    try std.testing.expect(net.world_hash(&v) != h);
}

test "lobby: the higher nonce hosts, on both cable kinds; another cart is told apart" {
    var seed: u32 = 1;
    while (seed <= 24) : (seed += 1) {
        var d: Duo = undefined;
        d.init(.{ .seed = seed, .kind = if (seed % 2 == 0) .straight else .crossed, .auto_lobby = false });
        try d.run(10_000_000, {}, done_lobby);
        const a = &d.b[0].net;
        const b = &d.b[1].net;
        try std.testing.expect(a.ls.role != .none and b.ls.role != .none and a.ls.role != b.ls.role);
        const host_side: usize = if (a.ls.role == .host) 0 else 1;
        try std.testing.expect(d.b[host_side].net.ls.link.nonce > d.b[host_side ^ 1].net.ls.link.nonce);
        try std.testing.expect(a.local_slot() != b.local_slot());
    }
    var d: Duo = undefined;
    d.init(.{ .seed = 3, .app1 = 'B', .auto_lobby = false });
    const Wc = struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].net.state() == .wrong_cart;
        }
    };
    try d.run(10_000_000, {}, Wc.f);
    // The simulator's null link: offline, never anything else.
    var o = net.Net(link.Link(link.NullPort)).init(link.Link(link.NullPort).init(.{}, net.app_id, 1));
    o.pump(1000);
    try std.testing.expectEqual(net.State.offline, o.state());
}

test "lobby: rules reach the guest, a racer clash blocks GO, GO under heavy loss" {
    var d: Duo = undefined;
    d.init(.{ .seed = 77, .auto_lobby = false, .loss_ppm = 50_000 });
    try d.run(20_000_000, {}, done_lobby);
    const hs: usize = if (d.b[0].net.ls.role == .host) 0 else 1;
    const h = &d.b[hs].net;
    const g = &d.b[hs ^ 1].net;
    const rules = net.Rules{ .mode = .gc, .track = 0, .crews = 2 };
    h.set_rules(rules);
    h.set_pick(racers.legacy, true);
    g.set_pick(racers.legacy, true);
    const Seen = struct {
        fn f(dd: *Duo, s: usize) bool {
            const gg = &dd.b[s ^ 1].net;
            const hh = &dd.b[s].net;
            return gg.rules() != null and gg.rules().?.mode == .gc and gg.peer_racer() == racers.legacy and hh.peer_racer() == racers.legacy;
        }
    };
    try d.run(5_000_000, hs, Seen.f);
    try std.testing.expect(std.meta.eql(rules, g.rules().?));
    try std.testing.expect(!h.can_go());
    try std.testing.expect(!h.go(d.now));
    g.set_pick(racers.botnet, true);
    const Can = struct {
        fn f(dd: *Duo, s: usize) bool {
            return dd.b[s].net.can_go();
        }
    };
    try d.run(5_000_000, hs, Can.f);
    try std.testing.expect(h.go(d.now));
    try d.run(20_000_000, {}, done_started);
    try std.testing.expectEqual(@as(u8, 1), g.race().id);
    try std.testing.expect(std.meta.eql(h.world_setup(), g.world_setup()));
    try std.testing.expectEqual(world.Mode.gc, g.world_setup().mode);
    try std.testing.expectEqual([2]u8{ racers.legacy, racers.botnet }, g.world_setup().humans);
    try std.testing.expectEqual(racers.botnet, g.local_car());
    try std.testing.expectEqual(racers.legacy, h.local_car());
    // And it runs in sync through the loss.
    try d.run(60_000_000, @as(u32, 600), done_tick);
    _ = try expect_logs_equal(&d);
}

test "10 seeded link races stay in sync every tick and finish" {
    var tally: Tally = .{};
    var seed: u32 = 1;
    while (seed <= 10) : (seed += 1) {
        try synced_race(.{
            .seed = seed,
            .kind = if (seed % 2 == 0) .straight else .crossed,
            .picks = picks_for(seed),
            .loop_until = if (seed % 3 == 0) 14_000 else 0,
        }, &tally);
    }
    tally.print("lockstep, clean cable");
}

test "10 seeded link races with 1% byte loss stay in sync and finish" {
    var tally: Tally = .{};
    var seed: u32 = 101;
    while (seed <= 110) : (seed += 1) {
        try synced_race(.{
            .seed = seed,
            .kind = if (seed % 2 == 0) .straight else .crossed,
            .picks = picks_for(seed),
            .loss_ppm = 10_000,
            .loop_until = 14_000,
        }, &tally);
    }
    tally.print("lockstep, 1% byte loss");
}

test "GC mode link race in sync to its end" {
    var tally: Tally = .{};
    try synced_race(.{ .seed = 55, .picks = .{ racers.rootkit, racers.sysadmin }, .rules = .{ .mode = .gc, .crews = 4 } }, &tally);
    tally.print("lockstep, GARBAGE COLLECTION");
}

test "CREWS 2 and 0: the cars left off the grid stay off, in sync to the end" {
    var tally: Tally = .{};
    try synced_race(.{ .seed = 61, .picks = .{ racers.legacy, racers.kiddie }, .rules = .{ .track = 3, .crews = 2 } }, &tally);
    try synced_race(.{ .seed = 62, .kind = .straight, .picks = .{ racers.botnet, racers.snouty }, .rules = .{ .crews = 0 } }, &tally);
    try synced_race(.{ .seed = 63, .picks = .{ racers.sysadmin, racers.rootkit }, .rules = .{ .mode = .gc, .track = 1, .crews = 2 } }, &tally);
    tally.print("lockstep, CREWS 2 / 0 / GC with 2");
}

test "unplugging mid-race: both sides hand the other car to the AI and finish" {
    var d: Duo = undefined;
    d.init(.{ .seed = 31, .picks = .{ racers.snouty, racers.legacy } });
    try d.run(20_000_000, {}, done_started);
    try d.run(60_000_000, @as(u32, 1500), done_tick);
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
        try std.testing.expectEqual(net.Left.unplugged, b.net.ls.left);
        const other: u8 = b.net.race().racers[b.net.local_slot() ^ 1];
        try std.testing.expectEqual(@as(?u8, other), b.net.handed_over());
        try std.testing.expectEqual(world.no_human, b.w.cars[other].human);
        try std.testing.expectEqual(@as(u8, b.net.local_slot()), b.w.cars[b.net.local_car()].human);
        try std.testing.expect(b.w.cars[b.net.local_car()].finished);
    }
}

test "a World changed on one badge is a desync on both within 64 ticks" {
    var worst: u32 = 0;
    for ([_]u32{ 600, 777, 1000, 1231 }, 0..) |at, k| {
        var d: Duo = undefined;
        d.init(.{ .seed = 40 + @as(u32, @intCast(k)), .loss_ppm = if (k == 3) 10_000 else 0 });
        d.b[k % 2].mutate_at = at;
        try d.run(20_000_000, {}, done_started);
        d.run(120_000_000, {}, struct {
            fn f(dd: *Duo, _: void) bool {
                return dd.both(.desync);
            }
        }.f) catch |e| {
            for (&d.b) |*b| std.debug.print("side {d}: state {t} tick {d} local_hi {d} remote_hi {d} desync_tick {d} w.phase {t}\n", .{ b.side, b.net.state(), b.net.ls.tick, b.net.ls.local_hi, b.net.ls.remote_hi, b.net.ls.desync_tick, b.w.phase });
            return e;
        };
        for (&d.b) |*b| {
            const late = b.net.ls.desync_tick - at;
            worst = @max(worst, late);
            try std.testing.expect(b.net.ls.desync_tick > at and late <= 64);
            // step stops on desync.
            const t = b.net.ls.tick;
            try std.testing.expect(!b.net.step(&b.w));
            try std.testing.expectEqual(t, b.net.ls.tick);
        }
    }
    if (report) std.debug.print("\ndesync: found on both badges at most {d} ticks after the change\n", .{worst});
}

test "Start pauses both badges on the same tick, the other's Start resumes" {
    var d: Duo = undefined;
    d.init(.{ .seed = 12 });
    try d.run(20_000_000, {}, done_started);
    try d.run(60_000_000, @as(u32, 400), done_tick);
    d.b[0].press_start_at = d.b[0].frames + 1;
    const On = struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].pause_on != null and dd.b[1].pause_on != null and dd.b[0].net.ls.tick > dd.b[0].pause_on.? + 60 and dd.b[1].net.ls.tick > dd.b[1].pause_on.? + 60;
        }
    };
    try d.run(10_000_000, {}, On.f);
    try std.testing.expectEqual(d.b[0].pause_on.?, d.b[1].pause_on.?);
    // Frozen: the race clock stands while the lockstep runs on.
    const wt = d.b[0].w.tick;
    d.run_for(1_000_000);
    try std.testing.expectEqual(wt, d.b[0].w.tick);
    try std.testing.expect(d.b[0].net.ls.paused and d.b[1].net.ls.paused);
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

test "main's pause: menu presses masked, RESUME's injected Start edge resumes both on one tick" {
    var d: Duo = undefined;
    d.init(.{ .seed = 14, .loss_ppm = 2_000, .loop_until = 14_000 });
    for (&d.b) |*b| b.main_pause = true;
    try d.run(20_000_000, {}, done_started);
    try d.run(60_000_000, @as(u32, 700), done_tick);
    // Badge 1 pauses with Start held 3 frames and picks RESUME while it may
    // still hold it (the edge waits a frame).
    d.b[1].press_start_at = d.b[1].frames + 1;
    d.b[1].resume_frame = d.b[1].frames + 4;
    const Off = struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].pause_off != null and dd.b[1].pause_off != null;
        }
    };
    try d.run(10_000_000, {}, Off.f);
    try std.testing.expectEqual(d.b[0].pause_on.?, d.b[1].pause_on.?);
    try std.testing.expectEqual(d.b[0].pause_off.?, d.b[1].pause_off.?);
    try std.testing.expect(d.b[0].pause_off.? > d.b[0].pause_on.?);
    // Badge 0 pauses, then badge 1 resumes from its menu.
    d.b[0].press_start_at = d.b[0].frames + 1;
    d.b[1].resume_frame = d.b[1].frames + 40;
    d.b[0].pause_off = null;
    d.b[1].pause_off = null;
    try d.run(10_000_000, {}, Off.f);
    try std.testing.expectEqual(d.b[0].pause_off.?, d.b[1].pause_off.?);
    try d.run(400_000_000, {}, done_finished);
    try std.testing.expect(sim.worlds_equal(&d.b[0].w, &d.b[1].w));
    _ = try expect_logs_equal(&d);
}

test "RESUME under 1% byte loss: the held Start resumes both on one tick, once, every time" {
    // main.zig's pause through net.Resume, without the 14 ms waiting loop
    // (more stalls, so more dropped bytes). 24 pauses, each badge pausing
    // and each resuming in turn; RESUME is picked inside a stall, so the
    // first held Start byte is often dropped, the case where M4's one
    // frame edge was lost and the race stayed paused.
    var d: Duo = undefined;
    d.init(.{ .seed = 21, .loss_ppm = 10_000 });
    for (&d.b) |*b| b.main_pause = true;
    try d.run(20_000_000, {}, done_started);
    try d.run(60_000_000, @as(u32, 300), done_tick);
    const Count = struct {
        fn ons(dd: *Duo, n: [2]u32) bool {
            return dd.b[0].pause_ons > n[0] and dd.b[1].pause_ons > n[1];
        }
        fn offs(dd: *Duo, n: [2]u32) bool {
            return dd.b[0].pause_offs > n[0] and dd.b[1].pause_offs > n[1];
        }
    };
    const cycles = 24;
    var worst_frames: u64 = 0;
    for (0..cycles) |k| {
        const pauser = &d.b[k % 2];
        const resumer = &d.b[(k / 2) % 2];
        const ons = [2]u32{ d.b[0].pause_ons, d.b[1].pause_ons };
        const offs = [2]u32{ d.b[0].pause_offs, d.b[1].pause_offs };
        pauser.press_start_at = pauser.frames + 1;
        try d.run(5_000_000, ons, Count.ons);
        try std.testing.expectEqual(d.b[0].pause_on.?, d.b[1].pause_on.?);
        d.run_for(300_000);
        resumer.resume_on_stall = true;
        const picked_from = resumer.frames;
        try d.run(60_000_000, offs, Count.offs);
        worst_frames = @max(worst_frames, resumer.frames - picked_from);
        try std.testing.expectEqual(d.b[0].pause_off.?, d.b[1].pause_off.?);
        try std.testing.expect(d.b[0].pause_off.? > d.b[0].pause_on.?);
        // Holding never toggles twice: still running a second later, one
        // on and one off each.
        d.run_for(1_000_000);
        for (&d.b, 0..) |*b, i| {
            try std.testing.expect(!b.net.ls.paused);
            try std.testing.expectEqual(ons[i] + 1, b.pause_ons);
            try std.testing.expectEqual(offs[i] + 1, b.pause_offs);
            try std.testing.expect(!b.hold.pending);
        }
    }
    const resumes = d.b[0].resumes + d.b[1].resumes;
    const first = d.b[0].first_dropped + d.b[1].first_dropped;
    const held = d.b[0].held_dropped + d.b[1].held_dropped;
    if (report) std.debug.print("\nRESUME under 1% loss: {d} resumes, {d} with the first held Start dropped ({d} held bytes dropped), all resumed; worst {d} frames from the pick to both unpaused\n", .{ resumes, first, held, worst_frames });
    try std.testing.expectEqual(@as(u32, cycles), resumes);
    // The case M4 lost happened, and the hold carried it.
    try std.testing.expect(first >= 3);
    try d.run(400_000_000, {}, done_finished);
    try std.testing.expect(sim.worlds_equal(&d.b[0].w, &d.b[1].w));
    _ = try expect_logs_equal(&d);
}

test "net.Resume: one edge in the kept bytes, armed by a kept byte without Start" {
    const start: u8 = 0x40;
    var r: net.Resume = .{};
    // Idle: the pad goes through; a kept Start is remembered.
    try std.testing.expectEqual(start, r.byte(start));
    r.took(start, true);
    // RESUME while the last kept byte has Start: nothing until a byte
    // without Start is kept (a dropped one does not arm).
    r.request();
    try std.testing.expectEqual(@as(u8, 0), r.byte(start));
    r.took(0, false);
    try std.testing.expectEqual(@as(u8, 0), r.byte(start));
    r.took(0, true);
    // Armed: Start on every byte, dropped or kept, until paused is off.
    var kept_starts: u32 = 0;
    for (0..6) |i| {
        const b = r.byte(0);
        try std.testing.expectEqual(start, b);
        const kept = i % 3 != 0;
        if (kept) kept_starts += 1;
        r.took(b, kept);
        r.settle(true);
    }
    try std.testing.expect(kept_starts > 0);
    r.settle(false);
    try std.testing.expect(!r.pending);
    try std.testing.expectEqual(@as(u8, 0), r.byte(0));
    // Start+Select (the OS chord) is kept without either bit: no Start.
    r.took(0xC0, true);
    try std.testing.expect(!r.last_start);
    // Paused already off when RESUME is picked: the next settle ends it
    // before any byte goes out.
    r.request();
    r.settle(false);
    try std.testing.expectEqual(@as(u8, 0), r.byte(0));
}

test "quit mid-race: the other badge races on with the AI, then a rematch" {
    var d: Duo = undefined;
    d.init(.{ .seed = 21, .picks = .{ racers.kiddie, racers.botnet } });
    try d.run(20_000_000, {}, done_started);
    const quitter: usize = 1;
    d.b[quitter].leave_at = 1000;
    const Q = struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].net.state() == .peer_left and dd.b[1].net.state() == .lobby;
        }
    };
    try d.run(60_000_000, {}, Q.f);
    const stay = &d.b[0];
    try std.testing.expectEqual(net.Left.quit, stay.net.ls.left);
    // The stayer finishes alone (it no longer waits for anyone).
    const Fin = struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].w.phase == .finished;
        }
    };
    try d.run(400_000_000, {}, Fin.f);
    try std.testing.expectEqual(@as(?u8, racers.botnet), stay.net.handed_over());
    try std.testing.expectEqual(world.no_human, stay.w.cars[racers.botnet].human);
    // Then it leaves too and both are in the lobby: race 2 starts in sync
    // with a new seed.
    const seed1 = stay.net.race().seed;
    d.b[quitter].leave_at = 0;
    stay.racing = false;
    stay.net.leave(d.now);
    d.b[0].racing = false;
    d.b[1].racing = false;
    try d.run(20_000_000, {}, done_started);
    try std.testing.expectEqual(@as(u8, 2), d.b[0].net.race().id);
    try std.testing.expectEqual(@as(u8, 2), d.b[1].net.race().id);
    try std.testing.expect(d.b[0].net.race().seed != seed1);
    try d.run(60_000_000, @as(u32, 900), done_tick);
    _ = try expect_logs_equal(&d);
}

test "Net over the badge's link compiles" {
    std.testing.refAllDecls(net.Net(link.Badge));
}

test "pump cost: port calls and packets per pump, idle and racing" {
    var d: Duo = undefined;
    d.init(.{ .seed = 5, .auto_lobby = false });
    try d.run(10_000_000, {}, done_lobby);
    // Idle lobby: 2 s.
    const g0 = d.wire.gets;
    const p0 = d.b[0].net.ls.stats.pumps + d.b[1].net.ls.stats.pumps;
    const c0 = d.b[0].net.ls.stats.control_recv + d.b[1].net.ls.stats.control_recv;
    d.run_for(2_000_000);
    const idle_pumps = d.b[0].net.ls.stats.pumps + d.b[1].net.ls.stats.pumps - p0;
    const idle_gets = d.wire.gets - g0;
    const idle_msgs = d.b[0].net.ls.stats.control_recv + d.b[1].net.ls.stats.control_recv - c0;
    // Racing: 30 s.
    d.opts.auto_lobby = true;
    try d.run(20_000_000, {}, done_started);
    const g1 = d.wire.gets;
    const puts1 = d.wire.puts;
    const p1 = d.b[0].net.ls.stats.pumps + d.b[1].net.ls.stats.pumps;
    const r1 = d.b[0].net.ls.stats.inputs_recv + d.b[1].net.ls.stats.inputs_recv;
    try d.run(60_000_000, @as(u32, 1800), done_tick);
    const race_pumps = d.b[0].net.ls.stats.pumps + d.b[1].net.ls.stats.pumps - p1;
    const race_gets = d.wire.gets - g1;
    const race_puts = d.wire.puts - puts1;
    const race_pkts = d.b[0].net.ls.stats.inputs_recv + d.b[1].net.ls.stats.inputs_recv - r1;
    if (report) std.debug.print(
        "\npump cost: lobby {d} pumps, {d} uart_get calls ({d} per pump), {d} control messages; race {d} pumps, {d} uart_get ({d}.{d:0>2} per pump), {d} uart_put, {d} input packets in ({d} per 100 pumps)\n",
        .{ idle_pumps, idle_gets, idle_gets / @max(idle_pumps, 1), idle_msgs, race_pumps, race_gets, race_gets / @max(race_pumps, 1), (race_gets * 100 / @max(race_pumps, 1)) % 100, race_puts, race_pkts, race_pkts * 100 / @max(race_pumps, 1) },
    );
    if (report) std.debug.print("@sizeOf(Net(link.Badge)) = {d} bytes, of which link.Badge {d}; @sizeOf(Net) on the virtual cable {d}\n", .{ @sizeOf(net.Net(link.Badge)), @sizeOf(link.Badge), @sizeOf(N) });
}

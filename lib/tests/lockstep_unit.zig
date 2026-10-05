//! Host tests for lib/lockstep.zig (docs/LOCKSTEP.md): two badges, each a
//! `Lockstep` and a small deterministic test World, on a
//! lib/link_virtual.zig cable, run on a shared microsecond clock with their
//! own 60 Hz frames (one a little slower, an occasional missed vsync),
//! polling the link only at the frame's pump points, with the badge's
//! 8-entry receive FIFO and optional byte loss. Ported from Snouty GC's
//! net_test.zig and run for input delays 2 and 3, one and four rules bytes,
//! and 3-bit and 7-bit picks.
const std = @import("std");
const link = @import("../link.zig");
const virtual = @import("../link_virtual.zig");
const lockstep = @import("../lockstep.zig");

/// Print per-test summaries (loss, stalls, detection latency).
const report = true;

// ---- the cable with faults --------------------------------------------------

/// Faults on top of the virtual cable: random byte loss, and the badge's
/// 8-entry receive FIFO (a byte arriving while 8 are unread is lost). The
/// virtual cable delivers a packet instantly, so the FIFO model is
/// pessimistic: a packet that arrives while the receiver draws waits whole
/// in the FIFO and the next one is lost. Off until both links are
/// connected (a HELLO is 10 wire bytes; on the badge the handshake polls in
/// a loop). `calls` counts every port call (the no-cable pump cost).
const Wire = struct {
    loss_ppm: u32 = 0,
    fifo: bool = false,
    rng: u32 = 0x1234_5678,
    lost: u32 = 0,
    overflow: u32 = 0,
    gets: u64 = 0,
    puts: u64 = 0,
    calls: u64 = 0,

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
        p.wire.calls += 1;
        p.inner.search(drive);
    }
    pub fn read(p: *Port, pin: link.Pin) bool {
        p.wire.calls += 1;
        return p.inner.read(pin);
    }
    pub fn probe(p: *Port, pin: link.Pin) bool {
        p.wire.calls += 1;
        return p.inner.probe(pin);
    }
    pub fn uart_start(p: *Port, tx: link.Pin) void {
        p.wire.calls += 1;
        p.inner.uart_start(tx);
    }
    pub fn uart_put(p: *Port, byte: u8) bool {
        const wi = p.wire;
        wi.calls += 1;
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
        p.wire.calls += 1;
        p.wire.gets += 1;
        return p.inner.uart_get();
    }
    pub fn take_framing_errors(p: *Port) u32 {
        p.wire.calls += 1;
        return p.inner.take_framing_errors();
    }
};

const L = link.Link(Port);

// ---- the test game ------------------------------------------------------------

const Config = struct {
    rules_len: u8,
    delay: u32,
    pick_bits: u8 = 3,
    version: u4 = 0,
    name: []const u8,
};

/// GC 1 rules byte and delay 2, Cycles 4 and 3, the crossings, and 7-bit picks.
const configs = [_]Config{
    .{ .rules_len = 1, .delay = 2, .name = "rules 1, delay 2" },
    .{ .rules_len = 1, .delay = 3, .name = "rules 1, delay 3" },
    .{ .rules_len = 4, .delay = 2, .name = "rules 4, delay 2" },
    .{ .rules_len = 4, .delay = 3, .name = "rules 4, delay 3" },
};
/// The paged SETUP for every length from 2 to 8 (GC's LINK BATTLE: 5).
const paged_configs = [_]Config{
    .{ .rules_len = 2, .delay = 2, .name = "rules 2, delay 2" },
    .{ .rules_len = 3, .delay = 3, .name = "rules 3, delay 3" },
    .{ .rules_len = 5, .delay = 2, .name = "rules 5, delay 2" },
    .{ .rules_len = 8, .delay = 3, .name = "rules 8, delay 3" },
};
const wide_configs = [_]Config{
    .{ .rules_len = 1, .delay = 2, .pick_bits = 7, .name = "rules 1, delay 2, 7-bit picks" },
    .{ .rules_len = 4, .delay = 3, .pick_bits = 7, .name = "rules 4, delay 3, 7-bit picks" },
};

const app_id = lockstep.apps.cycles;
const pause_bit: u8 = 0x40;
/// Simulated ticks of a test race (plus rules[0] & 0x3F).
const race_ticks: u32 = 2400;

/// A deterministic World of a few fields driven by both input bytes and an
/// LCG; a slot handed to the AI drives from the LCG instead.
fn Game(comptime C: Config) type {
    return struct {
        pub const rules_len = C.rules_len;
        pub const input_delay: u32 = C.delay;
        pub const pause_bit: ?u8 = 0x40;
        pub const pick_bits: u8 = C.pick_bits;
        pub const version: u4 = C.version;

        pub const World = struct {
            t: u32 = 0,
            len: u32 = race_ticks,
            rng: u32 = 1,
            pos: [2]i32 = .{ 0, 0 },
            score: [2]u32 = .{ 0, 0 },
            ai: [2]bool = .{ false, false },
            rules: [C.rules_len]u8 = @splat(0),
            picks: [2]u8 = .{ 0, 0 },
            finished: bool = false,
        };

        pub fn reset(w: *World, seed: u32, rules: [C.rules_len]u8, picks: [2]u8) void {
            w.* = .{ .rng = seed | 1, .rules = rules, .picks = picks, .len = race_ticks + (rules[0] & 0x3F) };
        }

        pub fn simulate(w: *World, in: [2]u8) void {
            if (w.finished) return;
            for (0..2) |s| {
                const b: u8 = if (w.ai[s]) @truncate(w.rng >> @intCast(8 * s + 3)) else in[s];
                const r = w.rules[s % C.rules_len];
                w.pos[s] +%= @as(i32, b & 0x0F) - 7 + @as(i32, r & 3) + w.picks[s];
                w.score[s] = w.score[s] *% 31 +% b;
            }
            w.rng = (w.rng *% 1_664_525 +% 1_013_904_223) ^ @as(u32, @bitCast(w.pos[0]));
            w.t += 1;
            if (w.t >= w.len) w.finished = true;
        }

        pub fn hash(w: *const World) u32 {
            return lockstep.hash_fields(World, w);
        }

        pub fn hand_over(w: *World, slot: u1) void {
            w.ai[slot] = true;
        }

        pub fn picks_ok(h: u8, g: u8) bool {
            return h != g;
        }

        pub fn can_pause(w: *const World) bool {
            return !w.finished;
        }
    };
}

fn Suite(comptime C: Config) type {
    return struct {
        const G = Game(C);
        const LS = lockstep.Lockstep(L, G);
        const World = G.World;
        const Rules = LS.Rules;

        const max_ticks = 8192;
        /// World hash after each lockstep tick, per side (index = tick).
        var logs: [2][max_ticks + 1]u32 = undefined;

        fn default_rules() Rules {
            var r: Rules = undefined;
            for (&r, 0..) |*x, i| x.* = @intCast(0x11 * (i + 1));
            return r;
        }

        /// Rules bytes that need SLIP escapes unless the SETUP flips them.
        fn special_rules() Rules {
            const pat = [_]u8{ 0xC0, 0xDB, 0x40, 0x5B, 0xC0, 0xC0, 0xDB, 0xDB };
            var r: Rules = undefined;
            for (&r, 0..) |*x, i| x.* = pat[i];
            return r;
        }

        const Opts = struct {
            seed: u32 = 1,
            kind: virtual.Kind = .crossed,
            loss_ppm: u32 = 0,
            rules: Rules = default_rules(),
            /// The pick each side makes (side, not role: the nonces pick the host).
            picks: [2]u8 = .{ 1, 2 },
            /// The app byte of side 1's link (another cart: not app_id).
            app1: u8 = app_id,
            /// Pump in a loop until this far into the frame (us), as carts do.
            loop_until: u64 = 0,
            /// Side 1's frame is this much longer (us) than side 0's 16 667.
            drift: u64 = 23,
            /// One frame in this many takes two vsyncs (0: never).
            slow_every: u32 = 150,
            /// Lobby on autopilot (rules, picks, ready, GO).
            auto_lobby: bool = true,
        };

        /// Pump points inside a frame (us from the frame's start): the top of
        /// update, then the band hooks of a ~3 ms draw.
        const draw_points = [_]u64{ 0, 500, 1000, 1500, 2000, 2500, 3000 };

        const Badge = struct {
            ls: LS,
            w: World = .{},
            side: u1,
            period: u64,
            frame_start: u64,
            point: u8 = 0,
            rng: u32,
            /// The World was reset from the agreed setup.
            racing: bool = false,
            frames: u64 = 0,
            /// Frames in a row where step ran nothing, and the longest run.
            wait_run: u32 = 0,
            wait_max: u32 = 0,
            wait_frames: u32 = 0,
            /// Longest wait at the race start.
            start_max: u32 = 0,
            /// Lockstep ticks at which `paused` turned on / off.
            pause_on: ?u32 = null,
            pause_off: ?u32 = null,
            /// Hold the pause bit on frames [press_at, press_at + 3) (0: never).
            press_start_at: u64 = 0,
            /// `paused` when the press began: the press is held until it
            /// flips (a frame's byte is dropped while step is stalled, so a
            /// short press can be lost, as on the badge).
            press_paused: ?bool = null,
            /// Leave the race once the lockstep tick reaches this (0: never).
            leave_at: u32 = 0,
            /// Mutate the World once the lockstep tick reaches this (0: never).
            mutate_at: u32 = 0,
            /// This frame's tick has run (or there is nothing to run).
            stepped: bool = true,
            held: u8 = 0,

            fn done(b: *const Badge) bool {
                return b.w.finished;
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

            /// A human: buttons held a few frames at a time, never the pause
            /// bit unless asked, sometimes Select (bit 7).
            fn script_byte(b: *Badge) u8 {
                const r = b.rand();
                if (r % 7 == 0) b.held = @as(u8, @truncate(r >> 8)) & 0xBF;
                var byte = b.held;
                if (b.press_start_at != 0 and b.frames >= b.press_start_at) {
                    const was = b.press_paused orelse b.ls.paused;
                    b.press_paused = was;
                    if (b.ls.paused == was and b.frames < b.press_start_at + 600) {
                        byte |= pause_bit;
                    } else {
                        b.press_start_at = 0;
                        b.press_paused = null;
                    }
                }
                return byte;
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
                    const app: u8 = if (side == 1) opts.app1 else app_id;
                    const seed = if (side == 0) opts.seed *% 2_654_435_761 +% 1 else opts.seed *% 40_503 +% 7;
                    const l = L.init(.{ .inner = d.cable.port(side), .wire = &d.wire }, app, seed);
                    d.b[i] = .{
                        .ls = LS.init(l),
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
                        if (report) for (&d.b) |*b| std.debug.print("timeout ({s}): side {d} role {t} state {t} tick {d} local_hi {d} remote_hi {d} peer_need {d} peer_top {d} racing {} paused {} pause_on {?d} off {?d} frames {d} wait_run {d} w.t {d} remote_ahead {any}\n", .{ C.name, b.side, b.ls.role, b.ls.state(), b.ls.tick, b.ls.local_hi, b.ls.remote_hi, b.ls.peer_need, b.ls.peer_top, b.racing, b.ls.paused, b.pause_on, b.pause_off, b.frames, b.wait_run, b.w.t, b.ls.remote_ahead });
                        return error.Timeout;
                    }
                    const i: usize = if (d.b[0].next_time() <= d.b[1].next_time()) 0 else 1;
                    const b = &d.b[i];
                    d.now = b.next_time();
                    d.wire.fifo = d.b[0].ls.link.connected() and d.b[1].ls.link.connected();
                    if (b.point == 0) d.frame(b) else {
                        // Band hooks and the loop to 14 ms: pump only while
                        // busy, retry a stalled step.
                        if (b.point < draw_points.len or b.ls.busy()) b.ls.pump(d.now);
                        if (!b.stepped) d.try_step(b);
                    }
                    b.point += 1;
                    if (b.point >= points) {
                        // The race start (the GO round trip, the first
                        // windows: the first 4 * delay ticks) is counted
                        // apart from the stalls of a running race.
                        if (b.racing and !b.stepped and !b.done()) {
                            b.wait_run += 1;
                            if (b.ls.tick < 4 * C.delay) {
                                b.start_max = @max(b.start_max, b.wait_run);
                            } else {
                                b.wait_frames += 1;
                                b.wait_max = @max(b.wait_max, b.wait_run);
                            }
                        } else b.wait_run = 0;
                        b.point = 0;
                        var len = b.period;
                        if (d.opts.slow_every != 0 and b.rand() % d.opts.slow_every == 0) len *= 2;
                        b.frame_start += len;
                        b.frames += 1;
                    }
                }
            }

            /// The top of one badge's update().
            fn frame(d: *Duo, b: *Badge) void {
                const n = &b.ls;
                n.pump(d.now);
                if (d.opts.auto_lobby and n.state() == .lobby) {
                    n.set_rules(d.opts.rules);
                    n.set_pick(d.opts.picks[b.side], true);
                    if (n.role == .host and n.can_go()) _ = n.go(d.now);
                }
                if (n.take_started()) {
                    G.reset(&b.w, n.seed(), n.rules().?, n.picks());
                    b.racing = true;
                    logs[b.side][0] = G.hash(&b.w);
                }
                if (b.racing and n.busy()) {
                    if (b.leave_at != 0 and n.tick >= b.leave_at) {
                        n.leave(d.now);
                        b.racing = false;
                        n.pump(d.now);
                        return;
                    }
                    n.submit(d.now, b.script_byte());
                    b.stepped = false;
                    d.try_step(b);
                } else b.stepped = true;
                n.pump(d.now);
            }

            /// One lockstep tick at most per frame; none once the World is over.
            fn try_step(_: *Duo, b: *Badge) void {
                const n = &b.ls;
                if (!b.racing or b.done()) return;
                const was_paused = n.paused;
                if (!n.step(&b.w)) return;
                b.stepped = true;
                if (n.paused and !was_paused) b.pause_on = n.tick - 1;
                if (!n.paused and was_paused) b.pause_off = n.tick - 1;
                if (n.tick <= max_ticks) logs[b.side][n.tick] = G.hash(&b.w);
                if (b.mutate_at != 0 and n.tick == b.mutate_at) b.w.pos[0] +%= 1;
            }

            fn both(d: *Duo, s: lockstep.State) bool {
                return d.b[0].ls.state() == s and d.b[1].ls.state() == s;
            }

            fn host_side(d: *const Duo) usize {
                return if (d.b[0].ls.role == .host) 0 else 1;
            }
        };

        fn done_lobby(d: *Duo, _: void) bool {
            return d.both(.lobby);
        }
        fn done_started(d: *Duo, _: void) bool {
            return d.b[0].racing and d.b[1].racing;
        }
        fn done_finished(d: *Duo, _: void) bool {
            return d.b[0].w.finished and d.b[1].w.finished;
        }
        fn done_tick(d: *Duo, t: u32) bool {
            return d.b[0].ls.tick >= t and d.b[1].ls.tick >= t;
        }

        /// Both badges logged the same World hash at every tick both reached.
        fn expect_logs_equal(d: *const Duo) !u32 {
            const upto = @min(@min(d.b[0].ls.tick, d.b[1].ls.tick), max_ticks);
            var t: u32 = 0;
            while (t <= upto) : (t += 1) {
                if (logs[0][t] != logs[1][t]) {
                    std.debug.print("{s}: World hashes differ at tick {d}\n", .{ C.name, t });
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
            start_max: u32 = 0,
            wait_frames: u64 = 0,
            checks: u64 = 0,
            frames: u64 = 0,

            fn add(t: *Tally, d: *const Duo) void {
                t.races += 1;
                t.ticks += d.b[0].ls.tick;
                for (&d.b) |*b| {
                    t.sent += b.ls.stats.inputs_sent;
                    t.recv += b.ls.stats.inputs_recv;
                    t.stale += b.ls.stats.inputs_stale;
                    t.old_windows += b.ls.stats.old_windows;
                    t.wait_max = @max(t.wait_max, b.wait_max);
                    t.start_max = @max(t.start_max, b.start_max);
                    t.wait_frames += b.wait_frames;
                    t.checks += b.ls.stats.checks_ok;
                    t.crc += b.ls.link.stats.crc_errors;
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
                    "\n{s} [{s}]: {d} races, {d} ticks; input packets sent {d}, received {d} ({d}.{d:0>2}% lost: {d} FIFO overflow bytes, {d} injected byte losses of {d}, {d} CRC drops); {d} stale, {d} old windows; checks ok {d}; frames without a tick {d} of {d} ({d}.{d:0>2}%), longest run {d}; race start waits at most {d} frames\n",
                    .{ name, C.name, t.races, t.ticks, t.sent, t.recv, lost_pkts * 100 / @max(t.sent, 1), (lost_pkts * 10000 / @max(t.sent, 1)) % 100, t.overflow, t.lost, t.puts, t.crc, t.stale, t.old_windows, t.checks, t.wait_frames, t.frames, t.wait_frames * 100 / @max(t.frames, 1), (t.wait_frames * 10000 / @max(t.frames, 1)) % 100, t.wait_max, t.start_max },
                );
            }
        };

        fn picks_for(seed: u32) [2]u8 {
            const m: u32 = @min(@as(u32, 1) << @intCast(C.pick_bits), 64);
            const a: u8 = @intCast(seed % m);
            const b: u8 = @intCast((a + 1 + seed % (m - 1)) % m);
            return .{ a, if (b == a) (a + 1) % @as(u8, @intCast(m)) else b };
        }

        /// One link race from cold (search, lobby, GO) to both badges
        /// finished; checks the per-tick World hashes and the final Worlds.
        fn synced_race(opts: Opts, tally: *Tally) !void {
            var d: Duo = undefined;
            d.init(opts);
            try d.run(20_000_000, {}, done_started);
            const a = &d.b[0];
            const b = &d.b[1];
            try std.testing.expectEqual(a.ls.seed(), b.ls.seed());
            try std.testing.expectEqual(a.ls.picks(), b.ls.picks());
            try std.testing.expectEqualSlices(u8, &opts.rules, &b.ls.rules().?);
            try std.testing.expectEqualSlices(u8, &opts.rules, &a.ls.rules().?);
            const hs = d.host_side();
            try std.testing.expectEqual([2]u8{ opts.picks[hs], opts.picks[hs ^ 1] }, a.ls.picks());
            try d.run(400_000_000, {}, done_finished);
            try std.testing.expectEqual(a.ls.tick, b.ls.tick);
            try std.testing.expect(std.meta.eql(a.w, b.w));
            _ = try expect_logs_equal(&d);
            try std.testing.expectEqual(lockstep.State.racing, a.ls.state());
            try std.testing.expectEqual(lockstep.State.racing, b.ls.state());
            try std.testing.expect(!a.w.ai[0] and !a.w.ai[1]);
            tally.add(&d);
        }

        // ---- scenarios ---------------------------------------------------

        fn clean_races() !void {
            var tally: Tally = .{};
            var seed: u32 = 1;
            while (seed <= 8) : (seed += 1) {
                try synced_race(.{
                    .seed = seed,
                    .kind = if (seed % 2 == 0) .straight else .crossed,
                    .picks = picks_for(seed),
                    .loop_until = if (seed % 3 == 0) 14_000 else 0,
                }, &tally);
            }
            tally.print("clean cable");
            // The pessimistic FIFO model loses a few packets; the lockstep
            // still rarely misses a frame.
            try std.testing.expect(tally.wait_frames * 100 < tally.frames);
            try std.testing.expect(tally.wait_max <= 4);
        }

        fn lossy_races() !void {
            var tally: Tally = .{};
            var seed: u32 = 101;
            while (seed <= 108) : (seed += 1) {
                try synced_race(.{
                    .seed = seed,
                    .kind = if (seed % 2 == 0) .straight else .crossed,
                    .picks = picks_for(seed),
                    .loss_ppm = 10_000,
                    .loop_until = 14_000,
                }, &tally);
            }
            tally.print("1% byte loss");
            // Stalls bounded: under 5% of frames, never 20 in a row.
            try std.testing.expect(tally.wait_frames * 20 < tally.frames);
            try std.testing.expect(tally.wait_max < 20);
        }

        fn unplug() !u64 {
            var d: Duo = undefined;
            d.init(.{ .seed = 31, .loop_until = 14_000 });
            try d.run(20_000_000, {}, done_started);
            try d.run(60_000_000, @as(u32, 900), done_tick);
            _ = try expect_logs_equal(&d);
            d.cable.plugged = false;
            const t0 = d.now;
            try d.run(5_000_000, {}, struct {
                fn f(dd: *Duo, _: void) bool {
                    return dd.both(.peer_left);
                }
            }.f);
            const ms = (d.now - t0) / 1000;
            try std.testing.expect(ms <= 60);
            try d.run(400_000_000, {}, done_finished);
            for (&d.b) |*b| {
                try std.testing.expectEqual(lockstep.Left.unplugged, b.ls.left);
                try std.testing.expect(b.ls.handed_over);
                const me = b.ls.local_slot();
                try std.testing.expect(b.w.ai[me ^ 1] and !b.w.ai[me]);
                try std.testing.expect(b.ls.busy());
            }
            return ms;
        }

        fn desync() !u32 {
            var worst: u32 = 0;
            for ([_]u32{ 600, 777, 1000, 1231 }, 0..) |at, k| {
                var d: Duo = undefined;
                d.init(.{ .seed = 40 + @as(u32, @intCast(k)), .loss_ppm = if (k == 3) 10_000 else 0 });
                d.b[k % 2].mutate_at = at;
                try d.run(20_000_000, {}, done_started);
                try d.run(120_000_000, {}, struct {
                    fn f(dd: *Duo, _: void) bool {
                        return dd.both(.desync);
                    }
                }.f);
                for (&d.b) |*b| {
                    const late = b.ls.desync_tick - at;
                    worst = @max(worst, late);
                    try std.testing.expect(b.ls.desync_tick > at and late <= 64);
                    try std.testing.expect(!b.ls.busy());
                    // step stops on desync.
                    const t = b.ls.tick;
                    try std.testing.expect(!b.ls.step(&b.w));
                    try std.testing.expectEqual(t, b.ls.tick);
                    // leave goes back to the lobby.
                    b.ls.leave(d.now);
                    try std.testing.expectEqual(lockstep.State.lobby, b.ls.state());
                }
            }
            return worst;
        }

        fn pause(loss_ppm: u32) !void {
            var d: Duo = undefined;
            d.init(.{ .seed = 12, .loss_ppm = loss_ppm, .loop_until = 14_000 });
            try d.run(20_000_000, {}, done_started);
            try d.run(60_000_000, @as(u32, 400), done_tick);
            d.b[0].press_start_at = d.b[0].frames + 1;
            try d.run(10_000_000, {}, struct {
                fn f(dd: *Duo, _: void) bool {
                    return dd.b[0].pause_on != null and dd.b[1].pause_on != null and dd.b[0].ls.tick > dd.b[0].pause_on.? + 60 and dd.b[1].ls.tick > dd.b[1].pause_on.? + 60;
                }
            }.f);
            try std.testing.expectEqual(d.b[0].pause_on.?, d.b[1].pause_on.?);
            // Frozen: the World stands while the lockstep runs on.
            const wt = d.b[0].w.t;
            const lt = d.b[0].ls.tick;
            d.run_for(1_000_000);
            try std.testing.expectEqual(wt, d.b[0].w.t);
            try std.testing.expect(d.b[0].ls.tick > lt + 30);
            try std.testing.expect(d.b[0].ls.paused and d.b[1].ls.paused);
            d.b[1].press_start_at = d.b[1].frames + 1;
            try d.run(10_000_000, {}, struct {
                fn f(dd: *Duo, _: void) bool {
                    return dd.b[0].pause_off != null and dd.b[1].pause_off != null;
                }
            }.f);
            try std.testing.expectEqual(d.b[0].pause_off.?, d.b[1].pause_off.?);
            try d.run(400_000_000, {}, done_finished);
            try std.testing.expect(std.meta.eql(d.b[0].w, d.b[1].w));
            _ = try expect_logs_equal(&d);
        }

        fn quit_and_rematch() !void {
            var d: Duo = undefined;
            d.init(.{ .seed = 21, .picks = .{ 3, 1 } });
            try d.run(20_000_000, {}, done_started);
            const quitter: usize = 1;
            d.b[quitter].leave_at = 1000;
            try d.run(60_000_000, {}, struct {
                fn f(dd: *Duo, _: void) bool {
                    return dd.b[0].ls.state() == .peer_left and dd.b[1].ls.state() == .lobby;
                }
            }.f);
            const stay = &d.b[0];
            try std.testing.expectEqual(lockstep.Left.quit, stay.ls.left);
            // The stayer finishes alone (it no longer waits for anyone).
            try d.run(400_000_000, {}, struct {
                fn f(dd: *Duo, _: void) bool {
                    return dd.b[0].w.finished;
                }
            }.f);
            try std.testing.expect(stay.ls.handed_over);
            try std.testing.expect(stay.w.ai[stay.ls.local_slot() ^ 1]);
            // Then it leaves too and both are in the lobby: race 2 starts in
            // sync with a new seed.
            const seed1 = stay.ls.seed();
            d.b[quitter].leave_at = 0;
            stay.ls.leave(d.now);
            d.b[0].racing = false;
            d.b[1].racing = false;
            try d.run(20_000_000, {}, done_started);
            try std.testing.expectEqual(@as(u8, 2), d.b[0].ls.race.id);
            try std.testing.expectEqual(@as(u8, 2), d.b[1].ls.race.id);
            try std.testing.expect(d.b[0].ls.seed() != seed1);
            try std.testing.expectEqual(d.b[0].ls.seed(), d.b[1].ls.seed());
            try d.run(60_000_000, @as(u32, 900), done_tick);
            _ = try expect_logs_equal(&d);
        }

        fn lobby_roles() !void {
            var seed: u32 = 1;
            while (seed <= 24) : (seed += 1) {
                var d: Duo = undefined;
                d.init(.{ .seed = seed, .kind = if (seed % 2 == 0) .straight else .crossed, .auto_lobby = false });
                try d.run(10_000_000, {}, done_lobby);
                const a = &d.b[0].ls;
                const b = &d.b[1].ls;
                try std.testing.expect(a.role != .none and b.role != .none and a.role != b.role);
                const hs = d.host_side();
                try std.testing.expect(d.b[hs].ls.link.nonce > d.b[hs ^ 1].ls.link.nonce);
                try std.testing.expect(a.local_slot() != b.local_slot());
                try std.testing.expect(!a.busy() and !b.busy());
            }
        }

        fn wrong_cart() !void {
            var d: Duo = undefined;
            d.init(.{ .seed = 3, .app1 = lockstep.apps.boy, .auto_lobby = false });
            try d.run(10_000_000, {}, struct {
                fn f(dd: *Duo, _: void) bool {
                    return dd.both(.wrong_cart);
                }
            }.f);
            try std.testing.expectEqualStrings("SNOUTY BOY", d.b[0].ls.partner_name());
            try std.testing.expectEqualStrings("SNOUTY CYCLES", d.b[1].ls.partner_name());
            // It stays told apart: no lobby, no role.
            d.run_for(2_000_000);
            try std.testing.expect(d.both(.wrong_cart));
            try std.testing.expectEqual(lockstep.Role.none, d.b[0].ls.role);
        }

        /// Rules reach the guest (SLIP bytes included); a pick clash blocks
        /// GO; rules changed in the same frame as GO still reach the guest
        /// (GC's GO carries them; the digest GO alternates with SETUP).
        fn lobby_rules_clash(loss_ppm: u32) !void {
            var d: Duo = undefined;
            d.init(.{ .seed = 77, .auto_lobby = false, .loss_ppm = loss_ppm, .loop_until = 14_000 });
            try d.run(20_000_000, {}, done_lobby);
            const hs = d.host_side();
            const h = &d.b[hs].ls;
            const g = &d.b[hs ^ 1].ls;
            const r1 = special_rules();
            h.set_rules(r1);
            h.set_pick(5, true);
            g.set_pick(5, true);
            const Seen = struct {
                fn f(dd: *Duo, s: usize) bool {
                    const gg = &dd.b[s ^ 1].ls;
                    const hh = &dd.b[s].ls;
                    const r = gg.rules() orelse return false;
                    return std.mem.eql(u8, &r, &special_rules()) and gg.peer_pick() == 5 and hh.peer_pick() == 5 and hh.peer_ready();
                }
            };
            try d.run(10_000_000, hs, Seen.f);
            try std.testing.expect(!h.can_go());
            try std.testing.expect(!h.go(d.now));
            d.run_for(500_000);
            try std.testing.expect(!h.can_go());
            g.set_pick(6, true);
            try d.run(10_000_000, hs, struct {
                fn f(dd: *Duo, s: usize) bool {
                    return dd.b[s].ls.can_go();
                }
            }.f);
            // New rules and GO in one frame: the guest has not heard them.
            var r2 = default_rules();
            r2[C.rules_len - 1] = 0xDB;
            h.set_rules(r2);
            try std.testing.expect(h.go(d.now));
            try d.run(30_000_000, hs, struct {
                fn f(dd: *Duo, s: usize) bool {
                    return dd.b[s].ls.busy() and dd.b[s ^ 1].ls.busy() and dd.b[s].ls.peer_started;
                }
            }.f);
            try std.testing.expectEqual(@as(u8, 1), g.race.id);
            try std.testing.expectEqualSlices(u8, &r2, &g.rules().?);
            try std.testing.expectEqualSlices(u8, &r2, &h.rules().?);
            try std.testing.expectEqual([2]u8{ 5, 6 }, g.picks());
            try std.testing.expectEqual(h.picks(), g.picks());
            try std.testing.expectEqual(h.seed(), g.seed());
            try std.testing.expectEqual(@as(u1, 1), g.local_slot());
            if (report and loss_ppm > 0) std.debug.print("\nGO through {d}% byte loss [{s}]: {d} GO resends\n", .{ loss_ppm / 10_000, C.name, h.stats.go_resends });
        }

        /// Every paged SETUP and digest GO is at most 8 wire bytes and
        /// decodes back; no control message is 5 bytes.
        fn wire_lengths() !void {
            var dummy: Duo = undefined;
            dummy.init(.{});
            var ls = dummy.b[0].ls;
            var r: u32 = 0xACE1;
            var worst_setup: u32 = 0;
            var worst_go: u32 = 0;
            var k: u32 = 0;
            while (k < 20_000) : (k += 1) {
                for (&ls.offer) |*x| {
                    r ^= r << 13;
                    r ^= r >> 17;
                    r ^= r << 5;
                    // Bias toward the SLIP bytes.
                    x.* = switch (r % 5) {
                        0 => 0xC0,
                        1 => 0xDB,
                        else => @truncate(r >> 8),
                    };
                }
                ls.race_id = @truncate(r >> 3);
                if (!LS.gc_wire and lockstep.slip_special(ls.race_id)) ls.race_id +%= 1;
                var page: u8 = 0;
                while (page < LS.pages) : (page += 1) {
                    const m = ls.setup_msg(page);
                    try std.testing.expect(m.len != lockstep.input_len);
                    worst_setup = @max(worst_setup, wire_len(&m));
                }
                ls.race = .{ .id = @truncate(r >> 11), .rules = ls.offer, .picks = .{ @as(u8, @truncate(r >> 17)) & LS_pick_mask, @as(u8, @truncate(r >> 24)) & LS_pick_mask } };
                if (!LS.gc_wire and lockstep.slip_special(ls.race.id)) ls.race.id +%= 1;
                const g = ls.go_msg();
                worst_go = @max(worst_go, wire_len(&g));
            }
            if (report) std.debug.print("\nwire [{s}]: SETUP at most {d} wire bytes, GO at most {d}\n", .{ C.name, worst_setup, worst_go });
            if (!LS.gc_wire) try std.testing.expect(worst_go <= 8);
            if (C.rules_len > 1) try std.testing.expect(worst_setup <= 8);
        }

        const LS_pick_mask: u8 = (@as(u8, 1) << @intCast(C.pick_bits)) - 1;

        fn wire_len(payload: []const u8) u32 {
            var buf: [1 + link.max_payload]u8 = undefined;
            buf[0] = @backingInt(link.Kind.data);
            @memcpy(buf[1 .. 1 + payload.len], payload);
            var n: u32 = 1; // END
            for (buf[0 .. 1 + payload.len]) |byte| n += if (lockstep.slip_special(byte)) 2 else 1;
            n += if (lockstep.slip_special(link.crc8(buf[0 .. 1 + payload.len]))) 2 else 1;
            return n;
        }

        /// With no cable a pump is one link.poll: the same port calls as a
        /// bare link polled at the same times, nothing sent, never busy.
        fn no_cable_pump() !void {
            var cable_a: virtual.Cable = .{ .kind = .crossed, .plugged = false };
            var cable_b: virtual.Cable = .{ .kind = .crossed, .plugged = false };
            var wire_a: Wire = .{};
            var wire_b: Wire = .{};
            var bare = L.init(.{ .inner = cable_a.port(0), .wire = &wire_a }, app_id, 99);
            var ls = LS.init(L.init(.{ .inner = cable_b.port(0), .wire = &wire_b }, app_id, 99));
            var now: u64 = 1_000_000;
            var k: u32 = 0;
            while (k < 20_000) : (k += 1) {
                now += 250 + (k % 7) * 100;
                bare.poll(now);
                ls.pump(now);
                try std.testing.expectEqual(wire_a.calls, wire_b.calls);
                try std.testing.expectEqual(bare.mode, ls.link.mode);
                try std.testing.expectEqual(lockstep.State.searching, ls.state());
                try std.testing.expect(!ls.busy());
            }
            try std.testing.expectEqual(@as(u64, 0), wire_b.puts);
            try std.testing.expectEqual(@as(u32, 0), ls.stats.control_sent + ls.stats.inputs_sent);
            if (report) std.debug.print("\nno cable [{s}]: {d} pumps, {d} port calls, as many as the bare link's\n", .{ C.name, k, wire_b.calls });
        }
    };
}

// ---- tests ---------------------------------------------------------------------

test "lockstep: wire helpers match lib/link.zig; input packets are always 8 wire bytes" {
    try std.testing.expectEqual(link.crc8("123456789"), lockstep.crc8("123456789"));
    try std.testing.expectEqual(@backingInt(link.Kind.data), lockstep.data_kind);
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
                    x.* = lockstep.sanitize(@truncate(r));
                }
                const p = lockstep.encode_input(n + 64 * (r % 50), ins, @intCast(c));
                try std.testing.expectEqual(@as(u32, 8), Suite(configs[0]).wire_len(&p));
                try std.testing.expectEqual(n, p[0] & 0x3F);
                try std.testing.expectEqualSlices(u8, &ins, p[1..4]);
                try std.testing.expectEqual(@as(u8, @intCast(c)), p[4]);
            }
        }
    }
    try std.testing.expectEqual(@as(u8, 0x3F), lockstep.sanitize(0xFF));
    try std.testing.expectEqual(@as(u8, 0x41), lockstep.sanitize(0x41));
    try std.testing.expectEqual(@as(u8, 0x80), lockstep.sanitize(0x80));
}

test "lockstep: hash_fields sees every field" {
    const T = struct { a: u8 = 1, b: [3]u16 = .{ 1, 2, 3 }, c: bool = false, d: enum(u8) { x, y } = .x, e: packed struct { p: u3 = 1, q: u5 = 2 } = .{} };
    const v: T = .{};
    const h = lockstep.hash_fields(T, &v);
    var w = v;
    try std.testing.expectEqual(h, lockstep.hash_fields(T, &w));
    w.b[2] = 4;
    try std.testing.expect(lockstep.hash_fields(T, &w) != h);
    w = v;
    w.e.q = 3;
    try std.testing.expect(lockstep.hash_fields(T, &w) != h);
    w = v;
    w.c = true;
    try std.testing.expect(lockstep.hash_fields(T, &w) != h);
}

test "lockstep: app names" {
    try std.testing.expectEqualStrings("SNOUTY GC", lockstep.app_name('G'));
    try std.testing.expectEqualStrings("SNOUTY LINK", lockstep.app_name('L'));
    try std.testing.expectEqualStrings("SNOUTENSTEIN", lockstep.app_name('S'));
    try std.testing.expectEqualStrings("SNOUTY ZERO", lockstep.app_name('Z'));
    try std.testing.expectEqualStrings("ANOTHER CART", lockstep.app_name(0));
}

test "lockstep: control messages fit the FIFO, decode back" {
    inline for (configs ++ paged_configs ++ wide_configs) |C| try Suite(C).wire_lengths();
}

test "lockstep: clean cable races stay in sync every tick and finish" {
    inline for (configs ++ paged_configs[2..3] ++ wide_configs[1..]) |C| try Suite(C).clean_races();
}

test "lockstep: 1% byte loss races stay in sync, stalls bounded" {
    inline for (configs) |C| try Suite(C).lossy_races();
}

test "lockstep: unplug mid-race: peer_left on both, the AI takes the slot" {
    inline for (configs) |C| {
        const ms = try Suite(C).unplug();
        if (report) std.debug.print("\nunplug [{s}]: both peer_left after {d} ms\n", .{ C.name, ms });
    }
}

test "lockstep: a World changed on one badge is a desync on both within 64 ticks" {
    inline for (configs) |C| {
        const worst = try Suite(C).desync();
        if (report) std.debug.print("\ndesync [{s}]: found on both badges at most {d} ticks after the change\n", .{ C.name, worst });
    }
}

test "lockstep: pause and resume on the same tick on both badges" {
    inline for (configs, 0..) |C, i| try Suite(C).pause(if (i % 2 == 1) 2_000 else 0);
}

test "lockstep: quit, the partner goes on with the AI, then a rematch with a new seed" {
    inline for (configs) |C| try Suite(C).quit_and_rematch();
}

test "lockstep: lobby roles over many seeds and both cable kinds" {
    inline for (configs[0..1] ++ configs[3..4]) |C| try Suite(C).lobby_roles();
}

test "lockstep: a wrong cart is told apart" {
    try Suite(configs[0]).wrong_cart();
    try Suite(configs[3]).wrong_cart();
}

test "lockstep: rules reach the guest, a picks_ok clash blocks GO" {
    inline for (configs ++ paged_configs ++ wide_configs) |C| try Suite(C).lobby_rules_clash(0);
}

test "lockstep: GO through 5% byte loss" {
    inline for (configs ++ paged_configs ++ wide_configs) |C| try Suite(C).lobby_rules_clash(50_000);
}

test "lockstep: no-cable pump is one link poll; offline in the simulator" {
    inline for (configs[0..1] ++ configs[3..4]) |C| try Suite(C).no_cable_pump();
    const G = Game(configs[0]);
    const O = lockstep.Lockstep(link.Link(link.NullPort), G);
    var o = O.init(link.Link(link.NullPort).init(.{}, app_id, 1));
    o.pump(1000);
    try std.testing.expectEqual(lockstep.State.offline, o.state());
    try std.testing.expect(!o.busy());
}

test "lockstep: over the badge's link it compiles; size" {
    inline for (configs) |C| {
        const B = lockstep.Lockstep(link.Badge, Game(C));
        std.testing.refAllDecls(B);
        if (report) std.debug.print("\n@sizeOf(Lockstep(link.Badge, [{s}])) = {d} bytes, of which link.Badge {d}\n", .{ C.name, @sizeOf(B), @sizeOf(link.Badge) });
    }
}

/// Two badges of one cart in different `G.version`s, frames of 16.7 ms
/// with a pump at the top and one in the draw, lobby on autopilot.
fn VersionPair(comptime A: type, comptime B: type) type {
    return struct {
        cable: virtual.Cable = .{ .kind = .crossed },
        wire: Wire = .{},
        a: A = undefined,
        b: B = undefined,

        fn init(p: *@This()) void {
            p.a = A.init(L.init(.{ .inner = p.cable.port(0), .wire = &p.wire }, app_id, 1234));
            p.b = B.init(L.init(.{ .inner = p.cable.port(1), .wire = &p.wire }, app_id, 98765));
        }

        fn lobby(ls: anytype, now: u64, pick: u8) void {
            ls.pump(now);
            if (ls.state() == .lobby) {
                ls.set_pick(pick, true);
                if (ls.role == .host and ls.can_go()) _ = ls.go(now);
            }
            _ = ls.take_started();
        }

        fn run(p: *@This(), us: u64) void {
            var now: u64 = 1_000_000;
            while (now < 1_000_000 + us) : (now += 16_667) {
                lobby(&p.a, now, 1);
                lobby(&p.b, now + 7_000, 2);
                p.a.pump(now + 2_000);
                p.b.pump(now + 9_000);
            }
        }
    };
}

test "lockstep: versions: v0 and v1 of one cart never race, both say wrong_version" {
    const V0 = lockstep.Lockstep(L, Game(configs[0]));
    const V1 = lockstep.Lockstep(L, Game(.{ .rules_len = 1, .delay = 2, .version = 1, .name = "v1" }));
    // The same version on both: the lobby starts a race.
    {
        var p: VersionPair(V1, V1) = .{};
        p.init();
        p.run(3_000_000);
        try std.testing.expect(p.a.busy() and p.b.busy());
        try std.testing.expectEqual(@as(u8, 0x11), p.a.link.partner_version);
    }
    // v0 against v1, both ways round (either may host).
    inline for (.{ .{ V0, V1 }, .{ V1, V0 } }) |pair| {
        var p: VersionPair(pair[0], pair[1]) = .{};
        p.init();
        p.run(5_000_000);
        try std.testing.expect(p.a.link.connected() and p.b.link.connected());
        try std.testing.expectEqual(lockstep.State.wrong_version, p.a.state());
        try std.testing.expectEqual(lockstep.State.wrong_version, p.b.state());
        try std.testing.expect(!p.a.busy() and !p.b.busy());
        try std.testing.expectEqual(@as(u32, 0), p.a.stats.control_sent + p.b.stats.control_sent);
        try std.testing.expectEqual(lockstep.Role.none, p.a.role);
    }
    // v0's HELLO version byte is exactly the link's protocol_version (GC M4).
    {
        var p: VersionPair(V0, V0) = .{};
        p.init();
        p.run(2_000_000);
        try std.testing.expectEqual(link.protocol_version, p.a.link.partner_version);
        try std.testing.expectEqual(link.protocol_version, p.b.link.partner_version);
    }
}

test "lockstep: a v1 badge sends nothing to an older one that ignores versions" {
    // The older badge: a bare v0 link on the same cart id that would hear
    // every DATA packet (GC M4 checks no version, it would wait in its lobby
    // for a PICK or GO that never comes).
    const V1 = lockstep.Lockstep(L, Game(.{ .rules_len = 1, .delay = 2, .version = 1, .name = "v1" }));
    var cable: virtual.Cable = .{ .kind = .straight };
    var wire: Wire = .{};
    var old = L.init(.{ .inner = cable.port(0), .wire = &wire }, app_id, 4321);
    var new = V1.init(L.init(.{ .inner = cable.port(1), .wire = &wire }, app_id, 777));
    var heard: u32 = 0;
    var now: u64 = 1_000_000;
    while (now < 6_000_000) : (now += 1_000) {
        old.poll(now);
        if (old.connected()) _ = old.send(now, &.{ @backingInt(lockstep.Msg.pick), 0, 0x81 });
        while (old.recv()) |_| heard += 1;
        new.pump(now + 300);
    }
    try std.testing.expect(old.connected());
    try std.testing.expectEqual(@as(u8, 0x11), old.partner_version);
    try std.testing.expectEqual(lockstep.State.wrong_version, new.state());
    try std.testing.expectEqual(@as(u32, 0), heard);
    try std.testing.expect(new.peer_pick() == null);
}

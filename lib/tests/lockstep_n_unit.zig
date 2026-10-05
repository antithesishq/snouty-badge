//! Host tests for lib/lockstep_n.zig (docs/LOCKSTEP_N.md): up to 17
//! badges, each a `LockstepN` over a lib/cart_serial.zig virtual port and
//! a small deterministic test World, joined by lib/party_virtual.zig's
//! model of `badge lobby` (per-port latency and jitter, the receive ring,
//! back-pressure, stalls, unplugs, the per-player queue limit). Each badge
//! has its own 60 Hz frame (a little slower per badge, an occasional
//! missed vsync) and pumps at the frame's top and at points through a
//! 14 ms frame, as a cart does.
const std = @import("std");
const cart_serial = @import("../cart_serial.zig");
const party = @import("../party.zig");
const pv = @import("../party_virtual.zig");
const lockstep_n = @import("../lockstep_n.zig");

/// Print per-test summaries (stalls, bytes per tick, drops).
const report = true;

const VPort = cart_serial.Virtual(.{});

const Config = struct {
    name: []const u8,
    rules_len: u8 = 2,
    delay: u32 = 3,
    pause: bool = false,
    send_every: u32 = 1,
};

/// A World of a few fields per slot driven by every present human's byte
/// (all 8 bits) and an LCG; a slot handed to the AI drives from the LCG.
fn Game(comptime C: Config) type {
    return struct {
        pub const rules_len = C.rules_len;
        pub const input_delay: u32 = C.delay;
        pub const pause_bit: ?u8 = if (C.pause) 0x40 else null;
        pub const send_every: u32 = C.send_every;

        pub const World = struct {
            t: u32 = 0,
            rng: u32 = 1,
            pos: [16]i32 = @splat(0),
            score: [16]u32 = @splat(0),
            /// Slots handed to the AI, and the World tick when it happened.
            bot: u16 = 0,
            handed_at: [16]u32 = @splat(0),
            mask: u16 = 0,
            present_trail: u32 = 0,
            rules: [C.rules_len]u8 = @splat(0),
            picks: [16]u8 = @splat(0),
        };

        pub fn reset(w: *World, seed: u32, rules: [C.rules_len]u8, picks: [16]u8, mask: u16) void {
            w.* = .{ .rng = seed | 1, .rules = rules, .picks = picks, .mask = mask };
        }

        pub fn simulate(w: *World, in: *const [16]u8, present: u16) void {
            for (0..16) |s| {
                const b = @as(u16, 1) << @intCast(s);
                if (w.mask & b == 0) continue;
                const x: u8 = if (present & b != 0) in[s] else if (w.bot & b != 0) @truncate(w.rng >> @intCast(s % 24)) else 0;
                w.pos[s] +%= @as(i32, x) - 127 + w.rules[s % C.rules_len] + w.picks[s];
                w.score[s] = w.score[s] *% 31 +% x;
            }
            w.present_trail = w.present_trail *% 3 +% present;
            w.rng = (w.rng *% 1_664_525 +% 1_013_904_223) ^ @as(u32, @bitCast(w.pos[0]));
            w.t += 1;
        }

        pub fn hash(w: *const World) u32 {
            var h: u32 = 0x811C_9DC5;
            const f = struct {
                fn feed(hh: *u32, x: u32) void {
                    hh.* = std.math.rotl(u32, hh.* ^ x, 5) *% 0x9E37_79B1;
                }
            }.feed;
            f(&h, w.t);
            f(&h, w.rng);
            for (w.pos) |p| f(&h, @bitCast(p));
            for (w.score) |p| f(&h, p);
            f(&h, w.bot);
            for (w.handed_at) |p| f(&h, p);
            f(&h, w.present_trail);
            return h;
        }

        pub fn hand_over(w: *World, slot: u4) void {
            w.bot |= @as(u16, 1) << slot;
            w.handed_at[slot] = w.t;
        }
    };
}

const max_b = 17;
const max_ticks = 10_000;

fn Suite(comptime C: Config) type {
    return struct {
        const G = Game(C);
        const LS = lockstep_n.LockstepN(VPort, G);
        const World = G.World;

        var logs: [max_b][max_ticks + 1]u32 = undefined;
        var group: Group = undefined;

        const rules: LS.Rules = blk: {
            var r: LS.Rules = undefined;
            for (&r, 0..) |*x, i| x.* = @intCast(0x11 * (i + 1) & 0xFF);
            break :blk r;
        };

        /// Pump points (us into the frame): the top of update, then the
        /// loop to 14 ms.
        const points = [_]u64{ 0, 2000, 4000, 6000, 8000, 10000, 12000, 14000 };

        const At = struct { mask: u32, t: u32 };
        const InState = struct { mask: u32, s: lockstep_n.State };

        const Badge = struct {
            ls: LS,
            w: World = .{},
            idx: usize,
            attached: bool = false,
            period: u64,
            frame_start: u64,
            point: u8 = 0,
            rng: u32,
            racing: bool = false,
            stepped: bool = true,
            frozen: bool = false,
            auto_ready: bool = true,
            leave_at: u32 = 0,
            mutate_at: u32 = 0,
            press_at: u64 = 0,
            press_paused: ?bool = null,
            pause_on: ?u32 = null,
            pause_off: ?u32 = null,
            frames: u64 = 0,
            held: u8 = 0,
            races: u32 = 0,
            wait_run: u32 = 0,
            wait_max: u32 = 0,
            wait_frames: u32 = 0,
            race_frames: u32 = 0,

            fn rand(b: *Badge) u32 {
                var x = b.rng;
                x ^= x << 13;
                x ^= x >> 17;
                x ^= x << 5;
                b.rng = x;
                return x;
            }

            fn next_time(b: *const Badge) u64 {
                return b.frame_start + points[b.point];
            }

            /// A human: all 8 bits, held a few frames at a time; the pause
            /// bit only when asked (pause configs).
            fn script_byte(b: *Badge) u8 {
                const r = b.rand();
                if (r % 7 == 0) b.held = @truncate(r >> 8);
                var byte = b.held;
                if (C.pause) {
                    byte &= ~@as(u8, 0x40);
                    if (b.press_at != 0 and b.frames >= b.press_at) {
                        const was = b.press_paused orelse b.ls.paused;
                        b.press_paused = was;
                        if (b.ls.paused == was) byte |= 0x40 else {
                            b.press_at = 0;
                            b.press_paused = null;
                        }
                    }
                }
                return byte;
            }
        };

        const Group = struct {
            relay: pv.Relay,
            b: [max_b]Badge,
            n: usize,
            now: u64,
            /// The host starts a race once this many players are ready.
            go_count: u8,
            latency_us: u32,
            jitter_us: u32,

            fn init(g: *Group, n: usize, seed: u32, latency_us: u32, jitter_us: u32) void {
                g.relay.init(seed);
                g.n = n;
                g.now = 1_000_000;
                g.go_count = 0xFF;
                g.latency_us = latency_us;
                g.jitter_us = jitter_us;
                for (0..max_b) |i| {
                    const s: u32 = seed *% 2_654_435_761 +% @as(u32, @intCast(i)) *% 40_503 +% 1;
                    var nm: [12]u8 = @splat(0);
                    _ = std.fmt.bufPrint(&nm, "P{d}", .{i}) catch unreachable;
                    g.b[i] = .{
                        .ls = LS.init(.{}, .{ .game = lockstep_n.games.snoutenstein, .name = nm }, s),
                        .idx = i,
                        .period = 16_667 + 3 * @as(u64, @intCast(i)),
                        .frame_start = g.now + @as(u64, @intCast(i)) * 997,
                        .rng = s | 1,
                    };
                }
                // Attach in order, a frame apart, so ids follow indices.
                for (0..n) |i| {
                    g.attach(i);
                    g.run_for(20_000 + 2 * @as(u64, latency_us + jitter_us));
                }
                g.go_count = @intCast(n);
            }

            fn attach(g: *Group, i: usize) void {
                const b = &g.b[i];
                b.attached = true;
                b.frame_start = @max(b.frame_start, g.now);
                g.relay.attach(i, pv.Endpoint.of(VPort, &b.ls.client.port), g.latency_us, g.jitter_us);
            }

            fn freeze(g: *Group, i: usize, on: bool) void {
                const b = &g.b[i];
                b.frozen = on;
                if (!on) {
                    b.frame_start = g.now;
                    b.point = 0;
                }
            }

            fn run_for(g: *Group, us: u64) void {
                const F = struct {
                    fn f(gg: *Group, end: u64) bool {
                        return gg.now >= end;
                    }
                };
                g.run(us + 1_000_000, g.now + us, F.f) catch unreachable;
            }

            /// Run events in time order until `done` or `limit_us`.
            fn run(g: *Group, limit_us: u64, ctx: anytype, comptime done: fn (*Group, @TypeOf(ctx)) bool) !void {
                const end = g.now + limit_us;
                while (!done(g, ctx)) {
                    if (g.now > end) {
                        if (report) for (g.b[0..max_b]) |*b| if (b.attached) std.debug.print("timeout ({s}): badge {d} slot {d} state {t} tick {d} local_hi {d} sent_hi {d} humans {b} cut_set {b} pending {b} racing {} frozen {}\n", .{ C.name, b.idx, b.ls.local_slot(), b.ls.state(), b.ls.tick, b.ls.local_hi, b.ls.sent_hi, b.ls.humans, b.ls.cut_set, b.ls.drop_pending, b.racing, b.frozen });
                        return error.Timeout;
                    }
                    var best: ?usize = null;
                    for (g.b[0..max_b], 0..) |*b, i| {
                        if (!b.attached or b.frozen) continue;
                        if (best == null or b.next_time() < g.b[best.?].next_time()) best = i;
                    }
                    const b = &g.b[best orelse return error.NoBadges];
                    g.now = @max(g.now, b.next_time());
                    g.relay.advance(g.now);
                    if (b.point == 0) g.frame(b) else {
                        if (b.ls.wants_pump()) b.ls.pump(g.now);
                        if (!b.stepped) try_step(b);
                    }
                    b.point += 1;
                    if (b.point == points.len) {
                        if (b.racing and b.ls.busy()) {
                            b.race_frames += 1;
                            if (!b.stepped) {
                                b.wait_run += 1;
                                b.wait_frames += 1;
                                b.wait_max = @max(b.wait_max, b.wait_run);
                            } else b.wait_run = 0;
                        }
                        b.point = 0;
                        var len = b.period;
                        if (b.rand() % 150 == 0) len *= 2;
                        b.frame_start += len;
                        b.frames += 1;
                    }
                }
            }

            fn frame(g: *Group, b: *Badge) void {
                const n = &b.ls;
                n.pump(g.now);
                if (n.state() == .lobby and b.auto_ready) {
                    n.set_rules(rules);
                    n.set_pick(@intCast(b.idx & 0x7F), true);
                    if (n.is_host() and @popCount(n.ready_mask()) >= g.go_count) _ = n.go(g.now);
                }
                if (n.take_started()) {
                    G.reset(&b.w, n.seed(), n.rules().?, n.picks(), n.participants());
                    b.racing = true;
                    b.races += 1;
                    b.pause_on = null;
                    b.pause_off = null;
                    logs[b.idx][0] = G.hash(&b.w);
                }
                if (b.racing and n.busy()) {
                    if (b.leave_at != 0 and n.tick >= b.leave_at) {
                        b.leave_at = 0;
                        n.leave(g.now);
                        b.racing = false;
                        b.auto_ready = false;
                        return;
                    }
                    n.submit(g.now, b.script_byte());
                    b.stepped = false;
                    try_step(b);
                } else b.stepped = true;
                n.pump(g.now);
            }

            fn try_step(b: *Badge) void {
                const n = &b.ls;
                if (!b.racing or n.tick >= max_ticks) return;
                const was = n.paused;
                if (!n.step(&b.w)) return;
                b.stepped = true;
                if (n.paused and !was) b.pause_on = n.tick - 1;
                if (!n.paused and was) b.pause_off = n.tick - 1;
                logs[b.idx][n.tick] = G.hash(&b.w);
                if (b.mutate_at != 0 and n.tick == b.mutate_at) b.w.pos[0] +%= 1;
            }

            /// Every racing badge of `mask` (indices) at tick `t` or more.
            fn at_tick(g: *Group, a: At) bool {
                for (g.b[0..max_b], 0..) |*b, i| {
                    if (a.mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
                    if (b.ls.tick < a.t) return false;
                }
                return true;
            }

            fn all_racing(g: *Group, mask: u32) bool {
                for (g.b[0..max_b], 0..) |*b, i| {
                    if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
                    if (!b.racing) return false;
                }
                return true;
            }

            fn all_state(g: *Group, a: InState) bool {
                for (g.b[0..max_b], 0..) |*b, i| {
                    if (a.mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
                    if (b.ls.state() != a.s) return false;
                }
                return true;
            }

            /// Every pair of `mask` logged the same World hash at every
            /// tick both reached; returns the ticks compared.
            fn expect_sync(g: *Group, mask: u32) !u32 {
                var upto: u32 = max_ticks;
                for (g.b[0..max_b], 0..) |*b, i| {
                    if (mask & (@as(u32, 1) << @intCast(i)) != 0) upto = @min(upto, b.ls.tick);
                }
                var first: ?usize = null;
                for (0..max_b) |i| {
                    if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
                    const f = first orelse {
                        first = i;
                        continue;
                    };
                    for (0..upto + 1) |t| {
                        if (logs[f][t] != logs[i][t]) {
                            std.debug.print("{s}: badges {d} and {d} differ at tick {d}\n", .{ C.name, f, i, t });
                            return error.Desync;
                        }
                    }
                }
                return upto;
            }

            fn summary(g: *Group, what: []const u8, mask: u32) void {
                if (!report) return;
                var frames: u64 = 0;
                var waits: u64 = 0;
                var wmax: u32 = 0;
                var bytes_out: u64 = 0;
                var bytes_in: u64 = 0;
                var ticks: u64 = 0;
                var backlog: u32 = 0;
                for (g.b[0..max_b], 0..) |*b, i| {
                    if (mask & (@as(u32, 1) << @intCast(i)) == 0) continue;
                    frames += b.race_frames;
                    waits += b.wait_frames;
                    wmax = @max(wmax, b.wait_max);
                    bytes_out += b.ls.client.stats.bytes_out;
                    bytes_in += b.ls.client.stats.bytes_in;
                    ticks += b.ls.tick;
                    backlog = @max(backlog, g.relay.max_backlog(i));
                }
                std.debug.print("\n{s} [{s}]: {d} badges, {d} ticks each; frames without a tick {d} of {d} ({d}.{d:0>2}%), longest run {d}; wire bytes per badge per tick out {d}.{d:0>2} in {d}.{d:0>2}; worst relay backlog {d} B\n", .{
                    what,                                    C.name,                     @popCount(mask),                          ticks / @max(@popCount(mask), 1),
                    waits,                                   frames,                     waits * 100 / @max(frames, 1),            (waits * 10000 / @max(frames, 1)) % 100,
                    wmax,                                    bytes_out / @max(ticks, 1), (bytes_out * 100 / @max(ticks, 1)) % 100, bytes_in / @max(ticks, 1),
                    (bytes_in * 100 / @max(ticks, 1)) % 100, backlog,
                });
            }
        };

        fn mask_of(n: usize) u32 {
            return (@as(u32, 1) << @intCast(n)) - 1;
        }

        fn start(g: *Group, mask: u32) !void {
            try g.run(30_000_000, mask, Group.all_racing);
        }

        // ---- scenarios -----------------------------------------------------

        /// n badges reach `ticks` in sync with jitter.
        fn synced(n: usize, ticks: u32, latency: u32, jitter: u32) !void {
            const g = &group;
            g.init(n, @intCast(n * 31 + 7), latency, jitter);
            const all = mask_of(n);
            try start(g, all);
            try std.testing.expectEqualSlices(u8, &rules, &g.b[n - 1].ls.rules().?);
            for (g.b[0..n]) |*b| {
                try std.testing.expectEqual(g.b[0].ls.seed(), b.ls.seed());
                try std.testing.expectEqual(@as(u16, @truncate(all)), b.ls.participants());
                try std.testing.expectEqual(@as(u8, @intCast(b.idx)), b.ls.picks()[b.ls.local_slot()]);
            }
            try g.run(@as(u64, ticks) * 40_000, At{ .mask = all, .t = ticks }, Group.at_tick);
            _ = try g.expect_sync(all);
            for (g.b[0..n]) |*b| {
                try std.testing.expectEqual(lockstep_n.State.racing, b.ls.state());
                try std.testing.expectEqual(@as(u16, 0), b.w.bot);
                try std.testing.expectEqual(@as(u32, 0), b.ls.stats.drops_proposed);
                try std.testing.expectEqual(@as(u32, 0), b.ls.stats.bad);
                try std.testing.expect(b.ls.stats.checks_ok >= (ticks / 32 - 2) * (n - 1));
            }
            var buf: [64]u8 = undefined;
            g.summary(std.fmt.bufPrint(&buf, "{d} badges in sync", .{n}) catch "", all);
        }

        /// The leaver's slot goes to the AI on the same tick everywhere.
        fn expect_same_handover(g: *Group, others: u32, slot: u4) !u32 {
            var at: ?u32 = null;
            for (g.b[0..max_b], 0..) |*b, i| {
                if (others & (@as(u32, 1) << @intCast(i)) == 0) continue;
                try std.testing.expect(b.w.bot & (@as(u16, 1) << slot) != 0);
                if (at) |a| try std.testing.expectEqual(a, b.w.handed_at[slot]) else at = b.w.handed_at[slot];
            }
            return at.?;
        }

        fn leave_mid_race() !void {
            const g = &group;
            g.init(6, 11, 1000, 1500);
            try start(g, mask_of(6));
            g.b[3].leave_at = 400;
            const others = mask_of(6) & ~@as(u32, 1 << 3);
            try g.run(60_000_000, At{ .mask = others, .t = 1200 }, Group.at_tick);
            const at = try expect_same_handover(g, others, 3);
            try std.testing.expect(at >= 400 and at <= 400 + 2 * C.delay + 4);
            _ = try g.expect_sync(others);
            try std.testing.expectEqual(lockstep_n.State.lobby, g.b[3].ls.state());
            if (report) std.debug.print("\nleave [{s}]: badge 3 left at its tick 400, AI from tick {d} on all\n", .{ C.name, at });
        }

        fn unplug_mid_race() !void {
            const g = &group;
            g.init(5, 12, 1000, 1500);
            try start(g, mask_of(5));
            try g.run(30_000_000, At{ .mask = 1 << 2, .t = 500 }, Group.at_tick);
            g.relay.unplug(2);
            const others = mask_of(5) & ~@as(u32, 1 << 2);
            try g.run(60_000_000, At{ .mask = others, .t = 1200 }, Group.at_tick);
            const at = try expect_same_handover(g, others, 2);
            _ = try g.expect_sync(others);
            try std.testing.expectEqual(lockstep_n.State.disconnected, g.b[2].ls.state());
            if (report) std.debug.print("\nunplug [{s}]: AI from tick {d} on all\n", .{ C.name, at });
        }

        /// `port`: the relay stops serving the badge's USB (it stays
        /// connected) instead of the cart freezing.
        fn stall_drop(frozen_idx: usize, port: bool) !void {
            const g = &group;
            g.init(5, 13, 1000, 1500);
            try start(g, mask_of(5));
            try g.run(30_000_000, At{ .mask = @as(u32, 1) << @intCast(frozen_idx), .t = 300 }, Group.at_tick);
            const t_freeze = g.now;
            if (port) g.relay.set_stalled(frozen_idx, true) else g.freeze(frozen_idx, true);
            const others = mask_of(5) & ~(@as(u32, 1) << @intCast(frozen_idx));
            try g.run(60_000_000, At{ .mask = others, .t = 900 }, Group.at_tick);
            const at = try expect_same_handover(g, others, @intCast(frozen_idx));
            _ = try g.expect_sync(others);
            var proposers: u32 = 0;
            for (g.b[0..5]) |*b| proposers += b.ls.stats.drops_proposed;
            try std.testing.expectEqual(@as(u32, 1), proposers);
            // The proposer is the lowest live slot.
            const proposer: usize = if (frozen_idx == 0) 1 else 0;
            try std.testing.expectEqual(@as(u32, 1), g.b[proposer].ls.stats.drops_proposed);
            const waited = g.now - t_freeze;
            // It wakes up: dropped, then back to the lobby.
            if (port) g.relay.set_stalled(frozen_idx, false) else g.freeze(frozen_idx, false);
            const F = struct {
                fn f(gg: *Group, i: usize) bool {
                    return gg.b[i].ls.state() == .dropped;
                }
            };
            g.b[frozen_idx].racing = false;
            try g.run(5_000_000, frozen_idx, F.f);
            g.b[frozen_idx].ls.leave(g.now);
            try std.testing.expectEqual(lockstep_n.State.lobby, g.b[frozen_idx].ls.state());
            if (report) std.debug.print("\nstall-drop [{s}]: badge {d} ({s}) stalled at tick 300, AI from tick {d} on all; the others reached tick 900 {d} ms after the stall\n", .{ C.name, frozen_idx, if (port) "its USB" else "its cart", at, waited / 1000 });
        }

        fn slow_badge() !void {
            const g = &group;
            g.init(4, 14, 1000, 1500);
            g.b[2].period = 30_000;
            try start(g, mask_of(4));
            try g.run(120_000_000, At{ .mask = mask_of(4), .t = 1500 }, Group.at_tick);
            _ = try g.expect_sync(mask_of(4));
            for (g.b[0..4]) |*b| {
                try std.testing.expectEqual(@as(u16, 0), b.w.bot);
                try std.testing.expectEqual(@as(u32, 0), b.ls.stats.drops_proposed);
            }
            g.summary("a badge with 30 ms ticks, never dropped", mask_of(4));
        }

        fn desync() !void {
            const g = &group;
            g.init(6, 15, 1000, 1500);
            try start(g, mask_of(6));
            g.b[1].mutate_at = 500;
            try g.run(30_000_000, InState{ .mask = mask_of(6), .s = .desync }, Group.all_state);
            var worst: u32 = 0;
            for (g.b[0..6]) |*b| worst = @max(worst, b.ls.desync_tick -| 500);
            try std.testing.expect(worst <= 2 * 32 + 2 * C.delay + 4);
            if (report) std.debug.print("\ndesync [{s}]: found on all 6 at most {d} ticks after the Worlds parted\n", .{ C.name, worst });
        }

        fn pause() !void {
            const g = &group;
            g.init(4, 16, 1000, 1500);
            try start(g, mask_of(4));
            try g.run(30_000_000, At{ .mask = mask_of(4), .t = 300 }, Group.at_tick);
            g.b[2].press_at = g.b[2].frames + 1;
            const On = struct {
                fn f(gg: *Group, _: void) bool {
                    for (gg.b[0..4]) |*b| if (b.pause_on == null) return false;
                    return true;
                }
            };
            try g.run(10_000_000, {}, On.f);
            g.run_for(500_000);
            g.b[0].press_at = g.b[0].frames + 1;
            const Off = struct {
                fn f(gg: *Group, _: void) bool {
                    for (gg.b[0..4]) |*b| if (b.pause_off == null) return false;
                    return true;
                }
            };
            try g.run(10_000_000, {}, Off.f);
            for (g.b[0..4]) |*b| {
                try std.testing.expectEqual(g.b[0].pause_on, b.pause_on);
                try std.testing.expectEqual(g.b[0].pause_off, b.pause_off);
            }
            try g.run(30_000_000, At{ .mask = mask_of(4), .t = g.b[0].pause_off.? + 300 }, Group.at_tick);
            _ = try g.expect_sync(mask_of(4));
            if (report) std.debug.print("\npause [{s}]: on at tick {d}, off at tick {d} on all 4\n", .{ C.name, g.b[0].pause_on.?, g.b[0].pause_off.? });
        }

        fn join_during_race() !void {
            const g = &group;
            g.init(4, 17, 1000, 1500);
            try start(g, mask_of(4));
            try g.run(30_000_000, At{ .mask = mask_of(4), .t = 200 }, Group.at_tick);
            g.attach(4);
            g.run_for(200_000);
            const late = &g.b[4].ls;
            try std.testing.expectEqual(lockstep_n.State.lobby, late.state());
            try std.testing.expect(late.match_running());
            try std.testing.expectEqual(@as(u4, 4), late.local_slot());
            for (g.b[0..4]) |*b| try std.testing.expectEqual(@as(u16, 0b1111), b.ls.participants());
            // The race ends (everyone leaves); the next one has five.
            for (g.b[0..4]) |*b| b.leave_at = 600;
            try g.run(60_000_000, InState{ .mask = mask_of(4), .s = .lobby }, Group.all_state);
            g.run_for(100_000);
            try std.testing.expect(!late.match_running());
            g.go_count = 5;
            for (g.b[0..5]) |*b| {
                b.auto_ready = true;
                b.racing = false;
            }
            try start(g, mask_of(5));
            try std.testing.expectEqual(@as(u16, 0b11111), late.participants());
            try g.run(60_000_000, At{ .mask = mask_of(5), .t = 300 }, Group.at_tick);
            _ = try g.expect_sync(mask_of(5));
            try std.testing.expectEqual(@as(u32, 1), g.b[4].races);
        }

        /// A spectator in the lobby that stops pumping: its ring fills and
        /// the relay queues for it (back-pressure), the race goes on; for
        /// long enough and the relay removes it.
        fn back_pressure() !void {
            const g = &group;
            g.init(9, 18, 1000, 1500);
            g.b[8].auto_ready = false;
            g.b[8].ls.set_pick(8, false);
            g.run_for(100_000);
            g.go_count = 8;
            try start(g, mask_of(8));
            g.run_for(100_000);
            try std.testing.expect(g.b[8].ls.match_running());
            g.freeze(8, true);
            g.run_for(3_000_000);
            // Its 4 KiB ring is full and the relay holds the rest.
            try std.testing.expectEqual(@as(u32, 0), g.b[8].ls.client.port.store.os_room());
            try std.testing.expect(g.relay.backlog(8) > 2048);
            g.freeze(8, false);
            g.run_for(200_000);
            try std.testing.expect(!g.relay.was_removed(8));
            try std.testing.expect(g.relay.backlog(8) < 512); // drained: only frames in flight
            try std.testing.expectEqual(lockstep_n.State.lobby, g.b[8].ls.state());
            try std.testing.expect(g.b[8].ls.match_running());
            const backlog_seen = g.relay.max_backlog(8);
            g.relay.set_stuck_limit(8, 16 * 1024);
            g.freeze(8, true);
            g.run_for(10_000_000);
            try std.testing.expect(g.relay.was_removed(8));
            g.freeze(8, false);
            g.run_for(100_000);
            try std.testing.expectEqual(lockstep_n.State.disconnected, g.b[8].ls.state());
            const t = g.b[0].ls.tick + 300;
            try g.run(30_000_000, At{ .mask = mask_of(8), .t = t }, Group.at_tick);
            _ = try g.expect_sync(mask_of(8));
            for (g.b[0..8]) |*b| try std.testing.expectEqual(@as(u16, 0), b.w.bot);
            if (report) std.debug.print("\nback-pressure [{s}]: a spectator not pumping for 3 s: its 4 KiB ring full and {d} B queued at the relay, kept; 10 s with the stuck limit scaled to 16 KiB: removed (more than that waited for 1 s); the race went on\n", .{ C.name, backlog_seen });
        }

        /// A racer whose cart stops reading: the relay removes it on
        /// overflow, the others see a normal leave on the same tick.
        fn deaf_racer() !void {
            const g = &group;
            g.init(16, 19, 1000, 1500);
            try start(g, mask_of(16));
            try g.run(30_000_000, At{ .mask = mask_of(16), .t = 300 }, Group.at_tick);
            g.relay.set_stuck_limit(5, 256);
            g.b[5].ls.client.port.deaf = true;
            const others = mask_of(16) & ~@as(u32, 1 << 5);
            try g.run(60_000_000, At{ .mask = others, .t = 900 }, Group.at_tick);
            try std.testing.expect(g.relay.was_removed(5));
            const at = try expect_same_handover(g, others, 5);
            _ = try g.expect_sync(others);
            var proposers: u32 = 0;
            for (g.b[0..16]) |*b| proposers += b.ls.stats.drops_proposed;
            try std.testing.expectEqual(@as(u32, 0), proposers);
            if (report) std.debug.print("\ndeaf racer [{s}]: removed by the relay, AI from tick {d} on all 15\n", .{ C.name, at });
        }

        fn network() !void {
            const g = &group;
            // 10 ms each way plus up to 75 ms of jitter each way.
            g.init(4, 20, 10_000, 75_000);
            g.go_count = 0xFF;
            g.run_for(3_000_000);
            const suggested = g.b[0].ls.suggested_delay();
            g.go_count = 4;
            for (g.b[0..4]) |*b| b.ls.set_delay(12); // whoever hosts
            try start(g, mask_of(4));
            for (g.b[0..4]) |*b| try std.testing.expectEqual(@as(u32, 12), b.ls.delay);
            try g.run(400_000_000, At{ .mask = mask_of(4), .t = 3000 }, Group.at_tick);
            _ = try g.expect_sync(mask_of(4));
            for (g.b[0..4]) |*b| try std.testing.expectEqual(@as(u32, 0), b.ls.stats.drops_proposed);
            try std.testing.expect(suggested >= 5 and suggested <= 14);
            if (report) std.debug.print("\nnetwork [{s}]: rtt to the relay up to {d} ms, suggested delay {d}; at delay 12:", .{ C.name, g.b[0].ls.rtt_us() / 1000, suggested });
            g.summary("network, delay 12", mask_of(4));
        }
    };
}

const base = Suite(.{ .name = "rules 2, delay 3" });

test "lockstep_n: 2, 4, 8 and 16 badges stay in sync for 10,000 ticks with jitter" {
    try base.synced(2, 10_000, 1000, 1500);
    try base.synced(4, 10_000, 1000, 1500);
    try base.synced(8, 10_000, 1000, 1500);
    try base.synced(16, 10_000, 1000, 1500);
}

test "lockstep_n: 8 rules bytes, delay 1, 30 Hz frames (two ticks per INPUT)" {
    try Suite(.{ .name = "rules 8, delay 3", .rules_len = 8 }).synced(4, 1500, 1000, 1500);
    try Suite(.{ .name = "rules 1, delay 1", .rules_len = 1, .delay = 1 }).synced(3, 1500, 300, 300);
    try Suite(.{ .name = "rules 2, delay 4, two ticks a frame", .delay = 4, .send_every = 2 }).synced(4, 2000, 1000, 1500);
}

test "lockstep_n: a leave mid-race lands on the same tick everywhere" {
    try base.leave_mid_race();
    try base.unplug_mid_race();
}

test "lockstep_n: a stalled badge is dropped on the same tick everywhere" {
    try base.stall_drop(4, false);
    try base.stall_drop(0, false); // the host itself
    try base.stall_drop(2, true); // the relay stops serving its port
}

test "lockstep_n: a slow badge (30 ms ticks) is never dropped" {
    try base.slow_badge();
}

test "lockstep_n: an injected hash mismatch is found on every badge" {
    try base.desync();
}

test "lockstep_n: pause on the same tick" {
    try Suite(.{ .name = "pause bit, delay 3", .pause = true }).pause();
}

test "lockstep_n: a join during a race waits for the next one" {
    try base.join_during_race();
}

test "lockstep_n: receive-ring back-pressure does not deadlock; overflow removes" {
    try base.back_pressure();
    try base.deaf_racer();
}

test "lockstep_n: network latency, delay 12 with 150 ms of jitter" {
    try Suite(.{ .name = "rules 2, network" }).network();
}

test "lockstep_n: RAM" {
    const LS = lockstep_n.LockstepN(cart_serial.Badge(.{}), Game(.{ .name = "ram", .rules_len = 2 }));
    if (report) std.debug.print("\nRAM: @sizeOf(LockstepN(cart_serial.Badge(.{{}}), G)) = {d} bytes for 16 slots (2 rules bytes); the port's static rings {d} bytes\n", .{ @sizeOf(LS), @sizeOf(cart_serial.Storage(4096, 1024)) });
    try std.testing.expect(@sizeOf(LS) < 4096);
}

//! Host tests for the party deathmatch glue (M8): badges, each a
//! `LockstepN` over `match.GN` and a `match.World` on a lib/cart_serial.zig
//! virtual port, joined by lib/party_virtual.zig's model of `badge lobby`
//! (latency and jitter each way), on a shared microsecond clock with their
//! own 60 Hz frames (a little slower per badge, an occasional missed
//! vsync), pumping at the top of the frame and on to 14 ms as party.zig
//! does. Every badge plays its own slot with bot.zig from its own World,
//! readies with its team pick, and the host goes once everyone is ready:
//! the GN contract (rules bytes, picks to teams, hand-over) end to end.
//! The lockstep itself is lib's (lib/tests/lockstep_n_unit.zig).
const std = @import("std");
const plib = @import("party_lib");
const lockstep_n = plib.lockstep_n;
const cart_serial = plib.cart_serial;
const pv = plib.party_virtual;
const state = @import("state.zig");
const levels = @import("levels.zig");
const match = @import("match.zig");
const bot = @import("bot.zig");

/// Print per-test summaries on stderr.
const report = true;

const VPort = cart_serial.Virtual(.{});
const LS = lockstep_n.LockstepN(VPort, match.GN);
const max_b = 16;
const max_ticks = 24_000;

const Badge = struct {
    ls: LS,
    w: match.World = undefined,
    idx: usize,
    attached: bool = false,
    period: u64,
    frame_start: u64,
    point: u8 = 0,
    rng: u32,
    racing: bool = false,
    stepped: bool = true,
    team_pick: u8 = 0,
    leave_at: u32 = 0,
    left: bool = false,
    race_frames: u32 = 0,
    wait_frames: u32 = 0,

    fn rand(b: *Badge) u32 {
        var x = b.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b.rng = x;
        return x;
    }
};

/// The pump points of a frame (us after its top), as party.zig's loop.
const points = [_]u64{ 0, 2000, 4000, 6000, 8000, 10000, 12000, 14000 };

var relay: pv.Relay = undefined;
var badges: [max_b]Badge = undefined;
var logs: [max_b][max_ticks + 1]u32 = undefined;
var n_badges: usize = 0;
var now: u64 = 0;
var rules: match.Rules = .{};

fn setup(n: usize, r: match.Rules, seed: u32) void {
    relay.init(seed);
    n_badges = n;
    now = 1_000_000;
    rules = r;
    for (0..n) |i| {
        const s: u32 = seed *% 2_654_435_761 +% @as(u32, @intCast(i)) *% 40_503 +% 1;
        var nm: [12]u8 = @splat(0);
        _ = std.fmt.bufPrint(&nm, "B{d}", .{i}) catch unreachable;
        badges[i] = .{
            .ls = LS.init(.{}, .{ .game = lockstep_n.games.snoutenstein, .name = nm }, s),
            .idx = i,
            .period = 16_667 + 3 * @as(u64, @intCast(i)),
            .frame_start = now + @as(u64, @intCast(i)) * 997,
            .rng = s | 1,
        };
    }
    // Attach in order, a frame apart, so ids follow indices.
    for (0..n) |i| {
        badges[i].attached = true;
        badges[i].frame_start = @max(badges[i].frame_start, now);
        relay.attach(i, pv.Endpoint.of(VPort, &badges[i].ls.client.port), 1000, 1500);
        run_until(now + 25_000, never);
    }
}

fn never() bool {
    return false;
}

fn next_time(b: *const Badge) u64 {
    return b.frame_start + points[b.point];
}

/// Run frames in time order until `done` or the clock reaches `limit`.
fn run_until(limit: u64, comptime done: fn () bool) void {
    while (now < limit and !done()) {
        var best: usize = 0;
        for (badges[0..n_badges], 0..) |*b, i| {
            if (next_time(b) < next_time(&badges[best])) best = i;
        }
        const b = &badges[best];
        now = @max(now, next_time(b));
        relay.advance(now);
        if (b.point == 0) frame(b) else if (b.ls.wants_pump()) {
            b.ls.pump(now);
            if (!b.stepped) try_step(b);
        }
        b.point += 1;
        if (b.point == points.len) {
            if (b.racing and b.ls.busy()) {
                b.race_frames += 1;
                if (!b.stepped) b.wait_frames += 1;
            }
            b.point = 0;
            var len = b.period;
            if (b.rand() % 150 == 0) len *= 2;
            b.frame_start += len;
        }
    }
}

/// The top of a frame: party.zig's lobby and match frames, the pad
/// replaced by bot.zig on this badge's slot.
fn frame(b: *Badge) void {
    const n = &b.ls;
    n.pump(now);
    if (n.state() == .lobby and !b.left) {
        if (n.is_host()) n.set_rules(rules.encode2());
        n.set_pick(b.team_pick, true);
        if (n.is_host() and @popCount(n.ready_mask()) == n_badges) _ = n.go(now);
    }
    if (n.take_started()) {
        const picks = n.picks();
        const team = match.GN.team_of(&picks);
        match.GN.start(&b.w, n.rules().?, n.participants(), &team, n.seed());
        b.racing = true;
        logs[b.idx][0] = match.GN.hash(&b.w);
    }
    if (b.racing and n.busy()) {
        if (b.leave_at != 0 and n.tick >= b.leave_at) {
            n.leave(now);
            b.racing = false;
            b.left = true;
            return;
        }
        const slot = n.local_slot();
        const in = bot.think(&b.w, &levels.all[b.w.gs.level], slot);
        n.submit(now, match.byte_of(in) & ~match.bit_start);
        b.stepped = false;
        try_step(b);
    } else b.stepped = true;
}

fn try_step(b: *Badge) void {
    const n = &b.ls;
    if (!b.racing or n.tick >= max_ticks or b.w.m.over) return;
    if (!n.step(&b.w)) return;
    b.stepped = true;
    logs[b.idx][n.tick] = match.GN.hash(&b.w);
}

fn all_racing() bool {
    for (badges[0..n_badges]) |*b| if (!b.racing) return false;
    return true;
}

fn all_over() bool {
    for (badges[0..n_badges]) |*b| {
        if (b.left) continue;
        if (!b.w.m.over and b.ls.tick < max_ticks) return false;
    }
    return true;
}

/// Every pair of racing badges logged the same World hash at every tick
/// both reached; returns the ticks compared.
fn expect_sync(mask: u32) !u32 {
    var upto: u32 = max_ticks;
    for (badges[0..n_badges], 0..) |*b, i| {
        if (mask >> @intCast(i) & 1 == 1) upto = @min(upto, b.ls.tick);
    }
    var first: ?usize = null;
    for (0..n_badges) |i| {
        if (mask >> @intCast(i) & 1 == 0) continue;
        const f = first orelse {
            first = i;
            continue;
        };
        for (0..upto + 1) |t| {
            if (logs[f][t] != logs[i][t]) {
                std.debug.print("badges {d} and {d} differ at tick {d}\n", .{ f, i, t });
                return error.Desync;
            }
        }
    }
    return upto;
}

fn summary(what: []const u8) void {
    if (!report) return;
    var frames: u64 = 0;
    var waits: u64 = 0;
    for (badges[0..n_badges]) |*b| {
        frames += b.race_frames;
        waits += b.wait_frames;
    }
    const m = &badges[0].w.m;
    var top: i16 = -100;
    for (m.frags) |f| top = @max(top, f);
    std.debug.print("\n{s}: {d} badges, {d} ticks, over {}, winner 0x{x}, top frags {d}, frames without a tick {d} of {d}\n", .{ what, n_badges, badges[0].ls.tick, m.over, m.winner, top, waits, frames });
}

const testing = std.testing;

test "party: 4 badges on Server Room with bugs play to the frag limit in sync" {
    setup(4, .{ .arena = 0, .frags = 0, .bugs = true }, 11);
    run_until(now + 5_000_000, all_racing);
    try testing.expect(all_racing());
    for (badges[0..4]) |*b| {
        try testing.expectEqual(@as(u16, 0xF), b.w.m.present);
        try testing.expectEqual(@as(u16, 0), b.w.m.bots);
        try testing.expectEqual(levels.arena_indices[0], b.w.gs.level);
        try testing.expectEqual(match.GN.input_delay, b.ls.delay);
    }
    run_until(now + 600_000_000, all_over);
    const t = try expect_sync(0xF);
    summary("4 badges, Server Room, 5 frags");
    try testing.expect(badges[0].w.m.over);
    try testing.expect(t > 600);
    for (badges[1..4]) |*b| try testing.expectEqual(badges[0].w.m.winner, b.w.m.winner);
}

test "party: 6 badges in 2 teams from their picks; teams win by team frags" {
    setup(6, .{ .arena = 2, .frags = 1, .bugs = false, .teams = 2 }, 23);
    // Badges 0-2 pick RED, 3-5 BLUE (pick = team + 1).
    for (badges[0..6], 0..) |*b, i| b.team_pick = if (i < 3) 1 else 2;
    run_until(now + 5_000_000, all_racing);
    try testing.expect(all_racing());
    for (badges[0..6]) |*b| {
        try testing.expectEqual(@as(u8, 2), b.w.m.teams);
        for (0..6) |s| try testing.expectEqual(@as(u8, if (s < 3) 0 else 1), b.w.m.team[s]);
    }
    run_until(now + 900_000_000, all_over);
    _ = try expect_sync(0x3F);
    summary("6 badges, Data Hall, 2 teams, 10 frags");
    const m = &badges[0].w.m;
    try testing.expect(m.over);
    try testing.expect(m.winner & state.team_win != 0 or m.winner == state.no_one);
    try testing.expectEqual(m.team_frags[0] + m.team_frags[1], blk: {
        var sum: i16 = 0;
        for (m.frags[0..6]) |f| sum += f;
        break :blk sum;
    });
}

test "party: a team match needs two teams to go" {
    var picks: [16]u8 = @splat(0);
    try testing.expect(match.GN.picks_ok(&picks, 0b111)); // FFA
    picks[0] = 1;
    picks[1] = 1;
    picks[2] = 1;
    try testing.expect(!match.GN.picks_ok(&picks, 0b111));
    picks[2] = 2;
    try testing.expect(match.GN.picks_ok(&picks, 0b111));
    const t = match.GN.team_of(&picks);
    try testing.expectEqual(@as(u8, 1), t[2]);
    try testing.expectEqual(@as(u8, 5), t[5]); // no pick: the slot (mod the team count at start)
}

test "party: a leaver becomes a bot on the same tick on every badge; 16 badges stay in sync" {
    setup(16, .{ .arena = 2, .frags = 4, .bugs = true }, 37);
    badges[5].leave_at = 400;
    run_until(now + 8_000_000, all_racing);
    try testing.expect(all_racing() or badges[5].left);
    const stay: u32 = 0xFFFF & ~@as(u32, 1 << 5);
    const D = struct {
        fn done() bool {
            for (badges[0..16], 0..) |*b, i| {
                if (i != 5 and b.ls.tick < 1500) return false;
            }
            return true;
        }
    };
    run_until(now + 120_000_000, D.done);
    const t = try expect_sync(stay);
    summary("16 badges, Data Hall, bugs, one leaves at 400");
    try testing.expect(t >= 1500);
    for (badges[0..16], 0..) |*b, i| {
        if (i == 5) continue;
        try testing.expectEqual(@as(u16, 1 << 5), b.w.m.bots);
        try testing.expect(!b.w.m.over);
    }
}

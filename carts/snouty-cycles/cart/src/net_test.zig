//! LINK DUEL's gate (PLAN M3 Track L item 4, `tools/check.sh link`): two
//! Games, each with its own `net.Net` and link, on lib/link_virtual.zig's
//! cable, driven frame by frame as main.zig drives them.
//!
//! The rig adds what the virtual cable leaves out: wire time (10 us a
//! byte at 1 Mbaud), a random delay per burst, random byte loss (a lost
//! byte costs its packet the CRC), and the badge's 8-byte receive FIFO
//! (a byte arriving at a full FIFO is lost: the pessimistic model, as the
//! cart only empties it at its pump points). The two badges run 60 Hz
//! frames of slightly different lengths with a missed vsync now and then,
//! a 1.5-4 ms render between the mid-frame pump and the late pumps.
//!
//! Every lockstep tick of both badges is hashed (`Game.duel_hash`) and
//! compared across them: the Games must be equal at every tick.
const std = @import("std");
const lh = @import("link_host");
const link = lh.link;
const virtual = lh.virtual;
const game = @import("game.zig");
const net = @import("net.zig");
const sim = @import("sim.zig");
const layouts = @import("layouts.zig");

const testing = std.testing;

const qlen: u32 = 2048;

/// One direction of the cable: bytes in flight with their arrival times.
const Line = struct {
    q: [qlen]Flying = undefined,
    head: u32 = 0,
    len: u32 = 0,
    /// Arrival of the last byte queued.
    last: u64 = 0,
    const Flying = struct { t: u64, b: u8 };
};

const Rig = struct {
    cable: virtual.Cable,
    /// lines[s]: the bytes side s sent.
    lines: [2]Line = .{ .{}, .{} },
    rng: u32,
    now: u64 = 1_000_000,
    /// Byte loss in 1/100000, and the most a burst is delayed (us).
    byte_loss: u32 = 0,
    max_delay: u64 = 0,
    /// Side s pumps continuously now (the late loop): its FIFO never fills.
    draining: [2]bool = .{ false, false },
    sent: u32 = 0,
    lost: u32 = 0,
    fifo_drops: u32 = 0,

    fn random(r: *Rig) u32 {
        var x = r.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        r.rng = x;
        return x;
    }

    /// Bytes whose time has come reach the far end's FIFO (8 deep).
    fn deliver(r: *Rig) void {
        for (&r.lines, 0..) |*l, s| {
            while (l.len > 0 and l.q[l.head].t <= r.now) {
                const f = l.q[l.head];
                l.head = (l.head + 1) % qlen;
                l.len -= 1;
                if (r.byte_loss != 0 and r.random() % 100_000 < r.byte_loss) {
                    r.lost += 1;
                    continue;
                }
                const far = &r.cable.ends[s ^ 1];
                if (far.uart_tx != null and far.rx_len >= 8 and !r.draining[s ^ 1]) {
                    r.fifo_drops += 1;
                    continue;
                }
                var p = r.cable.port(@intCast(s));
                _ = p.uart_put(f.b);
            }
        }
    }
};

/// lib/link.zig's Port over the virtual cable, through the rig's lines.
const TPort = struct {
    pub const available = true;
    rig: *Rig,
    side: u1,

    fn inner(p: *TPort) virtual.Port {
        return p.rig.cable.port(p.side);
    }
    pub fn search(p: *TPort, d: link.Pin) void {
        var i = p.inner();
        i.search(d);
    }
    pub fn read(p: *TPort, pin: link.Pin) bool {
        var i = p.inner();
        return i.read(pin);
    }
    pub fn probe(p: *TPort, pin: link.Pin) bool {
        var i = p.inner();
        return i.probe(pin);
    }
    pub fn uart_start(p: *TPort, tx: link.Pin) void {
        var i = p.inner();
        i.uart_start(tx);
    }
    pub fn uart_put(p: *TPort, byte: u8) bool {
        const r = p.rig;
        if (r.cable.ends[p.side].uart_tx == null) return true;
        const l = &r.lines[p.side];
        if (l.len == qlen) return true;
        // A new burst gets a random delay; bytes stay in order, 10 us apart.
        var t = l.last + 10;
        if (l.last < r.now) t = @max(t, r.now + 10 + if (r.max_delay != 0) r.random() % r.max_delay else 0);
        l.last = t;
        l.q[(l.head + l.len) % qlen] = .{ .t = t, .b = byte };
        l.len += 1;
        r.sent += 1;
        return true;
    }
    pub fn uart_get(p: *TPort) ?u8 {
        var i = p.inner();
        return i.uart_get();
    }
    pub fn take_framing_errors(_: *TPort) u32 {
        return 0;
    }
};

const L = link.Link(TPort);
const N = net.Net(L);

/// What a side's player does.
const Policy = struct {
    /// Matches to play before the host leaves to the menu instead of a
    /// rematch (both then come back to LINK DUEL, new rules).
    rematches: u32 = 2,
    /// Come back to LINK DUEL from the menu.
    reenter: bool = true,
};

const hash_ring = 1 << 16;

const Side = struct {
    g: *game.Game,
    n: N,
    rng: u32,
    period: u64,
    frame_start: u64 = 0,
    next_frame: u64,
    render_end: u64 = 0,
    stage: enum { idle, render, late } = .idle,
    next_late: u64 = 0,
    held: game.Buttons = .{},
    prev: game.Buttons = .{},
    policy: Policy = .{},
    matches: u32 = 0,
    /// Lockstep ticks hashed, for the cross check.
    hashes: *[hash_ring]u32,
    race: u8 = 0,
    last_tick: u32 = 0,
    /// Frames this side had no tick while racing (stalls).
    stall_frames: u32 = 0,
    racing_frames: u32 = 0,
    handed_over_seen: bool = false,

    fn random(s: *Side) u32 {
        var x = s.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        s.rng = x;
        return x;
    }
};

var games: [2]game.Game = undefined;
var hash_store: [2][hash_ring]u32 = undefined;

const World2 = struct {
    rig: Rig,
    sides: [2]Side,
    mismatches: u32 = 0,
    compared: u32 = 0,

    fn init(w: *World2, seed: u32, kind: virtual.Kind) void {
        w.rig = .{ .cable = .{ .kind = kind }, .rng = seed *% 2654435761 | 1 };
        for (0..2) |i| {
            games[i].init(seed +% @as(u32, @intCast(i)) *% 977);
            w.sides[i] = .{
                .g = &games[i],
                .n = N.init(L.init(.{ .rig = &w.rig, .side = @intCast(i) }, net.app_id, seed *% 40503 +% @as(u32, @intCast(i)) *% 7919 +% 1)),
                .rng = seed *% 69069 +% @as(u32, @intCast(i)) +% 12345,
                .period = if (i == 0) 16_667 else 16_690,
                .next_frame = w.rig.now + @as(u64, i) * 5_123,
                .hashes = &hash_store[i],
            };
            games[i].enter_link();
        }
        w.mismatches = 0;
        w.compared = 0;
    }

    /// Runs `us` of simulated time in 250 us steps.
    fn run(w: *World2, us: u64) void {
        const end = w.rig.now + us;
        while (w.rig.now < end) {
            w.rig.now += 250;
            w.rig.deliver();
            for (0..2) |i| w.side_step(i);
        }
    }

    fn side_step(w: *World2, i: usize) void {
        const s = &w.sides[i];
        const now = w.rig.now;
        defer w.rig.draining[i] = s.stage == .late;
        switch (s.stage) {
            .render => if (now >= s.render_end) {
                s.n.pump(now);
                w.record(i);
                s.stage = if (s.n.busy(s.g)) .late else .idle;
            },
            .late => {
                if (now -% s.frame_start >= net.pump_until_us) {
                    s.stage = .idle;
                } else {
                    s.n.retry(s.g, now);
                    w.record(i);
                }
            },
            .idle => {},
        }
        if (now >= s.next_frame) w.frame(i);
    }

    fn frame(w: *World2, i: usize) void {
        const s = &w.sides[i];
        const now = w.rig.now;
        s.frame_start = now;
        s.next_frame = now + s.period * @as(u64, if (s.random() % 150 == 0) 2 else 1);
        const g = s.g;
        if (g.duel_running()) {
            s.racing_frames += 1;
            if (!s.n.ticked) s.stall_frames += 1;
        }
        s.held = w.policy_buttons(i);
        const pressed: game.Buttons = @bitCast(@as(u8, @bitCast(s.held)) & ~@as(u8, @bitCast(s.prev)));
        s.prev = s.held;
        s.n.begin(g, now);
        g.update(s.held, pressed);
        s.n.end(g, now);
        s.n.pump(now);
        w.record(i);
        if (g.lk.ai_slot != null and g.state == .play) s.handed_over_seen = true;
        s.render_end = now + 1_500 + s.random() % 2_500;
        s.stage = .render;
    }

    /// The player: random riding in the duel, the host's random rules in
    /// the lobby, A for a rematch or B to the menu at the card.
    fn policy_buttons(w: *World2, i: usize) game.Buttons {
        const s = &w.sides[i];
        const g = s.g;
        var b: game.Buttons = .{};
        switch (g.state) {
            .title, .menu => if (s.policy.reenter and g.mode != .link) g.enter_link(),
            .link_lobby => {
                const lk = &g.lk;
                if (lk.host and lk.status == .lobby and lk.can_go and !lk.resync and s.random() % 8 == 0) {
                    lk.layout = @intCast(s.random() % layouts.count);
                    lk.opts = .from_bits(s.random() % 64);
                    if (lk.opts.speed == .slow) lk.opts.speed = .normal;
                    lk.first_to = @intCast(1 + s.random() % 3);
                    b.start = true;
                }
            },
            .countdown, .play, .round_over => {
                // Paused: hands off (any of A, B, Start resumes).
                if (g.lk.paused) return .{};
                b = s.prev;
                b.start = false;
                b.up = false;
                b.down = false;
                b.left = false;
                b.right = false;
                if (s.random() % 10 == 0) switch (s.random() % 4) {
                    0 => b.up = true,
                    1 => b.right = true,
                    2 => b.down = true,
                    else => b.left = true,
                };
                if (s.random() % 40 == 0) b.a = !b.a;
                if (s.random() % 60 == 0) b.b = !b.b;
            },
            .match_over => {
                if (g.timer < game.tuning.game_over_min_ticks) return .{};
                const leave = g.lk.host and s.matches >= s.policy.rematches;
                if (s.prev.a or s.prev.b) return .{};
                if (leave) {
                    s.matches = 0;
                    b.b = true;
                } else {
                    if (!g.lk.rematch[g.lk.slot]) s.matches += 1;
                    b.a = true;
                }
            },
            else => {},
        }
        return b;
    }

    /// Hashes each new lockstep tick and compares it with the other
    /// badge's hash of that tick in the same race.
    fn record(w: *World2, i: usize) void {
        const s = &w.sides[i];
        const ls = &s.n.ls;
        if (ls.race_id != s.race) {
            s.race = ls.race_id;
            s.last_tick = 0;
        }
        if (ls.tick == s.last_tick) return;
        s.last_tick = ls.tick;
        if (ls.state() != .racing and ls.state() != .waiting) return;
        if (ls.tick % 4 != 0) return;
        const h = s.g.duel_hash();
        s.hashes[ls.tick % hash_ring] = h;
        const o = &w.sides[i ^ 1];
        const ols = &o.n.ls;
        if (ols.race_id == ls.race_id and o.race == ls.race_id and ols.tick >= ls.tick and ols.tick - ls.tick < hash_ring - 64 and
            (ols.state() == .racing or ols.state() == .waiting))
        {
            w.compared += 1;
            if (o.hashes[ls.tick % hash_ring] != h) w.mismatches += 1;
        }
    }

    fn rounds(_: *const World2) u32 {
        return @min(games[0].lk.rounds_done, games[1].lk.rounds_done);
    }

    fn run_rounds(w: *World2, n: u32, cap_s: u64) !void {
        var t: u64 = 0;
        while (w.rounds() < n) : (t += 1) {
            if (t > cap_s) {
                std.debug.print("stuck: rounds {d}/{d}, states {s}/{s}, status {s}/{s}\n", .{
                    games[0].lk.rounds_done,      games[1].lk.rounds_done,
                    @tagName(games[0].state),     @tagName(games[1].state),
                    @tagName(games[0].lk.status), @tagName(games[1].lk.status),
                });
                return error.Stuck;
            }
            w.run(1_000_000);
        }
    }

    fn report(w: *const World2, name: []const u8) void {
        const a = &w.sides[0];
        const b = &w.sides[1];
        const pk = w.rig.sent / 8;
        std.debug.print("link gate [{s}]: {d} rounds, NO CONTEST {d}/{d}, hashes compared {d}, mismatched {d}; " ++
            "bytes {d} sent, {d} lost, {d} FIFO drops (~{d} packets); stalled frames {d}/{d} and {d}/{d}; " ++
            "inputs sent {d}/{d}, old windows {d}/{d}, sync skips {d}/{d}, checks ok {d}/{d}\n", .{
            name,                     w.rounds(),
            games[0].lk.no_contests,  games[1].lk.no_contests,
            w.compared,               w.mismatches,
            w.rig.sent,               w.rig.lost,
            w.rig.fifo_drops,         pk,
            a.stall_frames,           a.racing_frames,
            b.stall_frames,           b.racing_frames,
            a.n.ls.stats.inputs_sent, b.n.ls.stats.inputs_sent,
            a.n.ls.stats.old_windows, b.n.ls.stats.old_windows,
            a.n.ls.stats.skips,       b.n.ls.stats.skips,
            a.n.ls.stats.checks_ok,   b.n.ls.stats.checks_ok,
        });
    }
};

var rig_world: World2 = undefined;

test "LINK DUEL: 50 rounds on a clean cable, random riders and modifiers, in sync" {
    const w = &rig_world;
    w.init(3, .crossed);
    try w.run_rounds(50, 3600);
    w.report("clean");
    try testing.expectEqual(@as(u32, 0), w.mismatches);
    try testing.expect(w.compared > 1000);
    try testing.expectEqual(@as(u32, 0), games[0].lk.no_contests + games[1].lk.no_contests);
    // Host and guest, one each.
    try testing.expect(games[0].lk.host != games[1].lk.host);
}

test "LINK DUEL: 50 rounds with 5% packet loss and random delay: in sync or a clean NO CONTEST" {
    const w = &rig_world;
    w.init(11, .straight);
    // ~0.65% of bytes: about 5% of the 8-byte packets.
    w.rig.byte_loss = 650;
    w.rig.max_delay = 4_000;
    try w.run_rounds(50, 7200);
    w.report("5% loss");
    try testing.expectEqual(@as(u32, 0), w.mismatches);
    try testing.expect(w.compared > 1000);
    // A NO CONTEST is allowed (and must then be on both badges and play
    // on); none is expected.
    try testing.expectEqual(games[0].lk.no_contests, games[1].lk.no_contests);
}

/// Runs until both badges are in play past World tick `t`.
fn run_to_play(w: *World2, t: u32) !void {
    var k: u32 = 0;
    while (!(games[0].state == .play and games[1].state == .play and games[0].world.tick > t and games[1].world.tick > t)) : (k += 1) {
        if (k > 60 * 400) return error.NoPlay;
        w.run(16_000);
    }
}

test "LINK DUEL: unplugged in mid-round, a program rides the partner's cycle to the round's end, then the menu" {
    const w = &rig_world;
    w.init(21, .crossed);
    for (&w.sides) |*s| s.policy.reenter = false;
    // Calm riders: the round should outlast the unplug.
    try run_to_play(w, 30);
    w.rig.cable.plugged = false;
    var k: u32 = 0;
    while (k < 200) : (k += 1) {
        w.run(16_667);
        if (games[0].lk.ai_slot != null and games[1].lk.ai_slot != null) break;
    }
    // Both badges handed the other's cycle over (or the round ended first).
    for (0..2) |i| {
        const g = &games[i];
        try testing.expect(g.lk.ai_slot != null or g.state == .link_notice or g.state == .menu);
        if (g.lk.ai_slot) |sl| try testing.expectEqual(g.lk.slot ^ 1, sl);
    }
    try testing.expect(w.sides[0].handed_over_seen or w.sides[1].handed_over_seen);
    // The round plays out with the program, then PEER LEFT, then the menu.
    k = 0;
    while (!(games[0].state == .menu and games[1].state == .menu)) : (k += 1) {
        if (k > 400) return error.NoMenu;
        w.run(1_000_000);
    }
    try testing.expectEqual(game.LinkNotice.peer_left, games[0].lk.notice);
    try testing.expectEqual(game.LinkNotice.peer_left, games[1].lk.notice);
}

test "LINK DUEL: a World changed on one badge is NO CONTEST on both, then the match goes on in sync with a new seed" {
    const w = &rig_world;
    w.init(5, .straight);
    try run_to_play(w, 20);
    const seed0 = games[0].lk.seed;
    const race0 = w.sides[0].n.ls.race_id;
    // Corrupt one badge's World: a block in an empty cell.
    const gw = &games[0].world;
    var i: usize = 0;
    while (gw.grid[i] != sim.empty) i += 1;
    gw.grid[i] = sim.block;
    var k: u32 = 0;
    while (games[0].lk.no_contests == 0 or games[1].lk.no_contests == 0) : (k += 1) {
        if (k > 240) return error.NoDesync;
        w.run(16_667);
    }
    // Then a new race and more rounds, in sync.
    const before = w.rounds();
    w.mismatches = 0;
    w.compared = 0;
    try w.run_rounds(before + 4, 1200);
    w.report("desync");
    try testing.expectEqual(@as(u32, 1), games[0].lk.no_contests);
    try testing.expectEqual(@as(u32, 1), games[1].lk.no_contests);
    try testing.expect(w.sides[0].n.ls.race_id != race0);
    try testing.expect(games[0].lk.seed != seed0);
    try testing.expectEqual(games[0].lk.seed, games[1].lk.seed);
    try testing.expectEqual(@as(u32, 0), w.mismatches);
    try testing.expect(w.compared > 50);
}

test "LINK DUEL: Start on one badge pauses both on the same tick, Start on the other resumes both" {
    const w = &rig_world;
    w.init(9, .crossed);
    for (&w.sides) |*s| s.policy.reenter = false;
    try run_to_play(w, 60);
    // Side 0 presses Start (one frame) through its own update.
    const g0 = &games[0];
    const g1 = &games[1];
    var k: u32 = 0;
    // Wait for side 0's next frame boundary, then press.
    while (w.rig.now + 250 < w.sides[0].next_frame) w.run(250);
    w.rig.now = w.sides[0].next_frame - 250;
    // A frame of side 0 with Start held.
    {
        const s = &w.sides[0];
        const now = w.rig.now + 250;
        w.rig.now = now;
        w.rig.deliver();
        s.frame_start = now;
        s.next_frame = now + s.period;
        s.n.begin(g0, now);
        g0.update(.{ .start = true }, .{ .start = true });
        s.n.end(g0, now);
        s.prev = .{ .start = true };
        s.stage = .render;
        s.render_end = now + 2_000;
    }
    while (!(g0.lk.paused and g1.lk.paused)) : (k += 1) {
        if (k > 120) return error.NoPause;
        w.run(16_667);
    }
    const t0 = g0.world.tick;
    w.run(500_000);
    try testing.expect(g0.lk.paused and g1.lk.paused);
    try testing.expectEqual(t0, g0.world.tick);
    try testing.expectEqual(g0.world.tick, g1.world.tick);
    try testing.expectEqual(g0.duel_hash(), g1.duel_hash());
    // Side 1 resumes: B in the pause menu.
    {
        const s = &w.sides[1];
        while (w.rig.now + 250 < s.next_frame) w.run(250);
        const now = s.next_frame;
        w.rig.now = now;
        w.rig.deliver();
        s.frame_start = now;
        s.next_frame = now + s.period;
        s.n.begin(g1, now);
        g1.update(.{ .b = true }, .{ .b = true });
        s.n.end(g1, now);
        s.prev = .{ .b = true };
        s.stage = .render;
        s.render_end = now + 2_000;
    }
    k = 0;
    while (g0.lk.paused or g1.lk.paused) : (k += 1) {
        if (k > 120) return error.NoResume;
        w.run(16_667);
    }
    w.mismatches = 0;
    w.compared = 0;
    w.run(3_000_000);
    try testing.expectEqual(@as(u32, 0), w.mismatches);
    try testing.expect(w.compared > 20);
}

test "LINK DUEL: the input packet is always 8 wire bytes" {
    var r: u32 = 1;
    var k: u32 = 0;
    while (k < 20_000) : (k += 1) {
        r ^= r << 13;
        r ^= r >> 17;
        r ^= r << 5;
        const ins = [3]u8{ @truncate(r & 0x3F), @truncate((r >> 6) & 0x3F), @truncate((r >> 12) & 0x3F) };
        const p = net.lockstep.encode_input(r >> 3, ins, @truncate(r >> 24));
        var buf: [6]u8 = undefined;
        buf[0] = 0x10;
        @memcpy(buf[1..], &p);
        const crc = link.crc8(&buf);
        try testing.expect(crc != 0xC0 and crc != 0xDB);
        for (p) |b| try testing.expect(b != 0xC0 and b != 0xDB);
        try testing.expectEqual(net.lockstep.crc8(&buf), crc);
    }
}

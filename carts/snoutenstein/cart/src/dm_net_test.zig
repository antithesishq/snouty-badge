//! Host tests for the two-badge deathmatch (M7): two badges, each a
//! `lib/lockstep.zig` Lockstep over `match.G` and a `match.World`, on a
//! lib/link_virtual.zig cable, run on a shared microsecond clock with their
//! own 60 Hz frames (one a little slower, an occasional missed vsync),
//! pumping at the top of update and in the loop to 14 ms while busy (as
//! deathmatch.zig does), with the badge's 8-entry receive FIFO and optional
//! byte loss. Modelled on Snouty GC's net_test.zig and lib's
//! lockstep_unit.zig. The players are bot.zig plus random taps, each badge
//! computing its own player's input from its own World.
const std = @import("std");
const host = @import("link_host");
const link = host.link;
const virtual = host.virtual;
const lockstep = @import("lockstep");
const state = @import("state.zig");
const levels = @import("levels.zig");
const match = @import("match.zig");
const bot = @import("bot.zig");
const fixed = @import("fixed.zig");

/// Print per-test summaries (loss, stalls, detection latency) on stderr.
const report = true;

// ---- the cable with faults ------------------------------------------------------

/// Faults on top of the virtual cable: random byte loss, and the badge's
/// 8-entry receive FIFO (a byte arriving while 8 are unread is lost; the
/// cable delivers a packet instantly, so this is pessimistic). Off until
/// both links are connected (the handshake polls in a loop on the badge).
const Wire = struct {
    loss_ppm: u32 = 0,
    fifo: bool = false,
    rng: u32 = 0x1234_5678,
    lost: u32 = 0,
    overflow: u32 = 0,
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
        return p.inner.uart_get();
    }
    pub fn take_framing_errors(p: *Port) u32 {
        return p.inner.take_framing_errors();
    }
};

const L = link.Link(Port);
const LS = lockstep.Lockstep(L, match.G);
const World = match.World;

const max_ticks = 24_000;
/// World hash after each lockstep tick, per side (index = tick).
var logs: [2][max_ticks + 1]u32 = undefined;

const Opts = struct {
    seed: u32 = 1,
    kind: virtual.Kind = .crossed,
    loss_ppm: u32 = 0,
    rules: match.Rules = .{ .arena = 0, .frags = 0, .bugs = false },
    /// Pump in the loop until this far into the frame (us), as the cart does.
    loop_until: u64 = 14_000,
    /// Side 1's frame is this much longer (us) than side 0's 16 667.
    drift: u64 = 23,
    /// One frame in this many takes two vsyncs (0: never).
    slow_every: u32 = 150,
};

/// Pump points: the top of update, then (with `loop_until`) every 1 ms
/// from the end of a ~3 ms draw, while busy.
const draw_end: u64 = 3_000;

const Badge = struct {
    ls: LS,
    w: World = undefined,
    side: u1,
    period: u64,
    frame_start: u64,
    point: u8 = 0,
    rng: u32,
    racing: bool = false,
    frames: u64 = 0,
    wait_run: u32 = 0,
    wait_max: u32 = 0,
    wait_frames: u32 = 0,
    /// Lockstep ticks at which `paused` turned on / off.
    pause_on: ?u32 = null,
    pause_off: ?u32 = null,
    /// Hold Start from this frame until `paused` flips (0: never): a
    /// frame's byte is dropped while step is stalled, as on the badge.
    press_start_at: u64 = 0,
    press_paused: ?bool = null,
    /// Mutate the World once the lockstep tick reaches this (0: never).
    mutate_at: u32 = 0,
    stepped: bool = true,
    /// A random tap held for a few frames over the bot's buttons.
    tap: u8 = 0,
    tap_left: u8 = 0,

    fn rand(b: *Badge) u32 {
        var x = b.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b.rng = x;
        return x;
    }

    fn next_time(b: *const Badge) u64 {
        if (b.point == 0) return b.frame_start;
        return b.frame_start + draw_end + 1000 * @as(u64, b.point - 1);
    }

    /// This badge's player: the bot on its own World, now and then a
    /// random direction held for a few frames (so the two badges' players
    /// do not mirror the bot exactly), and Start when asked.
    fn script_byte(b: *Badge) u8 {
        const me = b.ls.local_slot();
        var byte = match.byte_of(bot.think(&b.w, &levels.all[b.w.gs.level], me));
        if (b.tap_left == 0 and b.rand() % 97 == 0) {
            b.tap = @as(u8, 1) << @intCast(b.rand() % 4);
            b.tap_left = 8;
        }
        if (b.tap_left > 0) {
            byte |= b.tap;
            b.tap_left -= 1;
        }
        byte &= ~match.bit_start;
        if (b.press_start_at != 0 and b.frames >= b.press_start_at) {
            const was = b.press_paused orelse b.ls.paused;
            b.press_paused = was;
            if (b.ls.paused == was and b.frames < b.press_start_at + 600) {
                byte |= match.bit_start;
            } else {
                b.press_start_at = 0;
                b.press_paused = null;
            }
        }
        // deathmatch.zig: while paused only Start reaches the lockstep.
        if (b.ls.paused) byte &= match.bit_start;
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
            const seed = if (side == 0) opts.seed *% 2_654_435_761 +% 1 else opts.seed *% 40_503 +% 7;
            const l = L.init(.{ .inner = d.cable.port(side), .wire = &d.wire }, lockstep.apps.snoutenstein, seed);
            d.b[i] = .{
                .ls = LS.init(l),
                .side = side,
                .period = 16_667 + if (side == 1) opts.drift else 0,
                .frame_start = d.now + @as(u64, side) * 7_000,
                .rng = seed | 1,
            };
        }
    }

    fn points(d: *const Duo) u8 {
        if (d.opts.loop_until <= draw_end) return 2;
        return @intCast(2 + (d.opts.loop_until - draw_end) / 1000);
    }

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
        const n_points = d.points();
        while (!done(d, ctx)) {
            if (d.now > end) {
                if (report) for (&d.b) |*b| std.debug.print("timeout: side {d} role {t} state {t} tick {d} racing {} paused {} frags {any} over {}\n", .{ b.side, b.ls.role, b.ls.state(), b.ls.tick, b.racing, b.ls.paused, b.w.m.frags, b.w.m.over });
                return error.Timeout;
            }
            const i: usize = if (d.b[0].next_time() <= d.b[1].next_time()) 0 else 1;
            const b = &d.b[i];
            d.now = b.next_time();
            d.wire.fifo = d.b[0].ls.link.connected() and d.b[1].ls.link.connected();
            if (b.point == 0) {
                d.frame(b);
            } else if (b.ls.busy()) {
                // deathmatch.zig: after drawing, pump until 14 ms while
                // busy, retrying a stalled step.
                b.ls.pump(d.now);
                if (!b.stepped) d.try_step(b);
            }
            b.point += 1;
            if (b.point >= n_points) {
                if (b.racing and !b.stepped and !b.w.m.over) {
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

    /// The top of one badge's update(): what deathmatch.zig does (the
    /// lobby on autopilot: the host offers the rules, both ready, GO).
    fn frame(d: *Duo, b: *Badge) void {
        const n = &b.ls;
        n.pump(d.now);
        if (n.state() == .lobby) {
            if (n.role == .host) n.set_rules(.{d.opts.rules.encode()});
            n.set_pick(0, true);
            if (n.role == .host and n.can_go()) _ = n.go(d.now);
        }
        if (n.take_started()) {
            match.init_rules(&b.w, match.Rules.decode(n.rules().?[0]), n.seed());
            b.racing = true;
            logs[b.side][0] = match.G.hash(&b.w);
        }
        if (b.racing and n.busy()) {
            n.submit(d.now, b.script_byte());
            b.stepped = false;
            d.try_step(b);
        } else b.stepped = true;
    }

    fn try_step(_: *Duo, b: *Badge) void {
        const n = &b.ls;
        if (!b.racing) return;
        const was_paused = n.paused;
        if (!n.step(&b.w)) return;
        b.stepped = true;
        if (n.paused and !was_paused) b.pause_on = n.tick - 1;
        if (!n.paused and was_paused) b.pause_off = n.tick - 1;
        if (n.tick <= max_ticks) logs[b.side][n.tick] = match.G.hash(&b.w);
        // A counter nothing rewrites (a position change is undone by a
        // respawn when player 1 happens to be in its death view: M9 bots).
        if (b.mutate_at != 0 and n.tick == b.mutate_at) b.w.m.deaths[1] +%= 1;
    }

    fn both(d: *Duo, s: lockstep.State) bool {
        return d.b[0].ls.state() == s and d.b[1].ls.state() == s;
    }
};

fn done_started(d: *Duo, _: void) bool {
    return d.b[0].racing and d.b[1].racing;
}
fn done_over(d: *Duo, _: void) bool {
    return d.b[0].w.m.over and d.b[1].w.m.over;
}
fn done_tick(d: *Duo, t: u32) bool {
    return d.b[0].ls.tick >= t and d.b[1].ls.tick >= t;
}

fn expect_logs_equal(d: *const Duo) !u32 {
    const upto = @min(@min(d.b[0].ls.tick, d.b[1].ls.tick), max_ticks);
    var t: u32 = 0;
    while (t <= upto) : (t += 1) {
        if (logs[0][t] != logs[1][t]) {
            std.debug.print("World hashes differ at tick {d}\n", .{t});
            return error.Desync;
        }
    }
    return upto;
}

fn summary(name: []const u8, d: *const Duo) void {
    if (!report) return;
    var sent: u64 = 0;
    var recv: u64 = 0;
    var crc: u64 = 0;
    var frames: u64 = 0;
    var waits: u64 = 0;
    var wait_max: u32 = 0;
    for (&d.b) |*b| {
        sent += b.ls.stats.inputs_sent;
        recv += b.ls.stats.inputs_recv;
        crc += b.ls.link.stats.crc_errors;
        frames += b.frames;
        waits += b.wait_frames;
        wait_max = @max(wait_max, b.wait_max);
    }
    const lost = sent -| recv;
    std.debug.print("\n{s}: {d} ticks, frags {d}:{d}; input packets sent {d}, received {d} ({d}.{d:0>2}% lost: {d} FIFO overflow bytes, {d} injected losses of {d} bytes, {d} CRC drops); frames without a tick {d} of {d}, longest run {d}\n", .{
        name,                       d.b[0].w.gs.tick,                     d.b[0].w.m.frags[0], d.b[0].w.m.frags[1], sent,        recv,
        lost * 100 / @max(sent, 1), (lost * 10000 / @max(sent, 1)) % 100, d.wire.overflow,     d.wire.lost,         d.wire.puts, crc,
        waits,                      frames,                               wait_max,
    });
}

/// A match from cold (search, lobby, GO) to the frag limit on both badges.
fn synced_match(opts: Opts) !Duo {
    var d: Duo = undefined;
    d.init(opts);
    try d.run(20_000_000, {}, done_started);
    try std.testing.expectEqual(d.b[0].ls.seed(), d.b[1].ls.seed());
    try std.testing.expectEqual(d.b[0].ls.rules().?, d.b[1].ls.rules().?);
    try std.testing.expect(d.b[0].ls.local_slot() != d.b[1].ls.local_slot());
    try d.run(@as(u64, max_ticks) * 17_000, {}, done_over);
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&d.b[0].w), std.mem.asBytes(&d.b[1].w)));
    _ = try expect_logs_equal(&d);
    const m = &d.b[0].w.m;
    try std.testing.expect(!m.forfeit);
    try std.testing.expect(m.frags[0] >= m.frag_limit or m.frags[1] >= m.frag_limit);
    for (&d.b) |*b| try std.testing.expectEqual(lockstep.State.racing, b.ls.state());
    return d;
}

// ---- tests ----------------------------------------------------------------------

test "deathmatch over the cable: 1% byte loss, played to the frag limit in sync" {
    const d = try synced_match(.{ .seed = 7, .loss_ppm = 10_000 });
    summary("1% byte loss, Server Room to 5", &d);
    var frames: u64 = 0;
    var waits: u64 = 0;
    for (&d.b) |*b| {
        frames += b.frames;
        waits += b.wait_frames;
        try std.testing.expect(b.wait_max < 20);
        try std.testing.expect(b.ls.stats.checks_ok > 0);
    }
    try std.testing.expect(waits * 20 < frames);
}

test "deathmatch over the cable: a clean cable, Build Farm with bugs, in sync for 3000 ticks" {
    var d: Duo = undefined;
    d.init(.{ .seed = 3, .kind = .straight, .rules = .{ .arena = 1, .frags = 3, .bugs = true } });
    try d.run(20_000_000, {}, done_started);
    try d.run(80_000_000, @as(u32, 3000), done_tick);
    _ = try expect_logs_equal(&d);
    try std.testing.expect(d.b[0].w.m.bugs);
    try std.testing.expectEqual(@as(u8, 1), d.b[1].w.m.arena);
    summary("clean cable, Build Farm DM, bugs on", &d);
}

test "deathmatch over the cable: the partner leaving is a forfeit win" {
    var d: Duo = undefined;
    d.init(.{ .seed = 31 });
    try d.run(20_000_000, {}, done_started);
    try d.run(60_000_000, @as(u32, 600), done_tick);
    _ = try expect_logs_equal(&d);
    d.cable.plugged = false;
    try d.run(5_000_000, {}, struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.both(.peer_left) and dd.b[0].w.m.over and dd.b[1].w.m.over;
        }
    }.f);
    for (&d.b) |*b| {
        const me = b.ls.local_slot();
        try std.testing.expectEqual(lockstep.Left.unplugged, b.ls.left);
        try std.testing.expect(b.w.m.forfeit);
        try std.testing.expectEqual(@as(u8, me), b.w.m.winner);
        // The finished World does not move any more.
        const h = match.hash(&b.w);
        _ = b.ls.step(&b.w);
        try std.testing.expectEqual(h, match.hash(&b.w));
    }
    // The other way: one badge quits (its pause B, `leave`): the one that
    // stays wins by forfeit.
    d.init(.{ .seed = 32 });
    try d.run(20_000_000, {}, done_started);
    try d.run(60_000_000, @as(u32, 400), done_tick);
    d.b[1].ls.leave(d.now);
    d.b[1].racing = false;
    try d.run(5_000_000, {}, struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].w.m.over;
        }
    }.f);
    try std.testing.expectEqual(lockstep.Left.quit, d.b[0].ls.left);
    try std.testing.expect(d.b[0].w.m.forfeit);
    try std.testing.expectEqual(@as(u8, d.b[0].ls.local_slot()), d.b[0].w.m.winner);
}

test "deathmatch over the cable: a World changed on one badge is a desync on both" {
    for ([_]u32{ 300, 777 }, 0..) |at, k| {
        var d: Duo = undefined;
        d.init(.{ .seed = 40 + @as(u32, @intCast(k)), .loss_ppm = if (k == 1) 10_000 else 0 });
        d.b[k].mutate_at = at;
        try d.run(20_000_000, {}, done_started);
        try d.run(60_000_000, {}, struct {
            fn f(dd: *Duo, _: void) bool {
                return dd.both(.desync);
            }
        }.f);
        for (&d.b) |*b| {
            const late = b.ls.desync_tick - at;
            if (report) std.debug.print("\ndesync injected at tick {d}: side {d} stopped {d} ticks later\n", .{ at, b.side, late });
            try std.testing.expect(b.ls.desync_tick > at and late <= 64);
            try std.testing.expect(!b.ls.step(&b.w));
            b.ls.leave(d.now);
            try std.testing.expectEqual(lockstep.State.lobby, b.ls.state());
        }
    }
}

test "deathmatch over the cable: Start pauses and resumes both badges on the same tick" {
    var d: Duo = undefined;
    d.init(.{ .seed = 12, .loss_ppm = 5_000 });
    try d.run(20_000_000, {}, done_started);
    try d.run(60_000_000, @as(u32, 400), done_tick);
    d.b[0].press_start_at = d.b[0].frames + 1;
    try d.run(10_000_000, {}, struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].pause_on != null and dd.b[1].pause_on != null and
                dd.b[0].ls.tick > dd.b[0].pause_on.? + 60 and dd.b[1].ls.tick > dd.b[1].pause_on.? + 60;
        }
    }.f);
    try std.testing.expectEqual(d.b[0].pause_on.?, d.b[1].pause_on.?);
    // Frozen: the World stands while the lockstep runs on.
    const wt = d.b[0].w.gs.tick;
    const lt = d.b[0].ls.tick;
    d.run_for(1_000_000);
    try std.testing.expectEqual(wt, d.b[0].w.gs.tick);
    try std.testing.expect(d.b[0].ls.tick > lt + 30);
    try std.testing.expect(d.b[0].ls.paused and d.b[1].ls.paused);
    // The other badge's Start resumes both.
    d.b[1].press_start_at = d.b[1].frames + 1;
    try d.run(10_000_000, {}, struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].pause_off != null and dd.b[1].pause_off != null;
        }
    }.f);
    try std.testing.expectEqual(d.b[0].pause_off.?, d.b[1].pause_off.?);
    try d.run(60_000_000, @as(u32, d.b[0].ls.tick + 600), done_tick);
    _ = try expect_logs_equal(&d);
    try std.testing.expect(d.b[0].w.gs.tick > wt + 500);
}

test "deathmatch over the cable: RAM" {
    if (report) std.debug.print("\n@sizeOf(Lockstep(link, match.G)) = {d} bytes (link {d}), match.World = {d} bytes\n", .{ @sizeOf(LS), @sizeOf(L), @sizeOf(World) });
    // M8: state.Match holds 16 players (PLAN.md M8 "How many players"),
    // World 2,188 bytes; M7's two-player Match kept it under 2,048. M9's
    // arsenal (ammo per slot, pad items, the 32-entry DmShot pool that keeps
    // GameState.projectiles unchanged) adds 752: World 2,940. M9.2's 16
    // dropped weapons add 256: World 3,196.
    try std.testing.expect(@sizeOf(World) < 3328);
}

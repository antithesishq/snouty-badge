//! The party source over the relay model (docs/MULTIPLAYER.md section 5,
//! root docs/LOCKSTEP_N.md): four badges, each its own console and a
//! `players.Session` over a `cart_serial.Virtual` port with the cart's
//! ring sizes, joined by lib/party_virtual.zig's model of `badge lobby`
//! (1 ms latency, up to 1.5 ms jitter each way). They play Mega Bomberman
//! (local ROM, skipped when absent) with its Team Player: badge 1 (the
//! host) drives tests/mp_bomberman.zig's menu script, everyone reaches the
//! 4-human battle, every badge walks its own bomber out of its corner.
//! Badge 3's updates take 60 ms (30 ms per Genesis frame) all along, so
//! everyone runs at its pace; badge 4 leaves the race mid-battle. Every
//! badge logs `state_hash` after every tick: the logs must agree, and the
//! leaver's pad goes idle on the same tick everywhere.
const std = @import("std");
const core = @import("core");
const Md = core.Md;
const players = @import("players");
const party_lib = @import("party_lib");
const pv = party_lib.party_virtual;
const bomber = @import("mp_bomberman.zig");

/// The cart's ring sizes (frontend/app.zig).
pub const VPort = party_lib.cart_serial.Virtual(.{ .rx_size = 2048, .tx_size = 512 });
pub const Sess = players.Session(VPort);

const n_badges = 4;
const leaver = 3;
/// The leaver quits here (the battle runs from `bomber.battle_frame`).
const leave_tick = bomber.battle_frame + 150;
/// Everyone else plays on to here.
const end_tick = bomber.battle_frame + 400;
const max_ticks = end_tick + 64;

/// Each player's way out of its corner (pads 1-4), from the battle on.
const moves = [4]u16{ core.Pad.right, core.Pad.up, core.Pad.down, core.Pad.right };

/// Pump points through an update (us from its start): the top, then the
/// pump loop, as the cart does.
const points = [_]u64{ 0, 4000, 8000, 12000, 16000 };

const Badge = struct {
    sess: Sess,
    md: *Md,
    period: u64,
    frame_start: u64,
    point: u8 = 0,
    attached: bool = false,
    racing: bool = false,
    left: bool = false,
    /// Ticks still to step in this update.
    owed: u32 = 0,
    log: [max_ticks + 1]u32 = undefined,
    /// The tick at which each slot first showed as handed over.
    gone_at: [16]?u32 = @splat(null),

    fn next_time(b: *const Badge) u64 {
        return b.frame_start + points[b.point];
    }

    /// This badge's byte for tick `t` (it plays pad `pad`): the menu
    /// script (pad 1 only), then its way out of the corner.
    fn byte_for(pad: usize, t: u32) u8 {
        if (t < bomber.battle_frame) return players.wire_byte(bomber.pads_at(t)[pad]);
        if (t < bomber.battle_frame + 90) return players.wire_byte(moves[pad]);
        return 0;
    }
};

const Group = struct {
    relay: pv.Relay,
    b: [n_badges]Badge,
    now: u64,
    rom_crc: u32,
    kind: core.ports.Kind,
    gone_seen: bool = false,

    fn update(g: *Group, b: *Badge) void {
        const s = &b.sess;
        const now = g.now;
        if (b.left) return s.pump(now);
        if (!b.racing) {
            const start = s.ls.is_host() and @popCount(s.ls.ready_mask()) == n_badges;
            if (!s.lobby(now, start)) return;
            b.racing = true;
            b.log[0] = b.md.state_hash();
        }
        // The update's two ticks: submit both, step what is in.
        const pad: usize = s.world.pad_of[s.ls.local_slot()];
        for (0..2) |_| s.submit(now, Badge.byte_for(pad, s.ls.local_hi));
        b.owed = 2;
        g.step(b);
    }

    fn step(g: *Group, b: *Badge) void {
        const s = &b.sess;
        while (b.owed > 0 and s.ls.tick < max_ticks) {
            if (b.sess.ls.tick == leave_tick and b == &g.b[leaver]) {
                s.leave(g.now);
                b.left = true;
                b.owed = 0;
                return;
            }
            if (!s.step(b.owed == 1)) return;
            b.owed -= 1;
            const t = s.ls.tick;
            b.log[t] = b.md.state_hash();
            for (0..16) |slot| {
                if (b.gone_at[slot] == null and s.world.gone >> @intCast(slot) & 1 != 0) b.gone_at[slot] = t;
            }
        }
    }

    fn run_until(g: *Group, limit_us: u64, comptime done: fn (*Group) bool) !void {
        const end = g.now + limit_us;
        while (!done(g)) {
            if (g.now > end) {
                for (&g.b, 0..) |*b, i| std.debug.print("mp-party timeout: badge {d} slot {d} state {t} tick {d} racing {}\n", .{ i, b.sess.ls.local_slot(), b.sess.ls.state(), b.sess.ls.tick, b.racing });
                return error.Timeout;
            }
            var best: ?usize = null;
            for (&g.b, 0..) |*b, i| {
                if (!b.attached) continue;
                if (best == null or b.next_time() < g.b[best.?].next_time()) best = i;
            }
            const b = &g.b[best orelse return error.NoBadges];
            g.now = @max(g.now, b.next_time());
            g.relay.advance(g.now);
            if (b.point == 0) g.update(b) else {
                b.sess.pump(g.now);
                if (b.racing and !b.left) g.step(b);
            }
            b.point += 1;
            if (b.point == points.len) {
                b.point = 0;
                b.frame_start += b.period;
            }
        }
    }

    fn all_racing(g: *Group) bool {
        for (&g.b) |*b| if (!b.racing) return false;
        return true;
    }

    fn finished(g: *Group) bool {
        for (&g.b, 0..) |*b, i| {
            if (i == leaver) {
                if (!b.left) return false;
            } else if (b.sess.ls.tick < end_tick) return false;
        }
        return true;
    }
};

test "mp-party: four badges play Mega Bomberman in lockstep, a 30 ms badge, a leaver" {
    const a = std.testing.allocator;
    const rom = bomber.load(a) orelse return error.SkipZigTest;
    defer a.free(rom);
    const g = try a.create(Group);
    defer a.destroy(g);
    g.relay.init(4711);
    g.now = 1_000_000;
    g.rom_crc = std.hash.Crc32.hash(rom);
    var mds: [n_badges]*Md = undefined;
    defer for (mds) |m| a.destroy(m);
    for (&g.b, &mds, 0..) |*b, *m, i| {
        m.* = try a.create(Md);
        m.*.init_in_place(core.RomSource.from_slice(rom));
        g.kind = m.*.setup.cfg.kind;
        b.* = .{
            .sess = undefined,
            .md = m.*,
            .period = if (i == 2) 60_000 else 33_333 + 7 * @as(u64, @intCast(i)),
            .frame_start = g.now + @as(u64, @intCast(i)) * 997,
        };
        var name: [12]u8 = @splat(0);
        _ = try std.fmt.bufPrint(&name, "P{d}", .{i + 1});
        b.sess.init(.{}, players.game_ram, name, m.*, @intCast(0x1234 + i));
        b.sess.crc = g.rom_crc;
        b.sess.crc_known = true;
        b.sess.kind = m.*.setup.cfg.kind;
        b.sess.want_ready = true;
    }
    try std.testing.expectEqual(core.ports.Kind.tap1, g.kind);
    // Attach in order, a few frames apart, so ids follow the badges.
    for (&g.b, 0..) |*b, i| {
        b.attached = true;
        b.frame_start = @max(b.frame_start, g.now);
        g.relay.attach(i, pv.Endpoint.of(VPort, &b.sess.ls.client.port), 1000, 1500);
        const F = struct {
            fn joined(gg: *Group) bool {
                for (&gg.b) |*bb| if (bb.attached and bb.sess.ls.state() != .lobby) return false;
                return true;
            }
        };
        try g.run_until(5_000_000, F.joined);
    }
    for (&g.b, 0..) |*b, i| try std.testing.expectEqual(@as(u4, @intCast(i)), b.sess.ls.local_slot());
    try g.run_until(10_000_000, Group.all_racing);
    for (&g.b) |*b| {
        try std.testing.expect(b.sess.rom_matches());
        try std.testing.expectEqual(core.ports.Kind.tap1, b.md.setup.cfg.kind);
        try std.testing.expect(b.md.setup.lockstep);
    }
    try g.run_until(600_000_000, Group.finished);

    // Every badge logged the same console after every tick it ran.
    const upto = g.b[0].sess.ls.tick;
    for (g.b[1..], 1..) |*b, i| {
        const last = @min(upto, b.sess.ls.tick);
        for (0..last + 1) |t| {
            if (g.b[0].log[t] != b.log[t]) {
                std.debug.print("\nmp-party: badges 1 and {d} differ at tick {d}\n", .{ i + 1, t });
                return error.Desync;
            }
        }
    }
    // And they ran exactly the console a single badge runs when it is
    // handed every player's pad for every tick: each byte reached its pad.
    const solo = try a.create(Md);
    defer a.destroy(solo);
    solo.init_in_place(core.RomSource.from_slice(rom));
    solo.setup.lockstep = true;
    for (1..upto + 1) |t| {
        var p: core.Pads = @splat(0);
        for (0..n_badges) |k| p[k] = Badge.byte_for(k, @intCast(t - 1));
        solo.step_frame_pads(&p, false);
        if (solo.state_hash() != g.b[0].log[t]) {
            std.debug.print("\nmp-party: the party run and the solo run differ at tick {d}\n", .{t});
            return error.Desync;
        }
    }
    // The leaver's pad went idle on the same tick on the three others.
    const at = g.b[0].gone_at[leaver] orelse return error.NoHandOver;
    for (g.b[1..leaver]) |*b| try std.testing.expectEqual(at, b.gone_at[leaver].?);
    try std.testing.expect(at > leave_tick);
    var stalls: u64 = 0;
    for (&g.b) |*b| stalls += b.sess.ls.stats.stalls;
    std.debug.print("\nmp-party: 4 badges, Mega Bomberman to tick {d} in sync (battle from {d}), badge 4 left at {d}, idle from tick {d} everywhere; step stalls {d}\n", .{ upto, bomber.battle_frame, leave_tick, at, stalls });
}

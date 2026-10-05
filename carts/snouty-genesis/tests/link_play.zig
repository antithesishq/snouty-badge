//! Two-player link play (docs/LINK_PLAY.md): two badges, each
//! a real console (the full core) and a `linkplay.Session` over a
//! lib/link_virtual.zig cable, on a shared microsecond clock with their own
//! 30 Hz updates (one a little slower, an occasional doubled update). The
//! model of an update, after app.zig: the top pumps, submits the badge's
//! pad and tries the tick; a tick that cannot run yet is retried every
//! millisecond while it still fits the update (`link_pump_until_us` less
//! the tick's cost); a tick runs its two Genesis frames at once (the
//! virtual clock does not move inside it) and the console's poll hook
//! pumps from inside them, then the badge pumps every 3.5 ms (the hook's
//! spacing) until the tick's cost has passed and every millisecond after
//! that until 31 ms into the update, while a race runs. The badge's
//! 8-entry receive FIFO is modelled as lib/tests/lockstep_unit.zig does
//! (pessimistically: a packet arrives in an instant, so a second one before
//! the next pump is lost), plus optional random byte loss.
//!
//! Checked: both consoles hash equal at every 4th tick, and equal to a
//! third console fed the bytes both badges submitted (so the lockstep
//! feeds exactly the pads, host on pad 1, guest on pad 2); 1% byte loss;
//! the partner leaving (cable out, Leave) with the race going on solo;
//! a desync found on both; a wrong ROM, the other build and a wrong cart
//! kept out of a race; a rematch after a Leave.
const std = @import("std");
const core = @import("core");
const lockstep = @import("lockstep");
const linkplay = @import("linkplay");
const link_host = @import("link_host");
const link = link_host.link;
const virtual = link_host.virtual;
const mpd = @import("mp_determinism.zig");
const Md = core.Md;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// Print per-test summaries (stalls, packets lost, detection latency).
const report = true;

// ---- the cable with faults (lib/tests/lockstep_unit.zig's) -------------------

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
const Session = linkplay.Session(L);
const Ls = Session.Ls;

// ---- the badges ------------------------------------------------------------

const period_us: u64 = 33_333;
const pump_until_us: u64 = 31_000;
const max_ticks = 4096;
/// Hashes are logged every this many ticks.
const log_every = 4;

const Opts = struct {
    seed: u32 = 1,
    loss_ppm: u32 = 0,
    /// Side 1's update is this much longer (us).
    drift: u64 = 37,
    /// One update in this many takes two periods (0: never).
    slow_every: u32 = 150,
    /// A tick's two Genesis frames (us): side 0, side 1.
    cost: [2]u64 = .{ 22_000, 27_000 },
    /// Side 1's link app byte (another cart: not the Genesis id).
    app1: u8 = linkplay.app_id,
    /// Side 1 runs another ROM (its CRC differs).
    other_rom: bool = false,
};

const Badge = struct {
    s: Session,
    md: *Md,
    side: u1,
    period: u64,
    cost: u64,
    frame_start: u64,
    /// The next event of this update (us).
    next: u64,
    rng: u32,
    held: u16 = 0,
    racing: bool = false,
    /// This update's tick ran; the time its frames end.
    stepped: bool = true,
    busy_until: u64 = 0,
    frames: u64 = 0,
    /// Updates without a tick in a race (stalls), the longest run.
    stall_frames: u32 = 0,
    stall_run: u32 = 0,
    stall_max: u32 = 0,
    race_updates: u32 = 0,
    /// The race start (GO round trip, the first windows) waits apart.
    start_max: u32 = 0,
    /// Bytes submitted, by the tick they drive (`ls.local_hi`).
    sent: [max_ticks]u8 = @splat(0),
    hashes: [max_ticks / log_every + 1]u32 = @splat(0),
    /// Leave the race at this tick (0: never); mutate the console then.
    leave_at: u32 = 0,
    mutate_at: u32 = 0,
    mutated: bool = false,
    /// Stop submitting (and stepping) at this tick (0: never).
    stop_at: u32 = 0,
    /// The host starts the race on its own (auto lobby).
    auto_go: bool = true,
    /// The link screen is open (link_lobby.zig: ready while open; B
    /// clears the ready flag).
    screen: bool = true,

    fn rand(b: *Badge) u32 {
        var x = b.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b.rng = x;
        return x;
    }

    /// A human: buttons held a few updates at a time (Up and Down together
    /// now and then, which the wire drops).
    fn pad(b: *Badge) u16 {
        const r = b.rand();
        if (r % 5 == 0) b.held = @truncate((r >> 8) & 0xFF);
        return b.held;
    }

    fn poll(ctx: *anyopaque) void {
        const b: *Badge = @ptrCast(@alignCast(ctx));
        b.s.pump(b.next);
    }
};

const Duo = struct {
    cable: virtual.Cable,
    wire: Wire,
    b: [2]Badge,
    now: u64,
    opts: Opts,
    rom: []const u8,
    rom2: []const u8,

    fn init(d: *Duo, rom: []const u8, rom2: []const u8, opts: Opts) !void {
        const a = std.testing.allocator;
        d.cable = .{ .kind = .crossed };
        d.wire = .{ .loss_ppm = opts.loss_ppm, .rng = opts.seed *% 2_654_435_761 | 1 };
        d.opts = opts;
        d.now = 1_000_000;
        d.rom = rom;
        d.rom2 = rom2;
        for (0..2) |i| {
            const side: u1 = @intCast(i);
            const r = if (side == 1 and opts.other_rom) rom2 else rom;
            const md = try a.create(Md);
            // Different garbage on each badge before power-on.
            @memset(std.mem.asBytes(md), if (side == 0) 0x00 else 0xA5);
            md.init_in_place(core.RomSource.from_slice(r));
            const app: u8 = if (side == 1) opts.app1 else linkplay.app_id;
            const seed = if (side == 0) opts.seed *% 2_654_435_761 +% 1 else opts.seed *% 40_503 +% 7;
            const l = L.init(.{ .inner = d.cable.port(side), .wire = &d.wire }, app, seed);
            d.b[i] = .{
                .s = undefined,
                .md = md,
                .side = side,
                .period = period_us + if (side == 1) opts.drift else 0,
                .cost = opts.cost[i],
                .frame_start = d.now + @as(u64, side) * 11_000,
                .next = d.now + @as(u64, side) * 11_000,
                .rng = seed | 1,
            };
            d.b[i].s.init(l, md);
            d.b[i].s.crc = std.hash.Crc32.hash(r);
            d.b[i].s.crc_known = true;
            d.b[i].s.kind = linkplay.race_kind(md.setup.cfg.kind);
        }
        // After the copies above: the hook's context is the badge's place.
        for (&d.b) |*b| b.md.setup.poll_hook = .{ .ctx = b, .func = &Badge.poll };
    }

    fn deinit(d: *Duo) void {
        for (&d.b) |*b| std.testing.allocator.destroy(b.md);
    }

    fn host(d: *Duo) *Badge {
        return if (d.b[0].s.ls.role == .host) &d.b[0] else &d.b[1];
    }

    /// Run events in time order until `done` or `limit_us` of virtual time.
    fn run(d: *Duo, limit_us: u64, ctx: anytype, comptime done: fn (*Duo, @TypeOf(ctx)) bool) !void {
        const end = d.now + limit_us;
        while (!done(d, ctx)) {
            if (d.now > end) {
                if (report) for (&d.b) |*b| std.debug.print("timeout: side {d} role {t} state {t} tick {d} local_hi {d} remote_hi {d} racing {} frames {d}\n", .{ b.side, b.s.ls.role, b.s.ls.state(), b.s.ls.tick, b.s.ls.local_hi, b.s.ls.remote_hi, b.racing, b.frames });
                return error.Timeout;
            }
            const i: usize = if (d.b[0].next <= d.b[1].next) 0 else 1;
            d.event(&d.b[i]);
        }
    }

    fn event(d: *Duo, b: *Badge) void {
        d.now = b.next;
        d.wire.fifo = d.b[0].s.ls.link.connected() and d.b[1].s.ls.link.connected();
        const into = d.now - b.frame_start;
        if (into == 0) return d.top(b);
        if (!b.stepped) {
            b.s.pump(d.now);
            d.try_step(b);
        } else if (b.s.ls.wants_pump()) {
            b.s.pump(d.now);
        }
        d.schedule(b);
    }

    /// The top of one badge's update.
    fn top(d: *Duo, b: *Badge) void {
        const s = &b.s;
        b.frames += 1;
        s.pump(d.now);
        if (s.take_start()) {
            b.racing = true;
            b.mutated = false;
            b.sent = @splat(0);
        }
        if (s.ls.state() == .lobby) {
            if (b.screen) {
                s.want = true;
                s.lobby(d.now, b.auto_go);
            } else if (s.want) {
                s.want = false;
                s.ls.set_pick(1, false);
            }
        }
        b.stepped = true;
        if (b.racing and s.ls.busy()) {
            const t = s.ls.tick;
            if (b.leave_at != 0 and t >= b.leave_at) {
                s.leave(d.now);
                b.racing = false;
            } else if (b.stop_at == 0 or t < b.stop_at) {
                if (b.mutate_at != 0 and t >= b.mutate_at and !b.mutated) {
                    b.md.work_ram[0x8123] ^= 0x5A;
                    b.mutated = true;
                }
                const hi = s.ls.local_hi;
                const p = b.pad();
                s.submit(d.now, p);
                if (s.ls.local_hi == hi + 1 and hi < max_ticks) b.sent[hi] = lockstep.sanitize(linkplay.wire_byte(p));
                b.stepped = false;
                b.race_updates += 1;
                d.try_step(b);
            }
        }
        d.schedule(b);
    }

    fn try_step(d: *Duo, b: *Badge) void {
        const into = d.now - b.frame_start;
        const wait_us = pump_until_us -| b.cost;
        if (into > wait_us) return;
        if (!b.s.step(true)) return;
        b.stepped = true;
        b.busy_until = d.now + b.cost;
        const t = b.s.ls.tick;
        if (t % log_every == 0 and t / log_every < b.hashes.len) b.hashes[t / log_every] = b.md.state_hash();
    }

    /// The next event of this badge: a pump point inside the update, or
    /// the next update's top (a stall counted when the tick never ran).
    fn schedule(d: *Duo, b: *Badge) void {
        const into = d.now - b.frame_start;
        var step: u64 = 1000;
        if (b.stepped and d.now < b.busy_until) step = 3500;
        const nxt = into + step;
        const waiting = !b.stepped and nxt <= pump_until_us -| b.cost;
        const tail = b.s.ls.wants_pump() and nxt <= pump_until_us;
        if (waiting or tail or (b.stepped and d.now < b.busy_until)) {
            b.next = b.frame_start + nxt;
            return;
        }
        if (b.racing and !b.stepped and b.s.ls.busy()) {
            b.stall_run += 1;
            if (b.s.ls.tick < 4 * Ls.input_delay) {
                b.start_max = @max(b.start_max, b.stall_run);
            } else {
                b.stall_frames += 1;
                b.stall_max = @max(b.stall_max, b.stall_run);
            }
        } else b.stall_run = 0;
        var len = b.period;
        if (d.opts.slow_every != 0 and b.rand() % d.opts.slow_every == 0) len *= 2;
        b.frame_start += len;
        b.next = b.frame_start;
    }

    fn both_ticks(d: *Duo, n: u32) bool {
        return d.b[0].s.ls.tick >= n and d.b[1].s.ls.tick >= n;
    }

    fn both_lobby(d: *Duo, _: void) bool {
        return d.b[0].s.ls.state() == .lobby and d.b[1].s.ls.state() == .lobby;
    }

    fn summary(d: *Duo, name: []const u8) void {
        if (!report) return;
        const h = &d.b[0];
        const g = &d.b[1];
        std.debug.print("link-play: {s}: ticks {d}/{d}, stalled updates {d}+{d} of {d}+{d} (longest {d}, {d}; race start {d}, {d}), bytes lost {d}, FIFO overflows {d}, checks ok {d}/{d}, old windows {d}/{d}\n", .{
            name,                     h.s.ls.tick,              g.s.ls.tick,
            h.stall_frames,           g.stall_frames,           h.race_updates,
            g.race_updates,           h.stall_max,              g.stall_max,
            h.start_max,              g.start_max,              d.wire.lost,
            d.wire.overflow,          h.s.ls.stats.checks_ok,   g.s.ls.stats.checks_ok,
            h.s.ls.stats.old_windows, g.s.ls.stats.old_windows,
        });
    }
};

fn until_ticks(d: *Duo, n: u32) bool {
    return d.both_ticks(n);
}

fn load_test_rom() ?[]u8 {
    return mpd.load(std.testing.allocator, "roms/snouty-test.bin", null);
}

fn load_mini() ?[]u8 {
    return mpd.load(std.testing.allocator, "roms/miniplanets.bin", null);
}

/// Both consoles agree at every logged tick up to `n`, and with a third
/// console fed the submitted bytes (host pad 1, guest pad 2).
fn check_sync(d: *Duo, n: u32) !void {
    const h = d.host();
    const g = if (h == &d.b[0]) &d.b[1] else &d.b[0];
    var k: u32 = 1;
    while (k * log_every <= n) : (k += 1) {
        if (d.b[0].hashes[k] != d.b[1].hashes[k]) {
            std.debug.print("link-play: hashes differ at tick {d}\n", .{k * log_every});
            return error.Desync;
        }
    }
    // The reference console.
    const a = std.testing.allocator;
    const ref = try a.create(Md);
    defer a.destroy(ref);
    @memset(std.mem.asBytes(ref), 0x3C);
    ref.init_in_place(core.RomSource.from_slice(d.rom));
    var w: linkplay.Game.World = .{ .md = ref };
    const rules = h.s.ls.race.rules;
    linkplay.Game.start(&w, &rules);
    var t: u32 = 0;
    while (t < n) : (t += 1) {
        linkplay.Game.simulate(&w, .{ h.sent[t], g.sent[t] });
        if ((t + 1) % log_every == 0) try expectEqual(h.hashes[(t + 1) / log_every], ref.state_hash());
    }
}

fn race(rom: []const u8, opts: Opts, ticks: u32, name: []const u8) !void {
    var d: Duo = undefined;
    try d.init(rom, rom, opts);
    defer d.deinit();
    try d.run(@as(u64, ticks + 200) * period_us * 3, ticks, until_ticks);
    d.summary(name);
    try check_sync(&d, ticks);
    try expectEqual(lockstep.State.racing, d.b[0].s.ls.state());
    try expectEqual(lockstep.State.racing, d.b[1].s.ls.state());
    // Both consoles are in lockstep mode with the race's peripheral.
    for (&d.b) |*b| {
        try expect(b.md.setup.lockstep);
        try expectEqual(core.ports.Kind.pads2, b.md.setup.cfg.kind);
    }
}

test "link-play: the wire byte puts the guest's pad on pad 2" {
    const a = std.testing.allocator;
    const rom = load_test_rom() orelse return error.SkipZigTest;
    defer a.free(rom);
    const md = try a.create(Md);
    defer a.destroy(md);
    md.init_in_place(core.RomSource.from_slice(rom));
    var w: linkplay.Game.World = .{ .md = md };
    const r = linkplay.make_rules(1, .pads2, linkplay.this_variant);
    linkplay.Game.start(&w, &r);
    const p1 = core.Pad.up | core.Pad.c;
    const p2 = core.Pad.left | core.Pad.start | core.Pad.down;
    linkplay.Game.simulate(&w, .{ linkplay.wire_byte(p1), linkplay.wire_byte(p2) });
    try expectEqual(p1, md.ports.pads[0]);
    try expectEqual(p2, md.ports.pads[1]);
    try expectEqual(@as(u32, 2), md.frame_count);
    // Every byte but Up+Down (bits 6 and 7) survives the wire.
    var b: u32 = 0;
    while (b < 256) : (b += 1) {
        const byte: u8 = @intCast(b);
        const pad = linkplay.pad_of(byte);
        try expectEqual(byte, linkplay.wire_byte(pad));
        if (byte & 0xC0 != 0xC0) try expectEqual(byte, lockstep.sanitize(byte));
    }
    // Rules round trip; the peripheral per detected kind.
    const rr = linkplay.make_rules(0xDEADBEEF, .tap1, .ram);
    try expectEqual(@as(u32, 0xDEADBEEF), linkplay.rules_crc(&rr));
    try expectEqual(core.ports.Kind.tap1, linkplay.rules_kind(&rr).?);
    try expectEqual(core.ports.Kind.pads2, linkplay.race_kind(.pad1));
    try expectEqual(core.ports.Kind.jcart, linkplay.race_kind(.jcart));
}

test "link-play: clean cable, test ROM, 900 ticks in sync" {
    const a = std.testing.allocator;
    const rom = load_test_rom() orelse return error.SkipZigTest;
    defer a.free(rom);
    try race(rom, .{}, 900, "clean, test ROM");
}

test "link-play: clean cable, Miniplanets, 600 ticks in sync" {
    const a = std.testing.allocator;
    const rom = load_mini() orelse return error.SkipZigTest;
    defer a.free(rom);
    try race(rom, .{ .seed = 7, .cost = .{ 29_000, 24_000 } }, 600, "clean, Miniplanets");
}

test "link-play: 1% byte loss, in sync" {
    const a = std.testing.allocator;
    const rom = load_test_rom() orelse return error.SkipZigTest;
    defer a.free(rom);
    try race(rom, .{ .seed = 3, .loss_ppm = 10_000 }, 900, "1% byte loss");
}

test "link-play: cable out mid-race, both go on solo with pad 2 released" {
    const a = std.testing.allocator;
    const rom = load_test_rom() orelse return error.SkipZigTest;
    defer a.free(rom);
    var d: Duo = undefined;
    try d.init(rom, rom, .{ .seed = 5 });
    defer d.deinit();
    try d.run(600 * period_us, @as(u32, 200), until_ticks);
    const t_out = d.now;
    d.cable.plugged = false;
    const Gone = struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].s.ls.state() == .peer_left and dd.b[1].s.ls.state() == .peer_left;
        }
    };
    try d.run(2_000_000, {}, Gone.f);
    const latency = d.now - t_out;
    try expect(latency < 100_000);
    for (&d.b) |*b| try expectEqual(lockstep.Left.unplugged, b.s.ls.left);
    // The race goes on alone; the partner's slot is handed over.
    const t0 = [2]u32{ d.b[0].s.ls.tick, d.b[1].s.ls.tick };
    try d.run(600 * period_us, t0[0] + 60, until_ticks);
    for (&d.b) |*b| {
        try expect(b.s.world.gone != 0);
        try expectEqual(@as(u16, 0), b.md.ports.pads[@as(u2, b.s.ls.local_slot()) ^ 1]);
    }
    if (report) std.debug.print("link-play: cable out: peer_left on both after {d} us\n", .{latency});
}

test "link-play: Leave, the partner's race goes on, then a rematch in sync" {
    const a = std.testing.allocator;
    const rom = load_test_rom() orelse return error.SkipZigTest;
    defer a.free(rom);
    var d: Duo = undefined;
    try d.init(rom, rom, .{ .seed = 11 });
    defer d.deinit();
    try d.run(600 * period_us, @as(u32, 150), until_ticks);
    // The guest leaves (the menu's Link: leave).
    const g = if (d.host() == &d.b[0]) &d.b[1] else &d.b[0];
    const h = d.host();
    g.leave_at = g.s.ls.tick;
    const HostLeft = struct {
        fn f(_: *Duo, hb: *Badge) bool {
            return hb.s.ls.state() == .peer_left;
        }
    };
    try d.run(2_000_000, h, HostLeft.f);
    try expectEqual(lockstep.Left.quit, h.s.ls.left);
    try expectEqual(lockstep.State.lobby, g.s.ls.state());
    // The host's frontend leaves too (app.zig end_race): both in the lobby,
    // and the host's auto lobby starts a rematch.
    g.leave_at = 0;
    h.s.leave(d.now);
    h.racing = false;
    const Again = struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].racing and dd.b[1].racing and dd.b[0].s.ls.race.id == 2 and dd.b[1].s.ls.race.id == 2 and dd.both_ticks(300);
        }
    };
    try d.run(1000 * period_us, {}, Again.f);
    try check_sync(&d, 300);
    d.summary("rematch");
}

test "link-play: a desync is found on both badges" {
    const a = std.testing.allocator;
    const rom = load_test_rom() orelse return error.SkipZigTest;
    defer a.free(rom);
    var d: Duo = undefined;
    try d.init(rom, rom, .{ .seed = 13 });
    defer d.deinit();
    d.b[1].mutate_at = 100;
    const Desync = struct {
        fn f(dd: *Duo, _: void) bool {
            return dd.b[0].s.ls.state() == .desync and dd.b[1].s.ls.state() == .desync;
        }
    };
    try d.run(1000 * period_us, {}, Desync.f);
    const late = @max(d.b[0].s.ls.desync_tick, d.b[1].s.ls.desync_tick) - 100;
    try expect(late <= 2 * Ls.check_every);
    if (report) std.debug.print("link-play: desync found on both {d} ticks after the change\n", .{late});
}

test "link-play: another ROM, the other build or another cart never races" {
    const a = std.testing.allocator;
    const rom = load_test_rom() orelse return error.SkipZigTest;
    defer a.free(rom);
    const mini = load_mini() orelse return error.SkipZigTest;
    defer a.free(mini);
    {
        // Side 1 has Miniplanets: whoever hosts, the guest sees WRONG ROM
        // and never readies.
        var d: Duo = undefined;
        try d.init(rom, mini, .{ .seed = 17, .other_rom = true });
        defer d.deinit();
        try d.run(4_000_000, {}, Duo.both_lobby);
        const Settle = struct {
            fn f(dd: *Duo, end: u64) bool {
                return dd.now >= end;
            }
        };
        try d.run(4_000_000, d.now + 3_000_000, Settle.f);
        const h = d.host();
        const g = if (h == &d.b[0]) &d.b[1] else &d.b[0];
        try expectEqual(linkplay.Match.wrong_rom, g.s.verdict());
        try expect(!h.s.ls.can_go());
        try expect(!d.b[0].racing and !d.b[1].racing);
    }
    {
        // The host offers the other build's rules: OTHER BUILD.
        var d: Duo = undefined;
        try d.init(rom, rom, .{ .seed = 19 });
        defer d.deinit();
        for (&d.b) |*b| b.auto_go = false;
        try d.run(4_000_000, {}, Duo.both_lobby);
        const h = d.host();
        const g = if (h == &d.b[0]) &d.b[1] else &d.b[0];
        h.s.crc_known = false; // the auto lobby stops offering its own
        const other: linkplay.Variant = if (linkplay.this_variant == .ram) .full else .ram;
        h.s.ls.set_rules(linkplay.make_rules(g.s.crc, g.s.kind, other));
        const Heard = struct {
            fn f(_: *Duo, gb: *Badge) bool {
                return gb.s.verdict() == .other_build;
            }
        };
        try d.run(2_000_000, g, Heard.f);
        try expect(!h.s.ls.can_go());
    }
    {
        // The guest leaves its link screen (B): no longer ready, no GO.
        var d: Duo = undefined;
        try d.init(rom, rom, .{ .seed = 29 });
        defer d.deinit();
        for (&d.b) |*b| b.auto_go = false;
        const Ready = struct {
            fn f(dd: *Duo, _: void) bool {
                return dd.both_lobby({}) and dd.host().s.ls.can_go();
            }
        };
        try d.run(4_000_000, {}, Ready.f);
        const h = d.host();
        const g = if (h == &d.b[0]) &d.b[1] else &d.b[0];
        g.screen = false;
        const NotReady = struct {
            fn f(dd: *Duo, hb: *Badge) bool {
                _ = dd;
                return !hb.s.ls.can_go();
            }
        };
        try d.run(1_000_000, h, NotReady.f);
        h.auto_go = true;
        const Settle = struct {
            fn f(dd: *Duo, end: u64) bool {
                return dd.now >= end;
            }
        };
        try d.run(2_000_000, d.now + 1_000_000, Settle.f);
        try expect(!h.racing and !g.racing);
    }
    {
        // Side 1 runs Snouty Pong: WRONG CART.
        var d: Duo = undefined;
        try d.init(rom, rom, .{ .seed = 23, .app1 = lockstep.apps.pong });
        defer d.deinit();
        const Wrong = struct {
            fn f(dd: *Duo, _: void) bool {
                return dd.b[0].s.ls.state() == .wrong_cart;
            }
        };
        try d.run(4_000_000, {}, Wrong.f);
        try std.testing.expectEqualStrings("SNOUTY PONG", d.b[0].s.ls.partner_name());
    }
}

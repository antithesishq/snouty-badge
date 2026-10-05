//! comlynx: ComLynx over the badge link cable (frontend/cablenet.zig,
//! docs/CABLE.md) between two host Lynxes joined by lib/link_virtual.zig.
//! Each virtual badge runs the cart's schedule: an update every 16,667 us
//! (the two badges' vsyncs out of phase), the frame stepped at its start
//! and the cable left unread while the step "runs" (`step_us`, bytes wait
//! in the 256-byte receive ring as with the DMA ring on the badge), then
//! `after_frame` and the pump until 14 ms into the update, as
//! frontend/cable.zig does. Bytes can be dropped on the wire (a packet
//! then fails its CRC) to exercise the resends.
//!
//! The handshake (same ROM, ROM mismatch, wrong cart, leave, cable out),
//! the token ring (tests/comlynx/ring.lnx, committed) on 2 consoles, and
//! Warbirds (Adrian's local dump `~/roms/lynx/Warbirds.lnx`, skipped when
//! absent) finding 2 players and reaching the cockpit over the cable, with
//! and without loss, both cable orientations.
const std = @import("std");
const core = @import("core");
const cablenet = @import("cablenet");
const link_host = @import("link_host");
const files = @import("testfiles.zig");
const runner = @import("runner.zig");
const wb = @import("comlynx_warbirds.zig");
const link = link_host.link;
const virtual = link_host.virtual;
const Lynx = core.Lynx;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

/// The virtual cable's port with random byte loss on transmit.
const LossyPort = struct {
    pub const available = true;
    inner: virtual.Port,
    /// Drop a byte with probability `loss_ppm` / 1e6.
    loss_ppm: u32 = 0,
    rng: *std.Random.DefaultPrng,
    dropped: u32 = 0,

    pub fn search(p: *LossyPort, drive: link.Pin) void {
        p.inner.search(drive);
    }
    pub fn read(p: *LossyPort, pin: link.Pin) bool {
        return p.inner.read(pin);
    }
    pub fn probe(p: *LossyPort, pin: link.Pin) bool {
        return p.inner.probe(pin);
    }
    pub fn uart_start(p: *LossyPort, tx: link.Pin) void {
        p.inner.uart_start(tx);
    }
    pub fn uart_put(p: *LossyPort, byte: u8) bool {
        if (p.loss_ppm > 0 and p.rng.random().intRangeLessThan(u32, 0, 1_000_000) < p.loss_ppm) {
            p.dropped += 1;
            return true;
        }
        return p.inner.uart_put(byte);
    }
    pub fn uart_get(p: *LossyPort) ?u8 {
        return p.inner.uart_get();
    }
    pub fn take_framing_errors(p: *LossyPort) u32 {
        return p.inner.take_framing_errors();
    }
};

const Link = link.Link(LossyPort);
const Net = cablenet.Net(Link);

const frame_us: u64 = 16_667;
const pump_until_us: u64 = 14_000;
const tick_us: u64 = 100;

const Badge = struct {
    lynx: Lynx,
    link: Link,
    net: Net,
    port: core.comlynx.Port,
    fe: runner.Frontend,
    /// Microseconds into each 16,667 us period at which its update starts.
    phase_us: u64,
    /// How long its frame step "takes" (the cable is not read meanwhile).
    step_us: u64,
    /// Badge frames since the console restarted linked (null: not yet).
    linked_frames: ?u32,
    /// Its pad source after the restart.
    script: []const u16,
    glyph: u32,
    cockpit_at: ?u32,
    /// Restarts that found the port (GO).
    restarts: u32,
    unlinks: u32,
    was_linked: bool,
    /// The frame in slices (frontend/cable.zig `step_frame`): the slice
    /// count, the one due next, the frame's start and length.
    slices: u32,
    slice: u32,
    stepping: bool,
    frame_t0: u64,
    frame_span: u64,
};

var badges: [2]Badge = undefined;
var cable: virtual.Cable = undefined;
var rng: std.Random.DefaultPrng = undefined;
var rom_buf: [512 * 1024 + 64]u8 = undefined;
var lay: core.cart.Layout = undefined;
var script_buf: [4096]u8 = undefined;
var controls: [4000]u16 = undefined;
var no_script: [1]u16 = .{0};

const Opts = struct {
    kind: virtual.Kind = .crossed,
    crc: [2]u32 = .{ 0x1234ABCD, 0x1234ABCD },
    loss_ppm: u32 = 0,
    phase_us: [2]u64 = .{ 0, 5_300 },
    step_us: [2]u64 = .{ 9_000, 11_000 },
    /// `tuning.link_slices` (1: the whole frame, then the cable).
    slices: u32 = 4,
    seed: u64 = 1,
};

fn setup(rom: []const u8, o: Opts) void {
    lay = core.cart.parse(rom, @intCast(rom.len));
    rng = .init(o.seed);
    cable = .{ .kind = o.kind };
    for (&badges, 0..) |*b, i| {
        b.lynx.init_in_place(core.Cart.from_slice(&lay, rom));
        b.link = Link.init(.{ .inner = cable.port(@intCast(i)), .loss_ppm = o.loss_ppm, .rng = &rng }, cablenet.app_id, @truncate(o.seed *% 0x9E3779B97F4A7C15 +% i * 7919 + 1));
        b.net = Net.init(&b.link, o.crc[i]);
        b.fe = .{ .running = true };
        b.phase_us = o.phase_us[i];
        b.step_us = o.step_us[i];
        b.linked_frames = null;
        b.script = &no_script;
        b.glyph = 0;
        b.cockpit_at = null;
        b.restarts = 0;
        b.unlinks = 0;
        b.was_linked = false;
        b.slices = o.slices;
        b.stepping = false;
    }
}

/// What a badge's frame does with its console: the LINK screen (frozen
/// until GO) or play (stepped), and the pad.
const PadFn = *const fn (b: *Badge, i: usize) u16;

fn script_pad(b: *Badge, _: usize) u16 {
    const k = b.linked_frames orelse return 0;
    if (k >= b.script.len) return 0;
    return b.fe.update(b.script[k]) orelse 0;
}

fn ring_pad(b: *Badge, _: usize) u16 {
    return @as(u16, b.net.my_id()) | 2 << 4;
}

/// Run `us` microseconds of both badges' schedules from `t0`; returns the
/// end time.
fn run(t0: u64, us: u64, pad: PadFn) u64 {
    var t = t0;
    const end = t0 + us;
    while (t < end) : (t += tick_us) {
        for (&badges, 0..) |*b, i| tick(b, i, t, pad);
    }
    return end;
}

fn tick(b: *Badge, i: usize, t: u64, pad: PadFn) void {
    const into = (t + frame_us - b.phase_us) % frame_us;
    if (into < tick_us) {
        // The update starts: service, maybe restart, begin the frame.
        if (b.net.before_frame(t, &b.lynx)) {
            b.net.restart(&b.lynx, &b.port);
            b.restarts += 1;
            b.linked_frames = 0;
        }
        b.stepping = b.net.attached;
        if (b.stepping) {
            b.lynx.begin_frame(pad(b, i));
            b.frame_t0 = b.lynx.time();
            b.frame_span = b.lynx.frame_end_time() -| b.frame_t0;
            b.slice = 1;
        }
    } else if (b.stepping and b.slice < b.slices and into >= b.step_us * b.slice / b.slices) {
        // A slice boundary (cablenet `step_frame`), at its share of the
        // frame's wall time.
        b.lynx.run_to(b.frame_t0 + b.frame_span * b.slice / b.slices);
        b.net.after_frame(t, &b.lynx);
        b.slice += 1;
    } else if (into >= b.step_us and into < b.step_us + tick_us) {
        if (b.stepping) {
            b.lynx.finish_frame();
            b.linked_frames.? += 1;
            b.stepping = false;
        }
        b.net.after_frame(t, &b.lynx);
    } else if (into > b.step_us and into < pump_until_us and b.net.attached) {
        b.net.service(t, &b.lynx);
    }
    if (b.was_linked and !b.net.linked) b.unlinks += 1;
    b.was_linked = b.net.linked;
}

var tiny_rom: [600]u8 = @splat(0x12);

test "comlynx: cable handshake: same ROM links both, the host first, both orientations" {
    for ([_]virtual.Kind{ .crossed, .straight }) |kind| {
        setup(&tiny_rom, .{ .kind = kind, .seed = 7 });
        var t = run(0, 1_000_000, ring_pad);
        for (&badges) |*b| try expectEqual(cablenet.Status.same_rom, b.net.status());
        try expect(badges[0].net.host != badges[1].net.host);
        badges[0].net.set_ready(true);
        t = run(t, 200_000, ring_pad);
        try expect(badges[1].net.partner_ready);
        try expectEqual(@as(u32, 0), badges[0].restarts + badges[1].restarts);
        badges[1].net.set_ready(true);
        t = run(t, 300_000, ring_pad);
        for (&badges) |*b| {
            try expectEqual(cablenet.Status.linked, b.net.status());
            try expectEqual(@as(u32, 1), b.restarts);
            try expect(b.net.attached);
        }
        // The host restarted first, the guest `stagger_frames` later.
        const h: usize = if (badges[0].net.host) 0 else 1;
        try expect(badges[h].linked_frames.? >= badges[h ^ 1].linked_frames.? + cablenet.stagger_frames - 1);
    }
}

test "comlynx: cable handshake: ROM mismatch and wrong cart never link" {
    setup(&tiny_rom, .{ .crc = .{ 1, 2 } });
    var t = run(0, 1_000_000, ring_pad);
    for (&badges) |*b| {
        try expectEqual(cablenet.Status.rom_mismatch, b.net.status());
        b.net.set_ready(true);
    }
    try expectEqual(@as(?u32, 2), badges[0].net.partner_crc);
    t = run(t, 500_000, ring_pad);
    for (&badges) |*b| try expectEqual(@as(u32, 0), b.restarts);

    // The partner runs another cart (Snouty Boy's app id).
    setup(&tiny_rom, .{});
    badges[1].link.app = 'B';
    t = run(0, 1_000_000, ring_pad);
    try expectEqual(cablenet.Status.wrong_cart, badges[0].net.status());
    try expectEqual(@as(u8, 'B'), badges[0].net.partner_app);
}

fn link_both(o: Opts, rom: []const u8, pad: PadFn) !u64 {
    setup(rom, o);
    var t = run(0, 1_000_000, pad);
    for (&badges) |*b| {
        try expectEqual(cablenet.Status.same_rom, b.net.status());
        b.net.set_ready(true);
    }
    t = run(t, 300_000, pad);
    for (&badges) |*b| try expect(b.net.attached);
    return t;
}

/// The clock `leave` waits on: the partner is not serviced meanwhile, so
/// its ack never comes and the wait runs out (5 ms).
fn leave_now() u64 {
    leave_clock += 50;
    return leave_clock;
}
var leave_clock: u64 = 0;

test "comlynx: cable: a partner leaving or the cable coming out unlinks both" {
    var t = try link_both(.{}, &tiny_rom, ring_pad);
    leave_clock = t;
    badges[0].net.leave(leave_now, &badges[0].lynx);
    t = leave_clock;
    try expect(!badges[0].net.linked);
    t = run(t, 100_000, ring_pad);
    try expect(!badges[1].net.linked);
    try expect(badges[1].lynx.link == null);
    try expectEqual(cablenet.Status.partner_left, badges[1].net.status());

    t = try link_both(.{ .seed = 3 }, &tiny_rom, ring_pad);
    cable.plugged = false;
    t = run(t, 200_000, ring_pad);
    for (&badges) |*b| {
        try expect(!b.net.linked);
        try expect(b.lynx.link == null);
        try expectEqual(cablenet.Status.searching, b.net.status());
    }
    // Plugged back in: a fresh session, linkable again.
    cable.plugged = true;
    t = run(t, 1_000_000, ring_pad);
    for (&badges) |*b| try expectEqual(cablenet.Status.same_rom, b.net.status());
}

// ---------------------------------------------------------------------------
// The token ring (tests/comlynx/ring.s) on 2 consoles over the cable.

const Res = struct {
    const base: u16 = 0x1F00;
    fn ok(l: *const Lynx) bool {
        return l.ram[base] == 0xC3;
    }
    fn messages(l: *const Lynx) u16 {
        return @as(u16, l.ram[base + 4]) | @as(u16, l.ram[base + 5]) << 8;
    }
    fn errors(l: *const Lynx) u8 {
        return l.ram[base + 8];
    }
    fn regens(l: *const Lynx) u8 {
        return l.ram[base + 9];
    }
};

var ring_buf: [4096]u8 = undefined;

const RingResult = struct { per_s: u32, errors: u32, regens: u32, resends: u32, dropped: u32 };

fn ring(o: Opts) !RingResult {
    const file = files.read_cart_file("tests/comlynx/ring.lnx", &ring_buf) orelse return error.SkipZigTest;
    var t = try link_both(o, file, ring_pad);
    t = run(t, 6 * 1_000_000, ring_pad);
    const at = Res.messages(&badges[0].lynx);
    t = run(t, 4 * 1_000_000, ring_pad);
    var r: RingResult = .{ .per_s = (Res.messages(&badges[0].lynx) -% at) / 4, .errors = 0, .regens = 0, .resends = 0, .dropped = 0 };
    for (&badges) |*b| {
        try expect(Res.ok(&b.lynx));
        try expect(b.net.attached);
        r.errors += Res.errors(&b.lynx);
        r.regens += Res.regens(&b.lynx);
        r.resends += b.net.stats.resends;
        r.dropped += b.link.port.dropped;
        try expectEqual(@as(u32, 0), b.net.stats.refused);
    }
    return r;
}

test "comlynx: cable: token ring on 2 consoles, clean and with byte loss" {
    // The whole frame before the cable (no slices): a hop costs a frame
    // of batching, and the ring's 33-49 ms watchdog sometimes fires
    // (printed only: docs/CABLE.md "Timing").
    const whole = try ring(.{ .slices = 1 });
    std.debug.print("\ncable ring, 1 slice: {d} msg/s, errors {d}, regens {d}\n", .{ whole.per_s, whole.errors, whole.regens });
    for ([_]virtual.Kind{ .crossed, .straight }) |kind| {
        const r = try ring(.{ .kind = kind });
        std.debug.print("\ncable ring {s}: {d} msg/s, errors {d}, regens {d}, resends {d}\n", .{ @tagName(kind), r.per_s, r.errors, r.regens, r.resends });
        try expectEqual(@as(u32, 0), r.errors);
        try expectEqual(@as(u32, 0), r.resends);
        try expect(r.per_s >= 25);
    }
    // 0.2% of the wire bytes lost (a packet in ~35): every frame arrives
    // (the frame-count test below), but a resend can hold a hop past the
    // ring's own 33-49 ms watchdog, whose regenerated token then shows as
    // sequence errors: a few, not a broken ring.
    const r = try ring(.{ .loss_ppm = 2_000, .seed = 11 });
    std.debug.print("cable ring, 0.2% byte loss: {d} msg/s, errors {d}, regens {d}, resends {d}, bytes dropped {d}\n", .{ r.per_s, r.errors, r.regens, r.resends, r.dropped });
    try expect(r.dropped > 0);
    try expect(r.resends > 0);
    try expect(r.regens <= 10);
    try expect(r.per_s >= 80);
}

test "comlynx: cable: every ComLynx frame arrives once, in order, through byte loss" {
    for ([_]u32{ 0, 2_000, 5_000 }) |loss| {
        var t = try link_both(.{ .loss_ppm = loss, .seed = 21 + loss }, &tiny_rom, ring_pad);
        // Badge 0's UART "sends" 40 frames a badge frame (a busy game:
        // ~14 packets), as if from its 62,500-baud UART, 11 bits apart.
        const before = badges[1].net.stats.frames_in;
        var sent: u32 = 0;
        var k: u32 = 0;
        while (k < 120) : (k += 1) {
            const p = badges[0].net.port.?;
            const t0 = badges[0].lynx.time();
            for (0..40) |j| {
                p.push_out(.{ .time = t0 + j * 11 * 256, .bit_ticks = 256, .data = @truncate(sent), .ninth = sent & 1 == 1, .kind = .frame });
                sent += 1;
            }
            t = run(t, frame_us, ring_pad);
        }
        t = run(t, 500_000, ring_pad);
        const got = badges[1].net.stats.frames_in - before;
        std.debug.print("\ncable frames, {d} ppm byte loss: sent {d}, delivered {d}, resends {d}, timeouts {d}, naks {d}, refused {d}, dropped bytes {d}\n", .{
            loss, sent, got, badges[0].net.stats.resends, badges[0].net.stats.timeouts, badges[0].net.stats.naks, badges[1].net.stats.refused, badges[0].link.port.dropped,
        });
        try expectEqual(sent, got);
        try expectEqual(@as(u32, 0), badges[0].port.out_dropped);
        try expectEqual(@as(u32, 0), badges[1].net.stats.refused);
        if (loss > 0) try expect(badges[0].net.stats.resends > 0);
        for (&badges) |*b| try expect(b.net.attached);
    }
}

// ---------------------------------------------------------------------------
// Warbirds (Adrian's local dump) over the cable.

fn warbirds(o: Opts, frames: u32) !void {
    const file = files.read_home_file("roms/lynx/Warbirds.lnx", &rom_buf) orelse return error.SkipZigTest;
    const json = files.read_cart_file("tools/scripts/warbirds_link.json", &script_buf) orelse return error.FileNotFound;
    @memset(&controls, 0);
    try runner.parse_script(std.testing.allocator, json, controls[0..frames]);
    var t = try link_both(o, file, script_pad);
    for (&badges) |*b| b.script = controls[0..frames];
    var k: u32 = 0;
    while (k < frames / 30) : (k += 1) {
        t = run(t, 30 * frame_us, script_pad);
        for (&badges) |*b| {
            const g = wb.players_glyph(&b.lynx);
            if (g != 0) b.glyph = g;
            if (b.cockpit_at == null and wb.cockpit(&b.lynx)) b.cockpit_at = b.linked_frames;
        }
    }
    std.debug.print("\ncable warbirds {s} loss {d} ppm: glyph {d} {d}, cockpit at {?d} {?d}, resends {d} {d}, late {d} {d}\n", .{
        @tagName(o.kind),            o.loss_ppm,
        badges[0].glyph,             badges[1].glyph,
        badges[0].cockpit_at,        badges[1].cockpit_at,
        badges[0].net.stats.resends, badges[1].net.stats.resends,
        badges[0].net.stats.late,    badges[1].net.stats.late,
    });
    for (&badges) |*b| {
        try expect(b.net.attached);
        // The title's digit for 2 players (comlynx_warbirds.zig: 2 consoles 12, 4 consoles 11).
        try expectEqual(@as(u32, 12), b.glyph);
        try expect(b.cockpit_at != null);
    }
    try expectEqual(badges[0].glyph, badges[1].glyph);
}

test "comlynx: cable: Warbirds (local dump) finds 2 players and starts the networked game" {
    try warbirds(.{ .kind = .crossed }, 1500);
    try warbirds(.{ .kind = .straight, .phase_us = .{ 9_000, 1_000 }, .seed = 5 }, 1500);
    try warbirds(.{ .loss_ppm = 2_000, .seed = 9 }, 1500);
}

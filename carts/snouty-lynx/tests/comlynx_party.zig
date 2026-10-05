//! comlynx: ComLynx over the lobby (frontend/lynxnet.zig on lib/party.zig)
//! through lib/party_virtual.zig's model of `badge lobby` and the badges'
//! USB (docs/COMLYNX.md section 10). Warbirds (Adrian's local dump,
//! skipped when absent) on 2 and 4 virtual badges: they join one room (the
//! ROM's CRC is in the game id), say ready, the host sends GO, every
//! badge restarts linked and runs tools/scripts/warbirds_link.json from
//! there; passing = every badge shows "N PLAYERS" and reaches the
//! cockpit. Also a leaver (unplugged mid-game) and the timestamped mode.
const std = @import("std");
const core = @import("core");
const ph = @import("party_host");
const lynxnet = @import("lynxnet");
const files = @import("testfiles.zig");
const runner = @import("runner.zig");
const wb = @import("comlynx_warbirds.zig");
const party = ph.party;
const pv = ph.party_virtual;
const cart_serial = ph.cart_serial;
const Lynx = core.Lynx;
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

const SerialPort = cart_serial.Virtual(.{ .rx_size = 2048, .tx_size = 512 });
const Client = party.Client(SerialPort);
const Net = lynxnet.Net(Client);

const Badge = struct {
    lynx: Lynx,
    client: Client,
    port: core.comlynx.Port,
    net: Net,
    fe: runner.Frontend,
    go_at: ?u32,
    glyph: u32,
    cockpit_at: ?u32,
    gone: bool,
};

var badges: [4]Badge = undefined;
var relay: pv.Relay = undefined;
var rom_buf: [512 * 1024 + 64]u8 = undefined;
var script_buf: [4096]u8 = undefined;
var controls: [4000]u16 = undefined;
var lay: core.cart.Layout = undefined;

const Opts = struct {
    n: usize,
    d_ms: u8 = 0,
    latency_us: u32 = 1000,
    jitter_us: u32 = 500,
    frames: u32 = 1500,
    /// Unplug this badge at this frame after GO.
    leaver: ?struct { i: usize, at: u32 } = null,
};

/// One badge frame in microseconds (the relay's clock), and when in it a
/// badge's update has sent (its frame stepped: about half the frame on
/// the badge, docs/COMLYNX.md section 9).
const frame_us: u64 = 16_667;
const send_us: u64 = 8_000;

fn play(o: Opts) !void {
    const file = files.read_home_file("roms/lynx/Warbirds.lnx", &rom_buf) orelse return error.SkipZigTest;
    lay = core.cart.parse(file, @intCast(file.len));
    const json = files.read_cart_file("tools/scripts/warbirds_link.json", &script_buf) orelse return error.FileNotFound;
    try runner.parse_script(std.testing.allocator, json, &controls);
    const crc = std.hash.Crc32.hash(file);
    relay.init(11);
    for (badges[0..o.n], 0..) |*b, i| {
        b.lynx.init_in_place(core.Cart.from_slice(&lay, file));
        b.client = Client.init(.{}, .{ .game = Net.game_id(crc), .name = party.pad(12, &.{ 'L', '0' + @as(u8, @intCast(i)) }), .max_players = 4 });
        b.net = Net.init(&b.client, &b.port, crc);
        b.net.want_d_ms = o.d_ms;
        b.fe = .{ .running = true };
        b.go_at = null;
        b.glyph = 0;
        b.cockpit_at = null;
        b.gone = false;
    }
    var f: u32 = 0;
    var started = false;
    while (f < o.frames * 2 + 400) : (f += 1) {
        // What reached the badges by the start of this frame.
        relay.advance(@as(u64, f) * frame_us);
        // Badges plug in a few frames apart (ids in that order).
        for (badges[0..o.n], 0..) |*b, i| {
            if (f == 3 * i) relay.attach(i, pv.Endpoint.of(SerialPort, &b.client.port), o.latency_us, o.jitter_us);
        }
        for (badges[0..o.n], 0..) |*b, i| {
            if (b.gone) continue;
            if (b.net.before_frame(&b.lynx)) {
                b.go_at = f;
                b.fe = .{ .running = true };
            }
            if (!b.net.linked) {
                if (b.client.state() == .joined and b.net.player_count() == o.n) b.net.set_ready(true);
                if (!started and b.net.all_ready() and b.net.start(o.d_ms)) started = true;
                // (Unlinked consoles idle here; GO restarts them anyway.)
            } else if (!b.net.attached) {
                // Switched on later (lynxnet.stagger_frames): the old game
                // runs on meanwhile (its clock is the link time).
                b.lynx.step_frame(0);
            } else if (b.net.can_step(&b.lynx)) {
                // The script counts game frames (a stalled badge waits).
                const k = b.lynx.frame_count;
                const pad = b.fe.update(if (k < controls.len) controls[k] else 0) orelse 0;
                b.lynx.step_frame(pad);
            }
            b.net.after_frame(&b.lynx);
            if (b.go_at != null) {
                const k = b.lynx.frame_count;
                if (k % 30 == 0) {
                    const gl = wb.players_glyph(&b.lynx);
                    if (gl != 0) b.glyph = gl;
                    if (b.cockpit_at == null and wb.cockpit(&b.lynx)) b.cockpit_at = k;
                }
                if (o.leaver) |lv| {
                    if (lv.i == i and k == lv.at) {
                        relay.unplug(i);
                        b.gone = true;
                    }
                }
            }
        }
        // The badges' sends leave about half way through the frame.
        relay.advance(@as(u64, f) * frame_us + send_us);
        // Stop once every badge has played `frames` game frames since GO.
        var done = true;
        for (badges[0..o.n]) |*b| {
            if (b.gone) continue;
            if (b.go_at == null or b.lynx.frame_count < o.frames) done = false;
        }
        if (done) break;
    }
}

fn report(o: Opts) void {
    std.debug.print("party: {d} badges, D {d} ms, latency {d}+{d} us:", .{ o.n, o.d_ms, o.latency_us, o.jitter_us });
    for (badges[0..o.n]) |*b| {
        std.debug.print(" [id {?d} go {?d} glyph {d} cockpit {?d} out {d} in {d} stalls {d} late {d} wdrop {d} odrop {d} ferr {d} txfull {d}]", .{ b.client.me(), b.go_at, b.glyph, b.cockpit_at, b.net.stats.frames_out, b.net.stats.frames_in, b.net.stats.stalls, b.net.stats.late, b.port.wire_dropped, b.port.out_dropped, b.port.framing_errors, b.net.stats.tx_full });
    }
    std.debug.print("\n", .{});
}

/// The digit glyph's pixel count Warbirds shows for 2 and 4 players
/// (tests/comlynx_warbirds.zig measured them: 12 and 11).
const glyph2 = 12;
const glyph4 = 11;

fn expect_game(o: Opts, glyph: u32) !void {
    for (badges[0..o.n]) |*b| {
        if (b.gone) continue;
        try expect(b.go_at != null);
        try expectEqual(glyph, b.glyph);
        try expect(b.cockpit_at != null);
    }
}

test "comlynx: Warbirds on 2 badges over the lobby in relay mode, 4 in timestamped mode (D 25 ms)" {
    const two: Opts = .{ .n = 2 };
    try play(two);
    report(two);
    try expect_game(two, glyph2);
    // Relay mode does not carry 4 (docs/COMLYNX.md section 5); T + D does.
    const four: Opts = .{ .n = 4, .d_ms = 25 };
    try play(four);
    report(four);
    try expect_game(four, glyph4);
}

test "comlynx: timestamped mode is the same game whatever the latency (2 badges, D 33 ms)" {
    const a: Opts = .{ .n = 2, .d_ms = 33, .latency_us = 1000, .jitter_us = 500 };
    try play(a);
    report(a);
    try expect_game(a, glyph2);
    var h: [2]u64 = undefined;
    for (badges[0..2], 0..) |*b, i| h[i] = runner.frame_hash(b.lynx.frame());
    const b8: Opts = .{ .n = 2, .d_ms = 33, .latency_us = 6000, .jitter_us = 6000 };
    try play(b8);
    report(b8);
    for (badges[0..2], 0..) |*b, i| {
        try expectEqual(@as(u32, 0), b.net.stats.late);
        // Stalls differ, the emulated game does not.
        try expectEqual(h[i], runner.frame_hash(b.lynx.frame()));
    }
}

test "comlynx: a badge unplugged mid-game leaves the others running" {
    const o: Opts = .{ .n = 4, .d_ms = 25, .frames = 1500, .leaver = .{ .i = 2, .at = 1000 } };
    try play(o);
    report(o);
    for (badges[0..4], 0..) |*b, i| {
        if (i == 2) continue;
        try expect(b.net.stats.leavers >= 1);
        try expect(b.cockpit_at != null);
        try expectEqual(@as(u16, 0b1011), b.net.present);
    }
}

test "comlynx: lobby sweep (printed with COMLYNX_TABLE=1)" {
    if (std.testing.environ.getPosix("COMLYNX_TABLE") == null) return error.SkipZigTest;
    for ([_]usize{ 2, 4 }) |n| {
        for ([_]u8{ 0, 17, 25, 33, 50, 75 }) |d| {
            for ([_]u32{ 1000, 8000 }) |lat| {
                const o: Opts = .{ .n = n, .d_ms = d, .latency_us = lat, .jitter_us = lat / 2 };
                try play(o);
                var ok = true;
                for (badges[0..n]) |*b| ok = ok and b.cockpit_at != null and b.glyph == (if (n == 2) @as(u32, glyph2) else glyph4);
                std.debug.print("{s} ", .{if (ok) "PASS" else "fail"});
                report(o);
            }
        }
    }
}

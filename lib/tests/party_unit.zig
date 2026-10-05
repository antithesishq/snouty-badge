//! Host tests for lib/party.zig (lobby protocol v1 client), lib/cart_serial.zig
//! (the ring ABI) and lib/party_virtual.zig (the `badge lobby` model).
//!
//! Byte vectors: the COBS ones are the examples of the COBS reference that
//! fork/CART_SERIAL.md links (Wikipedia, "Consistent Overhead Byte
//! Stuffing", encoding examples 1-7). The message ones follow the message
//! tables of fork/CART_SERIAL.md at sycl-badge-fork 13ffec9 (section
//! "Lobby protocol v1"); the fork's reference implementations
//! (`src/os/cart/lobby.zig` is a placeholder at 13ffec9, `tools/badge/
//! badge/lobby.py` does not exist yet) could not be run, so the wire
//! bytes were computed by an independent Python COBS encoder from those
//! tables. Re-check against lobby.py once it lands (M8.1).
const std = @import("std");
const party = @import("../party.zig");
const cart_serial = @import("../cart_serial.zig");
const pv = @import("../party_virtual.zig");

const Port = cart_serial.Virtual(.{});
const Client = party.Client(Port);
const expectEqual = std.testing.expectEqual;
const expectEqualSlices = std.testing.expectEqualSlices;
const expect = std.testing.expect;

// ---- COBS ----------------------------------------------------------------

fn expect_cobs(decoded: []const u8, encoded: []const u8) !void {
    var enc: [400]u8 = undefined;
    const n = party.cobs_encode(decoded, &enc);
    try expectEqualSlices(u8, encoded, enc[0..n]);
    var dec: [400]u8 = undefined;
    const m = party.cobs_decode(encoded, &dec).?;
    try expectEqualSlices(u8, decoded, dec[0..m]);
}

test "cobs: the reference examples" {
    try expect_cobs(&.{0x00}, &.{ 0x01, 0x01 });
    try expect_cobs(&.{ 0x00, 0x00 }, &.{ 0x01, 0x01, 0x01 });
    try expect_cobs(&.{ 0x00, 0x11, 0x00 }, &.{ 0x01, 0x02, 0x11, 0x01 });
    try expect_cobs(&.{ 0x11, 0x22, 0x00, 0x33 }, &.{ 0x03, 0x11, 0x22, 0x02, 0x33 });
    try expect_cobs(&.{ 0x11, 0x22, 0x33, 0x44 }, &.{ 0x05, 0x11, 0x22, 0x33, 0x44 });
    try expect_cobs(&.{ 0x11, 0x00, 0x00, 0x00 }, &.{ 0x02, 0x11, 0x01, 0x01, 0x01 });
    // 01..FE (254 bytes) -> FF 01..FE
    var src: [255]u8 = undefined;
    var exp: [257]u8 = undefined;
    for (0..254) |i| src[i] = @intCast(i + 1);
    exp[0] = 0xFF;
    for (0..254) |i| exp[1 + i] = @intCast(i + 1);
    try expect_cobs(src[0..254], exp[0..255]);
    // 00..FE (255 bytes) -> 01 FF 01..FE
    for (0..255) |i| src[i] = @intCast(i);
    exp[0] = 0x01;
    exp[1] = 0xFF;
    for (0..254) |i| exp[2 + i] = @intCast(i + 1);
    try expect_cobs(src[0..255], exp[0..256]);
    // 01..FF (255 bytes) -> FF 01..FE 02 FF
    for (0..255) |i| src[i] = @intCast(i + 1);
    exp[0] = 0xFF;
    for (0..254) |i| exp[1 + i] = @intCast(i + 1);
    exp[255] = 0x02;
    exp[256] = 0xFF;
    try expect_cobs(src[0..255], exp[0..257]);
}

test "cobs: malformed frames are refused" {
    var dec: [16]u8 = undefined;
    try expect(party.cobs_decode(&.{ 0x05, 0x01 }, &dec) == null); // block past the end
    try expect(party.cobs_decode(&.{ 0x02, 0x00 }, &dec) == null); // a zero inside
    try expect(party.cobs_decode(&.{ 0x09, 1, 2, 3, 4, 5, 6, 7, 8 }, dec[0..4]) == null); // too long
}

// ---- a client on a bare virtual port ---------------------------------------

const opts: party.Options = .{
    .game = party.pad(8, "SNOUTDM1"),
    .name = party.pad(12, "ADRIAN"),
    .max_players = 16,
};

/// Everything the client wrote so far.
fn take(c: *Client, buf: []u8) []u8 {
    const n = c.port.os_take(buf);
    return buf[0..n];
}

fn put(c: *Client, bytes: []const u8) void {
    std.debug.assert(c.port.os_put(bytes) == bytes.len);
}

const hello_wire = [_]u8{ 0x11, 0x01, 0x01, 0x53, 0x4E, 0x4F, 0x55, 0x54, 0x44, 0x4D, 0x31, 0x41, 0x44, 0x52, 0x49, 0x41, 0x4E, 0x01, 0x01, 0x01, 0x01, 0x01, 0x02, 0x10, 0x00 };
const welcome_wire = [_]u8{ 0x04, 0x81, 0x01, 0x02, 0x02, 0x10, 0x00 };
const roster_wire = [_]u8{ 0x03, 0x82, 0x02, 0x07, 0x41, 0x44, 0x52, 0x49, 0x41, 0x4E, 0x01, 0x01, 0x01, 0x01, 0x01, 0x03, 0x02, 0x42, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01, 0x00 };
const data_wire = [_]u8{ 0x04, 0x83, 0x03, 0x05, 0x02, 0xC0, 0x00 };
const pong_wire = [_]u8{ 0x06, 0x84, 0x78, 0x56, 0x34, 0x12, 0x00 };
const error_wire = [_]u8{ 0x0D, 0x8F, 0x03, 0x4E, 0x4F, 0x54, 0x20, 0x4A, 0x4F, 0x49, 0x4E, 0x45, 0x44, 0x00 };

test "client: states, the flush byte and HELLO" {
    var c = Client.init(.{ .os_supported = false }, opts);
    try expect(c.poll() == null);
    try expectEqual(party.State.unsupported, c.state());

    c = Client.init(.{}, opts);
    try expect(c.poll() == null);
    try expectEqual(party.State.disconnected, c.state());
    c.port.host_open = true;
    try expect(c.poll() == null);
    try expectEqual(party.State.joining, c.state());
    var buf: [512]u8 = undefined;
    const out = take(&c, &buf);
    // A lone 0x00 on (re)connect, then HELLO.
    try expectEqual(@as(u8, 0), out[0]);
    try expectEqualSlices(u8, &hello_wire, out[1..]);
    try expectEqualSlices(u8, &hello_wire, blk: {
        var f: [64]u8 = undefined;
        const n = party.encode_frame(&c.hello_body(), &f);
        break :blk f[0..n];
    });
}

test "client: every host message parses" {
    var c = Client.init(.{}, opts);
    c.port.host_open = true;
    _ = c.poll();
    var buf: [512]u8 = undefined;
    _ = take(&c, &buf);
    put(&c, &welcome_wire);
    put(&c, &roster_wire);
    put(&c, &data_wire);
    put(&c, &pong_wire);
    put(&c, &error_wire);
    put(&c, &.{ 0x02, 0x77, 0x00 }); // an unknown type: ignored
    const w = c.poll().?.joined;
    try expectEqual(@as(u8, 2), w.you);
    try expectEqual(@as(u8, 0), w.room);
    try expectEqual(@as(u8, 16), w.max_players);
    try expectEqual(party.State.joined, c.state());
    try expect(c.poll().? == .roster);
    try expectEqual(@as(u16, 0b101), c.present);
    try expectEqualSlices(u8, "ADRIAN", c.name(0));
    try expectEqualSlices(u8, "B", c.name(2));
    const d = c.poll().?.data;
    try expectEqual(@as(u8, 3), d.from);
    try expectEqualSlices(u8, &.{ 0x05, 0x00, 0xC0 }, d.bytes);
    try expectEqual(@as(u32, 0x12345678), c.poll().?.pong);
    const e = c.poll().?.err;
    try expectEqual(party.Err.not_joined, e.code);
    try expectEqualSlices(u8, "NOT JOINED", e.message);
    try expect(c.poll() == null);
    // ERROR 3 (the host forgot us): HELLO again.
    try expectEqualSlices(u8, &hello_wire, take(&c, &buf));
}

test "client: every cart message encodes" {
    var c = Client.init(.{}, opts);
    c.port.host_open = true;
    _ = c.poll();
    var buf: [512]u8 = undefined;
    _ = take(&c, &buf);
    try expect(!c.broadcast(&.{1})); // not joined: nothing written
    try expectEqual(@as(usize, 0), take(&c, &buf).len);
    put(&c, &welcome_wire);
    _ = c.poll();
    try expect(c.broadcast(&.{ 0x05, 0x00, 0xC0 }));
    try expectEqualSlices(u8, &.{ 0x04, 0x02, 0xFF, 0x05, 0x02, 0xC0, 0x00 }, take(&c, &buf));
    try expect(c.broadcast_echo(&.{0x42}));
    try expectEqualSlices(u8, &.{ 0x04, 0x02, 0xFE, 0x42, 0x00 }, take(&c, &buf));
    try expect(c.send(3, "hi"));
    try expectEqualSlices(u8, &.{ 0x05, 0x02, 0x03, 0x68, 0x69, 0x00 }, take(&c, &buf));
    try expect(c.ping(0x12345678));
    try expectEqualSlices(u8, &.{ 0x06, 0x03, 0x78, 0x56, 0x34, 0x12, 0x00 }, take(&c, &buf));
    c.leave();
    try expectEqualSlices(u8, &.{ 0x02, 0x04, 0x00 }, take(&c, &buf));
    try expectEqual(party.State.idle, c.state());
    c.join();
    try expectEqualSlices(u8, &hello_wire, take(&c, &buf));
}

test "client: resync on 0x00, long and broken frames dropped, empty frames ignored" {
    var c = Client.init(.{}, opts);
    c.port.host_open = true;
    _ = c.poll();
    // Mid-frame garbage (a listener joining mid-stream), then a frame.
    put(&c, &.{ 0x33, 0x44, 0x00 });
    put(&c, &.{ 0x00, 0x00 });
    put(&c, &.{ 0x05, 0x81, 0x00 }); // a block past the end
    put(&c, &welcome_wire);
    try expect(c.poll().? == .joined);
    // 300 non-zero bytes: too long, skipped to the next 0x00.
    var long: [300]u8 = @splat(0x55);
    put(&c, &long);
    put(&c, &.{0x00});
    put(&c, &data_wire);
    try expectEqual(@as(u8, 3), c.poll().?.data.from);
    try expect(c.poll() == null);
    try expect(c.dec.dropped >= 2);
}

test "client: re-HELLO when the port connects again" {
    var c = Client.init(.{}, opts);
    c.port.host_open = true;
    _ = c.poll();
    var buf: [512]u8 = undefined;
    _ = take(&c, &buf);
    put(&c, &welcome_wire);
    try expect(c.poll().? == .joined);
    c.port.host_open = false;
    try expect(c.poll().? == .lost);
    try expectEqual(party.State.disconnected, c.state());
    c.port.host_open = true;
    try expect(c.poll() == null);
    try expectEqual(party.State.joining, c.state());
    const out = take(&c, &buf);
    try expectEqual(@as(u8, 0), out[0]);
    try expectEqualSlices(u8, &hello_wire, out[1..]);
}

test "client: a frame is written whole or not at all" {
    var c = Client.init(.{}, opts);
    c.port.host_open = true;
    _ = c.poll();
    var buf: [2048]u8 = undefined;
    _ = take(&c, &buf);
    put(&c, &welcome_wire);
    _ = c.poll();
    const data: [200]u8 = @splat(7);
    var sent: u32 = 0;
    while (c.broadcast(&data)) sent += 1;
    try expectEqual(@as(u32, 1024 / 204), sent);
    try expect(c.stats.tx_full > 0);
    const out = take(&c, &buf);
    try expectEqual(@as(usize, sent * 204), out.len);
    try expect(c.broadcast(&data));
}

// ---- the relay model -----------------------------------------------------------

const Bench = struct {
    relay: pv.Relay,
    c: [6]Client,
    now: u64,

    fn init(b: *Bench, games: []const []const u8) void {
        b.relay.init(7);
        b.now = 0;
        for (games, 0..) |g, i| {
            var o = opts;
            o.game = party.pad(8, g);
            o.name = party.pad(12, &.{ 'P', '0' + @as(u8, @intCast(i)) });
            b.c[i] = Client.init(.{}, o);
        }
    }

    fn plug(b: *Bench, i: usize) void {
        b.relay.attach(i, pv.Endpoint.of(Port, &b.c[i].port), 1000, 500);
    }

    /// Run `us` in 1 ms steps; events of client i go to its log.
    fn run(b: *Bench, n: usize, us: u64, logs: ?*Logs) void {
        const end = b.now + us;
        while (b.now < end) {
            b.now += 1000;
            b.relay.advance(b.now);
            for (b.c[0..n], 0..) |*c, i| {
                while (c.poll()) |ev| if (logs) |l| l.add(i, ev);
            }
        }
    }
};

/// DATA payloads received per client (first byte of each, plus the sender).
const Logs = struct {
    data: [6][64]u16 = undefined,
    n: [6]u8 = @splat(0),
    rosters: [6]u8 = @splat(0),

    fn add(l: *Logs, i: usize, ev: party.Event) void {
        switch (ev) {
            .data => |d| {
                l.data[i][l.n[i]] = @as(u16, d.from) << 8 | d.bytes[0];
                l.n[i] += 1;
            },
            .roster => l.rosters[i] += 1,
            else => {},
        }
    }
};

test "relay: rooms per game, lowest free id, WELCOME then ROSTER" {
    var b: Bench = undefined;
    b.init(&.{ "SNOUTDM1", "SNOUTDM1", "OTHER", "SNOUTDM1" });
    for (0..4) |i| b.plug(i);
    b.run(4, 20_000, null);
    for (0..4) |i| try expectEqual(party.State.joined, b.c[i].state());
    // Same game: ids 0, 1, 2 in one room; the other game its own room.
    try expectEqual(@as(?u8, 0), b.c[0].me());
    try expectEqual(@as(?u8, 1), b.c[1].me());
    try expectEqual(@as(?u8, 0), b.c[2].me());
    try expectEqual(@as(?u8, 2), b.c[3].me());
    try expect(b.c[2].room != b.c[0].room);
    try expectEqual(@as(u16, 0b111), b.c[0].present);
    try expectEqual(@as(u16, 0b1), b.c[2].present);
    try expectEqualSlices(u8, "P3", b.c[1].name(2));
    // Player 1 leaves; a newcomer takes the lowest free id, 1.
    b.relay.unplug(1);
    b.run(4, 20_000, null);
    try expectEqual(@as(u16, 0b101), b.c[0].present);
    try expectEqual(party.State.disconnected, b.c[1].state());
    b.relay.replug(1);
    b.run(4, 20_000, null);
    try expectEqual(@as(?u8, 1), b.c[1].me());
    try expectEqual(@as(u16, 0b111), b.c[3].present);
}

test "relay: SEND fan-out, self-echo, one order for everyone" {
    var b: Bench = undefined;
    b.init(&.{ "G", "G", "G", "G" });
    for (0..4) |i| b.plug(i);
    b.run(4, 20_000, null);
    var logs: Logs = .{};
    // Everyone sends at once, several frames each, interleaved; badge 3
    // echoes to itself.
    for (0..5) |k| {
        for (0..4) |i| {
            const tag: u8 = @intCast(k * 16 + i);
            const ok = if (i == 3) b.c[i].broadcast_echo(&.{tag}) else b.c[i].broadcast(&.{tag});
            try expect(ok);
        }
        b.run(4, 1000, &logs);
    }
    try expect(b.c[0].send(2, &.{0xEE})); // only to player 2
    try expect(b.c[0].send(9, &.{0xEF})); // absent: dropped
    b.run(4, 30_000, &logs);
    // Each badge got every frame but its own (3 got its own too).
    try expectEqual(@as(u8, 15), logs.n[0]);
    try expectEqual(@as(u8, 15 + 1), logs.n[2]);
    try expectEqual(@as(u8, 20), logs.n[3]);
    // One order: removing each badge's own frames (and the directed one),
    // the sequences agree.
    var seq: [4][64]u16 = undefined;
    var len: [4]usize = @splat(0);
    for (0..4) |i| {
        for (logs.data[i][0..logs.n[i]]) |x| {
            if (x & 0xFF == 0xEE) continue;
            seq[i][len[i]] = x;
            len[i] += 1;
        }
    }
    for (0..4) |i| for (0..4) |j| {
        var a: [64]u16 = undefined;
        var na: usize = 0;
        for (seq[i][0..len[i]]) |x| if (x >> 8 != j and x >> 8 != i) {
            a[na] = x;
            na += 1;
        };
        var c: [64]u16 = undefined;
        var nc: usize = 0;
        for (seq[j][0..len[j]]) |x| if (x >> 8 != j and x >> 8 != i) {
            c[nc] = x;
            nc += 1;
        };
        try expectEqualSlices(u16, a[0..na], c[0..nc]);
    };
    // 3's own echoed frames sit at their place in that order: in 3's log
    // they come in the same order relative to 0's frames as in 1's log.
    try expectEqual(@as(u16, 3 << 8 | 3), logs.data[3][
        blk: {
            for (logs.data[3][0..logs.n[3]], 0..) |x, k| if (x >> 8 == 3) break :blk k;
            unreachable;
        }
    ]);
}

test "relay: PING, ERROR 3, unknown types" {
    var b: Bench = undefined;
    b.init(&.{"G"});
    b.c[0].want_join = false;
    b.plug(0);
    b.run(1, 5000, null);
    try expectEqual(party.State.idle, b.c[0].state());
    try expect(b.c[0].ping(77));
    // SEND before WELCOME, written by hand.
    try expect(b.c[0].write_body(&.{ party.T.send, 0xFF, 1 }));
    try expect(b.c[0].write_body(&.{0x55}));
    var got_pong = false;
    var got_err = false;
    const end = b.now + 10_000;
    while (b.now < end) {
        b.now += 1000;
        b.relay.advance(b.now);
        while (b.c[0].poll()) |ev| switch (ev) {
            .pong => |t| got_pong = t == 77,
            .err => |e| got_err = e.code == party.Err.not_joined,
            else => {},
        };
    }
    try expect(got_pong and got_err);
}

test "relay: unplug drops in-flight bytes for everyone; overflow removes the player" {
    var b: Bench = undefined;
    b.init(&.{ "G", "G", "G" });
    for (0..3) |i| b.plug(i);
    b.run(3, 20_000, null);
    var logs: Logs = .{};
    // 1 writes and is unplugged before the relay handles it: no one gets it.
    try expect(b.c[1].broadcast(&.{0x11}));
    b.relay.advance(b.now); // taken off the badge, still in flight
    b.relay.unplug(1);
    b.run(3, 20_000, &logs);
    try expectEqual(@as(u8, 0), logs.n[0]);
    try expectEqual(@as(u8, 0), logs.n[2]);
    try expectEqual(@as(u16, 0b101), b.c[0].present);
    // 2 stops reading; 0 floods: more than the limit waits for 2 for a second, 2 is removed,
    // 0 sees a plain leave.
    // (The stuck limit scaled down from 64 KiB to 8 KiB.)
    b.relay.stuck_limit = 8 * 1024;
    b.c[2].port.deaf = true;
    var k: u32 = 0;
    while (k < 200) : (k += 1) {
        const big: [200]u8 = @splat(@truncate(k));
        _ = b.c[0].broadcast(&big);
        b.run(3, 1000, null);
    }
    // Over the limit, but not yet for a second.
    try expect(!b.relay.was_removed(2));
    b.run(3, 1_100_000, null);
    try expect(b.relay.was_removed(2));
    try expectEqual(@as(u16, 0b1), b.c[0].present);
    try expectEqual(@as(u32, 1), b.relay.stats.removed);
}

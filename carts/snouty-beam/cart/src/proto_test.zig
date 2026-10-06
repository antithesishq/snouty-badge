//! Host tests of proto.zig: two badges, each a link (lib/link.zig) plus a
//! Sender and a Receiver, on lib/link_virtual.zig's cable with a timed
//! wire on top: every byte takes 10 us (1 Mbaud 8N1) and arrives into a
//! receive buffer of 256 bytes (the DMA ring, `rx_dma = 11`) or 8 (the PIO
//! FIFO); bytes arriving while it is full are lost. Each badge runs on its
//! own clock: it polls every `pump_us` until 14 ms into its frame, then
//! draws and presents for `gap_us` without polling, and a flash erase or
//! program parks it 50-300 ms per sector (a fake area that behaves like
//! NOR). A send blocks while the transmit FIFO (8 bytes) is full, so the
//! sender comes back only when the line has room. Faults: whole packets
//! dropped (1 in N, both ways), the cable pulled, a badge losing power.
const std = @import("std");
const slot = @import("beam_slot");
const link_host = @import("link_host");
const link = link_host.link;
const virtual = link_host.virtual;
const proto = @import("proto.zig");
const src_mod = @import("source.zig");

const pong_uf2 = @embedFile("pong_uf2");
const pong_slot = @embedFile("pong_slot");

const report = true;

// ---- the timed wire ----------------------------------------------------------------

const Arrival = struct { byte: u8, at: u64 };

const Wire = struct {
    byte_us: u64 = 10,
    /// Receive buffer per end: 256 the DMA ring, 8 the PIO FIFO.
    cap: u16 = 256,
    /// In flight from end d to end d ^ 1.
    q: [2][4096]Arrival = undefined,
    q_head: [2]u32 = .{ 0, 0 },
    q_len: [2]u32 = .{ 0, 0 },
    line_free: [2]u64 = .{ 0, 0 },
    clocks: [2]*u64 = undefined,
    overflow: u32 = 0,
};

const Port = struct {
    pub const available = true;
    inner: virtual.Port,
    wire: *Wire,

    fn side(p: *Port) u1 {
        return p.inner.side;
    }
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
        const w = p.wire;
        const s = p.side();
        const c = p.inner.cable;
        if (!c.plugged or c.ends[s].uart_tx == null) return true;
        const now = w.clocks[s].*;
        const at = @max(now, w.line_free[s]) + w.byte_us;
        w.line_free[s] = at;
        if (w.q_len[s] == w.q[s].len) @panic("wire queue full");
        w.q[s][(w.q_head[s] + w.q_len[s]) % w.q[s].len] = .{ .byte = byte, .at = at };
        w.q_len[s] += 1;
        return true;
    }
    pub fn uart_get(p: *Port) ?u8 {
        p.settle();
        return p.inner.uart_get();
    }
    pub fn take_framing_errors(_: *Port) u32 {
        return 0;
    }

    /// Bytes from the far end that have arrived by our clock go into our
    /// receive buffer, up to `cap`; the rest are lost.
    fn settle(p: *Port) void {
        const w = p.wire;
        const s = p.side();
        const d = s ^ 1;
        const c = p.inner.cable;
        const now = w.clocks[s].*;
        const me = &c.ends[s];
        while (w.q_len[d] > 0) {
            const a = w.q[d][w.q_head[d]];
            if (a.at > now) break;
            w.q_head[d] = (w.q_head[d] + 1) % @as(u32, @intCast(w.q[d].len));
            w.q_len[d] -= 1;
            if (!c.plugged or me.uart_tx == null) continue;
            if (me.rx_len >= w.cap) {
                w.overflow += 1;
                continue;
            }
            me.rx[me.rx_head +% @as(u8, @truncate(me.rx_len))] = a.byte;
            me.rx_len += 1;
        }
    }
};

const L = link.LinkQueue(Port, 32);

// ---- a badge -------------------------------------------------------------------------

const area_bytes = slot.default_area_size;

const Badge = struct {
    link: L,
    now: u64 = 1_000_000,
    next_at: u64 = 1_000_000,
    frame_start: u64 = 1_000_000,
    pump_us: u64 = 20,
    gap_us: u64 = 800,
    /// 1 in `drop_every` outgoing DATA packets lost (0: none).
    drop_every: u32 = 0,
    rng: u32,
    area: [area_bytes]u8 = @splat(0xFF),
    can_receive: bool = true,
    /// Flash writes left before the power goes (null: never).
    power_after: ?u32 = null,
    dead: bool = false,
    stall_min_us: u64 = 50_000,
    stall_max_us: u64 = 300_000,
    flash_ops: u32 = 0,
    session: u32 = 0,
    sender: Sender = .{},
    receiver: Receiver = .{},

    fn random(b: *Badge) u32 {
        var x = b.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b.rng = x;
        return x;
    }

    /// A flash write starts: false once the power is gone.
    fn flash_op(b: *Badge) bool {
        if (b.dead) return false;
        b.flash_ops += 1;
        if (b.power_after) |*n| {
            if (n.* == 0) {
                b.dead = true;
                return false;
            }
            n.* -= 1;
        }
        return true;
    }

    /// Park the core: a sector erase plus its program together take
    /// 50-300 ms, split 80/20.
    fn stall(b: *Badge, share: u64) void {
        const span = b.stall_max_us - b.stall_min_us;
        const total = b.stall_min_us + b.random() % span;
        b.now += total * share / 100;
    }
};

const Io = struct {
    b: *Badge,
    pub fn now(io: *Io) u64 {
        return io.b.now;
    }
    pub fn send(io: *Io, bytes: []const u8) bool {
        const b = io.b;
        if (b.drop_every != 0 and b.random() % b.drop_every == 0) return true;
        return b.link.send(b.now, bytes);
    }
    pub fn erase(io: *Io, at: u32) bool {
        const b = io.b;
        if (!b.flash_op()) return true;
        @memset(b.area[at..][0..slot.sector_size], 0xFF);
        b.stall(80);
        return true;
    }
    pub fn program(io: *Io, at: u32, data: []const u8) bool {
        const b = io.b;
        if (at % 256 != 0 or data.len % 256 != 0 or data.len > 4096) @panic("misaligned program");
        if (!b.flash_op()) return true;
        for (b.area[at..][0..data.len], data) |*c, x| c.* &= x;
        b.stall(20);
        return true;
    }
    pub fn read(io: *Io, at: u32, dst: []u8) void {
        @memcpy(dst, io.b.area[at..][0..dst.len]);
    }
    pub fn area_size(_: *Io) u32 {
        return area_bytes;
    }
    pub fn can_receive(io: *Io) bool {
        return io.b.can_receive;
    }
};

const Src = src_mod.Source(slot.SliceFile);
const Sender = proto.Sender(Io, Src);
const Receiver = proto.Receiver(Io);

const Pair = struct {
    cable: virtual.Cable,
    wire: Wire,
    b: [2]Badge,

    fn init(p: *Pair, kind: virtual.Kind, seed: u32, cap: u16) void {
        p.cable = .{ .kind = kind };
        p.wire = .{ .cap = cap };
        inline for (0..2) |i_| {
            const i: u32 = i_;
            p.b[i] = .{
                .link = L.init(.{ .inner = p.cable.port(i_), .wire = &p.wire }, 'T', seed *% (2654435761 + i * 40503) +% 1 + i),
                .rng = seed *% 747796405 +% 2891336453 +% i * 12345,
            };
            p.b[i].now += i * 3_333;
            p.b[i].next_at = p.b[i].now;
            p.b[i].frame_start = p.b[i].now;
            p.wire.clocks[i] = &p.b[i].now;
        }
    }

    fn io(p: *Pair, i: usize) Io {
        return .{ .b = &p.b[i] };
    }

    /// Run one pump iteration of whichever badge is due first.
    fn step(p: *Pair) void {
        const i: usize = if (p.b[0].dead or (!p.b[1].dead and p.b[1].next_at < p.b[0].next_at)) 1 else 0;
        const b = &p.b[i];
        if (b.dead) return;
        b.now = @max(b.now, b.next_at);
        var bio: Io = .{ .b = b };
        b.link.poll(b.now);
        while (b.link.recv()) |pkt| {
            const bytes = pkt.slice();
            if (bytes.len == 0) continue;
            if (to_sender(bytes[0])) b.sender.handle(&bio, bytes);
            if (to_receiver(bytes[0])) b.receiver.handle(&bio, bytes);
        }
        if (!b.link.connected() or b.link.session != b.session) {
            b.sender.link_lost();
            b.receiver.link_lost();
            b.session = b.link.session;
        }
        b.receiver.accepting = !b.sender.active();
        b.sender.tick(&bio);
        b.receiver.tick(&bio);
        // Next: after a pump interval, once the transmit FIFO has room;
        // past the frame's pump window, after the draw and present gap.
        var next = b.now + b.pump_us;
        const fifo_room = p.wire.line_free[i] -| 8 * p.wire.byte_us;
        next = @max(next, fifo_room);
        if (next - b.frame_start >= 14_000) {
            b.frame_start = @max(next, b.frame_start + 14_000) + b.gap_us;
            next = b.frame_start;
        }
        b.next_at = next;
    }

    fn run(p: *Pair, us: u64) void {
        const end = @min(p.b[0].next_at, p.b[1].next_at) + us;
        while (@min(p.b[0].next_at, p.b[1].next_at) < end) p.step();
    }

    fn run_until(p: *Pair, limit_us: u64, cond: *const fn (*Pair) bool) !u64 {
        const t0 = p.time();
        while (p.time() - t0 < limit_us) {
            p.step();
            if (cond(p)) return p.time() - t0;
        }
        return error.Timeout;
    }

    fn time(p: *const Pair) u64 {
        return @min(p.b[0].next_at, p.b[1].next_at);
    }

    fn connect(p: *Pair) !void {
        _ = try p.run_until(10_000_000, struct {
            fn f(q: *Pair) bool {
                return q.b[0].link.connected() and q.b[1].link.connected();
            }
        }.f);
        p.run(100_000);
        p.b[0].session = p.b[0].link.session;
        p.b[1].session = p.b[1].link.session;
    }
};

const to_sender = proto.to_sender;
const to_receiver = proto.to_receiver;

fn new_pair(kind: virtual.Kind, seed: u32, cap: u16) !*Pair {
    const p = try std.testing.allocator.create(Pair);
    p.init(kind, seed, cap);
    return p;
}

// ---- helpers ---------------------------------------------------------------------------

fn pong() !slot.Uf2(slot.SliceFile) {
    return slot.Uf2(slot.SliceFile).open(.{ .bytes = pong_uf2 });
}

/// Start badge `from` sending pong.
fn send_pong(p: *Pair, from: usize, xfer: u8) !void {
    const u = try pong();
    const S = struct {
        var image: [slot.default_area_size]u8 = undefined;
    };
    const img = S.image[0..u.info.image_len];
    u.read(0, img);
    const h = u.header(slot.crc32(img), "snouty-pong.uf2");
    const hb = h.encode();
    var bio = p.io(from);
    p.b[from].sender.start(&bio, &hb, u.info.image_len, .{ .uf2 = u }, xfer);
}

fn asking(p: *Pair) bool {
    return p.b[1].receiver.state == .asking;
}

fn both_done(p: *Pair) bool {
    return p.b[0].sender.state == .finished and p.b[1].receiver.state == .finished;
}

fn accept(p: *Pair, i: usize) void {
    var bio = p.io(i);
    p.b[i].receiver.accept(&bio);
}

/// The receiver's slot area up to the end of the image, as the fixture.
fn expect_pong_slot(area: []const u8) !void {
    try std.testing.expectEqualSlices(u8, pong_slot, area[0..pong_slot.len]);
    try std.testing.expect(slot.launchable(area));
    for (area[pong_slot.len..]) |x| if (x != 0xFF) return error.TestUnexpectedResult;
}

/// The pong slot under another name: an old cart in the receiver's slot.
fn put_old_slot(area: []u8) void {
    @memcpy(area[0..pong_slot.len], pong_slot);
    var h = slot.parse(pong_slot[0..slot.header_size], area_bytes) catch unreachable;
    h.name_len = slot.name_from_file("old-cart", &h.name_buf);
    area[0..slot.header_size].* = h.encode();
}

/// After a power cut: either the old slot, untouched and launchable (the
/// cut came before the header sector's erase), or no valid slot at all.
fn expect_old_or_none(area: []const u8) !void {
    const h = slot.parse(area[0..slot.header_size], area_bytes) catch return;
    try std.testing.expectEqualSlices(u8, "old-cart", h.name());
    try std.testing.expect(slot.launchable(area));
}

fn slot_valid(area: []const u8) bool {
    _ = slot.parse(area[0..slot.header_size], area_bytes) catch return false;
    return true;
}

// ---- tests ---------------------------------------------------------------------------------

test "pong fixture: flattening drops the header blocks, matches the loader model and beam-slot output" {
    const u = try pong();
    try std.testing.expectEqual(slot.ipc_end, u.info.load_addr);
    try std.testing.expectEqual(@as(u32, 0), u.info.descriptor_offset);
    // The dropped blocks (below the IPC block's end) hold no CART_MAGIC.
    var dropped: u32 = 0;
    var i: u32 = 0;
    while (i < u.info.blocks) : (i += 1) {
        const b = pong_uf2[i * 512 ..][0..512];
        const target = std.mem.readInt(u32, b[12..16], .little);
        if (target >= slot.ipc_end) continue;
        dropped += 1;
        var w: usize = 32;
        while (w < 32 + 256) : (w += 4) {
            try std.testing.expect(std.mem.readInt(u32, b[w..][0..4], .little) != slot.cart_magic);
        }
    }
    try std.testing.expect(dropped >= 1);
    // The loader model: every block copied into RAM in file order.
    var ram: [slot.cart_ram.end - slot.cart_ram.start]u8 = @splat(0);
    i = 0;
    while (i < u.info.blocks) : (i += 1) {
        const b = pong_uf2[i * 512 ..][0..512];
        const target = std.mem.readInt(u32, b[12..16], .little);
        const len = std.mem.readInt(u32, b[16..20], .little);
        @memcpy(ram[target - slot.cart_ram.start ..][0..len], b[32..][0..len]);
    }
    var image: [64 * 1024]u8 = undefined;
    const img = image[0..u.info.image_len];
    u.read(0, img);
    try std.testing.expectEqualSlices(u8, ram[slot.ipc_end - slot.cart_ram.start ..][0..img.len], img);
    // write_area (what `zig build beam-slot` writes) == the fixture.
    var area: [slot.default_area_size]u8 = undefined;
    const n = try slot.write_area(&u, "snouty-pong.uf2", &area);
    try std.testing.expectEqualSlices(u8, pong_slot, area[0..n]);
    try std.testing.expect(slot.launchable(pong_slot));
}

const Outcome = struct { took: u64, overflow: u32, naks: u32, resends: u32 };

fn full_transfer(kind: virtual.Kind, seed: u32, cap: u16, drop_every: u32, gap_us: u64) !Outcome {
    const p = try new_pair(kind, seed, cap);
    defer std.testing.allocator.destroy(p);
    try p.connect();
    for (&p.b) |*b| {
        b.drop_every = drop_every;
        b.gap_us = gap_us;
    }
    try send_pong(p, 0, @intCast(1 + seed % 250));
    _ = try p.run_until(5_000_000, asking);
    try std.testing.expectEqualSlices(u8, "snouty-pong", p.b[1].receiver.header.name());
    accept(p, 1);
    const took = try p.run_until(120_000_000, both_done);
    try std.testing.expectEqual(proto.SendResult.sent, p.b[0].sender.result);
    try std.testing.expectEqual(proto.RecvResult.received, p.b[1].receiver.result);
    try expect_pong_slot(&p.b[1].area);
    // Nothing touched the sender's own slot.
    for (p.b[0].area) |x| if (x != 0xFF) return error.TestUnexpectedResult;
    return .{ .took = took, .overflow = p.wire.overflow, .naks = p.b[0].sender.stats.naks, .resends = p.b[0].sender.stats.resends };
}

/// Sum of the faults seen over several runs, and the slowest run.
const Tally = struct {
    worst: u64 = 0,
    overflow: u32 = 0,
    naks: u32 = 0,
    resends: u32 = 0,
    fn add(t: *Tally, o: Outcome) void {
        t.worst = @max(t.worst, o.took);
        t.overflow += o.overflow;
        t.naks += o.naks;
        t.resends += o.resends;
    }
    fn print(t: *const Tally, what: []const u8) void {
        if (report) std.debug.print("\n{s}: worst {d} ms, ring/FIFO overflow {d} bytes, NAKs {d}, resends {d}\n", .{ what, t.worst / 1000, t.overflow, t.naks, t.resends });
    }
};

test "transfer: pong arrives byte-identical, both cable kinds, many seeds, flash stalls" {
    var t: Tally = .{};
    for ([_]virtual.Kind{ .crossed, .straight }) |kind| {
        var seed: u32 = 1;
        while (seed <= 12) : (seed += 1) t.add(try full_transfer(kind, seed, 256, 0, 800));
    }
    t.print("pong, DMA ring, 0.8 ms draw gap");
    try std.testing.expect(t.worst < 3_000_000);
    try std.testing.expectEqual(@as(u32, 0), t.overflow + t.naks + t.resends);
}

test "transfer: 1 in 50 packets dropped both ways still completes" {
    for ([_]virtual.Kind{ .crossed, .straight }) |kind| {
        var seed: u32 = 100;
        var t: Tally = .{};
        while (seed < 108) : (seed += 1) t.add(try full_transfer(kind, seed, 256, 50, 800));
        t.print("pong, 1 in 50 packets dropped");
        try std.testing.expect(t.naks + t.resends > 0);
    }
}

test "transfer: the 8-byte PIO FIFO (no DMA ring) loses bytes in every frame gap and still completes" {
    var seed: u32 = 200;
    var t: Tally = .{};
    while (seed < 204) : (seed += 1) t.add(try full_transfer(.crossed, seed, 8, 0, 2_700));
    t.print("pong, 8-byte FIFO, 2.7 ms gap");
    try std.testing.expect(t.overflow > 0);
}

test "transfer: a long draw (3 ms, vsync left on) overruns the DMA ring and recovers" {
    var seed: u32 = 300;
    var t: Tally = .{};
    while (seed < 304) : (seed += 1) t.add(try full_transfer(.straight, seed, 256, 0, 3_000));
    t.print("pong, DMA ring, 3 ms gap");
    try std.testing.expect(t.overflow > 0);
}

test "transfer: cable pulled mid-way leaves the slot invalid and both sides idle" {
    const p = try new_pair(.crossed, 7, 256);
    defer std.testing.allocator.destroy(p);
    // An old cart in the receiver's slot first.
    @memcpy(p.b[1].area[0..pong_slot.len], pong_slot);
    try p.connect();
    try send_pong(p, 0, 9);
    _ = try p.run_until(5_000_000, asking);
    accept(p, 1);
    _ = try p.run_until(60_000_000, struct {
        fn f(q: *Pair) bool {
            return q.b[1].receiver.written >= 8192;
        }
    }.f);
    p.cable.plugged = false;
    _ = try p.run_until(5_000_000, both_done);
    try std.testing.expectEqual(proto.SendResult.link_lost, p.b[0].sender.result);
    try std.testing.expectEqual(proto.RecvResult.link_lost, p.b[1].receiver.result);
    try std.testing.expect(!slot_valid(&p.b[1].area));
    p.b[0].sender.reset();
    p.b[1].receiver.reset();
    try std.testing.expectEqual(Sender.State.idle, p.b[0].sender.state);
    try std.testing.expectEqual(Receiver.State.idle, p.b[1].receiver.state);
    // Plugged back in: a new transfer works.
    p.cable.plugged = true;
    try p.connect();
    try send_pong(p, 0, 10);
    _ = try p.run_until(5_000_000, asking);
    accept(p, 1);
    _ = try p.run_until(60_000_000, both_done);
    try expect_pong_slot(&p.b[1].area);
}

test "transfer: decline, the 30 s timeout and REJECT reasons; the old slot stays" {
    const p = try new_pair(.straight, 11, 256);
    defer std.testing.allocator.destroy(p);
    @memcpy(p.b[1].area[0..pong_slot.len], pong_slot);
    try p.connect();
    try send_pong(p, 0, 21);
    _ = try p.run_until(5_000_000, asking);
    var bio = p.io(1);
    p.b[1].receiver.decline(&bio);
    _ = try p.run_until(5_000_000, both_done);
    try std.testing.expectEqual(proto.SendResult{ .rejected = .declined }, p.b[0].sender.result);
    try std.testing.expect(slot.launchable(&p.b[1].area));

    // Nobody answers: declined after 30 s.
    p.b[0].sender.reset();
    p.b[1].receiver.reset();
    try send_pong(p, 0, 22);
    _ = try p.run_until(5_000_000, asking);
    const took = try p.run_until(40_000_000, both_done);
    try std.testing.expect(took > 29_000_000);
    try std.testing.expectEqual(proto.SendResult{ .rejected = .declined }, p.b[0].sender.result);
    try std.testing.expect(slot.launchable(&p.b[1].area));

    // Firmware that cannot receive.
    p.b[0].sender.reset();
    p.b[1].receiver.reset();
    p.b[1].can_receive = false;
    try send_pong(p, 0, 23);
    _ = try p.run_until(5_000_000, struct {
        fn f(q: *Pair) bool {
            return q.b[0].sender.state == .finished;
        }
    }.f);
    try std.testing.expectEqual(proto.SendResult{ .rejected = .cannot_receive }, p.b[0].sender.result);
}

test "transfer: an image too big for the receiver's area is refused" {
    const p = try new_pair(.crossed, 12, 256);
    defer std.testing.allocator.destroy(p);
    try p.connect();
    const u = try pong();
    var h = u.header(0, "big.uf2");
    h.image_len = slot.capacity(area_bytes) + 4;
    h.load_addr = slot.cart_ram.end - h.image_len;
    const hb = h.encode();
    var bio = p.io(0);
    p.b[0].sender.start(&bio, &hb, h.image_len, .{ .uf2 = u }, 5);
    _ = try p.run_until(5_000_000, struct {
        fn f(q: *Pair) bool {
            return q.b[0].sender.state == .finished;
        }
    }.f);
    try std.testing.expectEqual(proto.SendResult{ .rejected = .too_big }, p.b[0].sender.result);
}

test "transfer: sender cancel mid-way; both offering at once" {
    const p = try new_pair(.crossed, 13, 256);
    defer std.testing.allocator.destroy(p);
    try p.connect();
    try send_pong(p, 0, 31);
    _ = try p.run_until(5_000_000, asking);
    accept(p, 1);
    _ = try p.run_until(60_000_000, struct {
        fn f(q: *Pair) bool {
            return q.b[1].receiver.written >= 4096;
        }
    }.f);
    var bio = p.io(0);
    p.b[0].sender.cancel(&bio);
    _ = try p.run_until(5_000_000, both_done);
    try std.testing.expectEqual(proto.SendResult.cancelled, p.b[0].sender.result);
    try std.testing.expectEqual(proto.RecvResult{ .sender_aborted = .cancelled }, p.b[1].receiver.result);
    try std.testing.expect(!slot_valid(&p.b[1].area));

    // Both press A in the same frame: each refuses the other (busy).
    p.b[0].sender.reset();
    p.b[1].receiver.reset();
    try send_pong(p, 0, 41);
    try send_pong(p, 1, 42);
    _ = try p.run_until(5_000_000, struct {
        fn f(q: *Pair) bool {
            return q.b[0].sender.state == .finished and q.b[1].sender.state == .finished;
        }
    }.f);
    try std.testing.expectEqual(proto.SendResult{ .rejected = .busy }, p.b[0].sender.result);
    try std.testing.expectEqual(proto.SendResult{ .rejected = .busy }, p.b[1].sender.result);
}

test "transfer: power cut after k flash writes never leaves a valid slot" {
    var k: u32 = 0;
    while (k < 16) : (k += 1) {
        const p = try new_pair(.straight, 50 + k, 256);
        defer std.testing.allocator.destroy(p);
        put_old_slot(&p.b[1].area);
        try p.connect();
        try send_pong(p, 0, @intCast(60 + k));
        _ = try p.run_until(5_000_000, asking);
        p.b[1].power_after = k;
        accept(p, 1);
        // Run until the receiver dies or finishes.
        _ = p.run_until(60_000_000, struct {
            fn f(q: *Pair) bool {
                return q.b[1].dead or q.b[1].receiver.state == .finished;
            }
        }.f) catch {};
        if (p.b[1].dead) {
            try expect_old_or_none(&p.b[1].area);
            // Power back on: a fresh cart sees no slot; the sender gave up.
            p.cable.plugged = false;
            p.b[1].dead = false;
            p.b[1].receiver = .{};
            p.b[1].next_at = p.b[1].now;
            _ = try p.run_until(10_000_000, struct {
                fn f(q: *Pair) bool {
                    return q.b[0].sender.state == .finished;
                }
            }.f);
            try expect_old_or_none(&p.b[1].area);
        } else {
            // k covered every write: the transfer completed.
            try expect_pong_slot(&p.b[1].area);
        }
    }
}

test "transfer: re-sending from the received slot gives an identical slot" {
    const p = try new_pair(.crossed, 77, 256);
    defer std.testing.allocator.destroy(p);
    try p.connect();
    try send_pong(p, 0, 71);
    _ = try p.run_until(5_000_000, asking);
    accept(p, 1);
    _ = try p.run_until(60_000_000, both_done);
    try expect_pong_slot(&p.b[1].area);
    // Badge 1 sends its slot back to badge 0.
    p.b[0].sender.reset();
    p.b[1].receiver.reset();
    const h = try slot.parse(p.b[1].area[0..slot.header_size], area_bytes);
    var bio = p.io(1);
    const hb = p.b[1].area[0..slot.header_size];
    p.b[1].sender.start(&bio, hb, h.image_len, .{ .flat = p.b[1].area[slot.image_offset..][0..h.image_len] }, 72);
    _ = try p.run_until(5_000_000, struct {
        fn f(q: *Pair) bool {
            return q.b[0].receiver.state == .asking;
        }
    }.f);
    accept(p, 0);
    _ = try p.run_until(60_000_000, struct {
        fn f(q: *Pair) bool {
            return q.b[1].sender.state == .finished and q.b[0].receiver.state == .finished;
        }
    }.f);
    try std.testing.expectEqualSlices(u8, &p.b[1].area, &p.b[0].area);
}

test "transfer: packets of a stale transfer are ignored" {
    const p = try new_pair(.straight, 88, 256);
    defer std.testing.allocator.destroy(p);
    try p.connect();
    try send_pong(p, 0, 81);
    _ = try p.run_until(5_000_000, asking);
    accept(p, 1);
    _ = try p.run_until(60_000_000, struct {
        fn f(q: *Pair) bool {
            return q.b[1].receiver.written >= 4096;
        }
    }.f);
    // Old transfer 80's packets reach both machines mid-way.
    var rio = p.io(1);
    var sio = p.io(0);
    const stale = [_][]const u8{
        &.{ proto.T.block, 80, 1, 0, 0, 16, 1, 2, 3, 4, 0 },
        &.{ proto.T.data, 80, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8 },
        &.{ proto.T.abort, 80, 1 },
    };
    for (stale) |pk| p.b[1].receiver.handle(&rio, pk);
    const stale_back = [_][]const u8{
        &.{ proto.T.ack, 80, 1, 0 },
        &.{ proto.T.nak, 80, 1, 0, 0, 0 },
        &.{ proto.T.done, 80, 0 },
        &.{ proto.T.reject, 80, 1 },
        &.{ proto.T.abort, 80, 1 },
    };
    for (stale_back) |pk| p.b[0].sender.handle(&sio, pk);
    try std.testing.expectEqual(Sender.State.sending, p.b[0].sender.state);
    try std.testing.expectEqual(Receiver.State.receiving, p.b[1].receiver.state);
    _ = try p.run_until(60_000_000, both_done);
    try expect_pong_slot(&p.b[1].area);
}

test "transfer: time for a 150 KB image (PLAN.md estimate)" {
    // A synthetic RAM cart: 150 KB of pseudo-random bytes from 0x20035100.
    const n_blocks = 600;
    const S = struct {
        var uf2: [n_blocks * 512]u8 = undefined;
        var image: [slot.default_area_size]u8 = undefined;
    };
    const uf2 = &S.uf2;
    var rng: u32 = 0x1234567;
    for (0..n_blocks) |i| {
        const b = uf2[i * 512 ..][0..512];
        @memset(b, 0);
        std.mem.writeInt(u32, b[0..4], 0x0A324655, .little);
        std.mem.writeInt(u32, b[4..8], 0x9E5D5157, .little);
        std.mem.writeInt(u32, b[8..12], 0x2000, .little);
        std.mem.writeInt(u32, b[12..16], slot.ipc_end + @as(u32, @intCast(i)) * 256, .little);
        std.mem.writeInt(u32, b[16..20], 256, .little);
        std.mem.writeInt(u32, b[20..24], @intCast(i), .little);
        std.mem.writeInt(u32, b[24..28], n_blocks, .little);
        std.mem.writeInt(u32, b[28..32], 0xE48BFF59, .little);
        for (b[32..288]) |*x| {
            rng ^= rng << 13;
            rng ^= rng >> 17;
            rng ^= rng << 5;
            x.* = @truncate(rng);
        }
        std.mem.writeInt(u32, b[508..512], 0x0AB16F30, .little);
    }
    const d = uf2[32..];
    std.mem.writeInt(u32, d[0..4], slot.cart_magic, .little);
    std.mem.writeInt(u32, d[4..8], slot.cart_version_v1, .little);
    std.mem.writeInt(u32, d[8..12], 0x20070000, .little);
    std.mem.writeInt(u32, d[12..16], 0x20071000, .little);
    std.mem.writeInt(u32, d[16..20], 0x20035121, .little);
    const u = try slot.Uf2(slot.SliceFile).open(.{ .bytes = uf2 });
    const img = S.image[0..u.info.image_len];
    u.read(0, img);
    const h = u.header(slot.crc32(img), "big.uf2");
    const hb = h.encode();

    const p = try new_pair(.crossed, 99, 256);
    defer std.testing.allocator.destroy(p);
    try p.connect();
    // Typical flash (45 ms erase + ~10 ms program per 4 KB).
    p.b[1].stall_min_us = 50_000;
    p.b[1].stall_max_us = 60_000;
    var bio = p.io(0);
    p.b[0].sender.start(&bio, &hb, u.info.image_len, .{ .uf2 = u }, 3);
    _ = try p.run_until(5_000_000, asking);
    accept(p, 1);
    const took = try p.run_until(60_000_000, both_done);
    try std.testing.expectEqual(proto.RecvResult.received, p.b[1].receiver.result);
    try std.testing.expectEqualSlices(u8, img, p.b[1].area[slot.image_offset..][0..img.len]);
    if (report) std.debug.print("\n150 KB image: {d} ms ({d} KB/s), naks {d}, resends {d}, ring overflow {d}\n", .{
        took / 1000, u.info.image_len * 1000 / took, p.b[0].sender.stats.naks, p.b[0].sender.stats.resends, p.wire.overflow,
    });
    // PLAN.md: about 6 s.
    try std.testing.expect(took < 8_000_000);
}

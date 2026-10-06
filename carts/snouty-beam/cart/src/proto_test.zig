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
//!
//! M3 (file mode): each badge also has a drive pair (lib/cart_files.zig
//! `Fake`): a file write parks it 50-300 ms like a flash sector, a commit
//! 150 ms. Each badge advertises its `Caps` in its link HELLO, and the
//! sender plans the offer from what its partner advertised (`proto.plan`,
//! as main.zig does). A badge can instead run M1's machines
//! (proto_v1.zig, a frozen copy of the M1 protocol) and advertise nothing,
//! to check that M1 and M3 carts still beam slot images to each other.
const std = @import("std");
const slot = @import("beam_slot");
const cart_files = @import("cart_files");
const link_host = @import("link_host");
const link = link_host.link;
const virtual = link_host.virtual;
const proto = @import("proto.zig");
const proto_v1 = @import("proto_v1.zig");
const src_mod = @import("source.zig");

const pong_uf2 = @embedFile("pong_uf2");
const pong_slot = @embedFile("pong_slot");
/// A real larger cart: snouty-boy.uf2 as built from main (501 blocks,
/// a 125 KB image).
const boy_uf2 = @embedFile("boy_uf2");

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
    /// The firmware takes slot images (os_flags bits 2 and 5).
    can_receive: bool = true,
    /// The firmware writes cart files (os_flags bit 6).
    takes_files: bool = true,
    /// Runs M1's machines (proto_v1.zig) and advertises nothing.
    v1: bool = false,
    /// Flash writes left before the power goes (null: never).
    power_after: ?u32 = null,
    dead: bool = false,
    stall_min_us: u64 = 50_000,
    stall_max_us: u64 = 300_000,
    flash_ops: u32 = 0,
    session: u32 = 0,
    sender: Sender = .{},
    receiver: Receiver = .{},
    v1_sender: V1Sender = .{},
    v1_receiver: V1Receiver = .{},
    /// SYCLBADGE and SYCLEXTRA (`reset` in `Pair.init`).
    drive: cart_files.Fake = undefined,

    fn random(b: *Badge) u32 {
        var x = b.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        b.rng = x;
        return x;
    }

    /// What this badge advertises in its HELLO.
    fn caps(b: *const Badge) proto.Caps {
        return .{ .slot = b.can_receive, .file = b.takes_files };
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
    pub fn takes_files(io: *Io) bool {
        return io.b.takes_files;
    }
    pub fn file_stat(io: *Io, volume: u1) cart_files.Error!cart_files.Stat {
        return io.b.drive.stat(volume);
    }
    /// `create` reserves in RAM: a millisecond.
    pub fn file_create(io: *Io, volume: u1, name: []const u8, size: u32) cart_files.Error!void {
        io.b.now += 1_000;
        return io.b.drive.create(volume, name, size);
    }
    /// A 4 KB write: up to a sector erase and program, 50-300 ms.
    pub fn file_write(io: *Io, offset: u32, data: []const u8) cart_files.Error!void {
        io.b.stall(100);
        return io.b.drive.write(offset, data);
    }
    /// FAT 1, FAT 2, the directory: three sectors.
    pub fn file_commit(io: *Io) cart_files.Error!void {
        io.b.now += 150_000;
        return io.b.drive.commit();
    }
    pub fn file_abort(io: *Io) void {
        io.b.drive.abort();
    }
};

const Src = src_mod.Source(slot.SliceFile);
const Sender = proto.Sender(Io, Src);
const Receiver = proto.Receiver(Io);
const Offer = Sender.Offer;
const V1Sender = proto_v1.Sender(Io, Src);
const V1Receiver = proto_v1.Receiver(Io);

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
            p.b[i].drive.reset();
            p.b[i].now += i * 3_333;
            p.b[i].next_at = p.b[i].now;
            p.b[i].frame_start = p.b[i].now;
            p.wire.clocks[i] = &p.b[i].now;
            p.advertise(i);
        }
    }

    /// Put badge `i`'s capabilities in its HELLO (before `connect`).
    fn advertise(p: *Pair, i: usize) void {
        const b = &p.b[i];
        b.link.app_version = if (b.v1) 0 else b.caps().nibble();
    }

    /// Badge `i` runs M1's machines (before `connect`).
    fn make_v1(p: *Pair, i: usize) void {
        p.b[i].v1 = true;
        p.advertise(i);
    }

    fn io(p: *Pair, i: usize) Io {
        return .{ .b = &p.b[i] };
    }

    /// What badge `i`'s partner advertised.
    fn partner_caps(p: *const Pair, i: usize) proto.Caps {
        return proto.Caps.of_partner(p.b[i].link.partner_version);
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
            if (b.v1) {
                if (to_sender(bytes[0])) b.v1_sender.handle(&bio, bytes);
                if (to_receiver(bytes[0])) b.v1_receiver.handle(&bio, bytes);
            } else {
                if (to_sender(bytes[0])) b.sender.handle(&bio, bytes);
                if (to_receiver(bytes[0])) b.receiver.handle(&bio, bytes);
            }
        }
        if (!b.link.connected() or b.link.session != b.session) {
            if (b.v1) {
                b.v1_sender.link_lost();
                b.v1_receiver.link_lost();
            } else {
                b.sender.link_lost();
                b.receiver.link_lost(&bio);
            }
            b.session = b.link.session;
        }
        if (b.v1) {
            b.v1_receiver.accepting = !b.v1_sender.active();
            b.v1_sender.tick(&bio);
            b.v1_receiver.tick(&bio);
        } else {
            b.receiver.accepting = !b.sender.active();
            b.sender.tick(&bio);
            b.receiver.tick(&bio);
        }
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
    const o = Offer.of_slot(&hb, u.info.image_len, .{ .uf2 = u });
    p.b[from].sender.start(&bio, &o, null, xfer);
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
    const o = Offer.of_slot(&hb, h.image_len, .{ .uf2 = u });
    p.b[0].sender.start(&bio, &o, null, 5);
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
    const o = Offer.of_slot(hb, h.image_len, .{ .flat = p.b[1].area[slot.image_offset..][0..h.image_len] });
    p.b[1].sender.start(&bio, &o, null, 72);
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
    const o = Offer.of_slot(&hb, u.info.image_len, .{ .uf2 = u });
    p.b[0].sender.start(&bio, &o, null, 3);
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

// ---- M3: received carts as files ----------------------------------------------------

/// The receiver's slot capacity (a fallback must fit it).
const capacity = slot.capacity(area_bytes);

/// What main.zig prepares for a drive file: the plan for the partner's
/// caps, the file offer (name, size, whole-file CRC-32) and, when the cart
/// has a slot image the partner may take, the slot offer (alone, or as the
/// file offer's fallback).
const Prepared = struct { plan: proto.Plan, offer: Offer, fallback: ?Offer };

fn prepare(caps: proto.Caps, bytes: []const u8, name: []const u8) ?Prepared {
    const opened = slot.Uf2(slot.SliceFile).open(.{ .bytes = bytes });
    const slot_ok = if (opened) |u| u.info.image_len <= capacity else |_| false;
    const file_ok = if (opened) |_| true else |e| e == error.Xip or e == error.StraddlesIpc;
    const pl = proto.plan(caps, file_ok, slot_ok) orelse return null;
    var slot_offer: ?Offer = null;
    if (pl.kind == .slot or pl.fallback) {
        const u = opened catch unreachable;
        var st: slot.CrcState = .{};
        var scratch: [slot.sector_size]u8 = undefined;
        while (!u.crc_step(&st, &scratch)) {}
        const hb = u.header(st.final(), name).encode();
        slot_offer = Offer.of_slot(&hb, u.info.image_len, .{ .uf2 = u });
    }
    if (pl.kind == .slot) return .{ .plan = pl, .offer = slot_offer.?, .fallback = null };
    const h = proto.FileHeader.init(@intCast(bytes.len), slot.crc32(bytes), name);
    return .{ .plan = pl, .offer = Offer.of_file(&h, .{ .file = .{ .bytes = bytes } }), .fallback = slot_offer };
}

/// Badge `from` plans an offer of `bytes` (a UF2 named `name`) from what
/// its partner advertised and starts sending; the kind it chose.
fn send_cart(p: *Pair, from: usize, bytes: []const u8, name: []const u8, xfer: u8) !proto.Kind {
    const prep = prepare(p.partner_caps(from), bytes, name) orelse return error.NothingToOffer;
    var bio = p.io(from);
    p.b[from].sender.start(&bio, &prep.offer, if (prep.fallback) |*f| f else null, xfer);
    return prep.plan.kind;
}

fn sender_done(p: *Pair) bool {
    return p.b[0].sender.state == .finished;
}

/// A synthetic XIP cart: `n` blocks of pseudo-random bytes at the cart
/// flash window (0x101C0000), RP2350 family.
fn xip_uf2(comptime n: u32) *const [n * 512]u8 {
    const S = struct {
        var uf2: [n * 512]u8 = undefined;
    };
    var rng: u32 = 0xC0FFEE;
    for (0..n) |i| {
        const b = S.uf2[i * 512 ..][0..512];
        @memset(b, 0);
        std.mem.writeInt(u32, b[0..4], 0x0A324655, .little);
        std.mem.writeInt(u32, b[4..8], 0x9E5D5157, .little);
        std.mem.writeInt(u32, b[8..12], 0x2000, .little);
        std.mem.writeInt(u32, b[12..16], slot.cart_xip.start + @as(u32, @intCast(i)) * 256, .little);
        std.mem.writeInt(u32, b[16..20], 256, .little);
        std.mem.writeInt(u32, b[20..24], @intCast(i), .little);
        std.mem.writeInt(u32, b[24..28], n, .little);
        std.mem.writeInt(u32, b[28..32], 0xE48BFF59, .little);
        for (b[32..288]) |*x| {
            rng ^= rng << 13;
            rng ^= rng >> 17;
            rng ^= rng << 5;
            x.* = @truncate(rng);
        }
        std.mem.writeInt(u32, b[508..512], 0x0AB16F30, .little);
    }
    return &S.uf2;
}

fn expect_erased(area: []const u8) !void {
    for (area) |x| if (x != 0xFF) return error.TestUnexpectedResult;
}

/// No file open and none added: the drive is as it was.
fn expect_drive_unchanged(d: *const cart_files.Fake, files_before: u32) !void {
    try std.testing.expect(d.open == null);
    try std.testing.expectEqual(files_before, d.file_count);
    try std.testing.expectEqual(@as(u32, 0), d.commits);
}

const FileRun = struct {
    kind: virtual.Kind = .crossed,
    seed: u32,
    cap: u16 = 256,
    drop_every: u32 = 0,
    gap_us: u64 = 800,
    stall_min_us: u64 = 50_000,
    stall_max_us: u64 = 300_000,
};

/// Badge 0 sends `bytes` as a file to badge 1, which accepts: the file on
/// its SYCLBADGE is byte-identical, its slot untouched.
fn file_transfer(r: FileRun, bytes: []const u8, name: []const u8) !Outcome {
    const p = try new_pair(r.kind, r.seed, r.cap);
    defer std.testing.allocator.destroy(p);
    try p.connect();
    for (&p.b) |*b| {
        b.drop_every = r.drop_every;
        b.gap_us = r.gap_us;
        b.stall_min_us = r.stall_min_us;
        b.stall_max_us = r.stall_max_us;
    }
    try std.testing.expectEqual(proto.Kind.file, try send_cart(p, 0, bytes, name, @intCast(1 + r.seed % 250)));
    _ = try p.run_until(5_000_000, asking);
    try std.testing.expectEqual(proto.Kind.file, p.b[1].receiver.kind);
    try std.testing.expectEqualStrings(name, p.b[1].receiver.name());
    try std.testing.expectEqual(@as(u1, 0), p.b[1].receiver.volume);
    accept(p, 1);
    const took = try p.run_until(120_000_000, both_done);
    try std.testing.expectEqual(proto.SendResult.sent, p.b[0].sender.result);
    try std.testing.expectEqual(proto.RecvResult.received, p.b[1].receiver.result);
    const d = &p.b[1].drive;
    try std.testing.expectEqualSlices(u8, bytes, d.contents(0, name).?);
    try std.testing.expectEqual(@as(u32, 1), d.commits);
    try std.testing.expectEqual(@as(u32, 0), d.aborts);
    try std.testing.expect(d.open == null);
    try expect_erased(&p.b[1].area);
    try std.testing.expectEqual(@as(u32, 0), p.b[0].drive.file_count);
    return .{ .took = took, .overflow = p.wire.overflow, .naks = p.b[0].sender.stats.naks, .resends = p.b[0].sender.stats.resends };
}

test "file: pong's UF2 arrives byte-identical on SYCLBADGE, both cable kinds, many seeds" {
    var t: Tally = .{};
    for ([_]virtual.Kind{ .crossed, .straight }) |kind| {
        var seed: u32 = 400;
        while (seed < 408) : (seed += 1) t.add(try file_transfer(.{ .kind = kind, .seed = seed }, pong_uf2, "snouty-pong.uf2"));
    }
    t.print("file: pong UF2 (47.5 KB), DMA ring, 50-300 ms writes");
    try std.testing.expect(t.worst < 6_000_000);
    try std.testing.expectEqual(@as(u32, 0), t.overflow + t.naks + t.resends);
}

test "file: snouty-boy's UF2 (250.5 KB) byte-identical; typical and slow drives" {
    var typical: Tally = .{};
    var seed: u32 = 420;
    while (seed < 422) : (seed += 1) typical.add(try file_transfer(.{ .kind = .crossed, .seed = seed, .stall_min_us = 50_000, .stall_max_us = 60_000 }, boy_uf2, "snouty-boy.uf2"));
    typical.print("file: snouty-boy UF2, typical writes (50-60 ms per 4 KB)");
    if (report) std.debug.print("  = {d} KB/s\n", .{boy_uf2.len * 1000 / typical.worst});
    // PLAN.md M3: about 9 s.
    try std.testing.expect(typical.worst < 12_000_000);
    var slow: Tally = .{};
    slow.add(try file_transfer(.{ .kind = .straight, .seed = 423 }, boy_uf2, "snouty-boy.uf2"));
    slow.print("file: snouty-boy UF2, 50-300 ms writes");
}

test "file: 1 in 50 packets dropped both ways, and the 8-byte FIFO, still complete" {
    for ([_]virtual.Kind{ .crossed, .straight }) |kind| {
        var t: Tally = .{};
        var seed: u32 = 430;
        while (seed < 436) : (seed += 1) t.add(try file_transfer(.{ .kind = kind, .seed = seed, .drop_every = 50 }, pong_uf2, "snouty-pong.uf2"));
        t.print("file: pong UF2, 1 in 50 packets dropped");
        try std.testing.expect(t.naks + t.resends > 0);
    }
    var t: Tally = .{};
    var seed: u32 = 440;
    while (seed < 442) : (seed += 1) t.add(try file_transfer(.{ .seed = seed, .cap = 8, .gap_us = 2_700 }, pong_uf2, "snouty-pong.uf2"));
    t.print("file: pong UF2, 8-byte FIFO, 2.7 ms gap");
    try std.testing.expect(t.overflow > 0);
}

test "file: an XIP cart goes as a file, byte-identical (a slot could never hold it)" {
    const xip = xip_uf2(200);
    try std.testing.expectError(error.Xip, slot.Uf2(slot.SliceFile).open(.{ .bytes = xip }));
    _ = try file_transfer(.{ .seed = 450 }, xip, "snouty-zero-xip.uf2");
}

/// A pair, connected, with badge 0 offering `bytes` as `name`; returns
/// once badge 1 is asking its owner or has refused.
fn offer_file(seed: u32, setup: *const fn (*Pair) void, bytes: []const u8, name: []const u8) !*Pair {
    const p = try new_pair(.crossed, seed, 256);
    setup(p);
    try p.connect();
    _ = try send_cart(p, 0, bytes, name, @intCast(1 + seed % 250));
    _ = try p.run_until(10_000_000, struct {
        fn f(q: *Pair) bool {
            return q.b[1].receiver.state == .asking or q.b[0].sender.state == .finished;
        }
    }.f);
    return p;
}

fn no_setup(_: *Pair) void {}

/// Accept and run to the end: the received file's name and drive.
fn accept_file(p: *Pair) !void {
    accept(p, 1);
    _ = try p.run_until(60_000_000, both_done);
    try std.testing.expectEqual(proto.SendResult.sent, p.b[0].sender.result);
    try std.testing.expectEqual(proto.RecvResult.received, p.b[1].receiver.result);
}

test "file: a taken name becomes name-2, name-3 (FAT names ignore case)" {
    const p = try offer_file(460, struct {
        fn f(q: *Pair) void {
            q.b[1].drive.preload(0, "Snouty-Pong.UF2", 48640);
            q.b[1].drive.preload(0, "SNOUTY-PONG-2.uf2", 48640);
        }
    }.f, pong_uf2, "snouty-pong.uf2");
    defer std.testing.allocator.destroy(p);
    // The offer shows the offered name; the final one is picked on accept.
    try std.testing.expectEqualStrings("snouty-pong.uf2", p.b[1].receiver.name());
    try accept_file(p);
    try std.testing.expectEqualStrings("snouty-pong-3.uf2", p.b[1].receiver.name());
    try std.testing.expectEqualSlices(u8, pong_uf2, p.b[1].drive.contents(0, "snouty-pong-3.uf2").?);
    try std.testing.expectEqual(@as(u32, 3), p.b[1].drive.file_count);
}

test "file: SYCLBADGE full, or out of root entries, sends it to SYCLEXTRA" {
    {
        const p = try offer_file(470, struct {
            fn f(q: *Pair) void {
                q.b[1].drive.volumes[0].free_bytes = 40 * 1024;
            }
        }.f, pong_uf2, "snouty-pong.uf2");
        defer std.testing.allocator.destroy(p);
        try std.testing.expectEqual(@as(u1, 1), p.b[1].receiver.volume);
        try accept_file(p);
        try std.testing.expectEqualSlices(u8, pong_uf2, p.b[1].drive.contents(1, "snouty-pong.uf2").?);
        try std.testing.expect(p.b[1].drive.find(0, "snouty-pong.uf2") == null);
    }
    {
        const p = try offer_file(471, struct {
            fn f(q: *Pair) void {
                q.b[1].drive.volumes[0].free_root_entries = 2;
            }
        }.f, pong_uf2, "snouty-pong.uf2");
        defer std.testing.allocator.destroy(p);
        try std.testing.expectEqual(@as(u1, 1), p.b[1].receiver.volume);
        try accept_file(p);
        try std.testing.expect(p.b[1].drive.contents(1, "snouty-pong.uf2") != null);
    }
    {
        // SYCLBADGE fills up between the offer and the owner's yes.
        const p = try offer_file(472, no_setup, pong_uf2, "snouty-pong.uf2");
        defer std.testing.allocator.destroy(p);
        try std.testing.expectEqual(@as(u1, 0), p.b[1].receiver.volume);
        p.b[1].drive.volumes[0].free_bytes = 1024;
        try accept_file(p);
        try std.testing.expectEqual(@as(u1, 1), p.b[1].receiver.volume);
        try std.testing.expect(p.b[1].drive.contents(1, "snouty-pong.uf2") != null);
    }
}

fn drives_full(q: *Pair) void {
    q.b[1].drive.volumes[0].free_bytes = 4096;
    q.b[1].drive.volumes[1].free_bytes = 4096;
}

test "file: both drives full falls back to the slot when the cart fits it" {
    const p = try offer_file(480, drives_full, boy_uf2, "snouty-boy.uf2");
    defer std.testing.allocator.destroy(p);
    // The file offer was refused; the slot offer is being asked.
    try std.testing.expect(p.b[0].sender.fell_back);
    try std.testing.expectEqual(proto.Kind.slot, p.b[0].sender.kind());
    try std.testing.expectEqual(proto.Kind.slot, p.b[1].receiver.kind);
    try std.testing.expectEqualStrings("snouty-boy", p.b[1].receiver.name());
    accept(p, 1);
    _ = try p.run_until(60_000_000, both_done);
    try std.testing.expectEqual(proto.SendResult.sent, p.b[0].sender.result);
    try std.testing.expectEqual(proto.RecvResult.received, p.b[1].receiver.result);
    try std.testing.expect(slot.launchable(&p.b[1].area));
    try expect_drive_unchanged(&p.b[1].drive, 0);
    // SYCLEXTRA absent (stock ext-flash geometry) and SYCLBADGE full: the same.
    const q = try offer_file(481, struct {
        fn f(r: *Pair) void {
            r.b[1].drive.volumes[0].free_bytes = 4096;
            r.b[1].drive.volumes[1].mounted = false;
        }
    }.f, boy_uf2, "snouty-boy.uf2");
    defer std.testing.allocator.destroy(q);
    try std.testing.expect(q.b[0].sender.fell_back and q.b[1].receiver.state == .asking);
}

test "file: no room anywhere: REJECT no space for an XIP cart, or a partner without a slot" {
    {
        const p = try offer_file(490, drives_full, xip_uf2(200), "snouty-zero-xip.uf2");
        defer std.testing.allocator.destroy(p);
        try std.testing.expectEqual(proto.SendResult{ .rejected = .no_space }, p.b[0].sender.result);
        try std.testing.expectEqual(proto.RecvResult{ .refused = .no_space }, p.b[1].receiver.result);
        try expect_drive_unchanged(&p.b[1].drive, 0);
        try expect_erased(&p.b[1].area);
    }
    {
        const p = try offer_file(491, struct {
            fn f(q: *Pair) void {
                drives_full(q);
                q.b[1].can_receive = false;
                q.advertise(1);
            }
        }.f, boy_uf2, "snouty-boy.uf2");
        defer std.testing.allocator.destroy(p);
        try std.testing.expect(!p.b[0].sender.fell_back);
        try std.testing.expectEqual(proto.SendResult{ .rejected = .no_space }, p.b[0].sender.result);
    }
}

test "file: a computer on USB at offer time: REJECT usb, nothing created" {
    const p = try offer_file(500, struct {
        fn f(q: *Pair) void {
            q.b[1].drive.usb_host = true;
        }
    }.f, boy_uf2, "snouty-boy.uf2");
    defer std.testing.allocator.destroy(p);
    try std.testing.expectEqual(proto.SendResult{ .rejected = .usb }, p.b[0].sender.result);
    try std.testing.expectEqual(proto.RecvResult{ .refused = .usb }, p.b[1].receiver.result);
    // No slot fallback either: the owner must unplug first.
    try std.testing.expect(!p.b[0].sender.fell_back);
    try std.testing.expectEqual(@as(u32, 0), p.b[1].drive.creates);
    try expect_erased(&p.b[1].area);
}

test "file: a computer attaching mid-transfer or before the commit: abort, no file" {
    {
        const p = try offer_file(510, struct {
            fn f(q: *Pair) void {
                q.b[1].drive.usb_after_writes = 3;
            }
        }.f, pong_uf2, "snouty-pong.uf2");
        defer std.testing.allocator.destroy(p);
        accept(p, 1);
        _ = try p.run_until(60_000_000, both_done);
        try std.testing.expectEqual(proto.SendResult{ .partner_aborted = .usb }, p.b[0].sender.result);
        try std.testing.expectEqual(proto.RecvResult{ .failed = .usb }, p.b[1].receiver.result);
        try expect_drive_unchanged(&p.b[1].drive, 0);
        try std.testing.expectEqual(@as(u32, 1), p.b[1].drive.aborts);
    }
    {
        // The host arrives with the last write: commit refuses.
        const p = try offer_file(511, struct {
            fn f(q: *Pair) void {
                q.b[1].drive.usb_after_writes = (pong_uf2.len + 4095) / 4096;
            }
        }.f, pong_uf2, "snouty-pong.uf2");
        defer std.testing.allocator.destroy(p);
        accept(p, 1);
        _ = try p.run_until(60_000_000, both_done);
        try std.testing.expectEqual(proto.SendResult{ .failed = .usb }, p.b[0].sender.result);
        try std.testing.expectEqual(proto.RecvResult{ .failed = .usb }, p.b[1].receiver.result);
        try expect_drive_unchanged(&p.b[1].drive, 0);
    }
}

test "file: a drive write or the commit failing: abort, no file" {
    {
        const p = try offer_file(520, struct {
            fn f(q: *Pair) void {
                q.b[1].drive.fail_write_at = 2;
            }
        }.f, pong_uf2, "snouty-pong.uf2");
        defer std.testing.allocator.destroy(p);
        accept(p, 1);
        _ = try p.run_until(60_000_000, both_done);
        try std.testing.expectEqual(proto.SendResult{ .partner_aborted = .drive }, p.b[0].sender.result);
        try std.testing.expectEqual(proto.RecvResult{ .failed = .drive }, p.b[1].receiver.result);
        try expect_drive_unchanged(&p.b[1].drive, 0);
    }
    {
        const p = try offer_file(521, struct {
            fn f(q: *Pair) void {
                q.b[1].drive.fail_commit = .io_error;
            }
        }.f, pong_uf2, "snouty-pong.uf2");
        defer std.testing.allocator.destroy(p);
        accept(p, 1);
        _ = try p.run_until(60_000_000, both_done);
        try std.testing.expectEqual(proto.SendResult{ .failed = .drive }, p.b[0].sender.result);
        try expect_drive_unchanged(&p.b[1].drive, 0);
    }
}

test "file: cable pulled mid-file: abort, no file, both idle; plugged back, it works" {
    const p = try offer_file(530, no_setup, boy_uf2, "snouty-boy.uf2");
    defer std.testing.allocator.destroy(p);
    accept(p, 1);
    _ = try p.run_until(60_000_000, struct {
        fn f(q: *Pair) bool {
            return q.b[1].receiver.written >= 40 * 1024;
        }
    }.f);
    try std.testing.expect(p.b[1].drive.open != null);
    p.cable.plugged = false;
    _ = try p.run_until(5_000_000, both_done);
    try std.testing.expectEqual(proto.SendResult.link_lost, p.b[0].sender.result);
    try std.testing.expectEqual(proto.RecvResult.link_lost, p.b[1].receiver.result);
    try expect_drive_unchanged(&p.b[1].drive, 0);
    try std.testing.expectEqual(@as(u32, 1), p.b[1].drive.aborts);
    try std.testing.expectEqual(@as(u32, 1280 * 1024), p.b[1].drive.volumes[0].free_bytes);
    p.b[0].sender.reset();
    p.b[1].receiver.reset();
    try std.testing.expectEqual(Sender.State.idle, p.b[0].sender.state);
    try std.testing.expectEqual(Receiver.State.idle, p.b[1].receiver.state);
    p.cable.plugged = true;
    try p.connect();
    _ = try send_cart(p, 0, pong_uf2, "snouty-pong.uf2", 99);
    _ = try p.run_until(5_000_000, asking);
    try accept_file(p);
    try std.testing.expectEqualSlices(u8, pong_uf2, p.b[1].drive.contents(0, "snouty-pong.uf2").?);
}

test "file: sender cancel, receiver cancel and decline leave no file" {
    {
        const p = try offer_file(540, no_setup, boy_uf2, "snouty-boy.uf2");
        defer std.testing.allocator.destroy(p);
        accept(p, 1);
        _ = try p.run_until(60_000_000, struct {
            fn f(q: *Pair) bool {
                return q.b[1].receiver.written >= 8192;
            }
        }.f);
        var bio = p.io(0);
        p.b[0].sender.cancel(&bio);
        _ = try p.run_until(5_000_000, both_done);
        try std.testing.expectEqual(proto.SendResult.cancelled, p.b[0].sender.result);
        try std.testing.expectEqual(proto.RecvResult{ .sender_aborted = .cancelled }, p.b[1].receiver.result);
        try expect_drive_unchanged(&p.b[1].drive, 0);
        try std.testing.expectEqual(@as(u32, 1), p.b[1].drive.aborts);
    }
    {
        const p = try offer_file(541, no_setup, boy_uf2, "snouty-boy.uf2");
        defer std.testing.allocator.destroy(p);
        accept(p, 1);
        _ = try p.run_until(60_000_000, struct {
            fn f(q: *Pair) bool {
                return q.b[1].receiver.written >= 8192;
            }
        }.f);
        var bio = p.io(1);
        p.b[1].receiver.cancel(&bio);
        _ = try p.run_until(5_000_000, both_done);
        try std.testing.expectEqual(proto.SendResult{ .partner_aborted = .cancelled }, p.b[0].sender.result);
        try expect_drive_unchanged(&p.b[1].drive, 0);
    }
    {
        const p = try offer_file(542, no_setup, pong_uf2, "snouty-pong.uf2");
        defer std.testing.allocator.destroy(p);
        var bio = p.io(1);
        p.b[1].receiver.decline(&bio);
        _ = try p.run_until(5_000_000, both_done);
        try std.testing.expectEqual(proto.SendResult{ .rejected = .declined }, p.b[0].sender.result);
        try std.testing.expectEqual(@as(u32, 0), p.b[1].drive.creates);
    }
}

test "negotiation: a receiver without cart files gets a slot image; one with neither gets nothing" {
    {
        // Fork firmware with cart transfer but not cart files.
        const p = try offer_file(550, struct {
            fn f(q: *Pair) void {
                q.b[1].takes_files = false;
                q.advertise(1);
            }
        }.f, pong_uf2, "snouty-pong.uf2");
        defer std.testing.allocator.destroy(p);
        try std.testing.expectEqual(proto.Caps{ .slot = true }, p.partner_caps(0));
        try std.testing.expectEqual(proto.Kind.slot, p.b[0].sender.kind());
        accept(p, 1);
        _ = try p.run_until(60_000_000, both_done);
        try expect_pong_slot(&p.b[1].area);
        try expect_drive_unchanged(&p.b[1].drive, 0);
    }
    {
        // Stock firmware (or a send-only build): nothing to offer, and an
        // offer made anyway is refused.
        const p = try new_pair(.straight, 551, 256);
        defer std.testing.allocator.destroy(p);
        p.b[1].takes_files = false;
        p.b[1].can_receive = false;
        p.advertise(1);
        try p.connect();
        try std.testing.expectEqual(proto.Caps{}, p.partner_caps(0));
        try std.testing.expectError(error.NothingToOffer, send_cart(p, 0, pong_uf2, "snouty-pong.uf2", 7));
        try send_pong(p, 0, 8);
        _ = try p.run_until(5_000_000, sender_done);
        try std.testing.expectEqual(proto.SendResult{ .rejected = .cannot_receive }, p.b[0].sender.result);
    }
}

/// Badge 0 (M1 machines) sends pong's slot image.
fn v1_send_pong(p: *Pair, xfer: u8) !void {
    const u = try pong();
    var st: slot.CrcState = .{};
    var scratch: [slot.sector_size]u8 = undefined;
    while (!u.crc_step(&st, &scratch)) {}
    const hb = u.header(st.final(), "snouty-pong.uf2").encode();
    var bio = p.io(0);
    p.b[0].v1_sender.start(&bio, &hb, u.info.image_len, .{ .uf2 = u }, xfer);
}

test "v1 interop: an M1 sender to an M3 receiver, slot mode" {
    var seed: u32 = 560;
    while (seed < 564) : (seed += 1) {
        const p = try new_pair(if (seed % 2 == 0) .crossed else .straight, seed, 256);
        defer std.testing.allocator.destroy(p);
        p.make_v1(0);
        if (seed == 563) for (&p.b) |*b| {
            b.drop_every = 50;
        };
        try p.connect();
        // The M3 badge sees an M1 partner: capabilities unknown.
        try std.testing.expect(!p.partner_caps(1).v2);
        try v1_send_pong(p, @intCast(seed % 200 + 1));
        _ = try p.run_until(5_000_000, asking);
        try std.testing.expectEqual(proto.Kind.slot, p.b[1].receiver.kind);
        accept(p, 1);
        _ = try p.run_until(60_000_000, struct {
            fn f(q: *Pair) bool {
                return q.b[0].v1_sender.state == .finished and q.b[1].receiver.state == .finished;
            }
        }.f);
        try std.testing.expectEqual(proto_v1.SendResult.sent, p.b[0].v1_sender.result);
        try std.testing.expectEqual(proto.RecvResult.received, p.b[1].receiver.result);
        try expect_pong_slot(&p.b[1].area);
        try expect_drive_unchanged(&p.b[1].drive, 0);
    }
}

test "v1 interop: an M3 sender to an M1 receiver plans a slot image; XIP has nothing to offer" {
    var seed: u32 = 570;
    while (seed < 574) : (seed += 1) {
        const p = try new_pair(if (seed % 2 == 0) .crossed else .straight, seed, 256);
        defer std.testing.allocator.destroy(p);
        p.make_v1(1);
        if (seed == 573) for (&p.b) |*b| {
            b.drop_every = 50;
        };
        try p.connect();
        try std.testing.expect(!p.partner_caps(0).v2);
        try std.testing.expectError(error.NothingToOffer, send_cart(p, 0, xip_uf2(200), "x.uf2", 1));
        try std.testing.expectEqual(proto.Kind.slot, try send_cart(p, 0, pong_uf2, "snouty-pong.uf2", @intCast(seed % 200 + 2)));
        _ = try p.run_until(5_000_000, struct {
            fn f(q: *Pair) bool {
                return q.b[1].v1_receiver.state == .asking;
            }
        }.f);
        var bio = p.io(1);
        p.b[1].v1_receiver.accept(&bio);
        _ = try p.run_until(60_000_000, struct {
            fn f(q: *Pair) bool {
                return q.b[0].sender.state == .finished and q.b[1].v1_receiver.state == .finished;
            }
        }.f);
        try std.testing.expectEqual(proto.SendResult.sent, p.b[0].sender.result);
        try std.testing.expectEqual(proto_v1.RecvResult.received, p.b[1].v1_receiver.result);
        try expect_pong_slot(&p.b[1].area);
    }
}

test "file: a stale transfer's packets are ignored mid-file" {
    const p = try offer_file(580, no_setup, pong_uf2, "snouty-pong.uf2");
    defer std.testing.allocator.destroy(p);
    accept(p, 1);
    _ = try p.run_until(60_000_000, struct {
        fn f(q: *Pair) bool {
            return q.b[1].receiver.written >= 4096;
        }
    }.f);
    var rio = p.io(1);
    const stale = [_][]const u8{
        &.{ proto.T.block, 80, 1, 0, 0, 16, 1, 2, 3, 4, 0 },
        &.{ proto.T.data, 80, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8 },
        &.{ proto.T.abort, 80, 1 },
    };
    for (stale) |pk| p.b[1].receiver.handle(&rio, pk);
    try std.testing.expectEqual(Receiver.State.receiving, p.b[1].receiver.state);
    try std.testing.expect(p.b[1].drive.open != null);
    _ = try p.run_until(60_000_000, both_done);
    try std.testing.expectEqualSlices(u8, pong_uf2, p.b[1].drive.contents(0, "snouty-pong.uf2").?);
}

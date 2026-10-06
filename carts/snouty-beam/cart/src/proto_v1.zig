//! TEST ONLY: a frozen copy of Snouty Beam M1's proto.zig (protocol v1, as
//! merged to main at e5e46001), so proto_test.zig can run today's M3
//! machines against an M1 badge on the virtual cable: an M1 sender to an
//! M3 receiver and the reverse must still work in slot mode. Never edit it
//! except to keep it compiling; the cart does not import it.
//!
//! Snouty Beam's transfer protocol (PLAN.md "Protocol"): pure state
//! machines, no cart API, no clock of their own.
//!
//! `Sender(Io, Src)` offers a slot header and streams the image, 4 KB
//! blocks stop and wait; `Receiver(Io)` takes the header, asks its owner
//! (`accept` / `decline`), writes each block into the slot area as it
//! arrives and the header last (fork/CART_TRANSFER.md "Write order").
//! Both get DATA packets from the link through `handle` and run timers
//! and sends from `tick`; the cart (main.zig) or a test harness
//! (proto_test.zig) pumps them.
//!
//! `Io` gives `now() u64` (microseconds; read again after a flash call,
//! which parks the core), `send(bytes) bool` (a link DATA packet,
//! <= 12 bytes) and, for the receiver, `erase(area_offset) bool` (one 4 KB
//! sector), `program(area_offset, data) bool` (<= 4 KB, 256-byte
//! multiple), `read(area_offset, dst)` (the slot area as memory),
//! `area_size() u32` and `can_receive() bool`. `Src` gives
//! `read(image_offset, dst)`.
//!
//! Packets (first byte type, second `xfer`, the sender's transfer id):
//!   OFFER  01 x 96          a transfer starts, the header follows as block FFFF
//!   ACCEPT 03 x 0           the owner said yes (the slot's header is erased)
//!   REJECT 04 x reason
//!   DATA   10 x seq16 b[..8] bytes seq*8.. of the current block
//!   BLOCK  11 x blk16 len16 crc32 flags   the block's packets follow
//!                           (flags bit 0: all zero, no DATA follows)
//!   ACK    12 x blk16       block received (image blocks: and written)
//!   NAK    13 x blk16 seq16 resend from seq
//!   DONE   14 x status      image read back and header written (or not)
//!   ABORT  1F x reason      either side gives up
//! Integers little-endian.
const std = @import("std");
const slot = @import("beam_slot");

pub const T = struct {
    pub const offer: u8 = 0x01;
    pub const accept: u8 = 0x03;
    pub const reject: u8 = 0x04;
    pub const data: u8 = 0x10;
    pub const block: u8 = 0x11;
    pub const ack: u8 = 0x12;
    pub const nak: u8 = 0x13;
    pub const done: u8 = 0x14;
    pub const abort: u8 = 0x1F;
};

/// The block number of the header.
pub const header_block: u16 = 0xFFFF;
pub const block_size: u32 = slot.sector_size;
pub const data_bytes: u32 = 8;
const flag_zero: u8 = 1;

pub const Reject = enum(u8) { declined = 1, too_big = 2, cannot_receive = 3, busy = 4, bad_header = 5, _ };
pub const AbortReason = enum(u8) { cancelled = 1, no_answer = 2, flash = 3, _ };
pub const DoneStatus = enum(u8) { ok = 0, crc = 1, flash = 2, _ };

/// Timing in microseconds, adjustable in one place.
pub const timing = struct {
    /// The sender resends a block after this much silence (the receiver's
    /// core may be parked ~300 ms in a flash write)...
    pub const resend_after: u64 = 600_000;
    /// ...this many times, then gives up.
    pub const tries: u8 = 5;
    /// The receiver NAKs a block whose data stopped this long ago...
    pub const nak_gap: u64 = 5_000;
    /// ...and repeats the same NAK at most this often.
    pub const nak_repeat: u64 = 50_000;
    /// The owner has this long to answer an offer (then: declined).
    pub const offer_timeout: u64 = 30_000_000;
    /// The sender waits this long for the answer; it repeats OFFER while
    /// it waits so a lost ACCEPT / REJECT is answered again.
    pub const answer_timeout: u64 = 35_000_000;
    pub const offer_repeat: u64 = 2_000_000;
    /// Slot readback per `tick` while verifying.
    pub const verify_chunk: u32 = 4096;
};

fn put16(b: []u8, v: u16) void {
    std.mem.writeInt(u16, b[0..2], v, .little);
}
fn put32(b: []u8, v: u32) void {
    std.mem.writeInt(u32, b[0..4], v, .little);
}
fn get16(b: []const u8) u16 {
    return std.mem.readInt(u16, b[0..2], .little);
}
fn get32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .little);
}

fn all_zero(bytes: []const u8) bool {
    for (bytes) |b| if (b != 0) return false;
    return true;
}

/// Counters for the screens and the tests.
pub const Stats = struct {
    blocks_sent: u32 = 0,
    resends: u32 = 0,
    naks: u32 = 0,
    data_packets: u32 = 0,
};

// ---- sender ----------------------------------------------------------------------

pub const SendResult = union(enum) {
    none,
    sent,
    rejected: Reject,
    /// No answer after `timing.tries` resends, or none to the offer.
    no_answer,
    /// The receiver gave up (`AbortReason`).
    partner_aborted: AbortReason,
    /// The receiver's readback or header write failed.
    failed: DoneStatus,
    cancelled,
    link_lost,
};

pub fn Sender(comptime Io: type, comptime Src: type) type {
    return struct {
        const Self = @This();

        pub const State = enum { idle, offering, waiting_answer, sending, finishing, finished };

        state: State = .idle,
        result: SendResult = .none,
        xfer: u8 = 0,
        header: [slot.header_size]u8 = undefined,
        image_len: u32 = 0,
        blocks: u16 = 0,
        /// Current block (`header_block` while offering).
        block: u16 = 0,
        buf: [block_size]u8 = undefined,
        len: u32 = 0,
        crc: u32 = 0,
        zero: bool = false,
        /// Next DATA packet to send, and the count in this block.
        pos: u16 = 0,
        packets: u16 = 0,
        /// The BLOCK packet (and before the header block: OFFER) is due.
        announce: bool = false,
        tries: u8 = 0,
        /// Last time we sent or heard anything for this block.
        quiet_since: u64 = 0,
        started_at: u64 = 0,
        offered_at: u64 = 0,
        last_offer: u64 = 0,
        /// Image bytes the receiver has acknowledged.
        acked: u32 = 0,
        stats: Stats = .{},
        src: Src = undefined,

        /// Start offering: `header` is the slot header the receiver will
        /// write, `src` reads the image. `xfer` must differ from the last
        /// transfer's (the cart takes a random non-zero byte).
        pub fn start(self: *Self, io: *Io, header: *const [slot.header_size]u8, image_len: u32, src: Src, xfer: u8) void {
            const now = io.now();
            self.* = .{
                .state = .offering,
                .xfer = xfer,
                .header = header.*,
                .image_len = image_len,
                .blocks = @intCast((image_len + block_size - 1) / block_size),
                .src = src,
                .started_at = now,
                .offered_at = now,
            };
            self.begin_block(now, header_block);
        }

        pub fn active(self: *const Self) bool {
            return self.state != .idle and self.state != .finished;
        }

        /// 0..1000 of the image acknowledged.
        pub fn permille(self: *const Self) u32 {
            if (self.image_len == 0) return 0;
            return @intCast(@as(u64, self.acked) * 1000 / self.image_len);
        }

        fn begin_block(self: *Self, now: u64, k: u16) void {
            self.block = k;
            if (k == header_block) {
                self.len = slot.header_size;
                @memcpy(self.buf[0..slot.header_size], &self.header);
            } else {
                const off = @as(u32, k) * block_size;
                self.len = @min(block_size, self.image_len - off);
                self.src.read(off, self.buf[0..self.len]);
            }
            self.crc = slot.crc32(self.buf[0..self.len]);
            self.zero = k != header_block and all_zero(self.buf[0..self.len]);
            self.packets = if (self.zero) 0 else @intCast((self.len + data_bytes - 1) / data_bytes);
            self.pos = 0;
            self.announce = true;
            self.tries = 0;
            self.quiet_since = now;
        }

        fn finish(self: *Self, r: SendResult) void {
            self.state = .finished;
            self.result = r;
        }

        /// Hold B: tell the receiver and stop.
        pub fn cancel(self: *Self, io: *Io) void {
            if (!self.active()) return;
            _ = io.send(&.{ T.abort, self.xfer, @backingInt(AbortReason.cancelled) });
            self.finish(.cancelled);
        }

        /// The link dropped or restarted (`session` changed).
        pub fn link_lost(self: *Self) void {
            if (self.active()) self.finish(.link_lost);
        }

        /// Back to idle once the cart has shown the result.
        pub fn reset(self: *Self) void {
            if (!self.active()) {
                self.state = .idle;
                self.result = .none;
            }
        }

        /// Send what is due (at most one packet) and run the timers.
        pub fn tick(self: *Self, io: *Io) void {
            const now = io.now();
            switch (self.state) {
                .idle, .finished => return,
                .waiting_answer => {
                    if (now -% self.offered_at >= timing.answer_timeout) {
                        _ = io.send(&.{ T.abort, self.xfer, @backingInt(AbortReason.no_answer) });
                        return self.finish(.no_answer);
                    }
                    if (now -% self.last_offer >= timing.offer_repeat) {
                        self.last_offer = now;
                        _ = io.send(&.{ T.offer, self.xfer, slot.header_size });
                    }
                    return;
                },
                .offering, .sending, .finishing => {},
            }
            if (now -% self.quiet_since >= timing.resend_after) {
                self.tries += 1;
                if (self.tries > timing.tries) {
                    _ = io.send(&.{ T.abort, self.xfer, @backingInt(AbortReason.no_answer) });
                    return self.finish(.no_answer);
                }
                self.stats.resends += 1;
                self.pos = 0;
                self.announce = true;
                self.quiet_since = now;
            }
            if (self.announce) {
                self.announce = false;
                if (self.block == header_block and self.pos == 0) {
                    self.last_offer = now;
                    _ = io.send(&.{ T.offer, self.xfer, slot.header_size });
                }
                var p: [12]u8 = undefined;
                p[0] = T.block;
                p[1] = self.xfer;
                put16(p[2..], self.block);
                put16(p[4..], @intCast(self.len));
                put32(p[6..], self.crc);
                p[10] = if (self.zero) flag_zero else 0;
                _ = io.send(p[0..11]);
                self.quiet_since = now;
                return;
            }
            if (self.pos < self.packets) {
                const off = @as(u32, self.pos) * data_bytes;
                const n = @min(data_bytes, self.len - off);
                var p: [4 + data_bytes]u8 = undefined;
                p[0] = T.data;
                p[1] = self.xfer;
                put16(p[2..], self.pos);
                @memcpy(p[4..][0..n], self.buf[off..][0..n]);
                if (io.send(p[0 .. 4 + n])) {
                    self.pos += 1;
                    self.stats.data_packets += 1;
                    self.quiet_since = now;
                }
            }
        }

        /// A DATA packet from the receiver.
        pub fn handle(self: *Self, io: *Io, p: []const u8) void {
            if (p.len < 2 or p[1] != self.xfer or !self.active()) return;
            const now = io.now();
            switch (p[0]) {
                T.ack => {
                    if (p.len < 4) return;
                    const k = get16(p[2..]);
                    if (k != self.block) return;
                    if (k == header_block) {
                        if (self.state == .offering) {
                            self.state = .waiting_answer;
                            self.offered_at = now;
                            self.last_offer = now;
                        }
                        return;
                    }
                    if (self.state != .sending) return;
                    self.acked += self.len;
                    self.stats.blocks_sent += 1;
                    if (k + 1 == self.blocks) {
                        // The last block: wait for DONE, resending this
                        // block on silence (the receiver repeats DONE).
                        self.state = .finishing;
                        self.quiet_since = now;
                        self.pos = self.packets;
                        self.tries = 0;
                    } else {
                        self.begin_block(now, k + 1);
                    }
                },
                T.nak => {
                    if (p.len < 6) return;
                    if (get16(p[2..]) != self.block) return;
                    if (self.state != .sending and self.state != .offering) return;
                    const from = get16(p[4..]);
                    self.stats.naks += 1;
                    self.pos = @min(from, self.packets);
                    self.announce = true;
                    self.quiet_since = now;
                },
                T.accept => {
                    if (self.state != .waiting_answer and self.state != .offering) return;
                    self.state = .sending;
                    self.begin_block(now, 0);
                },
                T.reject => {
                    if (p.len < 3) return;
                    if (self.state != .waiting_answer and self.state != .offering) return;
                    self.finish(.{ .rejected = @fromBackingInt(@intCast(p[2])) });
                },
                T.done => {
                    if (p.len < 3) return;
                    if (self.state != .finishing and !(self.state == .sending and self.block + 1 == self.blocks)) return;
                    const st: DoneStatus = @fromBackingInt(@intCast(p[2]));
                    if (st == .ok) {
                        self.acked = self.image_len;
                        self.finish(.sent);
                    } else {
                        self.finish(.{ .failed = st });
                    }
                },
                T.abort => {
                    if (p.len < 3) return;
                    self.finish(.{ .partner_aborted = @fromBackingInt(@intCast(p[2])) });
                },
                else => {},
            }
        }
    };
}

// ---- receiver --------------------------------------------------------------------

pub const RecvResult = union(enum) {
    none,
    /// The slot holds the new cart (its header written and read back).
    received,
    declined,
    /// The sender cancelled or gave up.
    sender_aborted: AbortReason,
    cancelled,
    link_lost,
    /// The image read back wrong (`crc`) or a flash call failed.
    failed: DoneStatus,
};

pub fn Receiver(comptime Io: type) type {
    return struct {
        const Self = @This();

        pub const State = enum { idle, header, asking, receiving, verifying, finished };

        state: State = .idle,
        result: RecvResult = .none,
        /// False while the cart is sending itself: offers get REJECT busy.
        accepting: bool = true,
        xfer: u8 = 0,
        /// The offered header, once complete and valid.
        header: slot.Header = undefined,
        header_bytes: [slot.header_size]u8 = undefined,
        blocks: u16 = 0,

        // The block being received.
        block: u16 = 0,
        have_block: bool = false,
        len: u32 = 0,
        crc: u32 = 0,
        packets: u16 = 0,
        next: u16 = 0,
        last_data: u64 = 0,
        nak_for: ?u16 = null,
        nak_at: u64 = 0,
        buf: [block_size]u8 = undefined,

        asked_at: u64 = 0,
        /// When we last said something the sender should answer with a
        /// BLOCK (ACCEPT or ACK): repeated after `timing.resend_after`.
        prompt_at: u64 = 0,
        prompts: u8 = 0,
        verify_at: u32 = 0,
        verify_crc: std.hash.Crc32 = .init(),
        /// Image bytes written.
        written: u32 = 0,

        /// The answer last given to a finished transfer, repeated when the
        /// sender asks again (its copy was lost).
        last_xfer: ?u8 = null,
        last_answer: [3]u8 = undefined,
        last_answer_len: u8 = 0,
        stats: Stats = .{},

        pub fn busy(self: *const Self) bool {
            return switch (self.state) {
                .header, .asking, .receiving, .verifying => true,
                .idle, .finished => false,
            };
        }

        /// The flash is being written: the slot no longer holds what it did.
        pub fn writing(self: *const Self) bool {
            return self.state == .receiving or self.state == .verifying;
        }

        pub fn permille(self: *const Self) u32 {
            if (!self.writing() or self.header.image_len == 0) return 0;
            if (self.state == .verifying) return 1000;
            return @intCast(@as(u64, self.written) * 1000 / self.header.image_len);
        }

        fn remember(self: *Self, bytes: []const u8) void {
            self.last_xfer = self.xfer;
            @memcpy(self.last_answer[0..bytes.len], bytes);
            self.last_answer_len = @intCast(bytes.len);
        }

        fn answer(self: *Self, io: *Io, bytes: []const u8) void {
            _ = io.send(bytes);
            self.remember(bytes);
        }

        fn finish(self: *Self, r: RecvResult) void {
            self.state = .finished;
            self.result = r;
        }

        pub fn reset(self: *Self) void {
            if (!self.busy()) {
                self.state = .idle;
                self.result = .none;
            }
        }

        /// The owner pressed A on the offer: erase the slot's header sector
        /// (from now on the slot is invalid), then ACCEPT.
        pub fn accept(self: *Self, io: *Io) void {
            if (self.state != .asking) return;
            if (!io.erase(0)) {
                self.answer(io, &.{ T.abort, self.xfer, @backingInt(AbortReason.flash) });
                return self.finish(.{ .failed = .flash });
            }
            const now = io.now();
            self.state = .receiving;
            self.block = 0;
            self.have_block = false;
            self.written = 0;
            self.prompt_at = now;
            self.prompts = 0;
            _ = io.send(&.{ T.accept, self.xfer, 0 });
        }

        pub fn decline(self: *Self, io: *Io) void {
            if (self.state != .asking) return;
            self.answer(io, &.{ T.reject, self.xfer, @backingInt(Reject.declined) });
            self.finish(.declined);
        }

        /// Hold B while receiving.
        pub fn cancel(self: *Self, io: *Io) void {
            if (!self.busy()) return;
            self.answer(io, &.{ T.abort, self.xfer, @backingInt(AbortReason.cancelled) });
            self.finish(.cancelled);
        }

        pub fn link_lost(self: *Self) void {
            if (self.busy()) self.finish(.link_lost);
        }

        fn begin(self: *Self, now: u64, k: u16, len: u32, crc: u32) void {
            self.block = k;
            self.have_block = true;
            self.len = len;
            self.crc = crc;
            self.packets = @intCast((len + data_bytes - 1) / data_bytes);
            self.next = 0;
            self.last_data = now;
            self.nak_for = null;
        }

        fn nak(self: *Self, io: *Io, now: u64) void {
            if (self.nak_for) |f| if (f == self.next and now -% self.nak_at < timing.nak_repeat) return;
            var p: [6]u8 = undefined;
            p[0] = T.nak;
            p[1] = self.xfer;
            put16(p[2..], self.block);
            put16(p[4..], self.next);
            _ = io.send(&p);
            self.nak_for = self.next;
            self.nak_at = now;
            self.stats.naks += 1;
        }

        fn ack(self: *Self, io: *Io, k: u16) void {
            var p: [4]u8 = undefined;
            p[0] = T.ack;
            p[1] = self.xfer;
            put16(p[2..], k);
            _ = io.send(&p);
        }

        pub fn handle(self: *Self, io: *Io, p: []const u8) void {
            if (p.len < 2) return;
            const now = io.now();
            const x = p[1];
            switch (p[0]) {
                T.offer => self.on_offer(io, now, x),
                T.block => {
                    if (p.len < 11 or x != self.xfer or !self.busy() and self.state != .finished) return;
                    const k = get16(p[2..]);
                    const len = get16(p[4..]);
                    const crc = get32(p[6..]);
                    const zero = p[10] & flag_zero != 0;
                    switch (self.state) {
                        .header => {
                            if (k != header_block or len != slot.header_size or zero) return;
                            if (!self.have_block) self.begin(now, k, len, crc);
                        },
                        .asking => if (k == header_block) self.ack(io, header_block),
                        .receiving => {
                            if (k == self.block and !self.have_block) {
                                if (len == 0 or len > block_size) return;
                                self.begin(now, k, len, crc);
                                if (zero) {
                                    @memset(self.buf[0..len], 0);
                                    self.next = self.packets;
                                    self.complete(io);
                                }
                            } else if (k < self.block) {
                                // Our ACK was lost.
                                self.ack(io, k);
                            }
                        },
                        .verifying => if (k + 1 == self.blocks) self.ack(io, k),
                        .finished => if (self.last_xfer == x and k + 1 == self.blocks) {
                            self.ack(io, k);
                            _ = io.send(self.last_answer[0..self.last_answer_len]);
                        },
                        .idle => {},
                    }
                },
                T.data => {
                    if (p.len < 5 or x != self.xfer or !self.have_block) return;
                    if (self.state != .header and self.state != .receiving) return;
                    const seq = get16(p[2..]);
                    if (seq == self.next and self.next < self.packets) {
                        const off = @as(u32, seq) * data_bytes;
                        const n = @min(data_bytes, self.len - off);
                        if (p.len - 4 != n) return;
                        @memcpy(self.buf[off..][0..n], p[4..][0..n]);
                        self.next += 1;
                        self.last_data = now;
                        if (self.next == self.packets) self.complete(io);
                    } else if (seq > self.next and seq < self.packets) {
                        self.nak(io, now);
                    }
                },
                T.abort => {
                    if (p.len < 3 or x != self.xfer or !self.busy()) return;
                    self.finish(.{ .sender_aborted = @fromBackingInt(@intCast(p[2])) });
                },
                else => {},
            }
        }

        fn on_offer(self: *Self, io: *Io, now: u64, x: u8) void {
            if (x == self.xfer) switch (self.state) {
                // The sender is resending everything: start the header over.
                .header => return self.begin_offer(now, x),
                // It missed our ACK / ACCEPT.
                .asking => return self.ack(io, header_block),
                .receiving, .verifying => return {
                    _ = io.send(&.{ T.accept, self.xfer, 0 });
                },
                .idle, .finished => {},
            };
            if (self.last_xfer == x and !self.busy()) {
                _ = io.send(self.last_answer[0..self.last_answer_len]);
                return;
            }
            // A new transfer. One that supersedes ours means the sender
            // restarted (its ABORT was lost): drop ours.
            if (!io.can_receive()) {
                self.xfer = x;
                self.answer(io, &.{ T.reject, x, @backingInt(Reject.cannot_receive) });
                return;
            }
            if (!self.accepting) {
                self.xfer = x;
                self.answer(io, &.{ T.reject, x, @backingInt(Reject.busy) });
                return;
            }
            self.begin_offer(now, x);
        }

        fn begin_offer(self: *Self, now: u64, x: u8) void {
            self.state = .header;
            self.result = .none;
            self.xfer = x;
            self.have_block = false;
            self.last_data = now;
        }

        /// The current block's bytes are all in.
        fn complete(self: *Self, io: *Io) void {
            const now = io.now();
            if (slot.crc32(self.buf[0..self.len]) != self.crc) {
                self.next = 0;
                self.nak_for = null;
                self.nak(io, now);
                return;
            }
            self.have_block = false;
            if (self.state == .header) {
                @memcpy(&self.header_bytes, self.buf[0..slot.header_size]);
                self.header = slot.parse(&self.header_bytes, io.area_size()) catch |e| {
                    const why: Reject = if (e == error.ImageTooLong) .too_big else .bad_header;
                    self.answer(io, &.{ T.reject, self.xfer, @backingInt(why) });
                    return self.finish(.declined);
                };
                self.blocks = @intCast((self.header.image_len + block_size - 1) / block_size);
                self.state = .asking;
                self.asked_at = now;
                self.ack(io, header_block);
                return;
            }
            // An image block: erase its sector, program it padded to whole
            // pages, ACK.
            const k = self.block;
            const at = slot.image_offset + @as(u32, k) * block_size;
            const padded = (self.len + 255) / 256 * 256;
            @memset(self.buf[self.len..padded], 0xFF);
            if (!io.erase(at) or !io.program(at, self.buf[0..padded])) {
                self.answer(io, &.{ T.abort, self.xfer, @backingInt(AbortReason.flash) });
                return self.finish(.{ .failed = .flash });
            }
            const after = io.now();
            self.written += self.len;
            self.ack(io, k);
            self.prompt_at = after;
            self.prompts = 0;
            if (k + 1 == self.blocks) {
                self.state = .verifying;
                self.verify_at = 0;
                self.verify_crc = .init();
            } else {
                self.block = k + 1;
            }
        }

        pub fn tick(self: *Self, io: *Io) void {
            const now = io.now();
            switch (self.state) {
                .idle, .finished => {},
                .header => if (self.have_block and self.next < self.packets and now -% self.last_data >= timing.nak_gap) {
                    self.nak(io, now);
                },
                .asking => if (now -% self.asked_at >= timing.offer_timeout) self.decline(io),
                .receiving => {
                    if (self.have_block) {
                        if (self.next < self.packets and now -% self.last_data >= timing.nak_gap) self.nak(io, now);
                    } else if (now -% self.prompt_at >= timing.resend_after) {
                        // Nothing since our ACCEPT / last ACK: say it again.
                        self.prompts += 1;
                        if (self.prompts > timing.tries) {
                            self.answer(io, &.{ T.abort, self.xfer, @backingInt(AbortReason.no_answer) });
                            return self.finish(.{ .sender_aborted = .no_answer });
                        }
                        self.prompt_at = now;
                        if (self.block == 0) {
                            _ = io.send(&.{ T.accept, self.xfer, 0 });
                        } else {
                            self.ack(io, self.block - 1);
                        }
                    }
                },
                .verifying => self.verify_step(io),
            }
        }

        fn verify_step(self: *Self, io: *Io) void {
            const len = self.header.image_len;
            if (self.verify_at < len) {
                var chunk: [timing.verify_chunk]u8 = undefined;
                const n = @min(timing.verify_chunk, len - self.verify_at);
                io.read(slot.image_offset + self.verify_at, chunk[0..n]);
                self.verify_crc.update(chunk[0..n]);
                self.verify_at += n;
                return;
            }
            if (self.verify_crc.final() != self.header.image_crc32) {
                self.answer(io, &.{ T.done, self.xfer, @backingInt(DoneStatus.crc) });
                return self.finish(.{ .failed = .crc });
            }
            // The header, last: one page, the rest of it erased.
            var page: [256]u8 = @splat(0xFF);
            @memcpy(page[0..slot.header_size], &self.header_bytes);
            var back: [slot.header_size]u8 = @splat(0);
            if (io.program(0, &page)) io.read(0, &back);
            if (!std.mem.eql(u8, &back, &self.header_bytes)) {
                self.answer(io, &.{ T.done, self.xfer, @backingInt(DoneStatus.flash) });
                return self.finish(.{ .failed = .flash });
            }
            self.answer(io, &.{ T.done, self.xfer, @backingInt(DoneStatus.ok) });
            self.finish(.received);
        }
    };
}

// ---- routing ---------------------------------------------------------------------

/// Packets a sender takes (the receiver's answers).
pub fn to_sender(t: u8) bool {
    return switch (t) {
        T.ack, T.nak, T.accept, T.reject, T.done, T.abort => true,
        else => false,
    };
}

/// Packets a receiver takes (ABORT goes to both; each checks its xfer).
pub fn to_receiver(t: u8) bool {
    return switch (t) {
        T.offer, T.block, T.data, T.abort => true,
        else => false,
    };
}

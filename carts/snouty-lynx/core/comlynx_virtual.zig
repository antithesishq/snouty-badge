//! An in-process ComLynx bus for 2-8 consoles (docs/COMLYNX.md section 3;
//! PLAN.md "M6 ComLynx: contract"): the host tests' stand-in for the
//! cable and for the badge transport. The consoles run side by side in
//! time slices (`Lynx.begin_frame` / `run_to` / `finish_frame`); after each
//! slice `pump` takes what every UART sent (core/comlynx.zig `Port.take`)
//! and delivers it to the consoles it reaches, at the time the mode says:
//!
//! - `.wire`: the cable, plus an optional transport delay. A console hears
//!   its own frames at once (`Echo.local`); the others get each frame
//!   `latency` (+ 0..`jitter`) ticks after it started, in their own wire,
//!   where frames that overlap are ANDed bit by bit (collisions: garbage,
//!   framing errors). Per sender and receiver the order is kept.
//! - `.relay`: the lobby protocol v1 relay with self-echo (SEND to $FE):
//!   each console's frames travel in batches (`batch`: one per emulated
//!   badge frame, per burst, or per slice) up to the relay, which puts
//!   all batches in one order and sends each to every console, the sender
//!   included (`Echo.bus`), `latency` after the batch left (half up, half
//!   down, each + 0..`jitter`/2). A console's frames keep their spacing
//!   inside a batch and never overlap on its wire: no collisions, and
//!   every console sees the same byte order.
//! - `.timestamped`: every console, the sender included, gets a frame on
//!   its wire at exactly the sender's start time T + `delay` (D). The
//!   wire picture (collisions included) is then the same on every
//!   console. On a real transport a console may not run past
//!   min(peer heartbeat) + D (it stalls instead); here the slices keep
//!   every console within one slice of the others, so a slice no longer
//!   than D (less the longest sprite run) delivers nothing late
//!   (`Stats.late` counts it if one is).
//!
//! Consoles may be switched on at different frames (`power_on_at`): real
//! consoles never start together, and a pair started on the same tick is
//! a mirror image (a ROM that picks a master from a free-running timer
//! picks the same on both). The bus keeps its own clock; console i's
//! clock is the bus clock minus the bus time it was switched on at, and
//! the bus converts every time it routes.
//!
//! Deterministic: the jitter comes from a seeded xorshift; the consoles
//! step in index order. Fixed capacity, no allocator; a test keeps the bus
//! in a static (it holds the consoles' ports).
const std = @import("std");
const lynx_mod = @import("lynx.zig");
const comlynx = @import("comlynx.zig");

const Lynx = lynx_mod.Lynx;
const Port = comlynx.Port;
const TxFrame = comlynx.TxFrame;
const RxFrame = comlynx.RxFrame;

pub const max_consoles = 8;

pub const Mode = enum { wire, relay, timestamped };

/// When a console's frames leave for the relay (`.relay`).
pub const Batch = enum {
    /// Once per emulated badge frame (1/60 s), at its end.
    frame,
    /// When the sender has been quiet for a frame time after its last
    /// frame (the burst is over), and at the latest at the frame's end.
    burst,
    /// After every slice (as near to per byte as the slices allow).
    slice,
};

pub const Config = struct {
    mode: Mode = .wire,
    /// One-way transport delay in ticks (16 MHz; 16,000 = 1 ms).
    latency: u64 = 0,
    /// Extra delay, uniform in 0..jitter ticks, per delivery.
    jitter: u64 = 0,
    /// `.timestamped`: D in ticks.
    delay: u64 = 0,
    /// Run slice in ticks (1,600 = 100 us).
    slice: u32 = 1600,
    batch: Batch = .frame,
    seed: u64 = 0x5EED_C0DE,
    /// Deliveries are handed to a console this far ahead of their time
    /// (they wait on its wire), so a console that ran past the slice end
    /// (an instruction, or a whole sprite run: up to ~4 ms) still gets
    /// them on time. 4 ms.
    lookahead: u64 = 4 * 16_000,
    /// Where a console hears its own frames: null = the mode's own
    /// (`.wire` local, `.relay` and `.timestamped` through the bus);
    /// `.local` in the other modes = the sender's UART echoes at once and
    /// the bus delivers only to the others (docs/COMLYNX.md: Warbirds
    /// needs it).
    echo: ?comlynx.Echo = null,
};

pub const Stats = struct {
    /// Frames the UARTs put on the wire.
    sent: u64 = 0,
    /// Deliveries made (one per receiving console).
    delivered: u64 = 0,
    /// Deliveries due before the receiver's clock (moved to now), and the
    /// worst lateness in ticks.
    late: u64 = 0,
    worst_late: u64 = 0,
    /// Deliveries a full wire refused / pending entries dropped (full).
    refused: u64 = 0,
    dropped: u64 = 0,
    /// Relay batches sent.
    batches: u64 = 0,
};

const Pending = struct {
    due: u64,
    f: RxFrame,
};

/// Deliveries waiting per receiver, in due order.
const pending_cap = 4096;
const Queue = struct {
    items: [pending_cap]Pending = undefined,
    head: u32 = 0,
    len: u32 = 0,

    fn at(q: *Queue, i: u32) *Pending {
        return &q.items[(q.head + i) % pending_cap];
    }

    fn insert(q: *Queue, p: Pending) bool {
        if (q.len == pending_cap) return false;
        var i = q.len;
        while (i > 0 and q.at(i - 1).due > p.due) : (i -= 1) q.at(i).* = q.at(i - 1).*;
        q.at(i).* = p;
        q.len += 1;
        return true;
    }

    fn pop(q: *Queue) Pending {
        const p = q.items[q.head];
        q.head = (q.head + 1) % pending_cap;
        q.len -= 1;
        return p;
    }
};

/// A relay batch in flight up to the relay.
const batch_cap = 128;
const Upload = struct {
    arrive: u64,
    seq: u64,
    src: u8,
    n: u32,
    frames: [batch_cap]TxFrame,
};
const uploads_cap = 512;

pub const VirtualBus = struct {
    cfg: Config,
    n: u8,
    consoles: [max_consoles]*Lynx,
    ports: [max_consoles]Port,
    queues: [max_consoles]Queue,
    /// Per receiver: the end of the last frame delivered (`.relay` never
    /// overlaps frames), and per sender and receiver the last due time
    /// (`.wire` keeps each link's order).
    wire_free: [max_consoles]u64,
    last_due: [max_consoles][max_consoles]u64,
    // Relay state.
    batch: [max_consoles][batch_cap]TxFrame,
    batch_len: [max_consoles]u32,
    last_tx: [max_consoles]u64,
    uploads: [uploads_cap]Upload,
    uploads_len: u32,
    seq: u64,
    rng: u64,
    stats: Stats,
    /// The bus clock (16 MHz ticks) and its frame fraction (as `Lynx`).
    time: u64,
    frac: u32,
    frame_index: u32,
    /// Bus frame at which console i is switched on, and the bus time its
    /// clock started at (valid once `on[i]`).
    start_frame: [max_consoles]u32,
    offset: [max_consoles]u64,
    on: [max_consoles]bool,

    /// Set up over `consoles` (initialised and reset together, so their
    /// clocks agree), attaching a port to each.
    pub fn init(b: *VirtualBus, cfg: Config, consoles: []const *Lynx) void {
        std.debug.assert(consoles.len >= 1 and consoles.len <= max_consoles);
        b.cfg = cfg;
        b.n = @intCast(consoles.len);
        b.uploads_len = 0;
        b.seq = 0;
        b.rng = cfg.seed | 1;
        b.stats = .{};
        b.time = 0;
        b.frac = 0;
        b.frame_index = 0;
        for (0..max_consoles) |i| {
            b.queues[i] = .{};
            b.wire_free[i] = 0;
            b.batch_len[i] = 0;
            b.last_tx[i] = 0;
            b.start_frame[i] = 0;
            b.offset[i] = 0;
            b.on[i] = true;
            for (0..max_consoles) |j| b.last_due[i][j] = 0;
        }
        for (consoles, 0..) |l, i| {
            b.consoles[i] = l;
            b.ports[i] = .{ .id = @intCast(i), .echo = b.echo() };
            l.attach_link(&b.ports[i]);
        }
    }

    fn echo(b: *const VirtualBus) comlynx.Echo {
        return b.cfg.echo orelse if (b.cfg.mode == .wire) .local else .bus;
    }

    fn rand(b: *VirtualBus, max: u64) u64 {
        if (max == 0) return 0;
        var x = b.rng;
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        b.rng = x;
        return x % (max + 1);
    }

    /// Switch console i on at bus frame `frame` (default 0); it must be
    /// freshly reset (its clock at 0) and is not stepped before that.
    pub fn power_on_at(b: *VirtualBus, i: usize, frame: u32) void {
        b.start_frame[i] = frame;
        b.on[i] = frame == 0;
    }

    /// One badge frame for every console that is on, `pads[i]` the pad
    /// word of console i.
    pub fn step_frame(b: *VirtualBus, pads: []const u16) void {
        var n = lynx_mod.ticks_per_frame;
        b.frac += lynx_mod.frame_frac_num;
        if (b.frac >= lynx_mod.frame_frac_den) {
            b.frac -= lynx_mod.frame_frac_den;
            n += 1;
        }
        const t0 = b.time;
        const end = t0 + n;
        for (b.consoles[0..b.n], 0..) |l, i| {
            if (!b.on[i] and b.frame_index >= b.start_frame[i]) {
                b.on[i] = true;
                b.offset[i] = t0 -| l.time();
            }
            if (b.on[i]) l.begin_frame(pads[i]);
        }
        var t = t0;
        while (t < end) {
            t = @min(end, t + b.cfg.slice);
            for (b.consoles[0..b.n], 0..) |l, i| {
                if (b.on[i]) l.run_to(t - b.offset[i]);
            }
            b.pump(t, t == end);
        }
        for (b.consoles[0..b.n], 0..) |l, i| {
            if (b.on[i]) l.finish_frame();
        }
        b.time = end;
        b.frame_index += 1;
    }

    /// After every console reached `t`: route what they sent, deliver what
    /// is due before the next slice ends.
    pub fn pump(b: *VirtualBus, t: u64, frame_end: bool) void {
        for (b.consoles[0..b.n], 0..) |l, i| {
            if (!b.on[i]) continue;
            l.link_sync();
            const src: u8 = @intCast(i);
            while (b.ports[i].take()) |tf| {
                var f = tf;
                f.time += b.offset[i];
                b.stats.sent += 1;
                switch (b.cfg.mode) {
                    .wire => b.route_wire(src, f),
                    .timestamped => b.route_timestamped(src, f),
                    .relay => b.add_to_batch(src, f),
                }
            }
        }
        if (b.cfg.mode == .relay) b.relay(t, frame_end);
        const horizon = t + b.cfg.slice + b.cfg.lookahead;
        for (0..b.n) |i| {
            const q = &b.queues[i];
            while (q.len > 0 and q.at(0).due < horizon) {
                const p = q.pop();
                // A console that is off is not on the wire.
                if (!b.on[i] or p.due < b.offset[i]) continue;
                var f = p.f;
                f.start = p.due - b.offset[i];
                const late = b.consoles[i].link_deliver(f) orelse {
                    b.stats.refused += 1;
                    continue;
                };
                b.stats.delivered += 1;
                if (late > 0) {
                    b.stats.late += 1;
                    b.stats.worst_late = @max(b.stats.worst_late, late);
                }
            }
        }
    }

    fn rx(src: u8, f: TxFrame) RxFrame {
        return .{ .start = f.time, .bit_ticks = f.bit_ticks, .data = f.data, .ninth = f.ninth, .kind = f.kind, .src = src };
    }

    fn enqueue(b: *VirtualBus, dest: usize, due: u64, f: RxFrame) void {
        if (!b.queues[dest].insert(.{ .due = due, .f = f })) b.stats.dropped += 1;
    }

    fn frame_len(f: TxFrame) u64 {
        return if (f.kind == .frame) comlynx.frame_bits * @as(u64, f.bit_ticks) else 0;
    }

    fn route_wire(b: *VirtualBus, src: u8, f: TxFrame) void {
        for (0..b.n) |d| {
            if (d == src) continue;
            var due = f.time + b.cfg.latency + b.rand(b.cfg.jitter);
            // A link keeps its order (and a frame's spacing after the one
            // before from the same sender).
            due = @max(due, b.last_due[src][d]);
            b.last_due[src][d] = due + frame_len(f);
            b.enqueue(d, due, rx(src, f));
        }
    }

    fn route_timestamped(b: *VirtualBus, src: u8, f: TxFrame) void {
        for (0..b.n) |d| {
            if (d == src and b.echo() == .local) continue;
            b.enqueue(d, f.time + b.cfg.delay, rx(src, f));
        }
    }

    fn add_to_batch(b: *VirtualBus, src: u8, f: TxFrame) void {
        const k = b.batch_len[src];
        if (k == batch_cap) b.flush(src, f.time);
        b.batch[src][b.batch_len[src]] = f;
        b.batch_len[src] += 1;
        b.last_tx[src] = f.time + frame_len(f);
    }

    /// Send console `src`'s batch to the relay at `t`.
    fn flush(b: *VirtualBus, src: u8, t: u64) void {
        const k = b.batch_len[src];
        if (k == 0) return;
        if (b.uploads_len == uploads_cap) {
            b.stats.dropped += k;
            b.batch_len[src] = 0;
            return;
        }
        const u = &b.uploads[b.uploads_len];
        b.uploads_len += 1;
        u.arrive = t + b.cfg.latency / 2 + b.rand(b.cfg.jitter / 2);
        u.seq = b.seq;
        b.seq += 1;
        u.src = src;
        u.n = k;
        @memcpy(u.frames[0..k], b.batch[src][0..k]);
        b.batch_len[src] = 0;
        b.stats.batches += 1;
    }

    fn relay(b: *VirtualBus, t: u64, frame_end: bool) void {
        // Batches leave.
        for (0..b.n) |i| {
            const src: u8 = @intCast(i);
            if (b.batch_len[i] == 0) continue;
            const go = switch (b.cfg.batch) {
                .slice => true,
                .frame => frame_end,
                .burst => frame_end or t >= b.last_tx[i] + comlynx.frame_bits * @as(u64, b.batch[i][0].bit_ticks),
            };
            if (go) b.flush(src, t);
        }
        // The relay forwards what has reached it, in arrival order (one
        // order for every receiver); a batch is forwarded only once every
        // batch that could arrive before it is known, which here is when
        // its arrival is not after `t` (later uploads arrive later).
        while (true) {
            var best: ?u32 = null;
            for (b.uploads[0..b.uploads_len], 0..) |*u, k| {
                if (u.arrive > t) continue;
                if (best == null or u.arrive < b.uploads[best.?].arrive or
                    (u.arrive == b.uploads[best.?].arrive and u.seq < b.uploads[best.?].seq)) best = @intCast(k);
            }
            const k = best orelse break;
            const u = b.uploads[k];
            b.uploads[k] = b.uploads[b.uploads_len - 1];
            b.uploads_len -= 1;
            for (0..b.n) |d| {
                if (d == u.src and b.echo() == .local) continue;
                const base = u.arrive + b.cfg.latency - b.cfg.latency / 2 + b.rand(b.cfg.jitter - b.cfg.jitter / 2);
                const t0 = u.frames[0].time;
                var open_break = false;
                for (u.frames[0..u.n]) |f| {
                    var due = base + (f.time - t0);
                    if (f.kind != .break_off and !open_break) due = @max(due, b.wire_free[d]);
                    if (f.kind == .break_on) open_break = true;
                    if (f.kind == .break_off) open_break = false;
                    b.wire_free[d] = @max(b.wire_free[d], due + frame_len(f));
                    b.enqueue(d, due, rx(u.src, f));
                }
            }
        }
    }

    pub fn deinit(b: *VirtualBus) void {
        for (b.consoles[0..b.n]) |l| l.attach_link(null);
    }
};

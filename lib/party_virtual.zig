//! A model of the laptop's `badge lobby` relay and the badges' USB, for
//! host tests of lib/party.zig and lib/lockstep_n.zig. It follows lobby
//! protocol v1 as `fork/CART_SERIAL.md` states it and the reference relay
//! does it (sycl-badge-fork main 8ca6da6, `tools/badge/badge/lobby.py`;
//! the real relay end to end: tools/party_e2e, docs/LOCKSTEP_N.md):
//!
//! - rooms per game id: a new player goes to the first room with the same
//!   game and a free slot, else a new room; a room's size is its first
//!   member's `max_players` (0 = 16, else clamped to 2..16); rooms are
//!   numbered from 1; player ids are the lowest free one;
//! - WELCOME to the new player, then ROSTER to everyone in the room, after
//!   every join and leave; a HELLO from a player in a room is a rejoin: it
//!   leaves first (ROSTER without it to the others), then joins afresh, so
//!   it may land in another room or id; a HELLO of another version leaves
//!   too, then gets ERROR 1;
//! - SEND to an id, to 0xFF (everyone else) or 0xFE (everyone, the sender
//!   included) becomes DATA, one frame at a time: each frame is queued to
//!   every recipient before the next frame is looked at (one order per
//!   room); a SEND to an absent id is dropped; PING -> PONG; SEND or LEAVE
//!   before WELCOME -> ERROR 3; a short message, or SEND data over 240
//!   bytes -> ERROR 4; unknown types are ignored;
//! - no silent loss: a connected player's queue is never trimmed; a player
//!   whose cart stopped reading is removed (ROSTER to the others, port
//!   closed) when more than `stuck_limit` (64 KiB) has waited for it for
//!   `stuck_us` (1 s), or `hard_limit` (1 MiB) is waiting: the rule of
//!   the real relay (exedev-94, host tool 5ddec50: one relay thread,
//!   frames queued in arrival order). This model's queue holds 256 KiB,
//!   so its hard limit is that; tests scale the limits down per port;
//! - an unplugged port leaves its room, and the bytes it had in flight
//!   (written by the cart, not yet handled by the relay) reach no one.
//!
//! On top of that the USB and the laptop: each port has a latency and a
//! jitter each way (a deterministic PRNG; per-direction order is kept, so
//! jitter never reorders a port's bytes), the badge's receive ring fills
//! (bytes wait in the relay's queue: back-pressure), a port can stall (the
//! relay neither reads nor writes it, but it stays connected), and a port
//! can be unplugged and plugged in again. Time is in microseconds, driven
//! by the test through `advance(now)`. Delivery times are rounded up to
//! the millisecond.
const std = @import("std");
const party = @import("party.zig");

/// A badge's USB as the relay sees it: the OS side of a
/// `cart_serial.Virtual` port, type-erased so badges with different ring
/// sizes share one relay.
pub const Endpoint = struct {
    ctx: *anyopaque,
    put: *const fn (*anyopaque, []const u8) usize,
    take: *const fn (*anyopaque, []u8) usize,
    set_host_open: *const fn (*anyopaque, bool) void,

    /// The endpoint of a `cart_serial.Virtual(...)` port.
    pub fn of(comptime V: type, v: *V) Endpoint {
        const F = struct {
            fn put(c: *anyopaque, b: []const u8) usize {
                const p: *V = @ptrCast(@alignCast(c));
                return p.os_put(b);
            }
            fn take(c: *anyopaque, b: []u8) usize {
                const p: *V = @ptrCast(@alignCast(c));
                return p.os_take(b);
            }
            fn set(c: *anyopaque, open: bool) void {
                const p: *V = @ptrCast(@alignCast(c));
                p.host_open = open;
            }
        };
        return .{ .ctx = v, .put = F.put, .take = F.take, .set_host_open = F.set };
    }
};

pub const max_ports = 24;
pub const max_rooms = 8;
/// Bytes a queue can hold (badge -> relay and relay -> badge).
pub const queue_cap: u32 = 1 << 18;
const chunk_cap = 512;

/// A byte queue whose tail is in flight: chunks with a delivery time.
const Queue = struct {
    buf: [queue_cap]u8 = undefined,
    head: u32 = 0,
    len: u32 = 0,
    /// Bytes at the head whose time has come.
    ready: u32 = 0,
    chunks: [chunk_cap]Chunk = undefined,
    c_head: u16 = 0,
    c_len: u16 = 0,
    last_time: u64 = 0,

    const Chunk = struct { time: u64, len: u32 };

    fn clear(q: *Queue) void {
        q.head = 0;
        q.len = 0;
        q.ready = 0;
        q.c_head = 0;
        q.c_len = 0;
    }

    /// Append `bytes` arriving at `time` (rounded up to the ms, never
    /// before the previous chunk). False when full.
    fn push(q: *Queue, bytes: []const u8, time: u64) bool {
        if (q.len + bytes.len > queue_cap) return false;
        var t = (time + 999) / 1000 * 1000;
        t = @max(t, q.last_time);
        q.last_time = t;
        for (bytes, 0..) |b, i| q.buf[(q.head + q.len + @as(u32, @intCast(i))) % queue_cap] = b;
        q.len += @intCast(bytes.len);
        const n: u32 = @intCast(bytes.len);
        if (q.c_len > 0) {
            const last = &q.chunks[(q.c_head + q.c_len - 1) % chunk_cap];
            if (last.time == t or q.c_len == chunk_cap) {
                last.len += n;
                return true;
            }
        }
        q.chunks[(q.c_head + q.c_len) % chunk_cap] = .{ .time = t, .len = n };
        q.c_len += 1;
        return true;
    }

    /// Move chunks due by `now` into `ready`.
    fn due(q: *Queue, now: u64) void {
        while (q.c_len > 0 and q.chunks[q.c_head].time <= now) {
            q.ready += q.chunks[q.c_head].len;
            q.c_head = (q.c_head + 1) % chunk_cap;
            q.c_len -= 1;
        }
    }

    /// The first chunk's time (null: nothing in flight).
    fn next_time(q: *const Queue) ?u64 {
        return if (q.c_len > 0) q.chunks[q.c_head].time else null;
    }

    /// Up to `out.len` ready bytes, without removing them.
    fn peek(q: *const Queue, out: []u8) usize {
        const n = @min(out.len, q.ready);
        for (out[0..n], 0..) |*b, i| b.* = q.buf[(q.head + @as(u32, @intCast(i))) % queue_cap];
        return n;
    }

    fn drop(q: *Queue, n: u32) void {
        q.head = (q.head + n) % queue_cap;
        q.len -= n;
        q.ready -= n;
    }
};

pub const Stats = struct {
    frames_in: u32 = 0,
    frames_out: u32 = 0,
    /// Players removed because their queue stayed too long (or full).
    removed: u32 = 0,
    errors_sent: u32 = 0,
};

const PortState = struct {
    ep: ?Endpoint = null,
    plugged: bool = false,
    stalled: bool = false,
    latency_us: u32 = 0,
    jitter_us: u32 = 0,
    /// badge -> relay
    in_q: Queue = .{},
    dec: party.Decoder = .{},
    /// relay -> badge
    out_q: Queue = .{},
    room: ?u8 = null,
    id: u8 = 0,
    name: [party.name_len]u8 = @splat(0),
    /// The most bytes ever waiting for this badge (back-pressure seen).
    max_backlog: u32 = 0,
    removed: bool = false,
    /// Its queue is full: removed after the frame in hand.
    overflow: bool = false,
    /// This player's stuck limit (0: the relay's `stuck_limit`).
    limit: u32 = 0,
    /// Since when more than the stuck limit has waited (null: not now).
    stuck_since: ?u64 = null,
};

const Room = struct {
    used: bool = false,
    game: [party.game_len]u8 = @splat(0),
    size: u8 = 0,
    /// Port index per player id.
    members: [party.max_players]?u8 = @splat(null),
};

pub const Relay = struct {
    ports: [max_ports]PortState = @splat(.{}),
    rooms: [max_rooms]Room = @splat(.{}),
    rng: u32 = 0x9E37_79B9,
    now: u64 = 0,
    /// Bytes queued for one player (in flight plus waiting for its ring)
    /// beyond which the player is removed.
    stuck_limit: u32 = 64 * 1024,
    stuck_us: u64 = 1_000_000,
    hard_limit: u32 = queue_cap,
    stats: Stats = .{},

    pub fn init(r: *Relay, seed: u32) void {
        r.* = .{};
        r.rng = seed | 1;
    }

    fn rand(r: *Relay) u32 {
        var x = r.rng;
        x ^= x << 13;
        x ^= x >> 17;
        x ^= x << 5;
        r.rng = x;
        return x;
    }

    fn delay(r: *Relay, p: *const PortState) u64 {
        const j: u64 = if (p.jitter_us == 0) 0 else r.rand() % (p.jitter_us + 1);
        return p.latency_us + j;
    }

    /// Plug badge `i` in (its port connects: DTR high).
    pub fn attach(r: *Relay, i: usize, ep: Endpoint, latency_us: u32, jitter_us: u32) void {
        const p = &r.ports[i];
        p.* = .{ .ep = ep, .latency_us = latency_us, .jitter_us = jitter_us };
        r.replug(i);
    }

    pub fn replug(r: *Relay, i: usize) void {
        const p = &r.ports[i];
        if (p.plugged) return;
        p.plugged = true;
        p.removed = false;
        p.overflow = false;
        p.stuck_since = null;
        p.in_q.clear();
        p.out_q.clear();
        p.dec.reset();
        p.ep.?.set_host_open(p.ep.?.ctx, true);
        // A sender writes a lone 0x00 when it (re)connects.
        _ = p.out_q.push(&.{0}, r.now + r.delay(p));
    }

    /// The cable comes out (or the host closes the port): the player
    /// leaves, and what it had in flight reaches no one.
    pub fn unplug(r: *Relay, i: usize) void {
        const p = &r.ports[i];
        if (!p.plugged) return;
        r.leave_room(i, r.now);
        p.plugged = false;
        p.in_q.clear();
        p.out_q.clear();
        p.dec.reset();
        p.ep.?.set_host_open(p.ep.?.ctx, false);
    }

    /// The relay stops reading and writing port `i`; it stays connected.
    pub fn set_stalled(r: *Relay, i: usize, stalled: bool) void {
        r.ports[i].stalled = stalled;
    }

    /// Port `i`'s own stuck limit (0: the relay's).
    pub fn set_stuck_limit(r: *Relay, i: usize, bytes: u32) void {
        r.ports[i].limit = bytes;
    }

    pub fn player(r: *const Relay, i: usize) ?struct { room: u8, id: u8 } {
        const p = &r.ports[i];
        const room = p.room orelse return null;
        return .{ .room = room, .id = p.id };
    }

    pub fn backlog(r: *const Relay, i: usize) u32 {
        return r.ports[i].out_q.len;
    }

    pub fn max_backlog(r: *const Relay, i: usize) u32 {
        return r.ports[i].max_backlog;
    }

    pub fn was_removed(r: *const Relay, i: usize) bool {
        return r.ports[i].removed;
    }

    /// Run the relay and the USB up to `now`.
    pub fn advance(r: *Relay, now: u64) void {
        r.now = now;
        // The badges' OS sends what the carts wrote.
        var buf: [1024]u8 = undefined;
        for (&r.ports) |*p| {
            const ep = p.ep orelse continue;
            if (p.stalled and p.plugged) continue;
            while (true) {
                const n = ep.take(ep.ctx, &buf);
                if (n == 0) break;
                if (!p.plugged) continue; // discarded by the badge's OS
                if (!p.in_q.push(buf[0..n], now + r.delay(p))) unreachable;
            }
        }
        // The relay handles what reached it, in arrival order across
        // ports (ties to the lower port).
        while (true) {
            var best: ?usize = null;
            var best_t: u64 = now + 1;
            for (&r.ports, 0..) |*p, i| {
                if (!p.plugged or p.stalled) continue;
                const t = p.in_q.next_time() orelse continue;
                if (t < best_t) {
                    best_t = t;
                    best = i;
                }
            }
            const i = best orelse break;
            const p = &r.ports[i];
            const c = p.in_q.chunks[p.in_q.c_head];
            p.in_q.due(best_t);
            var left = c.len;
            while (left > 0 and p.plugged) {
                var tmp: [256]u8 = undefined;
                const n: u32 = @intCast(p.in_q.peek(tmp[0..@min(tmp.len, left)]));
                p.in_q.drop(n);
                left -= n;
                for (tmp[0..n]) |b| {
                    var body: [party.max_body]u8 = undefined;
                    if (p.dec.push(b, &body)) |m| {
                        r.stats.frames_in += 1;
                        r.handle(i, body[0..m], best_t);
                        r.remove_overflowed();
                        if (!p.plugged) break;
                    }
                }
            }
        }
        // Deliver into the badges' receive rings as far as they have room.
        for (&r.ports) |*p| {
            const ep = p.ep orelse continue;
            if (!p.plugged) continue;
            if (!p.stalled) {
                p.out_q.due(now);
                while (p.out_q.ready > 0) {
                    var tmp: [512]u8 = undefined;
                    const n = p.out_q.peek(&tmp);
                    const put: u32 = @intCast(ep.put(ep.ctx, tmp[0..n]));
                    if (put == 0) break;
                    p.out_q.drop(put);
                }
            }
            // Too much waiting for too long: the cart (or its USB) stopped
            // reading.
            const limit = if (p.limit != 0) p.limit else r.stuck_limit;
            if (p.out_q.len > limit) {
                const since = p.stuck_since orelse now;
                p.stuck_since = since;
                if (now - since >= r.stuck_us) p.overflow = true;
            } else p.stuck_since = null;
        }
        r.remove_overflowed();
    }

    // ---- the protocol ----

    fn queue(r: *Relay, i: usize, body: []const u8, t: u64) void {
        const p = &r.ports[i];
        if (!p.plugged) return;
        var f: [party.max_frame]u8 = undefined;
        const n = party.encode_frame(body, &f);
        if (p.overflow) return;
        if (p.out_q.len + n > r.hard_limit or !p.out_q.push(f[0..n], t + r.delay(p))) {
            // No silent loss: a player that stopped reading is removed,
            // once the frame in hand has reached everyone else.
            p.overflow = true;
            return;
        }
        r.stats.frames_out += 1;
        p.max_backlog = @max(p.max_backlog, p.out_q.len);
    }

    fn remove_overflowed(r: *Relay) void {
        var again = true;
        while (again) {
            again = false;
            for (&r.ports, 0..) |*p, i| {
                if (!p.overflow) continue;
                p.overflow = false;
                p.stuck_since = null;
                r.stats.removed += 1;
                r.unplug(i);
                p.removed = true;
                again = true;
            }
        }
    }

    fn send_error(r: *Relay, i: usize, code: u8, msg: []const u8, t: u64) void {
        var b: [64]u8 = undefined;
        b[0] = party.T.err;
        b[1] = code;
        @memcpy(b[2..][0..msg.len], msg);
        r.stats.errors_sent += 1;
        r.queue(i, b[0 .. 2 + msg.len], t);
    }

    fn handle(r: *Relay, i: usize, b: []const u8, t: u64) void {
        const p = &r.ports[i];
        switch (b[0]) {
            party.T.hello => {
                if (b.len < 23) return r.send_error(i, party.Err.malformed, "BAD HELLO", t);
                // As lobby.py: a rejoin (or a HELLO of another version)
                // leaves the old room first.
                r.leave_room(i, t);
                if (b[1] != party.version) return r.send_error(i, party.Err.unsupported_version, "VERSION", t);
                r.join(i, b[2..10].*, b[10..22].*, b[22], t);
            },
            party.T.send => {
                if (b.len < 2 or b.len - 2 > party.max_data) return r.send_error(i, party.Err.malformed, "BAD SEND", t);
                const room_i = p.room orelse return r.send_error(i, party.Err.not_joined, "NOT JOINED", t);
                const room = &r.rooms[room_i];
                var d: [party.max_body]u8 = undefined;
                d[0] = party.T.data;
                d[1] = p.id;
                const data = b[2..];
                @memcpy(d[2..][0..data.len], data);
                const frame = d[0 .. 2 + data.len];
                const to = b[1];
                // One frame to every recipient before the next frame (a
                // copy: a recipient removed on overflow leaves the room).
                const members = room.members;
                for (members, 0..) |m, id| {
                    const j = m orelse continue;
                    const yes = switch (to) {
                        party.to_others => j != i,
                        party.to_all => true,
                        else => id == to,
                    };
                    if (yes) r.queue(j, frame, t);
                }
            },
            party.T.ping => {
                if (b.len < 5) return r.send_error(i, party.Err.malformed, "BAD PING", t);
                r.queue(i, &.{ party.T.pong, b[1], b[2], b[3], b[4] }, t);
            },
            party.T.leave => {
                if (p.room == null) return r.send_error(i, party.Err.not_joined, "NOT JOINED", t);
                r.leave_room(i, t);
            },
            else => {},
        }
    }

    fn join(r: *Relay, i: usize, game: [party.game_len]u8, name: [party.name_len]u8, max: u8, t: u64) void {
        const p = &r.ports[i];
        var room_i: ?usize = null;
        for (&r.rooms, 0..) |*room, k| {
            if (!room.used or !std.mem.eql(u8, &room.game, &game)) continue;
            for (room.members[0..room.size]) |m| {
                if (m == null) {
                    room_i = k;
                    break;
                }
            }
            if (room_i != null) break;
        }
        if (room_i == null) {
            for (&r.rooms, 0..) |*room, k| if (!room.used) {
                const size: u8 = if (max == 0) 16 else @min(@max(max, 2), 16);
                room.* = .{ .used = true, .game = game, .size = size };
                room_i = k;
                break;
            };
        }
        const k = room_i orelse return r.send_error(i, party.Err.no_room, "SERVER FULL", t);
        const room = &r.rooms[k];
        const id: u8 = for (room.members[0..room.size], 0..) |m, id| {
            if (m == null) break @intCast(id);
        } else unreachable;
        room.members[id] = @intCast(i);
        p.room = @intCast(k);
        p.id = id;
        p.name = name;
        // Room numbers start at 1 (lobby.py).
        r.queue(i, &.{ party.T.welcome, party.version, id, @intCast(k + 1), room.size }, t);
        r.send_roster(k, t);
    }

    fn leave_room(r: *Relay, i: usize, t: u64) void {
        const p = &r.ports[i];
        const k = p.room orelse return;
        const room = &r.rooms[k];
        room.members[p.id] = null;
        p.room = null;
        var any = false;
        for (room.members) |m| any = any or m != null;
        if (!any) {
            room.* = .{};
            return;
        }
        r.send_roster(k, t);
    }

    fn send_roster(r: *Relay, k: usize, t: u64) void {
        const room = &r.rooms[k];
        var b: [2 + party.max_players * (1 + party.name_len)]u8 = undefined;
        b[0] = party.T.roster;
        var count: u8 = 0;
        for (room.members, 0..) |m, id| {
            const j = m orelse continue;
            const e = b[2 + @as(usize, count) * (1 + party.name_len) ..][0 .. 1 + party.name_len];
            e[0] = @intCast(id);
            @memcpy(e[1..], &r.ports[j].name);
            count += 1;
        }
        b[1] = count;
        const body = b[0 .. 2 + @as(usize, count) * (1 + party.name_len)];
        const members = room.members;
        for (members) |m| {
            const j = m orelse continue;
            r.queue(j, body, t);
        }
    }
};

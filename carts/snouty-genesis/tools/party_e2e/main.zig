//! The Genesis party end to end over the real relay (docs/MULTIPLAYER.md
//! section 6; run by carts/snouty-genesis/tools/party_e2e.sh), after
//! tools/party_e2e/main.zig (Snoutenstein's), whose simulator side is
//! copied here as it is: one process plays N badges, each a TCP listener
//! on 127.0.0.1:<base + i> posing as the fork simulator to `badge lobby
//! --no-usb --sim`, with the cart's receive and transmit rings (2 KiB and
//! 512 B, frontend/app.zig) between the socket and a `players.Session`
//! (the cart's own LockstepN G, frontend/players.zig) over its own
//! console running the same ROM.
//!
//! Each badge's update (every 33.3 ms / `--speed`) does what the party
//! cart does: pump, submit its pad for two ticks, step what is in, pump
//! whenever bytes arrive until 14 ms in. The pads: badge 1 drives Mega
//! Bomberman's menu script (tests/mp_bomberman.zig) to the 4-human battle,
//! then every badge walks its own bomber out of its corner and then holds
//! a pseudo-random pad. Events: one badge leaves the race (QUIT), one
//! says HELLO again on the same link (the relay's rejoin: a leave and a
//! fresh join); both must be handed over on the same tick on every racer
//! and end up in the lobby with MATCH IN PROGRESS. Every badge logs
//! `Md.state_hash` after every tick and all logs must agree.
//! Exit status 0 when every check holds.
const std = @import("std");
const core = @import("core");
const players = @import("players");
const party_lib = @import("party_lib");
const lockstep_n = party_lib.lockstep_n;
const bomber = @import("bomber");
const c = std.c;

const party = lockstep_n.party;
const max_n = 8;
const rx_size: u32 = 2048;
const tx_size: u32 = 512;

// ---- clock ---------------------------------------------------------------

fn now_us() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

// ---- the simulator's side of one badge ------------------------------------

fn Ring(comptime cap: u32) type {
    return struct {
        const Self = @This();
        buf: [cap]u8 = undefined,
        w: u32 = 0,
        r: u32 = 0,
        fn len(s: *const Self) u32 {
            return s.w -% s.r;
        }
        fn room(s: *const Self) u32 {
            return cap - s.len();
        }
        fn push(s: *Self, bytes: []const u8) usize {
            const n: u32 = @intCast(@min(bytes.len, s.room()));
            for (bytes[0..n], 0..) |b, i| s.buf[(s.w +% @as(u32, @intCast(i))) % cap] = b;
            s.w +%= n;
            return n;
        }
        fn pop(s: *Self, out: []u8) usize {
            const n: u32 = @intCast(@min(out.len, s.len()));
            for (out[0..n], 0..) |*b, i| b.* = s.buf[(s.r +% @as(u32, @intCast(i))) % cap];
            s.r +%= n;
            return n;
        }
        /// The longest contiguous run of queued bytes.
        fn front(s: *const Self) []const u8 {
            const at = s.r % cap;
            return s.buf[at..@min(cap, at + s.len())];
        }
        /// The longest contiguous run of free space.
        fn back(s: *Self) []u8 {
            const at = s.w % cap;
            return s.buf[at..@min(cap, at + s.room())];
        }
    };
}

const Conn = struct {
    listen_fd: c_int = -1,
    client_fd: c_int = -1,
    /// A pty instead of a TCP listener: `client_fd` is the master while
    /// someone holds the slave open (DTR), -1 otherwise.
    pty: bool = false,
    master_fd: c_int = -1,
    pty_path: [64]u8 = @splat(0),
    rx: Ring(rx_size) = .{},
    tx: Ring(tx_size) = .{},
    cart_open: bool = false,
    /// `connected()` reads false once (DTR dropped and raised again while
    /// the relay keeps the link): the cart says HELLO on the same link.
    blip: bool = false,
    accepted: u32 = 0,
    /// A tap on the bytes the relay sent this badge (as they enter the
    /// receive ring): every ROSTER in the order it came.
    tap: party.Decoder = .{},
    rosters: [64]u16 = undefined,
    roster_n: u8 = 0,
    /// Connections the relay closed (or reset).
    closed_by_peer: u32 = 0,
    closed_at: u64 = 0,
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    tx_dropped: u64 = 0,
};

/// The port LockstepN owns: the cart_serial interface (`open`,
/// `connected`, `read`, `space`, `write`) over a `Conn`.
const Port = struct {
    conn: *Conn,
    pub fn supported(p: *Port) bool {
        _ = p;
        return true;
    }
    pub fn open(p: *Port) bool {
        p.conn.cart_open = true;
        return true;
    }
    pub fn close(p: *Port) void {
        p.conn.cart_open = false;
    }
    pub fn is_open(p: *Port) bool {
        return p.conn.cart_open;
    }
    pub fn connected(p: *Port) bool {
        if (p.conn.blip) {
            p.conn.blip = false;
            return false;
        }
        return p.conn.client_fd >= 0;
    }
    pub fn available(p: *Port) u32 {
        return p.conn.rx.len();
    }
    pub fn read(p: *Port, buf: []u8) usize {
        return p.conn.rx.pop(buf);
    }
    pub fn space(p: *Port) u32 {
        return p.conn.tx.room();
    }
    pub fn write(p: *Port, bytes: []const u8) usize {
        return p.conn.tx.push(bytes);
    }
};

fn set_int_opt(fd: c_int, level: i32, opt: u32, v: c_int) void {
    _ = c.setsockopt(fd, level, opt, &v, @sizeOf(c_int));
}

fn listen_on(port: u16) !c_int {
    const fd = c.socket(c.AF.INET, c.SOCK.STREAM, 0);
    if (fd < 0) return error.Socket;
    set_int_opt(fd, c.SOL.SOCKET, c.SO.REUSEADDR, 1);
    // Accepted sockets inherit it (set before listen: the window scale).
    if (opts.rcvbuf != 0) set_int_opt(fd, c.SOL.SOCKET, c.SO.RCVBUF, @intCast(opts.rcvbuf));
    var addr: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7F00_0001) };
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) {
        _ = c.close(fd);
        return error.AddressInUse;
    }
    if (c.listen(fd, 4) != 0) return error.Listen;
    return fd;
}

/// Close with a reset, as the simulator does (no TIME_WAIT, the peer sees
/// ECONNRESET).
fn reset_close(fd: c_int) void {
    const l: c.linger = .{ .onoff = 1, .linger = 0 };
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.LINGER, &l, @sizeOf(c.linger));
    _ = c.close(fd);
}

const send_flags: u32 = c.MSG.DONTWAIT | (if (@hasDecl(c.MSG, "NOSIGNAL")) c.MSG.NOSIGNAL else 0);

fn drop_client(conn: *Conn, by_peer: bool) void {
    if (conn.client_fd < 0) return;
    if (!conn.pty) reset_close(conn.client_fd);
    conn.client_fd = -1;
    if (by_peer) {
        conn.closed_by_peer += 1;
        conn.closed_at = now_us();
    }
}

fn accept_one(conn: *Conn) void {
    const fd = c.accept(conn.listen_fd, null, null);
    if (fd < 0) return;
    if (conn.client_fd >= 0) {
        // One client at a time: a probe never kicks out the lobby.
        reset_close(fd);
        return;
    }
    set_int_opt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, 1);
    if (@hasDecl(c.SO, "NOSIGPIPE")) set_int_opt(fd, c.SOL.SOCKET, c.SO.NOSIGPIPE, 1);
    conn.client_fd = fd;
    conn.accepted += 1;
}

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn ptsname(fd: c_int) ?[*:0]const u8;
extern "c" fn cfmakeraw(t: *c.termios) void;

fn open_pty(conn: *Conn) !void {
    const o_rdwr_noctty: u32 = @bitCast(c.O{ .ACCMODE = .RDWR, .NOCTTY = true });
    const fd = posix_openpt(@intCast(o_rdwr_noctty));
    if (fd < 0 or grantpt(fd) != 0 or unlockpt(fd) != 0) return error.Pty;
    const name = ptsname(fd) orelse return error.Pty;
    const path = std.mem.span(name);
    if (path.len >= conn.pty_path.len) return error.Pty;
    @memcpy(conn.pty_path[0..path.len], path);
    // Raw from the start (pyserial sets it too, but only once it opens).
    var t: c.termios = undefined;
    if (c.tcgetattr(fd, &t) == 0) {
        cfmakeraw(&t);
        _ = c.tcsetattr(fd, .NOW, &t);
    }
    const nb: u32 = @bitCast(c.O{ .NONBLOCK = true });
    _ = c.fcntl(fd, c.F.SETFL, @as(c_int, @intCast(nb)));
    conn.pty = true;
    conn.master_fd = fd;
}

/// A pty is "connected" while someone holds its slave open (the master
/// sees HUP otherwise).
fn follow_pty(conn: *Conn) void {
    if (!conn.pty or conn.master_fd < 0) return;
    var p = [1]c.pollfd{.{ .fd = conn.master_fd, .events = 0, .revents = 0 }};
    _ = c.poll(&p, 1, 0);
    const open = p[0].revents & c.POLL.HUP == 0;
    if (open and conn.client_fd < 0) {
        conn.client_fd = conn.master_fd;
        conn.accepted += 1;
    } else if (!open and conn.client_fd >= 0) {
        drop_client(conn, true);
    }
}

/// Socket -> receive ring while it has room (bytes for a cart that has not
/// opened the port are discarded).
fn service_rx(conn: *Conn, revents: i16) void {
    if (conn.client_fd < 0) return;
    const hup = revents & (c.POLL.HUP | c.POLL.ERR) != 0;
    while (true) {
        var scratch: [4096]u8 = undefined;
        const dst: []u8 = if (conn.cart_open) conn.rx.back() else &scratch;
        if (dst.len == 0) break;
        const n = if (conn.pty) c.read(conn.client_fd, dst.ptr, dst.len) else c.recv(conn.client_fd, dst.ptr, dst.len, c.MSG.DONTWAIT);
        if (n == 0) return drop_client(conn, true);
        if (n < 0) {
            const e = std.posix.errno(n);
            if (e == .AGAIN) break;
            return drop_client(conn, true);
        }
        conn.bytes_in += @intCast(n);
        tap(conn, dst[0..@intCast(n)]);
        if (conn.cart_open) conn.rx.w +%= @intCast(n);
    }
    // The ring is full and the peer is gone: nothing more will be read.
    if (hup and conn.client_fd >= 0 and conn.rx.room() == 0) drop_client(conn, true);
}

fn tap(conn: *Conn, bytes: []const u8) void {
    var body: [party.max_body]u8 = undefined;
    for (bytes) |b| {
        const n = conn.tap.push(b, &body) orelse continue;
        if (body[0] != party.T.roster or n < 2) continue;
        var mask: u16 = 0;
        for (0..body[1]) |k| {
            const at = 2 + k * (1 + party.name_len);
            if (at < n and body[at] < 16) mask |= @as(u16, 1) << @intCast(body[at]);
        }
        if (conn.roster_n < conn.rosters.len) {
            conn.rosters[conn.roster_n] = mask;
            conn.roster_n += 1;
        }
    }
}

/// Transmit ring -> socket (discarded while no client is connected).
fn service_tx(conn: *Conn) void {
    if (conn.client_fd < 0) {
        conn.tx_dropped += conn.tx.len();
        conn.tx.r = conn.tx.w;
        return;
    }
    while (conn.tx.len() > 0) {
        const f = conn.tx.front();
        const n = if (conn.pty) c.write(conn.client_fd, f.ptr, f.len) else c.send(conn.client_fd, f.ptr, f.len, send_flags);
        if (n < 0) {
            const e = std.posix.errno(n);
            if (e == .AGAIN) return;
            return drop_client(conn, true);
        }
        conn.tx.r +%= @intCast(n);
        conn.bytes_out += @intCast(n);
    }
}

// ---- one badge ---------------------------------------------------------------

const Sess = players.Session(Port);
const Role = enum { racer, leave, rejoin };

const Inst = struct {
    idx: u8,
    role: Role = .racer,
    conn: Conn = .{},
    sess: Sess,
    md: *core.Md,
    period: u64,
    frame_top: u64 = 0,
    window_end: u64 = 0,
    racing: bool = false,
    raced: bool = false,
    owed: u32 = 0,
    saw_desync: bool = false,
    log: []u32,
    /// The tick each slot was handed over at, as this badge saw it.
    handed: [16]?u32 = @splat(null),
    slot_at_start: u4 = 0,
    roster_start: u8 = 0,
    rng: u32 = 1,
    held: u8 = 0,
};

var insts: []Inst = undefined;
var n_badges: usize = 0;

const Opts = struct {
    badges: usize = 4,
    base_port: u16 = 27400,
    speed: u32 = 4,
    delay: u32 = 3,
    rom: []const u8 = "",
    /// Ticks past the battle's start the racers play to.
    after: u32 = 600,
    rcvbuf: u32 = 0,
    join_timeout_s: u32 = 20,
};
var opts: Opts = .{};

/// Each player's way out of its corner (pads 1-4).
const moves = [4]u16{ core.Pad.right, core.Pad.up, core.Pad.down, core.Pad.right };

/// Badge `b`'s byte for tick `t` (it plays pad `pad`).
fn byte_for(b: *Inst, pad: usize, t: u32) u8 {
    if (t < bomber.battle_frame) return players.wire_byte(bomber.pads_at(t)[pad]);
    if (t < bomber.battle_frame + 90) return if (pad < 4) players.wire_byte(moves[pad]) else 0;
    // Then a human: a direction or a bomb, held a few ticks.
    var x = b.rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    b.rng = x;
    if (x % 8 == 0) b.held = @as(u8, 1) << @intCast((x >> 8) % 7);
    return b.held;
}

fn pump(b: *Inst, now: u64) void {
    b.sess.pump(now);
    if (b.sess.ls.state() == .desync) b.saw_desync = true;
}

fn try_step(b: *Inst) void {
    const s = &b.sess;
    while (b.racing and b.owed > 0) {
        if (!s.step(false)) return;
        b.owed -= 1;
        const t = s.ls.tick;
        if (t < b.log.len) b.log[t] = b.md.state_hash();
        for (0..16) |slot| {
            if (b.handed[slot] == null and s.world.gone >> @intCast(slot) & 1 != 0) b.handed[slot] = t - 1;
        }
    }
}

fn frame(b: *Inst, now: u64) void {
    const s = &b.sess;
    pump(b, now);
    if (!b.racing) {
        if (b.raced) {
            // Out of the race (left, rejoined, desync): stay in the lobby.
            if (s.ls.state() == .desync) s.leave(now);
            return;
        }
        const go = s.ls.is_host() and @popCount(s.ls.ready_mask()) == n_badges;
        if (s.ls.is_host()) s.ls.set_delay(opts.delay);
        if (!s.lobby(now, go)) return;
        b.racing = true;
        b.raced = true;
        b.log[0] = b.md.state_hash();
        b.slot_at_start = s.ls.local_slot();
        b.roster_start = b.conn.roster_n;
    }
    if (!s.ls.busy()) {
        b.racing = false;
        return;
    }
    const pad: usize = s.world.pad_of[s.ls.local_slot()];
    for (0..2) |_| s.submit(now, byte_for(b, pad, s.ls.local_hi));
    b.owed = 2;
    try_step(b);
    pump(b, now);
    try_step(b);
}

// ---- the run ---------------------------------------------------------------

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("party_e2e_genesis: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn usage() noreturn {
    std.debug.print(
        \\usage: party_e2e_genesis --rom FILE [--badges 2-8] [--base-port P] [--speed K]
        \\                         [--delay D] [--after T] [--join-timeout S]
        \\Listens on 127.0.0.1:P..P+N-1 for `badge lobby --no-usb --sim P-...`
        \\(carts/snouty-genesis/tools/party_e2e.sh runs both). --speed K: updates
        \\K times faster than the badge's 30 Hz.
        \\
    , .{});
    std.process.exit(2);
}

fn parse_args(init: std.process.Init.Minimal) void {
    var args = init.args.iterateAllocator(std.heap.page_allocator) catch die("args", .{});
    _ = args.next();
    while (args.next()) |a| {
        const eql = std.mem.eql;
        const num = struct {
            fn f(it: anytype) u32 {
                const s = it.next() orelse usage();
                return std.fmt.parseInt(u32, s, 10) catch usage();
            }
        }.f;
        if (eql(u8, a, "--badges")) {
            opts.badges = num(&args);
        } else if (eql(u8, a, "--base-port")) {
            opts.base_port = @intCast(num(&args));
        } else if (eql(u8, a, "--speed")) {
            opts.speed = @max(1, num(&args));
        } else if (eql(u8, a, "--delay")) {
            opts.delay = num(&args);
        } else if (eql(u8, a, "--after")) {
            opts.after = num(&args);
        } else if (eql(u8, a, "--join-timeout")) {
            opts.join_timeout_s = num(&args);
        } else if (eql(u8, a, "--rom")) {
            opts.rom = args.next() orelse usage();
        } else usage();
    }
    if (opts.badges < 3 or opts.badges > max_n) die("--badges must be 3 to 8 (a leaver and a rejoin need someone left)", .{});
    if (opts.rom.len == 0) usage();
}

var failures: u32 = 0;
fn check(ok: bool, comptime fmt: []const u8, args: anytype) void {
    if (ok) {
        std.debug.print("  ok    " ++ fmt ++ "\n", args);
    } else {
        failures += 1;
        std.debug.print("  FAIL  " ++ fmt ++ "\n", args);
    }
}

fn ignore_sigpipe() void {
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.mem.zeroes(std.posix.sigset_t),
        .flags = 0,
    };
    std.posix.sigaction(.PIPE, &act, null);
}

fn read_rom(gpa: std.mem.Allocator, path: []const u8) []u8 {
    const z = std.fmt.allocPrintSentinel(gpa, "{s}", .{path}, 0) catch die("oom", .{});
    const f = std.c.fopen(z.ptr, "rb") orelse die("cannot open {s}", .{path});
    defer _ = std.c.fclose(f);
    const buf = gpa.alloc(u8, 4 << 20) catch die("oom", .{});
    const n = std.c.fread(buf.ptr, 1, buf.len, f);
    if (n == 0) die("empty ROM {s}", .{path});
    return buf[0..n];
}

pub fn main(init: std.process.Init.Minimal) !void {
    parse_args(init);
    ignore_sigpipe();
    n_badges = opts.badges;
    const gpa = std.heap.page_allocator;
    const rom = read_rom(gpa, opts.rom);
    const crc = std.hash.Crc32.hash(rom);
    const period: u64 = 33_333 / opts.speed;
    const end_tick = bomber.battle_frame + opts.after;
    const leave_at = bomber.battle_frame + opts.after / 3;
    const rejoin_at = bomber.battle_frame + 2 * opts.after / 3;

    insts = try gpa.alloc(Inst, n_badges);
    for (insts, 0..) |*b, i| {
        var nm: [12]u8 = @splat(0);
        _ = std.fmt.bufPrint(&nm, "GEN{d}", .{i + 1}) catch unreachable;
        const md = try gpa.create(core.Md);
        md.init_in_place(core.RomSource.from_slice(rom));
        b.* = .{
            .idx = @intCast(i),
            .sess = undefined,
            .md = md,
            .period = period + 3 * @as(u64, @intCast(i)) / opts.speed,
            .log = try gpa.alloc(u32, end_tick + 512),
            .rng = 0x9E37_79B9 +% @as(u32, @intCast(i)) *% 7919,
        };
        b.sess.init(.{ .conn = &b.conn }, players.game_full, nm, md, 0xC0FFEE +% @as(u32, @intCast(i)));
        b.sess.crc = crc;
        b.sess.crc_known = true;
        b.sess.kind = md.setup.cfg.kind;
        b.sess.want_ready = true;
        b.conn.listen_fd = listen_on(opts.base_port + @as(u16, @intCast(i))) catch |e| die("cannot listen on 127.0.0.1:{d}: {t}", .{ opts.base_port + i, e });
    }
    insts[n_badges - 1].role = .leave;
    insts[n_badges - 2].role = .rejoin;
    std.debug.print("party_e2e_genesis: {d} badges on 127.0.0.1:{d}-{d}, ROM crc {X:0>8} ({s}), delay {d}, updates every {d} us (x{d}); battle from tick {d}, leave at {d}, rejoin at {d}, end at {d}\n", .{
        n_badges, opts.base_port, opts.base_port + n_badges - 1, crc, @tagName(insts[0].md.setup.cfg.kind), opts.delay, period, opts.speed, bomber.battle_frame, leave_at, rejoin_at, end_tick,
    });

    const t0 = now_us();
    for (insts, 0..) |*b, i| b.frame_top = t0 + @as(u64, @intCast(i)) * 997 / opts.speed;
    var pfds: [2 * max_n]c.pollfd = undefined;
    var owner: [2 * max_n]struct { i: u8, listener: bool } = undefined;
    var joined = false;
    var left_done = false;
    var rejoin_done = false;
    var timed_out = false;

    while (true) {
        const now = now_us();
        if (!joined) {
            var all = true;
            for (insts) |*b| all = all and (b.sess.ls.state() == .lobby and @popCount(b.sess.ls.present()) == n_badges);
            if (all) {
                joined = true;
                std.debug.print("party_e2e_genesis: all {d} in one room after {d} ms\n", .{ n_badges, (now - t0) / 1000 });
            } else if (now - t0 > @as(u64, opts.join_timeout_s) * 1_000_000) {
                for (insts) |*b| std.debug.print("  badge {d}: state {t} present {b:0>16} accepted {d}\n", .{ b.idx, b.sess.ls.state(), b.sess.ls.present(), b.conn.accepted });
                die("the badges did not all join one room (is `badge lobby --no-usb --sim {d}-{d}` running?)", .{ opts.base_port, opts.base_port + n_badges - 1 });
            }
        }
        // The events, by badge 1's tick.
        const t = insts[0].sess.ls.tick;
        if (!left_done and t >= leave_at) {
            left_done = true;
            const b = &insts[n_badges - 1];
            std.debug.print("party_e2e_genesis: tick {d}: badge {d} (slot {d}) leaves the race\n", .{ t, b.idx, b.sess.ls.local_slot() });
            b.sess.leave(now);
            b.racing = false;
        }
        if (!rejoin_done and t >= rejoin_at) {
            rejoin_done = true;
            const b = &insts[n_badges - 2];
            std.debug.print("party_e2e_genesis: tick {d}: badge {d} (slot {d}) says HELLO again on the same link (a rejoin)\n", .{ t, b.idx, b.sess.ls.local_slot() });
            b.conn.blip = true;
        }
        var done = rejoin_done;
        for (insts) |*b| {
            if (b.role == .racer and b.sess.ls.tick < end_tick) done = false;
            if (b.role != .racer and !(b.sess.ls.state() == .lobby and b.sess.ls.match_running())) done = false;
        }
        if (done) break;
        if (now - t0 > 600_000_000) {
            timed_out = true;
            break;
        }

        var next: u64 = now + 1000;
        for (insts) |*b| {
            if (now >= b.frame_top) {
                frame(b, now);
                b.window_end = now + b.period * 14_000 / 33_333;
                b.frame_top += b.period;
                if (b.frame_top <= now) b.frame_top = now + b.period;
            } else if (now < b.window_end and b.conn.rx.len() > 0) {
                pump(b, now);
                try_step(b);
            }
            next = @min(next, b.frame_top);
        }
        var np: usize = 0;
        for (insts, 0..) |*b, i| {
            service_tx(&b.conn);
            if (b.conn.listen_fd >= 0) {
                pfds[np] = .{ .fd = b.conn.listen_fd, .events = c.POLL.IN, .revents = 0 };
                owner[np] = .{ .i = @intCast(i), .listener = true };
                np += 1;
            }
            if (b.conn.client_fd >= 0) {
                var ev: i16 = 0;
                if (!b.conn.cart_open or b.conn.rx.room() > 0) ev |= c.POLL.IN;
                if (b.conn.tx.len() > 0) ev |= c.POLL.OUT;
                pfds[np] = .{ .fd = b.conn.client_fd, .events = ev, .revents = 0 };
                owner[np] = .{ .i = @intCast(i), .listener = false };
                np += 1;
            }
        }
        const t_poll = now_us();
        const wait_ms: c_int = if (next <= t_poll) 0 else @intCast(@min(1, (next - t_poll + 999) / 1000));
        _ = c.poll(&pfds, @intCast(np), wait_ms);
        for (pfds[0..np], owner[0..np]) |p, o| {
            if (p.revents == 0) continue;
            const conn = &insts[o.i].conn;
            if (o.listener) accept_one(conn) else if (p.fd == conn.client_fd) {
                service_rx(conn, p.revents);
                service_tx(conn);
            }
        }
    }

    report(t0, timed_out, end_tick);
    for (insts) |*b| {
        if (b.conn.client_fd >= 0) reset_close(b.conn.client_fd);
        if (b.conn.listen_fd >= 0) _ = c.close(b.conn.listen_fd);
    }
    if (failures != 0) {
        std.debug.print("party_e2e_genesis: {d} check(s) FAILED\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("party_e2e_genesis: PASS\n", .{});
}

fn report(t0: u64, timed_out: bool, end_tick: u32) void {
    std.debug.print("party_e2e_genesis: {d} badges, {d} s\n", .{ n_badges, (now_us() - t0) / 1_000_000 });
    check(!timed_out, "finished in time", .{});
    check(insts[0].md.setup.cfg.kind == .tap1, "Mega Bomberman's Team Player plugged in on every badge", .{});
    var min_tick: u32 = std.math.maxInt(u32);
    for (insts) |*b| if (b.role == .racer) {
        min_tick = @min(min_tick, b.sess.ls.tick);
    };
    check(min_tick >= end_tick, "every racer reached tick {d} (lowest {d})", .{ end_tick, min_tick });
    for (insts) |*b| check(!b.saw_desync, "badge {d}: no desync ({d} hash checks ok)", .{ b.idx, b.sess.ls.stats.checks_ok });
    const r = &insts[0];
    var bad: u32 = 0;
    for (insts[1..]) |*b| {
        if (!b.raced) continue;
        const upto = @min(b.sess.ls.tick, min_tick);
        for (0..upto + 1) |t| {
            if (b.log[t] != r.log[t]) {
                std.debug.print("  badge {d} and badge {d} differ at tick {d}\n", .{ r.idx, b.idx, t });
                bad += 1;
                break;
            }
        }
    }
    check(bad == 0, "every badge logged the same console hash at every tick (racers to tick {d})", .{min_tick});
    for (insts) |*x| {
        if (x.role == .racer) continue;
        const slot = x.slot_at_start;
        var tick: ?u32 = null;
        var same = true;
        var all = true;
        for (insts) |*b| {
            if (b.role != .racer) continue;
            const h = b.handed[slot] orelse {
                all = false;
                continue;
            };
            if (tick) |t| same = same and t == h else tick = h;
        }
        check(all and same, "{s} badge {d} (slot {d}): pad released from tick {?d} on every racer", .{ @tagName(x.role), x.idx, slot, tick });
        check(x.sess.ls.state() == .lobby and x.sess.ls.match_running(), "{s} badge {d}: back in the lobby as slot {d}, MATCH IN PROGRESS", .{ @tagName(x.role), x.idx, x.sess.ls.local_slot() });
    }
    const rj = &insts[n_badges - 2];
    const bitv = @as(u16, 1) << rj.slot_at_start;
    var left = false;
    var back = false;
    for (r.conn.rosters[r.roster_start..r.conn.roster_n]) |mask| {
        if (mask & bitv == 0) left = true else if (left) back = true;
    }
    check(left and back, "the rejoin: badge 0 saw slot {d} leave the roster, then come back", .{rj.slot_at_start});
    check(rj.conn.accepted == 1, "the rejoin stayed on its link (accepted {d})", .{rj.conn.accepted});
    var bytes_out: u64 = 0;
    var bytes_in: u64 = 0;
    var ticks: u64 = 0;
    var stalls: u64 = 0;
    for (insts) |*b| if (b.role == .racer) {
        bytes_out += b.conn.bytes_out;
        bytes_in += b.conn.bytes_in;
        ticks += b.sess.ls.tick;
        stalls += b.sess.ls.stats.stalls;
    };
    std.debug.print("  stats: wire bytes per racer per tick out {d}.{d:0>2} in {d}.{d:0>2}; step stalls {d}\n", .{ bytes_out / @max(ticks, 1), (bytes_out * 100 / @max(ticks, 1)) % 100, bytes_in / @max(ticks, 1), (bytes_in * 100 / @max(ticks, 1)) % 100, stalls });
}

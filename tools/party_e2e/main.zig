//! Party lockstep end to end over the real relay (docs/LOCKSTEP_N.md,
//! section "End to end"; run by tools/party_e2e.sh).
//!
//! One process plays N badges. Each badge is what the fork simulator is
//! to `badge lobby` (sycl-badge-fork 8ca6da6, src/simulator/serial.zig):
//! a TCP listener on 127.0.0.1:<base + i> serving one client at a time (a
//! second connection is reset at once), the cart's receive ring (4 KiB)
//! filled from the socket only while it has room (TCP back-pressure), the
//! transmit ring (1 KiB) drained to the socket, its bytes discarded while
//! no client is connected, `connected()` = a client is connected. On that
//! port a `LockstepN` (lib/lockstep_n.zig, the cart's code unchanged)
//! plays Snoutenstein's party deathmatch (`match.GN`), its input byte from
//! bot.zig for its own slot, at the badge's own 60 Hz frame: pump and
//! submit at the frame's top, then pump whenever bytes arrive until 14 ms,
//! then nothing until the next frame (vsync), as a cart does.
//!
//! The relay is the real `badge lobby` (python), started by the script
//! with `--no-usb --sim <ports>`; it connects to the listeners as it does
//! to simulators. Scenarios:
//!   plain:  N badges race to the frag limit; every badge logs its World
//!           hash at every tick and all logs must agree.
//!   events: 8 or more badges; mid-race one badge unplugs (its simulator
//!           quits), one rejoins on the same connection (a HELLO while in
//!           the room: the relay's leave + fresh join), one is reset and
//!           reconnected by the relay (a fresh join), and one freezes (its
//!           cart stops reading and sending: the others stall-drop it, the
//!           relay removes it once its backlog passes `--queue-limit` for
//!           1 s; it wakes, finds itself dropped, goes back to the lobby).
//!           The rest race to the frag limit; each leaver must be handed to
//!           the AI on the same tick on every badge, logs must agree.
//! `--pty LIST` puts those badges on a pseudo-terminal instead (the relay
//! opens it with `--port /dev/pts/N`, its serial path, as it opens a badge's
//! /dev/ttyACM*): a tty buffers about 20 KB, as USB does a few KB, where
//! the relay's TCP socket buffers megabytes, so only there does a badge
//! that stopped reading back up into the relay's own queue and get
//! removed. The events scenario puts its frozen badge on a pty.
//! Exit status 0 when every check holds. Linux and macOS (libc).
const std = @import("std");
const lockstep_n = @import("lockstep_n");
const stein = @import("stein");
const match = stein.match;
const bot = stein.bot;
const levels = stein.levels;
const c = std.c;

const party = lockstep_n.party;
const max_n = 16;
const rx_size: u32 = 4096; // cart_serial.Options defaults
const tx_size: u32 = 1024;
const check_every: u32 = 32;

// ---- the game: the cart's own party namespace, as cart/src/party.zig uses it

const G = match.GN;

const LS = lockstep_n.LockstepN(Port, G);

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
            if (at < n and body[at] < max_n) mask |= @as(u16, 1) << @intCast(body[at]);
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

const Latency = struct {
    /// 10 us buckets up to 200 ms.
    hist: [20_000]u32 = @splat(0),
    n: u64 = 0,
    max: u64 = 0,
    sum: u64 = 0,
    fn add(l: *Latency, us: u64) void {
        l.hist[@min(us / 10, l.hist.len - 1)] += 1;
        l.n += 1;
        l.sum += us;
        l.max = @max(l.max, us);
    }
    fn pct(l: *const Latency, p: u64) u64 {
        if (l.n == 0) return 0;
        const want = (l.n * p + 99) / 100;
        var acc: u64 = 0;
        for (l.hist, 0..) |h, i| {
            acc += h;
            if (acc >= want) return i * 10 + 5;
        }
        return l.max;
    }
};

const Role = enum { racer, unplug, rejoin, reconnect, freeze };

const Inst = struct {
    idx: u8,
    role: Role = .racer,
    conn: Conn = .{},
    ls: LS,
    w: match.World = undefined,
    period: u64,
    frame_top: u64 = 0,
    window_end: u64 = 0,
    stepped: bool = true,
    racing: bool = false,
    raced: bool = false,
    auto_ready: bool = true,
    frozen: bool = false,
    gone: bool = false,
    saw_dropped: bool = false,
    saw_desync: bool = false,
    over_at: ?u32 = null,
    log: []u32,
    handed: [max_n]?u32 = @splat(null),
    prev_bots: u16 = 0,
    race_frames: u64 = 0,
    wait_frames: u64 = 0,
    wait_run: u32 = 0,
    wait_max: u32 = 0,
    submit_at: [1024]u64 = @splat(0),
    seen_hi: [max_n]u32 = @splat(0),
    slot_at_start: u4 = 0,
    /// `conn.roster_n` when the race started.
    roster_start: u8 = 0,
};

var insts: []Inst = undefined;
var n_badges: usize = 0;
/// Race slot -> instance (from each racer's own slot at the start).
var slot_inst: [max_n]?u8 = @splat(null);
var lat: Latency = .{};

const Opts = struct {
    badges: usize = 2,
    base_port: u16 = 7341,
    speed: u32 = 1,
    delay: ?u32 = null,
    arena: ?u8 = null,
    frags: u8 = 0,
    bugs: bool = true,
    scenario: enum { plain, events } = .plain,
    max_ticks: u32 = 30_000,
    /// SO_RCVBUF of each badge's socket (0: the system's): small models a
    /// badge's USB, which holds little more than the cart's ring, so a
    /// stopped cart backs bytes up into the relay soon.
    rcvbuf: u32 = 0,
    /// Badges on a pty (bit per index).
    pty_mask: u16 = 0,
    /// Where to write the pty paths (one per line, for `--port`).
    pty_file: ?[]const u8 = null,
    join_timeout_s: u32 = 20,
    seed: u32 = 1,
};
var opts: Opts = .{};
var rules: [2]u8 = undefined;

fn level_of(w: *const match.World) *const levels.Level {
    return &levels.all[w.gs.level];
}

/// After every pump of a racer: the inputs that arrived, timed from the
/// sender's submit (one process, one clock).
fn after_pump(b: *Inst, now: u64) void {
    if (!b.racing or b.role != .racer) return;
    const me = b.ls.local_slot();
    var m = b.ls.race.mask & ~(@as(u16, 1) << me);
    while (m != 0) : (m &= m - 1) {
        const s: u4 = @intCast(@ctz(m));
        const from = slot_inst[s] orelse continue;
        while (b.seen_hi[s] < b.ls.hi[s]) : (b.seen_hi[s] += 1) {
            const t = b.seen_hi[s];
            const at = insts[from].submit_at[t % 1024];
            if (at != 0) lat.add(now -| at);
        }
    }
}

fn pump(b: *Inst, now: u64) void {
    b.ls.pump(now);
    after_pump(b, now);
    switch (b.ls.state()) {
        .dropped => b.saw_dropped = true,
        .desync => b.saw_desync = true,
        else => {},
    }
}

fn try_step(b: *Inst) void {
    if (!b.racing or b.stepped) return;
    if (b.ls.tick >= opts.max_ticks) return;
    if (!b.ls.step(&b.w)) return;
    b.stepped = true;
    const t = b.ls.tick;
    b.log[t] = G.hash(&b.w);
    const bots = b.w.m.bots;
    var nb = bots & ~b.prev_bots;
    while (nb != 0) : (nb &= nb - 1) b.handed[@ctz(nb)] = t - 1;
    b.prev_bots = bots;
    if (b.w.m.over and b.over_at == null) b.over_at = t;
}

fn frame(b: *Inst, now: u64) void {
    const ls = &b.ls;
    pump(b, now);
    if (ls.state() == .lobby and b.auto_ready) {
        if (ls.is_host()) {
            ls.set_rules(rules);
            ls.set_delay(opts.delay.?);
        }
        ls.set_pick(0, true);
        if (ls.is_host() and @popCount(ls.ready_mask()) >= n_badges) _ = ls.go(now);
    }
    if (ls.take_started()) {
        // As cart/src/party.zig starts a match.
        const picks = ls.picks();
        const team = G.team_of(&picks);
        G.start(&b.w, ls.rules().?, ls.participants(), &team, ls.seed());
        b.racing = true;
        b.raced = true;
        b.log[0] = G.hash(&b.w);
        b.prev_bots = 0;
        b.slot_at_start = ls.local_slot();
        b.roster_start = b.conn.roster_n;
        slot_inst[ls.local_slot()] = b.idx;
        b.seen_hi = @splat(ls.delay);
    }
    if (b.racing and !ls.busy()) {
        // Out of the race (dropped, desync, lost the room).
        b.racing = false;
        b.auto_ready = false;
    }
    switch (ls.state()) {
        .dropped, .desync => ls.leave(now),
        else => {},
    }
    if (b.racing) {
        const before = ls.local_hi;
        const byte = match.byte_of(bot.think(&b.w, level_of(&b.w), ls.local_slot()));
        if (before < ls.tick + ls.delay + 1) b.submit_at[before % 1024] = now;
        ls.submit(now, byte);
        b.stepped = false;
        try_step(b);
    } else b.stepped = true;
    pump(b, now);
    try_step(b);
}

/// Frame bookkeeping at the frame's end: frames of a running match (the
/// World not over) without a tick.
fn end_frame(b: *Inst) void {
    if (!b.racing or b.over_at != null) return;
    b.race_frames += 1;
    if (!b.stepped) {
        b.wait_frames += 1;
        b.wait_run += 1;
        b.wait_max = @max(b.wait_max, b.wait_run);
    } else b.wait_run = 0;
}

// ---- the run ---------------------------------------------------------------

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("party_e2e: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn usage() noreturn {
    std.debug.print(
        \\usage: party_e2e [--badges N] [--base-port P] [--scenario plain|events]
        \\                 [--speed K] [--delay D] [--arena 0-2] [--frags 0-4] [--no-bugs]
        \\                 [--max-ticks T] [--join-timeout S] [--seed S] [--rcvbuf BYTES]
        \\                 [--pty I,J,...] [--pty-file FILE]
        \\Listens on 127.0.0.1:P..P+N-1 for `badge lobby --no-usb --sim P-...`
        \\(tools/party_e2e.sh runs both). --speed K: K frames per 16.7 ms (the
        \\delay defaults to 3 x K ticks, the same wall time).
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
        } else if (eql(u8, a, "--arena")) {
            opts.arena = @intCast(num(&args));
        } else if (eql(u8, a, "--frags")) {
            opts.frags = @intCast(num(&args));
        } else if (eql(u8, a, "--no-bugs")) {
            opts.bugs = false;
        } else if (eql(u8, a, "--max-ticks")) {
            opts.max_ticks = num(&args);
        } else if (eql(u8, a, "--join-timeout")) {
            opts.join_timeout_s = num(&args);
        } else if (eql(u8, a, "--seed")) {
            opts.seed = num(&args);
        } else if (eql(u8, a, "--rcvbuf")) {
            opts.rcvbuf = num(&args);
        } else if (eql(u8, a, "--pty-file")) {
            opts.pty_file = args.next() orelse usage();
        } else if (eql(u8, a, "--pty")) {
            var it = std.mem.splitScalar(u8, args.next() orelse usage(), ',');
            while (it.next()) |x| opts.pty_mask |= @as(u16, 1) << (std.fmt.parseInt(u4, x, 10) catch usage());
        } else if (eql(u8, a, "--scenario")) {
            const sc = args.next() orelse usage();
            opts.scenario = if (eql(u8, sc, "plain")) .plain else if (eql(u8, sc, "events")) .events else usage();
        } else usage();
    }
    if (opts.badges < 2 or opts.badges > max_n) die("--badges must be 2 to 16", .{});
    if (opts.scenario == .events and opts.badges < 6) die("--scenario events needs 6 or more badges", .{});
    if (opts.delay == null) opts.delay = @min(3 * opts.speed, LS.delay_cap);
    // The events scenario's frozen badge sits on a pty (see the top).
    if (opts.scenario == .events and opts.pty_file != null) opts.pty_mask |= @as(u16, 1) << @intCast(opts.badges - 4);
    if (opts.pty_mask != 0 and opts.pty_file == null) die("--pty needs --pty-file (the script passes the paths to the relay)", .{});
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

pub fn main(init: std.process.Init.Minimal) !void {
    parse_args(init);
    ignore_sigpipe();
    n_badges = opts.badges;
    const arena = opts.arena orelse levels.suggest_arena(@intCast(n_badges));
    rules = (match.Rules{ .arena = arena, .frags = opts.frags, .bugs = opts.bugs }).encode2();
    const period: u64 = 16_667 / opts.speed;

    const gpa = std.heap.page_allocator;
    insts = try gpa.alloc(Inst, n_badges);
    for (insts, 0..) |*b, i| {
        var nm: [12]u8 = @splat(0);
        _ = std.fmt.bufPrint(&nm, "E2E{d}", .{i}) catch unreachable;
        b.* = .{
            .idx = @intCast(i),
            .ls = undefined,
            .period = period + 3 * @as(u64, @intCast(i)) / opts.speed,
            .log = try gpa.alloc(u32, opts.max_ticks + 1),
        };
        b.ls = LS.init(.{ .conn = &b.conn }, .{ .game = lockstep_n.games.snoutenstein, .name = nm, .max_players = 16 }, opts.seed *% 2_654_435_761 +% @as(u32, @intCast(i)) *% 40_503 +% 1);
        if (opts.pty_mask & (@as(u16, 1) << @intCast(i)) != 0) {
            open_pty(&b.conn) catch die("cannot open a pty", .{});
        } else b.conn.listen_fd = listen_on(opts.base_port + @as(u16, @intCast(i))) catch |e| die("cannot listen on 127.0.0.1:{d}: {t} (a simulator running?)", .{ opts.base_port + i, e });
    }
    if (opts.pty_file) |path| {
        var text: [16 * 70]u8 = undefined;
        var n: usize = 0;
        for (insts) |*b| if (b.conn.pty) {
            const p = std.mem.sliceTo(&b.conn.pty_path, 0);
            @memcpy(text[n..][0..p.len], p);
            text[n + p.len] = '\n';
            n += p.len + 1;
        };
        const f = std.c.fopen(@ptrCast((std.fmt.allocPrintSentinel(gpa, "{s}", .{path}, 0) catch die("oom", .{})).ptr), "w") orelse die("cannot write {s}", .{path});
        _ = std.c.fwrite(&text, 1, n, f);
        _ = std.c.fclose(f);
    }
    if (opts.scenario == .events) {
        insts[n_badges - 1].role = .unplug;
        insts[n_badges - 2].role = .rejoin;
        insts[n_badges - 3].role = .reconnect;
        insts[n_badges - 4].role = .freeze;
    }
    std.debug.print("party_e2e: {d} badges on 127.0.0.1:{d}-{d}, {s}, arena {s}, frag limit {d}, bugs {s}, delay {d}, {d} Hz frames, World {d} B\n", .{
        n_badges,                       opts.base_port,            opts.base_port + n_badges - 1,
        @tagName(opts.scenario),        levels.arena_names[arena], (match.Rules{ .frags = opts.frags }).frag_limit(),
        if (opts.bugs) "on" else "off", opts.delay.?,              60 * opts.speed,
        @sizeOf(match.World),
    });

    const t0 = now_us();
    for (insts, 0..) |*b, i| b.frame_top = t0 + @as(u64, @intCast(i)) * 997 / opts.speed;

    var pfds: [2 * max_n]c.pollfd = undefined;
    var owner: [2 * max_n]struct { i: u8, listener: bool } = undefined;

    var started_at: ?u64 = null;
    var joined_at: ?u64 = null;
    var all_over_at: ?u64 = null;
    var ev_done: [4]?u32 = @splat(null);
    var freeze_since: u64 = 0;
    var unfrozen = false;
    var result_timeout = false;

    while (true) {
        const now = now_us();
        // ---- what the run waits for
        if (joined_at == null) {
            var all = true;
            for (insts) |*b| all = all and (b.ls.state() == .lobby and @popCount(b.ls.present()) == n_badges);
            if (all) {
                joined_at = now;
                std.debug.print("party_e2e: all {d} in one room after {d} ms\n", .{ n_badges, (now - t0) / 1000 });
            } else if (now - t0 > @as(u64, opts.join_timeout_s) * 1_000_000) {
                for (insts) |*b| std.debug.print("  badge {d}: state {t} present {b:0>16} accepted {d}\n", .{ b.idx, b.ls.state(), b.ls.present(), b.conn.accepted });
                die("the badges did not all join one room in {d} s (is `badge lobby --no-usb --sim {d}-{d}` running?)", .{ opts.join_timeout_s, opts.base_port, opts.base_port + n_badges - 1 });
            }
        }
        if (started_at == null) {
            var all = true;
            for (insts) |*b| all = all and b.racing;
            if (all) started_at = now;
        }
        // ---- the events, by the tick of badge 0 (always a racer)
        if (opts.scenario == .events and started_at != null) {
            const t = insts[0].ls.tick;
            const plan = [4]struct { at: u32, role: Role }{ .{ .at = 200, .role = .unplug }, .{ .at = 350, .role = .rejoin }, .{ .at = 500, .role = .reconnect }, .{ .at = 650, .role = .freeze } };
            for (plan, 0..) |p, k| {
                if (ev_done[k] != null or t < p.at) continue;
                ev_done[k] = t;
                for (insts) |*b| {
                    if (b.role != p.role) continue;
                    std.debug.print("party_e2e: tick {d}: badge {d} (slot {d}) {s}\n", .{ t, b.idx, b.ls.local_slot(), switch (p.role) {
                        .unplug => "unplugged (its simulator quits)",
                        .rejoin => "says HELLO again on the same link (a rejoin)",
                        .reconnect => "is reset; the relay reconnects it",
                        .freeze => "freezes (stops reading and sending)",
                        .racer => unreachable,
                    } });
                    switch (p.role) {
                        .unplug => {
                            drop_client(&b.conn, false);
                            if (b.conn.listen_fd >= 0) _ = c.close(b.conn.listen_fd);
                            b.conn.listen_fd = -1;
                            if (b.conn.master_fd >= 0) _ = c.close(b.conn.master_fd);
                            b.conn.master_fd = -1;
                            b.gone = true;
                        },
                        .rejoin => b.conn.blip = true,
                        .reconnect => drop_client(&b.conn, false),
                        .freeze => {
                            b.frozen = true;
                            freeze_since = now;
                        },
                        .racer => {},
                    }
                }
            }
            // The frozen badge wakes a second after the relay removed it
            // (or after 90 s, and the check below fails).
            const fz = &insts[n_badges - 4];
            if (fz.frozen and !unfrozen) {
                const removed = fz.conn.closed_by_peer > 0;
                if ((removed and now -| fz.conn.closed_at > 1_000_000) or now -| freeze_since > 90_000_000) {
                    fz.frozen = false;
                    unfrozen = true;
                    fz.frame_top = now;
                    std.debug.print("party_e2e: badge {d} wakes ({d} ms after freezing; the relay {s} it)\n", .{ fz.idx, (now -| freeze_since) / 1000, if (removed) "had removed" else "had NOT removed" });
                }
            }
        }
        // ---- done?
        if (started_at != null) {
            var done = true;
            var all_over = true;
            for (insts) |*b| {
                if (b.role != .racer) continue;
                const o = b.over_at orelse {
                    done = false;
                    all_over = false;
                    continue;
                };
                if (b.ls.tick < o + 2 * check_every + opts.delay.? + 2) done = false;
            }
            if (all_over and all_over_at == null) all_over_at = now;
            if (opts.scenario == .events) {
                if (!unfrozen) done = false;
                for (insts) |*b| {
                    if (b.role == .racer or b.role == .unplug) continue;
                    if (b.ls.state() != .lobby or !b.ls.match_running()) done = false;
                }
                if (all_over_at) |a| if (now - a > 30_000_000) {
                    result_timeout = true;
                    break;
                };
            }
            if (done) break;
            var stuck = true;
            for (insts) |*b| if (b.role == .racer and b.ls.tick < opts.max_ticks) {
                stuck = false;
            };
            if (stuck) break;
        }
        if (now - t0 > 900_000_000) {
            result_timeout = true;
            break;
        }

        for (insts) |*b| follow_pty(&b.conn);
        // ---- badges: frame tops, then pumps while bytes arrive until 14 ms
        var next: u64 = now + 1000;
        for (insts) |*b| {
            if (b.gone or b.frozen) continue;
            if (now >= b.frame_top) {
                if (b.frame_top != 0) end_frame(b);
                frame(b, now);
                b.window_end = now + b.period * 14_000 / 16_667;
                b.frame_top += b.period;
                if (b.frame_top <= now) b.frame_top = now + b.period;
            } else if (now < b.window_end and b.conn.rx.len() > 0) {
                pump(b, now);
                try_step(b);
            }
            next = @min(next, b.frame_top);
        }
        // ---- sockets
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

    report(t0, result_timeout);
    for (insts) |*b| {
        if (b.conn.client_fd >= 0 and !b.conn.pty) reset_close(b.conn.client_fd);
        if (b.conn.listen_fd >= 0) _ = c.close(b.conn.listen_fd);
        if (b.conn.master_fd >= 0) _ = c.close(b.conn.master_fd);
    }
    if (failures != 0) {
        std.debug.print("party_e2e: {d} check(s) FAILED\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("party_e2e: PASS\n", .{});
}

fn report(t0: u64, timed_out: bool) void {
    const now = now_us();
    std.debug.print("party_e2e: {d} badges, {s}, {d} s\n", .{ n_badges, @tagName(opts.scenario), (now - t0) / 1_000_000 });
    check(!timed_out, "finished in time", .{});

    // Every racer reached the end of the match, no badge saw a desync.
    var ref: ?*Inst = null;
    var min_tick: u32 = std.math.maxInt(u32);
    for (insts) |*b| {
        if (b.role != .racer) continue;
        if (ref == null) ref = b;
        min_tick = @min(min_tick, b.ls.tick);
        check(b.over_at != null, "badge {d}: the match ended (frag limit) at tick {?d}, winner {d}", .{ b.idx, b.over_at, b.w.m.winner });
    }
    for (insts) |*b| check(!b.saw_desync, "badge {d}: no desync ({d} hash checks ok)", .{ b.idx, b.ls.stats.checks_ok });
    const r = ref.?;
    // The same World at every tick: racers to the lowest tick, leavers to
    // where they stopped.
    var bad: u32 = 0;
    for (insts) |*b| {
        if (b == r or !b.raced) continue;
        const upto = if (b.role == .racer) min_tick else @min(b.ls.tick, min_tick);
        for (0..upto + 1) |t| {
            if (b.log[t] != r.log[t]) {
                std.debug.print("  badge {d} and badge {d} differ at tick {d}\n", .{ r.idx, b.idx, t });
                bad += 1;
                break;
            }
        }
    }
    check(bad == 0, "every badge logged the same World hash at every tick (racers to tick {d})", .{min_tick});
    var final_same = true;
    for (insts) |*b| if (b.role == .racer and G.hash(&b.w) != G.hash(&r.w)) {
        final_same = false;
    };
    check(final_same, "every racer ends with the same World (hash {X:0>8})", .{G.hash(&r.w)});

    // Frames without a tick, while the match ran.
    var frames: u64 = 0;
    var waits: u64 = 0;
    var wmax: u32 = 0;
    var bytes_in: u64 = 0;
    var bytes_out: u64 = 0;
    var ticks: u64 = 0;
    var racers: u64 = 0;
    for (insts) |*b| {
        if (b.role != .racer) continue;
        racers += 1;
        frames += b.race_frames;
        waits += b.wait_frames;
        wmax = @max(wmax, b.wait_max);
        bytes_in += b.conn.bytes_in;
        bytes_out += b.conn.bytes_out;
        ticks += b.ls.tick;
    }
    std.debug.print("  stats: {d} ticks per racer; frames without a tick {d} of {d} ({d}.{d:0>2}%), longest run {d}; wire bytes per racer per tick out {d}.{d:0>2} in {d}.{d:0>2}\n", .{
        ticks / racers,                          waits,                                    frames,
        waits * 100 / @max(frames, 1),           (waits * 10000 / @max(frames, 1)) % 100,  wmax,
        bytes_out / @max(ticks, 1),              (bytes_out * 100 / @max(ticks, 1)) % 100, bytes_in / @max(ticks, 1),
        (bytes_in * 100 / @max(ticks, 1)) % 100,
    });
    std.debug.print("  input latency (a badge's submit to another badge's LockstepN, through the relay; 10 us buckets): p50 {d}.{d:0>2} ms, p99 {d}.{d:0>2} ms, max {d}.{d:0>2} ms, mean {d}.{d:0>2} ms, {d} samples\n", .{
        lat.pct(50) / 1000, lat.pct(50) % 1000 / 10, lat.pct(99) / 1000,              lat.pct(99) % 1000 / 10,
        lat.max / 1000,     lat.max % 1000 / 10,     lat.sum / @max(lat.n, 1) / 1000, lat.sum / @max(lat.n, 1) % 1000 / 10,
        lat.n,
    });
    if (opts.scenario == .plain) {
        // Without events nobody waits long: one late frame of the relay is
        // at most a few frames without a tick.
        check(wmax <= 6, "no long stall (longest run of frames without a tick {d})", .{wmax});
        check(waits * 100 <= frames * 5, "frames without a tick under 5%", .{});
        return;
    }

    // ---- events: each leaver handed to the AI on the same tick everywhere
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
        check(all and same, "{s} badge {d} (slot {d}): AI from tick {?d} on every racer", .{ @tagName(x.role), x.idx, slot, tick });
    }
    // The rejoin: every racer saw the slot leave the roster, then come back.
    const rj = &insts[n_badges - 2];
    for (insts) |*b| {
        if (b.role != .racer) continue;
        const bitv = @as(u16, 1) << rj.slot_at_start;
        var left = false;
        var back = false;
        // Every ROSTER the relay sent this badge, in order (the tap).
        for (b.conn.rosters[b.roster_start..b.conn.roster_n]) |mask| {
            if (mask & bitv == 0) left = true else if (left) back = true;
        }
        if (b.idx == 0) check(left and back, "the rejoin: badge 0 saw slot {d} leave the roster, then a ROSTER with it again", .{rj.slot_at_start});
        if (!(left and back) and b.idx != 0) check(false, "the rejoin: badge {d} saw the leave and the join", .{b.idx});
    }
    check(rj.conn.accepted == 1, "the rejoin stayed on its link (accepted {d})", .{rj.conn.accepted});
    for (insts) |*x| {
        if (x.role == .racer or x.role == .unplug) continue;
        check(x.ls.state() == .lobby and x.ls.match_running(), "{s} badge {d}: back in the lobby as slot {d}, MATCH IN PROGRESS", .{ @tagName(x.role), x.idx, x.ls.local_slot() });
    }
    const rc = &insts[n_badges - 3];
    check(rc.conn.accepted >= 2, "the reconnect: the relay connected again ({d} links)", .{rc.conn.accepted});
    const fz = &insts[n_badges - 4];
    check(fz.conn.closed_by_peer >= 1, "the frozen badge: the relay removed it (closed its link)", .{});
    var gone_seen = true;
    for (insts) |*b| {
        if (b.role != .racer) continue;
        var seen = false;
        for (b.conn.rosters[b.roster_start..b.conn.roster_n]) |mask| seen = seen or mask & (@as(u16, 1) << fz.slot_at_start) == 0;
        gone_seen = gone_seen and seen;
    }
    check(gone_seen, "the frozen badge: every racer saw it leave the roster", .{});
    // Waking, it finds its link closed by the relay (then reconnects and
    // joins afresh), or, if the relay had reconnected it already, reads the
    // DROP from its ring first: either way it is back in the lobby (above).
    check(fz.saw_dropped or fz.conn.closed_by_peer >= 1, "the frozen badge woke {s}", .{if (fz.saw_dropped) "DROPPED" else "to a closed link, then joined afresh"});
}

//! Warbirds over the real `badge lobby` relay, no hardware
//! (docs/COMLYNX.md section 10; run by tools/lynx_e2e.sh). The pattern of
//! tools/party_e2e/main.zig at the repository root (its socket and ring
//! code is reused here): one process plays N badges, each what the fork
//! simulator is to `badge lobby` (a TCP listener on 127.0.0.1:<base + i>,
//! one client at a time, the cart's receive ring filled only while it has
//! room, the transmit ring drained to the socket). On each port runs the
//! Lynx cart's own network code, unchanged: lib/party.zig's client,
//! frontend/lynxnet.zig, the core with its UART, Warbirds from Adrian's
//! local dump, at the badge's own 60 Hz, with
//! tools/scripts/warbirds_link.json from each restart.
//!
//! The lobby: every badge joins the ROM's room, says ready, the host (id
//! 0) sends GO (to = 0xFE: every badge restarts on the same message) with
//! D (`--d-ms`, 0 = relay mode). Pass: every badge shows Warbirds's "N
//! PLAYERS" and reaches the cockpit. `--events`: after the game starts,
//! the last badge says HELLO again on its link (a rejoin: the relay's
//! leave + fresh join) and the one before it unplugs; the others must
//! keep playing (their games go on, the leavers' frames stop). Prints the
//! message lag (a peer's heartbeat to this badge's link time when the
//! message is taken from the ring: the relay's latency plus up to a frame
//! of waiting for the badge's next frame), the stalls and the traffic.
//! Linux (libc).
const std = @import("std");
const core = @import("core");
const party = @import("party");
const lynxnet = @import("lynxnet");
const runner = @import("runner");
const c = std.c;

const max_n = 8;
const rx_size: u32 = 2048; // frontend/linkport.zig's rings
const tx_size: u32 = 512;

fn now_us() u64 {
    var ts: c.timespec = undefined;
    _ = c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000 + @as(u64, @intCast(ts.nsec)) / 1000;
}

// ---- the simulator's side of one badge (as tools/party_e2e/main.zig) ----

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
        fn front(s: *const Self) []const u8 {
            const at = s.r % cap;
            return s.buf[at..@min(cap, at + s.len())];
        }
        fn back(s: *Self) []u8 {
            const at = s.w % cap;
            return s.buf[at..@min(cap, at + s.room())];
        }
    };
}

const Conn = struct {
    listen_fd: c_int = -1,
    client_fd: c_int = -1,
    rx: Ring(rx_size) = .{},
    tx: Ring(tx_size) = .{},
    cart_open: bool = false,
    /// `connected()` reads false once: the cart says HELLO again on the
    /// same link (a rejoin).
    blip: bool = false,
    accepted: u32 = 0,
    bytes_in: u64 = 0,
    bytes_out: u64 = 0,
    /// A tap on what the relay sends this badge: each ComLynx message's
    /// relay latency (its sender's send to here, one process, one clock).
    tap: party.Decoder = .{},
};

/// Wall time each lobby id sent each message seq (lynxnet's `seq`).
var sent_at: [max_n][256]u64 = @splat(@splat(0));
var relay_hist: [2000]u64 = @splat(0);
var relay_n: u64 = 0;
var relay_max: u64 = 0;

fn tap(conn: *Conn, bytes: []const u8) void {
    var body: [party.max_body]u8 = undefined;
    const now = now_us();
    for (bytes) |b| {
        const n = conn.tap.push(b, &body) orelse continue;
        if (n < 4 or body[0] != party.T.data or body[2] != lynxnet.Msg.frames or body[1] >= max_n) continue;
        const at = sent_at[body[1]][body[3]];
        if (at == 0 or now < at) continue;
        const us = now - at;
        relay_hist[@min(us / 100, relay_hist.len - 1)] += 1;
        relay_n += 1;
        relay_max = @max(relay_max, us);
    }
}

fn relay_pct(p: u64) u64 {
    if (relay_n == 0) return 0;
    const want = (relay_n * p + 99) / 100;
    var acc: u64 = 0;
    for (relay_hist, 0..) |h, i| {
        acc += h;
        if (acc >= want) return i * 100 + 50;
    }
    return relay_max;
}

const Port = struct {
    conn: *Conn,
    pub fn supported(_: *Port) bool {
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
    var addr: c.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7F00_0001) };
    if (c.bind(fd, @ptrCast(&addr), @sizeOf(c.sockaddr.in)) != 0) {
        _ = c.close(fd);
        return error.AddressInUse;
    }
    if (c.listen(fd, 4) != 0) return error.Listen;
    return fd;
}

fn reset_close(fd: c_int) void {
    const l: c.linger = .{ .onoff = 1, .linger = 0 };
    _ = c.setsockopt(fd, c.SOL.SOCKET, c.SO.LINGER, &l, @sizeOf(c.linger));
    _ = c.close(fd);
}

const send_flags: u32 = c.MSG.DONTWAIT | (if (@hasDecl(c.MSG, "NOSIGNAL")) c.MSG.NOSIGNAL else 0);

fn drop_client(conn: *Conn) void {
    if (conn.client_fd < 0) return;
    reset_close(conn.client_fd);
    conn.client_fd = -1;
}

fn accept_one(conn: *Conn) void {
    const fd = c.accept(conn.listen_fd, null, null);
    if (fd < 0) return;
    if (conn.client_fd >= 0) {
        reset_close(fd);
        return;
    }
    set_int_opt(fd, c.IPPROTO.TCP, c.TCP.NODELAY, 1);
    conn.client_fd = fd;
    conn.accepted += 1;
}

fn service_rx(conn: *Conn) void {
    if (conn.client_fd < 0) return;
    while (true) {
        var scratch: [4096]u8 = undefined;
        const dst: []u8 = if (conn.cart_open) conn.rx.back() else &scratch;
        if (dst.len == 0) break;
        const n = c.recv(conn.client_fd, dst.ptr, dst.len, c.MSG.DONTWAIT);
        if (n == 0) return drop_client(conn);
        if (n < 0) {
            if (std.posix.errno(n) == .AGAIN) break;
            return drop_client(conn);
        }
        conn.bytes_in += @intCast(n);
        tap(conn, dst[0..@intCast(n)]);
        if (conn.cart_open) conn.rx.w +%= @intCast(n);
    }
}

fn service_tx(conn: *Conn) void {
    if (conn.client_fd < 0) {
        conn.tx.r = conn.tx.w;
        return;
    }
    while (conn.tx.len() > 0) {
        const f = conn.tx.front();
        const n = c.send(conn.client_fd, f.ptr, f.len, send_flags);
        if (n < 0) {
            if (std.posix.errno(n) == .AGAIN) return;
            return drop_client(conn);
        }
        conn.tx.r +%= @intCast(n);
        conn.bytes_out += @intCast(n);
    }
}

// ---- Warbirds probes (as tests/comlynx_warbirds.zig) ----

fn rgb(l: *const core.Lynx, x: usize, y: usize) [3]u8 {
    const f = l.frame();
    const b = f.pixels[y * 80 + x / 2];
    const pen = if (x & 1 == 0) b >> 4 else b & 0xF;
    return .{ f.bluered[pen] & 0xF, f.green[pen] & 0xF, f.bluered[pen] >> 4 };
}

fn cockpit(l: *const core.Lynx) bool {
    const w = [3]u8{ 13, 0, 0 };
    return std.mem.eql(u8, &rgb(l, 0, 1), &w) and std.mem.eql(u8, &rgb(l, 159, 1), &w);
}

/// The pixel count of the first glyph of "N PLAYERS" (2: 12, 3: 13, 4: 11).
fn players_glyph(l: *const core.Lynx) u32 {
    const o = [3]u8{ 15, 4, 0 };
    var x0: usize = 160;
    for (88..102) |y| for (90..160) |x| {
        if (std.mem.eql(u8, &rgb(l, x, y), &o)) x0 = @min(x0, x);
    };
    if (x0 == 160) return 0;
    var n: u32 = 0;
    for (88..102) |y| for (x0..@min(x0 + 7, 160)) |x| {
        if (std.mem.eql(u8, &rgb(l, x, y), &o)) n += 1;
    };
    return n;
}

fn glyph_players(g: u32) u32 {
    return switch (g) {
        12 => 2,
        13 => 3,
        11 => 4,
        else => 0,
    };
}

// ---- one badge ----

const Client = party.Client(Port);
const Net = lynxnet.Net(Client);

const Inst = struct {
    conn: Conn = .{},
    client: Client,
    net: Net,
    cport: core.comlynx.Port = .{},
    lynx: core.Lynx,
    fe: runner.Frontend = .{ .running = true },
    frame_top: u64 = 0,
    restarted_at: ?u64 = null,
    players: u32 = 0,
    cockpit_at: ?u32 = null,
    gone: bool = false,
    stepped: u64 = 0,
    stalled: u64 = 0,
};

var rom: [512 * 1024 + 64]u8 = undefined;
var script_buf: [4096]u8 = undefined;
var controls: [8000]u16 = @splat(0);
var lay: core.cart.Layout = undefined;
var insts: []Inst = undefined;

/// Message lag, 100 us buckets up to 200 ms.
var hist: [2000]u64 = @splat(0);
var lag_n: u64 = 0;
var lag_max: u64 = 0;
fn on_lag(us: u64) void {
    hist[@min(us / 100, hist.len - 1)] += 1;
    lag_n += 1;
    lag_max = @max(lag_max, us);
}
fn pct(p: u64) u64 {
    if (lag_n == 0) return 0;
    const want = (lag_n * p + 99) / 100;
    var acc: u64 = 0;
    for (hist, 0..) |h, i| {
        acc += h;
        if (acc >= want) return i * 100 + 50;
    }
    return lag_max;
}

const Opts = struct {
    badges: usize = 2,
    base_port: u16 = 27500,
    d_ms: u8 = 25,
    frames: u32 = 1500,
    events: bool = false,
    join_timeout_s: u32 = 20,
    rom_path: []const u8 = "",
};
var opts: Opts = .{};

fn die(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("lynx_e2e: " ++ fmt ++ "\n", args);
    std.process.exit(2);
}

fn usage() noreturn {
    std.debug.print(
        \\usage: lynx_e2e --rom FILE [--badges N] [--base-port P] [--d-ms D] [--frames F] [--events]
        \\Listens on 127.0.0.1:P..P+N-1 for `badge lobby --no-usb --sim P-...`
        \\(carts/snouty-lynx/tools/lynx_e2e.sh runs both). D 0 = relay mode.
        \\
    , .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = init.args.iterateAllocator(std.heap.page_allocator) catch die("args", .{});
    _ = args.next();
    while (args.next()) |a| {
        const eql = std.mem.eql;
        if (eql(u8, a, "--badges")) {
            opts.badges = std.fmt.parseInt(usize, args.next() orelse usage(), 10) catch usage();
        } else if (eql(u8, a, "--base-port")) {
            opts.base_port = std.fmt.parseInt(u16, args.next() orelse usage(), 10) catch usage();
        } else if (eql(u8, a, "--d-ms")) {
            opts.d_ms = std.fmt.parseInt(u8, args.next() orelse usage(), 10) catch usage();
        } else if (eql(u8, a, "--frames")) {
            opts.frames = std.fmt.parseInt(u32, args.next() orelse usage(), 10) catch usage();
        } else if (eql(u8, a, "--events")) {
            opts.events = true;
        } else if (eql(u8, a, "--rom")) {
            opts.rom_path = args.next() orelse usage();
        } else usage();
    }
    if (opts.rom_path.len == 0 or opts.badges < 2 or opts.badges > max_n) usage();
    var act: std.posix.Sigaction = .{ .handler = .{ .handler = std.posix.SIG.IGN }, .mask = std.mem.zeroes(std.posix.sigset_t), .flags = 0 };
    std.posix.sigaction(.PIPE, &act, null);

    var io_mem: std.Io.Threaded = .init_single_threaded;
    const io = io_mem.io();
    const cwd = std.Io.Dir.cwd();
    const file = cwd.readFile(io, opts.rom_path, &rom) catch |e| die("cannot read {s}: {t}", .{ opts.rom_path, e });
    lay = core.cart.parse(file, @intCast(file.len));
    const json = cwd.readFile(io, "carts/snouty-lynx/tools/scripts/warbirds_link.json", &script_buf) catch die("run from the repository root", .{});
    runner.parse_script(std.heap.page_allocator, json, &controls) catch die("bad script", .{});
    const crc = std.hash.Crc32.hash(file);

    const n = opts.badges;
    insts = try std.heap.page_allocator.alloc(Inst, n);
    for (insts, 0..) |*b, i| {
        b.* = .{ .client = undefined, .net = undefined, .lynx = undefined };
        b.lynx.init_in_place(core.Cart.from_slice(&lay, file));
        var nm: [12]u8 = @splat(0);
        _ = std.fmt.bufPrint(&nm, "LYNX{d}", .{i}) catch unreachable;
        b.client = Client.init(.{ .conn = &b.conn }, .{ .game = Net.game_id(crc), .name = nm, .max_players = 8 });
        b.net = Net.init(&b.client, &b.cport, crc);
        b.net.lag_sink = &on_lag;
        b.conn.listen_fd = listen_on(opts.base_port + @as(u16, @intCast(i))) catch |e| die("cannot listen on 127.0.0.1:{d}: {t}", .{ opts.base_port + i, e });
    }
    std.debug.print("lynx_e2e: {d} badges on 127.0.0.1:{d}-{d}, {s}, D {d} ms, {d} frames, events {}\n", .{
        n, opts.base_port, opts.base_port + n - 1, if (opts.d_ms == 0) "relay mode" else "timestamped", opts.d_ms, opts.frames, opts.events,
    });

    const t0 = now_us();
    // Badges' frames are not in phase (each its own 60 Hz).
    for (insts, 0..) |*b, i| b.frame_top = t0 + @as(u64, @intCast(i)) * 3_917;
    var pfds: [2 * max_n]c.pollfd = undefined;
    var owner: [2 * max_n]struct { i: u8, listener: bool } = undefined;
    var started = false;
    var joined_at: ?u64 = null;
    var ev_done = false;
    while (true) {
        const now = now_us();
        if (joined_at == null) {
            var all = true;
            for (insts) |*b| all = all and b.client.state() == .joined and b.net.player_count() == n;
            if (all) {
                joined_at = now;
                std.debug.print("lynx_e2e: all {d} in one room after {d} ms\n", .{ n, (now - t0) / 1000 });
            } else if (now - t0 > @as(u64, opts.join_timeout_s) * 1_000_000) {
                for (insts, 0..) |*b, i| std.debug.print("  badge {d}: {t}, {d} present, accepted {d}\n", .{ i, b.client.state(), b.net.player_count(), b.conn.accepted });
                die("the badges did not all join one room (is `badge lobby --no-usb --sim {d}-{d}` running?)", .{ opts.base_port, opts.base_port + n - 1 });
            }
        }
        // Done: every badge played `frames` frames since its restart.
        var done = true;
        for (insts) |*b| {
            if (b.gone) continue;
            if (b.restarted_at == null or b.lynx.frame_count < opts.frames) done = false;
        }
        if (done) break;
        if (now - t0 > 300_000_000) break;
        // The events, by badge 0's game frames.
        if (opts.events and !ev_done and insts[0].restarted_at != null and insts[0].lynx.frame_count >= 1000) {
            ev_done = true;
            const rj = &insts[n - 1];
            rj.conn.blip = true;
            std.debug.print("lynx_e2e: badge {d} says HELLO again (rejoin)\n", .{n - 1});
            if (n >= 3) {
                const up = &insts[n - 2];
                drop_client(&up.conn);
                if (up.conn.listen_fd >= 0) _ = c.close(up.conn.listen_fd);
                up.conn.listen_fd = -1;
                up.gone = true;
                std.debug.print("lynx_e2e: badge {d} unplugged\n", .{n - 2});
            }
        }
        var next: u64 = now + 1000;
        for (insts) |*b| {
            if (b.gone) continue;
            if (now >= b.frame_top) {
                b.frame_top += 16_667;
                if (b.frame_top <= now) b.frame_top = now + 16_667;
                badge_frame(b, &started);
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
        const wait_ms: c_int = if (next <= t_poll) 0 else 1;
        _ = c.poll(&pfds, @intCast(np), wait_ms);
        for (pfds[0..np], owner[0..np]) |p, o| {
            if (p.revents == 0) continue;
            const conn = &insts[o.i].conn;
            if (o.listener) accept_one(conn) else if (p.fd == conn.client_fd) {
                service_rx(conn);
                service_tx(conn);
            }
        }
    }
    report(t0);
}

fn badge_frame(b: *Inst, started: *bool) void {
    const net = &b.net;
    if (net.before_frame(&b.lynx)) {
        b.restarted_at = now_us();
        b.fe = .{ .running = true };
    }
    if (!net.linked) {
        if (b.client.state() == .joined and net.player_count() == opts.badges) net.set_ready(true);
        if (!started.* and net.all_ready() and net.start(opts.d_ms)) started.* = true;
    } else if (!net.attached) {
        // Switched on a few frames after GO: the old game runs on.
        b.lynx.step_frame(0);
    } else if (net.can_step(&b.lynx)) {
        const k = b.lynx.frame_count;
        const pad = b.fe.update(if (k < controls.len) controls[k] else 0) orelse 0;
        b.lynx.step_frame(pad);
        b.stepped += 1;
        if (k % 30 == 0) {
            const g = players_glyph(&b.lynx);
            if (g != 0) b.players = glyph_players(g);
            if (b.cockpit_at == null and cockpit(&b.lynx)) b.cockpit_at = k;
        }
    } else b.stalled += 1;
    const s0 = net.seq;
    net.after_frame(&b.lynx);
    if (b.client.me()) |id| {
        var s = s0;
        const t = now_us();
        while (s != net.seq) : (s +%= 1) sent_at[id][s] = t;
    }
}

fn report(t0: u64) void {
    const n = opts.badges;
    std.debug.print("lynx_e2e: {d} badges, {d} s\n", .{ n, (now_us() - t0) / 1_000_000 });
    var failures: u32 = 0;
    for (insts, 0..) |*b, i| {
        const ok = b.gone or (b.players == n and b.cockpit_at != null) or (opts.events and b.cockpit_at != null);
        if (!ok) failures += 1;
        std.debug.print("  badge {d} (id {?d}){s}: {s} players {d}, cockpit at game frame {?d}, stepped {d}, stalled {d}, msgs out {d} in {d}, ComLynx frames out {d} in {d}, late {d}, leavers seen {d}, wire bytes out {d} in {d}\n", .{
            i,                    b.client.me(),       if (b.gone) " (unplugged)" else "", if (ok) "PASS" else "FAIL", b.players,        b.cockpit_at,        b.stepped,        b.stalled,
            b.net.stats.msgs_out, b.net.stats.msgs_in, b.net.stats.frames_out,             b.net.stats.frames_in,      b.net.stats.late, b.net.stats.leavers, b.conn.bytes_out, b.conn.bytes_in,
        });
    }
    std.debug.print("  message lag (peer heartbeat to this badge's link time at the frame that drains it): p50 {d}.{d} ms, p99 {d}.{d} ms, max {d}.{d} ms, {d} samples\n", .{
        pct(50) / 1000, pct(50) % 1000 / 100, pct(99) / 1000, pct(99) % 1000 / 100, lag_max / 1000, lag_max % 1000 / 100, lag_n,
    });
    std.debug.print("  relay latency (a ComLynx message's SEND leaving the badge to its DATA arriving at another; 100 us buckets): p50 {d}.{d} ms, p99 {d}.{d} ms, max {d}.{d} ms, {d} samples\n", .{
        relay_pct(50) / 1000, relay_pct(50) % 1000 / 100, relay_pct(99) / 1000, relay_pct(99) % 1000 / 100, relay_max / 1000, relay_max % 1000 / 100, relay_n,
    });
    if (failures != 0) {
        std.debug.print("lynx_e2e: {d} badge(s) FAILED\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("lynx_e2e: PASS\n", .{});
}

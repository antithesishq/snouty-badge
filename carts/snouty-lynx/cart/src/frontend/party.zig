//! The PARTY screen (docs/COMLYNX.md section 10): the lobby for ComLynx
//! play over the laptop's `badge lobby`, opened from the menu's Party row.
//! Its states and lines follow Snoutenstein's M8 lobby
//! (carts/snoutenstein/cart/src/party.zig) so the two feel alike:
//!
//! - NEEDS PARTY FIRMWARE (stock firmware, the simulator), START BADGE
//!   LOBBY ON THE LAPTOP (no host program), JOINING..., then the room:
//!   the roster in id order (your row highlighted, a tick when ready),
//!   the host's SYNC row (Left/Right: RELAY, or T+D with D 17-50 ms; the
//!   host's choice goes out with GO), the status line and the hints.
//! - A: ready. Start (the host, everyone ready, two at least): GO. Every
//!   badge then restarts the game linked, a few frames apart (Lynx games
//!   look for each other at power on), and plays.
//! - B: back to the menu (leaves the room).
//!
//! The room is per ROM: the lobby game id carries the ROM's CRC
//! (frontend/lynxnet.zig `game_id`), so only badges running the same
//! dump meet.
const std = @import("std");
const cart = @import("cart-api");
const core = @import("core");
const input = @import("input.zig");
const text = @import("text.zig");
const romsrc = @import("romsrc.zig");
const linkport = @import("linkport.zig");

pub const Result = enum { stay, back, started };

/// The host's SYNC choices: 0 = relay mode, else D in ms.
const d_choices = [_]u8{ 0, 17, 25, 33, 50 };
var d_i: usize = 2;

/// Open the lobby (the menu's Party row). False when the scrub arena is
/// too small for the link's queues.
pub fn enter() bool {
    return linkport.open(romsrc.crc);
}

/// One frame of the lobby: run the client, take the buttons, draw.
pub fn update(l: *core.Lynx, e: input.Edge) Result {
    if (linkport.before_frame(l)) return .started;
    defer linkport.after_frame(l);
    if (e.pressed(.b)) {
        linkport.close(l);
        return .back;
    }
    const st = linkport.state();
    if (st == .joined) {
        const net = &linkport.net;
        if (e.pressed(.a)) net.set_ready(!net.ready);
        const host = net.me() != null and net.me() == net.host();
        if (host) {
            if (e.pressed(.left)) d_i = (d_i + d_choices.len - 1) % d_choices.len;
            if (e.pressed(.right)) d_i = (d_i + 1) % d_choices.len;
            net.want_d_ms = d_choices[d_i];
            if (e.pressed(.start)) _ = net.start(d_choices[d_i]);
        }
    }
    draw(st);
    return .stay;
}

const bg: cart.DisplayColor = .rgb(0x000000);
const band: cart.DisplayColor = .rgb(0x0A1A50);
const white: cart.DisplayColor = .rgb(0xFFFFFF);
const grey: cart.DisplayColor = .rgb(0x8898C0);
const yellow: cart.DisplayColor = .rgb(0xFFD040);
const coral: cart.DisplayColor = .rgb(0xFF7050);
const green: cart.DisplayColor = .rgb(0x50E070);
const steel: cart.DisplayColor = .rgb(0x283860);

fn centered(s: []const u8, y: i32, fg: cart.DisplayColor, b: cart.DisplayColor) void {
    const n: usize = @min(s.len, 20);
    const w: i32 = @intCast(n * 8);
    text.draw(s[0..n], @divTrunc(@as(i32, cart.screen_width) - w, 2), y, fg, b);
}

fn draw(st: anytype) void {
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = cart.screen_height, .fill_color = bg });
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = 9, .fill_color = band });
    text.draw("PARTY", 2, 1, coral, band);
    switch (st) {
        .unsupported => {
            centered("NEEDS PARTY", 40, white, bg);
            centered("FIRMWARE", 50, white, bg);
            centered("FLASH THE FORK OS", 66, grey, bg);
        },
        .disconnected => {
            centered("START BADGE LOBBY", 40, white, bg);
            centered("ON THE LAPTOP", 50, white, bg);
            centered("badge lobby", 66, grey, bg);
        },
        .joined => draw_room(),
        else => centered("JOINING...", 52, yellow, bg),
    }
    if (st != .joined) centered("B: BACK", 118, grey, bg);
    cart.mark_dirty_rect(0, 0, cart.screen_width, cart.screen_height);
}

fn draw_room() void {
    const net = &linkport.net;
    var buf: [24]u8 = undefined;
    const n = net.player_count();
    var k0: usize = num(&buf, 0, n);
    buf[k0] = '/';
    k0 = num(&buf, k0 + 1, linkport.max_players);
    text.draw(buf[0..k0], 120, 1, grey, band);
    const me = net.me() orelse 0;
    const host = net.host() == me;
    if (host) text.draw("HOST", 64, 1, yellow, band);
    // The ROM (the room is per ROM).
    text.draw(fit(&buf, romsrc.title_name()), 2, 11, grey, bg);
    // SYNC: the host's choice (others see their own until GO brings it).
    const d = net.want_d_ms;
    const sync = if (d == 0) "SYNC: RELAY" else blk: {
        @memcpy(buf[0..8], "SYNC: T+");
        const e = num(&buf, 8, d);
        @memcpy(buf[e..][0..3], " MS");
        break :blk buf[0 .. e + 3];
    };
    text.draw(if (host) "<" else " ", 2, 21, coral, bg);
    text.draw(sync, 10, 21, if (host) white else grey, bg);
    cart.rect(.{ .x = 0, .y = 31, .width = cart.screen_width, .height = 1, .fill_color = steel });
    // Roster: eight rows.
    var k: i32 = 0;
    var id: u8 = 0;
    while (id < 16) : (id += 1) {
        if (net.present >> @intCast(id) & 1 == 0) continue;
        if (k == 8) break;
        const y: i32 = 34 + 9 * k;
        k += 1;
        const mine = id == me;
        const rb = if (mine) steel else bg;
        if (mine) cart.rect(.{ .x = 0, .y = y - 1, .width = cart.screen_width, .height = 9, .fill_color = steel });
        const nm = linkport.name(id);
        buf[0] = 'P';
        var e = num(&buf, 1, id + 1);
        buf[e] = ' ';
        const m = @min(nm.len, 10);
        @memcpy(buf[e + 1 ..][0..m], nm[0..m]);
        e += 1 + m;
        const line = buf[0..e];
        text.draw(line, 4, y, white, rb);
        const ready = if (mine) net.ready else net.peers_ready >> @intCast(id) & 1 == 1;
        if (ready) text.draw("READY", 116, y, green, rb);
    }
    const me_ready = net.ready;
    if (host and net.all_ready()) {
        centered("START: GO!", 108, coral, bg);
    } else if (host and me_ready) {
        centered("WAITING FOR READY", 108, grey, bg);
    } else if (me_ready) {
        centered("READY: HOST STARTS", 108, green, bg);
    } else {
        centered("A: READY", 108, white, bg);
    }
    centered(if (host) "<>: SYNC  B: BACK" else "B: BACK", 118, grey, bg);
}

/// `v` in decimal into `buf` at `at`; the end index.
fn num(buf: *[24]u8, at: usize, v: u32) usize {
    var d: [10]u8 = undefined;
    var n: usize = 0;
    var x = v;
    while (true) {
        d[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
        x /= 10;
        if (x == 0) break;
    }
    for (0..n) |i| buf[at + i] = d[n - 1 - i];
    return at + n;
}

fn fit(buf: *[24]u8, s: []const u8) []const u8 {
    const n = @min(s.len, 19);
    @memcpy(buf[0..n], s[0..n]);
    return buf[0..n];
}

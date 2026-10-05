//! The party lobby screen (docs/MULTIPLAYER.md, root docs/LOCKSTEP_N.md):
//! the Genesis menu's colours and band, Snoutenstein's party flow and
//! wording (carts/snoutenstein/cart/src/party.zig) so the two lobbies feel
//! alike. Only in party builds (`build_options.party`); app.zig owns the
//! session and calls `update` while `State.party` shows.
//!
//! What it shows: the port's state (NEEDS PARTY FIRMWARE, START BADGE
//! LOBBY ON THE LAPTOP, JOINING...), then the room: the ROM check (the
//! host offers its ROM's CRC32 and peripheral; a guest with another ROM
//! cannot ready: WRONG ROM), the peripheral, the delay (the host picks it
//! with Left/Right, AUTO = the round-trip suggestion), the roster with
//! your slot, the host and who is ready, and the status line (A: READY,
//! READY: HOST STARTS, START: GO!, n READY, NEED 2, WAITING FOR HOST,
//! MATCH IN PROGRESS). After a race ended badly the last line says why
//! (DESYNC, YOU WERE DROPPED) until the next A. B leaves the room and
//! goes back to the game.
const std = @import("std");
const cart = @import("cart-api");
const core = @import("core");
const players = @import("players");
const text = @import("text.zig");
const menu = @import("menu.zig");
const input = @import("input.zig");
const romsrc = @import("romsrc.zig");

/// Why the last race ended, shown until the next A.
pub const End = enum { none, desync, dropped, left };
pub var last_end: End = .none;

/// The host's delay choice: 0 = AUTO (`suggested_delay`), else 1-30.
var delay_choice: u8 = 0;

pub const Result = enum { stay, back, started };

/// One lobby update over `s` (a `players.Session`): input, the session's
/// lobby frame, drawing. `started`: a race began (the console was reset
/// for it); `back`: B, the room was left.
pub fn update(s: anytype, md: *const core.Md, e: input.Edge, now: u64) Result {
    const l = &s.ls;
    s.crc = romsrc.crc;
    s.crc_known = romsrc.crc_known;
    s.kind = md.setup.cfg.kind;
    if (e.pressed(.b)) {
        l.exit(now);
        s.want_ready = false;
        return .back;
    }
    if (e.pressed(.a)) {
        s.want_ready = !s.want_ready;
        last_end = .none;
    }
    if (l.is_host()) {
        if (e.pressed(.left)) delay_choice = if (delay_choice == 0) 30 else delay_choice - 1;
        if (e.pressed(.right)) delay_choice = if (delay_choice >= 30) 0 else delay_choice + 1;
        l.set_delay(if (delay_choice == 0) l.suggested_delay() else delay_choice);
    }
    // Start alone (Start + Select is the OS's).
    const go = e.pressed(.start) and !e.held(.select);
    const started = s.lobby(now, go);
    draw(s);
    return if (started) .started else .stay;
}

const band_h = 20;
const x0 = 4;

fn centered(str: []const u8, y: i32, fg: cart.DisplayColor, back: cart.DisplayColor) void {
    const n: i32 = @intCast(@min(str.len, 20));
    text.draw(str[0..@intCast(n)], @divTrunc(160 - 8 * n, 2), y, fg, back);
}

fn put(dst: []u8, parts: []const []const u8) []const u8 {
    var i: usize = 0;
    for (parts) |p| {
        const k = @min(p.len, dst.len - i);
        @memcpy(dst[i..][0..k], p[0..k]);
        i += k;
    }
    return dst[0..i];
}

fn num(buf: []u8, v: u32) []const u8 {
    return std.fmt.bufPrint(buf, "{d}", .{v}) catch "?";
}

const ink = menu.title_color;
const dim: cart.DisplayColor = .rgb(0x8898C0);
const hot: cart.DisplayColor = .rgb(0xFFD040);
const bad: cart.DisplayColor = .rgb(0xFF6060);
const good: cart.DisplayColor = .rgb(0x60E060);
const bg: cart.DisplayColor = .rgb(0x000000);

fn draw(s: anytype) void {
    const l = &s.ls;
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = band_h, .fill_color = menu.band_color });
    cart.rect(.{ .x = 0, .y = band_h, .width = 160, .height = 128 - band_h, .fill_color = bg });
    centered("PARTY", 1, ink, menu.band_color);
    var nb: [20]u8 = undefined;
    const title = romsrc.title_name();
    centered(title[0..@min(title.len, 20)], 10, hot, menu.band_color);
    _ = &nb;
    switch (l.state()) {
        .unsupported => {
            centered("NEEDS PARTY FIRMWARE", 44, ink, bg);
            centered("FLASH THE FORK OS", 58, dim, bg);
        },
        .disconnected => {
            centered("START BADGE LOBBY", 40, ink, bg);
            centered("ON THE LAPTOP", 52, ink, bg);
            centered("badge.py lobby", 68, dim, bg);
        },
        .lobby => draw_room(s),
        else => centered("JOINING...", 52, ink, bg),
    }
    if (l.state() != .lobby) centered("B: BACK", 118, dim, bg);
}

fn draw_room(s: anytype) void {
    const l = &s.ls;
    var b1: [24]u8 = undefined;
    var b2: [8]u8 = undefined;
    var y: i32 = band_h + 2;
    // The ROM check and the pads the race plugs in.
    const rules = l.rules();
    if (!s.crc_known) {
        text.draw("CHECKING ROM...", x0, y, dim, bg);
    } else if (rules == null) {
        text.draw("ROM: WAITING HOST", x0, y, dim, bg);
    } else if (s.rom_matches()) {
        text.draw("ROM: SAME AS HOST", x0, y, good, bg);
    } else {
        text.draw("WRONG ROM", x0, y, bad, bg);
    }
    y += 9;
    const kind = if (rules) |r| players.rules_kind(&r) orelse s.kind else s.kind;
    text.draw(put(&b1, &.{ "PADS: ", menu.kind_name(kind) }), x0, y, dim, bg);
    y += 9;
    if (l.is_host()) {
        const d = l.delay_offer();
        const v = if (delay_choice == 0) put(&b1, &.{ "DELAY: AUTO ", num(&b2, d) }) else put(&b1, &.{ "DELAY: ", num(&b2, d), " <>" });
        text.draw(v, x0, y, ink, bg);
    } else {
        text.draw("DELAY: HOST'S", x0, y, dim, bg);
    }
    y += 10;
    // The roster: slot, name, YOU / HOST, a tick when ready.
    const present = l.present();
    const ready = l.ready_mask();
    var shown: u32 = 0;
    for (0..16) |i| {
        if (present >> @intCast(i) & 1 == 0) continue;
        if (shown == 6) break;
        const slot: u4 = @intCast(i);
        const me = slot == l.local_slot();
        const tag: []const u8 = if (me) " YOU" else if (l.host_slot() == slot) " HOST" else "";
        const line = put(&b1, &.{ "P", num(&b2, i + 1), " ", l.name(slot), tag });
        text.draw(line[0..@min(line.len, 17)], x0, y, if (me) hot else ink, bg);
        if (ready >> @intCast(i) & 1 != 0) text.draw("*", 148, y, good, bg);
        y += 9;
        shown += 1;
    }
    // Status and hint lines.
    const ready_n: u8 = @popCount(ready & present);
    const me_ready = ready >> l.local_slot() & 1 == 1;
    var sb: [24]u8 = undefined;
    switch (last_end) {
        .desync => centered("DESYNC", 103, bad, bg),
        .dropped => centered("YOU WERE DROPPED", 103, bad, bg),
        .left, .none => {},
    }
    if (l.match_running()) {
        centered("MATCH IN PROGRESS", 111, hot, bg);
    } else if (l.is_host() and l.can_go()) {
        centered("START: GO!", 111, hot, bg);
    } else if (l.is_host() and me_ready) {
        centered(put(&sb, &.{ num(&b2, ready_n), " READY, NEED 2" }), 111, dim, bg);
    } else if (me_ready) {
        centered("READY: HOST STARTS", 111, good, bg);
    } else if (rules == null) {
        centered("WAITING FOR HOST", 111, dim, bg);
    } else if (s.crc_known and !s.rom_matches()) {
        centered("NEEDS THE HOST'S ROM", 111, bad, bg);
    } else {
        centered("A: READY", 111, ink, bg);
    }
    centered(if (l.is_host()) "<>: DELAY  B: BACK" else "B: BACK", 119, dim, bg);
}

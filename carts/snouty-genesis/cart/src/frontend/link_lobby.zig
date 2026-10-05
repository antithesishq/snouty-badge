//! The link screen (docs/MULTIPLAYER.md section 8): two badges on the link
//! cable agree on a race here. The party lobby's colours, band and wording
//! (frontend/lobby.zig on branch `party`) where they fit, the cable
//! screens' shared wording (root docs/LOCKSTEP.md section 6) for the link
//! states. app.zig owns the session and calls `update` while
//! `State.link` shows.
//!
//! What it shows: the link's state (NO LINK IN SIMULATOR, PLUG IN THE
//! CABLE, WRONG CART: <cart>, WRONG VERSION), then the lobby: which pad
//! this badge plays (the host is player 1), the ROM check (the host
//! offers its ROM's CRC32, peripheral and build; a guest with another ROM
//! or the other build cannot ready: WRONG ROM, OTHER BUILD), the pads the
//! race plugs in, whether the partner has its link screen open, and the
//! status line (A: START, WAITING FOR PLAYER 2, READY: HOST STARTS,
//! NEEDS THE HOST'S ROM). After a race that ended badly the last line says
//! why (DESYNC, PARTNER LEFT) until the screen is left. Keys: A or Start
//! (the host) starts, B goes back to the game.
const cart = @import("cart-api");
const core = @import("core");
const linkplay = @import("linkplay");
const text = @import("text.zig");
const menu = @import("menu.zig");
const input = @import("input.zig");
const romsrc = @import("romsrc.zig");

/// Why the last race ended, shown until the screen is left.
pub const End = enum { none, desync, partner_left, left };
pub var last_end: End = .none;

pub const Result = enum { stay, back };

/// One link screen update over `s` (a `linkplay.Session`): input, the
/// session's lobby frame, drawing. `back`: B, the game resumes (a race
/// that started is app.zig's business: `Session.take_start`).
pub fn update(s: anytype, e: input.Edge, now: u64) Result {
    s.crc = romsrc.crc;
    s.crc_known = romsrc.crc_known;
    if (e.pressed(.b)) {
        // Not ready any more: the host cannot start without this badge.
        s.want = false;
        s.ls.set_pick(1, false);
        last_end = .none;
        return .back;
    }
    s.want = true;
    // A or Start alone (Start + Select is the OS's).
    const go = (e.pressed(.a) or e.pressed(.start)) and !e.held(.select);
    s.lobby(now, go);
    draw(s);
    return .stay;
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
    centered("LINK CABLE 2P", 1, ink, menu.band_color);
    const title = romsrc.title_name();
    centered(title[0..@min(title.len, 20)], 10, hot, menu.band_color);
    var b1: [24]u8 = undefined;
    switch (l.state()) {
        .offline => {
            centered("NO LINK IN SIMULATOR", 48, ink, bg);
            centered("PLAY ON TWO BADGES", 62, dim, bg);
        },
        .searching => {
            centered("PLUG IN THE CABLE", 40, ink, bg);
            centered("UART HEADER TO", 58, dim, bg);
            centered("UART HEADER", 67, dim, bg);
        },
        .wrong_cart => {
            centered("WRONG CART:", 44, bad, bg);
            centered(l.partner_name(), 56, bad, bg);
            centered("RUN SNOUTY GENESIS", 72, dim, bg);
        },
        .wrong_version => {
            centered("WRONG VERSION:", 44, bad, bg);
            centered("UPDATE BOTH BADGES", 56, bad, bg);
        },
        .lobby => draw_lobby(s, &b1),
        // A race runs: app.zig shows the game, not this screen.
        else => centered("STARTING...", 52, ink, bg),
    }
    switch (last_end) {
        .desync => centered("DESYNC", 103, bad, bg),
        .partner_left => centered("PARTNER LEFT", 103, bad, bg),
        .left, .none => {},
    }
    if (l.state() != .lobby) centered("B: BACK", 119, dim, bg);
}

fn draw_lobby(s: anytype, b1: *[24]u8) void {
    const l = &s.ls;
    const host = l.role == .host;
    var y: i32 = band_h + 4;
    text.draw(if (host) "YOU: PLAYER 1 (HOST)" else "YOU: PLAYER 2", x0, y, hot, bg);
    y += 11;
    const v = s.verdict();
    switch (v) {
        .checking => text.draw("CHECKING ROM...", x0, y, dim, bg),
        .waiting_host => text.draw("ROM: WAITING HOST", x0, y, dim, bg),
        .same => text.draw(if (host) "ROM: OFFERED" else "ROM: SAME AS HOST", x0, y, good, bg),
        .wrong_rom => text.draw("WRONG ROM", x0, y, bad, bg),
        .other_build => text.draw("OTHER BUILD (XIP)", x0, y, bad, bg),
    }
    y += 10;
    const rules = l.rules();
    const kind = if (rules) |r| linkplay.rules_kind(&r) orelse s.kind else s.kind;
    text.draw(put(b1, &.{ "PADS: ", kind_name(kind) }), x0, y, dim, bg);
    y += 10;
    const partner_ready = l.peer_ready();
    text.draw(if (partner_ready) "PARTNER: READY" else "PARTNER: NOT READY", x0, y, if (partner_ready) good else dim, bg);
    // Status and hint lines.
    if (host and l.can_go()) {
        centered("A: START!", 111, hot, bg);
    } else if (host) {
        centered("WAITING FOR PLAYER 2", 111, dim, bg);
    } else if (v == .same) {
        centered("READY: HOST STARTS", 111, good, bg);
    } else if (v == .wrong_rom or v == .other_build) {
        centered("NEEDS THE HOST'S ROM", 111, bad, bg);
    } else {
        centered("WAITING FOR HOST", 111, dim, bg);
    }
    centered("B: BACK", 119, dim, bg);
}

/// The peripheral's short name (the PADS line).
fn kind_name(k: core.ports.Kind) []const u8 {
    return switch (k) {
        .pad1 => "1 pad",
        .pads2 => "2 pads",
        .tap1 => "Tap in 1",
        .tap2 => "Tap in 2",
        .taps => "Taps 1+2",
        .ea4way => "4 Way Play",
        .jcart => "J-Cart",
    };
}

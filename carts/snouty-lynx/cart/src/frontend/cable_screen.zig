//! The LINK screen (docs/CABLE.md): two badges on the link cable, opened
//! from the menu's "Link cable" row. Laid out like the party branch's
//! PARTY screen (frontend/party.zig there) so the two feel alike:
//!
//! - CONNECT THE CABLE (no partner: the cable is out, or the other badge
//!   has not opened its LINK screen), WRONG CART: <name> (the partner runs
//!   another cart), CONNECTING..., PARTNER LEFT, ROM MISMATCH (both CRCs:
//!   every ComLynx game needs the same cart in each Lynx), OTHER VERSION,
//!   then the pair: YOU / PARTNER with READY ticks.
//! - A: ready (or not). When both are ready the host's GO restarts both
//!   games linked, the guest 7 frames later, and both play.
//! - B: back to the menu (leaves the link).
const cart = @import("cart-api");
const core = @import("core");
const lockstep = @import("lockstep");
const input = @import("input.zig");
const text = @import("text.zig");
const romsrc = @import("romsrc.zig");
const cable = @import("cable.zig");

pub const Result = enum { stay, back, started };

/// Open the screen (the menu's Link cable row).
pub fn enter() void {
    cable.enter(romsrc.crc);
}

/// One frame of the screen: service the cable, take the buttons, draw.
pub noinline fn update(l: *core.Lynx, e: input.Edge) Result {
    if (cable.before_frame(l)) return .started;
    defer cable.after_frame(l);
    if (e.pressed(.b)) {
        cable.close(l);
        return .back;
    }
    const st = cable.status();
    if (st == .same_rom and e.pressed(.a)) cable.net.set_ready(!cable.net.ready);
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

fn centered(s: []const u8, y: i32, fg: cart.DisplayColor) void {
    const n: usize = @min(s.len, 20);
    const w: i32 = @intCast(n * 8);
    text.draw(s[0..n], @divTrunc(@as(i32, cart.screen_width) - w, 2), y, fg, bg);
}

noinline fn draw(st: anytype) void {
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = cart.screen_height, .fill_color = bg });
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = 9, .fill_color = band });
    text.draw("LINK CABLE", 2, 1, coral, band);
    switch (cable.cable_kind()) {
        .crossed => text.draw("CROSSED", 102, 1, grey, band),
        .straight => text.draw("STRAIGHT", 94, 1, grey, band),
        .unknown => {},
    }
    var buf: [24]u8 = undefined;
    if (cable.no_memory) {
        centered("NO MEMORY FOR", 40, white);
        centered("THE LINK", 50, white);
    } else switch (st) {
        .unavailable => {
            centered("NO LINK PORT", 40, white);
            centered("IN THE SIMULATOR", 50, white);
        },
        .searching => {
            centered("CONNECT THE CABLE", 34, white);
            centered("(UART HEADERS)", 44, grey);
            centered("AND OPEN LINK CABLE", 62, white);
            centered("ON THE OTHER BADGE", 72, white);
            centered("SEARCHING...", 92, yellow);
        },
        .wrong_cart => {
            centered("WRONG CART:", 40, coral);
            centered(lockstep.app_name(cable.partner_app()), 50, white);
            centered("START SNOUTY LYNX", 68, grey);
            centered("ON THE OTHER BADGE", 78, grey);
        },
        .connecting, .linked => centered("CONNECTING...", 52, yellow),
        .partner_left => {
            centered("PARTNER LEFT", 40, coral);
            centered("THE LINK SCREEN", 50, white);
            centered("WAITING...", 70, yellow);
        },
        .other_version => {
            centered("OTHER SNOUTY LYNX", 40, coral);
            centered("VERSION:", 50, white);
            centered("UPDATE BOTH BADGES", 68, grey);
        },
        .rom_mismatch => {
            centered("ROM MISMATCH", 30, coral);
            centered(crc_line(&buf, "YOURS  ", cable.net.crc), 48, white);
            centered(crc_line(&buf, "THEIRS ", cable.net.partner_crc orelse 0), 58, white);
            centered("PUT THE SAME ROM", 76, grey);
            centered("ON BOTH BADGES", 86, grey);
        },
        .same_rom => draw_pair(),
    }
    centered("B: BACK", 118, grey);
    cart.mark_dirty_rect(0, 0, cart.screen_width, cart.screen_height);
}

fn draw_pair() void {
    const net = &cable.net;
    var buf: [24]u8 = undefined;
    // The ROM (both run the same one).
    const name = romsrc.title_name();
    const n = @min(name.len, 19);
    @memcpy(buf[0..n], name[0..n]);
    text.draw(buf[0..n], 2, 12, grey, bg);
    cart.rect(.{ .x = 0, .y = 22, .width = cart.screen_width, .height = 1, .fill_color = steel });
    cart.rect(.{ .x = 0, .y = 33, .width = cart.screen_width, .height = 9, .fill_color = steel });
    text.draw("YOU", 4, 34, white, steel);
    if (net.ready) text.draw("READY", 116, 34, green, steel);
    text.draw("PARTNER", 4, 45, white, bg);
    if (net.partner_ready) text.draw("READY", 116, 45, green, bg);
    if (net.ready and net.partner_ready) {
        centered("GO!", 78, coral);
    } else if (net.ready) {
        centered("WAITING FOR PARTNER", 78, grey);
        centered("A: NOT READY", 96, grey);
    } else {
        centered("A: READY", 78, white);
        centered("BOTH READY: THE GAME", 96, grey);
        centered("RESTARTS LINKED", 106, grey);
    }
}

fn crc_line(buf: *[24]u8, label: []const u8, crc: u32) []const u8 {
    @memcpy(buf[0..label.len], label);
    const hex = "0123456789ABCDEF";
    for (0..8) |i| buf[label.len + i] = hex[(crc >> @intCast(28 - 4 * i)) & 0xF];
    return buf[0 .. label.len + 8];
}

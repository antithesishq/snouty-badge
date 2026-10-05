//! New for Snouty GC (M4 Track B): what the link race shows (SPEC 7.3,
//! docs/NET.md section 3). The LINK lobby over the live floor (the cable
//! state while searching, host or guest, the host's MODE / TRACK / CREWS
//! rows and the guest's read-only view of them, the partner's pick), the
//! notices over a link race (WAITING FOR PEER, PEER LEFT, AI DRIVING) and
//! the DESYNC band on the results. Draw only: main.zig owns `net` and
//! hands this module a `View` each frame (so a debug export can show a
//! made-up one in the simulator, where the link is offline).
const cart = @import("cart-api");
const net = @import("net.zig");
const world = @import("world.zig");
const track = @import("track.zig");
const hud = @import("hud.zig");
const menu = @import("menu.zig");

/// What the lobby shows.
pub const View = struct {
    state: net.State = .searching,
    role: net.Role = .none,
    /// 0 unknown, 1 crossed, 2 straight (link.Cable).
    cable: u8 = 0,
    /// The host's rules (null: the guest has not heard them yet).
    rules: ?net.Rules = null,
    /// The partner's pick (null: not heard since this lobby began).
    peer: ?net.Pick = null,
};

/// Lobby rows: MODE, TRACK, CREWS (the host's), then the racer select.
pub const Row = enum(u8) { mode, track, crews, racer };
pub const row_count = 4;

/// CREWS choices (SPEC 7.1): AI racers on the grid.
pub const crew_steps = [_]u8{ 4, 2, 0 };

const panel = cart.DisplayColor.rgb(0x2A1E34);
const panel_hi = cart.DisplayColor.rgb(0x4A2440);

pub fn mode_name(m: world.Mode) []const u8 {
    return if (m == .gc) "LINK GC" else "LINK RACE";
}

fn crews_text(buf: *[9]u8, crews: u8) []const u8 {
    buf.* = "CREWS: 4 ".*;
    buf[7] = '0' + @as(u8, @min(crews, 9));
    return buf[0..8];
}

/// The lobby: the title at 2x, a panel with the rows (or the cable state
/// while there is no partner), the role, cable, partner and prompt lines
/// under it. `cursor` is the host's row; the guest's is always RACER.
pub fn draw_lobby(v: *const View, cursor: u8, frame: u32) void {
    menu.big_title(8);
    const y0: i32 = 36;
    const pitch: i32 = 13;
    cart.rect(.{ .x = 4, .y = y0 - 3, .width = 152, .height = 4 * pitch + 5, .fill_color = panel, .stroke_color = hud.dim });
    hud.fill_rect(4, 92, 152, 32, hud.anti_black);
    switch (v.state) {
        .lobby => {},
        .offline => {
            hud.centered("NO LINK IN", y0 + pitch, hud.coral);
            hud.centered("SIMULATOR", y0 + 2 * pitch, hud.coral);
            hud.centered("NEEDS TWO BADGES", 96, hud.grey);
            return hud.centered("B BACK", 116, hud.dim);
        },
        .wrong_cart => {
            hud.centered("WRONG CART", y0, hud.coral);
            hud.centered("THE OTHER BADGE", y0 + pitch, hud.white);
            hud.centered("RUNS ANOTHER CART", y0 + 2 * pitch, hud.white);
            hud.centered("START SNOUTY GCP", y0 + 3 * pitch, hud.grey);
            hud.centered("THEN LINK ON IT", 96, hud.grey);
            return hud.centered("B BACK", 116, hud.dim);
        },
        .wrong_version => {
            // The other badge runs another Snouty GC version (lockstep's
            // G.version; docs/LOCKSTEP.md 4.7).
            hud.centered("WRONG VERSION", y0, hud.coral);
            hud.centered("UPDATE BOTH BADGES", y0 + pitch, hud.white);
            return hud.centered("B BACK", 116, hud.dim);
        },
        else => {
            // Searching (or a race state the lobby never shows).
            hud.centered("PLUG IN THE CABLE", y0, hud.white);
            var dots: [12]u8 = "SEARCHING...".*;
            const n_dots = (frame / 15) % 4;
            for (dots[9 + n_dots ..]) |*c| c.* = ' ';
            hud.text(&dots, 80 - 48, y0 + pitch, hud.coral);
            hud.centered("UART HEADER TO", y0 + 2 * pitch, hud.grey);
            hud.centered("UART HEADER", y0 + 3 * pitch, hud.grey);
            hud.centered("OPEN LINK ON BOTH", 96, hud.grey);
            return hud.centered("B BACK", 116, hud.dim);
        },
    }
    const host = v.role == .host;
    const sel: u8 = if (host) cursor else @backingInt(Row.racer);
    var cb: [9]u8 = undefined;
    const r = v.rules;
    const items = [row_count][]const u8{
        if (r) |x| mode_name(x.mode) else "MODE: ...",
        if (r) |x| track.tracks[x.track % track.tracks.len].name else "TRACK: ...",
        if (r) |x| crews_text(&cb, x.crews) else "CREWS: ...",
        "PICK A RACER",
    };
    for (items, 0..) |item, i| {
        const y = y0 + @as(i32, @intCast(i)) * pitch;
        const on = i == sel;
        if (on) hud.fill_rect(6, y - 2, 148, 11, panel_hi);
        const color = if (on) hud.coral else if (host or i == @backingInt(Row.racer)) hud.white else hud.grey;
        hud.centered(item, y, color);
        // The host changes the rules with Left / Right on its row.
        if (on and host and i != @backingInt(Row.racer)) {
            hud.text("<", 8, y, hud.coral);
            hud.text(">", 144, y, hud.coral);
        }
    }
    // Role and cable.
    hud.text(if (host) "HOST" else "GUEST", 4, 96, hud.cyan);
    const kind: []const u8 = switch (v.cable) {
        1 => "CROSSED",
        2 => "STRAIGHT",
        else => "",
    };
    hud.text(kind, 156 - 8 * @as(i32, @intCast(kind.len)), 96, hud.grey);
    // The partner, or what the guest waits for.
    if (!host and r == null) {
        hud.centered("WAITING FOR HOST", 106, hud.grey);
    } else if (v.peer) |p| {
        peer_line(p, 106);
    } else {
        hud.centered("PEER IN THE LOBBY", 106, hud.grey);
    }
    hud.centered(if (host) "A SELECT  B BACK" else "A RACER  B BACK", 116, hud.dim);
}

/// "PEER KIDDIE" in the racer's livery, READY in green at the right.
pub fn peer_line(p: net.Pick, y: i32) void {
    if (p.racer >= world.car_count) return hud.centered("PEER: PICKING", y, hud.grey);
    hud.text("PEER", 4, y, hud.grey);
    hud.text(hud.name_of(p.racer), 44, y, hud.livery(p.racer));
    if (p.ready) hud.text("READY", 156 - 40, y, hud.green);
}

/// Over a link race: `WAITING FOR PEER` (the partner's inputs are 0.5 s
/// late) or, for a while after the partner went, `PEER LEFT, AI DRIVING`
/// with the reason. A band across the middle of the floor.
pub const Notice = enum(u8) { none, waiting, peer_left };

pub fn draw_notice(k: Notice, why: net.Left, frame: u32) void {
    switch (k) {
        .none => {},
        .waiting => {
            hud.fill_rect(4, 44, 152, 22, hud.anti_black);
            hud.centered("WAITING FOR PEER", 47, if ((frame / 20) % 2 == 0) hud.white else hud.grey);
            hud.centered("CHECK THE CABLE", 56, hud.grey);
        },
        .peer_left => {
            hud.fill_rect(4, 40, 152, 31, hud.anti_black);
            hud.centered("PEER LEFT,", 43, hud.coral);
            hud.centered("AI DRIVING", 52, hud.white);
            const reason: []const u8 = switch (why) {
                .unplugged => "CABLE OUT",
                .restarted => "PEER RESTARTED",
                .quit => "PEER QUIT",
                .none => "",
            };
            hud.centered(reason, 61, hud.grey);
        },
    }
}

/// On both results cards after a desync: the race stopped where the two
/// badges' Worlds parted.
pub fn draw_desync(frame: u32) void {
    hud.fill_rect(0, 0, 160, 12, hud.anti_black);
    hud.centered("DESYNC: RACE ENDED", 2, if ((frame / 20) % 2 == 0) hud.coral else hud.white);
}

//! What the link race shows (M6): the LINK RACE lobby over the turning
//! floor (the cable state while there is no partner, then host or guest,
//! the host's TRACK row, the machine row, both badges' ready marks), the
//! notices over a link race (WAITING FOR PEER, PEER LEFT, AI DRIVING) and
//! the DESYNC band. Draw only: main.zig owns the lockstep and hands this
//! module a `View` each frame (so `debug_link_view` can show a made-up one
//! in the simulator, where the link is offline).
const cart = @import("cart-api");
const lockstep = @import("lockstep");
const track = @import("track.zig");
const hud = @import("hud.zig");
const sprites = @import("sprites.zig");
const menu = @import("menu.zig");

/// What the lobby shows.
pub const View = struct {
    state: lockstep.State = .searching,
    role: lockstep.Role = .none,
    /// 0 unknown, 1 crossed, 2 straight (link.Cable).
    cable: u8 = 0,
    /// The partner's app byte (wrong cart).
    partner_app: u8 = 0,
    /// The host's track (index into `track.tracks`; null: the guest has
    /// not heard it yet).
    track: ?u8 = null,
    /// This badge's machine and ready mark.
    pick: u8 = 0,
    ready: bool = false,
    /// The partner's machine (null: not heard this lobby) and ready mark.
    peer_pick: ?u8 = null,
    peer_ready: bool = false,
    /// Host: Start goes now.
    can_go: bool = false,
};

/// Lobby rows: the host's TRACK, then MACHINE (the guest has only MACHINE).
pub const Row = enum(u8) { track, machine };
pub const row_count = 2;

/// Machine names for the lobby (menu.machine_items without the prefix).
pub const machine_names = [5][]const u8{ "ANTEATER", "ARGMAX", "DROPOUT", "BACKPROP", "OVERFIT" };

const panel_hi = cart.DisplayColor.rgb(0x4A2440);
const grey = cart.DisplayColor.rgb(0x9A93A0);

/// The machine's colour: the Anteater white, a rival's machine its livery.
fn machine_color(pick: u8) cart.DisplayColor {
    return if (pick == 0 or pick >= 5) hud.white else .rgb(sprites.livery_rgb[pick - 1]);
}

fn box() void {
    cart.rect(.{ .x = 0, .y = 14, .width = 160, .height = 114, .fill_color = hud.anti_black });
    hud.centered("LINK RACE", 4, hud.cyan);
}

/// The lobby. `cursor` is the host's row; the guest's is always MACHINE.
pub fn draw_lobby(v: *const View, cursor: u8, frame: u32) void {
    box();
    switch (v.state) {
        .lobby => {},
        .offline => {
            hud.centered("NO LINK IN", 40, hud.coral);
            hud.centered("SIMULATOR", 52, hud.coral);
            hud.centered("NEEDS TWO BADGES", 76, grey);
            return hud.centered("B BACK", 114, hud.dim);
        },
        .wrong_cart => {
            const name = lockstep.app_name(v.partner_app);
            if (name.len + 12 <= 20) {
                var buf: [20]u8 = undefined;
                @memcpy(buf[0..12], "WRONG CART: ");
                @memcpy(buf[12..][0..name.len], name);
                hud.centered(buf[0 .. 12 + name.len], 40, hud.coral);
            } else {
                hud.centered("WRONG CART:", 34, hud.coral);
                hud.centered(name, 46, hud.white);
            }
            hud.centered("START SNOUTY ZERO", 64, grey);
            hud.centered("ON THE OTHER BADGE", 76, grey);
            return hud.centered("B BACK", 114, hud.dim);
        },
        else => {
            // Searching (or a race state the lobby never shows).
            hud.centered("PLUG IN THE CABLE", 34, hud.white);
            var dots: [12]u8 = "SEARCHING...".*;
            const n_dots = (frame / 15) % 4;
            for (dots[9 + n_dots ..]) |*c| c.* = ' ';
            hud.text(&dots, 80 - 48, 46, hud.coral);
            hud.centered("UART HEADER TO", 64, grey);
            hud.centered("UART HEADER,", 76, grey);
            hud.centered("LINK RACE ON BOTH", 88, grey);
            return hud.centered("B BACK", 114, hud.dim);
        },
    }
    const host = v.role == .host;
    // Role and cable.
    hud.text(if (host) "HOST" else "GUEST", 4, 18, hud.cyan);
    const kind: []const u8 = switch (v.cable) {
        1 => "CROSSED",
        2 => "STRAIGHT",
        else => "",
    };
    hud.text(kind, 156 - 8 * @as(i32, @intCast(kind.len)), 18, grey);
    const sel: u8 = if (host) cursor else @backingInt(Row.machine);
    // TRACK: the host changes it, the guest sees it live.
    const ty: i32 = 34;
    if (sel == @backingInt(Row.track)) cart.rect(.{ .x = 2, .y = ty - 2, .width = 156, .height = 22, .fill_color = panel_hi });
    if (v.track) |ti| {
        const k = ti % track.tracks.len;
        hud.centered(track.tracks[k].name, ty, if (sel == @backingInt(Row.track)) hud.coral else hud.white);
        // "EDGE LEAGUE": the menu's leagues hold three tracks each.
        const league = track.leagues[k / 3].name;
        var buf: [16]u8 = undefined;
        @memcpy(buf[0..league.len], league);
        @memcpy(buf[league.len..][0..7], " LEAGUE");
        hud.centered(buf[0 .. league.len + 7], ty + 10, grey);
    } else {
        hud.centered("TRACK: ...", ty, grey);
        hud.centered("WAITING FOR HOST", ty + 10, grey);
    }
    if (host and sel == @backingInt(Row.track)) {
        hud.text("<", 4, ty, hud.coral);
        hud.text(">", 148, ty, hud.coral);
    }
    // MACHINE: both badges.
    const my: i32 = 62;
    const on_machine = sel == @backingInt(Row.machine);
    if (on_machine) cart.rect(.{ .x = 2, .y = my - 2, .width = 156, .height = 22, .fill_color = panel_hi });
    const pick = v.pick % 5;
    hud.centered(machine_names[pick], my, if (on_machine) hud.coral else machine_color(pick));
    hud.centered(menu.machine_blurbs[pick], my + 10, hud.orange);
    if (on_machine and !v.ready) {
        hud.text("<", 4, my, hud.coral);
        hud.text(">", 148, my, hud.coral);
    }
    // Ready marks.
    hud.text("YOU", 4, 88, hud.white);
    if (v.ready) hud.text("READY", 156 - 40, 88, hud.cyan) else hud.text("A: READY", 156 - 64, 88, grey);
    if (v.peer_pick) |pp| {
        hud.text("PEER", 4, 98, hud.white);
        const name = machine_names[pp % 5];
        hud.text(name, 44, 98, machine_color(pp % 5));
        if (v.peer_ready) hud.text("READY", 156 - 40, 98, hud.cyan);
    } else {
        hud.centered("PEER IN THE LOBBY", 98, grey);
    }
    // The prompt.
    if (host and v.can_go) {
        if ((frame / 20) % 2 == 0) hud.centered("START: GO", 114, hud.cyan);
    } else if (v.ready) {
        hud.centered(if (host) "WAITING FOR PEER" else "HOST STARTS", 114, grey);
    } else {
        hud.centered("A READY  B BACK", 114, hud.dim);
    }
}

/// Over a link race: `WAITING FOR PEER` (the partner's inputs are late)
/// or, for a while after the partner went, `PEER LEFT, AI DRIVING` with
/// the reason. A band across the floor above the message bar.
pub const Notice = enum(u8) { none, waiting, peer_left };

pub fn draw_notice(k: Notice, why: lockstep.Left, frame: u32) void {
    switch (k) {
        .none => {},
        .waiting => {
            cart.rect(.{ .x = 4, .y = 30, .width = 152, .height = 22, .fill_color = hud.anti_black });
            hud.centered("WAITING FOR PEER", 33, if ((frame / 20) % 2 == 0) hud.white else grey);
            hud.centered("CHECK THE CABLE", 42, grey);
        },
        .peer_left => {
            cart.rect(.{ .x = 4, .y = 22, .width = 152, .height = 31, .fill_color = hud.anti_black });
            hud.centered("PEER LEFT,", 25, hud.coral);
            hud.centered("AI DRIVING", 34, hud.white);
            const reason: []const u8 = switch (why) {
                .unplugged => "CABLE OUT",
                .restarted => "PEER RESTARTED",
                .quit => "PEER QUIT",
                .none => "",
            };
            hud.centered(reason, 43, grey);
        },
    }
}

/// Over the race and the results after a desync: the two badges' Worlds
/// parted and the race stopped there.
pub fn draw_desync(frame: u32) void {
    cart.rect(.{ .x = 0, .y = 56, .width = 160, .height = 16, .fill_color = hud.anti_black });
    hud.centered("DESYNC: RACE ENDED", 60, if ((frame / 20) % 2 == 0) hud.coral else hud.white);
}

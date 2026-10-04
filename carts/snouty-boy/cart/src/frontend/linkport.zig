//! The Game Boy link cable over the badge link (lib/link.zig, docs/LINK.md
//! M1 at the root): joins two badges' UART headers to the core's serial
//! port (core/serial.zig). The core gets a wire (`Gb.link`) only while the
//! partner badge runs Snouty Boy too; otherwise it keeps the no-cable stub,
//! so playing alone is exactly as before.
//!
//! While linked the scrubber, the chorded rewind and fast forward are off
//! (a rewound or sped-up game would leave the partner's behind): main.zig
//! and frontend/flow.zig read `linked`. The rewind history restarts when
//! the cable goes in and when it comes out. Between frames the cart keeps
//! answering the partner (`pump`) until `tuning.link_pump_until_us` after
//! the update began, so a master's transfer is answered within a scanline
//! or so even while this badge waits for vsync.
const cart = @import("cart-api");
const core = @import("core");
const link = @import("link");
const rewind = @import("rewind.zig");
const tuning = @import("tuning.zig");

/// Our app id in the link's HELLO: only another Snouty Boy is a partner.
pub const app_id: u8 = 'B';

var l: link.Badge = undefined;
/// The core has a wire (a Snouty Boy partner is connected).
pub var linked = false;
var session: u32 = 0;
/// Updates left to show the plugged/unplugged note.
pub var note_left: u16 = 0;
pub var note: []const u8 = "";

pub fn init() void {
    l = link.Badge.init(.{}, app_id, cart.rand());
}

/// Once per update, before the game steps: keep the link alive and attach
/// or detach the wire as the partner comes and goes.
pub fn update(gb: *core.Gb) void {
    l.poll(cart.micros_since_boot());
    const want = l.connected() and l.partner_app == app_id;
    if (want and linked and l.session != session) {
        // The partner's cart restarted: forget the old exchange.
        core.serial.unlink(gb);
    }
    if (want == linked) {
        session = l.session;
        return;
    }
    linked = want;
    session = l.session;
    if (want) {
        gb.link = .{ .ctx = &l, .send = send, .recv = recv };
        show("Link cable connected");
    } else {
        core.serial.unlink(gb);
        gb.link = null;
        show("Link cable unplugged");
    }
    gb.reschedule();
    // A history that mixes linked and unlinked play cannot replay.
    rewind.reset(gb);
}

/// After the frame: answer the partner until the pump deadline.
pub fn pump(gb: *core.Gb, update_us: u64) void {
    if (!linked) return;
    while (cart.micros_since_boot() -% update_us < tuning.link_pump_until_us) {
        core.serial.service(gb);
    }
}

fn show(s: []const u8) void {
    note = s;
    note_left = 120;
}

fn send(ctx: *anyopaque, m: core.serial.Msg) void {
    const lk: *link.Badge = @ptrCast(@alignCast(ctx));
    const bytes = m.encode();
    _ = lk.send(cart.micros_since_boot(), &bytes);
}

fn recv(ctx: *anyopaque) ?core.serial.Msg {
    const lk: *link.Badge = @ptrCast(@alignCast(ctx));
    if (lk.recv()) |p| return core.serial.Msg.decode(p.slice());
    lk.poll(cart.micros_since_boot());
    const p = lk.recv() orelse return null;
    return core.serial.Msg.decode(p.slice());
}

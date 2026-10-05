//! ComLynx over the link cable on the badge (docs/CABLE.md), as Snouty
//! Boy's frontend/linkport.zig is its Game Boy link: `link.Badge` (PIO2 on
//! the UART header, lib/link.zig) with app id 'X', the protocol in
//! frontend/cablenet.zig, the LINK screen in frontend/cable_screen.zig.
//! (The party branch's frontend/linkport.zig is the USB lobby transport;
//! this file is the cable's, so the two can sit side by side.)
//!
//! The link runs only from the moment the LINK screen opens until the
//! screen is left or the link ends: playing alone never touches the pins.
//! The DMA receive ring (`link.rp2350.rx_dma`, docs/LINK.md) is on: a
//! burst of ComLynx packets arriving while this badge steps a 15 ms frame
//! is longer than the PIO's 8-byte FIFO.
//!
//! While `linked` the core has a ComLynx port and the scrubber, the
//! chorded rewind and fast forward are off (a rewound or sped-up console
//! would leave the other behind): main.zig and the menu read `linked`. The
//! port's queues (~3.7 KB) are lent from the scrubber's arena
//! (frontend/rewind.zig `lend`) from GO until the link ends, when the
//! history restarts empty; unlinked the arena is all the scrubber's.
//! Between frames the cart keeps reading and answering the cable (`pump`)
//! until `tuning.link_pump_until_us` into the update, so acks come back
//! within a pump rather than a frame.
//!
//! `-Dlynx-link=false` (`enabled` false) leaves all of it out: every entry
//! point below returns at once on a comptime-known branch, so the link
//! driver, the protocol and the LINK screen are never analysed and the
//! scrub arena keeps their ~17 KB (docs/CABLE.md "Build option"). The
//! core's UART (core/uart.zig) stays: it is shared byte for byte with the
//! party branch and costs ~6 KB.
const cart = @import("cart-api");
const core = @import("core");
const link = @import("link");
const cablenet = @import("cablenet.zig");
const rewind = @import("rewind.zig");
const tuning = @import("tuning.zig");
const debug = @import("debug.zig");
const build_options = @import("build_options");

/// The link cable is built in (`-Dlynx-link`, on by default).
pub const enabled = build_options.link;

const Port = core.comlynx.Port;

pub const Net = cablenet.Net(link.Badge);

comptime {
    if (cablenet.max_payload != link.max_payload) @compileError("cablenet.max_payload must match lib/link.zig");
}

/// The cart DMA channel of the link's receive ring (3-15; the cart uses
/// no other DMA).
pub const dma_channel: u4 = 11;

var lk: link.Badge = undefined;
pub var net: Net = undefined;
/// `lk` exists (the LINK screen opened once).
var up = false;
/// The cable is serviced (the LINK screen is open, or linked).
pub var open = false;
/// The core has a ComLynx port (GO came and the console restarted).
pub var linked = false;
/// A note over the status strip's last line ("Partner left link"), updates
/// left to show it.
pub var note: []const u8 = "";
pub var note_left: u16 = 0;
/// GO came but the arena had no room for the port.
pub var no_memory = false;

/// The badge has the link hardware (false in the wasm simulator).
pub fn available() bool {
    if (!enabled) return false;
    return link.rp2350.Port.available;
}

fn now() u64 {
    return cart.micros_since_boot();
}

/// The LINK screen opens for the ROM with CRC `crc`: start (or restart)
/// the link, so the partner sees a fresh session.
pub noinline fn enter(crc: u32) void {
    if (!enabled) return;
    if (!up) {
        link.rp2350.rx_dma = dma_channel;
        lk = link.Badge.init(.{}, cablenet.app_id, cart.rand());
        up = true;
    } else lk.restart(now());
    net = Net.init(&lk, crc);
    open = true;
    no_memory = false;
}

/// Leave the LINK screen or the link: say so to the partner, the stub
/// again, the scrubber back.
pub fn close(l: *core.Lynx) void {
    if (!enabled or !open) return;
    net.leave(now, l);
    open = false;
    sync(l);
}

/// The link ended under us (the partner left, the cable came out): the
/// arena back, a note, the cable no longer serviced.
fn sync(l: *core.Lynx) void {
    if (linked and !net.linked) {
        rewind.take_back(l);
        if (open) show(if (lk.connected()) "Partner left link" else "Link cable out");
        open = false;
    }
    linked = net.linked and net.attached;
}

fn show(s: []const u8) void {
    note = s;
    note_left = 150;
}

/// Before the frame's step. True when GO restarted the console linked
/// (main.zig enters play).
pub fn before_frame(l: *core.Lynx) bool {
    if (!enabled or !open) return false;
    const restart = net.before_frame(now(), l);
    if (restart) {
        if (rewind.lend(@sizeOf(Port))) |mem| {
            net.restart(l, @ptrCast(mem.ptr));
            debug.core_moved();
            linked = true;
            show("Link cable: linked");
            return true;
        }
        no_memory = true;
        net.leave(now, l);
    }
    sync(l);
    return false;
}

/// After the frame (stepped or not): what the UART sent goes out.
pub fn after_frame(l: *core.Lynx) void {
    if (!enabled or !open) return;
    net.after_frame(now(), l);
    sync(l);
}

/// One linked game frame (main.zig `step`), in `tuning.link_slices`
/// pieces with the cable serviced between them.
pub noinline fn step_frame(l: *core.Lynx, pad: u16) void {
    if (!enabled) return l.step_frame(pad);
    net.step_frame(now, l, pad, tuning.link_slices);
}

/// At the end of the update, while linked: keep reading and answering the
/// cable until `tuning.link_pump_until_us` after `update_us`.
pub noinline fn pump(l: *core.Lynx, update_us: u64) void {
    if (!enabled or !linked) return;
    while (now() -% update_us < tuning.link_pump_until_us and net.linked) net.service(now(), l);
    sync(l);
}

/// After a boot while linked (the menu's Reset): attach the port again.
pub fn after_boot(l: *core.Lynx) void {
    if (!enabled) return;
    if (linked) if (net.port) |p| l.attach_link(p);
}

/// The LINK screen's view of the cable.
pub fn status() cablenet.Status {
    if (!enabled) return .unavailable;
    if (!up) return if (available()) .searching else .unavailable;
    return net.status();
}

pub fn partner_app() u8 {
    return lk.partner_app;
}

pub fn cable_kind() link.Cable {
    return lk.cable();
}

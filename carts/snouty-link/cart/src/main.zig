//! Snouty Link: the link-cable test cart (docs/LINK.md). Two badges joined
//! by a 3-pin JST-SH cable on their UART headers show each other's buttons
//! and the link's health: state, cable orientation, round trip, lost
//! packets and errors. While searching it shows the two header pins'
//! levels, which is what to look at when a cable will not connect.
//!
//! Every frame each badge sends one DATA packet (its buttons and a
//! sequence number) and pings every half second; the rest of the frame it
//! keeps polling the link so the partner's pings come back at wire speed.
//!
//! Diagnostics while not connected: falling edges on the receive pin
//! (EDGE: is the partner's data reaching us), raw bytes (BYT), locks and
//! handshake timeouts, the PIO program counters and FSTAT. A runs a
//! loopback self test of the PIO UART on each header pin (no cable
//! needed): OK, or N<bytes back> E<edges seen> <first bytes> P<pcs>.
//! B switches the UART between 1 Mbaud and 115200 (for a Raspberry Pi
//! Debug Probe and a serial terminal, docs/LINK.md).
const cart = @import("cart-api");
const link = @import("link");

comptime {
    cart.export_start_code();
}

/// Sent in HELLO; the partner shows it.
const app_id: u8 = 'L';
/// Keep polling the link until this long after the frame started (us).
const pump_until_us: u64 = 12_000;

const bg = cart.DisplayColor.rgb(0x101820);
const fg = cart.DisplayColor.rgb(0xE0E8F0);
const dim = cart.DisplayColor.rgb(0x60707C);
const good = cart.DisplayColor.rgb(0x40E070);
const warn = cart.DisplayColor.rgb(0xF0C040);
const bad = cart.DisplayColor.rgb(0xF05050);

var l: link.Badge = undefined;
var frame: u32 = 0;
var seq: u8 = 0;
var partner_buttons: u16 = 0;
var partner_seq: ?u8 = null;
var lost: u32 = 0;
var received: u32 = 0;
var session_seen: u32 = 0;
/// Falling edges seen on the receive pin while pumping (diagnostics).
var rx_edges: u32 = 0;
var rx_was_high = false;
var tests: [2]link.rp2350.SelfTest = undefined;
var tested = false;
var a_was_down = false;
var b_was_down = false;

pub fn start() void {
    cart.set_vsync_enabled(1000.0 / 60.0);
    cart.set_double_buffer_mode(.no_copy_full_frame);
    l = link.Badge.init(.{}, app_id, cart.rand());
}

pub fn update() void {
    const t0 = cart.micros_since_boot();
    const mine = read_controls();
    const mine_bits: u16 = @bitCast(mine);
    const a_down = mine.a and !(start_select_held(mine));

    // A: self test of the PIO UART on each header pin (loopback, no cable
    // needed), then search again.
    if (a_down and !a_was_down and l.state != .unavailable) {
        tests = .{ link.rp2350.self_test(.a), link.rp2350.self_test(.b) };
        tested = true;
        l.restart(cart.micros_since_boot());
    }
    a_was_down = a_down;

    // B: switch the UART speed (1 Mbaud, or 115200 for a Debug Probe and a
    // serial terminal); both badges must match.
    const b_down = mine.b and !(start_select_held(mine));
    if (b_down and !b_was_down and l.state != .unavailable) {
        link.rp2350.baud = if (link.rp2350.baud == link.baud) 115_200 else link.baud;
        l.restart(cart.micros_since_boot());
    }
    b_was_down = b_down;

    l.poll(t0);
    if (l.session != session_seen) {
        session_seen = l.session;
        partner_seq = null;
        partner_buttons = 0;
    }
    if (l.connected()) {
        seq +%= 1;
        _ = l.send(t0, &.{ 'B', @truncate(mine_bits), @truncate(mine_bits >> 8), seq });
        if (frame % 30 == 0) l.ping(t0);
    }
    drain();

    draw(mine_bits);
    frame +%= 1;

    if (cart.is_wasm) {
        present_wasm();
        return;
    }
    while (cart.micros_since_boot() - t0 < pump_until_us) {
        l.poll(cart.micros_since_boot());
        drain();
        // Falling edges on the receive pin: is the partner's data on the wire?
        const rx: link.Pin = if (l.mode == .normal) .b else .a;
        for (0..32) |_| {
            const high = l.port.read(rx);
            if (rx_was_high and !high) rx_edges += 1;
            rx_was_high = high;
        }
    }
}

fn start_select_held(c: cart.Controls) bool {
    return c.start and c.select;
}

fn drain() void {
    while (l.recv()) |p| {
        const b = p.slice();
        if (b.len != 4 or b[0] != 'B') continue;
        partner_buttons = @as(u16, b[1]) | @as(u16, b[2]) << 8;
        if (partner_seq) |prev| lost += b[3] -% prev -% 1;
        partner_seq = b[3];
        received += 1;
    }
}

// ---- drawing ----

fn draw(mine: u16) void {
    cart.rect(.{ .x = 0, .y = 0, .width = 160, .height = 128, .fill_color = bg });
    cart.text(.{ .str = "SNOUTY LINK", .x = 0, .y = 0, .text_color = warn });

    var buf: [24]u8 = undefined;
    const state_str: []const u8, const state_color = switch (l.state) {
        .unavailable => .{ "NO LINK PORT", dim },
        .searching => .{ "SEARCHING", warn },
        .handshake => .{ "HANDSHAKE", warn },
        .connected => .{ "CONNECTED", good },
    };
    say(0, 0, "STATE", dim);
    say(6, 0, state_str, state_color);

    const s = l.stats;
    switch (l.state) {
        .unavailable => {
            say(0, 2, "THE SIMULATOR HAS", fg);
            say(0, 3, "NO UART HEADER.", fg);
            say(0, 4, "RUN ON A BADGE.", fg);
        },
        .searching, .handshake => {
            say(0, 1, "MODE", dim);
            say(6, 1, if (l.mode == .normal) "TX PIN1" else "TX PIN3", fg);
            say(15, 1, if (link.rp2350.baud == link.baud) "1M" else "115K", warn);
            say(0, 2, "PIN1", dim);
            say(5, 2, level(l.port.read(.a)), fg);
            say(9, 2, "PIN3", dim);
            say(14, 2, level(l.port.read(.b)), fg);
            say(0, 3, "EDGE", dim);
            say(5, 3, fmt(&buf, "{d}", .{rx_edges}), fg);
            say(11, 3, "BYT", dim);
            say(15, 3, fmt(&buf, "{d}", .{s.rx_bytes}), fg);
            say(0, 4, "LOCK", dim);
            say(5, 4, fmt(&buf, "{d}", .{s.locks}), fg);
            say(11, 4, "TMO", dim);
            say(15, 4, fmt(&buf, "{d}", .{s.handshake_timeouts}), fg);
            if (link.rp2350.is_badge) {
                const r = link.rp2350.regs();
                say(0, 5, fmt(&buf, "PC {d} {d} FS {X:0>8}", .{ r.pc0, r.pc1, r.fstat }), dim);
            }
        },
        .connected => {
            say(0, 1, "CABLE", dim);
            say(6, 1, if (l.cable() == .crossed) "CROSSED" else "STRAIGHT", fg);
            say(0, 2, "PEER", dim);
            say(6, 2, fmt(&buf, "{c} V{d} S{d}", .{ printable(l.partner_app), l.partner_version, l.session }), fg);
            say(0, 3, "RTT", dim);
            say(6, 3, if (l.rtt_us == 0) "-" else fmt(&buf, "{d} US", .{l.rtt_us}), fg);
            say(0, 4, "DATA", dim);
            say(6, 4, fmt(&buf, "{d}", .{received}), fg);
            say(0, 5, "LOST", dim);
            say(6, 5, fmt(&buf, "{d}", .{lost}), if (lost == 0) fg else bad);
        },
    }

    if (l.state != .unavailable) {
        if (tested) {
            for (tests, 0..) |t, i| {
                const name: []const u8 = if (i == 0) "PIN1" else "PIN3";
                if (t.ok()) {
                    say(0, 6 + @as(i32, @intCast(i)), fmt(&buf, "{s} OK E{d}", .{ name, t.edges }), good);
                } else {
                    say(0, 6 + @as(i32, @intCast(i)), fmt(&buf, "{s} N{d} E{d} {X:0>2}{X:0>2} P{d}{d}", .{
                        name, t.n, t.edges, t.got[0], t.got[1], t.regs.pc0, t.regs.pc1,
                    }), bad);
                }
            }
        } else {
            say(0, 6, "A: SELF TEST B: BAUD", dim);
        }
    }

    say(0, 8, "CRC", dim);
    say(4, 8, fmt(&buf, "{d}", .{s.crc_errors}), if (s.crc_errors == 0) fg else bad);
    say(10, 8, "FRM", dim);
    say(14, 8, fmt(&buf, "{d}", .{s.framing_errors}), fg);
    say(0, 9, "TX", dim);
    say(4, 9, fmt(&buf, "{d}", .{s.tx_packets}), fg);
    say(10, 9, "RX", dim);
    say(14, 9, fmt(&buf, "{d}", .{s.rx_packets}), fg);

    pad(4, 101, "ME", mine);
    pad(84, 101, "PEER", if (l.connected()) partner_buttons else 0);
}

/// Buttons as lit boxes: a cross for the stick, then B and A, SELECT and
/// START; 27 pixels tall, label above.
fn pad(x: i32, y: i32, label: []const u8, bits: u16) void {
    const c: cart.Controls = @bitCast(bits);
    cart.text(.{ .str = label, .x = x, .y = y - 9, .text_color = dim });
    box(x + 7, y, c.up);
    box(x + 7, y + 14, c.down);
    box(x, y + 7, c.left);
    box(x + 14, y + 7, c.right);
    box(x + 28, y + 9, c.b);
    box(x + 38, y + 4, c.a);
    box(x + 26, y + 20, c.select);
    box(x + 36, y + 20, c.start);
}

fn box(x: i32, y: i32, on: bool) void {
    cart.rect(.{ .x = x, .y = y, .width = 6, .height = 6, .stroke_color = dim, .fill_color = if (on) good else bg });
}

/// Text rows 0..9 at y = 10..82 (the pads start at y = 92).
fn say(col: i32, row: i32, str: []const u8, color: cart.DisplayColor) void {
    cart.text(.{ .str = str, .x = col * 8, .y = 10 + row * 8, .text_color = color });
}

fn level(high: bool) []const u8 {
    return if (high) "HI" else "LO";
}

fn printable(c: u8) u8 {
    return if (c >= ' ' and c <= 'Z') c else '?';
}

fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return @import("std").fmt.bufPrint(buf, f, args) catch "?";
}

/// Button state. Upstream's platform_wasm.zig exposes `controls` but never
/// fills it from the simulator, which writes its button word (same bit
/// layout as cart.Controls) to linear address 0x04; read that directly on
/// wasm. Hardware gets the OS-maintained cart.controls. (From demosnout.)
fn read_controls() cart.Controls {
    if (cart.is_wasm) return @bitCast(@as(*const volatile u16, @ptrFromInt(0x04)).*);
    return cart.controls.*;
}

/// Simulator shim (see snouty-bugs/CLAUDE.md): upstream's wasm platform
/// never presents, and the web simulator reads a legacy framebuffer at 0x20
/// with red and blue swapped. Hardware builds compile none of this.
fn present_wasm() void {
    const sim_framebuffer: *cart.Framebuffer = @ptrFromInt(0x20);
    for (cart.framebuffer, sim_framebuffer) |*src_column, *dst_column| {
        for (src_column, dst_column) |src, *dst| {
            const c = src.to_color();
            dst.* = .from_color(.{ .r = c.b, .g = c.g, .b = c.r });
        }
    }
}

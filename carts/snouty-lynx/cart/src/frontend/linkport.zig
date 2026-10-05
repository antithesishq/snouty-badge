//! ComLynx on the badge (docs/COMLYNX.md sections 6 and 10), as Snouty
//! Boy's frontend/linkport.zig is its link cable: the fork firmware's cart
//! serial port (lib/cart_serial.zig, the raw ring ABI at 0x200350F4 for
//! our pinned SDK), the lobby client on it (lib/party.zig) and the
//! console's ComLynx port on that (frontend/lynxnet.zig).
//!
//! While `linked` the core has a ComLynx port and the scrubber, the
//! chorded rewind and fast forward are off (a rewound or sped-up console
//! would leave the others behind): main.zig and the menu read `linked`.
//! The ComLynx port's queues live in the scrubber's arena, lent from the
//! moment the lobby opens (frontend/rewind.zig `lend`) until it closes;
//! the history restarts empty after. The serial rings are static (the OS
//! may finish a pass after the cart unpublishes them): 2 KiB in, 512 B
//! out, which holds three peers' worst-case frames (62,500 baud, 4 bytes
//! a ComLynx frame) for longer than a badge frame, and the ring is
//! drained every frame (the relay drops a badge that stops reading).
const core = @import("core");
const party = @import("party");
const cart_serial = @import("cart_serial");
const rewind = @import("rewind.zig");
const lynxnet = @import("lynxnet.zig");

const Port = core.comlynx.Port;

pub const Serial = cart_serial.Badge(.{ .rx_size = 2048, .tx_size = 512 });
pub const Client = party.Client(Serial);
pub const Net = lynxnet.Net(Client);

/// The name every Lynx goes by in the rosters (no text entry on a badge).
pub const player_name = "LYNX";
/// Rooms hold this many (Slime World links 8).
pub const max_players = 8;

/// The core has a ComLynx port (GO came).
pub var linked = false;
/// The lobby client exists (the lobby was opened once).
var up = false;
var client: Client = undefined;
pub var net: Net = undefined;
var port: ?*Port = null;

/// The firmware serves the cart serial port (`os_flags` bit 1). Never in
/// the web simulator or badge-bench.
pub fn supported() bool {
    var s: Serial = .{};
    return s.supported();
}

/// Open the lobby for the ROM with CRC `crc`: the port's memory from the
/// scrub arena, the client (its HELLO joins the ROM's room). False when
/// the arena is too small.
pub fn open(crc: u32) bool {
    // Stock firmware or the simulator: the screen says so, the scrub
    // history stays.
    if (!supported()) return true;
    if (port == null) {
        const mem = rewind.lend(@sizeOf(Port)) orelse return false;
        const p: *Port = @ptrCast(mem.ptr);
        p.* = .{};
        port = p;
    }
    if (!up) {
        client = Client.init(.{}, .{
            .game = Net.game_id(crc),
            .name = party.pad(party.name_len, player_name),
            .max_players = max_players,
        });
        net = Net.init(&client, port.?, crc);
        net.want_d_ms = 25;
        up = true;
    } else {
        net.port = port.?;
        net.crc = crc;
        client.join();
    }
    return true;
}

/// Leave the room and the link: the stub again, the scrubber back.
pub fn close(l: *core.Lynx) void {
    if (up) {
        net.unlink(l);
        net.set_ready(false);
        client.leave();
    }
    linked = false;
    if (port != null) {
        port = null;
        rewind.take_back(l);
    }
}

/// The lobby state (for the screen).
pub fn state() party.State {
    if (!up) return if (supported()) .disconnected else .unsupported;
    return client.state();
}

/// A player's name in the room ("" when absent).
pub fn name(id: u8) []const u8 {
    return if (up) client.name(id) else "";
}

/// Before the frame's step: drain the ring, act on what came. True when
/// GO restarted the console linked (main.zig enters play).
pub fn before_frame(l: *core.Lynx) bool {
    if (!up) return false;
    const restarted = net.before_frame(l);
    linked = net.linked;
    // The room is gone (the relay or the cable): play on alone.
    if (linked and client.state() != .joined) {
        net.unlink(l);
        linked = false;
    }
    return restarted;
}

/// May the frame step (timestamped mode waits for the peers)?
pub fn can_step(l: *const core.Lynx) bool {
    if (!up or !linked) return true;
    return net.can_step(l);
}

/// After the frame (stepped or not): send what the UART sent.
pub fn after_frame(l: *core.Lynx) void {
    if (!up) return;
    net.after_frame(l);
}

/// After a boot while linked (menu Reset): attach the port again.
pub fn after_boot(l: *core.Lynx) void {
    if (linked and net.attached) l.attach_link(port.?);
}

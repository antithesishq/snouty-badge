//! A simulated 3-pin cable between two badges, for host tests of
//! lib/link.zig. Each end is a Port. Wires: crossed joins pin a of one end
//! to pin b of the other, straight joins a to a and b to b. A wire reads
//! high when any end drives it high (SIO search, or an idle UART transmit
//! pin) and low otherwise (the pads' pull-downs). Bytes put on a UART
//! transmit pin arrive at once at the other end if its UART receives on
//! that wire. Fights are counted: a byte sent on a wire the other end also
//! drives (its levels would clash on the low bits).
const link = @import("link.zig");
const Pin = link.Pin;

pub const Kind = enum { crossed, straight };

const End = struct {
    /// SIO search: the pin driven high (the other is an input).
    drive: ?Pin = null,
    /// UART running: its transmit pin (receive is the other pin).
    uart_tx: ?Pin = null,
    rx: [256]u8 = undefined,
    rx_head: u8 = 0,
    rx_len: u16 = 0,
};

pub const Cable = struct {
    kind: Kind,
    plugged: bool = true,
    ends: [2]End = .{ .{}, .{} },
    fights: u32 = 0,
    /// Bytes lost because the other end was not receiving on that wire.
    lost: u32 = 0,
    /// Drop every byte while set (a noisy cable).
    drop_all: bool = false,

    pub fn port(c: *Cable, side: u1) Port {
        return .{ .cable = c, .side = side };
    }

    /// The pin of end `to` that end `from`'s `pin` is wired to.
    fn far_pin(c: *const Cable, pin: Pin) Pin {
        return if (c.kind == .straight) pin else pin.other();
    }

    fn drives_high(e: *const End, pin: Pin) bool {
        if (e.uart_tx) |tx| return tx == pin;
        if (e.drive) |d| return d == pin;
        return false;
    }

    /// Restart one end as if its cart started again (pins released).
    pub fn reset_end(c: *Cable, side: u1) void {
        c.ends[side] = .{};
    }
};

pub const Port = struct {
    pub const available = true;
    cable: *Cable,
    side: u1,

    fn me(p: *Port) *End {
        return &p.cable.ends[p.side];
    }
    fn them(p: *Port) *End {
        return &p.cable.ends[p.side ^ 1];
    }

    pub fn search(p: *Port, drive: Pin) void {
        p.me().* = .{ .drive = drive };
    }

    pub fn read(p: *Port, pin: Pin) bool {
        if (Cable.drives_high(p.me(), pin)) return true;
        if (!p.cable.plugged) return false;
        return Cable.drives_high(p.them(), p.cable.far_pin(pin));
    }

    pub fn uart_start(p: *Port, tx: Pin) void {
        p.me().* = .{ .uart_tx = tx };
    }

    pub fn uart_put(p: *Port, byte: u8) bool {
        const tx = p.me().uart_tx orelse return true;
        if (!p.cable.plugged or p.cable.drop_all) return true;
        const far = p.cable.far_pin(tx);
        const t = p.them();
        if (Cable.drives_high(t, far)) p.cable.fights += 1;
        const rx_ok = if (t.uart_tx) |their_tx| their_tx.other() == far else false;
        if (!rx_ok or t.rx_len == t.rx.len) {
            p.cable.lost += 1;
            return true;
        }
        t.rx[(t.rx_head +% @as(u8, @truncate(t.rx_len)))] = byte;
        t.rx_len += 1;
        return true;
    }

    pub fn uart_get(p: *Port) ?u8 {
        const e = p.me();
        if (e.uart_tx == null or e.rx_len == 0) return null;
        const byte = e.rx[e.rx_head];
        e.rx_head +%= 1;
        e.rx_len -= 1;
        return byte;
    }

    pub fn take_framing_errors(_: *Port) u32 {
        return 0;
    }
};

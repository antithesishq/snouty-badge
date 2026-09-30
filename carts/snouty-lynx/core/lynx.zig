//! The whole Atari Lynx: `Lynx`, `init_in_place`, `reset`, `step_frame(pad)`
//! and the frame view the frontend converts (SPEC.md sections 6 and 7).
//! Badge-agnostic: no cart-api, no floats, no allocator, no clock, no
//! randomness; the pad word per frame is the only input.
//!
//! M0 scaffold: the subsystems (cpu65.zig, bus.zig, mikey.zig, suzy.zig)
//! are stubs with their public shape, and `step_frame` draws a moving test
//! pattern into RAM at the display address with a fixed 16-colour palette,
//! so the frontend's video path (framebuffer bytes -> two palette indices ->
//! RGB565, SPEC.md 6) is exercised end to end. M1 replaces the body of
//! `step_frame` with 1/60 s of emulated time (266,667 ticks of 16 MHz).
const std = @import("std");

pub const cart = @import("cart.zig");
pub const cpu65 = @import("cpu65.zig");
pub const bus = @import("bus.zig");
pub const mikey = @import("mikey.zig");
pub const suzy = @import("suzy.zig");
// TODO(M0 Track A): `pub const boot = @import("boot.zig");` - the post-boot
// state (loader decryption, registers, MAPCTL, cart block counter; SPEC.md
// section 11). It plugs into `init_in_place`/`reset` below.

pub const Cart = cart.Cart;

/// Picture size (SPEC.md section 6): 160x102, 4 bits per pixel.
pub const screen_w = 160;
pub const screen_h = 102;
/// Bytes of one displayed frame in Lynx RAM (two pixels per byte, the left
/// one in the high nibble).
pub const frame_bytes = screen_w * screen_h / 2;

/// The pad word `step_frame` takes. The low byte is the JOYSTICK register
/// ($FCB0) layout as an unrotated game reads it; bit 8 is Pause (SWITCHES
/// $FCB1 bit 0). SPEC.md section 5.
pub const Pad = struct {
    pub const a: u16 = 1 << 0; // outer button
    pub const b: u16 = 1 << 1; // inner button
    pub const opt2: u16 = 1 << 2;
    pub const opt1: u16 = 1 << 3;
    pub const right: u16 = 1 << 4;
    pub const left: u16 = 1 << 5;
    pub const down: u16 = 1 << 6;
    pub const up: u16 = 1 << 7;
    pub const pause: u16 = 1 << 8;
};

/// What the frontend shows: `frame_bytes` bytes of 4-bit pixels, row after
/// row, and the palette registers (GREEN $FDA0-$FDAF low nibble, BLUERED
/// $FDB0-$FDBF blue high nibble, red low nibble).
pub const Frame = struct {
    pixels: *const [frame_bytes]u8,
    green: *const [16]u8,
    bluered: *const [16]u8,
};

pub const Lynx = struct {
    /// The 64 KB of RAM (display and collision buffers live in it).
    ram: [0x10000]u8,
    cpu: cpu65.Regs,
    mikey: mikey.Mikey,
    suzy: suzy.Suzy,
    cart: Cart,
    /// The pad word of the last `step_frame`.
    pad: u16,
    /// Frames stepped since reset.
    frame_count: u32,

    /// Set up in place (the console is ~66 KB: never build one on the
    /// stack, 32 KB on the badge).
    pub fn init_in_place(l: *Lynx, c: Cart) void {
        l.cart = c;
        l.reset();
    }

    pub fn reset(l: *Lynx) void {
        @memset(&l.ram, 0);
        l.cpu = .{};
        l.mikey = .{};
        l.suzy = .{};
        l.pad = 0;
        l.frame_count = 0;
        // TODO(M0 Track A): boot.apply(l) - decrypt the loader from
        // `l.cart` into RAM and leave the registers, MAPCTL and the block
        // counter as the boot ROM does.
    }

    /// One badge frame of Lynx time. M0: the test pattern.
    pub fn step_frame(l: *Lynx, pad: u16) void {
        l.pad = pad;
        test_pattern(l);
        l.frame_count +%= 1;
    }

    /// The frame to show (the display buffer at DISPADR).
    pub fn frame(l: *const Lynx) Frame {
        const a: u16 = l.mikey.dispadr & 0xFFFC;
        const start = @min(@as(usize, a), l.ram.len - frame_bytes);
        return .{
            .pixels = l.ram[start..][0..frame_bytes],
            .green = &l.mikey.green,
            .bluered = &l.mikey.bluered,
        };
    }
};

/// M0 placeholder: 16 vertical bars (10 px each, palette 0..15), a band
/// that walks down one line a frame in inverted colours, and in rows 0..3
/// the first 320 bytes of cart block 0 as pixels (so the cart path shows).
fn test_pattern(l: *Lynx) void {
    for (&l.mikey.green, &l.mikey.bluered, 0..) |*g, *br, i| {
        const v: u8 = @intCast(i);
        // A hue walk: red up, green across, blue down.
        g.* = (v * 7) & 0xF;
        br.* = ((15 - v) << 4) | v;
    }
    l.mikey.green[0] = 0;
    l.mikey.bluered[0] = 0x20;
    l.mikey.green[15] = 0xF;
    l.mikey.bluered[15] = 0xFF;

    const base: usize = l.mikey.dispadr;
    const band: u32 = l.frame_count % screen_h;
    var y: u32 = 0;
    while (y < screen_h) : (y += 1) {
        const row = l.ram[base + y * (screen_w / 2) ..][0 .. screen_w / 2];
        for (row, 0..) |*px, bx| {
            const x: u32 = @intCast(bx * 2);
            var left: u8 = @intCast(x / 10);
            var right: u8 = @intCast((x + 1) / 10);
            if (y < 4) {
                const c = l.cart.read(0, y * (screen_w / 2) + @as(u32, @intCast(bx)));
                left = c >> 4;
                right = c & 0xF;
            } else if (y >= band and y < band + 6) {
                left ^= 0xF;
                right ^= 0xF;
            }
            px.* = left << 4 | right;
        }
    }
}

test "lynx: test pattern fills the frame deterministically" {
    const S = struct {
        var l: Lynx = undefined;
    };
    const data: [600]u8 = @splat(0x12);
    const lay = cart.parse(&data, data.len);
    S.l.init_in_place(Cart.from_slice(&lay, &data));
    S.l.step_frame(0);
    const f = S.l.frame();
    try std.testing.expectEqual(@as(u8, 0x12), f.pixels[0]);
    // Row 4 is in the inverted band on frame 0: bar 0 reads 15.
    try std.testing.expectEqual(@as(u8, 0xFF), f.pixels[4 * 80]);
    // Row 10, pixels 0/1: bar 0; pixels 158/159: bar 15.
    try std.testing.expectEqual(@as(u8, 0x00), f.pixels[10 * 80]);
    try std.testing.expectEqual(@as(u8, 0xFF), f.pixels[10 * 80 + 79]);
    try std.testing.expectEqual(@as(u32, 1), S.l.frame_count);
}

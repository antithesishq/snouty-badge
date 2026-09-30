//! Stand-in for a part that is not written yet (M0: parts 3 to 10), so the
//! timeline is complete from the first milestone. Draws a dark vertical
//! gradient tinted per part, the part's index as a big digit that pulses on
//! the beat, and its name underneath. `Placeholder(index, name)` returns a
//! module-shaped struct with the part interface of SPEC.md section 4.
const cart = @import("cart-api");
const palette = @import("../palette.zig");
const fx = @import("../fx.zig");
const text = @import("../text.zig");

pub fn Placeholder(comptime index: u8, comptime label: []const u8) type {
    return struct {
        pub const name: []const u8 = label;

        const digits: []const u8 = if (index < 10)
            &[_]u8{'0' + index}
        else
            &[_]u8{ '0' + index / 10, '0' + index % 10 };

        // A different dark tint per part: hue from the index.
        const tints = [_]u32{ 0x180830, 0x082030, 0x301008, 0x083018, 0x280828, 0x302808 };
        const tint = tints[index % tints.len];

        pub fn init() void {}
        pub fn enter() void {}

        pub fn render(t: u32, fb: cart.FramebufferPtr) void {
            fx.vgradient(fb, 0x020204, tint);
            // Brightness pulse on the 30-frame beat.
            const beat: u32 = t % 30;
            const glow: u32 = 255 - @min(beat * 8, 150);
            const g: u32 = (glow << 16) | (glow << 8) | glow;
            const scale = 6;
            const x = text.centre_x(digits, scale);
            text.shadowed(digits, x, 30, .rgb(palette.mix_rgb(0x404040, g, 256)), scale);
            text.shadowed(name, text.centre_x(name, 1), 88, .rgb(0xc0c0d0), 1);
            text.shadowed("coming in M1", text.centre_x("coming in M1", 1), 104, .rgb(0x606078), 1);
        }
    };
}

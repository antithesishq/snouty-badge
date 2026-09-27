//! Stub `cart-api` module for the bare-metal emulation bench.
//!
//! Only the parts of the cart API the tracer modules use. The types must
//! track ../sycl-badge/src/os/cart/api.zig (non-wasm path): DisplayColor is
//! packed r:u5 (bits 0..4), g:u6 (5..10), b:u5 (11..15), and on hardware
//! `Pixel.from_color` is a plain @bitCast of DisplayColor (the wasm build
//! byte-swaps; that path is irrelevant here). If upstream changes either
//! layout, change it here too or the emulated PNGs will not match.
pub const is_wasm = false;
pub const screen_width: u32 = 160;
pub const screen_height: u32 = 128;

pub const DisplayColor = packed struct(u16) { r: u5, g: u6, b: u5 };

pub const Pixel = packed struct(u16) {
    bits: u16,
    pub fn from_color(color: DisplayColor) Pixel {
        return @bitCast(color);
    }
    pub fn to_color(pixel: Pixel) DisplayColor {
        return @bitCast(pixel);
    }
    pub fn set_color(pixel: *Pixel, color: DisplayColor) void {
        pixel.* = from_color(color);
    }
};

pub const framebuffer_alignment = 0x2000;
pub const Framebuffer = [screen_width][screen_height]Pixel;
pub const FramebufferPtr = *align(framebuffer_alignment) Framebuffer;

/// The emulator finds the framebuffer through this symbol (bench.py).
export var fb_storage: Framebuffer align(framebuffer_alignment) linksection(".fb") = undefined;
/// A var pointer, as on hardware (api.zig: `pub var framebuffer: FramebufferPtr`),
/// so the tracer's codegen reloads it the same way.
pub export var framebuffer: FramebufferPtr = &fb_storage;

pub fn micros_since_boot() u64 {
    return 0;
}

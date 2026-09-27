//! Root of an execute-in-place (XIP) cart build (build/os_cart.zig, mode .xip).
//!
//! The cart itself is the `user_cart` module, untouched: it still calls
//! `cart.export_start_code()`, so the SDK's RAM platform exports `_start`, the
//! usual start/update/present loop, and looks for `start`/`update` on the root
//! module, which this file forwards. What differs from a RAM cart is only how
//! the OS gets into that loop: it reads `[SP, entry]` from the vector table at
//! the start of the cart flash window (sycl-badge/src/cart/cart_xip.ld,
//! src/os/cart.zig executeCart), sets VTOR and jumps. Unlike the RAM path it
//! does not enable the FPU or the cycle counter, mask interrupts, copy `.data`
//! or clear `.bss` for us, so the reset handler here does all of that before
//! calling `_start`.
const cart = @import("cart-api");
const user = @import("user_cart");

// Pulls the SDK's RAM platform into analysis so that its `_start` export exists
// (Zig only emits a file's exports once something references that file; in a
// RAM cart the cart's own root does this). The 20-byte descriptor it also
// exports lands in an orphan section and is unused in XIP mode.
comptime {
    cart.export_start_code();
}

pub fn start() void {
    user.start();
}

pub fn update() void {
    user.update();
}

/// The SDK's RAM cart entry (platform_cart_ram.zig): aligns cycles with the OS,
/// calls root.start(), then loops root.update() and present() forever.
extern fn _start() callconv(.c) void;

// Linker-script symbols (cart_xip.ld). Only their addresses are used.
extern var __stack_top__: u8;
extern var microzig_data_start: u32;
extern var microzig_data_end: u8;
extern var microzig_data_load_start: u32;
extern var microzig_bss_start: u32;
extern var microzig_bss_end: u8;

const VectorTable = extern struct {
    initial_sp: *const anyopaque,
    reset: *const fn () callconv(.c) noreturn,
};

/// First words of the flash window: what the OS validates and jumps through.
/// The linker sets bit 0 of the Thumb function address for us.
export const xip_vector_table linksection("microzig_flash_start") = VectorTable{
    .initial_sp = @ptrCast(&__stack_top__),
    .reset = &xip_reset,
};

fn xip_reset() callconv(.c) noreturn {
    // Carts poll the OS; no interrupt may land while VTOR points at a
    // two-entry table.
    asm volatile ("cpsid i");

    // FPU on (CPACR CP10/CP11 full access, FPCCR lazy stacking), as the RAM
    // path in src/os/cart.zig does before jumping.
    const CPACR: *volatile u32 = @ptrFromInt(0xE000ED88);
    const FPCCR: *volatile u32 = @ptrFromInt(0xE000EF34);
    FPCCR.* = FPCCR.* | (1 << 31) | (1 << 30);
    CPACR.* = 0xFFFF_FFFF;

    // Cycle counter: DEMCR.TRCENA then DWT_CTRL.CYCCNTENA. The SDK loop and
    // badge-bench read DWT_CYCCNT to time frames.
    const DEMCR: *volatile u32 = @ptrFromInt(0xE000EDFC);
    const DWT_CTRL: *volatile u32 = @ptrFromInt(0xE0001000);
    DEMCR.* = DEMCR.* | (1 << 24);
    DWT_CTRL.* = DWT_CTRL.* | 1;
    asm volatile ("dsb\n isb");

    // .data lives in RAM but is stored in flash; .bss starts zeroed. Both are
    // 4-byte aligned by cart_xip.ld, so copy and clear by words (the cart RAM
    // of a big cart is 165 KB of .bss; bytes would take 4 ms at start-up).
    const data_len = @intFromPtr(&microzig_data_end) - @intFromPtr(&microzig_data_start);
    const data_dst: [*]volatile u32 = @ptrCast(&microzig_data_start);
    const data_src: [*]const volatile u32 = @ptrCast(&microzig_data_load_start);
    var i: usize = 0;
    while (i < data_len / 4) : (i += 1) data_dst[i] = data_src[i];
    const bss_len = @intFromPtr(&microzig_bss_end) - @intFromPtr(&microzig_bss_start);
    const bss: [*]volatile u32 = @ptrCast(&microzig_bss_start);
    i = 0;
    while (i < bss_len / 4) : (i += 1) bss[i] = 0;
    asm volatile ("dsb\n isb");

    _start();
    unreachable;
}

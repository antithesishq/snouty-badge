//! Emulator menu (SPEC.md sections 5 and 12). M2 stub with the frozen
//! public shape (PLAN.md M2 contract); Track A fills it in. Until then B
//! resumes and nothing is drawn.
const cart = @import("cart-api");
const core = @import("core");
const input = @import("input.zig");

pub const version = "0.2.0-m2";

/// Sound approximation on/off (SPEC.md section 9): main.zig copies it into
/// `audio.enabled` every frame. Keep the name.
pub var sound_enabled: bool = true;

pub const Result = enum { stay, resume_game };

/// Enter the menu. Called in the frame the Select hold threshold is
/// reached, before anything is drawn; the caller then calls `update` once
/// in the same frame.
pub fn open() void {}

/// Leave the menu; the caller steps the game in the same frame.
pub fn close() void {}

/// One menu frame: handle input, then draw over the frozen game frame.
/// Returns `.resume_game` when the game should run again (the caller calls
/// `close`, suppresses held buttons and runs a game frame).
pub fn update(gg: *core.Gg, e: input.Edge) Result {
    _ = gg;
    cart.rect(.{ .x = 0, .y = 0, .width = cart.screen_width, .height = 12, .fill_color = .rgb(0x2040C0) });
    cart.text(.{ .str = "MENU (M2 stub) B", .x = 2, .y = 2, .text_color = .rgb(0xFFFFFF) });
    if (e.pressed(.b)) return .resume_game;
    return .stay;
}

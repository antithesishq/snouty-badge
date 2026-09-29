//! `Md.tone()` -> the badge's one `tone2` voice (SPEC.md section 9). Calls
//! `tone2` only when the note changes, and stops the buzzer when nothing
//! is keyed on. f32 is fine here (frontend, not core). M1 Track C owns
//! this file; M2 adds the menu's sound toggle through `enabled`.
//!
//! Volume: `Tone.level` 0..15 maps linearly onto tone2 volume 0.2..1.0
//! (level 0 is still audible: silence is `tone()` returning null).
const cart = @import("cart-api");
const core = @import("core");

/// Sound on/off (menu toggle from M2, default on).
pub var enabled: bool = true;

/// Frequencies outside this range are treated as silence.
const min_hz: u16 = 20;
const max_hz: u16 = 16000;

/// What the buzzer is doing, as last commanded (null: silent).
var playing: ?core.Tone = null;
/// `tone2` calls since boot (a `debug_*` export).
pub var tone_calls: u32 = 0;

fn stop() void {
    if (playing == null) return;
    cart.tone2(cart.Tone2Options.stop);
    tone_calls +%= 1;
    playing = null;
}

/// Stop the buzzer (the game is paused).
pub fn silence() void {
    stop();
}

/// The frequency now sounding, 0 when silent (a `debug_*` export).
pub fn playing_hz() u32 {
    return if (playing) |p| p.hz else 0;
}

/// Once per update, after the frames ran.
pub fn update(md: *const core.Md) void {
    if (!enabled) return stop();
    const t = md.tone() orelse return stop();
    if (t.hz < min_hz or t.hz > max_hz) return stop();
    if (playing) |p| if (p.hz == t.hz and p.level == t.level) return;
    cart.tone2(.{
        .frequency = @floatFromInt(t.hz),
        .duration = -1.0,
        .volume = 0.2 + @as(f32, @floatFromInt(t.level)) * (0.8 / 15.0),
        .flags = .{ .shape = .square },
    });
    tone_calls +%= 1;
    playing = t;
}

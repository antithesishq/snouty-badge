//! The cart's few sounds (SPEC 5): the bell where the listing says
//! "BELLS IN LINE 2660" (a big kill) and "5470, 5480" (the arrival), a
//! gunshot crack on every shot, a low knell at a death and a short
//! fanfare at the arrival. One voice; each effect is a short list of notes
//! played by a frame-counted sequencer, a new effect cutting the old.
//!
//! The badge renders the voice itself into the newer firmware's streaming
//! ring (lib/tone_stream.zig; that OS ignores `tone2`, docs/SOUND.md
//! section 7); only the wasm build calls `cart.tone2` (finite tones, for
//! the simulator). Off by default: App.sound starts as `-Dsound` says and
//! the title menu or the help overlay toggles it.
const cart = @import("cart-api");
const tone_stream = @import("tone_stream");
const app_mod = @import("app.zig");

const Shape = tone_stream.Shape;

const Note = struct {
    /// 0 is a rest.
    hz: u16,
    ms: u16,
    shape: Shape = .triangle,
    /// Percent of full level.
    vol: u8 = 60,
};

const crack = [_]Note{
    .{ .hz = 2600, .ms = 12, .shape = .square, .vol = 70 },
    .{ .hz = 180, .ms = 30, .shape = .sawtooth, .vol = 70 },
    .{ .hz = 90, .ms = 70, .shape = .sawtooth, .vol = 50 },
};
const bell = [_]Note{
    .{ .hz = 1319, .ms = 90, .vol = 70 },
    .{ .hz = 1319, .ms = 260, .vol = 35 },
    .{ .hz = 0, .ms = 60 },
    .{ .hz = 1319, .ms = 90, .vol = 70 },
    .{ .hz = 1319, .ms = 400, .vol = 30 },
};
const knell = [_]Note{
    .{ .hz = 98, .ms = 700, .shape = .minor, .vol = 60 },
    .{ .hz = 0, .ms = 250 },
    .{ .hz = 98, .ms = 700, .shape = .minor, .vol = 50 },
    .{ .hz = 0, .ms = 250 },
    .{ .hz = 73, .ms = 1200, .shape = .minor, .vol = 45 },
};
const fanfare = [_]Note{
    .{ .hz = 523, .ms = 110 },
    .{ .hz = 659, .ms = 110 },
    .{ .hz = 784, .ms = 110 },
    .{ .hz = 1047, .ms = 220 },
    .{ .hz = 0, .ms = 60 },
    .{ .hz = 784, .ms = 110 },
    .{ .hz = 1047, .ms = 600, .shape = .major },
};

var seq: []const Note = &.{};
var at: usize = 0;
var frames_left: u32 = 0;

fn start_tone(n: Note) void {
    const peak = tone_stream.level_from_volume(n.vol);
    if (cart.is_wasm) {
        cart.tone2(.{
            .frequency = @floatFromInt(n.hz),
            .duration = @as(f32, @floatFromInt(n.ms)) * (1.0 / 1000.0),
            .volume = @as(f32, @floatFromInt(n.vol)) * (1.0 / 100.0),
            .flags = .{ .shape = @fromBackingInt(@intCast(@backingInt(n.shape))) },
        });
    } else {
        tone_stream.play(n.hz, tone_stream.ms(n.ms), peak, n.shape);
    }
}

/// Once per cart update: takes the App's effect (if the sound is on),
/// steps the sequencer and feeds the ring.
pub fn update(app: *app_mod.App) void {
    const fx = app.sfx;
    app.sfx = .none;
    if (!app.sound) {
        if (seq.len > 0) {
            seq = &.{};
            if (!cart.is_wasm) tone_stream.stop();
        }
    } else if (fx != .none) {
        seq = switch (fx) {
            .crack => &crack,
            .bell => &bell,
            .knell => &knell,
            .fanfare => &fanfare,
            .none => unreachable,
        };
        at = 0;
        frames_left = 0;
    }
    if (seq.len > 0 and frames_left == 0) {
        if (at < seq.len) {
            const n = seq[at];
            at += 1;
            if (n.hz == 0) {
                if (!cart.is_wasm) tone_stream.stop();
            } else start_tone(n);
            frames_left = @max(1, (@as(u32, n.ms) * 60 + 999) / 1000);
        } else {
            seq = &.{};
        }
    }
    if (frames_left > 0) frames_left -= 1;
    if (!cart.is_wasm) tone_stream.update();
}

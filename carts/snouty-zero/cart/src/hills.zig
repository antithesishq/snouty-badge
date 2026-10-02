//! Hills (SPEC 15, M4): a height profile along the centerline from the
//! `hill` flag (centerline flags bit 7). A run of hill samples becomes a
//! smooth rise and fall of `amp` world px; the renderer bends the floor
//! rows and the sprite projection with it. Visual only: the simulation
//! never reads it.
const fixed = @import("fixed.zig");
const track = @import("track.zig");
const world = @import("world.zig");
const sim = @import("sim.zig");

pub const flag_hill: u8 = 0x80;
/// Crest height, world px.
pub const amp: i32 = 26;

/// Height per centerline sample, world px.
pub var profile: [256]u8 = @splat(0);
pub var any: bool = false;

/// Build the profile for a track: each maximal run of hill samples gets
/// a half-sine bump.
pub fn init(t: *const track.Track) void {
    profile = @splat(0);
    any = false;
    var i: usize = 0;
    while (i < 256) : (i += 1) {
        if (t.sample(i).flags & flag_hill == 0) continue;
        // Skip runs that started before index 0 (handled from their start).
        if (i == 0) {
            // Find the true start by walking backwards around the ring.
            var s: usize = 255;
            while (s > 0 and t.sample(s).flags & flag_hill != 0) s -= 1;
            if (s != 0) {
                // The run wraps: start at s + 1.
                _ = fill_run(t, s + 1);
                // Skip the part of it at the front.
                while (i < 256 and t.sample(i).flags & flag_hill != 0) i += 1;
                continue;
            }
        }
        const len = fill_run(t, i);
        i += len;
    }
}

/// Fills the run starting at `start`, returns its length.
fn fill_run(t: *const track.Track, start: usize) usize {
    var len: usize = 0;
    while (len < 256 and t.sample((start + len) & 255).flags & flag_hill != 0) len += 1;
    if (len == 0) return 0;
    any = true;
    for (0..len) |k| {
        // sin(pi * (k + 0.5) / len) via the turn table: half a turn over the run.
        const a: fixed.Turn = @intCast(((2 * k + 1) * 32768) / (2 * len));
        profile[(start + k) & 255] = @intCast((fixed.sin(a) * amp) >> fixed.Q);
    }
    return len;
}

/// Height of the floor at `samples_ahead` (Q16.16 samples) of the player's
/// progress, world px, linearly interpolated.
pub fn height_at(samples_ahead: i32) i32 {
    const p = &world.w.machines[world.player];
    const base: i32 = @as(i32, p.progress) << fixed.Q;
    const pos = base + samples_ahead;
    const i: usize = @intCast((pos >> fixed.Q) & 255);
    const f: i32 = pos & 0xFFFF;
    const h0: i32 = profile[i];
    const h1: i32 = profile[(i + 1) & 255];
    return h0 + (((h1 - h0) * f) >> fixed.Q);
}

/// World px per centerline sample, Q16.16 (lap length / 256).
pub fn sample_px() i32 {
    const lap: i32 = world.w.lap_px;
    return (lap << fixed.Q) >> 8;
}

/// Height at distance `z` world px ahead of the camera (which sits
/// `cam_behind` behind the player), relative to the floor under the camera.
pub noinline fn height_ahead(z: i32, cam_behind: i32) i32 {
    if (!any) return 0;
    const spx = sample_px();
    if (spx == 0) return 0;
    const ahead_samples = fixed.div(z - cam_behind, spx >> fixed.Q);
    const cam_samples = fixed.div(-cam_behind, spx >> fixed.Q);
    return height_at(ahead_samples) - height_at(cam_samples);
}

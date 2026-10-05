//! RIPPLE: interference of ring waves (SPEC.md section 2.2). Nine emitters
//! sit at the zone centres and a tenth rides the hand. Each zone's presence
//! sets its emitter's amplitude, its nearness the wavelength (closer =
//! tighter rings) and how fast the rings run; the sum, wrapped through the
//! palette, is a moiré you play with your fingers. Without a hand the nine
//! hum quietly with slowly drifting phases. Punch: every phase jumps and the
//! hand emitter rings loud. Param: wavelength.
//!
//! Per pixel: one distance-table load (`dist[|dx|][|dy|]`, Q4 pixels, built
//! at init) per emitter, a multiply, an integer sine, a multiply-add.
const std = @import("std");
const math = @import("../math.zig");
const palette = @import("../palette.zig");
const surface = @import("../surface.zig");
const U = @import("../uniforms.zig").U;
const arena = @import("arena.zig");

pub const name = "RIPPLE";
pub const param_name = "WAVE";
pub const default_palette = 0;

const emitters = 10;
/// Zone centres (surface pixels).
const cx = [3]i32{ 13, 40, 67 };
const cy = [3]i32{ 11, 32, 53 };
/// Amplitude (Q8) of an idle emitter and of a fully covered one.
const amp_idle: f32 = 40;
const amp_hand: f32 = 256;
/// Wavelength (pixels) far and near, scaled by the param.
const lambda_far: f32 = 24;
const lambda_near: f32 = 8;
/// Phase speed (turns per second) far and near.
const speed_far: f32 = 0.35;
const speed_near: f32 = 1.6;
/// Colour cycles across the summed range.
const gain: f32 = 0.9;

/// Distance in Q4 pixels for |dx| < 80, |dy| < 64 (in the shared arena).
const Dist = [surface.w][surface.h]u16;
var dist: *Dist = undefined;
/// Emitter phases (1024 per turn, Q6 fraction).
var phase: [emitters]u32 = @splat(0);
var hand_boost: f32 = 0;
var lut: palette.Lut = undefined;

pub fn init() void {}

pub fn enter() void {
    dist = arena.as(Dist);
    for (&phase, 0..) |*p, i| p.* = @intCast(i * 97 << 6);
    hand_boost = 0;
    for (0..surface.w) |x| for (0..surface.h) |y| {
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        dist[x][y] = @intFromFloat(@sqrt(fx * fx + fy * fy) * 16.0);
    };
}


const Emitter = struct { x: i32, y: i32, k: i32, ph: u32, a: i32 };

pub fn render(u: *const U, pal: *const palette.Cosine, out: *surface.Surface) void {
    const lam_scale = 0.6 + 0.1 * @as(f32, @floatFromInt(u.param));
    if (u.punch_age == 0) {
        hand_boost = 1.0;
        for (&phase, 0..) |*p, i| p.* +%= @intCast((256 + i * 64) << 6);
    }
    hand_boost *= 0.97;

    var em: [emitters]Emitter = undefined;
    var n: usize = 0;
    var amp_sum: f32 = 0;
    for (0..emitters) |i| {
        var a: f32 = undefined;
        var near: f32 = undefined;
        var ex: i32 = undefined;
        var ey: i32 = undefined;
        if (i < 9) {
            const pres = u.presence[i];
            near = u.near[i] * pres;
            a = amp_idle + (amp_hand - amp_idle) * pres;
            ex = cx[i % 3];
            ey = cy[i / 3];
        } else {
            const on: f32 = if (u.hand.present) 1 else 0;
            near = u.hand.z;
            a = (0.35 * on * u.hand.z + hand_boost) * amp_hand;
            ex = std.math.clamp(math.iround(u.hx), 0, surface.w - 1);
            ey = std.math.clamp(math.iround(u.hy), 0, surface.h - 1);
        }
        const lambda = (lambda_far + (lambda_near - lambda_far) * near) * lam_scale;
        const speed = speed_far + (speed_near - speed_far) * near + if (i == 9) hand_boost * 2.0 else 0;
        // Phases advance outward (rings expand): subtract.
        phase[i] -%= @intFromFloat(speed * (1024.0 * 64.0 / 60.0));
        if (a < 2) continue;
        amp_sum += a;
        em[n] = .{
            .x = ex,
            .y = ey,
            // Q8 turns-per-Q4-pixel: 1024 / (lambda * 16) * 256.
            .k = @intFromFloat(16384.0 / lambda),
            .ph = phase[i] >> 6,
            .a = @intFromFloat(a),
        };
        n += 1;
    }
    // Scale so the sum spans `gain` palette cycles at full swing.
    const norm: i32 = @intFromFloat(gain * 256.0 * 256.0 / @max(amp_sum, 1.0));

    for (&lut, 0..) |*e, i| {
        const f = @as(f32, @floatFromInt(i)) / 256.0;
        const band = 0.5 + 0.5 * math.cos_turns(f * 3.0);
        e.* = palette.pack(palette.at(pal, f + u.t * 0.03 + u.kick), 0.25 + 0.95 * band, u.flash);
    }

    // Emitter-outer per column: each emitter's constants stay in registers
    // and the |dy| split into two runs walks its distance column with no abs.
    var acc: [surface.h]i32 = undefined;
    for (0..surface.w) |x| {
        @memset(&acc, 0);
        const xi: i32 = @intCast(x);
        for (em[0..n]) |e| {
            const dcol = &dist[@abs(xi - e.x)];
            const k = e.k;
            const ph: i32 = @bitCast(e.ph);
            const a = e.a;
            const ey: usize = @intCast(e.y);
            // Rows above the emitter: |dy| = ey - y.
            for (0..ey) |y| {
                const d: i32 = dcol[ey - y];
                acc[y] += (math.isin(@bitCast(((d * k) >> 8) + ph)) * a) >> 15;
            }
            for (ey..surface.h) |y| {
                const d: i32 = dcol[y - ey];
                acc[y] += (math.isin(@bitCast(((d * k) >> 8) + ph)) * a) >> 15;
            }
        }
        const col = &out[x];
        for (0..surface.h) |y| {
            const idx: u32 = @bitCast((acc[y] * norm) >> 8);
            col[y] = lut[(idx +% 128) & 255];
        }
    }
}

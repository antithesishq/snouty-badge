//! The 80 KB arena shared by the real-time tracer and the freeze-frame path
//! tracer (PLAN.md M4 "Memory"). The real-time tracer keeps
//! water.primary_fade_rt (40 KB) in its first half; pt.zig keeps its
//! 160 x 128 accumulator in all of it. Only one of them runs at a time:
//! pt.begin takes the arena (owner = .pt), pt.release gives it back and
//! invalidates the real-time tables, so the next real-time frame rebuilds
//! them (about 1.6 ms, once).
const camera = @import("camera.zig");

pub var words: [camera.width * camera.height]u32 align(8) = undefined;

pub const Owner = enum { realtime, pt };
pub var owner: Owner = .realtime;

//! STUB (Track B, M4): stand-in for Track A's arena.zig so the app state
//! machine builds and runs before the path tracer lands. Same declarations
//! as PLAN.md M4 "Memory"; the integrator replaces this file with Track A's.
//! The real-time tracer does not use it here (water.zig is unchanged in
//! this branch), so an 80 KB stub arena would be pure extra .bss and half30
//! overflows the RAM window with it: this stub is half size (two RGB565
//! pixels per word, what pt.zig's stub stores). Track A's arena is the full
//! PLAN.md size and takes water.primary_fade_rt's 40 KB in exchange.
const camera = @import("camera.zig");

pub var words: [camera.width * camera.height / 2]u32 align(8) = undefined;
pub const Owner = enum { realtime, pt };
pub var owner: Owner = .realtime;

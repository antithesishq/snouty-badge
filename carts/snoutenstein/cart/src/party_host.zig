//! The party deathmatch's pure core for host programs outside the cart
//! (tools/party_e2e: real `badge lobby` end to end, docs/LOCKSTEP_N.md):
//! one module root that reaches the files a host program needs, since a
//! Zig module cannot import files above its root. No cart-api.
pub const match = @import("match.zig");
pub const bot = @import("bot.zig");
pub const levels = @import("levels.zig");
pub const state = @import("state.zig");

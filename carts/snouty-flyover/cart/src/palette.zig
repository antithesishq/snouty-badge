//! The 256-entry palette (layout SPEC.md 5.3), the per-frame fog table and the
//! water table. Stub: Track A fills the literal table and begin_frame.
pub const rgb565: [256]u16 = @splat(0);
pub var fog: [8][256]u16 = undefined;
pub const water: [256]u16 = @splat(0);

/// Cycle the pulse ranges (M1) and rebuild `fog` for this frame.
pub fn begin_frame(frame: u32) void {
    _ = frame;
}

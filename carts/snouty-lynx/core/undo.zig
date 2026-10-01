//! Time scrubber state store (SPEC.md section 10, PLAN.md "Frozen for M3"):
//! copy-on-first-write undo records applied by swapping, Snouty Genesis's
//! design (carts/snouty-genesis/core/undo.zig). One tracker for one
//! console, file-level state so the bus write path and Suzy can reach the
//! dirty bytes without a Lynx offset. No cart-api, no allocator: the arena
//! comes from the frontend. M3 prep: the frozen shape as no-op stubs
//! (Track A fills it); `touch`/`touch_range` must stay trivially cheap when
//! tracking is off.
const lynx_mod = @import("lynx.zig");
const Lynx = lynx_mod.Lynx;

pub const block_size = 64;
pub const Slot = extern struct { id: u16, pad: u16 = 0, data: [block_size]u8 };
pub const frames_per_record = 30;
pub const max_records = 64;
pub const Region = enum(u4) { ram = 0, small = 15 };

var arena_slots: usize = 0;

pub fn init(arena: []align(4) u8) void {
    arena_slots = arena.len / @sizeOf(Slot);
}
pub fn capacity_slots() usize {
    return arena_slots;
}
pub fn reset(l: *Lynx) void {
    _ = l;
}
pub fn disable() void {}
pub fn record_frame(l: *Lynx) void {
    _ = l;
}
pub fn can_step(dir: i2) bool {
    _ = dir;
    return false;
}
pub fn step(l: *Lynx, dir: i2) bool {
    _ = l;
    _ = dir;
    return false;
}
pub fn parked() bool {
    return false;
}
pub fn resume_here(l: *Lynx) void {
    _ = l;
}
pub fn depth_frames() u32 {
    return 0;
}
pub fn history_frames() u32 {
    return 0;
}
pub fn record_count() usize {
    return 0;
}
pub fn slots_in_use() usize {
    return 0;
}
pub fn lost_history() bool {
    return false;
}
/// One RAM byte is about to be written.
pub inline fn touch(addr: u16) void {
    _ = addr;
}
/// `bytes` RAM bytes from `addr` are about to be written (wraps at 64 KB).
pub fn touch_range(addr: u16, bytes: u32) void {
    _ = addr;
    _ = bytes;
}

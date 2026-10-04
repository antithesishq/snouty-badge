//! Streaming audio on the badge's new OS firmware (sycl-badge upstream
//! 97c093e "Streaming Audio, v1 Mixer", checked at 3392a1b), spoken by the
//! cart itself: the pinned SDK (a6ce19f) has no API for it and still
//! describes the old `tone` words in the IPC block. Snouty Lynx's M5
//! (carts/snouty-lynx/PLAN.md "M5 Sound: contract"); any cart may use it.
//!
//! The ABI (upstream `src/os/cart/os_abi.zig`, `platform_badge.zig`
//! `audio_set_buffer`/`audio_submit_samples`, `drivers/audio.zig`
//! `mix_buffer_samples`, `kernel.zig` `handle_cart_message`):
//!
//! - The cart owns a ring of unsigned 8-bit mono samples at `sample_rate`
//!   (128 = silence), `align(8)`. Four u32 words of the IPC block
//!   (base 0x20020000) describe it, at 0x2003509C (`Ring`): `ptr` (its
//!   address), `len`, `head` (the cart's: the next sample it will write)
//!   and `tail` (the OS's: the next sample it will read). Empty when
//!   head == tail; the cart fills at most len - 1. Indices wrap at len.
//! - `start`: write ptr, len, head = 0, tail = 0, `dmb`, then the FIFO
//!   word 0x29000002 (CART_START_AUDIO) to SIO FIFO_WR 0xD0000054 once
//!   FIFO_ST 0xD0000050 bit 1 (RDY) is set, then `sev`, as the pinned
//!   runtime sends its words. `push`: samples at head, `dmb`, the new head.
//! - The OS mixes 512 samples per DMA buffer (~11.6 ms, two buffers ping-
//!   pong), pads an underrun with silence, and stops audio itself when
//!   the cart exits.
//! - Never CART_STOP_AUDIO (0x29000001): the OS answers it with a FIFO word
//!   (0x29000003) the pinned runtime does not expect. To go quiet, stop
//!   pushing.
//! - Old firmware: 0x29000002 has the type byte 0x29 of its CART_VOLUME,
//!   which re-applies `global_volume` (0x200350AC, never written here) and
//!   plays nothing; the ring words overlay the unused `tone_*` words.
//!   Harmless, no detection needed.
//!
//! The ring is reached through `ring`, a pointer the caller may replace:
//! the badge build points it at the IPC words, every other target (the
//! wasm simulator, which has no streaming audio, and host tests) at a
//! plain struct; the FIFO send and `dmb` compile only for the badge.
//! The samples are written through the slice `start` was given, so the
//! host tests never dereference `Ring.ptr` (a u32 address on the badge).
const builtin = @import("builtin");

/// The firmware's streaming rate (upstream api.zig `audio_sample_rate`).
pub const sample_rate = 44100;

/// The four IPC words (upstream `CartIPCData.audio_buffer_*`).
pub const Ring = extern struct { ptr: u32, len: u32, head: u32, tail: u32 };

/// Where the badge firmware keeps `Ring` (IPC base 0x20020000 + 0x1509C).
pub const ipc_ring_address = 0x2003509C;

/// The Cortex-M33 cart core (RAM and XIP carts); false for wasm and hosts.
pub const is_badge = builtin.os.tag == .freestanding and (builtin.cpu.arch.isThumb() or builtin.cpu.arch.isArm());

/// CART_START_AUDIO.
pub const start_word: u32 = 0x29000002;

const sio_fifo_st: usize = 0xD0000050;
const sio_fifo_wr: usize = 0xD0000054;
const fifo_rdy: u32 = 1 << 1;

/// Stand-in ring off the badge.
var off_badge_ring: Ring = .{ .ptr = 0, .len = 0, .head = 0, .tail = 0 };

/// The ring's words; replace before `start` to run against another ring.
pub var ring: *volatile Ring = if (is_badge) @ptrFromInt(ipc_ring_address) else &off_badge_ring;

/// The sample buffer `start` was given (empty before).
var buf: []u8 = &.{};

/// Hand `b` to the OS and start playback (silence until the first `push`).
/// Call once; `b.len` must be at least 2 (one sample of capacity).
pub fn start(b: []align(8) u8) void {
    buf = b;
    const r = ring;
    r.ptr = @truncate(@intFromPtr(b.ptr));
    r.len = @intCast(b.len);
    r.head = 0;
    r.tail = 0;
    dmb();
    if (comptime is_badge) fifo_send(start_word);
}

/// Samples written and not yet read by the OS (0 before `start`).
pub fn queued() u32 {
    const len: u32 = @intCast(buf.len);
    if (len == 0) return 0;
    const r = ring;
    const head = r.head;
    const tail = r.tail;
    return if (head >= tail) head - tail else len - tail + head;
}

/// Samples `push` would take now (len - 1 - queued; 0 before `start`).
pub fn free() u32 {
    const len: u32 = @intCast(buf.len);
    if (len == 0) return 0;
    return len - 1 - queued();
}

/// Copy as many of `s` as fit, wrapping at the end of the buffer, then
/// publish the new head. Returns the count written.
pub fn push(s: []const u8) u32 {
    const n: u32 = @min(@as(u32, @intCast(s.len)), free());
    if (n == 0) return 0;
    const len: u32 = @intCast(buf.len);
    const head = ring.head;
    const first = @min(n, len - head);
    @memcpy(buf[head..][0..first], s[0..first]);
    @memcpy(buf[0 .. n - first], s[first..n]);
    var new_head = head + n;
    if (new_head >= len) new_head -= len;
    // The samples must be visible to the OS core before the head that
    // covers them.
    dmb();
    ring.head = new_head;
    return n;
}

inline fn dmb() void {
    if (comptime is_badge) asm volatile ("dmb" ::: .{ .memory = true });
}

/// The pinned runtime's send (platform_cart_ram.zig `tone2`): wait for
/// room in the FIFO, write the word, wake the OS core.
fn fifo_send(word: u32) void {
    const st: *volatile u32 = @ptrFromInt(sio_fifo_st);
    const wr: *volatile u32 = @ptrFromInt(sio_fifo_wr);
    while (st.* & fifo_rdy == 0) asm volatile ("nop");
    wr.* = word;
    asm volatile ("sev");
}

// ---- Host tests ----

const std = @import("std");

/// A test ring of `n` samples behind a plain `Ring`; restores nothing (each
/// test points `ring` at its own struct).
fn test_ring(r: *Ring, b: []align(8) u8) void {
    ring = r;
    start(b);
}

/// What the OS does: read `k` samples from tail (k <= queued).
fn os_consume(r: *Ring, out: []u8) void {
    for (out) |*o| {
        o.* = buf[r.tail];
        r.tail = if (r.tail + 1 == r.len) 0 else r.tail + 1;
    }
}

test "stream_audio: empty ring" {
    var r: Ring = undefined;
    var b: [16]u8 align(8) = undefined;
    test_ring(&r, &b);
    try std.testing.expectEqual(@as(u32, 16), r.len);
    try std.testing.expectEqual(@as(u32, 0), r.head);
    try std.testing.expectEqual(@as(u32, 0), r.tail);
    try std.testing.expectEqual(@as(u32, @truncate(@intFromPtr(&b))), r.ptr);
    try std.testing.expectEqual(@as(u32, 0), queued());
    try std.testing.expectEqual(@as(u32, 15), free());
    try std.testing.expectEqual(@as(u32, 0), push(&.{}));
}

test "stream_audio: len-1 capacity and a full ring" {
    var r: Ring = undefined;
    var b: [8]u8 align(8) = undefined;
    test_ring(&r, &b);
    const s = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try std.testing.expectEqual(@as(u32, 7), push(&s));
    try std.testing.expectEqual(@as(u32, 7), queued());
    try std.testing.expectEqual(@as(u32, 0), free());
    try std.testing.expectEqual(@as(u32, 7), r.head);
    // Full: nothing more goes in, the head stays one short of the tail.
    try std.testing.expectEqual(@as(u32, 0), push(&s));
    try std.testing.expectEqual(@as(u32, 7), r.head);
    var out: [7]u8 = undefined;
    os_consume(&r, &out);
    try std.testing.expectEqualSlices(u8, s[0..7], &out);
    try std.testing.expectEqual(@as(u32, 0), queued());
    try std.testing.expectEqual(@as(u32, 7), free());
}

test "stream_audio: writes wrap at len" {
    var r: Ring = undefined;
    var b: [8]u8 align(8) = @splat(0);
    test_ring(&r, &b);
    var out: [6]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 6), push(&.{ 1, 2, 3, 4, 5, 6 }));
    os_consume(&r, &out);
    // head = tail = 6: five samples go to 6, 7, 0, 1, 2.
    try std.testing.expectEqual(@as(u32, 5), push(&.{ 10, 11, 12, 13, 14 }));
    try std.testing.expectEqual(@as(u32, 3), r.head);
    try std.testing.expectEqual(@as(u32, 5), queued());
    try std.testing.expectEqual(@as(u32, 2), free());
    try std.testing.expectEqualSlices(u8, &.{ 12, 13, 14 }, b[0..3]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 11 }, b[6..8]);
    os_consume(&r, out[0..5]);
    try std.testing.expectEqualSlices(u8, &.{ 10, 11, 12, 13, 14 }, out[0..5]);
    // A push that ends exactly at len leaves head at 0, not len.
    r.head = 3;
    r.tail = 3;
    try std.testing.expectEqual(@as(u32, 5), push(&.{ 1, 2, 3, 4, 5 }));
    try std.testing.expectEqual(@as(u32, 0), r.head);
}

test "stream_audio: queued and free with the tail ahead of the head" {
    var r: Ring = undefined;
    var b: [4096]u8 align(8) = undefined;
    test_ring(&r, &b);
    r.head = 100;
    r.tail = 4000;
    try std.testing.expectEqual(@as(u32, 196), queued());
    try std.testing.expectEqual(@as(u32, 4096 - 1 - 196), free());
    r.head = 3999;
    try std.testing.expectEqual(@as(u32, 4095), queued());
    try std.testing.expectEqual(@as(u32, 0), free());
}

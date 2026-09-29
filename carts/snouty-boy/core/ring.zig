//! Keyframe ring bookkeeping for the time scrubber (SPEC.md section 10),
//! kept free of cart-api and of the keyframe payload so the host tests can
//! exercise it (`tests/ring_unit.zig`). `cart/src/frontend/rewind.zig` owns
//! the actual keyframe slots and input log and asks this type which slot
//! and which log byte to touch.
//!
//! Frame numbers count frames recorded since `reset` (not `Gb.frame_count`).
//! Keyframe slots hold the console at frames 0, interval, 2 * interval, ...;
//! the input log byte for frame f is the pad that stepped the console from
//! frame f to frame f + 1, stored at `log_index(f)`.
//!
//! Positions: `live` is the newest recorded frame, where the game was when
//! the menu opened. `cursor` is null while the game sits at `live`, or the
//! age of the keyframe the game is parked on (0 = newest keyframe). Stepping
//! the game from a parked position truncates the history to that keyframe
//! (SPEC.md 10.1: no branching history).
const std = @import("std");

/// `max_n` sizes the input log and bounds the slot count; the slots in use,
/// `n`, are chosen at run time (`init`), because on the badge the keyframe
/// pool and the slot size (cart RAM per the ROM header) are only known at
/// start. `n` defaults to `max_n`.
pub fn Ring(comptime max_n: usize, comptime interval: u32) type {
    if (max_n < 2) @compileError("a keyframe ring needs at least 2 slots");
    if (interval == 0) @compileError("interval must be positive");
    return struct {
        const Self = @This();

        pub const max_slots = max_n;
        pub const frames_per_keyframe = interval;
        /// Input log length in frames. The span from the oldest keyframe to
        /// `live` is at most (n - 1) * interval + interval - 1 frames, so a
        /// log of max_n * interval never overwrites a byte still needed.
        pub const log_len: u32 = max_n * interval;

        /// Slots in use, 2..max_n.
        n: usize = max_n,
        /// Valid keyframes, 1..n after `reset`.
        count: usize = 0,
        /// Slot of the newest keyframe.
        head: usize = 0,
        /// Newest recorded frame number.
        live: u32 = 0,
        /// Age of the keyframe the game is parked on, or null at `live`.
        cursor: ?usize = null,

        /// What the caller does after `record`.
        pub const Record = struct {
            /// Store this frame's pad here.
            log_index: usize,
            /// Snapshot the console (after the step) into this slot.
            snapshot_slot: ?usize,
        };

        /// What the caller does for `step`.
        pub const Step = union(enum) {
            /// Restore this slot; the game is now parked on it.
            restore: usize,
            /// Restore `slot`, then replay the logged frames `from..to`
            /// (`to` exclusive) to get back to `live`.
            replay: struct { slot: usize, from: u32, to: u32 },
        };

        /// A ring using `n` of the `max_n` slots (clamped to 2..max_n).
        pub fn init(n: usize) Self {
            return .{ .n = @min(@max(n, 2), max_n) };
        }

        /// Forget all history. The caller snapshots the reset console into
        /// the returned slot (frame 0).
        pub fn reset(r: *Self) usize {
            r.* = .{ .n = r.n, .count = 1, .head = 0, .live = 0, .cursor = null };
            return 0;
        }

        /// Frame number of the newest keyframe.
        pub fn head_frame(r: Self) u32 {
            return r.live - r.live % interval;
        }

        pub fn slot_of_age(r: Self, age: usize) usize {
            std.debug.assert(age < r.count);
            return (r.head + r.n - age) % r.n;
        }

        pub fn frame_of_age(r: Self, age: usize) u32 {
            return r.head_frame() - @as(u32, @intCast(age)) * interval;
        }

        pub fn log_index(f: u32) usize {
            return f % log_len;
        }

        /// The input log holds the pad for frame `f` (it has been played and
        /// not yet overwritten).
        pub fn has_pad(r: Self, f: u32) bool {
            return f < r.live and r.live - f <= log_len;
        }

        /// Frame the game is at: `live`, or the parked keyframe's frame.
        pub fn position(r: Self) u32 {
            return if (r.cursor) |a| r.frame_of_age(a) else r.live;
        }

        /// A game frame was just stepped. Truncates the future first if the
        /// game was parked on a keyframe.
        pub fn record(r: *Self) Record {
            if (r.cursor) |a| {
                r.live = r.frame_of_age(a);
                r.head = r.slot_of_age(a);
                r.count -= a;
                r.cursor = null;
            }
            const idx = log_index(r.live);
            r.live += 1;
            var snap: ?usize = null;
            if (r.live % interval == 0) {
                r.head = (r.head + 1) % r.n;
                r.count = @min(r.count + 1, r.n);
                snap = r.head;
            }
            return .{ .log_index = idx, .snapshot_slot = snap };
        }

        /// Age Left (dir < 0) or Right (dir > 0) would move the cursor to,
        /// null at the ends. Right from age 0 goes back to `live`.
        fn target(r: Self, dir: i2) ?union(enum) { age: usize, live } {
            if (dir < 0) {
                const a: usize = if (r.cursor) |c|
                    c + 1
                else if (r.live == r.head_frame()) 1 else 0;
                return if (a < r.count) .{ .age = a } else null;
            }
            if (dir > 0) {
                const c = r.cursor orelse return null;
                return if (c == 0) .live else .{ .age = c - 1 };
            }
            return null;
        }

        pub fn can_step(r: Self, dir: i2) bool {
            return r.target(dir) != null;
        }

        /// Move the cursor one keyframe; null (and no change) at the ends.
        pub fn step(r: *Self, dir: i2) ?Step {
            const t = r.target(dir) orelse return null;
            switch (t) {
                .age => |a| {
                    r.cursor = a;
                    return .{ .restore = r.slot_of_age(a) };
                },
                .live => {
                    r.cursor = null;
                    return .{ .replay = .{ .slot = r.slot_of_age(0), .from = r.head_frame(), .to = r.live } };
                },
            }
        }

        /// How far behind `live` the game is parked, in frames.
        pub fn depth_frames(r: Self) u32 {
            return r.live - r.position();
        }

        /// Frames of history reachable from `live` (back to the oldest
        /// keyframe).
        pub fn history_frames(r: Self) u32 {
            if (r.count == 0) return 0;
            return r.live - r.frame_of_age(r.count - 1);
        }

        /// History as fifths of the ring's full span (n - 1 keyframe gaps),
        /// rounded up: 0 with no history, 5 when the ring is full.
        pub fn history_fraction(r: Self) u8 {
            const full: u32 = @intCast((r.n - 1) * interval);
            const h: u32 = @min(r.history_frames(), full);
            return @intCast((h * 5 + full - 1) / full);
        }
    };
}

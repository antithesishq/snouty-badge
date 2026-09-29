//! Keyframe ring bookkeeping for the time scrubber (SPEC.md sections 10 and
//! 19.3), kept free of cart-api and of the keyframe payload so the host tests
//! can exercise it (`tests/ring_unit.zig`). The payload is a page store
//! (`core/kstore.zig`), which addresses keyframes by age (0 = newest) just
//! like this type; `cart/src/frontend/rewind.zig` owns the store and the
//! input log and asks this type which keyframe and which log byte to touch.
//!
//! Frame numbers count frames recorded since `reset` (not `Gb.frame_count`).
//! Keyframes hold the console at frames 0, interval, 2 * interval, ...; the
//! newest is at `head_frame()`. The input log byte for frame f is the pad
//! that stepped the console from frame f to frame f + 1, stored at
//! `log_index(f)`.
//!
//! Count. At most `n` keyframes, but the store may hold fewer: when its pool
//! runs out it evicts the oldest ones, and the caller reports the surviving
//! count with `set_count` after every snapshot. Eviction only ever removes
//! from the old end, so ages and frames stay consistent.
//!
//! Positions: `live` is the newest recorded frame, where the game was when
//! the menu opened. `cursor` is null while the game sits at `live`, or the
//! age of the keyframe the game is parked on (0 = newest keyframe). Stepping
//! the game from a parked position truncates the history to that keyframe
//! (SPEC.md 10.1: no branching history): `record` tells the caller how many
//! of the newest keyframes to drop from the store.
const std = @import("std");

pub fn Ring(comptime n: usize, comptime interval: u32) type {
    if (n < 2) @compileError("a keyframe ring needs at least 2 keyframes");
    if (interval == 0) @compileError("interval must be positive");
    return struct {
        const Self = @This();

        pub const max_keyframes = n;
        pub const frames_per_keyframe = interval;
        /// Input log length in frames. The span from the oldest keyframe to
        /// `live` is at most (n - 1) * interval + interval - 1 frames, so a
        /// log of n * interval never overwrites a byte still needed.
        pub const log_len: u32 = n * interval;

        /// Valid keyframes, 1..n after `reset`.
        count: usize = 0,
        /// Newest recorded frame number.
        live: u32 = 0,
        /// Age of the keyframe the game is parked on, or null at `live`.
        cursor: ?usize = null,

        /// What the caller does after `record`.
        pub const Record = struct {
            /// First drop this many of the newest keyframes from the store
            /// (truncation after resuming from a parked keyframe).
            drop_newest: usize,
            /// Store this frame's pad here.
            log_index: usize,
            /// Snapshot the console (after the step) as the new newest
            /// keyframe, then report the store's count with `set_count`.
            snapshot: bool,
        };

        /// What the caller does for `step`.
        pub const Step = union(enum) {
            /// Restore the keyframe of this age; the game is now parked on it.
            restore: usize,
            /// Restore the newest keyframe (age 0), then replay the logged
            /// frames `from..to` (`to` exclusive) to get back to `live`.
            replay: struct { from: u32, to: u32 },
        };

        /// Forget all history. The caller empties the store and snapshots
        /// the current console as the only keyframe (frame 0).
        pub fn reset(r: *Self) void {
            r.* = .{ .count = 1, .live = 0, .cursor = null };
        }

        /// The store could not keep the history (kstore `error.PoolFull`) and
        /// was emptied; the caller stored the console at `live`, which must
        /// be a keyframe frame, as the only keyframe.
        pub fn restart_at_live(r: *Self) void {
            std.debug.assert(r.live % interval == 0 and r.cursor == null);
            r.count = 1;
        }

        /// After a snapshot: the store now holds `c` keyframes (it may have
        /// evicted old ones). Only shrinks.
        pub fn set_count(r: *Self, c: usize) void {
            std.debug.assert(c >= 1 and c <= r.count);
            r.count = c;
        }

        /// Frame number of the newest keyframe.
        pub fn head_frame(r: Self) u32 {
            return r.live - r.live % interval;
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
            var drop: usize = 0;
            if (r.cursor) |a| {
                r.live = r.frame_of_age(a);
                r.count -= a;
                drop = a;
                r.cursor = null;
            }
            const idx = log_index(r.live);
            r.live += 1;
            const snap = r.live % interval == 0;
            if (snap) r.count = @min(r.count + 1, n);
            return .{ .drop_newest = drop, .log_index = idx, .snapshot = snap };
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
                    return .{ .restore = a };
                },
                .live => {
                    r.cursor = null;
                    return .{ .replay = .{ .from = r.head_frame(), .to = r.live } };
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
            const full: u32 = (n - 1) * interval;
            const h: u32 = @min(r.history_frames(), full);
            return @intCast((h * 5 + full - 1) / full);
        }
    };
}

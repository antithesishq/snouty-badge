//! The Antithesis part (SPEC.md 13.1, PLAN.md "Interface A (history.zig)"):
//! a ring of 8 World keyframes, one every 30 game ticks, and a ring of 256
//! logged controls words, so any tick of the last few seconds can be
//! rebuilt exactly by copying a keyframe and replaying the log through
//! `simulate(.silent)`. History is meta-state: it lives here, not in the
//! World, and is never rewound.
const cart = @import("cart-api");
const input = @import("input.zig");
const world = @import("world.zig");
const main = @import("main.zig");

/// 8 x 30 ticks (M7; was 4 x 60): the same 240 ticks of reach, but a
/// restore replays at most 29 silent ticks instead of 59, which kept the
/// hold-B frames of a full stage-4 wave inside the frame budget.
pub const keyframe_count = 8;
pub const keyframe_every: u32 = 30;
pub const log_len = 256;
pub const invalid: u32 = 0xFFFF_FFFF;

pub const State = struct {
    /// slot = (tick / 30) % 8.
    keyframes: [keyframe_count]world.World,
    /// Tick of each keyframe; `invalid` when the slot is empty.
    keyframe_tick: [keyframe_count]u32,
    /// Controls used for tick t, at log[t % 256].
    log: [log_len]u16,
    /// A keyframe saved by `checkpoint` holds the world *before* the
    /// input update of its tick (a `record` keyframe holds it after).
    pre_input: [keyframe_count]bool,
};

/// Left undefined (so the ~85 KB of keyframes are .bss, not .data) until
/// `reset`, which `main.start` and every new game call.
var st: State = undefined;

/// New game: all keyframes invalid. The log slots of ticks -1 and -2 get
/// the controls the World's edge detector starts from, so a restore to
/// tick 0 can rebuild it.
pub fn reset() void {
    st.keyframe_tick = @splat(invalid);
    st.pre_input = @splat(false);
    st.log = @splat(0);
    st.log[log_len - 1] = @bitCast(world.w.input.current);
    st.log[log_len - 2] = @bitCast(world.w.input.previous);
}

fn slot_of(tick: u32) usize {
    return (tick / keyframe_every) % keyframe_count;
}

fn log_at(tick: u32) cart.Controls {
    return @bitCast(st.log[tick % log_len]);
}

/// Called at the top of `simulate(.live)`, after `input.update` for the
/// tick: logs the controls and, every 30 ticks, saves a keyframe.
pub fn record() void {
    const t = world.w.game_tick;
    st.log[t % log_len] = @bitCast(world.w.input.current);
    if (t % keyframe_every == 0) {
        const i = slot_of(t);
        st.keyframes[i] = world.w;
        st.keyframe_tick[i] = t;
        st.pre_input[i] = false;
    }
}

/// Saves the world as it is now (between ticks, before the next input
/// update) as the keyframe of its 30-tick window. Called after anything
/// outside `simulate` edits the World (the rewind resume grant, the debug
/// warp), so no later restore replays across the edit without it.
pub fn checkpoint() void {
    const t = world.w.game_tick;
    const i = slot_of(t);
    st.keyframes[i] = world.w;
    st.keyframe_tick[i] = t;
    st.pre_input[i] = true;
}

/// Oldest tick a restore can reach (the oldest valid keyframe's tick), or
/// the current tick when there is no keyframe yet.
pub fn earliest_tick() u32 {
    var best: u32 = invalid;
    for (st.keyframe_tick) |t| {
        if (t != invalid and t < best) best = t;
    }
    return if (best == invalid) world.w.game_tick else best;
}

/// Rebuilds the world as it was at the start of frame `tick` (after tick
/// - 1 was simulated): copies the newest valid keyframe at or before
/// `tick` into w, then for t in kf.tick+1 .. tick-1 applies
/// `input.update(log[t])` and runs `simulate(.silent)`. Requires
/// earliest_tick() <= tick <= w.game_tick and tick - kf.tick <= 255;
/// returns false (and leaves w alone) otherwise.
pub fn restore(tick: u32) bool {
    if (tick > world.w.game_tick) return false;
    var best: ?usize = null;
    for (st.keyframe_tick, 0..) |t, i| {
        if (t == invalid or t > tick) continue;
        if (best == null or t > st.keyframe_tick[best.?]) best = i;
    }
    const i = best orelse return false;
    const kf_tick = st.keyframe_tick[i];
    if (tick - kf_tick >= log_len) return false;

    world.w = st.keyframes[i];
    if (st.pre_input[i]) {
        if (kf_tick == tick) return true;
        input.update(log_at(kf_tick));
    } else if (kf_tick == tick) {
        // A `record` keyframe already took tick's input; undo that.
        world.w.input = .{ .current = log_at(tick -% 1), .previous = log_at(tick -% 2) };
        return true;
    }
    while (true) {
        main.simulate(.silent);
        if (world.w.game_tick >= tick) break;
        input.update(log_at(world.w.game_tick));
    }
    return true;
}

/// Drops keyframes with tick > `tick` (the future that was rewound away).
pub fn invalidate_after(tick: u32) void {
    for (&st.keyframe_tick) |*t| {
        if (t.* != invalid and t.* > tick) t.* = invalid;
    }
}

/// Field-by-field comparison by comptime reflection (structs, arrays,
/// enums, bools, ints, floats by bit pattern). Padding bytes are never
/// read, so the pools' padding cannot cause a false mismatch.
pub fn worlds_equal(a: *const world.World, b: *const world.World) bool {
    return eql(world.World, a, b);
}

fn eql(comptime T: type, a: *const T, b: *const T) bool {
    switch (@typeInfo(T)) {
        .@"struct" => |s| {
            if (s.layout == .@"packed") {
                const I = @Int(.unsigned, @bitSizeOf(T));
                return @as(I, @bitCast(a.*)) == @as(I, @bitCast(b.*));
            }
            inline for (s.field_names, s.field_types) |name, F| {
                if (!eql(F, &@field(a.*, name), &@field(b.*, name))) return false;
            }
            return true;
        },
        .array => |arr| {
            for (a, b) |*x, *y| {
                if (!eql(arr.child, x, y)) return false;
            }
            return true;
        },
        .@"enum", .bool, .int => return a.* == b.*,
        .float => {
            const I = @Int(.unsigned, @bitSizeOf(T));
            return @as(I, @bitCast(a.*)) == @as(I, @bitCast(b.*));
        },
        else => @compileError("worlds_equal: unsupported field type " ++ @typeName(T)),
    }
}

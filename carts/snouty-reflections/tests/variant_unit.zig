//! Host test for cart/src/variant.zig (review G3): the frozen path
//! tracer's slice leaves room for the display in every variant's frame
//! period. Part of the root `zig build test` (build.zig registers it with
//! the selected build options); tools/check_variants.sh runs it standalone
//! with a build_options stub whose variant enum is read from build.zig.
const std = @import("std");
const variant = @import("variant");
const testing = std.testing;

test "variant: frozen path tracer slice < frame period for every variant" {
    var n: u32 = 0;
    for (std.enums.values(variant.Variant)) |v| {
        const f = variant.config_of(v).fps;
        const period = variant.frame_period_us(f);
        const slice = variant.pt_slice_for(f);
        std.debug.print("variant {s}: {d} fps, period {d} us, pt slice {d} us\n", .{ @tagName(v), f, period, slice });
        try testing.expect(slice > 0);
        try testing.expect(slice < period);
        try testing.expectEqual(variant.pt_reserve_us, period - slice);
        n += 1;
    }
    try testing.expect(n >= 4);
    // The shipped cut20 keeps M4's 36 ms; half30 keeps its 30 fps period.
    try testing.expectEqual(@as(u32, 36_000), variant.pt_slice_for(variant.config_of(.cut20).fps));
    try testing.expectEqual(@as(u32, 33_333), variant.frame_period_us(variant.config_of(.half30).fps));
    try testing.expect(variant.pt_slice_for(variant.config_of(.half30).fps) < 33_333 - 3_000);
}

test "variant: tufty20 is full15's scene at 20 fps" {
    // The Tufty 2350 port (docs/variants.md "tufty20"): every knob but the
    // frame rate comes from full15.
    var want = variant.config_of(.full15);
    want.fps = 20;
    try testing.expectEqualDeep(want, variant.config_of(.tufty20));
    try testing.expectEqual(@as(u32, 36_000), variant.pt_slice_for(variant.config_of(.tufty20).fps));
}

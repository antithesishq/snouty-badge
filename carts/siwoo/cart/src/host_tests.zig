//! Root for `zig build test`: the modules whose tests run on the host. The
//! test module imports the real cart API for its types only (Pixel,
//! Framebuffer); nothing here calls the platform.
const std = @import("std");
const font = @import("gen/name_font.zig");

test {
    _ = @import("math.zig");
    _ = @import("rng.zig");
    _ = @import("palette.zig");
    _ = @import("head.zig");
    _ = @import("name.zig");
}

test "name font: every capital is non-empty and fits its rows" {
    try std.testing.expectEqual(@as(u32, 20), font.height);
    var c: u8 = 'A';
    while (c <= 'Z') : (c += 1) {
        const g = font.glyph(c);
        try std.testing.expect(g.len > 0);
        for (g) |col| try std.testing.expect(col >> font.height == 0);
    }
    try std.testing.expectEqual(@as(usize, 0), font.glyph(' ').len);
}
